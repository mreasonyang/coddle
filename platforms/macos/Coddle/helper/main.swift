// coddle-helper: bounded privileged RPCs and expiring lid-closed lease.
import Foundation
import Darwin

// MARK: - Configuration

let environment = ProcessInfo.processInfo.environment

/// Testing escape hatch: let the binary run as a normal user. Production
/// installations never set this, so the daemon refuses to run unprivileged.
#if CODDLE_HELPER_TESTING
let allowNonRoot = environment["CODDLE_HELPER_ALLOW_NONROOT"] == "1"
#else
let allowNonRoot = false
#endif
/// Testing escape hatch: route commands without actually invoking `pmset`.
#if CODDLE_HELPER_TESTING
let dryRun = environment["CODDLE_HELPER_DRYRUN"] == "1"
#else
let dryRun = false
#endif

/// Socket path: argv[1] wins, then $CODDLE_HELPER_SOCK (if unprivileged/test), then the default.
var socketPath = "/var/run/com.coddle.helper.sock"
if allowNonRoot || geteuid() != 0 {
    if let env = environment["CODDLE_HELPER_SOCK"], !env.isEmpty {
        socketPath = env
    }
}
if allowNonRoot && CommandLine.arguments.count > 1 {
    let arg = CommandLine.arguments[1]
    if !arg.isEmpty { socketPath = arg }
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
}

func fatal(_ message: String) -> Never {
    writeStderr("coddle-helper: \(message)")
    exit(1)
}

// MARK: - Root check

if geteuid() != 0 && !allowNonRoot {
    fatal("must run as root (set CODDLE_HELPER_ALLOW_NONROOT=1 to override for testing)")
}

#if CODDLE_HELPER_TESTING
// The integration fixture must never be able to reach a real power write.
guard geteuid() != 0, allowNonRoot, dryRun else {
    fatal("test helper requires non-root dry-run mode")
}
#endif

// MARK: - pmset

/// Run /usr/bin/pmset with fixed, whitelisted arguments. Returns (status, output).
@Sendable
func runPmset(_ arguments: [String]) -> (status: Int32, output: String) {
    if dryRun {
        #if CODDLE_HELPER_TESTING
        // Exercise the production socket and command queues with a delayed,
        // observable write. This dependency is absent from release builds.
        guard let statePath = environment["CODDLE_HELPER_TEST_STATE"] else { return (-1, "missing test state") }
        if arguments == ["-g"] {
            if let failure = environment["CODDLE_HELPER_TEST_READ_FAILURE"], FileManager.default.fileExists(atPath: failure) {
                return (1, "fixture read failure")
            }
            let value = (try? String(contentsOfFile: statePath, encoding: .utf8)) ?? "unknown"
            return (0, " SleepDisabled\t\t\(value)\n")
        }
        guard let value = arguments.last else { return (-1, "missing test value") }
        writeStderr("test pmset begin \(value)")
        if arguments.contains("disablesleep") && value == "1" {
            let delay = Double(environment["CODDLE_HELPER_TEST_ENABLE_DELAY"] ?? "0") ?? 0
            Thread.sleep(forTimeInterval: min(10, max(0, delay)))
        }
        if value == "0", let failureFile = environment["CODDLE_HELPER_TEST_OFF_FAILURE"],
           FileManager.default.fileExists(atPath: failureFile) {
            writeStderr("test pmset fail 0")
            return (1, "fixture OFF failure")
        }
        do {
            try value.write(toFile: statePath, atomically: true, encoding: .utf8)
        } catch {
            return (-1, "test write failed")
        }
        writeStderr("test pmset end \(value)")
        #endif
        return (0, "DRYRUN pmset \(arguments.joined(separator: " "))")
    }
    return BoundedIO.run("/usr/bin/pmset", arguments: arguments, timeout: 5)
}

// MARK: - Renewable global lease

// Serialize writes and durable recovery. No journal means no state to restore.
let powerWriteQueue = DispatchQueue(label: "com.coddle.helper.power-writes")
#if CODDLE_HELPER_TESTING
let leaseDuration = min(30, max(0.2, Double(environment["CODDLE_HELPER_TEST_LEASE_SECONDS"] ?? "30") ?? 30))
guard let journalPath = environment["CODDLE_HELPER_TEST_JOURNAL"] else { fatal("missing test journal") }
#else
let leaseDuration: TimeInterval = 30
let journalPath = "/var/db/com.coddle.helper.sleep-state"
#endif
let sleepLease = SleepLease(journal: journalPath, read: {
    let result = runPmset(["-g"])
    guard result.status == 0 else { return nil }
    for line in result.output.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        if parts.count == 2, parts[0] == "SleepDisabled", ["0", "1"].contains(parts[1]) {
            return parts[1] == "1"
        }
    }
    return nil
}, write: { runPmset(["-a", "disablesleep", $0 ? "1" : "0"]).status == 0 }, now: { BoundedIO.now })

