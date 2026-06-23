import SwiftUI
import AppKit

@main
struct PcsuiteMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Standard menu-bar dropdown (native NSMenu): the content is built from
        // Button / Toggle / Menu / Divider items.
        MenuBarExtra("vi-conn", systemImage: "iphone") {
            MenuContent(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        pcsuite_log_init()
        // Menu-bar-only app: no Dock icon, no main window at launch.
        NSApp.setActivationPolicy(.accessory)
        Notifier.requestAuth()
    }
}
