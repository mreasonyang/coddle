import Foundation
import IOKit

/// Real-time power telemetry from `AppleSmartBattery` / `PowerTelemetryData`.
struct PowerFlow: Equatable, Sendable {
    var adapterWatts: Int? = nil
    var systemPowerInWatts: Double? = nil
    var systemLoadWatts: Double? = nil
    var batteryPowerWatts: Double? = nil

    var hasData: Bool {
        adapterWatts != nil || systemPowerInWatts != nil || systemLoadWatts != nil || batteryPowerWatts != nil
    }
}

/// Pure presentation logic for power flow telemetry.
struct PowerFlowPresentation {
    static func batteryFlowWattsText(watts: Double?) -> String {
        guard let bw = watts else { return "—" }
        if bw > 0.05 {
            return String(format: "+%.1f W", bw)
        } else if bw < -0.05 {
            return String(format: "%.1f W", bw)
        } else {
            return "0.0 W"
        }
    }

    static func batteryFlowStateText(watts: Double?, externalConnected: Bool,
                                     tr: (String) -> String = { $0 }) -> String? {
        guard let bw = watts else { return nil }
        if bw > 0.05 { return tr("state.charging") }
        if bw < -0.05 { return tr("state.discharging") }
        return externalConnected ? tr("power.bypassed") : nil
    }

    static func batteryFlowText(watts: Double?, externalConnected: Bool, tr: (String) -> String = { $0 }) -> String {
        let value = batteryFlowWattsText(watts: watts)
        guard let state = batteryFlowStateText(watts: watts, externalConnected: externalConnected, tr: tr) else {
            return value
        }
        return "\(value) (\(state))"
    }

    static func batteryFlowIcon(watts: Double?, externalConnected: Bool) -> String {
        guard let bw = watts else { return "battery.0" }
        if bw > 0.05 {
            return "battery.100.bolt"
        } else if bw < -0.05 {
            return "battery.25"
        } else if externalConnected {
            return "powerplug.fill"
        } else {
            return "battery.100"
        }
    }
}

/// Battery state read natively from IOKit (`AppleSmartBattery`). No root, no
/// private API. Capacities are reported in mAh by macOS.
struct BatteryInfo: Sendable {
    var present = false
    var installed = false
    var percent: Int? = nil
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var cycleCount: Int? = nil
    var designCapacity: Int? = nil
    var fullChargeCapacity: Int? = nil

    // ChargerData (nested) — reason a plugged-in pack is not drawing current.
    var notChargingReason: Int? = nil
    /// Signed battery current in mA (negative = discharging). nil if unavailable.
    var amperage: Int? = nil

    /// Real-time electrical power telemetry (adapter watts, input, load, battery flow).
    var powerFlow: PowerFlow? = nil

    /// Raw gauge state of charge in percent, one decimal, from the battery-pack
    /// child service's raw capacities. Deliberately distinct from `percent`
    /// (the macOS value, which stays the headline everywhere). `nil` when the
    /// pack is absent (Intel / older macOS), its keys are missing, or a
    /// capacity is at the driver's 0xFFFF "unknown" sentinel — never a
    /// fabricated value.
    var hardwarePercent: Double? = nil
    /// Pack temperature in °C from the gauge's centi-°C `Temperature`. `nil`
    /// when unavailable (the gauge's exactly-0 sentinel) or an implausible
    /// magnitude — never a fake 0.0 °C. A cold-soaked pack legitimately reads
    /// below 0 °C, so negatives are valid readings, not "unavailable".
    var temperatureCelsius: Double? = nil

    /// State of health as a percentage (full / design). Nil if unavailable.
    var healthPercent: Double? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else {
            return nil
        }
        return (Double(full) / Double(design) * 1000).rounded() / 10
    }
}

/// A reason-aware charging state. `holding` carries the active limit so the UI
/// can say "holding at N%" instead of the ambiguous "not charging".
enum ChargeStatus: Equatable {
    case noBattery
    case charging
    case charged
    case holding(limit: Int)
    case notCharging
    case discharging
    case onBattery
}

