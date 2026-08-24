import Foundation

enum ClaudeStatusLineBridge {
    private static let backupName = "claude-statusline-backup.json"
    private static let helperName = "claude-statusline"
    private static let previousCommandName = "claude-statusline-previous-command"

    static var isInstalled: Bool {
        isInstalled(settingsURL: defaultSettingsURL, supportURL: defaultSupportURL)
    }

    static func install() throws {
        try install(settingsURL: defaultSettingsURL, supportURL: defaultSupportURL)
    }

    static func restore() throws {
        try restore(settingsURL: defaultSettingsURL, supportURL: defaultSupportURL)
    }
}

extension ClaudeStatusLineBridge {
    static func install(settingsURL: URL, supportURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(at: supportURL, withIntermediateDirectories: true)

        var settings = try readObject(at: settingsURL) ?? [:]
        let helperURL = supportURL.appending(path: helperName)
        let existing = settings["statusLine"] as? [String: Any]
        let existingCommand = existing?["command"] as? String
        if existingCommand?.contains(helperURL.path) == true { return }

        let backupURL = supportURL.appending(path: backupName)
        if !manager.fileExists(atPath: backupURL.path) {
            var backup: [String: Any] = ["had_status_line": existing != nil]
            if let existing { backup["status_line"] = existing }
            try writeJSONObject(backup, to: backupURL)
        }

        let previousURL = supportURL.appending(path: previousCommandName)
        try Data((existingCommand ?? "").utf8).write(to: previousURL, options: .atomic)
        try Data(helperScript.utf8).write(to: helperURL, options: .atomic)
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: helperURL.path
        )

        var statusLine = existing ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = shellQuoted(helperURL.path)
        settings["statusLine"] = statusLine
        try writeJSONObject(settings, to: settingsURL)
    }

    static func restore(settingsURL: URL, supportURL: URL) throws {
        let backupURL = supportURL.appending(path: backupName)
        guard let backup = try readObject(at: backupURL) else { return }
        var settings = try readObject(at: settingsURL) ?? [:]
        if backup["had_status_line"] as? Bool == true,
           let previous = backup["status_line"] as? [String: Any] {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeJSONObject(settings, to: settingsURL)
        try? FileManager.default.removeItem(at: backupURL)
    }

    static func isInstalled(settingsURL: URL, supportURL: URL) -> Bool {
        let helperURL = supportURL.appending(path: helperName)
        guard let settings = try? readObject(at: settingsURL),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else { return false }
        return command.contains(helperURL.path)
    }
}

private extension ClaudeStatusLineBridge {
    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")
    }

    static var defaultSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Costbar", directoryHint: .isDirectory)
    }

    static func readObject(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = value as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let helperScript = #"""
    #!/bin/sh
    set -u

    support_dir="${HOME}/Library/Application Support/Costbar"
    snapshot="${support_dir}/claude-status.json"
    previous="${support_dir}/claude-statusline-previous-command"
    temporary="${snapshot}.tmp.$$"
    input=$(/bin/cat)
    umask 077
    /usr/bin/printf '%s\n' "$input" > "$temporary"
    /bin/mv -f "$temporary" "$snapshot"

    if [ -s "$previous" ]; then
        /usr/bin/printf '%s\n' "$input" | /bin/sh -c "$(/bin/cat "$previous")"
        exit $?
    fi

    five=$(/usr/bin/plutil -extract rate_limits.five_hour.used_percentage raw -o - "$snapshot" 2>/dev/null || true)
    week=$(/usr/bin/plutil -extract rate_limits.seven_day.used_percentage raw -o - "$snapshot" 2>/dev/null || true)
    if [ -n "$five" ] || [ -n "$week" ]; then
        /usr/bin/printf 'Claude%s%s\n' "${five:+ · 5h ${five}%}" "${week:+ · 7d ${week}%}"
    else
        /usr/bin/printf 'Claude · Costbar sync\n'
    fi
    """#
}
