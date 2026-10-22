import Foundation

/// A physical network identity. A missing key means offline or not enough
/// network information to identify it; an interface name alone is not an identity.
struct NetworkFingerprint: Equatable, Sendable {
    var key: String? = nil
    var vpnActive: Bool = false
}

/// Pure interpretation of SystemConfiguration service snapshots. The live
/// reader and fixture tests use this same path, without requiring network changes.
enum NetworkFingerprintParser {
    static func parse(
        ipv4Primary: String?,
        ipv4Services: [[String: Any]],
        ipv6Primary: String?,
        ipv6Services: [[String: Any]],
        preferredPhysicalKey: String? = nil
    ) -> NetworkFingerprint {
        let ipv4Key = selectedKey(primary: ipv4Primary, services: ipv4Services, ipv6: false,
                                  preferredKey: preferredPhysicalKey)
        let ipv6Key = selectedKey(primary: ipv6Primary, services: ipv6Services, ipv6: true,
                                  preferredKey: preferredPhysicalKey)
        return NetworkFingerprint(
            key: ipv4Key ?? ipv6Key,
            vpnActive: isTunnel(ipv4Primary) || isTunnel(ipv6Primary))
    }

    private static func isTunnel(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }

    private static func selectedKey(
        primary: String?, services: [[String: Any]], ipv6: Bool, preferredKey: String?
    ) -> String? {
        let candidates: [(name: String, key: String)] = services.compactMap { service in
            guard let name = service["InterfaceName"] as? String,
                  networkFingerprintIsPhysical(name),
                  let key = identity(service, ipv6: ipv6) else { return nil }
            return (name, key)
        }
        // A real physical primary remains authoritative. When a VPN hides it,
        // keep the last identity only while that physical network still exists.
        if let primary, let match = candidates.first(where: { $0.name == primary }) {
            return match.key
        }
        if isTunnel(primary), let preferredKey,
           candidates.contains(where: { $0.key == preferredKey }) {
            return preferredKey
        }
        // With no usable history, choose deterministically by interface/identity,
        // not by SystemConfiguration's service UUID enumeration order.
        return candidates.sorted {
            $0.name == $1.name ? $0.key < $1.key : $0.name < $1.name
        }.first?.key
    }

    private static func identity(_ service: [String: Any], ipv6: Bool) -> String? {
        if let mac = service["ARPResolvedHardwareAddress"] as? String, !mac.isEmpty {
            return "mac:\(mac.lowercased())"
        }
        if let hash = service["NetworkSignatureHash"] as? Data, !hash.isEmpty {
            return "sig:" + hash.map { String(format: "%02x", $0) }.joined()
        }
        if let signature = service["NetworkSignature"] as? String, !signature.isEmpty {
            return "str:\(signature)"
        }
        guard let router = service["Router"] as? String, !router.isEmpty else { return nil }
        if ipv6 { return "ip6:\(router)" }
        let subnets = service["SubnetMasks"] as? [String]
        return "ip:\(router)/\(subnets?.first ?? "")"
    }
}
