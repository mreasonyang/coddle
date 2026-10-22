import Foundation

extension IntegrationTests {
    @MainActor static func keepAwakeMenuStateTests() async {
        for state in KeepAwakeMenuState.allCases {
            expect(state.localizationKey == "awakeMenu.\(state.rawValue)" &&
                   state.hasException == (state != .off && state != .on),
                   "menu state exposes its localized label and exception visibility")
        }

        for display in [false, true] { for lid in [false, true] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.config.keepDisplayAwake = display
            f.config.keepAwakeOnLidClosed = lid
            f.away.protectionReady = true
            f.helper.installed = lid
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            expect(m.keepAwakeMenuState == .on, "matching active intents, including child options, show ON")
            let before = (f.saved.count, f.systemAssertions.count, f.displayAssertions.count, f.helper.writes.count)
            for _ in 0..<10 { _ = m.keepAwakeMenuState }
            expect(before == (f.saved.count, f.systemAssertions.count, f.displayAssertions.count, f.helper.writes.count),
                   "reading the menu state performs no persistence or control operations")
            m.setKeepAwakeEnabled(false)
            expect(m.keepAwakeMenuState == .stopping, "master OFF immediately reports stopping")
            await m.waitForPendingOperations()
            expect(m.keepAwakeMenuState == .off && !m.keepAwakeMenuState.hasException,
                   "verified release shows OFF even with a successful stop receipt")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }}

