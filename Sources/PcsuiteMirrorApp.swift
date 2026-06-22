import SwiftUI

@main
struct PcsuiteMirrorApp: App {
    var body: some Scene {
        WindowGroup("pcsuite mirror") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var mirror = Mirror()
    @State private var ip = "192.168.1.42"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("phone IP", text: $ip).frame(width: 150).textFieldStyle(.roundedBorder)
                Button("Connect") { mirror.connect(ip: ip) }
                Text(mirror.status).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !mirror.dims.isEmpty { Text(mirror.dims).font(.caption.monospaced()) }
                Text("frames \(mirror.frameCount)").font(.caption.monospaced())
            }
            .padding(8)
            MirrorView(layer: mirror.feeder.layer)
                .frame(minWidth: 420, minHeight: 560)
                .background(.black)
        }
        .onAppear {
            pcsuite_log_init()
            if let auto = ProcessInfo.processInfo.environment["PCSUITE_AUTOCONNECT"], !auto.isEmpty {
                ip = auto
                mirror.connect(ip: auto)
            }
        }
    }
}