// Offline recovery runs only after launchd stops the daemon during uninstall.
if CommandLine.arguments.dropFirst().contains("--restore-sleep") {
    let result = sleepLease.release()
    if result != "ok" { writeStderr(result) }
    exit(result == "ok" ? 0 : 1)
}

func handle(_ line: String) -> String {
    // Capture acceptance time before waiting behind earlier power writes.
    let expires = BoundedIO.now + leaseDuration
    return handleCommand(line, runPmset: { arguments in
        powerWriteQueue.sync { runPmset(arguments) }
    }, enableLease: {
        powerWriteQueue.sync { sleepLease.acquire(until: expires) }
    }, releaseLease: {
        powerWriteQueue.sync { sleepLease.release() }
    }, leaseStatus: {
        powerWriteQueue.sync { sleepLease.status() }
    })
}

// Replay only recorded Coddle changes; preserve external ON at startup.
powerWriteQueue.sync { _ = sleepLease.release() }
let leaseTimer = DispatchSource.makeTimerSource(queue: powerWriteQueue)
leaseTimer.schedule(deadline: .now() + 0.2, repeating: 0.2)
leaseTimer.setEventHandler { sleepLease.reconcile() }
leaseTimer.resume()

// MARK: - Unix socket plumbing

func fillSockaddr(_ addr: inout sockaddr_un, _ path: String) -> socklen_t {
    memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < capacity else {
        fatal("socket path too long (max \(capacity - 1) bytes)")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
        let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
        _ = strlcpy(raw, path, capacity)
    }
    return socklen_t(MemoryLayout<sockaddr_un>.size)
}

/// uid of the current console (GUI login) user, or nil if it cannot be read.
func consoleUserID() -> uid_t? {
    var info = Darwin.stat()
    guard stat("/dev/console", &info) == 0 else { return nil }
    return info.st_uid
}

// MARK: - Server

signal(SIGPIPE, SIG_IGN)

unlink(socketPath)

// Atomic permissions on socket bind to prevent symlink race conditions
let oldMask = umask(0o111)

let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
if listenFD < 0 {
    umask(oldMask)
    fatal("socket() failed: \(String(cString: strerror(errno)))")
}

var address = sockaddr_un()
let addressLength = fillSockaddr(&address, socketPath)
let bindResult = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, addressLength) }
}
umask(oldMask)
if bindResult != 0 { fatal("bind(\(socketPath)) failed: \(String(cString: strerror(errno)))") }

if listen(listenFD, 8) != 0 { fatal("listen() failed: \(String(cString: strerror(errno)))") }

writeStderr("coddle-helper: listening on \(socketPath)")

// A fixed admission budget bounds waiting threads and descriptors even if
// an authorized peer slowly streams input or submits long-running mutations.
let admission = DispatchSemaphore(value: 8)
let clientQueue = DispatchQueue(label: "com.coddle.helper.clients", attributes: .concurrent)
let shutdownQueue = DispatchQueue(label: "com.coddle.helper.shutdown")
var signalSources = [DispatchSourceSignal]()
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: shutdownQueue)
    source.setEventHandler {
        powerWriteQueue.sync { _ = sleepLease.release() }
        unlink(socketPath)
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

while true {
    let clientFD = accept(listenFD, nil, nil)
    if clientFD < 0 {
        if errno != EINTR { Thread.sleep(forTimeInterval: 0.05) }
        continue
    }
    // Authenticate before allocating a worker or admitting the descriptor.
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    let havePeer = getpeereid(clientFD, &peerUID, &peerGID) == 0
    let authorized = havePeer && (allowNonRoot || peerUID == 0 || peerUID == consoleUserID())
    guard authorized, admission.wait(timeout: .now()) == .success else {
        close(clientFD)
        continue
    }
    BoundedIO.nonblocking(clientFD)
    let requestDeadline = BoundedIO.now + 3
    clientQueue.async {
        defer { close(clientFD); admission.signal() }
        let reply: String
        if let line = BoundedIO.readLine(clientFD, until: requestDeadline) {
            reply = handle(line)
        } else {
            reply = "err invalid-request"
        }
        _ = BoundedIO.writeLine(clientFD, reply, until: BoundedIO.now + 0.2)
    }
}
