// Policy and network regressions. All inputs are fixtures; no live network,
// preferences, power settings, or hardware APIs are accessed.
import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

func fingerprint(
    _ v4: [[String: Any]] = [], primary4: String? = nil,
    _ v6: [[String: Any]] = [], primary6: String? = nil
) -> NetworkFingerprint {
    NetworkFingerprintParser.parse(
        ipv4Primary: primary4, ipv4Services: v4,
        ipv6Primary: primary6, ipv6Services: v6)
}

// An empty/missing IPv4 service list must still reach the IPv6 parser.
let ipv6Home: [String: Any] = ["InterfaceName": "en0", "Router": "fe80::a"]
expect(fingerprint().key == nil, "no services remain unknown")
expect(fingerprint([], [ipv6Home], primary6: "en0").key == "ip6:fe80::a",
       "pure IPv6 identifies the physical network without an IPv4 service")
expect(fingerprint([["InterfaceName": "en0"]], [ipv6Home]).key == "ip6:fe80::a",
       "IPv4 service without identity falls through to IPv6")

// Preserve all existing IPv4 key formats so persisted dwell/manual entries work.
let ipv4Home: [String: Any] = [
    "InterfaceName": "en0", "ARPResolvedHardwareAddress": "AA:BB:CC:DD:EE:FF",
    "NetworkSignatureHash": Data([0xab, 0xcd]), "NetworkSignature": "signature",
    "Router": "192.0.2.1", "SubnetMasks": ["255.255.255.0"]
]
expect(fingerprint([ipv4Home], [ipv6Home]).key == "mac:aa:bb:cc:dd:ee:ff",
       "IPv4 remains preferred and MAC encoding remains compatible")
expect(fingerprint([["InterfaceName": "en0", "NetworkSignatureHash": Data([0, 0xab, 0xff])]]).key == "sig:00abff",
       "IPv4 signature hash encoding remains compatible")
expect(fingerprint([["InterfaceName": "en0", "NetworkSignature": "IPv4.Router=192.0.2.1"]]).key == "str:IPv4.Router=192.0.2.1",
       "IPv4 signature encoding remains compatible")
expect(fingerprint([["InterfaceName": "en0", "Router": "192.0.2.1", "SubnetMasks": ["255.255.255.0"]]]).key == "ip:192.0.2.1/255.255.255.0",
       "IPv4 router/subnet encoding remains compatible")
expect(fingerprint([["InterfaceName": "en0", "Router": "192.0.2.1"]]).key == "ip:192.0.2.1/",
       "IPv4 router without subnet retains its previous encoding")

let ethernet: [String: Any] = ["InterfaceName": "en1", "ARPResolvedHardwareAddress": "11:22:33:44:55:66"]
expect(fingerprint([ipv4Home, ethernet], primary4: "en0").key == "mac:aa:bb:cc:dd:ee:ff",
       "physical IPv4 primary is preferred over another interface")
expect(fingerprint([ipv4Home, ethernet], primary4: "en1").key == "mac:11:22:33:44:55:66",
       "physical IPv4 primary is selected independent of array order")
expect(fingerprint([ipv4Home, ethernet]).key == "mac:aa:bb:cc:dd:ee:ff",
       "IPv4 fallback is stable by physical interface rather than service order")
expect(fingerprint([], [ipv6Home, ["InterfaceName": "en1", "Router": "fe80::b"]], primary6: "en1").key == "ip6:fe80::b",
       "IPv6 physical primary is preferred")

// Tunnels are a status flag, never a network identity or a substitute for IPv6.
for tunnel in ["utun3", "ipsec0", "ppp0"] {
    let service: [String: Any] = ["InterfaceName": tunnel, "Router": "198.51.100.1"]
    let v4VPN = fingerprint([ipv4Home, service], primary4: tunnel)
    expect(v4VPN.key == "mac:aa:bb:cc:dd:ee:ff" && v4VPN.vpnActive,
           "\(tunnel) IPv4 primary preserves the physical fingerprint")
    let v6VPN = fingerprint([service], primary4: tunnel, [ipv6Home], primary6: tunnel)
    expect(v6VPN.key == "ip6:fe80::a" && v6VPN.vpnActive,
           "tunnel-only IPv4 does not prevent IPv6 fallback for \(tunnel)")
    let onlyTunnel = fingerprint([], [service], primary6: tunnel)
    expect(onlyTunnel.key == nil && onlyTunnel.vpnActive,
           "\(tunnel) IPv6 service cannot become a physical network")
}
expect(!fingerprint([ipv4Home], primary4: "en0", [ipv6Home], primary6: "en0").vpnActive,
       "physical primaries do not set VPN status")

