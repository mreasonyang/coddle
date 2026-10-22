import AppKit
import CoreServices
import Darwin
import Foundation

/// Immutable metadata and icons. Icons are created on the sampler's serial
/// queue, then only read by the UI; Coddle never mutates a published NSImage.
struct SignificantEnergyApp: Identifiable, @unchecked Sendable {
    static let displayLimit = 3
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let energyScore: Double
}

struct EnergyProcessUsage: Sendable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let startTime: UInt64
    let cpuTimeNs: UInt64
    let wakeups: UInt64
    let lifetimeSeconds: Double

    var identity: String { "\(id):\(startTime)" }
}

struct EnergyUsageSnapshot: Sendable {
    var timestamp: TimeInterval
    var processes: [EnergyProcessUsage]
    var unreadable = 0
}

struct EnergySample: Sendable {
    var apps: [SignificantEnergyApp]
    var statusKey: String
}

/// All process inspection, scoring and icon loading is confined to this queue.
/// NSWorkspace.runningApplications and NSRunningApplication properties are
/// documented as thread safe. A PID/start-time identity prevents a reused PID
/// from inheriting an old process's counters or icon.
final class EnergySamplingWorker: @unchecked Sendable {
    private struct Sample {
        let cpuTimeNs: UInt64
        let wakeups: UInt64
        let timestamp: TimeInterval
    }
    private struct CachedIcon { let image: NSImage? }

    private let queue = DispatchQueue(label: "com.coddle.energy-sampling", qos: .utility)
    private let readUsage: @Sendable () -> EnergyUsageSnapshot
    private let readIcon: @Sendable (pid_t) -> NSImage?
    private var previousSamples: [String: Sample] = [:]
    private var icons: [String: CachedIcon] = [:]

    init(readUsage: @escaping @Sendable () -> EnergyUsageSnapshot = { EnergySamplingWorker.readLiveUsage() },
         readIcon: @escaping @Sendable (pid_t) -> NSImage? = { NSRunningApplication(processIdentifier: $0)?.icon }) {
        self.readUsage = readUsage
        self.readIcon = readIcon
    }

    func sample(limit: Int) async -> EnergySample {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.sampleOnQueue(limit: limit)) }
        }
    }

    private func sampleOnQueue(limit: Int) -> EnergySample {
        let snapshot = readUsage()
        var nextSamples: [String: Sample] = [:]
        var candidates: [(process: EnergyProcessUsage, score: Double)] = []
        for process in snapshot.processes {
            let identity = process.identity
            nextSamples[identity] = Sample(cpuTimeNs: process.cpuTimeNs, wakeups: process.wakeups,
                                           timestamp: snapshot.timestamp)
            let score: Double
            if let prev = previousSamples[identity], snapshot.timestamp - prev.timestamp >= 0.8 {
                let dt = snapshot.timestamp - prev.timestamp
                let cpu = process.cpuTimeNs >= prev.cpuTimeNs ? process.cpuTimeNs - prev.cpuTimeNs : 0
                let wakeups = process.wakeups >= prev.wakeups ? process.wakeups - prev.wakeups : 0
                score = Double(cpu) / (dt * 1_000_000_000) * 100 + Double(wakeups) / dt * 0.04
            } else {
                let lifetime = max(1, process.lifetimeSeconds)
                score = Double(process.cpuTimeNs) / (lifetime * 1_000_000_000) * 100 * 1.4
                    + Double(process.wakeups) / lifetime * 0.03
            }
            if score >= 1.5 { candidates.append((process, score)) }
        }
        previousSamples = nextSamples
        icons = icons.filter { nextSamples[$0.key] != nil }
        candidates.sort { $0.score > $1.score }
        let apps = candidates.prefix(max(0, limit)).map { candidate in
            let process = candidate.process
            if icons[process.identity] == nil {
                icons[process.identity] = CachedIcon(image: readIcon(process.id))
            }
            return SignificantEnergyApp(id: process.id, name: process.name,
                bundleIdentifier: process.bundleIdentifier, icon: icons[process.identity]?.image,
                energyScore: candidate.score)
        }
        return EnergySample(apps: apps, statusKey: snapshot.processes.isEmpty ? "energySample.unavailable" :
            (snapshot.unreadable > 0 ? "energySample.partial" : "energySample.ready"))
    }

    private static func readLiveUsage() -> EnergyUsageSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let machNow = mach_absolute_time()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let numer = UInt64(max(1, info.numer)), denom = UInt64(max(1, info.denom))
        let selfBundleID = Bundle.main.bundleIdentifier
        var result = EnergyUsageSnapshot(timestamp: now, processes: [])
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            if let bid = app.bundleIdentifier, bid == selfBundleID || bid == "com.apple.ActivityMonitor" { continue }
            guard let name = app.localizedName, !name.isEmpty else { continue }
            var ri = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ri) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard rc == 0 else { result.unreadable += 1; continue }
            let cpuNs = ((ri.ri_user_time &+ ri.ri_system_time) &* numer) / denom
            let ageTicks = machNow > ri.ri_proc_start_abstime ? machNow - ri.ri_proc_start_abstime : 1
            let ageNs = (ageTicks &* numer) / denom
            result.processes.append(EnergyProcessUsage(id: pid, name: name, bundleIdentifier: app.bundleIdentifier,
                startTime: ri.ri_proc_start_abstime, cpuTimeNs: cpuNs, wakeups: ri.ri_pkg_idle_wkups,
                lifetimeSeconds: max(1, Double(ageNs) / 1_000_000_000)))
        }
        return result
    }
}

