import Foundation

struct HelperCapabilities: Equatable, Sendable {
    static let response = "ok protocol=1 version=2 capabilities=lease_disablesleep,set_disablesleep,set_powermode"
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
        (!lid || features.isSuperset(of: ["lease_disablesleep", "set_disablesleep"])) &&
        (!energy || features.contains("set_powermode"))
    }
}

enum HelperReadiness: Equatable, Sendable {
    case absent, unavailable, outdated, ready(HelperCapabilities)
    var capabilities: HelperCapabilities? { if case .ready(let c) = self { return c }; return nil }
}

/// Pure command dispatch for the privileged helper (see `helper/main.swift`).
///
/// The one side-effecting operation — `pmset -a disablesleep` — is injected so
/// the dispatch can be unit-tested without root or a real power-management
/// change; the daemon passes its own `runPmset`. Arguments are whitelisted to
/// the literal `0` / `1`, so there is no arbitrary command execution.
///
/// Returns `ok` on success or `err <msg>` on any failure:
///   * `ping`                 -> `ok`
///   * `set_disablesleep 0`   -> safe legacy OFF
///   * `lease_disablesleep 1` -> renewable ON; rejects legacy unbounded ON
///   * bad arity/argument     -> `err bad-args`
///   * empty line             -> `err empty-command`
///   * anything else          -> `err unknown-command`
func handleCommand(
    _ line: String,
    runPmset: ([String]) -> (status: Int32, output: String),
    enableLease: (() -> String)? = nil
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
        let (status, output) = runPmset(["-a", "disablesleep", "0"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 ? "ok" : "err rc=\(status) \(trimmed)"

    case "lease_disablesleep":
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
