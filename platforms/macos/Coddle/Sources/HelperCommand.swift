import Foundation

struct HelperCapabilities: Equatable, Sendable {
    static let response = "ok protocol=1 version=3 capabilities=lease_disablesleep,set_disablesleep,set_powermode,preserve_sleep,lid_state"
    var protocolVersion: Int
    var componentVersion: Int
    var features: Set<String>
    static func parse(_ response: String) -> HelperCapabilities? {
        let parts = response.split(separator: " ").map(String.init)
        guard parts.count == 4, parts[0] == "ok",
              parts[1].hasPrefix("protocol="), parts[2].hasPrefix("version="),
              parts[3].hasPrefix("capabilities="),
              let proto = Int(parts[1].dropFirst(9)), proto == 1,
              let version = Int(parts[2].dropFirst(8)), version > 0 else { return nil }
        return HelperCapabilities(protocolVersion: proto, componentVersion: version,
            features: Set(parts[3].dropFirst(13).split(separator: ",").map(String.init)))
    }
    func supports(lid: Bool, energy: Bool) -> Bool {
        (!lid || features.isSuperset(of: ["preserve_sleep", "lid_state"])) &&
        (!energy || features.contains("set_powermode"))
    }
}

enum HelperReadiness: Equatable, Sendable {
    case absent, unavailable, outdated, ready(HelperCapabilities)
    var capabilities: HelperCapabilities? { if case .ready(let c) = self { return c }; return nil }
}

/// Pure command dispatch for the privileged helper (see `helper/main.swift`).
///
/// Energy writes and sleep lease operations are injected independently so the
/// dispatcher cannot bypass durable ownership when releasing sleep control.
///
/// Returns `ok` on success or `err <msg>` on any failure:
///   * `ping`                 -> `ok`
///   * `set_disablesleep 0`   -> release only a recorded Coddle lease
///   * `lease_disablesleep 1` -> renewable ON; rejects legacy unbounded ON
///   * `lease_sleep 1`        -> state-preserving ON (requires helper v3)
///   * `release_sleep`        -> restore this helper's recorded baseline
///   * `lid_state`            -> verified Coddle lease, excluding external ON
///   * bad arity/argument     -> `err bad-args`
///   * empty line             -> `err empty-command`
///   * anything else          -> `err unknown-command`
func handleCommand(
    _ line: String,
    runPmset: ([String]) -> (status: Int32, output: String),
    enableLease: (() -> String)? = nil,
    releaseLease: (() -> String)? = nil,
    leaseStatus: (() -> String)? = nil
) -> String {
    let parts = line
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)

    guard let command = parts.first else { return "err empty-command" }

    switch command {
    case "capabilities":
        guard parts.count == 1 else { return "err bad-args" }
        return HelperCapabilities.response
    case "ping":
        guard parts.count == 1 else { return "err bad-args" }
        return "ok"

    case "set_disablesleep":
        guard parts.count == 2, parts[1] == "0" || parts[1] == "1" else {
            return "err bad-args"
        }
        guard parts[1] == "0" else { return "err lease-required" }
        return releaseLease?() ?? "err lease-required"

    case "release_sleep":
        guard parts.count == 1 else { return "err bad-args" }
        return releaseLease?() ?? "err lease-required"
    case "lid_state":
        guard parts.count == 1 else { return "err bad-args" }
        return leaseStatus?() ?? "err state-unconfirmed"
    case "lease_sleep", "lease_disablesleep":
        guard parts.count == 2, parts[1] == "1" else { return "err bad-args" }
        return enableLease?() ?? "err lease-required"

    case "set_powermode":
        guard parts.count == 2, parts[1] == "0" || parts[1] == "1" || parts[1] == "2" else {
            return "err bad-args"
        }
        let (status, output) = runPmset(["-a", "powermode", parts[1]])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 ? "ok" : "err rc=\(status) \(trimmed)"

    default:
        return "err unknown-command"
    }
}
