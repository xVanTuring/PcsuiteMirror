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
        Toggle(L("Clipboard sync"), isOn: $model.clipboardEnabled)
        Menu(L("Clipboard direction")) {
            ForEach(ClipboardDirection.allCases) { d in
                Toggle(d.label, isOn: pick(model.clipboardDirection == d) { model.clipboardDirection = d })
            }
        }
        .disabled(!model.clipboardEnabled)
        Toggle(L("Verify-code relay"), isOn: $model.verifyEnabled)
        Toggle(L("Auto-reconnect last device"), isOn: $model.autoReconnect)
        Menu(L("Mirror resolution")) {
            ForEach(MirrorResolution.allCases) { r in
                Toggle(r.label, isOn: pick(model.resolution == r) { model.setResolution(r) })
            }
        }
        if model.lastDevice != nil && !model.isConnected {
            Button(L("Forget device")) { model.forgetDevice() }
        }

        Divider()
        Button(L("Quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var connectionItems: some View {
        if model.isConnected {
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

    /// A radio-style binding: reads `selected`; selecting it runs `choose` (turning a
    /// Toggle on picks that option; turning it off is ignored).
    private func pick(_ selected: Bool, _ choose: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { selected }, set: { if $0 { choose() } })
    }
}
