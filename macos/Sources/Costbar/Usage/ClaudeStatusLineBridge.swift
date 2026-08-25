import CostbarKit
import Foundation

enum ClaudeStatusLineBridgeError: LocalizedError {
    case core(costbar_status_t)

    var errorDescription: String? {
        switch self {
        case let .core(status):
            "The Zig core could not update the Claude status bridge (status \(status.rawValue))."
        }
    }
}

/// Thin UI-facing ABI wrapper. File I/O, JSON preservation, shell quoting, and
/// helper generation are implemented by `src/claude_status.zig`.
enum ClaudeStatusLineBridge {
    static var isInstalled: Bool {
        var installed: UInt8 = 0
        guard costbar_claude_status_bridge_is_installed(&installed) == COSTBAR_STATUS_OK else {
            return false
        }
        return installed != 0
    }

    static func install() throws {
        try check(costbar_claude_status_bridge_install())
    }

    static func restore() throws {
        try check(costbar_claude_status_bridge_restore())
    }

    private static func check(_ status: costbar_status_t) throws {
        guard status == COSTBAR_STATUS_OK else {
            throw ClaudeStatusLineBridgeError.core(status)
        }
    }
}
