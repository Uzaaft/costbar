import Foundation

enum LocalUsageCollectionError: LocalizedError {
    case noData(provider: String)

    var errorDescription: String? {
        switch self {
        case let .noData(provider):
            "No local \(provider) usage was found for this month."
        }
    }
}

enum LocalAISettings {
    private static let codexKey = "track-codex-local-usage-v1"
    private static let claudeKey = "track-claude-local-usage-v1"

    static func tracksCodex(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: codexKey)
    }

    static func tracksClaude(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: claudeKey)
    }

    static func save(
        tracksCodex: Bool,
        tracksClaude: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(tracksCodex, forKey: codexKey)
        defaults.set(tracksClaude, forKey: claudeKey)
    }
}

enum LocalAIUsageCollector {
    static func codex(period: Dashboard.Period) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let usage = try scanCodex(period: period)
            let serverAllowances = CodexRateLimitReader.read() ?? []
            let allowances = serverAllowances.isEmpty ? usage.allowances : serverAllowances
            guard usage.foundData || !allowances.isEmpty else {
                throw LocalUsageCollectionError.noData(provider: "Codex")
            }
            return try encodeSnapshot(
                period: period,
                usage: usage.tokens,
                allowances: allowances,
                models: usage.models,
                source: "Local Codex sessions"
            )
        }.value
    }

    static func claude(period: Dashboard.Period) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let usage = try scanClaude(period: period)
            let allowances = readClaudeStatusAllowances()
            guard usage.foundData || !allowances.isEmpty else {
                throw LocalUsageCollectionError.noData(provider: "Claude")
            }
            return try encodeSnapshot(
                period: period,
                usage: usage.tokens,
                allowances: allowances,
                models: usage.models,
                source: "Local Claude Code sessions"
            )
        }.value
    }
}

private extension LocalAIUsageCollector {
    struct Tokens: Encodable {
        var inputTokens: UInt64 = 0
        var outputTokens: UInt64 = 0
        var cacheReadTokens: UInt64 = 0
        var cacheCreationTokens: UInt64 = 0
        var reasoningTokens: UInt64 = 0

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case cacheCreationTokens = "cache_creation_tokens"
            case reasoningTokens = "reasoning_tokens"
        }