/// UI-facing cache. Concurrent callers share one background sample, including
/// empty results; the main actor never performs process or icon I/O.
@MainActor
final class EnergyAppMonitor {
    static let shared = EnergyAppMonitor()
    private let sample: @Sendable (Int) async -> EnergySample
    private let now: () -> TimeInterval
    private var samplingTask: Task<Void, Never>?
    private var lastSampledAt: TimeInterval?
    private var cachedLimit = 0
    private var cachedApps: [SignificantEnergyApp] = []
    private(set) var statusKey = "energySample.unavailable"

    init(sample: (@Sendable (Int) async -> EnergySample)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let worker = EnergySamplingWorker()
        self.sample = sample ?? { await worker.sample(limit: $0) }
        self.now = now
    }

    func sampleTopApps(limit: Int = SignificantEnergyApp.displayLimit) async -> [SignificantEnergyApp] {
        let requestedLimit = max(0, limit)
        while true {
            if let task = samplingTask { await task.value; continue }
            if let lastSampledAt, now() - lastSampledAt < 1.5, requestedLimit <= cachedLimit {
                return Array(cachedApps.prefix(requestedLimit))
            }
            let sampleLimit = max(SignificantEnergyApp.displayLimit, requestedLimit)
            samplingTask = Task { [self] in
                let result = await sample(sampleLimit)
                cachedApps = result.apps
                statusKey = result.statusKey
                cachedLimit = sampleLimit
                lastSampledAt = now()
                samplingTask = nil
            }
        }
    }

    /// Opens Activity Monitor switched to the "Energy" tab and selects the target app,
    /// using the exact `'ptru'` AppleEvent pass-through descriptor used by macOS Control Center
    /// (`"openTab:Power;bundle-id:<bundleID>;name:<appName>"`).
    static func openInActivityMonitor(_ app: SignificantEnergyApp) {
        for candidate in NSApplication.shared.windows
        where candidate.isVisible && candidate.level == .popUpMenu {
            candidate.orderOut(nil)
        }

        let activityMonitorURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        let bundleID = app.bundleIdentifier ?? ""
        let payload = "openTab:Power;bundle-id:\(bundleID);name:\(app.name)"
        let descriptor = NSAppleEventDescriptor(
            descriptorType: FourCharCode(0x70747275), // 'ptru'
            data: Data(payload.utf8)
        )

        var spec = LSLaunchURLSpec(
            appURL: Unmanaged.passUnretained(activityMonitorURL as CFURL),
            itemURLs: nil,
            passThruParams: descriptor?.aeDesc,
            launchFlags: [.defaults, .async],
            asyncRefCon: nil
        )
        let status = LSOpenFromURLSpec(&spec, nil)
        if status != noErr {
            NSWorkspace.shared.openApplication(
                at: activityMonitorURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        }
    }
}
