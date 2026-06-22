import Foundation

/// Drives the Rust core: connect over LAN, start mirroring, pump raw HEVC frames
/// into the decoder. Validates the two things we care about: (1) connection,
/// (2) screen mirroring (frames decode + display).
final class Mirror: ObservableObject {
    @Published var status = "idle"
    @Published var frameCount = 0
    @Published var dims = ""

    let feeder = HEVCFeeder()
    private var session: PcSession?
    private var screen: PcScreen?
    private var connecting = false   // guards against a double connect (onAppear can fire twice)

    init() {
        feeder.onFormat = { [weak self] w, h in
            self?.onMain { self?.dims = "\(w)×\(h)" }
            log("first format \(w)x\(h)")
        }
        feeder.onEnqueue = { [weak self] in
            self?.onMain { self?.frameCount += 1 }
        }
    }

    func connect(ip: String) {
        // `connecting`/`session` are only touched on the main thread, so this guard
        // is race-free and prevents a second control session (the phone allows one).
        guard !connecting, session == nil else { return }
        connecting = true
        status = "connecting…"
        log("connecting to \(ip)")
        // connect_lan blocks for a few seconds — never on the main thread.
        Thread.detachNewThread { [weak self] in
            do {
                let s = try pcsuite_connect_lan(ip, false)
                self?.onMain { self?.session = s; self?.status = "connected" }
                log("connected ✓")
                self?.startScreen(s)
            } catch {
                self?.onMain { self?.connecting = false; self?.status = "connect failed" }
                log("connect failed: \(error)")
            }
        }
    }

    private func startScreen(_ s: PcSession) {
        do {
            let sc = try s.start_screen()
            self.screen = sc
            onMain { self.status = "mirroring" }
            log("screen started ✓")
            let t = Thread { [weak self] in
                var total = 0
                // next_frame() blocks until the next access unit; loop off-main.
                while true {
                    let v = sc.next_frame()
                    let n = v.len()
                    if n == 0 { log("stream ended after \(total) frames"); break }
                    total += 1
                    let data = Data(bytes: v.as_ptr(), count: n)
                    self?.feeder.handle(data)
                    if total == 1 || total % 60 == 0 { log("frame \(total) (\(n) B)") }
                }
            }
            t.name = "frame-pump"
            t.stackSize = 4 << 20
            t.start()
        } catch {
            onMain { self.status = "screen failed" }
            log("screen failed: \(error)")
        }
    }

    private func onMain(_ b: @escaping () -> Void) { DispatchQueue.main.async(execute: b) }
}

/// Log to stderr so a headless `xcodebuild`-built binary run shows progress.
func log(_ s: String) {
    FileHandle.standardError.write(Data(("[mirror] " + s + "\n").utf8))
}
