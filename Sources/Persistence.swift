import Foundation

/// How we reach the phone.
enum Transport: String, Codable {
    case usb
    case lan
}

/// A connection target the app can remember and reconnect to. For LAN we keep the
/// last IP; USB needs nothing (it's "whatever phone is on the adb cable").
struct DeviceRef: Codable, Equatable {
    var transport: Transport
    var ip: String?
    /// Phone display name when known (e.g. "iQOO 15"), used for nicer labels —
    /// populated by QR pairing. Optional → backward-compatible with stored data.
    var name: String? = nil

    /// Short label for the menu, e.g. "iQOO 15", "USB", or "192.168.1.42".
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        switch transport {
        case .usb: return L("via USB")
        case .lan: return ip ?? L("via Wi-Fi")
        }
    }
}

/// A per-phone pairing seed (historyPhone `ext.seeds`) for the LAN connectType=2
/// path. Keyed by the phone's LAN IP. Not needed when using connectType=1.
struct SeedEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var ip: String
    var seed: String
}

/// Mirror resolution preset — caps the phone's longer screen edge (px). Lower =
/// less encode/decode latency. `.high` (0) means the core's full-resolution default.
enum MirrorResolution: String, CaseIterable, Identifiable, Codable {
    case high, medium, low
    var id: String { rawValue }
    var maxSize: Int64 {
        switch self {
        case .high: return 0      // 0 → core default (full)
        case .medium: return 1280
        case .low: return 720
        }
    }
    var label: String {
        switch self {
        case .high: return L("High (full)")
        case .medium: return L("Medium (1280)")
        case .low: return L("Low (720)")
        }
    }
}

/// Phone facts from the `/base-info` gateway (storage capacity, model, OS) — the
/// data the desktop app shows in its device panel. Built from the tab-separated
/// string returned by `PcSession.device_info()`.
struct PhoneInfo: Equatable {
    var name: String
    var brand: String
    var product: String
    var androidVersion: String
    var osVersion: String
    var widthPixels: Int
    var heightPixels: Int
    var foldScreen: Bool
    var totalStorageGB: String
    var availableStorageGB: String
    var availableBytes: Int64
    var account: String
    /// Real vivo-account openId (16-hex) reported by the phone; "" if not logged in
    /// or an older core. Used to self-fill the pairing identity (see AppModel).
    var openID: String = ""

    /// Parse the `device_info()` payload: tab-separated fields in a fixed order
    /// (12 legacy fields + an optional 13th `openID`).
    static func parse(_ s: String) -> PhoneInfo? {
        let f = s.components(separatedBy: "\t")
        guard f.count >= 12 else { return nil }
        return PhoneInfo(
            name: f[0], brand: f[1], product: f[2], androidVersion: f[3], osVersion: f[4],
            widthPixels: Int(f[5]) ?? 0, heightPixels: Int(f[6]) ?? 0,
            foldScreen: f[7] == "1",
            totalStorageGB: f[8], availableStorageGB: f[9],
            availableBytes: Int64(f[10]) ?? 0, account: f[11],
            openID: f.count > 12 ? f[12] : ""
        )
    }

    /// Compact storage summary, e.g. "327.55 / 512 GB".
    var storageSummary: String { "\(availableStorageGB) / \(totalStorageGB) GB" }
}

/// Clipboard sync direction.
enum ClipboardDirection: String, CaseIterable, Identifiable, Codable {
    case both       // two-way
    case toPhone    // Mac → phone only
    case fromPhone  // phone → Mac only
    var id: String { rawValue }
    /// Apply the phone's clipboard to this Mac (phone→PC).
    var recv: Bool { self != .toPhone }
    /// Push this Mac's clipboard to the phone (PC→phone).
    var send: Bool { self != .fromPhone }
    var label: String {
        switch self {
        case .both: return L("Two-way")
        case .toPhone: return L("Mac → phone only")
        case .fromPhone: return L("Phone → Mac only")
        }
    }
}

