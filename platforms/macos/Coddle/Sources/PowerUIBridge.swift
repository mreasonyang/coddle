import Foundation

/// Thin Swift wrapper over the Objective-C PowerUI bridge (PowerUI.h/.m).
///
/// Drives the OS-native Charge Limit (Apple silicon, macOS 26.4+) through
/// PowerUIAgent. Verified working from a non-root process on macOS 27 — so no
/// privileged helper is required for this path.
enum PowerUI {
    static var isSupported: Bool { coddle_powerui_supported() == 1 }
    static var supportsTemporaryFullCharge: Bool { coddle_powerui_temporary_full_supported() == 1 }

    static func availableLimits() -> [Int] {
        var buf = [Int32](repeating: 0, count: 32)
        var count: Int32 = 0
        var errp: UnsafeMutablePointer<CChar>? = nil
        let rc = buf.withUnsafeMutableBufferPointer { bp in
            coddle_powerui_available_limits(bp.baseAddress, 32, &count, &errp)
        }
        defer { if let e = errp { coddle_powerui_free(e) } }
        guard rc == 0, count > 0 else { return [] }
        let validCount = min(Int(count), buf.count)
        return (0..<validCount).map { Int(buf[$0]) }.sorted()
    }

    /// Current configured limit and whether it is enforced. A disabled limit
    /// reads as 100 with enabled == false.
    static func current() -> (limit: Int, enabled: Bool)? {
        var limit: Int32 = 0
        var enabled: Int32 = 0
        var errp: UnsafeMutablePointer<CChar>? = nil
        let rc = coddle_powerui_get(&limit, &enabled, &errp)
        defer { if let e = errp { coddle_powerui_free(e) } }
        guard rc == 0 else { return nil }
        return (Int(limit), enabled != 0)
    }

    /// Enable the limit at `percent`. Returns an error message, or nil on success.
    @discardableResult
    static func set(_ percent: Int) -> String? {
        guard percent >= 0 && percent <= 100 else {
            return "invalid charge limit"
        }
        var errp: UnsafeMutablePointer<CChar>? = nil
        let rc = coddle_powerui_set(Int32(percent), &errp)
        defer { if let e = errp { coddle_powerui_free(e) } }
        if rc == 0 { return nil }
        return errp.map { String(cString: $0) } ?? "unknown PowerUI error"
    }

    /// Turn the limit off. Returns an error message, or nil on success.
    @discardableResult
    static func disable() -> String? {
        var errp: UnsafeMutablePointer<CChar>? = nil
        let rc = coddle_powerui_disable(&errp)
        defer { if let e = errp { coddle_powerui_free(e) } }
        if rc == 0 { return nil }
        return errp.map { String(cString: $0) } ?? "unknown PowerUI error"
    }

    /// Temporarily disable the charge limit to charge to 100% now (Control Center behavior).
    @discardableResult
    static func chargeToFullNow() -> String? {
        var errp: UnsafeMutablePointer<CChar>? = nil
        let rc = coddle_powerui_charge_to_full_now(&errp)
        defer { if let e = errp { coddle_powerui_free(e) } }
        if rc == 0 { return nil }
        return errp.map { String(cString: $0) } ?? "unknown PowerUI error"
    }
}
