import Foundation
import AVFoundation

/// Connection lifecycle state, surfaced to the UI.
enum ConnState: Equatable {
    case disconnected
    case connecting(DeviceRef)
    case reconnecting(DeviceRef)
    case connected(DeviceRef)
    case failed(String)
}

/// Which background features to arm on connect.
struct ConnectFeatures {
    var clipboard: Bool
    var clipRecv: Bool
    var clipSend: Bool
    var verify: Bool
}

/// Owns the Rust FFI handles and runs everything off the main thread.
///
/// Design notes (the hard part of making this production-grade):
/// - All connect/disconnect/mirror lifecycle runs on one **serial** queue, so the
///   handles are never mutated concurrently.
/// - The blocking pollers (`next_frame`, `next_verify_code`) run on dedicated
///   threads that hold a strong reference to the Rust handle while parked. We can't
///   drop the handle out from under them, so teardown asks the handle to stop
///   (`PcScreen.stop()` / `PcSession.stop_verify()`), then **waits** for the polling
///   thread to exit (semaphore) before releasing the handle. That guarantees the
///   Rust `Session`/`ScreenStream` actually drop — aborting their tasks and freeing
///   the control WS / adb forwards — which is required because the phone only allows
///   one control session at a time.
/// - Callbacks are always delivered on the main queue.
final class SessionController {
    // Delivered on the main queue.
    var onState: ((ConnState) -> Void)?
    var onMirroring: ((Bool, AVSampleBufferDisplayLayer?) -> Void)?
    var onFrameCount: ((Int) -> Void)?
    var onFormat: ((Int, Int) -> Void)?
    var onVerifyCode: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.pcsuite.session")
    private let inputQueue = DispatchQueue(label: "com.pcsuite.input")

    // Handles + worker bookkeeping. Touched on `queue` (and the worker threads they
    // belong to). `sessionRef`/`mirroring` are read from `inputQueue`/main under lock.
    private var session: PcSession?
    private var screen: PcScreen?
    private var feeder: HEVCFeeder?

    private var verifyDone: DispatchSemaphore?
    private var frameDone: DispatchSemaphore?

    // Black-screen recovery (touched on `queue`). If a freshly started stream delivers
    // no frame within a few seconds — the phone's screen service didn't fully reset
    // between a stop and the next start — tear it down and start again. Bounded, so a
    // genuinely stuck phone (e.g. locked screen) doesn't restart-loop forever.
    private var mirrorGen = 0
    private var firstFrameSeen = false
    private var mirrorRecoveries = 0
    private let mirrorRecoverDelay: TimeInterval = 4.0
    private let mirrorRecoverMax = 2

    private let lock = NSLock()
    private var sessionRef: PcSession?   // lock-guarded snapshot for input dispatch
    private var cancelRequested = false  // lock-guarded

    // Coalesced pointer-move state (lock-guarded).
    private var pendingMove: (UInt8, Int, Int, Int, Int)?
    private var moveDraining = false

    // MARK: - Connect / disconnect

    func connect(_ device: DeviceRef, features: ConnectFeatures, reconnect: Bool) {
        lock.lock(); cancelRequested = false; lock.unlock()
        queue.async { [self] in
            teardownLocked()                       // ensure any prior session is gone
            emitState(reconnect ? .reconnecting(device) : .connecting(device))
            do {
                let s: PcSession
                switch device.transport {
                case .usb: s = try pcsuite_connect_usb()
                case .lan: s = try pcsuite_connect_lan(device.ip ?? "", false)
                }
                if isCancelled() {                 // user cancelled mid-connect → discard
                    log("connect cancelled; discarding session")
                    emitState(.disconnected)
                    return
                }
                if features.clipboard {
                    do { try s.enable_clipboard(features.clipRecv, features.clipSend) }
                    catch { log("clipboard enable failed: \(ffiMessage(error))") }
                }
                if features.verify {
                    s.enable_verify()
                    startVerifyLoop(s)
                }
                setSession(s)
                emitState(.connected(device))
                emitMirroring(false, nil)
                log("connected ✓ (\(device.displayName))")
            } catch {
                if isCancelled() { emitState(.disconnected) }
                else { emitState(.failed(ffiMessage(error))) }
                log("connect failed: \(ffiMessage(error))")
            }
        }
    }

