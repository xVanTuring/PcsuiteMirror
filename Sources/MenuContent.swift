import SwiftUI
import AppKit

/// Standard menu-bar dropdown. Every view here must be a native menu item
/// (Button / Toggle / Menu / Divider / Text) — SwiftUI renders them into an NSMenu.
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusText)   // disabled status label

        Divider()
        connectionItems

        Divider()
        Button(L("Settings…")) { PreferencesWindowController.shared.show(model: model) }
            .keyboardShortcut(",")
        if model.lastDevice != nil && !model.isConnected {
            Button(L("Forget device")) { model.forgetDevice() }
        }

        Divider()
        Button(L("Quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var connectionItems: some View {
        if model.isConnected {
            if let info = model.deviceInfo {
                Text("\(info.name) · \(L("Storage")) \(info.storageSummary)")
            }
            Button(model.mirroring ? L("Stop mirroring") : L("Start mirroring")) {
                if model.mirroring { model.closeMirror() } else { model.openMirror() }
            }
            if let code = model.lastCode {
                Text("\(L("Last code")): \(code)")
            }
            Button(L("Disconnect")) { model.disconnect() }
        } else if model.isBusy {
            Button(L("Cancel")) { model.cancelConnect() }
        } else {
            Button(L("Connect via USB")) { model.connectUSB() }
            Button(L("Pair via QR…")) { model.pairQR() }
            Button(L("Connect over Wi-Fi…")) {
                if let ip = promptForIP(default: model.lanIP) {
                    let t = ip.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { model.lanIP = t; model.connectLAN() }
                }
            }
            if let last = model.lastDevice {
                Button("\(L("Reconnect")) \(last.displayName)") { model.reconnectLast() }
            }
        }
    }
}
