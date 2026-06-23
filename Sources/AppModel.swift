import Foundation
import AVFoundation
import SwiftUI

/// Mirror-window link status, surfaced so the window can show a reconnect overlay
/// instead of a frozen picture when the connection drops mid-mirror.
enum MirrorLink: Equatable {
    case live          // streaming normally (or no mirror window open)
    case reconnecting  // the link dropped; an auto-reconnect is in progress
    case lost          // the link dropped and we are not (or no longer) reconnecting
}

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
    /// Phone-reported secure-screen token ("" / "clear" = none; "password",
    /// "safety", "lockScreen" = a privacy screen the phone handles itself).
    @Published private(set) var privacyState: String = ""
    /// Mirror-window link status (drives the reconnect overlay).
    @Published private(set) var mirrorLink: MirrorLink = .live

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

    // Auto-reconnect bookkeeping (main thread). A bumped `reconnectGen` cancels any
    // pending attempt; `reconnectDevice` is non-nil only while a sequence is active.
    private var reconnectGen = 0
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 6
    private var reconnectDevice: DeviceRef?

    /// Set by the mirror window: receives the phone's caret position (mirror
    /// pixel space) or nil when no field is focused. Plain closure (not
    /// @Published) so high-frequency caret updates don't churn SwiftUI.
    var imeCursorSink: ((CGPoint?) -> Void)?
    /// Set by the mirror window: whether the phone has a focused text field, so
    /// the keyboard only types in input mode.
    var imeActiveSink: ((Bool) -> Void)?

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

    func connectUSB() {
        cancelReconnect()
        controller.connect(DeviceRef(transport: .usb, ip: nil), features: features, reconnect: false)
    }

    func connectLAN() {
        let ip = lanIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        cancelReconnect()
        controller.connect(DeviceRef(transport: .lan, ip: ip), features: features, reconnect: false)
    }

    func reconnectLast() {
        guard let dev = lastDevice else { return }
        cancelReconnect()
        controller.connect(dev, features: features, reconnect: false)
    }

    func cancelConnect() { cancelReconnect(); controller.cancel() }
    func disconnect() { cancelReconnect(); closeMirror(); controller.disconnect() }

    // MARK: - Auto-reconnect on unexpected loss

    /// An established session dropped (USB unplug, Wi-Fi loss, phone ended it). If
    /// auto-reconnect is on, start a bounded backoff sequence to the same device;
    /// otherwise just surface the loss to an open mirror window.
    private func handleConnectionLost(_ device: DeviceRef) {
        guard autoReconnect else {
            mirrorLink = mirror.isShowing ? .lost : .live
            return
        }
        reconnectGen += 1
        reconnectAttempts = 0
        reconnectDevice = device
        mirrorLink = mirror.isShowing ? .reconnecting : .live
        scheduleReconnect(gen: reconnectGen, delay: 0.5)
    }

    /// Fire one reconnect attempt after `delay`, unless the sequence was cancelled
    /// or auto-reconnect was turned off in the meantime.
    private func scheduleReconnect(gen: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reconnectGen == gen, self.autoReconnect,
                  let dev = self.reconnectDevice else { return }
            self.reconnectAttempts += 1
            log("auto-reconnect attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts) → \(dev.displayName)")
            self.controller.connect(dev, features: self.features, reconnect: true)
        }
    }

    /// Stop any in-flight reconnect sequence and clear the overlay.
    private func cancelReconnect() {
        reconnectGen += 1
        reconnectAttempts = 0
        reconnectDevice = nil
        mirrorLink = .live
    }
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
    /// Type Unicode text into the phone's focused field.
    func typeText(_ s: String) { controller.sendText(s) }
    /// Backspace (delete one char before the cursor).
    func backspace() { controller.sendDeleteSurrounding(before: 1, after: 0) }

    /// Whether the phone is currently showing a secure/privacy screen.
    var privacyActive: Bool { !privacyState.isEmpty && privacyState != "clear" }

    // MARK: - Controller wiring (callbacks arrive on main)

    private func wire() {
        controller.onState = { [weak self] st in
            guard let self else { return }
            self.state = st
            switch st {
            case .connected(let d):
                self.lastDevice = d
                Store.lastDevice = d
                if self.reconnectDevice != nil { log("auto-reconnect succeeded") }
                self.cancelReconnect()
                // Resume mirroring if the window is still open after a recovered drop.
                if self.mirror.isShowing && !self.mirroring {
                    self.controller.startMirror(maxSize: self.resolution.maxSize)
                }
            case .failed:
                // A reconnect attempt failed: back off and retry, or give up.
                guard self.reconnectDevice != nil else { break }
                if self.autoReconnect, self.reconnectAttempts < self.maxReconnectAttempts {
                    let backoff = min(8.0, pow(2.0, Double(self.reconnectAttempts - 1)))
                    log("auto-reconnect retry in \(Int(backoff))s")
                    self.scheduleReconnect(gen: self.reconnectGen, delay: backoff)
                } else {
                    log("auto-reconnect gave up after \(self.reconnectAttempts) attempts")
                    let showing = self.mirror.isShowing
                    self.cancelReconnect()
                    self.mirrorLink = showing ? .lost : .live
                }
            default:
                break
            }
        }
        controller.onConnectionLost = { [weak self] device in
            self?.handleConnectionLost(device)
        }
        controller.onMirroring = { [weak self] on, layer in
            guard let self else { return }
            self.mirroring = on
            self.displayLayer = layer
            if !on { self.frameCount = 0; self.videoSize = .zero; self.privacyState = "" }
        }
        controller.onPrivacy = { [weak self] tok in self?.privacyState = tok }
        controller.onInputState = { [weak self] active, hasCaret, x, y in
            guard let self else { return }
            self.imeActiveSink?(active)        // gate the keyboard on input mode
            if !active {
                self.imeCursorSink?(nil)       // field gone → fall back to pointer
            } else if hasCaret {
                self.imeCursorSink?(CGPoint(x: x, y: y))
            }
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