        do {
            let f = ModelFixture(); defer { f.clean() }
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            expect(!m.helperInstalled && m.helperStatus == nil && m.keepAwakeMenuState == .off,
                   "an absent optional helper is a stable OFF, not an error")
            f.helper.installGate = DispatchSemaphore(value: 0)
            m.installHelper()
            expect(m.helperBusy && m.keepAwakeMenuState == .pending, "helper installation busy is pending")
            f.helper.installGate?.signal()
            await waitForInstall(m)
            expect(m.helperInstalled && m.helperStatus == nil && m.keepAwakeMenuState == .off,
                   "successful helper installation is not attention")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.config.keepDisplayAwake = true
            f.config.keepAwakeOnLidClosed = true
            f.helper.installed = true
            f.away.protectionReady = true
            var holdOff = false
            var resumeOff: CheckedContinuation<Void, Never>?
            var services = f.services()
            services.setSystemAwake = { on in
                if holdOff && !on {
                    holdOff = false
                    await withCheckedContinuation { resumeOff = $0 }
                }
                f.systemAssertions.append(on)
                return true
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            holdOff = true
            f.away.isAway = true; f.awayCallback?(f.away)
            for _ in 0..<500 where resumeOff == nil { try? await Task.sleep(for: .milliseconds(2)) }
            expect(resumeOff != nil && m.bagGuardActive && m.systemAwakeApplied &&
                   m.keepAwakeMenuState == .pending, "guard cannot claim paused while an active control is still releasing")
            resumeOff?.resume(); resumeOff = nil
            await m.waitForPendingOperations()
            expect(m.keepAwakeMenuState == .paused, "guard pause requires every control to be released")
            m.sleepDisplayNow()
            expect(m.displaySleepStatus == "display.requiresRunning" && m.keepAwakeMenuState == .attention,
                   "a rejected sleep action remains visible even while protected")
            // An explicit preference edit clears the previous action receipt.
            m.keepDisplayAwake = false; await m.waitForPendingOperations()
            m.sleepDisplayNow()
            expect(m.displaySleepStatus == "display.protected" && m.keepAwakeMenuState == .paused,
                   "a current protective rejection uses the confirmed paused state")
            f.away.isAway = false; f.awayCallback?(f.away)
            await settle(); await m.waitForPendingOperations()
            expect(m.displaySleepStatus == "display.protected" && m.keepAwakeMenuState == .attention,
                   "a retained rejection remains visible after the protective pause ends")
            f.away.isAway = true; f.awayCallback?(f.away)
            await settle(); await m.waitForPendingOperations()
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.bagGuardActive && m.keepAwakeMenuState == .off, "master OFF does not claim a protective pause")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            var services = f.services()
            services.setDisplayAwake = {
                if f.assertionFailure { return false }
                f.displayAssertions.append($0)
                return true
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.keepDisplayAwake = true
            expect(m.assertionsApplying && !m.displayAwakeApplied && m.keepAwakeMenuState == .pending,
                   "a changed display intent cannot be reported ON before application")
            await m.waitForPendingOperations()
            f.assertionFailure = true
            m.keepDisplayAwake = false; await m.waitForPendingOperations()
            expect(m.awakeFeedbackError != nil && m.displayAwakeApplied &&
                   m.keepAwakeMenuState == .attention, "failed release and stale actual state cannot appear ON")
            m.setKeepAwakeEnabled(false)
            expect(m.keepAwakeMenuState == .stopping, "stopping wins over an existing assertion error")
            await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopPartial" && m.keepAwakeMenuState == .attention,
                   "partial stop remains attention even though the master intent is OFF")
            f.assertionFailure = false
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.keepAwakeMenuState == .off, "verified retry clears the attention state")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.away.protectionReady = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            m.keepAwakeOnLidClosed = true
            expect(m.keepAwakeMenuState == .pending, "unapplied lid intent is pending before helper response")
            await m.waitForPendingOperations()
            expect(!m.helperInstalled && m.helperStatus != nil && m.lidStateUnconfirmed &&
                   m.keepAwakeMenuState == .attention, "requested lid mode with an unavailable helper needs attention")
            f.helper.installGate = DispatchSemaphore(value: 0)
            m.installHelper()
            expect(m.helperBusy && m.keepAwakeMenuState == .attention,
                   "a helper retry in progress does not hide the existing error")
            f.helper.installGate?.signal()
            await waitForInstall(m)
            expect(m.keepAwakeMenuState == .on, "confirmed helper recovery restores ON")
            f.helper.sleepDisabled = nil
            m.refresh(); await m.waitForPendingOperations()
            expect(m.lidStateUnconfirmed && m.keepAwakeMenuState == .attention,
                   "unknown lid readback cannot be summarized as ON")
            f.helper.sleepDisabled = false
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        for ready in [false, true] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            f.helper.installed = true
            f.config.awayDetectionEnabled = !ready
            f.away.protectionReady = ready
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            expect(m.lidAwakeApplied && m.keepAwakeMenuState == .attention,
                   "disabled or untrained away protection remains visible for selected lid mode")
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-menu-state-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = OnboardingStore(directory: root)
            try! ConfigStore.save(f.config, at: store.configURL)
            let m = AppModel(services: f.services(), onboardingStore: store)
            await m.waitForPendingOperations()
            _ = await m.onboarding?.recordStopRequested(lidRequired: false).value
            expect(m.taskStopStatus.isEmpty && m.keepAwakeMenuState == .attention,
                   "a durable stop obligation is visible independently of transient status text")
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.keepAwakeMenuState == .off, "clearing the durable stop restores stable OFF")
            f.configSaveError = NSError(domain: "menu-state-save", code: 1)
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopSaveFailed" && m.keepAwakeMenuState == .attention,
                   "a failed stop save remains attention even when all controls are released")
            f.configSaveError = nil
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        for result in [DisplaySleepResult.requested, .failed, .unavailable] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.displaySleepResult = result
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            m.sleepDisplayNow()
            expect(m.keepAwakeMenuState == .pending, "an in-flight one-shot action is pending")
            await m.waitForPendingOperations()
            expect(m.keepAwakeMenuState == (result == .requested ? .on : .attention),
                   "successful sleep acknowledgement is neutral while a failed request remains visible")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        for failure in ["assertion", "settings", "notReady"] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            if failure == "notReady" { f.hardwareReadError = HardwareFailure(message: "fixture unavailable") }
            var services = f.services()
            if failure == "assertion" { services.systemAssertionActive = { nil } }
            if failure == "settings" { services.openDisplaySettings = { false } }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            if failure == "settings" { m.openDisplayTimeoutSettings() }
            else { m.sleepDisplayNow(); await m.waitForPendingOperations() }
            expect(m.keepAwakeMenuState == .attention, "sleep admission or settings failure remains visible: \(failure)")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            m.sleepDisplayNow()
            expect(m.displaySleepStatus == "display.requiresRunning" && m.keepAwakeMenuState == .attention,
                   "an incompatible sleep request remains visible while the master is OFF")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}