extension BatteryInfo {
    /// Precedence-based state machine. Cross-references the native charge limit
    /// (`limit`/`enabled` from PowerUI) so a healthy hold is not mislabelled as
    /// a fault. `NotChargingReason` bit 24 (0x01000000) is the firmware's
    /// "held by a charge limit" hint, used as a secondary signal only.
    func chargeStatus(limit: Int?, enabled: Bool) -> ChargeStatus {
        if !present || !installed { return .noBattery }
        if isCharging { return .charging }
        if externalConnected {
            if fullyCharged || (percent ?? 0) >= 100 { return .charged }
            let limitOK = enabled && (limit ?? 0) > 0
            let holdReason = ((notChargingReason ?? 0) & 0x0100_0000) != 0
            if limitOK, (percent ?? 0) >= (limit ?? 0) || holdReason {
                return .holding(limit: limit ?? 0)
            }
            return .notCharging
        }
        // No AC: the pack is supplying the machine unless the current reads >= 0
        // (idle / no reading) — word that generically as "on battery".
        if let a = amperage, a < 0 { return .discharging }
        return .onBattery
    }
}

/// Map an `AppleSmartBattery` property bag to a `BatteryInfo`.
///
/// Pure and IOKit-free: the live path (`readBattery()`) feeds it the service's
/// `CFProperties` dictionary, and tests feed it equivalent fixtures directly.
/// Values may arrive as `NSNumber` (IOKit) or natively bridged `Int`/`Bool`
/// (fixtures), so the accessors tolerate both. `present` reflects whether the
/// bag carried any keys at all.
///
/// `pack` is the optional `AppleSmartBatteryPack` child-service bag. Only the
/// pack-specific readings (`hardwarePercent`, `temperatureCelsius`) are taken
/// from it; the `AppleSmartBattery` values (notably `percent`) are left
/// untouched, so charge-limit logic and the status machine are unaffected.
func parseSmartBattery(_ properties: [String: Any], pack: [String: Any]? = nil) -> BatteryInfo {
    var info = BatteryInfo()

    func int(_ key: String, _ d: [String: Any]) -> Int? {
        if let i = d[key] as? Int { return i }
        if let n = d[key] as? NSNumber { return Int(n.int64Value) }
        return nil
    }
    func bool(_ key: String, _ d: [String: Any]) -> Bool? {
        if let b = d[key] as? Bool { return b }
        if let n = d[key] as? NSNumber { return n.boolValue }
        return nil
    }

    info.present = !properties.isEmpty
    info.installed = bool("BatteryInstalled", properties) ?? true
    info.cycleCount = int("CycleCount", properties)
    info.externalConnected = bool("ExternalConnected", properties) ?? false
    info.isCharging = bool("IsCharging", properties) ?? false
    info.fullyCharged = bool("FullyCharged", properties) ?? false
    info.amperage = int("Amperage", properties)

    if let bd = properties["BatteryData"] as? [String: Any] {
        info.designCapacity = int("DesignCapacity", bd)
        info.fullChargeCapacity = int("FullChargeCapacity", bd)
    } else if let design = int("DesignCapacity", properties) {
        info.designCapacity = design
        info.fullChargeCapacity = int("FullChargeCapacity", properties) ?? int("MaxCapacity", properties)
    }

    if let cd = properties["ChargerData"] as? [String: Any] {
        info.notChargingReason = int("NotChargingReason", cd)
    }

    if let cur = int("CurrentCapacity", properties),
       let maxc = int("MaxCapacity", properties), maxc > 0 {
        let raw = Int((Double(cur) / Double(maxc) * 100).rounded())
        info.percent = max(0, min(100, raw))
    }

    if let pack, !pack.isEmpty {
        // On macOS 27 / Apple silicon the useful pack keys live inside the
        // pack's nested `BatteryData`; accept top-level keys too so a different
        // OS layout still parses. Top-level wins when both are present.
        let pd = pack["BatteryData"] as? [String: Any] ?? [:]
        func pint(_ key: String) -> Int? { int(key, pack) ?? int(key, pd) }

        // 0xFFFF (65535) is the gauge's "unknown", the same sentinel this driver
        // uses for e.g. AvgTimeToEmpty. A capacity that is non-positive or at/above
        // it is unavailable, never a value to divide by.
        func plausible(_ v: Int) -> Bool { v > 0 && v < 0xFFFF }

        // Hardware percent: raw gauge capacities, else the macOS-style
        // remaining/full pair. Both must be plausible, so a sentinel capacity
        // cannot fabricate a rate; the over-full clamp still applies.
        if let cur = pint("AppleRawCurrentCapacity"), let maxc = pint("AppleRawMaxCapacity"),
           plausible(cur), plausible(maxc) {
            info.hardwarePercent = clampPercent(Double(cur) / Double(maxc) * 100)
        } else if let rem = pint("RemainingCapacity"), let full = pint("FullChargeCapacity"),
                  plausible(rem), plausible(full) {
            info.hardwarePercent = clampPercent(Double(rem) / Double(full) * 100)
        }

        // Temperature is centi-°C (3429 -> 34.29 °C). Only exactly 0 is the
        // gauge's "unavailable" sentinel; a cold-soaked pack legitimately reads
        // below zero, so negatives down to a physical floor are kept. Fall back
        // to VirtualTemperature, and treat any remaining 0 or out-of-band value
        // as nil rather than a fabricated 0.0 °C.
        if let centi = [pint("Temperature"), pint("VirtualTemperature")]
            .compactMap({ $0 }).first(where: { $0 != 0 && (-4000...12000).contains($0) }) {
            info.temperatureCelsius = Double(centi) / 100.0
        }
    }

    // Adapter wattage: inspect sources in order using validity predicate (w > 0 && w < 0xFFFF && w <= 500),
    // fully decoupling container/dictionary presence from wattage validity.
    func plausibleAdapterWatts(_ w: Int?) -> Bool {
        guard let w else { return false }
        return w > 0 && w < 0xFFFF && w <= 500
    }

    var adapterWatts: Int? = nil

    // 1. First inspect AdapterDetails["Watts"]. If valid, accept it.
    if let ad = properties["AdapterDetails"] as? [String: Any],
       let w = int("Watts", ad), plausibleAdapterWatts(w) {
        adapterWatts = w
    }

    // 2. If not resolved, inspect AppleRawAdapterDetails as an array:
    //    - If BestAdapterIndex points to a valid adapter, accept it.
    //    - Otherwise, find the first entry in the array with valid Watts.
    if adapterWatts == nil, let rawList = properties["AppleRawAdapterDetails"] as? [[String: Any]] {
        let index = int("BestAdapterIndex", properties) ?? -1
        if index >= 0 && index < rawList.count,
           let w = int("Watts", rawList[index]), plausibleAdapterWatts(w) {
            adapterWatts = w
        } else if let validAdapter = rawList.first(where: { plausibleAdapterWatts(int("Watts", $0)) }),
                  let w = int("Watts", validAdapter) {
            adapterWatts = w
        }
    }

    // 3. If not resolved, inspect AppleRawAdapterDetails as a dictionary for valid Watts.
    if adapterWatts == nil, let rawDict = properties["AppleRawAdapterDetails"] as? [String: Any],
       let w = int("Watts", rawDict), plausibleAdapterWatts(w) {
        adapterWatts = w
    }

    // 4. If not resolved, inspect top-level AdapterWatts or Watts.
    if adapterWatts == nil {
        if let w = int("AdapterWatts", properties), plausibleAdapterWatts(w) {
            adapterWatts = w
        } else if let w = int("Watts", properties), plausibleAdapterWatts(w) {
            adapterWatts = w
        }
    }

    // Power telemetry: SystemPowerIn, SystemLoad, and BatteryPower in mW.
    let ptd = properties["PowerTelemetryData"] as? [String: Any]

    func plausiblePowerMW(_ v: Int?) -> Bool {
        guard let v else { return false }
        return v >= 0 && v != 0xFFFF && v != 0xFFFFFFFF && v <= 500_000
    }

    func plausibleVoltageMV(_ v: Int?) -> Bool {
        guard let v else { return false }
        return v > 0 && v != 0xFFFF && v != 0xFFFFFFFF && v <= 50_000
    }

    func plausibleAmperageMA(_ a: Int?) -> Bool {
        guard let a else { return false }
        return a != 0xFFFF && a != -0xFFFF && a != 0x7FFF && a != -0x8000 && abs(a) <= 50_000
    }

    func roundWatts(_ watts: Double) -> Double {
        let rounded = (watts * 10).rounded() / 10.0
        return rounded == 0.0 ? 0.0 : rounded
    }

    var systemPowerInWatts: Double? = nil
    if let mw = int("SystemPowerIn", ptd ?? [:]) ?? int("SystemPowerIn", properties),
       plausiblePowerMW(mw) {
        systemPowerInWatts = roundWatts(Double(mw) / 1000.0)
    }

    var batteryPowerWatts: Double? = nil
    let voltage = int("Voltage", properties) ?? int("AppleRawBatteryVoltage", properties)
    let amperage = int("Amperage", properties) ?? int("InstantAmperage", properties)

    if let v = voltage, let a = amperage, plausibleVoltageMV(v), plausibleAmperageMA(a) {
        let rawWatts = (Double(v) * Double(a)) / 1_000_000.0
        if abs(rawWatts) < 0.05 {
            batteryPowerWatts = 0.0
        } else {
            batteryPowerWatts = roundWatts(rawWatts)
        }
    } else if let bp = int("BatteryPower", ptd ?? [:]) ?? int("BatteryPower", properties),
              bp != 0xFFFF && abs(bp) <= 500_000 {
        let rawWatts = Double(bp) / 1000.0
        if abs(rawWatts) < 0.05 {
            batteryPowerWatts = 0.0
        } else {
            batteryPowerWatts = roundWatts(rawWatts)
        }
    }

    var systemLoadWatts: Double? = nil
    if let sl = int("SystemLoad", ptd ?? [:]) ?? int("SystemLoad", properties),
       plausiblePowerMW(sl) {
        systemLoadWatts = roundWatts(Double(sl) / 1000.0)
    } else if !info.externalConnected, let bp = batteryPowerWatts {
        // Pure battery discharge when unplugged from AC
        systemLoadWatts = roundWatts(abs(bp))
    } else if let pin = systemPowerInWatts, let bp = batteryPowerWatts {
        // On AC: P_load = P_in - P_bat (handles both charging bp > 0 and assist/drain bp < 0)
        systemLoadWatts = roundWatts(max(0.0, pin - bp))
    }

    // When unplugged on battery, input from external power source is 0.0 W.
    if !info.externalConnected && (systemLoadWatts != nil || batteryPowerWatts != nil) {
        systemPowerInWatts = 0.0
    }

    let flow = PowerFlow(
        adapterWatts: adapterWatts,
        systemPowerInWatts: systemPowerInWatts,
        systemLoadWatts: systemLoadWatts,
        batteryPowerWatts: batteryPowerWatts
    )
    if flow.hasData {
        info.powerFlow = flow
    }

    return info
}