    /// Discard the result of an in-flight connect (the blocking Rust call can't be
    /// aborted, but we drop whatever it returns).
    func cancel() {
        lock.lock(); cancelRequested = true; lock.unlock()
    }

    func disconnect() {
        cancel()
        queue.async { [self] in
            teardownLocked()
            emitState(.disconnected)
            log("disconnected")
        }
    }

    /// Stop mirroring and verify, then release the session. Runs on `queue`.
    private func teardownLocked() {
        stopMirrorLocked()
        if let s = session, let done = verifyDone {
            s.stop_verify()
            done.wait()                 // block until the verify thread exits
            verifyDone = nil
        }
        setSession(nil)                 // last ref → Rust Session drops → cleanup
    }

    // MARK: - Mirroring

    func startMirror(maxSize: Int64) {
        queue.async { [self] in startMirrorLocked(maxSize: maxSize) }
    }

    /// Apply a new resolution to a live mirror: stop the current stream and reopen
    /// it with the new `max_size` (SCREEN_START params are fixed per stream).
    func restartMirror(maxSize: Int64) {
        queue.async { [self] in
            guard screen != nil else { return }
            stopMirrorLocked()
            startMirrorLocked(maxSize: maxSize)
        }
    }

    private func startMirrorLocked(maxSize: Int64) {
        guard let s = session, screen == nil else { return }
        do {
            let sc = try s.start_screen(maxSize)
            let f = HEVCFeeder()
                f.onFormat = { [weak self] w, h in self?.emit { self?.onFormat?(w, h) } }
                var tally = 0
                f.onEnqueue = { [weak self] in
                    tally += 1                       // onEnqueue fires on the main queue
                    self?.onFrameCount?(tally)
                }
                screen = sc
                feeder = f
                mirrorGen += 1
                let gen = mirrorGen
                firstFrameSeen = false
                let done = DispatchSemaphore(value: 0)
                frameDone = done
                let pump = Thread { [weak self] in
                    var first = true
                    while true {
                        let v = sc.next_frame()
                        let n = Int(v.len())
                        if n == 0 { break }          // stopped or stream ended
                        if first {                   // first real frame → stream is alive
                            first = false
                            self?.queue.async {
                                self?.firstFrameSeen = true
                                self?.mirrorRecoveries = 0   // healthy → restore retry budget
                            }
                        }
                        f.handle(Data(bytes: v.as_ptr(), count: n))
                    }
                    done.signal()
                }
                pump.name = "frame-pump"
                pump.stackSize = 4 << 20
                pump.start()
                emitMirroring(true, f.layer)
                scheduleMirrorWatchdog(gen: gen, maxSize: maxSize)
                log("mirroring ✓")
            } catch {
                emitMirroring(false, nil)
                log("start mirror failed: \(ffiMessage(error))")
            }
    }

    /// If this stream generation hasn't produced a single frame after a short grace
    /// period (black screen), restart it once the phone has had a moment to reset —
    /// up to `mirrorRecoverMax` times. Only fires while still mirroring this exact
    /// generation, so it never disturbs a working stream or a closed window.
    private func scheduleMirrorWatchdog(gen: Int, maxSize: Int64) {
        queue.asyncAfter(deadline: .now() + mirrorRecoverDelay) { [weak self] in
            guard let self,
                  self.mirrorGen == gen, self.screen != nil, !self.firstFrameSeen
            else { return }
            guard self.mirrorRecoveries < self.mirrorRecoverMax else {
                log("mirror still black after \(self.mirrorRecoveries) recoveries; leaving as-is")
                return
            }
            self.mirrorRecoveries += 1
            log("no frames in \(self.mirrorRecoverDelay)s → recovering mirror (attempt \(self.mirrorRecoveries))")
            self.stopMirrorLocked()
            self.startMirrorLocked(maxSize: maxSize)
        }
    }

