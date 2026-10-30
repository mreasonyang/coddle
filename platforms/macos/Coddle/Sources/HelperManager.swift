import Foundation
import Darwin
import IOKit
import CryptoKit

@_silgen_name("IOPMFeatureIsAvailable")
private func coddle_IOPMFeatureIsAvailable(_ feature: CFString, _ powerSource: CFString?) -> DarwinBoolean

/// macOS system Energy Mode (`pmset -a powermode 0|1|2`).
enum EnergyMode: Int, CaseIterable, Identifiable, Sendable {
    case automatic = 0
    case lowPower = 1
    case highPower = 2

    var id: Int { rawValue }

    var localizationKey: String {
        switch self {
        case .automatic: return "energyMode.auto"
        case .lowPower:  return "energyMode.low"
        case .highPower: return "energyMode.high"
        }
    }

    var iconName: String {
        switch self {
        case .automatic: return "sparkles"
        case .lowPower:  return "leaf.fill"
        case .highPower: return "bolt.fill"
        }
    }
}

/// Error surfaced by the privileged helper. `message` is safe to show in the UI.
struct HelperError: Error {
    let message: String
    var status: Int32 = 0
}

/// App-side management of Coddle's optional privileged helper.
///
/// The helper is a tiny root LaunchDaemon (`com.coddle.helper`) that can toggle
/// `pmset -a disablesleep`, which is the only supported way to keep running with
/// the lid closed and no external display. It is installed to
/// `/Library/PrivilegedHelperTools` and `/Library/LaunchDaemons` by ONE
/// `osascript ... with administrator privileges` prompt.
///
/// Hard rule: `install()` / `uninstall()` are ONLY ever called from an explicit
/// user action (the panel's Install/Remove buttons) — never at launch, never
/// automatically. Energy Mode can explicitly authorize one change without a
/// helper; other socket requests fail gracefully without prompting when absent.
enum HelperManager {
    /// Unix domain socket the daemon listens on (must match helper/main.swift).
    static let socketPath = "/var/run/com.coddle.helper.sock"
    static let label = "com.coddle.helper"
    static let installedBinary = "/Library/PrivilegedHelperTools/com.coddle.helper"
    static let installedPlist = "/Library/LaunchDaemons/com.coddle.helper.plist"

    private static let bundledBinaryName = "coddle-helper"

    // MARK: - Bundle resources

