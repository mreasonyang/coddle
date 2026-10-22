import Foundation

/// Opt-in, reversible checks for the local machine. Never installs the helper,
/// changes disablesleep, sleeps the computer, or uses the app's preferences.
@main struct HardwareSmoke {
    @MainActor static func main() async {
        guard CommandLine.arguments.contains("--write-and-restore") else {
            print("Use --write-and-restore to opt in to temporary limit changes and power assertions.")
            exit(2)
        }
        var failures: [String] = []
        let assertions = KeepAwakeWorker()
        let system = await assertions.setSystemAwake(true)
        let display = await assertions.setDisplayAwake(true)
        let released = await assertions.release()
        print("IOPM assertions: system=\(system) display=\(display) released=\(released)")
        if !(system && display && released) { failures.append("assertion lifecycle") }

        if PowerUI.isSupported, let before = PowerUI.current(),
           let alternate = PowerUI.availableLimits().first(where: { $0 != before.limit && $0 < 100 }) {
            let writeError = PowerUI.set(alternate)
            var changed = false
            for _ in 0..<20 {
                if let current = PowerUI.current(), current.limit == alternate && current.enabled { changed = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Restore even when a failed/timed-out request may have reached the OS.
            let restoreError = before.enabled ? PowerUI.set(before.limit) : PowerUI.disable()
            var restored = false
            for _ in 0..<20 {
                if let current = PowerUI.current(), current.limit == before.limit && current.enabled == before.enabled { restored = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            print("charge limit: before=\(before), temporary=\(alternate), writeError=\(writeError ?? "none"), readback=\(changed), restoreError=\(restoreError ?? "none"), restored=\(restored)")
            if writeError != nil || !changed || restoreError != nil || !restored { failures.append("charge limit round-trip") }
        } else { print("SKIP charge write: no supported alternative/native limit") }
        if failures.isEmpty { print("hardware-smoke: PASS for available capabilities") }
        else { print("hardware-smoke: FAIL \(failures)"); exit(1) }
    }
}
