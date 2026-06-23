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

// MARK: - Privacy overlay (shown over the picture when the phone hits a secure screen)

/// Drives the privacy overlay. `kind` is the phone's `privacyState` token.
final class PrivacyOverlayModel: ObservableObject {
    @Published var kind: String = ""   // "" / "clear" = hidden
    var active: Bool { !kind.isEmpty && kind != "clear" }
}

/// A frosted panel covering the picture while the phone shows a secure surface
/// (fingerprint / password / lock screen). The phone stops streaming then, so
/// this replaces the frozen / black picture with a clear instruction.
struct PrivacyOverlay: View {
    @ObservedObject var model: PrivacyOverlayModel

    private var symbol: String {
        switch model.kind {
        case "lockScreen": return "lock.fill"
        case "password": return "rectangle.and.pencil.and.ellipsis"
        default: return "lock.shield.fill"   // "safety" / fingerprint / secure
        }
    }

    var body: some View {
        ZStack {
            if model.active {
                RoundedRectangle(cornerRadius: kCorner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: kCorner, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                    )
                VStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(L("隐私操作请在手机端处理"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(model.active)   // block stray clicks only while secure
        .animation(.easeInOut(duration: 0.2), value: model.active)
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
    private let overlayHost: NSView
    private let chromeProgress: ChromeProgress
    private let frameLayer = CALayer()

    /// No-chrome screen size (the picture's fixed pixel size).
    private(set) var screenSize: CGSize = .zero
    private(set) var progress: CGFloat = 0
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var animTimer: Timer?

    init(video: MirrorInputView, chromeHost: NSView, overlayHost: NSView, progress: ChromeProgress) {
        self.video = video
        self.chromeHost = chromeHost
        self.overlayHost = overlayHost
        self.chromeProgress = progress
        super.init(frame: .zero)
        wantsLayer = true
        frameLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        frameLayer.cornerRadius = kCorner
        frameLayer.cornerCurve = .continuous
        layer?.addSublayer(frameLayer)         // behind the subviews
        addSubview(chromeHost)                 // bars (in the margins)
        addSubview(video)                      // the picture (centre)
        overlayHost.wantsLayer = true
        addSubview(overlayHost)                // privacy overlay, above the picture
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
            let videoRect = screenSize.width > 1
                ? NSRect(x: kInset, y: kNav, width: screenSize.width, height: screenSize.height)
                : bounds
            video.frame = videoRect
            overlayHost.frame = videoRect   // privacy panel covers the picture
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
    /// Committed Unicode text from the keyboard (IME `commitText` on the phone).
    var onText: ((String) -> Void)?
    /// A special key as an Android `KEYCODE_*` value (Enter/Tab/arrows/Esc).
    var onKeyCode: ((Int) -> Void)?
    /// Backspace (delete one char before the cursor).
    var onBackspace: (() -> Void)?
    /// Phone caret position (mirror pixel space, top-left origin) for the IME;
    /// nil falls back to the pointer location.
    var imeAnchorVideo: CGPoint?
    /// Whether the phone currently has a focused text field. The keyboard only
    /// types to the phone while this is true.
    var phoneInputActive = false

    // Touch-style pointer: the system arrow is hidden over the picture and replaced
    // by a soft translucent disc that follows the pointer and ripples on click.
    private let cursorLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var scrollAccum: CGFloat = 0   // trackpad scroll accumulator (points)
    private var lastPoint: CGPoint = .zero // last pointer location (anchors the IME)

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
        Self.styleCursor(cursorLayer)
        root.addSublayer(cursorLayer)
        root.mask = maskLayer
        layer = root
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: Touch-style cursor

    private static let cursorSize: CGFloat = 24

    /// A dual-tone disc that stays visible on any background: a dark outer ring
    /// (reads on light/white screens) wrapping a bright inner ring + faint fill
    /// (reads on dark screens), plus a soft shadow for separation.
    private static func styleCursor(_ c: CALayer) {
        let s = cursorSize
        c.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        c.backgroundColor = NSColor.clear.cgColor
        c.zPosition = 100          // stays above any later-added video layer
        c.isHidden = true

        let inner = CGRect(x: 2, y: 2, width: s - 4, height: s - 4)

        let fill = CALayer()
        fill.frame = inner
        fill.cornerRadius = inner.width / 2
        fill.backgroundColor = NSColor(white: 0.5, alpha: 0.22).cgColor
        c.addSublayer(fill)

        let dark = CALayer()           // dark outer ring → visible on light bg
        dark.frame = c.bounds
        dark.cornerRadius = s / 2
        dark.borderColor = NSColor.black.withAlphaComponent(0.55).cgColor
        dark.borderWidth = 3
        dark.shadowColor = NSColor.black.cgColor
        dark.shadowOpacity = 0.35
        dark.shadowRadius = 3
        dark.shadowOffset = .zero
        c.addSublayer(dark)

        let light = CALayer()          // bright inner ring → visible on dark bg
        light.frame = inner
        light.cornerRadius = inner.width / 2
        light.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        light.borderWidth = 2
        c.addSublayer(light)
    }

    /// A fully transparent cursor so only our drawn disc shows over the picture.
    private static let blankCursor: NSCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func resetCursorRects() { addCursorRect(bounds, cursor: Self.blankCursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with e: NSEvent) { cursorLayer.isHidden = false; moveCursor(e) }
    override func mouseExited(with e: NSEvent) { cursorLayer.isHidden = true }
    override func mouseMoved(with e: NSEvent) { moveCursor(e) }

    private func moveCursor(_ e: NSEvent) {
        let p = loc(e)
        lastPoint = p
        withoutImplicitAnimation {
            cursorLayer.position = p
            cursorLayer.isHidden = false
        }
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }

    /// A quick press feedback: the disc shrinks-then-settles and an expanding ring
    /// fades out from the touch point.
    private func tapFeedback(at p: CGPoint) {
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.62; pop.toValue = 1.0; pop.duration = 0.35
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cursorLayer.add(pop, forKey: "tap")

        let ring = CALayer()
        ring.frame = CGRect(x: 0, y: 0, width: Self.cursorSize, height: Self.cursorSize)
        ring.position = p
        ring.cornerRadius = Self.cursorSize / 2
        ring.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ring.borderWidth = 2
        ring.zPosition = 99
        layer?.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.7; grow.toValue = 2.3
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.9; fade.toValue = 0
        let g = CAAnimationGroup(); g.animations = [grow, fade]; g.duration = 0.42
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(g, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak ring] in ring?.removeFromSuperlayer() }
    }

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
        // Keep the touch cursor above the freshly added video layer.
        cursorLayer.removeFromSuperlayer()
        layer?.addSublayer(cursorLayer)
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
    override var acceptsFirstResponder: Bool { true }

    /// Map a point (view coords, bottom-left origin) into the aspect-fit video rect,
    /// then to phone pixel coords (top-left origin). nil if on the letterbox.
    /// The aspect-fit rectangle (view coords) where the picture is actually drawn.
    private func fitRect() -> CGRect? {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let vidAR = videoSize.width / videoSize.height
        let viewAR = bounds.width / bounds.height
        if vidAR > viewAR {
            let h = bounds.width / vidAR
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * vidAR
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
    }

    private func map(_ p: CGPoint) -> (Int, Int, Int, Int)? {
        guard let rect = fitRect(), rect.contains(p) else { return nil }
        let nx = (p.x - rect.minX) / rect.width
        let ny = (p.y - rect.minY) / rect.height
        let vx = Int((nx * videoSize.width).rounded())
        let vy = Int(((1 - ny) * videoSize.height).rounded()) // flip y to top-left origin
        return (vx, vy, Int(videoSize.width), Int(videoSize.height))
    }

    /// Inverse of `map`: a phone caret point (mirror px, top-left) → view point.
    private func videoToView(_ p: CGPoint) -> CGPoint? {
        guard let rect = fitRect() else { return nil }
        let fx = min(max(p.x / videoSize.width, 0), 1)
        let fy = min(max(p.y / videoSize.height, 0), 1)
        return CGPoint(x: rect.minX + fx * rect.width,
                       y: rect.minY + (1 - fy) * rect.height) // flip y to bottom-left
    }

    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func send(_ action: UInt8, _ button: UInt8, _ e: NSEvent) {
        guard let m = map(loc(e)) else { return }
        onMouse?(action, button, m.0, m.1, m.2, m.3)
    }

    override func mouseDown(with e: NSEvent) { moveCursor(e); tapFeedback(at: loc(e)); send(0, 1, e) }
    override func mouseDragged(with e: NSEvent) { moveCursor(e); send(2, 1, e) }
    override func mouseUp(with e: NSEvent) { moveCursor(e); send(1, 1, e) }
    override func rightMouseDown(with e: NSEvent) { moveCursor(e); send(0, 2, e) }
    override func rightMouseDragged(with e: NSEvent) { moveCursor(e); send(2, 2, e) }
    override func rightMouseUp(with e: NSEvent) { moveCursor(e); send(1, 2, e) }

    /// Trackpad scrolling is far finer-grained than a wheel notch — emitting one
    /// phone scroll per event makes it hyper-sensitive. Accumulate the precise
    /// delta and emit a tick only once it crosses a threshold; a wheel mouse
    /// (coarse, line-based deltas) still emits one tick per notch.
    override func scrollWheel(with e: NSEvent) {
        guard let m = map(loc(e)) else { return }
        if e.hasPreciseScrollingDeltas {
            scrollAccum += e.scrollingDeltaY
            let threshold: CGFloat = 22   // points of finger travel per phone scroll tick
            while abs(scrollAccum) >= threshold {
                let dir = scrollAccum > 0 ? 1 : -1
                onScroll?(dir, m.0, m.1, m.2, m.3)
                scrollAccum -= CGFloat(dir) * threshold
            }
            if e.phase == .ended || e.phase == .cancelled || e.momentumPhase == .ended {
                scrollAccum = 0
            }
        } else if e.scrollingDeltaY != 0 {
            onScroll?(e.scrollingDeltaY > 0 ? 1 : -1, m.0, m.1, m.2, m.3)
        }
    }

    // MARK: Keyboard → phone

    // Pinyin/kana/etc. in-progress composition (shown in the macOS candidate
    // window; nothing is sent to the phone until the IME commits final text).
    private var markedText = ""

    override func keyDown(with e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Leave ⌘/⌃ chords to the system (menu shortcuts, etc.); don't beep.
        if flags.contains(.command) || flags.contains(.control) { return }
        // Type only when the phone is in input mode (a field is focused);
        // otherwise swallow the key so stray typing never reaches the phone.
        guard phoneInputActive else { return }

        // While composing (IME candidate up), every key belongs to the IME.
        if !hasMarkedText() {
            // Special keys → Android KEYCODE_* (so they act like hardware keys).
            switch e.keyCode {
            case 51:        onBackspace?(); return              // Delete (backspace)
            case 36, 76:    onKeyCode?(66); return              // Return / Enter → ENTER
            case 48:        onKeyCode?(61); return              // Tab → TAB
            case 53:        onKeyCode?(4);  return              // Esc → BACK
            case 117:       onKeyCode?(112); return             // Fwd Delete → FORWARD_DEL
            case 123:       onKeyCode?(21); return              // ← DPAD_LEFT
            case 124:       onKeyCode?(22); return              // → DPAD_RIGHT
            case 125:       onKeyCode?(20); return              // ↓ DPAD_DOWN
            case 126:       onKeyCode?(19); return              // ↑ DPAD_UP
            default: break
            }
        }
        // Route through the active input method: latin keys arrive via
        // insertText, CJK/emoji composition via setMarkedText then insertText.
        _ = inputContext?.handleEvent(e)
    }

    // Consume key-ups so they don't ring the system bell at the responder chain end.
    override func keyUp(with e: NSEvent) {}

    // Swallow editing selectors the IME emits for keys we don't model, so the
    // responder chain doesn't end in a system beep.
    override func doCommand(by selector: Selector) {}
}

// MARK: - IME text input (so Chinese / Japanese / emoji compose correctly)

extension MirrorInputView: NSTextInputClient {
    private func asString(_ any: Any) -> String {
        (any as? String) ?? (any as? NSAttributedString)?.string ?? ""
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let s = asString(string)
        if !s.isEmpty { onText?(s) }   // committed text → commit on the phone
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = asString(string)   // still composing; not sent yet
    }

    func unmarkText() { markedText = "" }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: markedText.utf16.count)
    }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Anchor the IME candidate window at the phone's reported caret (mapped into
    /// view coords); fall back to the last tap location if no caret is known.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let w = window else { return .zero }
        let p: CGPoint
        if let a = imeAnchorVideo, let v = videoToView(a) {
            p = v
        } else {
            p = (lastPoint == .zero) ? CGPoint(x: bounds.midX, y: bounds.midY) : lastPoint
        }
        let inWindow = convert(p, to: nil)
        return w.convertToScreen(NSRect(origin: inWindow, size: CGSize(width: 1, height: 1)))
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
    private let privacyOverlay = PrivacyOverlayModel()
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
        video.onText = { [weak self] s in self?.model.typeText(s) }
        video.onKeyCode = { [weak self] code in self?.model.key(code) }
        video.onBackspace = { [weak self] in self?.model.backspace() }

        let chromeHost = NSHostingView(rootView: MirrorChromeView(
            progress: chromeProgress,
            onClose: { [weak self] in self?.model.closeMirror() },
            onMinimize: { [weak self] in self?.window?.miniaturize(nil) },
            onZoom: { [weak self] in self?.window?.zoom(nil) },
            onKey: { [weak self] code in self?.model.key(code) }
        ))

        let overlayHost = NSHostingView(rootView: PrivacyOverlay(model: privacyOverlay))
        overlayHost.layer?.backgroundColor = .clear

        let container = MirrorContainerView(video: video, chromeHost: chromeHost, overlayHost: overlayHost, progress: chromeProgress)
        container.onHover = { [weak self] hovering in self?.container?.setProgress(hovering ? 1 : 0, animated: true) }

        w.contentView = container
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true    // real native shadow; we invalidate it per-frame as the frame grows
        w.acceptsMouseMovedEvents = true   // so the touch-style cursor can follow the pointer
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
        model.$privacyState
            .receive(on: RunLoop.main)
            .sink { [weak self] tok in self?.privacyOverlay.kind = tok }
            .store(in: &bag)
        // Phone caret → place the IME there (mapped to view coords in firstRect).
        model.imeCursorSink = { [weak self] p in self?.video?.imeAnchorVideo = p }
        // Phone input mode → gate the keyboard (only type when a field is focused).
        model.imeActiveSink = { [weak self] on in self?.video?.phoneInputActive = on }

        applyAspect(model.videoSize)
        if connect { model.startMirror() }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(video)   // keyboard goes to the picture
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
        model.imeCursorSink = nil
        model.imeActiveSink = nil
        model.stopMirror()
        window = nil; container = nil; video = nil
        NSApp.setActivationPolicy(.accessory) // back to menu-bar agent
    }
}
