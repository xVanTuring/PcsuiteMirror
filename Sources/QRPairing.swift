import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Render `string` as a QR code, offline, via CoreImage. `px` is the target pixel
/// size of the square output. Nearest-neighbour scaling keeps the modules crisp.
func qrImage(from string: String, px: CGFloat = 260) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let out = filter.outputImage, out.extent.width > 0 else { return nil }
    let scaled = out.transformed(by: CGAffineTransform(scaleX: px / out.extent.width,
                                                       y: px / out.extent.height))
    let rep = NSCIImageRep(ciImage: scaled)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

/// The QR pairing sheet: shows the code for the phone to scan and a Cancel button.
/// Closing the window (button or red X) cancels the pairing via the window delegate.
struct QRPairingView: View {
    let url: String
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(L("Scan to connect"))
                .font(.headline)
            Text(L("On the phone, open vivo PCSuite → 扫码连接电脑 and scan this code."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let img = qrImage(from: url) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .padding(10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text(url).font(.caption).textSelection(.enabled)
            }

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("Waiting for the phone…")).font(.caption).foregroundStyle(.secondary)
            }

            Button(L("Cancel")) { cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 340)
    }
}

/// Hosts `QRPairingView` in an on-demand window (a menu-bar agent has none by
/// default). Closing it by any means cancels the pairing; `close()` dismisses it
/// programmatically (pairing finished/failed) without firing the cancel callback.
final class QRPairingWindowController: NSObject, NSWindowDelegate {
    static let shared = QRPairingWindowController()
    private var window: NSWindow?
    private var onCancel: (() -> Void)?

    /// Show the QR for `url`. `onCancel` fires if the user dismisses the window
    /// before pairing completes.
    func show(url: String, onCancel: @escaping () -> Void) {
        close()                              // drop any prior window (no callback)
        self.onCancel = onCancel
        let host = NSHostingController(rootView: QRPairingView(url: url) { [weak self] in
            self?.window?.performClose(nil)  // → windowWillClose → onCancel
        })
        let w = NSWindow(contentViewController: host)
        w.title = L("Pair via QR")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dismiss because pairing finished or failed — no cancel callback fired.
    func close() {
        guard let w = window else { return }
        onCancel = nil
        window = nil
        w.delegate = nil
        w.close()
    }

    func windowWillClose(_ notification: Notification) {
        let cb = onCancel
        onCancel = nil
        window = nil
        cb?()   // user dismissed the window → cancel the pairing
    }
}
