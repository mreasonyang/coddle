// Read-only hardware smoke with explicit assertions. Missing hardware is a
// supported capability result, not a reason to suppress all process failures.
import Foundation

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

let b = readBattery()
let supported = PowerUI.isSupported
let limits = PowerUI.availableLimits()
let limit = PowerUI.current()
print("battery present : \(b.present)")
print("percent         : \(b.percent.map(String.init) ?? "n/a")")
print("state           : \(b.chargeStatus(limit: limit?.limit, enabled: limit?.enabled ?? false))")
print("externalConnected: \(b.externalConnected)")
print("cycles          : \(b.cycleCount.map(String.init) ?? "n/a")")
print("health          : \(b.healthPercent.map { String(format: "%.1f%%", $0) } ?? "n/a")")
print("hardwarePercent : \(b.hardwarePercent.map { String(format: "%.1f%%", $0) } ?? "n/a")")
print("temperature     : \(b.temperatureCelsius.map { String(format: "%.2f °C", $0) } ?? "n/a")")
if let flow = b.powerFlow {
    print("powerFlow       : in=\(flow.systemPowerInWatts.map { "\($0)W" } ?? "n/a") load=\(flow.systemLoadWatts.map { "\($0)W" } ?? "n/a") battery=\(flow.batteryPowerWatts.map { "\($0)W" } ?? "n/a") adapter=\(flow.adapterWatts.map { "\($0)W" } ?? "n/a")")
} else {
    print("powerFlow       : unavailable")
}
print("MCL supported   : \(supported)")
print("available limits: \(limits)")
if let percent = b.percent { require((0...100).contains(percent), "battery percent outside 0...100") }
if let cycles = b.cycleCount { require(cycles >= 0, "negative battery cycles") }
if let hw = b.hardwarePercent { require((0.0...100.0).contains(hw), "hardware percent outside 0...100") }
if let temp = b.temperatureCelsius { require((-40.0...120.0).contains(temp), "implausible battery temperature was surfaced") }
if let flow = b.powerFlow {
    if let w = flow.adapterWatts { require((1...500).contains(w), "implausible adapter watts") }
    if let inWatts = flow.systemPowerInWatts { require(inWatts >= 0 && inWatts <= 500, "implausible system power in") }
    if let load = flow.systemLoadWatts { require(load >= 0 && load <= 500, "implausible system load") }
    if let bp = flow.batteryPowerWatts { require(abs(bp) <= 500, "implausible battery power") }
}
if supported {
    require(!limits.isEmpty && limits.allSatisfy { (1...100).contains($0) }, "supported PowerUI has invalid/empty limits")
    require(limit != nil, "supported PowerUI failed to read its current limit")
}
if let limit {
    require((0...100).contains(limit.limit), "native limit outside 0...100")
    print("current limit   : \(limit.limit)% (enabled=\(limit.enabled))")
} else { print("current limit   : unavailable (unsupported capability)") }
// Do not load/create/repair the user's config during a read-only smoke test.
var config = CoddleConfig(); config.holdLimit = 85; config.theme = "classic"
let data = try JSONEncoder().encode(config)
let decoded = ConfigStore.decode(data)
require(decoded?.holdLimit == 85 && decoded?.theme == "classic", "config round-trip failed")
if CommandLine.arguments.contains("--require-battery") { require(b.present, "expected a real battery") }
if CommandLine.arguments.contains("--require-powerui") { require(supported, "expected native charge-limit support") }
print("coddle-selftest: PASS (read-only)")
