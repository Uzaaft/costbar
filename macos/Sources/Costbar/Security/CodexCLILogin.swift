import Darwin
import Foundation

/// Runs `codex login`, optionally against an isolated CODEX_HOME.
enum CodexCLILogin {
    static func run(
        homeURL: URL?,
        timeout: TimeInterval,
        environment: [String: String]
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            guard let executable = resolveBinary(environment: environment, fileManager: fileManager) else {
                throw CodexAccountManagerError.codexCLINotFound
            }
            var processEnvironment = environment
            processEnvironment["PATH"] = effectivePATH(environment: environment, fileManager: fileManager)
            if let homeURL {
                processEnvironment["CODEX_HOME"] = homeURL.path
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["login"]
            process.environment = processEnvironment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                throw CodexAccountManagerError.loginFailed(-1, error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(max(1, timeout))
            while process.isRunning, Date() < deadline {
                Darwin.usleep(100_000)
            }
            if process.isRunning {
                process.terminate()
                throw CodexAccountManagerError.loginTimedOut
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            // Lossy on purpose: this is CLI diagnostics for a failure message,
            // and truncating mid-character must not discard the whole reason.
            // swiftlint:disable:next optional_data_string_conversion
            let captured = String(decoding: data.prefix(4_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw CodexAccountManagerError.loginFailed(process.terminationStatus, captured)
            }
        }.value
    }

    private static func resolveBinary(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        if let override = environment["COSTBAR_CODEX_PATH"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for directory in effectivePATH(environment: environment, fileManager: fileManager)
            .split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func effectivePATH(
        environment: [String: String],
        fileManager: FileManager
    ) -> String {
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path,
        ])
        var seen: Set<String> = []
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}
