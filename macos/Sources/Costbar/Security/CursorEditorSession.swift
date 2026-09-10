import Foundation
import SQLite3

/// Reads the signed-in Cursor editor cookie. Costbar never writes the database.
enum CursorEditorSession {
    static func cookieHeader(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        let path = home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let db = open(path) else { return nil }
        defer { sqlite3_close(db) }
        let token = string(db, key: "cursorAuth/accessToken")
        let account = string(db, key: "cursorAuth/stripeMembershipAuthId")
        guard let token, !token.isEmpty else { return nil }
        if let account, !account.isEmpty {
            return "WorkosCursorSessionToken=\(account)::\(token)"
        }
        return "WorkosCursorSessionToken=\(token)"
    }

    private static func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
            return db
        }
        sqlite3_close(db)
        db = nil
        let uri = "file:\(path)?immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            return db
        }
        sqlite3_close(db)
        return nil
    }

    private static func string(_ db: OpaquePointer, key: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: bytes)
    }
}
