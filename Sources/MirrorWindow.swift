import SwiftUI
import AppKit
import AVFoundation
import Combine

private let kCorner: CGFloat = 18      // screen + outer-frame corner
private let kBar: CGFloat = 34         // title-bar height (taller → easier to grab + drag)
private let kInset: CGFloat = 6        // frame margin around the screen (sides)
private let kNav: CGFloat = 38         // bottom navigation-key bar height

/// Android `KeyEvent` codes for the on-screen navigation keys.
enum AndroidKey {
    static let back = 4        // KEYCODE_BACK
    static let home = 3        // KEYCODE_HOME
    static let appSwitch = 187 // KEYCODE_APP_SWITCH (recents)
}

// MARK: - Chrome bars (SwiftUI: just the buttons; bg + geometry are AppKit/CoreAnimation)

/// Published chrome progress (0 hidden → 1 shown). Set by the AppKit container; the
/// SwiftUI bars animate themselves off it.
final class ChromeProgress: ObservableObject {
    @Published var p: CGFloat = 0
}

/// The title bar (top) and Android nav keys (bottom). Transparent elsewhere so the
/// frame layer and the video (behind/around it) show through.
struct MirrorChromeView: View {
    @ObservedObject var progress: ChromeProgress
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onKey: (Int) -> Void

    var body: some View {
        let p = progress.p
        VStack(spacing: 0) {
            titleBar.opacity(Double(p)).offset(y: -(1 - p) * 6)
            Spacer(minLength: 0)
            navBar.opacity(Double(p)).offset(y: (1 - p) * 6)
        }
        .animation(.easeInOut(duration: 0.24), value: progress.p)
    }

    private var titleBar: some View {
        ZStack(alignment: .leading) {
            WindowDragHandle()      // drag the window from any empty title-bar spot
            HStack {
                TrafficLights(onClose: onClose, onMinimize: onMinimize, onZoom: onZoom)
                Spacer()
            }
            .padding(.leading, 12)
        }
        .frame(height: kBar)
    }

    private var navBar: some View {
        HStack(spacing: 40) {
            NavKey(symbol: "chevron.left") { onKey(AndroidKey.back) }    // back
            NavKey(symbol: "circle") { onKey(AndroidKey.home) }          // home
            NavKey(symbol: "square") { onKey(AndroidKey.appSwitch) }     // recents
        }
        .frame(height: kNav)
    }
}

// MARK: - AppKit container (fixed window; grows a frame LAYER around a fixed screen)

/// The window's content view. The OS window is FIXED at the grown size and never resizes
/// (so the picture can't shake). The visible "window" is a rounded `frameLayer` that
/// grows outward from the screen's edges while the screen layer stays put. The shadow is
/// the REAL native window shadow: we drive the grow with a per-frame timer and call
/// `invalidateShadow()` each tick so the system re-derives its own shadow as the frame
/// grows — no hand-drawn shadow.
final class MirrorContainerView: NSView {
    let video: MirrorInputView
    private let chromeHost: NSView
    private let chromeProgress: ChromeProgress
    private let frameLayer = CALayer()

    /// No-chrome screen size (the picture's fixed pixel size).
    private(set) var screenSize: CGSize = .zero
    private(set) var progress: CGFloat = 0
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var animTimer: Timer?

    init(video: MirrorInputView, chromeHost: NSView, progress: ChromeProgress) {
        self.video = video
        self.chromeHost = chromeHost
        self.chromeProgress = progress
        super.init(frame: .zero)
        wantsLayer = true
        frameLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        frameLayer.cornerRadius = kCorner
        frameLayer.cornerCurve = .continuous
        layer?.addSublayer(frameLayer)         // behind the subviews
        addSubview(chromeHost)                 // bars (in the margins)
        addSubview(video)                      // the picture (centre), on top
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Set the fixed screen size and lay everything out for the current progress.
    func configure(screenSize: CGSize) {
        self.screenSize = screenSize
        layoutContent()
        applyFrameLayer()
        window?.invalidateShadow()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }

    /// Grow/shrink the frame layer with a per-frame timer; the picture stays fixed and we
    /// re-derive the native window shadow each tick. The window never moves, so there is
    /// nothing to fall out of sync with.
    func setProgress(_ p: CGFloat, animated: Bool) {
        animTimer?.invalidate(); animTimer = nil
        chromeProgress.p = p   // SwiftUI bars animate off this (its own .animation)
        guard animated else {
            progress = p; applyFrameLayer(); window?.invalidateShadow(); return
        }
        let from = progress
        let start = Date()
        let duration = 0.24
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let raw = min(1.0, Date().timeIntervalSince(start) / duration)
            let e = raw * raw * raw * (raw * (raw * 6 - 15) + 10) // smootherstep
            self.progress = from + (p - from) * e
            self.applyFrameLayer()
            self.window?.invalidateShadow()
            if raw >= 1 {
                self.progress = p
                self.applyFrameLayer()
                self.window?.invalidateShadow()
                t.invalidate(); self.animTimer = nil
            }
        }
    }