        mutating func add(_ other: Tokens) {
            inputTokens = inputTokens.addingClamped(other.inputTokens)
            outputTokens = outputTokens.addingClamped(other.outputTokens)
            cacheReadTokens = cacheReadTokens.addingClamped(other.cacheReadTokens)
            cacheCreationTokens = cacheCreationTokens.addingClamped(other.cacheCreationTokens)
            reasoningTokens = reasoningTokens.addingClamped(other.reasoningTokens)
        }
    }

    struct Allowance: Encodable {
        let id: String
        let label: String
        let usedPercent: Double
        let resetsAtUnix: Int64?
        let detail: String?

        enum CodingKeys: String, CodingKey {
            case id
            case label
            case usedPercent = "used_percent"
            case resetsAtUnix = "resets_at_unix"
            case detail
        }
    }

    struct Snapshot: Encodable {
        let period: Dashboard.Period
        let tokenUsage: Tokens
        let allowanceWindows: [Allowance]
        let models: [String]
        let source: String
        let updatedAtUnix: Int64

        enum CodingKeys: String, CodingKey {
            case period
            case tokenUsage = "token_usage"
            case allowanceWindows = "allowance_windows"
            case models
            case source
            case updatedAtUnix = "updated_at_unix"
        }
    }

    struct ScanResult {
        var tokens = Tokens()
        var allowances: [Allowance] = []
        var models: [String] = []
        var foundData = false
    }

    static func encodeSnapshot(
        period: Dashboard.Period,
        usage: Tokens,
        allowances: [Allowance],
        models: [String],
        source: String
    ) throws -> Data {
        try JSONEncoder().encode(Snapshot(
            period: period,
            tokenUsage: usage,
            allowanceWindows: allowances,
            models: models.sorted(),
            source: source,
            updatedAtUnix: Int64(Date.now.timeIntervalSince1970)
        ))
    }

    static func scanCodex(period: Dashboard.Period) throws -> ScanResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appending(path: ".codex/sessions", directoryHint: .isDirectory),
            home.appending(path: ".codex/archived_sessions", directoryHint: .isDirectory),
        ]
        var result = ScanResult()
        var modelNames = Set<String>()
        var newestLimits: (timestamp: Int64, values: [Allowance])?

        for file in recentJSONLFiles(roots: roots, period: period) {
            var lastCumulative: Tokens?
            try forEachJSONObject(in: file) { object in
                guard let timestamp = timestamp(in: object), period.contains(timestamp) else {
                    return
                }
                guard let payload = object["payload"] as? [String: Any] else { return }
                if let model = payload["model"] as? String, !model.isEmpty {
                    modelNames.insert(model)
                }
                guard payload["type"] as? String == "token_count" else { return }
                if let info = payload["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any] {
                    lastCumulative = codexTokens(total)
                    result.foundData = true
                }
                if let limits = codexAllowances(payload["rate_limits"]),
                   newestLimits == nil || timestamp >= newestLimits!.timestamp {
                    newestLimits = (timestamp, limits)
                }
            }
            if let lastCumulative { result.tokens.add(lastCumulative) }
        }
        result.models = Array(modelNames)
        result.allowances = newestLimits?.values ?? []
        return result
    }

    static func scanClaude(period: Dashboard.Period) throws -> ScanResult {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
        var result = ScanResult()
        var modelNames = Set<String>()
        for file in recentJSONLFiles(roots: [root], period: period) {
            try forEachJSONObject(in: file) { object in
                guard object["type"] as? String == "assistant",
                      let timestamp = timestamp(in: object),
                      period.contains(timestamp),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { return }
                let tokens = Tokens(
                    inputTokens: unsigned(usage["input_tokens"]),
                    outputTokens: unsigned(usage["output_tokens"]),
                    cacheReadTokens: unsigned(usage["cache_read_input_tokens"]),
                    cacheCreationTokens: unsigned(usage["cache_creation_input_tokens"])
                )
                result.tokens.add(tokens)
                result.foundData = true
                if let model = message["model"] as? String, !model.isEmpty {
                    modelNames.insert(model)
                }
            }
        }
        result.models = Array(modelNames)
        return result
    }

    static func recentJSONLFiles(
        roots: [URL],
        period: Dashboard.Period
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        return roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { entry -> URL? in
                guard let url = entry as? URL, url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true
                else { return nil }
                let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                return modified >= TimeInterval(period.startUnix) ? url : nil
            }
        }
    }

    static func forEachJSONObject(
        in file: URL,
        body: ([String: Any]) -> Void
    ) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)),
                  let object = value as? [String: Any]
            else { continue }
            body(object)
        }
    }

    static func timestamp(in object: [String: Any]) -> Int64? {
        if let number = object["timestamp"] as? NSNumber {
            return number.int64Value
        }
        guard let value = object["timestamp"] as? String else { return nil }
        return iso8601Date(from: value).map {
            Int64($0.timeIntervalSince1970)
        }
    }

    static func codexTokens(_ usage: [String: Any]) -> Tokens {
        let cached = unsigned(usage["cached_input_tokens"])
        let reasoning = unsigned(usage["reasoning_output_tokens"])
        return Tokens(
            inputTokens: unsigned(usage["input_tokens"]).subtractingClamped(cached),
            outputTokens: unsigned(usage["output_tokens"]).subtractingClamped(reasoning),
            cacheReadTokens: cached,
            reasoningTokens: reasoning
        )
    }

    static func codexAllowances(_ value: Any?) -> [Allowance]? {
        guard let limits = value as? [String: Any] else { return nil }
        return [
            allowance(id: "primary", window: limits["primary"]),
            allowance(id: "secondary", window: limits["secondary"]),
        ].compactMap { $0 }
    }

    static func allowance(id: String, window value: Any?) -> Allowance? {
        guard let window = value as? [String: Any],
              let used = double(window["used_percent"] ?? window["usedPercent"])
        else { return nil }
        let duration = signed(window["window_minutes"] ?? window["windowDurationMins"])
        return Allowance(
            id: id,
            label: windowLabel(durationMinutes: duration, fallback: id.capitalized),
            usedPercent: min(max(used, 0), 100),
            resetsAtUnix: signed(window["resets_at"] ?? window["resetsAt"]),
            detail: nil
        )
    }

    static func readClaudeStatusAllowances() -> [Allowance] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Costbar/claude-status.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any]
        else { return [] }
        return [
            claudeAllowance(id: "five-hour", label: "5 hour", value: limits["five_hour"]),
            claudeAllowance(id: "seven-day", label: "7 day", value: limits["seven_day"]),
        ].compactMap { $0 }
    }

    static func claudeAllowance(
        id: String,
        label: String,
        value: Any?
    ) -> Allowance? {
        guard let window = value as? [String: Any],
              let used = double(window["used_percentage"])
        else { return nil }
        return Allowance(
            id: id,
            label: label,
            usedPercent: min(max(used, 0), 100),
            resetsAtUnix: signed(window["resets_at"]),
            detail: nil
        )
    }

    static func windowLabel(durationMinutes: Int64?, fallback: String) -> String {
        switch durationMinutes {
        case 300: "5 hour"
        case 10_080: "7 day"
        case let minutes?: "\(minutes) min"
        case nil: fallback
        }
    }

    static func unsigned(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else { return 0 }
        return number.int64Value > 0 ? UInt64(number.int64Value) : 0
    }

    static func signed(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

private enum CodexRateLimitReader {
    static func read() -> [LocalAIUsageCollector.Allowance]? {
        guard let executable = executablePath() else { return nil }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let received = LockedData()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            received.append(chunk)
        }

        do {
            try process.run()
            let messages = [
                #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"costbar","title":"Costbar","version":"0.1.0"}}}"#,
                #"{"method":"initialized"}"#,
                #"{"id":2,"method":"account/rateLimits/read"}"#,
            ].joined(separator: "\n") + "\n"
            input.fileHandleForWriting.write(Data(messages.utf8))
            try? input.fileHandleForWriting.close()

            let deadline = Date.now.addingTimeInterval(4)
            while process.isRunning, Date.now < deadline {
                let hasResponse = received.hasJSONRPCResponse(id: 2)
                if hasResponse { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            return nil
        }

        let data = received.value
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 2,
                  let result = object["result"] as? [String: Any],
                  let limits = result["rateLimits"] as? [String: Any]
            else { continue }
            return LocalAIUsageCollector.codexAllowances(limits)
        }
        return nil
    }

    private static func executablePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private extension Dashboard.Period {
    func contains(_ timestamp: Int64) -> Bool {
        timestamp >= startUnix && timestamp < endExclusiveUnix
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }

    func subtractingClamped(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

private func iso8601Date(from value: String) -> Date? {
    let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    if let date = try? Date(value, strategy: fractional) { return date }
    return try? Date(value, strategy: plain)
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func hasJSONRPCResponse(id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.split(separator: 0x0A).contains { line in
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line)
            ) as? [String: Any] else { return false }
            return (object["id"] as? NSNumber)?.intValue == id
        }
    }
}