// A VPN can hide either physical primary without changing the actual network.
// The previous selected key is useful only if it still occurs in a live service.
for physicalPrimary in ["en0", "en1"] {
    let before = fingerprint([ipv4Home, ethernet], primary4: physicalPrimary)
    for services in [[ipv4Home, ethernet], [ethernet, ipv4Home]] {
        let vpn = NetworkFingerprintParser.parse(ipv4Primary: "utun3", ipv4Services: services,
            ipv6Primary: nil, ipv6Services: [], preferredPhysicalKey: before.key)
        expect(vpn.key == before.key && vpn.vpnActive,
               "VPN preserves \(physicalPrimary) regardless of service enumeration")
        var away = AwayDetector()
        away.config.usualFingerprints = [before.key!]
        let start = Date(timeIntervalSince1970: 2_000)
        _ = away.sample(key: before.key, now: start)
        expect(!away.sample(key: vpn.key, now: start.addingTimeInterval(1200)).isAway,
               "VPN-only transition does not release bag-guard keep-awake")
    }
}
let disappeared = NetworkFingerprintParser.parse(ipv4Primary: "utun3", ipv4Services: [ethernet],
    ipv6Primary: nil, ipv6Services: [], preferredPhysicalKey: "mac:aa:bb:cc:dd:ee:ff")
expect(disappeared.key == "mac:11:22:33:44:55:66",
       "disconnected previous network is not retained just because VPN is active")
let newPrimary = NetworkFingerprintParser.parse(ipv4Primary: "en1", ipv4Services: [ipv4Home, ethernet],
    ipv6Primary: nil, ipv6Services: [], preferredPhysicalKey: "mac:aa:bb:cc:dd:ee:ff")
expect(newPrimary.key == "mac:11:22:33:44:55:66", "real primary change overrides prior selection")
let ipv6Other: [String: Any] = ["InterfaceName": "en1", "Router": "fe80::b"]
let vpn6 = NetworkFingerprintParser.parse(ipv4Primary: nil, ipv4Services: [],
    ipv6Primary: "utun4", ipv6Services: [ipv6Home, ipv6Other], preferredPhysicalKey: "ip6:fe80::b")
expect(vpn6.key == "ip6:fe80::b" && vpn6.vpnActive, "IPv6-only VPN retains its physical network")
expect(fingerprint([ethernet, ipv4Home]).key == fingerprint([ipv4Home, ethernet]).key,
       "cold-start fallback does not depend on service UUID ordering")

// Routerless IPv6 can use a real signature, but not the machine's interface name.
expect(fingerprint([], [["InterfaceName": "en0", "NetworkSignatureHash": Data([1, 2])]]).key == "sig:0102",
       "routerless IPv6 can use a network signature hash")
expect(fingerprint([], [["InterfaceName": "en0", "NetworkSignature": "network-a"]]).key == "str:network-a",
       "routerless IPv6 can use a network signature")
let unknownHome = fingerprint([], [["InterfaceName": "en0", "Addresses": ["2001:db8:a::1"]]])
let unknownCafe = fingerprint([], [["InterfaceName": "en0", "Addresses": ["2001:db8:b::1"]]])
expect(unknownHome.key == nil && unknownCafe.key == nil,
       "two unidentified IPv6 networks never share an if6:en0 identity")
let emptyIdentity: [String: Any] = [
    "InterfaceName": "en0", "Router": "", "NetworkSignature": "",
    "ARPResolvedHardwareAddress": "", "NetworkSignatureHash": Data()
]
expect(fingerprint([emptyIdentity], [emptyIdentity]).key == nil,
       "empty identity fields cannot create a shared usual network")