    override func layout() {
        super.layout()
        layoutContent()
        applyFrameLayer()
    }

    private func layoutContent() {
        chromeHost.frame = bounds
        withoutImplicitAnimation {
            if screenSize.width > 1 {
                video.frame = NSRect(x: kInset, y: kNav, width: screenSize.width, height: screenSize.height)
            } else {
                video.frame = bounds
            }
        }
    }

    private func applyFrameLayer() {
        withoutImplicitAnimation { frameLayer.frame = frameRect(for: progress) }
    }

    /// Frame layer's rect at progress `p`: the screen rect at p=0 (only the floating
    /// screen shows) growing to the whole window at p=1 (full chrome margins).
    private func frameRect(for p: CGFloat) -> NSRect {
        guard screenSize.width > 1 else { return bounds }
        return NSRect(
            x: kInset * (1 - p),
            y: kNav * (1 - p),
            width: screenSize.width + 2 * kInset * p,
            height: screenSize.height + (kBar + kNav) * p
        )
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }
}

// MARK: - macOS window controls

/// macOS-style window controls (close / minimize / zoom) for a borderless window.
/// Glyphs appear while the cluster is hovered, like the system.
struct TrafficLights: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1.0, green: 0.37, blue: 0.34), "xmark", onClose)
            light(Color(red: 0.99, green: 0.74, blue: 0.18), "minus", onMinimize)
            light(Color(red: 0.16, green: 0.78, blue: 0.25), "plus", onZoom)
        }
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
    }
}

/// One Android navigation key (back / home / recents) for the bottom bar.
struct NavKey: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 40, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(hovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Transparent AppKit view that starts a window drag on mouse-down.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
    }
}

// MARK: - Video surface (AppKit)

/// NSView that draws the display layer (rounded) and maps mouse events into the phone's
/// reference frame. Positioned (fixed) by `MirrorContainerView`.
final class MirrorInputView: NSView {
    private(set) var hostedLayer: AVSampleBufferDisplayLayer
    private let maskLayer = CAShapeLayer()
    var videoSize: CGSize = .zero
    var onMouse: ((UInt8, UInt8, Int, Int, Int, Int) -> Void)?
    var onScroll: ((Int, Int, Int, Int, Int) -> Void)?

