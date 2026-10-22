import AppKit
import Foundation

extension IntegrationTests {
    @MainActor static func displayManagementTests() async {
        // An inactive checkbox callback must not rewrite remembered preferences
        // or enqueue persistence/hardware work, even if native input leaks past
        // its disabled appearance.
        for bits in 0..<4 {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.installed = true
            f.config.keepDisplayAwake = bits & 1 != 0
            f.config.keepAwakeOnLidClosed = bits & 2 != 0
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            let saved = f.saved.count
            let helperWrites = f.helper.writes.count
            let assertions = f.systemAssertions.count + f.displayAssertions.count
            expect(!m.canEditKeepAwakeOptions, "master OFF denies child edits")
            m.setKeepDisplayAwake(!m.keepDisplayAwake)
            m.setKeepAwakeOnLidClosed(!m.keepAwakeOnLidClosed)
            await m.waitForPendingOperations()
            expect(m.keepDisplayAwake == (bits & 1 != 0) && m.keepAwakeOnLidClosed == (bits & 2 != 0),
                   "disabled child callbacks preserve all saved preference combinations")
            expect(f.saved.count == saved && f.helper.writes.count == helperWrites &&
                   f.systemAssertions.count + f.displayAssertions.count == assertions,
                   "rejected child edits do not save or call services")
            m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
            expect(m.canEditKeepAwakeOptions, "master ON admits child edits")
            m.setKeepDisplayAwake(true); m.setKeepAwakeOnLidClosed(true)
            await m.waitForPendingOperations()
            expect(m.keepDisplayAwake && m.keepAwakeOnLidClosed && m.displayAwakeApplied && m.lidAwakeApplied,
                   "enabled child callbacks update preferences and apply effects")
            m.setKeepAwakeEnabled(false)
            expect(!m.canEditKeepAwakeOptions, "stopping immediately denies child edits")
            m.setKeepDisplayAwake(false); m.setKeepAwakeOnLidClosed(false)
            await m.waitForPendingOperations()
            expect(m.keepDisplayAwake && m.keepAwakeOnLidClosed && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "late checkbox callbacks cannot change remembered choices during stop")
            m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
            expect(!m.canEditKeepAwakeOptions, "shutdown denies child edits")
            let afterQuit = f.saved.count
            m.setKeepDisplayAwake(false); m.setKeepAwakeOnLidClosed(false)
            await m.waitForPendingOperations()
            expect(m.keepDisplayAwake && m.keepAwakeOnLidClosed && f.saved.count == afterQuit,
                   "post-shutdown callbacks cannot modify preferences")
        }
        expect(DisplaySleep.commandResult(status: 0, output: "pmset: Failed to put the display to sleep") == .failed,
               "zero exit with diagnostic output is a failure")
        expect(DisplaySleep.commandResult(status: -1, output: "") == .failed, "timeout is not accepted")
        expect(DisplaySleep.commandResult(status: 0, output: "") == .requested, "quiet success acknowledges only request")
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.installed = true
            f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            let saves = f.saved.count
            m.sleepDisplayNow(); m.sleepDisplayNow()
            await m.waitForPendingOperations()
            expect(f.displaySleepRequests == 1, "double activation sends a single request")
            expect(m.keepAwake && !m.keepDisplayAwake && m.keepAwakeOnLidClosed, "sleep preserves all pre-existing choices")
            expect(m.systemAwakeApplied && !m.displayAwakeApplied && m.lidAwakeApplied, "sleep confirms actual scopes")
            expect(f.saved.count == saves && f.config.keepAwake && !f.config.keepDisplayAwake, "one-shot sleep does not save or change configuration")
            expect(m.displaySleepStatus == "display.requested", "acknowledgement does not claim physical screen sleep")
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                f.workspace.post(name: name, object: nil); await settle(); await m.waitForPendingOperations()
                expect(m.displaySleepStatus == nil, "returning clears only the old success acknowledgement")
            }
            f.application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            m.refresh(); await settle(); await m.waitForPendingOperations()
            expect(f.displaySleepRequests == 1, "wake, topology and polling never replay sleep")
            f.away.isAway = true; f.away.protectionReady = true; f.awayCallback?(f.away)
            await settle(); await m.waitForPendingOperations()
            expect(m.bagGuardActive && m.displaySleepStatus == nil, "protection clears outdated keep-running acknowledgement")
            f.away.isAway = false; f.awayCallback?(f.away)
            await settle(); await m.waitForPendingOperations()
            m.restoreSystemDefaults(); await m.waitForPendingOperations()
            expect(!m.keepAwake && !m.keepDisplayAwake && m.keepAwakeOnLidClosed, "restore keeps child preferences while stopping all effects")
            expect(m.taskStopOrdinary == .confirmed && m.taskStopDisplay == .confirmed && m.taskStopLid == .confirmed, "restore verifies each scope")
            expect(m.taskStopStatus == "onboarding.stopped", "success requires all controls off")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
            let restarted = AppModel(services: f.services()); await restarted.waitForPendingOperations()
            expect(!restarted.systemAwakeApplied && !restarted.displayAwakeApplied && !restarted.lidAwakeApplied, "restart honors saved stop")
            expect(f.displaySleepRequests == 1, "restart never repeats one-shot action")
            restarted.shutdownKeepAwake(); await restarted.waitForPendingOperations()
        }
        for failure in ["system", "display", "unknown", "request", "unavailable"] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            var services = f.services()
            services.systemAssertionActive = {
                if failure == "unknown" { return nil }
                return failure == "system" ? false : f.systemAssertions.last ?? false
            }
            services.displayAssertionActive = { failure == "display" ? true : f.displayAssertions.last ?? false }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            if failure == "request" { f.displaySleepResult = .failed }
            if failure == "unavailable" { f.displaySleepResult = .unavailable }
            let saves = f.saved.count
            m.sleepDisplayNow(); await m.waitForPendingOperations()
            expect(f.displaySleepRequests == (["request", "unavailable"].contains(failure) ? 1 : 0), "sleep admission is gated: \(failure)")
            expect(m.displaySleepStatus != "display.requested" && !m.displaySleepBusy, "honest failure: \(failure)")
            let status = m.displaySleepStatus
            f.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            f.application.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            await settle(); await m.waitForPendingOperations()
            expect(m.displaySleepStatus == status && f.saved.count == saves, "errors survive return events without changing persisted choices")
            for away in [true, false] {
                f.away.isAway = away; f.away.protectionReady = true; f.awayCallback?(f.away)
                await settle(); await m.waitForPendingOperations()
                expect(m.bagGuardActive == away && m.displaySleepStatus == status,
                       "background protection transitions preserve a retryable sleep error")
            }
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        for action in ["stop", "screen", "quit", "guard"] {
            let f = ModelFixture(); defer { f.clean() }
            var started = false
            var services = f.services()
            services.setSystemAwake = { on in
                if on { started = true; try? await Task.sleep(for: .milliseconds(100)) }
                f.systemAssertions.append(on); return true
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.setKeepAwakeEnabled(true)
            m.sleepDisplayNow()
            for _ in 0..<100 where !started { try? await Task.sleep(for: .milliseconds(2)) }
            expect(started, "in-flight ON exercised")
            switch action {
            case "stop": m.setKeepAwakeEnabled(false)
            case "screen": m.keepDisplayAwake = true
            case "quit": m.shutdownKeepAwake()
            default: f.away.isAway = true; f.away.protectionReady = true; f.awayCallback?(f.away); await settle()
            }
            await m.waitForPendingOperations()
            expect(f.displaySleepRequests == 0, "superseded request cannot sleep display: \(action)")
            if action == "stop" || action == "quit" { expect(!m.systemAwakeApplied && !m.displayAwakeApplied, "late ON ends OFF") }
            if action == "screen" { expect(m.keepDisplayAwake && m.displayAwakeApplied, "latest screen intent wins") }
            if action == "guard" {
                expect(m.bagGuardActive && !m.systemAwakeApplied, "protection releases ordinary assertion")
                m.keepAwake = false; m.keepDisplayAwake = false
                f.away.isAway = false; f.awayCallback?(f.away); await settle(); await m.waitForPendingOperations()
                expect(!m.systemAwakeApplied && !m.displayAwakeApplied && f.displaySleepRequests == 0, "guard recovery cannot resurrect closed intents")
            }
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepDisplayAwake = true; f.config.keepAwakeOnLidClosed = true
            f.helper.installed = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            f.configSaveError = NSError(domain: "fixture", code: 1)
            m.restoreSystemDefaults(); await m.waitForPendingOperations()
            expect(!m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied, "save failure never blocks physical stop")
            expect(m.taskStopStatus == "onboarding.stopSaveFailed", "save failure reports restart uncertainty")
            f.configSaveError = nil; m.restoreSystemDefaults(); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopped" && f.config.keepDisplayAwake && f.config.keepAwakeOnLidClosed && !f.config.keepAwake, "retry saves OFF without erasing child preferences")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepDisplayAwake = true
            var reject = false
            var services = f.services()
            services.setDisplayAwake = { on in
                if reject && !on { return false }
                f.displayAssertions.append(on); return true
            }
            let m = AppModel(services: services); await m.waitForPendingOperations(); reject = true
            m.restoreSystemDefaults(); await m.waitForPendingOperations()
            expect(m.taskStopDisplay == .failed && m.taskStopStatus == "onboarding.stopPartial", "display release failure prevents complete stop")
            reject = false; m.restoreSystemDefaults(); await m.waitForPendingOperations()
            expect(m.taskStopDisplay == .confirmed && !m.displayAwakeApplied, "retry confirms display OFF")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.locked = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            m.keepAwake = true; await m.waitForPendingOperations()
            expect(m.systemAwakeApplied && !m.bagGuardActive, "lock alone does not stop work")
            m.openDisplayTimeoutSettings()
            expect(f.displaySettingsRequests == 1, "system opener handles timeout settings")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        await stopRecoveryDuringGuardTests()
        await masterKeepAwakeTests()
    }

    @MainActor private static func stopRecoveryDuringGuardTests() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-display-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for transition in ["guard-active", "guard-cleared", "ordinary", "display", "lid"] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepDisplayAwake = true; f.config.keepAwakeOnLidClosed = true
            f.helper.installed = true
            let store = OnboardingStore(directory: root.appendingPathComponent(transition))
            try! ConfigStore.save(f.config, at: store.configURL)
            var pauseNextSave = false
            var resumeSave: CheckedContinuation<Void, Never>?
            var services = f.services()
            services.saveConfig = { config in
                if pauseNextSave {
                    pauseNextSave = false
                    await withCheckedContinuation { resumeSave = $0 }
                }
                f.config = config; f.saved.append(config)
            }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            pauseNextSave = true
            m.restoreSystemDefaults()
            for _ in 0..<500 where resumeSave == nil { try? await Task.sleep(for: .milliseconds(2)) }
            expect(resumeSave != nil && m.taskStopBusy && m.onboarding?.record.stopPending == true,
                   "stop is pending while its OFF configuration save is paused: \(transition)")

            let guardTransition = transition.hasPrefix("guard-")
            if guardTransition {
                f.away.isAway = true; f.away.protectionReady = true; f.awayCallback?(f.away)
                for _ in 0..<500 where !m.bagGuardActive { try? await Task.sleep(for: .milliseconds(2)) }
                expect(m.bagGuardActive, "complete away protection conditions engage during stop")
                if transition == "guard-cleared" {
                    f.away.isAway = false; f.awayCallback?(f.away)
                    for _ in 0..<500 where m.bagGuardActive { try? await Task.sleep(for: .milliseconds(2)) }
                    expect(!m.bagGuardActive, "protection can clear before stop persistence completes")
                }
            } else {
                // OFF remains authoritative until verification completes.
                // Editing an inactive preference does not cancel that stop.
                switch transition {
                case "ordinary":
                    let before = (f.saved.count, f.systemAssertions.count, f.displayAssertions.count, f.helper.writes.count)
                    m.setKeepAwakeEnabled(true); m.keepAwake = true
                    expect(!m.keepAwake, "both master entry points reject ON during a pending stop")
                    expect(before == (f.saved.count, f.systemAssertions.count, f.displayAssertions.count, f.helper.writes.count) &&
                           m.taskStopBusy && m.taskStopStatus == "onboarding.stopping",
                           "rejected ON does not save, apply controls or reset the pending stop")
                case "display": m.keepDisplayAwake = false
                default: m.keepAwakeOnLidClosed = false
                }
            }

            resumeSave?.resume(); resumeSave = nil
            await m.waitForPendingOperations()
            expect(!m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "stop leaves all actual controls OFF: \(transition)")
            expect(m.taskStopOrdinary == .confirmed && m.taskStopDisplay == .confirmed && m.taskStopLid == .confirmed,
                   "guard or inactive preference changes do not discard verified release: \(transition); status=\(m.taskStopStatus), ordinary=\(m.taskStopOrdinary), display=\(m.taskStopDisplay), lid=\(m.taskStopLid)")
            expect(m.taskStopStatus == "onboarding.stopped" && !m.taskStopBusy,
                   "stop completes across protective and inactive-preference transitions: \(transition)")
            expect(m.onboarding?.record.stopPending == false && !store.bootstrap().record.stopPending,
                   "completed stop clears both live and durable recovery obligations: \(transition)")
            if m.bagGuardActive {
                f.away.isAway = false; f.awayCallback?(f.away)
                for _ in 0..<500 where m.bagGuardActive { try? await Task.sleep(for: .milliseconds(2)) }
                expect(!m.bagGuardActive, "protection clears after completed stop")
                await m.waitForPendingOperations()
            }
            expect(!m.keepAwake && m.keepDisplayAwake == (transition != "display") &&
                   m.keepAwakeOnLidClosed == (transition != "lid") &&
                   !m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "guard release leaves master OFF and retains the latest child preferences")
            m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
            expect(m.systemAwakeApplied && m.displayAwakeApplied == m.keepDisplayAwake &&
                   m.lidAwakeApplied == m.keepAwakeOnLidClosed,
                   "only an explicit ON after stop completion resumes the saved options")
            m.keepDisplayAwake = false; await m.waitForPendingOperations()
            m.sleepDisplayNow(); await m.waitForPendingOperations()
            expect(f.displaySleepRequests == 1 && m.displaySleepStatus == "display.requested",
                   "immediate sleep remains available after the user deselects display always-on")
            m.restoreSystemDefaults(); await m.waitForPendingOperations()
            expect(!store.bootstrap().record.stopPending, "a subsequent explicit stop clears its recovery journal")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}
