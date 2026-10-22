import AppKit
import Foundation

extension IntegrationTests {
    @MainActor static func masterKeepAwakeTests() async {
        await masterStopOwnershipTests()
        await retainedAwakePreferenceTests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-master-awake-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.installed = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            m.keepDisplayAwake = true; m.keepAwakeOnLidClosed = true
            await m.waitForPendingOperations()
            expect(!m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed,
                   "child preferences can be retained while the master is OFF")
            expect(!f.systemAssertions.contains(true) && !f.displayAssertions.contains(true) && !f.helper.writes.contains(true),
                   "inactive saved options never reach an ON writer")
            let initialSaves = f.saved.count
            m.sleepDisplayNow(); await m.waitForPendingOperations()
            expect(!m.canSleepDisplayNow && m.displaySleepStatus == "display.requiresRunning" &&
                   f.displaySleepRequests == 0 && f.saved.count == initialSaves,
                   "immediate sleep never starts the master or saves choices while it is OFF")

            m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
            expect(m.systemAwakeApplied && m.displayAwakeApplied && m.lidAwakeApplied,
                   "a new master session applies the saved child options")
            m.keepDisplayAwake = true; m.keepAwakeOnLidClosed = true
            await m.waitForPendingOperations()
            let litSaves = f.saved.count
            m.sleepDisplayNow(); await m.waitForPendingOperations()
            expect(!m.canSleepDisplayNow && m.displaySleepStatus == "display.requiresRunning" &&
                   m.keepDisplayAwake && m.displayAwakeApplied &&
                   f.displaySleepRequests == 0 && f.saved.count == litSaves,
                   "immediate sleep cannot silently turn off a selected always-on screen")
            m.keepDisplayAwake = false; await m.waitForPendingOperations()
            let beforeSleep = f.saved.count
            f.configSaveError = NSError(domain: "unexpected-sleep-save", code: 1)
            m.sleepDisplayNow(); await m.waitForPendingOperations()
            expect(m.canSleepDisplayNow && f.displaySleepRequests == 1 && m.displaySleepStatus == "display.requested",
                   "sleep uses confirmed existing system keep-awake and preserves lid mode")
            expect(f.saved.count == beforeSleep && m.configError == nil && m.keepAwakeOnLidClosed && m.lidAwakeApplied,
                   "one-shot sleep performs no configuration write even when storage would fail")
            f.configSaveError = nil
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(!m.keepAwake && !m.keepDisplayAwake && m.keepAwakeOnLidClosed &&
                   !m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "master OFF releases every scope while preserving child preferences")
            expect(!f.config.keepAwake && !f.config.keepDisplayAwake && f.config.keepAwakeOnLidClosed &&
                   m.taskStopStatus == "onboarding.stopped",
                   "master OFF saves and confirms all three releases")
            m.keepDisplayAwake = true; m.keepAwakeOnLidClosed = true
            m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
            expect(m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed &&
                   m.displayAwakeApplied && m.lidAwakeApplied,
                   "re-enabling the master restores the saved child choices")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        // Child preferences are valid while OFF. Actual helper cleanup still
        // uses the verified stop journal independently of those preferences.
        for mask in [1, 2, 3] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepDisplayAwake = mask & 1 != 0
            f.config.keepAwakeOnLidClosed = mask & 2 != 0
            f.helper.installed = true
            f.helper.sleepDisabled = mask & 2 != 0
            if mask == 3 { f.helper.writeError = HelperError(message: "legacy cleanup delayed") }
            let store = OnboardingStore(directory: root.appendingPathComponent("orphan-\(mask)"))
            try! ConfigStore.save(f.config, at: store.configURL)
            var services = f.services()
            services.loadConfig = { try await ConfigStore.readAsync(at: store.configURL) }
            services.saveConfig = {
                try await ConfigStore.saveAsync($0, at: store.configURL)
                f.config = $0; f.saved.append($0)
            }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            let stored = try! ConfigStore.read(at: store.configURL)
            expect(!m.keepAwake && m.keepDisplayAwake == (mask & 1 != 0) && m.keepAwakeOnLidClosed == (mask & 2 != 0) &&
                   !stored.keepAwake && stored.keepDisplayAwake == m.keepDisplayAwake && stored.keepAwakeOnLidClosed == m.keepAwakeOnLidClosed,
                   "startup retains saved child choices without enabling the master")
            expect(!f.systemAssertions.contains(true) && !f.displayAssertions.contains(true) && !f.helper.writes.contains(true),
                   "startup never transiently applies a saved child while the master is OFF")
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            if mask == 3 {
                expect(m.lidStateUnconfirmed && store.bootstrap().record.stopPending,
                       "failed helper cleanup retains the actual-state and persistent stop obligations")
                m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
                expect(!m.keepAwake, "a pending cleanup must be resolved before a new master session")
                f.helper.writeError = nil
                m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            }
            expect(!store.bootstrap().record.stopPending && m.taskStopStatus == "onboarding.stopped",
                   "successful cleanup clears the persisted stop journal")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
            let restarted = AppModel(services: services, onboardingStore: store)
            await restarted.waitForPendingOperations()
            expect(!restarted.keepAwake && restarted.keepDisplayAwake == (mask & 1 != 0) && restarted.keepAwakeOnLidClosed == (mask & 2 != 0) &&
                   !restarted.systemAwakeApplied && !restarted.displayAwakeApplied && !restarted.lidAwakeApplied,
                   "restart preserves inactive preferences without restoring their effects")
            restarted.shutdownKeepAwake(); await restarted.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepDisplayAwake = true; f.config.keepAwakeOnLidClosed = true
            f.helper.installed = true
            let store = OnboardingStore(directory: root.appendingPathComponent("reload"))
            try! ConfigStore.save(f.config, at: store.configURL)
            let m = AppModel(services: f.services(), onboardingStore: store)
            await m.waitForPendingOperations()
            f.config.keepAwake = false // A hand edit changes only the master.
            m.reloadConfig(); await m.waitForPendingOperations()
            expect(!m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed &&
                   !m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "reload preserves child choices and releases previous active controls")
            expect(m.taskStopStatus == "onboarding.stopped" && !store.bootstrap().record.stopPending,
                   "reload uses the same verified stop and journal completion")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        // Returning can happen before an asynchronous sleep acknowledgement.
        // Suppress the late success, but retain failures for explicit retry.
        for result in [DisplaySleepResult.requested, .failed] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            var resumeSleep: CheckedContinuation<Void, Never>?
            var services = f.services()
            services.sleepDisplays = {
                await withCheckedContinuation { resumeSleep = $0 }
                f.displaySleepRequests += 1
                return result
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.sleepDisplayNow()
            for _ in 0..<500 where resumeSleep == nil { try? await Task.sleep(for: .milliseconds(2)) }
            expect(resumeSleep != nil, "asynchronous sleep reply is held after request admission")
            f.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil); await settle()
            resumeSleep?.resume(); resumeSleep = nil
            await m.waitForPendingOperations()
            expect(m.displaySleepStatus == (result == .requested ? nil : "display.failed"),
                   "return events suppress a late success but never hide a retryable error")
            expect(f.displaySleepRequests == 1 && m.keepAwake && !m.keepDisplayAwake && m.canSleepDisplayNow,
                   "reply handling preserves choices and permits a new explicit request")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}