/// One-decimal percent, clamped to 0...100. `nil` inputs are the caller's job.
private func clampPercent(_ value: Double) -> Double {
    let rounded = (max(0, min(100, value)) * 10).rounded() / 10
    return rounded
}

func readBattery() -> BatteryInfo {
    var info = BatteryInfo()
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return info }
    defer { IOObjectRelease(service) }

    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any]
    else { return info }

    info = parseSmartBattery(dict, pack: readBatteryPackProperties())
    info.present = true   // a live service answered: the pack is present regardless
    return info
}

/// Read the `AppleSmartBatteryPack` child service (macOS 27+ / Apple silicon).
///
/// The pack is a separate registry node under `AppleSmartBattery` and is the
/// only place the raw capacities and gauge temperature live. Returns `nil` when
/// the node or its properties are unavailable (Intel Macs, older macOS), which
/// the parser treats as "no extra readings" — never as zero.
///
/// Single-pack assumption: `IOServiceGetMatchingService` with a name match
/// returns only the first `AppleSmartBatteryPack` node, so this reports one
/// pack. A dual-battery Mac (two independent packs, e.g. some older 15"/17"
/// models with two service nodes) is untested here and would need a match-all
/// walk to enumerate every pack; today the first pack is used and any others
/// are ignored. On the Apple-silicon machines this feature targets there is a
/// single pack node.
func readBatteryPackProperties() -> [String: Any]? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBatteryPack"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any]
    else { return nil }
    return dict
}