    func stopMirror() {
        queue.async { [self] in stopMirrorLocked() }
    }

    private func stopMirrorLocked() {
        guard let sc = screen, let done = frameDone else { return }
        sc.stop()
        done.wait()                     // block until the frame pump exits
        frameDone = nil
        screen = nil
        feeder = nil
        emitMirroring(false, nil)
        log("mirroring stopped")
    }

    // MARK: - Verify loop

    private func startVerifyLoop(_ s: PcSession) {
        let done = DispatchSemaphore(value: 0)
        verifyDone = done
        let t = Thread { [weak self] in
            while true {
                let raw = s.next_verify_code().toString()
                if raw.isEmpty { break }            // stopped or session ended
                let code = raw.components(separatedBy: "\t").first ?? raw
                self?.emit { self?.onVerifyCode?(code) }
            }
            done.signal()
        }
        t.name = "verify-loop"
        t.start()
    }

    // MARK: - Input (mouse / scroll), dispatched off the main thread

    /// action: 0=down 1=up 2=move · button: 1=left 2=right.
    func sendMouse(action: UInt8, button: UInt8, x: Int, y: Int, w: Int, h: Int) {
        if action == 2 { coalesceMove(button: button, x: x, y: y, w: w, h: h); return }
        inputQueue.async { [self] in
            guard let s = snapshotSession() else { return }
            _ = s.mouse(action, button, Int64(x), Int64(y), Int64(w), Int64(h))
        }
    }

    func sendScroll(v: Int, x: Int, y: Int, w: Int, h: Int) {
        inputQueue.async { [self] in
            guard let s = snapshotSession() else { return }
            _ = s.scroll(Int64(v), Int64(x), Int64(y), Int64(w), Int64(h))
        }
    }

    /// Press an Android navigation key (down+up). `keycode` is a `KEYCODE_*` value.
    func sendKey(_ keycode: Int) {
        inputQueue.async { [self] in
            guard let s = snapshotSession() else { return }
            _ = s.key(Int64(keycode))
        }
    }

    /// Drag moves can arrive far faster than the network round-trip; keep only the
    /// latest pending move so the cursor doesn't lag behind a backlog.
    private func coalesceMove(button: UInt8, x: Int, y: Int, w: Int, h: Int) {
        lock.lock()
        pendingMove = (button, x, y, w, h)
        let kick = !moveDraining
        if kick { moveDraining = true }
        lock.unlock()
        guard kick else { return }
        inputQueue.async { [self] in
            while true {
                lock.lock()
                guard let m = pendingMove else { moveDraining = false; lock.unlock(); return }
                pendingMove = nil
                lock.unlock()
                guard let s = snapshotSession() else {
                    lock.lock(); moveDraining = false; lock.unlock(); return
                }
                _ = s.mouse(2, m.0, Int64(m.1), Int64(m.2), Int64(m.3), Int64(m.4))
            }
        }
    }

    // MARK: - Helpers

    private func setSession(_ s: PcSession?) {
        session = s
        lock.lock(); sessionRef = s; lock.unlock()
    }
    private func snapshotSession() -> PcSession? {
        lock.lock(); defer { lock.unlock() }; return sessionRef
    }
    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }; return cancelRequested
    }
    private func emitState(_ s: ConnState) { emit { self.onState?(s) } }
    private func emitMirroring(_ on: Bool, _ layer: AVSampleBufferDisplayLayer?) {
        emit { self.onMirroring?(on, layer) }
    }
    private func emit(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}