    init(_ l: AVSampleBufferDisplayLayer) {
        hostedLayer = l
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        // Round the video itself: AVSampleBufferDisplayLayer composites video on the GPU
        // and ignores the parent's cornerRadius mask, so rounding it directly + a shape
        // mask on the root are what actually clip the picture to rounded corners.
        Self.round(l)
        root.addSublayer(l)
        root.mask = maskLayer
        layer = root
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private static func round(_ l: CALayer) {
        l.cornerRadius = kCorner
        l.cornerCurve = .continuous
        l.masksToBounds = true
    }

    func setLayer(_ l: AVSampleBufferDisplayLayer) {
        hostedLayer.removeFromSuperlayer()
        Self.round(l)
        hostedLayer = l
        layer?.addSublayer(l)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hostedLayer.frame = bounds
        maskLayer.frame = bounds
        maskLayer.path = CGPath(roundedRect: bounds, cornerWidth: kCorner, cornerHeight: kCorner, transform: nil)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Map a point (view coords, bottom-left origin) into the aspect-fit video rect,
    /// then to phone pixel coords (top-left origin). nil if on the letterbox.
    private func map(_ p: CGPoint) -> (Int, Int, Int, Int)? {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let vidAR = videoSize.width / videoSize.height
        let viewAR = bounds.width / bounds.height
        let rect: CGRect
        if vidAR > viewAR {
            let h = bounds.width / vidAR
            rect = CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * vidAR
            rect = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
        guard rect.contains(p) else { return nil }
        let nx = (p.x - rect.minX) / rect.width
        let ny = (p.y - rect.minY) / rect.height
        let vx = Int((nx * videoSize.width).rounded())
        let vy = Int(((1 - ny) * videoSize.height).rounded()) // flip y to top-left origin
        return (vx, vy, Int(videoSize.width), Int(videoSize.height))
    }

    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func send(_ action: UInt8, _ button: UInt8, _ e: NSEvent) {
        guard let m = map(loc(e)) else { return }
        onMouse?(action, button, m.0, m.1, m.2, m.3)
    }

    override func mouseDown(with e: NSEvent) { send(0, 1, e) }
    override func mouseDragged(with e: NSEvent) { send(2, 1, e) }
    override func mouseUp(with e: NSEvent) { send(1, 1, e) }
    override func rightMouseDown(with e: NSEvent) { send(0, 2, e) }
    override func rightMouseDragged(with e: NSEvent) { send(2, 2, e) }
    override func rightMouseUp(with e: NSEvent) { send(1, 2, e) }

    override func scrollWheel(with e: NSEvent) {
        guard e.scrollingDeltaY != 0, let m = map(loc(e)) else { return }
        onScroll?(e.scrollingDeltaY > 0 ? 1 : -1, m.0, m.1, m.2, m.3)
    }
}

/// Borderless window that can still become key (so mouse/keyboard reach the content).
final class MirrorPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Window manager

/// Owns the mirror window. Showing it starts mirroring; closing it stops mirroring.
final class MirrorWindowManager: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: NSWindow?
    private var container: MirrorContainerView?
    private var video: MirrorInputView?
    private let chromeProgress = ChromeProgress()
    private var bag = Set<AnyCancellable>()
    private var baseScreenH: CGFloat = 640   // screen height in points; window = screen + chrome

    init(model: AppModel) { self.model = model }

    func show(connect: Bool = true) {
        NSApp.setActivationPolicy(.regular)  // Dock icon + Cmd-Tab while the mirror is up
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // The window is fixed at the GROWN size (screen + chrome margins). It never
        // resizes; the chrome animates within it (native shadow follows via per-frame
        // invalidateShadow).
        let w = MirrorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: baseScreenH + kBar + kNav),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        let placeholder = model.displayLayer ?? AVSampleBufferDisplayLayer()
        let video = MirrorInputView(placeholder)
        video.videoSize = model.videoSize
        video.onMouse = { [weak self] a, b, x, y, w, h in self?.model.mouse(action: a, button: b, x: x, y: y, w: w, h: h) }
        video.onScroll = { [weak self] v, x, y, w, h in self?.model.scroll(v: v, x: x, y: y, w: w, h: h) }

        let chromeHost = NSHostingView(rootView: MirrorChromeView(
            progress: chromeProgress,
            onClose: { [weak self] in self?.model.closeMirror() },
            onMinimize: { [weak self] in self?.window?.miniaturize(nil) },
            onZoom: { [weak self] in self?.window?.zoom(nil) },
            onKey: { [weak self] code in self?.model.key(code) }
        ))

        let container = MirrorContainerView(video: video, chromeHost: chromeHost, progress: chromeProgress)
        container.onHover = { [weak self] hovering in self?.container?.setProgress(hovering ? 1 : 0, animated: true) }

        w.contentView = container
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true    // real native shadow; we invalidate it per-frame as the frame grows
        w.isMovableByWindowBackground = false
        w.minSize = NSSize(width: 240, height: 420)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        window = w
        self.container = container
        self.video = video

        model.$displayLayer
            .receive(on: RunLoop.main)
            .sink { [weak self] layer in
                guard let self, let layer, let v = self.video, v.hostedLayer !== layer else { return }
                v.setLayer(layer)
            }.store(in: &bag)
        model.$videoSize
            .receive(on: RunLoop.main)
            .sink { [weak self] sz in self?.applyAspect(sz) }
            .store(in: &bag)

        applyAspect(model.videoSize)
        if connect { model.startMirror() }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("mirror window number: \(w.windowNumber)")
    }

    func close() { window?.close() }

    /// Fit the window (fixed size) to the phone's aspect ratio: screen = baseScreenH tall,
    /// window = screen + chrome margins. Repositions the picture + frame layer.
    private func applyAspect(_ sz: CGSize) {
        guard let w = window, let container = container, sz.width > 0, sz.height > 0 else { return }
        let screenH = baseScreenH
        let screenW = (screenH * sz.width / sz.height).rounded()
        video?.videoSize = sz
        let newSize = NSSize(width: screenW + 2 * kInset, height: screenH + kBar + kNav)
        if abs(w.frame.width - newSize.width) > 0.5 || abs(w.frame.height - newSize.height) > 0.5 {
            w.setContentSize(newSize)
        }
        container.configure(screenSize: CGSize(width: screenW, height: screenH))
    }

    /// Test hook (=2): jump to the hovered/grown state.
    func testForceHover() { container?.setProgress(1, animated: false) }

    /// Test hook (=5): put the window on the active Space at a known spot, leave at rest.
    func testPosition() {
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window?.setFrameOrigin(NSPoint(x: 120, y: 200))
    }

    /// Test hook (=3): toggle the hover animation forever for a screen recording.
    private var testTimer: Timer?
    func testAutoToggle() {
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window?.setFrameOrigin(NSPoint(x: 120, y: 200))
        var on = false
        testTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            on.toggle()
            self?.container?.setProgress(on ? 1 : 0, animated: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        testTimer?.invalidate(); testTimer = nil
        bag.removeAll()
        model.stopMirror()
        window = nil; container = nil; video = nil
        NSApp.setActivationPolicy(.accessory) // back to menu-bar agent
    }
}