expect(fingerprint([["InterfaceName": "en0", "Router": 123]], [["Router": "fe80::a"]]).key == nil,
       "wrong-typed or missing service fields remain unknown")

// Prove the parser output cannot teach the detector that the same NIC is home.
let t0 = Date(timeIntervalSince1970: 1_000)
var detector = AwayDetector()
detector.config.usualMinDwellSeconds = 60
_ = detector.sample(key: unknownHome.key, now: t0)
detector.creditDwell(now: t0.addingTimeInterval(120), capSeconds: 120)
let unknownVerdict = detector.sample(key: unknownCafe.key, now: t0.addingTimeInterval(120))
expect(detector.dwell.isEmpty && detector.usualSet().isEmpty && !unknownVerdict.isUsual,
       "routerless samples never accumulate learned dwell under an interface key")
detector.load(dwell: ["if6:en0": 7200]) // persisted data from the old implementation
expect(!detector.sample(key: unknownHome.key, now: t0.addingTimeInterval(150)).isUsual,
       "an obsolete learned interface key cannot identify an unknown network")
expect(detector.sample(key: unknownCafe.key, now: t0.addingTimeInterval(1200)).isAway,
       "unknown IPv6 retains the existing offline safety backstop")

// Sparse hourly profiles must not fabricate an AC-to-battery transition.
func observedMorningUnplug() -> SmartPolicy.Profile {
    var p = SmartPolicy.Profile()
    for h in 0...8 { p.total[h] = 10; p.ac[h] = 10 }
    p.total[9] = 10; p.ac[9] = 1
    for h in 10...11 { p.total[h] = 10 }
    // Noon sleep/quit: hours 12 and 13 have no observations.
    for h in 14...17 { p.total[h] = 10 }
    for h in 18...23 { p.total[h] = 10; p.ac[h] = 10 }
    return p
}
var p = observedMorningUnplug()
expect(p.predictedUnplugHour(minSamples: 5) == 9,
       "a lunch observation gap cannot overpower the observed 09:00 unplug")
expect(SmartPolicy().decide(hour: 8, profile: p).target == 100,
       "the actual morning unplug still receives a pre-unplug top-up")
p.total[13] = 1; p.ac[13] = 1
expect(p.predictedUnplugHour(minSamples: 5) == 9,
       "an under-sampled preceding hour cannot establish a stronger transition")
p.total[13] = 5; p.ac[13] = 5
expect(p.predictedUnplugHour(minSamples: 5) == 14,
       "a preceding hour reaching the sample threshold can establish a transition")

var midnight = SmartPolicy.Profile()
midnight.total[23] = 5; midnight.ac[23] = 5
midnight.total[0] = 5; midnight.ac[0] = 1
midnight.total[1] = 5
expect(midnight.predictedUnplugHour(minSamples: 5) == 0,
       "trusted transition calculation wraps from hour 23 to 0")
expect(SmartPolicy().decide(hour: 23, profile: midnight).target == 100,
       "midnight unplug retains its previous-day top-up window")
p = observedMorningUnplug()
p.total[23] = 0; p.ac[23] = 0
p.total[0] = 10; p.ac[0] = 0
expect(p.predictedUnplugHour(minSamples: 5) == 9,
       "missing hour 23 cannot fabricate a midnight transition")

var sparse = SmartPolicy.Profile()
sparse.total[4] = 5; sparse.ac[4] = 1
sparse.total[12] = 5
sparse.total[20] = 10
expect(sparse.predictedUnplugHour(minSamples: 5) == 20,
       "without trusted transitions, sparse data falls back to lowest AC and confidence")
expect(sparse.predictedUnplugHour(minSamples: 11) == nil,
       "insufficient current-hour samples still yield no prediction")
var alwaysAC = SmartPolicy.Profile()
for h in 0..<24 { alwaysAC.total[h] = 10; alwaysAC.ac[h] = 10 }
expect(alwaysAC.predictedUnplugHour(minSamples: 5) == nil,
       "always-plugged-in usage still never predicts an unplug")

print("coddle-policy-tests: \(checks) checks passed")
