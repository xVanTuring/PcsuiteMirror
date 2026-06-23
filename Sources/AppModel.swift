import Foundation
import AVFoundation
import SwiftUI

/// Observable app state + intent surface for the UI. All mutations happen on the
/// main thread (SwiftUI actions, plus controller callbacks which hop to main).
final class AppModel: ObservableObject {
    // Connection / mirroring state.
    @Published private(set) var state: ConnState = .disconnected
    @Published private(set) var mirroring = false
    @Published private(set) var displayLayer: AVSampleBufferDisplayLayer?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var frameCount = 0
    @Published private(set) var lastCode: String?

    // Persisted preferences (default ON).
    @Published var autoReconnect: Bool { didSet { Store.autoReconnect = autoReconnect } }
    @Published var clipboardEnabled: Bool { didSet { Store.clipboardEnabled = clipboardEnabled } }
    @Published var clipboardDirection: ClipboardDirection { didSet { Store.clipboardDirection = clipboardDirection } }
    @Published var verifyEnabled: Bool { didSet { Store.verifyEnabled = verifyEnabled } }
    @Published var lanIP: String { didSet { Store.lanIP = lanIP } }
    @Published private(set) var resolution: MirrorResolution
    @Published private(set) var lastDevice: DeviceRef?

    private let controller = SessionController()
    private lazy var mirror = MirrorWindowManager(model: self)

    init() {
        autoReconnect = Store.autoReconnect
        clipboardEnabled = Store.clipboardEnabled
        clipboardDirection = Store.clipboardDirection
        verifyEnabled = Store.verifyEnabled
        lanIP = Store.lanIP
        resolution = Store.resolution
        lastDevice = Store.lastDevice
        wire()
        if autoReconnect, let dev = lastDevice {
            controller.connect(dev, features: features, reconnect: true)
        }
        if ["1", "2", "3", "4", "5"].contains(ProcessInfo.processInfo.environment["PCSUITE_MIRROR_TEST"]) {
            DispatchQueue.main.async { [weak self] in self?.openMirrorTest() }
        }
    }

    // MARK: - Derived state for the UI

    var isConnected: Bool { if case .connected = state { return true }; return false }
    var isBusy: Bool {
        switch state { case .connecting, .reconnecting: return true; default: return false }
    }
    var busyDevice: DeviceRef? {
        switch state {
        case .connecting(let d), .reconnecting(let d): return d
        default: return nil
        }
    }
    var statusText: String {
        switch state {
        case .disconnected: return L("Disconnected")
        case .connecting(let d): return "\(L("Connecting…")) \(d.displayName)"
        case .reconnecting(let d): return "\(L("Reconnecting…")) \(d.displayName)"
        case .connected(let d): return "\(L("Connected")) · \(d.displayName)"
        case .failed(let m): return "\(L("Connection failed")): \(m)"
        }
    }
    var statusIcon: String {
        switch state {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .disconnected: return "circle.dashed"
        }
    }

    private var features: ConnectFeatures {
        ConnectFeatures(
            clipboard: clipboardEnabled,
            clipRecv: clipboardDirection.recv,
            clipSend: clipboardDirection.send,
            verify: verifyEnabled
        )
    }

    // MARK: - Intents

    func connectUSB() { controller.connect(DeviceRef(transport: .usb, ip: nil), features: features, reconnect: false) }

    func connectLAN() {
        let ip = lanIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        controller.connect(DeviceRef(transport: .lan, ip: ip), features: features, reconnect: false)
    }

    func reconnectLast() {
        guard let dev = lastDevice else { return }
        controller.connect(dev, features: features, reconnect: false)
    }

    func cancelConnect() { controller.cancel() }
    func disconnect() { closeMirror(); controller.disconnect() }
    func startMirror() { controller.startMirror(maxSize: resolution.maxSize) }
    func stopMirror() { controller.stopMirror() }
    func forgetDevice() { lastDevice = nil; Store.lastDevice = nil }

    /// Change mirror resolution; restarts the live stream if mirroring.
    func setResolution(_ r: MirrorResolution) {
        guard r != resolution else { return }
        resolution = r
        Store.resolution = r
        if mirroring { controller.restartMirror(maxSize: r.maxSize) }
    }

    /// Open the mirror window (which begins mirroring) / close it (which stops).
    func openMirror() { mirror.show() }
    func closeMirror() { mirror.close() }

    /// Open a blank mirror window with NO phone connection, for UI testing of the
    /// window/hover chrome. Faked video size drives the aspect layout; the surface shows
    /// its placeholder. Enabled via the PCSUITE_MIRROR_TEST=1 environment variable.
    func openMirrorTest() {
        let mode = ProcessInfo.processInfo.environment["PCSUITE_MIRROR_TEST"]
        if mode == "4" || mode == "5" {
            // Real mirror, once the auto-reconnect has settled. 4 = auto-toggle hover,
            // 5 = stay at rest (for inspecting the un-hovered corners).
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) { [weak self] in
                guard let self else { return }
                self.openMirror()
                if mode == "4" { self.mirror.testAutoToggle() } else { self.mirror.testPosition() }
            }
            return
        }
        videoSize = CGSize(width: 1080, height: 2400)
        mirror.show(connect: false)
        switch mode {
        case "2": mirror.testForceHover()
        case "3": mirror.testAutoToggle()
        default: break
        }
    }

    func mouse(action: UInt8, button: UInt8, x: Int, y: Int, w: Int, h: Int) {
        controller.sendMouse(action: action, button: button, x: x, y: y, w: w, h: h)
    }
    func scroll(v: Int, x: Int, y: Int, w: Int, h: Int) {
        controller.sendScroll(v: v, x: x, y: y, w: w, h: h)
    }
    /// Press an Android navigation key (see `AndroidKey`).
    func key(_ keycode: Int) { controller.sendKey(keycode) }

    // MARK: - Controller wiring (callbacks arrive on main)

    private func wire() {
        controller.onState = { [weak self] st in
            guard let self else { return }
            self.state = st
            if case .connected(let d) = st {
                self.lastDevice = d
                Store.lastDevice = d
            }
        }
        controller.onMirroring = { [weak self] on, layer in
            guard let self else { return }
            self.mirroring = on
            self.displayLayer = layer
            if !on { self.frameCount = 0; self.videoSize = .zero }
        }
        controller.onFrameCount = { [weak self] c in self?.frameCount = c }
        controller.onFormat = { [weak self] w, h in
            self?.videoSize = CGSize(width: w, height: h)
        }
        controller.onVerifyCode = { [weak self] code in
            self?.lastCode = code
            Pasteboard.copy(code)
            Notifier.postCode(code)
        }
    }
}
