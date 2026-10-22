import AppKit
import Foundation

extension IntegrationTests {
    @MainActor static func retainedAwakePreferenceTests() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-retained-awake-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        for display in [false, true] { for lid in [false, true] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.config.keepDisplayAwake = display; f.config.keepAwakeOnLidClosed = lid
            f.helper.installed = lid; f.away.protectionReady = true
            let store = OnboardingStore(directory: root.appendingPathComponent("combination-\(display)-\(lid)"))
            try! ConfigStore.save(f.config, at: store.configURL)
            var services = f.services()
            services.loadConfig = { try await ConfigStore.readAsync(at: store.configURL) }
            services.saveConfig = {
                try await ConfigStore.saveAsync($0, at: store.configURL)
                f.config = $0; f.saved.append($0)
            }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            let saved = try! ConfigStore.read(at: store.configURL)
            expect(!saved.keepAwake && saved.keepDisplayAwake == display && saved.keepAwakeOnLidClosed == lid,
                   "master OFF persists all four child-preference combinations unchanged")
            expect(!m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied && m.keepAwakeMenuState == .off,
                   "saved child preferences do not count as active or pending controls while OFF")
            let before = (f.systemAssertions.count, f.displayAssertions.count, f.helper.writes.count)
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                f.workspace.post(name: name, object: nil)
            }
            f.application.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            f.away.isAway = true; f.awayCallback?(f.away)
            await settle(); m.refresh(); await m.waitForPendingOperations()
            f.away.isAway = false; f.awayCallback?(f.away)
            await settle(); await m.waitForPendingOperations()
            expect(!f.systemAssertions.dropFirst(before.0).contains(true) &&
                   !f.displayAssertions.dropFirst(before.1).contains(true) && !f.helper.writes.dropFirst(before.2).contains(true),
                   "wake, polling and guard transitions cannot apply child preferences under master OFF")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
            let restarted = AppModel(services: services, onboardingStore: store)
            await restarted.waitForPendingOperations()
            expect(!restarted.keepAwake && restarted.keepDisplayAwake == display && restarted.keepAwakeOnLidClosed == lid &&
                   !restarted.systemAwakeApplied && !restarted.displayAwakeApplied && !restarted.lidAwakeApplied,
                   "quit and restart preserve inactive preferences without resuming their effects")
            if display { restarted.keepAwake = true }
            else { restarted.setKeepAwakeEnabled(true) }
            await restarted.waitForPendingOperations()
            expect(restarted.systemAwakeApplied && restarted.displayAwakeApplied == display && restarted.lidAwakeApplied == lid,
                   "both master entry points apply retained preferences on the next explicit ON")
            restarted.setKeepAwakeEnabled(false); await restarted.waitForPendingOperations()
            restarted.shutdownKeepAwake(); await restarted.waitForPendingOperations()
        }}

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepDisplayAwake = true; f.config.keepAwakeOnLidClosed = true
            f.helper.installed = true; f.away.protectionReady = true
            let store = OnboardingStore(directory: root.appendingPathComponent("failed-save-restart"))
            try! ConfigStore.save(f.config, at: store.configURL)
            var services = f.services()
            services.loadConfig = { try await ConfigStore.readAsync(at: store.configURL) }
            services.saveConfig = {
                if let error = f.configSaveError { throw error }
                try await ConfigStore.saveAsync($0, at: store.configURL)
                f.config = $0; f.saved.append($0)
            }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            f.configSaveError = NSError(domain: "retained-stop", code: 1)
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopSaveFailed" && m.keepDisplayAwake && m.keepAwakeOnLidClosed &&
                   !m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "failed OFF persistence retains preferences while releasing every effect")
            let oldDisk = try! ConfigStore.read(at: store.configURL)
            expect(oldDisk.keepAwake && oldDisk.keepDisplayAwake && oldDisk.keepAwakeOnLidClosed && store.bootstrap().record.stopPending,
                   "failed save leaves old preferences intact and a separate durable stop obligation")
            m.setKeepAwakeEnabled(true); m.keepAwake = true
            let setupResult = await m.applySetupAwake(.open)
            m.reloadConfig(); await m.waitForPendingOperations()
            expect(!m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed && setupResult.0 == .failed,
                   "pending stop blocks both ON entry points, setup and a stale ON configuration reload")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
            let writesBeforeRestart = (f.systemAssertions.count, f.displayAssertions.count, f.helper.writes.count)
            let restarted = AppModel(services: services, onboardingStore: store)
            await restarted.waitForPendingOperations()
            expect(!restarted.keepAwake && restarted.keepDisplayAwake && restarted.keepAwakeOnLidClosed &&
                   restarted.onboarding?.record.stopPending == true,
                   "restart masks an unsaved old master ON without deleting its child preferences")
            expect(!f.systemAssertions.dropFirst(writesBeforeRestart.0).contains(true) &&
                   !f.displayAssertions.dropFirst(writesBeforeRestart.1).contains(true) && !f.helper.writes.dropFirst(writesBeforeRestart.2).contains(true),
                   "recovery never transiently reapplies saved child options")
            f.configSaveError = nil
            restarted.restoreSystemDefaults(); await restarted.waitForPendingOperations()
            let repaired = try! ConfigStore.read(at: store.configURL)
            expect(!repaired.keepAwake && repaired.keepDisplayAwake && repaired.keepAwakeOnLidClosed &&
                   !store.bootstrap().record.stopPending && restarted.taskStopStatus == "onboarding.stopped",
                   "stop retry repairs only the master and clears responsibility after confirmed release")
            restarted.setKeepAwakeEnabled(true); await restarted.waitForPendingOperations()
            expect(restarted.systemAwakeApplied && restarted.displayAwakeApplied && restarted.lidAwakeApplied,
                   "the next explicit ON can resume both preferences after recovery succeeds")
            restarted.shutdownKeepAwake(); await restarted.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepDisplayAwake = true; f.config.keepAwakeOnLidClosed = true
            f.config.awayDetectionEnabled = false
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            expect(m.keepAwakeMenuState == .off && !m.lidStateUnconfirmed && m.helperStatus == nil,
                   "inactive lid preference needs neither a helper nor trained guard readiness")
            f.helper.installError = HelperError(message: "fixture installation rejected")
            m.installHelper(); await waitForInstall(m)
            expect(!m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed && !m.lidAwakeApplied,
                   "failed helper installation retains preferences without claiming lid control")
            f.helper.installError = nil
            m.installHelper(); await waitForInstall(m)
            m.removeHelper(); await waitForInstall(m)
            expect(!m.helperInstalled && m.keepDisplayAwake && m.keepAwakeOnLidClosed &&
                   !m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "helper removal preserves saved choices and does not claim any active control")
            expect(!f.helper.writes.contains(true), "helper preparation and removal under OFF never apply saved lid ON")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepDisplayAwake = true; f.config.keepAwakeOnLidClosed = true
            f.away.protectionReady = true
            f.helper.installError = HelperError(message: "fixture active installation rejected")
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            m.installHelper(); await waitForInstall(m)
            expect(m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed &&
                   m.systemAwakeApplied && m.displayAwakeApplied && !m.lidAwakeApplied &&
                   m.keepAwakeMenuState == .attention,
                   "failed helper installation under ON retains choices and reports the missing lid effect")
            f.helper.installError = nil
            m.installHelper(); await waitForInstall(m)
            expect(m.lidAwakeApplied && m.keepAwakeMenuState == .on,
                   "a successful explicit helper retry applies the retained active lid preference")
            m.removeHelper(); await waitForInstall(m)
            expect(m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed &&
                   !m.helperInstalled && !m.lidAwakeApplied && m.keepAwakeMenuState != .on,
                   "helper removal preserves active preferences without advertising unavailable lid control")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepDisplayAwake = true; f.config.keepAwakeOnLidClosed = true
            f.helper.installed = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            let open = await m.applySetupAwake(.open); await m.waitForPendingOperations()
            expect(open.0 == .confirmed && m.keepAwake && !m.keepDisplayAwake && !m.keepAwakeOnLidClosed,
                   "an explicit new onboarding plan may replace the saved child choices")
            m.keepDisplayAwake = true; m.keepAwakeOnLidClosed = true
            await m.waitForPendingOperations()
            let stopped = await m.applySetupAwake(.none); await m.waitForPendingOperations()
            expect(stopped.0 == .confirmed && stopped.1 == .confirmed && !m.keepAwake &&
                   m.keepDisplayAwake && m.keepAwakeOnLidClosed && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "the setup no-task stop preserves preferences just like the master OFF action")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}
