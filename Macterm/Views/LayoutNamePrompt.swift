import AppKit

/// Modal name prompt for "Save Workspace as Layout…". Mirrors the app's other
/// AppKit modals (QuitConfirmation, the quick-terminal alert) rather than a
/// SwiftUI sheet. Returns the trimmed name, or nil if cancelled / left empty.
enum LayoutNamePrompt {
    @MainActor
    static func run(defaultName: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Workspace as Layout"
        alert.informativeText = "Name this layout. It'll appear as a choice when you create a new context."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        field.placeholderString = "Layout name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