    static func bundledHelperPath() -> String? {
        if let url = Bundle.main.url(forResource: bundledBinaryName, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        let fallback = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/\(bundledBinaryName)").path
        return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
    }

    // MARK: - Status

    static func filesPresent() -> Bool {
        FileManager.default.fileExists(atPath: installedPlist) || FileManager.default.fileExists(atPath: installedBinary)
    }

    /// Ready means the LaunchDaemon plist is present AND the daemon answers.
    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: installedPlist) else { return false }
        if case .success = call("ping") { return true }
        return false
    }

    static func inspectCapabilities() -> HelperReadiness {
        guard filesPresent() else { return .absent }
        guard isInstalled() else { return .unavailable }
        guard case .success(let reply) = call("capabilities"), let capabilities = HelperCapabilities.parse(reply) else { return .outdated }
        return .ready(capabilities)
    }

    /// Wait briefly for launchd to bring the daemon up after an install.
    static func waitForHelper(seconds: Double = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if isInstalled() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    /// Pure parser for `pmset -g` output: the system-wide `SleepDisabled` flag,
    /// or nil when the line is absent (e.g. pmset failed, or the key is not
    /// reported on this OS). Real output separates the label and value with a
    /// tab (`" SleepDisabled\t\t0"`), so split on any whitespace.
    static func parseSleepDisabled(_ pmsetOutput: String) -> Bool? {
        for line in pmsetOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SleepDisabled") {
                guard let value = trimmed.split(whereSeparator: { $0.isWhitespace }).last,
                      value == "0" || value == "1" else { return nil }
                return value == "1"
            }
        }
        return nil
    }

    /// Pure parser for `pmset -g` output: the system-wide `powermode` (`0` = Automatic,
    /// `1` = Low Power, `2` = High Power), falling back to `lowpowermode` when `powermode`
    /// is absent on older/non-HighPower machines.
    static func parsePowerMode(_ pmsetOutput: String) -> EnergyMode? {
        var fallbackLowPower: EnergyMode? = nil
        for line in pmsetOutput.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0.isWhitespace })
            guard let key = parts.first, let valStr = parts.last, parts.count >= 2 else { continue }
            if key == "powermode", let raw = Int(valStr), let mode = EnergyMode(rawValue: raw) {
                return mode
            }
            if key == "lowpowermode", let raw = Int(valStr) {
                fallbackLowPower = (raw == 1) ? .lowPower : .automatic
            }
        }
        return fallbackLowPower
    }

    /// Pure reply parser. `ok` is success; a line starting with `err` is the
    /// helper's own error text; anything else (including empty) is surfaced
    /// verbatim, with an explicit message for a missing reply.
    static func parseReply(_ reply: String) -> Result<Void, HelperError> {
        if reply == "ok" { return .success(()) }
        if reply.hasPrefix("err") { return .failure(HelperError(message: reply)) }
        return .failure(HelperError(message: reply.isEmpty ? "no reply from helper" : reply))
    }

    private static func runPmsetSnapshot() -> String? {
        let result = BoundedIO.run("/usr/bin/pmset", arguments: ["-g"], timeout: 3)
        return result.status == 0 ? result.output : nil
    }

    /// Reads the system-wide `SleepDisabled` flag from `pmset -g` (no root).
    static func sleepDisabledFromPmset() -> Bool? {
        guard let text = runPmsetSnapshot() else { return nil }
        return parseSleepDisabled(text)
    }

    /// Reads the active `EnergyMode` from `pmset -g` (no root).
    static func powerModeFromPmset() -> EnergyMode? {
        if let text = runPmsetSnapshot(), let mode = parsePowerMode(text) {
            return mode
        }
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPower : nil
    }

    /// Queries `IOPMFeatureIsAvailable` to determine which Energy Modes this Mac supports.
    static func availableEnergyModes() -> [EnergyMode] {
        let lowSupported = coddle_IOPMFeatureIsAvailable("LowPowerMode" as CFString, nil).boolValue
        let highSupported = coddle_IOPMFeatureIsAvailable("HighPowerMode" as CFString, nil).boolValue
        var modes: [EnergyMode] = [.automatic]
        if lowSupported || highSupported {
            modes.append(.lowPower)
        }
        if highSupported {
            modes.append(.highPower)
        }
        return modes
    }

    // MARK: - RPC

    /// Daemon leases expire after 30 seconds; renew independently of UI refresh.
    static let leaseRenewalInterval: TimeInterval = 10

    /// Scoped readback: an external global ON must not look like our lease.
    static func parseLidState(_ response: String) -> Bool? {
        switch response {
        case "ok lid=0": return false
        case "ok lid=1": return true
        default: return nil
        }
    }

    static func lidControlActive() -> Bool? {
        guard case .success(let response) = call("lid_state") else { return nil }
        return parseLidState(response)
    }

    static func disablesleepCommand(_ on: Bool) -> String {
        on ? "lease_sleep 1" : "release_sleep"
    }

    @discardableResult
    static func setDisablesleep(_ on: Bool, request: (String) -> Result<String, HelperError> = call) -> Result<Void, HelperError> {
        let result = request(disablesleepCommand(on))
        if case .failure(let error) = result, error.message == "err unknown-command" {
            let upgrade = "Installed helper is outdated. Remove and install it again in Settings."
            return .failure(HelperError(message: upgrade))
        }
        return result.map { _ in () }
    }

    /// Changing Energy Mode authorizes only that change. Helper installation is
    /// exclusively the explicit Install action in Settings. Choose one channel
    /// before writing: a missing helper uses one-shot authorization; an installed
    /// or incomplete helper installation must report its own RPC failure. A
    /// timed-out request may still execute, so never retry it through another channel.
    @discardableResult
    static func setPowerMode(
        _ mode: Int,
        helperFilesPresent: () -> Bool = filesPresent,
        request: (String) -> Result<String, HelperError> = call,
        authorize: (String) -> Result<Void, HelperError> = runPrivileged
    ) -> Result<Void, HelperError> {
        guard let script = powerModeScript(mode) else {
            return .failure(HelperError(message: "err bad-args"))
        }
        if helperFilesPresent() {
            return request("set_powermode \(mode)").map { _ in () }
        }
        return authorize(script)
    }

    static func powerModeScript(_ mode: Int) -> String? {
        (0...2).contains(mode) ? "/usr/bin/pmset -a powermode \(mode)" : nil
    }

    /// One deadline includes connect, write and newline-terminated response.
    static func call(_ command: String) -> Result<String, HelperError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(HelperError(message: "socket() failed")) }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        BoundedIO.nonblocking(fd)
        let deadline = BoundedIO.now + 2
        var address = sockaddr_un()
        let length = fillSockaddr(&address, socketPath)
        guard length > 0 else { return .failure(HelperError(message: "socket path too long")) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS,
                  BoundedIO.ready(fd, events: Int16(POLLOUT), until: deadline) else {
                return .failure(HelperError(message: "error.helperNotRunning"))
            }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                return .failure(HelperError(message: "error.helperNotRunning"))
            }
        }
        guard BoundedIO.writeLine(fd, command, until: deadline),
              let line = BoundedIO.readLine(fd, until: deadline) else {
            return .failure(HelperError(message: "helper request timed out or invalid response"))
        }
        let reply = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if command == "capabilities", HelperCapabilities.parse(reply) != nil { return .success(reply) }
        if command == "lid_state", parseLidState(reply) != nil { return .success(reply) }
        return parseReply(reply).map { _ in reply }
    }

    // MARK: - Install / uninstall (explicit user action only)

    static func install() -> Result<Void, HelperError> {
        guard let helper = bundledHelperPath() else {
            return .failure(HelperError(message: "helper binary missing from app bundle"))
        }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: helper)) else {
            return .failure(HelperError(message: "helper binary cannot be read"))
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return runPrivileged(installationScript(helper: helper, sha256: digest))
    }

    /// The staged bytes must match those selected before authorization. The
    /// fixed plist cannot redirect launchd through a mutable bundle resource.
    /// An ad-hoc signature provides integrity, not publisher authentication.
    static func installationScript(helper: String, sha256: String) -> String {
        """
        set -eu
        /bin/mkdir -p /Library/PrivilegedHelperTools
        stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.coddle-install.XXXXXX)
        trap '/bin/rm -rf "$stage"' EXIT
        /bin/chmod 700 "$stage"
        /usr/bin/install -m 755 -o root -g wheel \(shellQuote(helper)) "$stage/helper"
        actual=$(/usr/bin/shasum -a 256 "$stage/helper" | /usr/bin/awk '{print $1}')
        [ "$actual" = \(shellQuote(sha256)) ]
        /usr/bin/codesign --verify --strict --all-architectures "$stage/helper"
        /bin/cat > "$stage/helper.plist" <<'CODDLE_PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>com.coddle.helper</string>
        <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/com.coddle.helper</string></array>
        <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
        <key>ProcessType</key><string>Background</string>
        </dict></plist>
        CODDLE_PLIST
        /usr/bin/plutil -lint "$stage/helper.plist"
        /usr/bin/install -m 755 -o root -g wheel "$stage/helper" \(shellQuote(installedBinary))
        /usr/bin/codesign --verify --strict --all-architectures \(shellQuote(installedBinary))
        /usr/bin/install -m 644 -o root -g wheel "$stage/helper.plist" \(shellQuote(installedPlist))
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootstrap system \(shellQuote(installedPlist))
        /bin/launchctl kickstart -k system/\(label)
        """
    }

    static func uninstall() -> Result<Void, HelperError> {
        runPrivileged(uninstallationScript)
    }

    static let uninstallationScript = """
    set -eu
    if /bin/launchctl bootout system/\(label); then
        :
    else
        coddle_bootout_status=$?
        if /bin/launchctl print system/\(label) >/dev/null 2>&1; then
            exit "$coddle_bootout_status"
        else
            coddle_print_status=$?
            [ "$coddle_print_status" -eq 113 ] || exit "$coddle_bootout_status"
        fi
    fi
    if [ -e /var/db/com.coddle.helper.sleep-state ] || [ -L /var/db/com.coddle.helper.sleep-state ]; then
        \(shellQuote(installedBinary)) --restore-sleep
    fi
    /bin/rm -f \(shellQuote(installedPlist)) \(shellQuote(installedBinary)) \(shellQuote(socketPath))
    """

    // MARK: - Privileged shell

    /// Run `script` directly as root through `osascript ... with administrator privileges`.
    /// The script is passed via argv and executed by AppleScript directly in memory,
    /// avoiding temporary files to prevent TOCTOU local privilege escalation attacks.
    private static func runPrivileged(_ script: String) -> Result<Void, HelperError> {
        let result = BoundedIO.run("/usr/bin/osascript", arguments: [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run", script,
        ], timeout: nil) // User can cancel authorization; do not abandon a still-running root script.
        if result.status == 0 { return .success(()) }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(HelperError(message: output.isEmpty ? "administrator authorization failed" : output,
                                    status: result.status))
    }

    // MARK: - Socket helpers

    private static func fillSockaddr(_ addr: inout sockaddr_un, _ path: String) -> socklen_t {
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return 0 }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            _ = strlcpy(raw, path, capacity)
        }
        return socklen_t(MemoryLayout<sockaddr_un>.size)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
