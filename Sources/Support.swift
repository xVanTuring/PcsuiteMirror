import Foundation
import AppKit
import UserNotifications

/// Log to stderr so a headless-launched binary still shows progress.
func log(_ s: String) {
    FileHandle.standardError.write(Data(("[mirror] " + s + "\n").utf8))
}

/// Localized string lookup (Localizable.strings, keyed by the English source text).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Extract a human-readable message from a thrown FFI error (a `RustString`).
func ffiMessage(_ error: Error) -> String {
    if let rs = error as? RustString { return rs.toString() }
    return "\(error)"
}

/// Modal prompt for a phone IP (a standard menu can't host a text field). Returns
/// the entered string, or nil if cancelled.
func promptForIP(default value: String) -> String? {
    let alert = NSAlert()
    alert.messageText = L("Connect over Wi-Fi")
    alert.informativeText = L("Enter the phone's IP address")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.stringValue = value
    field.placeholderString = "192.168.x.x"
    alert.accessoryView = field
    alert.addButton(withTitle: L("Connect"))
    alert.addButton(withTitle: L("Cancel"))
    NSApp.activate(ignoringOtherApps: true)
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

enum Pasteboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a local notification announcing a received SMS verify code.
    static func postCode(_ code: String) {
        let content = UNMutableNotificationContent()
        content.title = L("Verification code")
        content.body = String(format: L("%@ copied to clipboard"), code)
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
