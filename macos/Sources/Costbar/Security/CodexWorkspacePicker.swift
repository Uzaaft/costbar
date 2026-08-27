import AppKit
import Foundation

/// Chooses which ChatGPT workspace a Codex login should use.
@MainActor
protocol CodexWorkspaceSelecting {
    /// Returns `nil` when the account has no workspaces to choose between,
    /// and throws ``CodexAccountManagerError/workspaceSelectionCancelled``
    /// when the person dismisses the choice.
    func selectWorkspace(
        from workspaces: [CodexWorkspace],
        email: String,
        selectedID: String?
    ) throws -> CodexWorkspace?
}

/// Asks with a modal alert. Tests substitute their own selector.
@MainActor
struct CodexWorkspaceAlertPicker: CodexWorkspaceSelecting {
    func selectWorkspace(
        from workspaces: [CodexWorkspace],
        email: String,
        selectedID: String?
    ) throws -> CodexWorkspace? {
        guard !workspaces.isEmpty else { return nil }
        guard workspaces.count > 1 else { return workspaces[0] }

        let sorted = workspaces.sorted { $0.displayName < $1.displayName }
        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 360, height: 26),
            pullsDown: false
        )
        for workspace in sorted {
            popup.addItem(withTitle: workspace.displayName)
            popup.lastItem?.representedObject = workspace.normalizedID
        }
        if let selectedID,
           let index = sorted.firstIndex(where: {
               $0.normalizedID == selectedID.lowercased()
           }) {
            popup.selectItem(at: index)
        }
        let alert = NSAlert()
        alert.messageText = "Choose Codex workspace"
        alert.informativeText = "\(email) belongs to more than one ChatGPT workspace."
        alert.alertStyle = .informational
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Workspace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let selected = popup.selectedItem?.representedObject as? String
        else { throw CodexAccountManagerError.workspaceSelectionCancelled }
        return sorted.first { $0.normalizedID == selected }
    }
}
