import Foundation

enum UsageCache {
    static let groupID = "group.com.costbar.mobile"
    private static func fileURL() throws -> URL {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return directory.appendingPathComponent("usage.json")
    }

    static func read() -> UsageSnapshot? {
        guard let url = try? fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? UsageSnapshot.decode(data)
    }

    static func write(_ snapshot: UsageSnapshot?) throws {
        let url = try fileURL()
        if let snapshot {
            try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
