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

    /// Short label for the menu, e.g. "USB" or "192.168.1.42".
    var displayName: String {
        switch transport {
        case .usb: return L("via USB")
        case .lan: return ip ?? L("via Wi-Fi")
        }
    }
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
}