/// Thin UserDefaults-backed settings store. Defaults: auto-reconnect, clipboard and
/// verify-code relay are all ON out of the box (requirements 2 & 4).
enum Store {
    private static let d = UserDefaults.standard
    private static func flag(_ k: String, default def: Bool) -> Bool {
        d.object(forKey: k) as? Bool ?? def
    }

    static var autoReconnect: Bool {
        get { flag("autoReconnect", default: true) }
        set { d.set(newValue, forKey: "autoReconnect") }
    }
    static var clipboardEnabled: Bool {
        get { flag("clipboardEnabled", default: true) }
        set { d.set(newValue, forKey: "clipboardEnabled") }
    }
    static var verifyEnabled: Bool {
        get { flag("verifyEnabled", default: true) }
        set { d.set(newValue, forKey: "verifyEnabled") }
    }
    static var notifyEnabled: Bool {
        get { flag("notifyEnabled", default: true) }
        set { d.set(newValue, forKey: "notifyEnabled") }
    }
    static var lanIP: String {
        get { d.string(forKey: "lanIP") ?? "" }
        set { d.set(newValue, forKey: "lanIP") }
    }
    static var resolution: MirrorResolution {
        get { MirrorResolution(rawValue: d.string(forKey: "resolution") ?? "") ?? .high }
        set { d.set(newValue.rawValue, forKey: "resolution") }
    }
    static var clipboardDirection: ClipboardDirection {
        get { ClipboardDirection(rawValue: d.string(forKey: "clipboardDirection") ?? "") ?? .both }
        set { d.set(newValue.rawValue, forKey: "clipboardDirection") }
    }
    static var lastDevice: DeviceRef? {
        get {
            guard let data = d.data(forKey: "lastDevice") else { return nil }
            return try? JSONDecoder().decode(DeviceRef.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                d.set(data, forKey: "lastDevice")
            } else {
                d.removeObject(forKey: "lastDevice")
            }
        }
    }

    // MARK: - LAN pairing identity (only the LAN path needs these; USB ignores them)

    /// vivo account openId — the phone matches the LAN sign against this. Account-
    /// level: the same value works for every phone signed into that account.
    static var openID: String {
        get { d.string(forKey: "openID") ?? "" }
        set { d.set(newValue, forKey: "openID") }
    }
    /// Display name announced to the phone. Defaults to this Mac's name.
    static var deviceName: String {
        get { d.string(forKey: "deviceName") ?? (Host.current().localizedName ?? "My Mac") }
        set { d.set(newValue, forKey: "deviceName") }
    }
    /// PC device id / MAC (12 hex). Optional — the phone only validates openId.
    static var pcMac: String {
        get { d.string(forKey: "pcMac") ?? "" }
        set { d.set(newValue, forKey: "pcMac") }
    }
    /// Optional display account string (cosmetic, e.g. a masked phone number).
    static var accountLabel: String {
        get { d.string(forKey: "accountLabel") ?? "" }
        set { d.set(newValue, forKey: "accountLabel") }
    }
    /// Super-clipboard PC device id (6 chars). The phone pushes its clipboard only
    /// to the id it registered for this Mac at pairing, so this MUST match it for
    /// phone→Mac sync. Empty → core placeholder (phone→Mac won't work).
    static var clipPcId: String {
        get { d.string(forKey: "clipPcId") ?? "" }
        set { d.set(newValue, forKey: "clipPcId") }
    }
    /// Connect with connectType=1 (no stored seed). Recommended (and the default):
    /// it needs only the openID and works on any network. Turn off to use the per-IP
    /// `seeds` below (connectType=2) — but the connect path also auto-falls-back to
    /// connectType=1 when no seed is stored for the target IP.
    static var lanUseRemote: Bool {
        get { flag("lanUseRemote", default: true) }
        set { d.set(newValue, forKey: "lanUseRemote") }
    }
    /// Per-phone stored pairing seeds for the connectType=2 LAN path.
    static var seeds: [SeedEntry] {
        get {
            guard let data = d.data(forKey: "seeds") else { return [] }
            return (try? JSONDecoder().decode([SeedEntry].self, from: data)) ?? []
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "seeds") }
    }
}
