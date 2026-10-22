import AppKit
import Foundation

extension IntegrationTests {
    @MainActor static func onboardingAcceptance() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-onboarding-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func store(_ name: String) -> OnboardingStore { OnboardingStore(directory: root.appendingPathComponent(name)) }
        do {
            let s = store("first")
            let first = s.bootstrap()
            expect(first.requiresSetup && !first.record.existingUser, "missing config creates first-run journal")
            expect(FileManager.default.fileExists(atPath: s.url.path) && !FileManager.default.fileExists(atPath: s.configURL.path), "journal exists before default configuration")
            try! ConfigStore.save(CoddleConfig(), at: s.configURL)
            expect(s.bootstrap().requiresSetup, "in-progress journal takes priority over new config")
            var pending = first.record; pending.charge = .requested; pending.helperInstall = .requested
            try! s.save(pending)
            let resumed = s.bootstrap()
            expect(resumed.record.charge == .unknown && resumed.record.helperInstall == .unknown, "interrupted effects resume as unknown, not replayable requests")
            let old = store("old"); try! ConfigStore.save(CoddleConfig(), at: old.configURL)
            expect(!old.bootstrap().requiresSetup && old.bootstrap().record.existingUser, "valid existing installation migrates without forced wizard")
            let bad = store("bad"); try! FileManager.default.createDirectory(at: bad.directory, withIntermediateDirectories: true)
            let bytes = Data("{invalid".utf8); try! bytes.write(to: bad.configURL)
            expect(bad.bootstrap().error != nil && (try! Data(contentsOf: bad.configURL)) == bytes, "malformed configuration is preserved and blocks setup")
            expect(!FileManager.default.fileExists(atPath: bad.url.path), "malformed existing config is not marked as new installation")
            try! bytes.write(to: s.url)
            expect(s.bootstrap().error != nil && (try! Data(contentsOf: s.url)) == bytes, "malformed journal is never replaced with empty draft")
            let blocked = store("blocked"); try! Data().write(to: blocked.directory)
            expect(blocked.bootstrap().error != nil, "unwritable journal cannot begin operations")
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            let s = store("review-existing"); try! ConfigStore.save(f.config, at: s.configURL)
            let m = AppModel(services: f.services(), onboardingStore: s); await m.waitForPendingOperations()
            m.onboarding!.beginReview()
            expect(!m.setupRequired && !m.onboarding!.record.completed && m.onboarding!.record.existingUser,
                   "voluntary guide review preserves normal access for existing users")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let caps = HelperCapabilities.parse(HelperCapabilities.response)
            expect(caps?.supports(lid: true, energy: true) == true, "current helper advertises required capabilities")
            expect(HelperCapabilities.parse("ok") == nil && HelperCapabilities.parse("ok protocol=2 version=2 capabilities=lease_disablesleep") == nil, "ping and unknown protocols cannot prove readiness")
            expect(HelperManager.parseSleepDisabled("SleepDisabled 2") == nil, "invalid sleep readback stays unknown")
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.battery.percent = 10
            let s = store("happy"); let m = AppModel(services: f.services(), onboardingStore: s)
            await m.waitForPendingOperations(); let flow = m.onboarding!; await flow.refresh()
            expect(f.limitWrites.isEmpty && !f.systemAssertions.contains(true) && !f.helper.writes.contains(true), "fresh launch never starts default power policies")
            expect(f.notificationRequests == 0 && f.notifications.isEmpty, "fresh low battery does not request or send notifications")
            flow.chooseTask(.lid); await flow.installHelper()
            expect(flow.helperReady && f.helper.writes.isEmpty && flow.record.task == .lid, "preparation installs compatible helper without applying ON or losing goal")
            await flow.chooseLogin(false); await flow.chooseReminder(false)
            expect(flow.prerequisitesReady && f.notificationRequests == 0, "one-click optional declines resolve preparation")
            await flow.rememberNetwork()
            expect(flow.networkRemembered && !f.helper.writes.contains(true), "explicit network choice stores fingerprint without starting task")
            await flow.apply(); await m.waitForPendingOperations()
            expect(flow.record.completed && flow.record.charge == .confirmed && flow.record.ordinary == .confirmed && flow.record.lid == .confirmed, "successful apply requires all three actual readbacks")
            expect(f.config.keepAwake && f.config.keepAwakeOnLidClosed && f.limitWrites == [80], "plan persists intended policies and writes charge once")
            expect(s.bootstrap().record.completed, "completion is durable")
            m.restoreSystemDefaults(); await settle(); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopped" && !f.config.keepAwake && f.config.keepAwakeOnLidClosed, "unified stop preserves the lid preference while verifying OFF")
            expect(f.helper.writes.last == false && !s.bootstrap().record.stopPending, "verified stop clears recovery journal")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.helper.installed = true; f.helper.readinessOverride = .outdated
            let m = AppModel(services: f.services(), onboardingStore: store("oldhelper")); await m.waitForPendingOperations()
            let flow = m.onboarding!; await flow.refresh(); flow.chooseTask(.lid)
            expect(!flow.helperReady && !flow.helperResolved, "old responding helper blocks lid readiness")
            f.helper.installError = HelperError(message: "User canceled -128", status: 1)
            await flow.installHelper()
            expect(flow.error == "onboarding.installCanceled" && flow.record.task == .lid, "administrator cancellation keeps requested goal")
            flow.skipHelper(); expect(flow.record.helper != .skipped, "lid goal cannot silently skip helper")
            flow.skipHelper(downgrade: true)
            expect(flow.record.task == .open && flow.helperResolved, "explicit downgrade makes helper optional")
            f.authorizationResult = "notification.denied"
            await flow.chooseReminder(true)
            expect(flow.notificationResolved && f.config.lowBatteryReminder == .disabled && f.notificationRequests == 1, "OS denial persists explicit disabled reminder")
            for _ in 0..<3 { await flow.refresh(); m.refresh(); await m.waitForPendingOperations() }
            expect(f.notificationRequests == 1 && f.notifications.isEmpty, "refresh and low-battery paths cannot repeat authorization")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
            let restarted = AppModel(services: f.services(), onboardingStore: store("oldhelper")); await restarted.waitForPendingOperations(); await restarted.onboarding!.refresh()
            expect(restarted.lowBatteryReminder == .disabled && f.notificationRequests == 1, "denial survives restart without prompt")
            restarted.shutdownKeepAwake(); await restarted.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            let s = store("interrupted-denial"); var record = s.bootstrap().record
            record.reminder = .enabled; record.notificationRequest = .requested
            try! s.save(record); f.notificationState = "notification.denied"
            let m = AppModel(services: f.services(), onboardingStore: s); await m.waitForPendingOperations(); await m.onboarding!.refresh()
            expect(m.onboarding!.record.reminder == .disabled && m.onboarding!.notificationResolved && f.notificationRequests == 0,
                   "denial while app was closed resolves interrupted request without another decision or prompt")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            let s = store("revoked-permission-summary"); var record = s.bootstrap().record
            record.step = 4; record.habit = .unchanged; record.helper = .skipped
            record.login = .enabled; record.reminder = .enabled; record.notificationRequest = .confirmed
            try! s.save(record)
            f.config.lowBatteryReminder = .enabled; f.notificationState = "notification.denied"; f.login = .requiresApproval
            let m = AppModel(services: f.services(), onboardingStore: s); await m.waitForPendingOperations()
            let flow = m.onboarding!; await flow.refresh()
            expect(flow.notificationSummaryKey == "notification.denied" && flow.loginSummaryKey == "login.requiresApproval",
                   "confirmation summaries expose revoked notification permission and pending login approval")
            expect(!flow.canAdvance && !flow.notificationResolved && !flow.loginResolved,
                   "revoked live permission and pending login approval block apply")
            flow.returnToPreparation(step: 3)
            expect(flow.record.step == 3, "permission repair opens the permission page directly")
            flow.returnToPreparation(step: 2)
            expect(flow.record.step == 2, "helper repair opens the helper page directly")
            flow.returnToPreparation(step: 5)
            expect(flow.record.step == 2, "repair navigation cannot skip ahead to completion")
            flow.returnToPreparation(step: 3)
            for state in ["notification.alertsOff", "notification.unavailable", "notification.unknown"] {
                f.notificationState = state; await flow.refresh()
                expect(flow.notificationSummaryKey == state && !flow.notificationResolved,
                       "notification summary preserves actual unresolved service status: \(state)")
            }
            f.login = .notFound; await flow.refresh()
            expect(flow.loginSummaryKey == "login.notFound" && !flow.loginResolved,
                   "missing login app is not summarized as an intentional manual launch")
            f.notificationState = "notification.ready"; f.login = .enabled; await flow.refresh()
            expect(flow.notificationSummaryKey == "onboarding.notificationReady" && flow.loginSummaryKey == "onboarding.loginReady" && flow.canAdvance,
                   "ready summaries require actual service readback")
            await flow.chooseLogin(false); await flow.chooseReminder(false)
            f.notificationState = "notification.denied"; await flow.refresh()
            expect(flow.notificationSummaryKey == "onboarding.reminderOffShort" && flow.loginSummaryKey == "onboarding.loginManualShort" && flow.canAdvance,
                   "explicit optional declines use concise summaries and remain resolved")
            expect(f.notificationRequests == 0, "summary refresh never requests notification permission")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.battery = BatteryInfo(); f.clamshell = nil; f.availableEnergyModes = [.automatic]
            let m = AppModel(services: f.services(), onboardingStore: store("desktop")); await m.waitForPendingOperations()
            let flow = m.onboarding!; await flow.refresh()
            expect(!flow.hasBattery && !flow.hasLid && !flow.helperUseful && flow.record.step == 1, "desktop skips battery page, lid and unnecessary helper")
            flow.chooseTask(.lid); expect(flow.record.task == .none, "desktop cannot choose lid task")
            await flow.chooseLogin(false); await flow.apply(); await m.waitForPendingOperations()
            expect(flow.record.completed && f.notificationRequests == 0 && f.limitWrites.isEmpty, "desktop can finish without battery controls or notification permission")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.hardwareReadError = HardwareFailure(message: "unavailable")
            let m = AppModel(services: f.services(), onboardingStore: store("unknown")); await m.waitForPendingOperations()
            let flow = m.onboarding!; await flow.refresh()
            expect(!flow.hardwareKnown && !flow.canAdvance && flow.record.step == 0, "unknown hardware is neither unsupported nor actionable")
            f.hardwareReadError = nil; f.supportsLimit = true; f.availableLimits = [85, 100]
            await flow.refresh(); expect(!flow.canAdvance, "unavailable 80 percent target is not silently approximated")
            expect(flow.requiresLimitSelection && flow.selectedLimit == nil && flow.record.targetLimit == 80,
                   "unsupported draft exposes an empty selection without replacing the stored target")
            flow.chooseLimit(82)
            expect(flow.selectedLimit == nil && flow.record.targetLimit == 80, "unsupported explicit target is rejected")
            flow.skipHelper(); await flow.chooseLogin(false); await flow.chooseReminder(false)
            await flow.apply()
            expect(f.limitWrites.isEmpty && !flow.record.completed && !flow.prerequisitesReady,
                   "direct apply cannot bypass supported-target selection or write an approximate limit")
            flow.chooseLimit(85)
            expect(flow.canAdvance && flow.selectedLimit == 85 && !flow.requiresLimitSelection,
                   "user can explicitly choose a supported alternative")
            flow.next(); flow.next(); flow.next()
            f.availableLimits = [90, 100]; await flow.refresh()
            expect(flow.record.step == 4 && !flow.canAdvance, "a changed capability invalidates an unstarted confirmation")
            flow.returnToLimitSelection()
            expect(flow.record.step == 0, "an unstarted charging plan can return to supported-limit selection")
            flow.chooseLimit(90)
            f.networkFingerprint = nil; await flow.refresh()
            expect(!flow.networkAvailable, "offline network cannot be remembered")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        for existingUser in [false, true] {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.availableLimits = [90, 100]; f.hardwareLimit = (90, true)
            f.config.smartEnabled = true; f.config.manualLimit = 95; f.config.holdLimit = existingUser ? 90 : 80
            f.config.keepAwake = true; f.config.lowBatteryReminder = .disabled
            let s = store("unavailable-limit-recovery-\(existingUser)"); var record = s.bootstrap().record
            record.step = 4; record.existingUser = existingUser; record.charge = .failed
            record.task = .open; record.ordinary = .confirmed; record.helper = .skipped
            record.login = .skipped; record.reminder = .disabled
            try! s.save(record)
            let m = AppModel(services: f.services(), onboardingStore: s); await m.waitForPendingOperations()
            let flow = m.onboarding!; await flow.refresh()
            expect(flow.requiresLimitSelection && !flow.canAdvance, "capability changes block a stale target at confirmation")
            flow.returnToLimitSelection()
            expect(flow.record.step == 4, "a partially applied plan cannot reopen and rewrite earlier choices")
            let chargeWrites = f.limitWrites.count
            flow.keepCurrentChargeSetup(); await flow.waitForPersistence()
            expect(flow.record.habit == .unchanged && flow.record.charge == .idle && flow.record.ordinary == .confirmed && flow.prerequisitesReady,
                   "keeping current charging state abandons only the unavailable charge plan")
            expect(f.limitWrites.count == chargeWrites, "keeping current charging state performs no hardware write")
            await flow.apply(); await m.waitForPendingOperations()
            expect(flow.record.completed && f.limitWrites.count == chargeWrites && f.hardwareLimit.limit == 90,
                   "completion preserves actual charging state after abandoning an unavailable target")
            if existingUser {
                expect(f.config.smartEnabled && f.config.manualLimit == 95 && f.config.holdLimit == 90,
                       "existing user charge configuration is preserved by recovery")
            } else {
                expect(!f.config.smartEnabled && f.config.manualLimit == 90,
                       "first setup adopts actual native state rather than replaying the abandoned target")
            }
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.helper.installed = true
            let m = AppModel(services: f.services(), onboardingStore: store("partial")); await m.waitForPendingOperations()
            let flow = m.onboarding!; await flow.refresh(); flow.chooseTask(.lid); await flow.chooseLogin(false); await flow.chooseReminder(false)
            f.helper.writeError = HelperError(message: "denied")
            await flow.apply(); await m.waitForPendingOperations()
            expect(!flow.record.completed && flow.record.charge == .confirmed && flow.record.ordinary == .confirmed && flow.record.lid == .failed, "partial apply preserves confirmed charge and ordinary results")
            let chargeWrites = f.limitWrites.count
            f.helper.writeError = nil; await flow.apply(); await m.waitForPendingOperations()
            expect(flow.record.completed && f.limitWrites.count == chargeWrites, "retry never rewrites successful charge operation")
            f.helper.writeError = HelperError(message: "OFF failed")
            m.restoreSystemDefaults()
            expect(flow.hasStopResult && !flow.stopNeedsRetry && flow.ordinaryResultKey == "onboarding.stopping" && flow.lidResultKey == "onboarding.stopping",
                   "stop begins with current stopping results instead of previous confirmed ON")
            await settle(); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopPartial" && m.taskStopOrdinary == .confirmed && m.taskStopLid == .failed, "failed OFF shows separate confirmed ordinary and unconfirmed lid state")
            expect(flow.record.stopPending && !f.config.keepAwake && f.config.keepAwakeOnLidClosed, "failed stop persists master OFF, saved lid preference and recovery obligation")
            expect(flow.stopNeedsRetry && flow.ordinaryResultKey == "onboarding.stopConfirmed" && flow.lidResultKey == "onboarding.stopUnconfirmed",
                   "partial stop presentation supersedes old confirmed application results")
            flow.beginReview()
            expect(flow.record.stopPending && flow.stopNeedsRetry, "reopening the guide cannot discard an unresolved stop journal")
            f.helper.sleepDisabled = nil
            m.restoreSystemDefaults(); await settle(); await m.waitForPendingOperations()
            expect(m.taskStopLid == .unknown && flow.lidResultKey == "onboarding.stopUnconfirmed" && flow.stopNeedsRetry,
                   "unknown stop readback cannot revive the historical confirmed ON state")
            f.configSaveError = NSError(domain: "fixture", code: 1); f.helper.writeError = nil
            m.restoreSystemDefaults(); await settle(); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopSaveFailed" && flow.stopNeedsRetry && flow.ordinaryResultKey == "onboarding.stopConfirmed",
                   "verified OFF with unsaved intent remains a retryable stop result")
            f.configSaveError = nil
            f.helper.writeError = nil; m.restoreSystemDefaults(); await settle(); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopped", "explicit stop retry verifies both paths")
            expect(flow.hasStopResult && !flow.stopNeedsRetry && flow.record.task == .none && flow.ordinaryResultKey == "onboarding.stopConfirmed",
                   "completed setup no longer claims an active task after stop, while retaining the verified stop result")
            flow.beginReview(); flow.chooseHabit(.unchanged); flow.chooseTask(.open)
            expect(!flow.hasStopResult, "a new guide review clears a finished stop presentation")
            await flow.refresh(); await flow.chooseLogin(false); await flow.apply(); await m.waitForPendingOperations()
            expect(flow.record.completed && !flow.hasStopResult && flow.ordinaryResultKey == "onboarding.result.confirmed",
                   "a new explicit task application clears the earlier stop presentation")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.config.manualLimit = 80; f.hardwareLimit = (90, true)
            let s = store("interrupted"); var record = s.bootstrap().record
            record.charge = .requested; record.step = 4; record.helper = .skipped; record.login = .skipped; record.reminder = .disabled
            try! s.save(record); f.config.lowBatteryReminder = .disabled
            let m = AppModel(services: f.services(), onboardingStore: s); await m.waitForPendingOperations()
            await m.onboarding!.refresh(); await m.onboarding!.apply()
            expect(f.limitWrites.isEmpty && m.onboarding!.record.charge == .failed, "unknown interrupted charge reads actual state without immediate repeated write")
            await m.onboarding!.apply(); await m.waitForPendingOperations()
            expect(f.limitWrites == [80] && m.onboarding!.record.completed, "separate retry applies confirmed failure")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.installed = true
            let m = AppModel(services: f.services(), onboardingStore: store("late-on")); await m.waitForPendingOperations()
            let flow = m.onboarding!; await flow.refresh(); flow.chooseHabit(.unchanged); flow.chooseTask(.lid); await flow.chooseLogin(false); await flow.chooseReminder(false)
            let gate = DispatchSemaphore(value: 0); f.helper.writeGate = gate
            let apply = Task { await flow.apply() }
            for _ in 0..<100 where flow.record.lid != .requested { await settle() }
            m.restoreSystemDefaults(); gate.signal(); await apply.value
            await m.waitForPendingOperations(); await settle()
            expect(!m.keepAwake && m.keepAwakeOnLidClosed && f.helper.sleepDisabled == false, "OFF wins after delayed ON completes while retaining the preference")
            expect(!flow.record.completed && flow.record.task == .none && flow.record.lid == .idle, "late ON result cannot resurrect stopped draft or mark completion: completed=\(flow.record.completed) task=\(flow.record.task) lid=\(flow.record.lid) stop=\(m.taskStopStatus) pending=\(flow.record.stopPending) busy=\(m.taskStopBusy)")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.installed = true; f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            f.config.keepDisplayAwake = true
            let s = store("stop-restart"); var record = s.bootstrap().record; record.stopPending = true; record.task = .lid; record.ordinary = .confirmed; record.lid = .confirmed
            try! s.save(record)
            let m = AppModel(services: f.services(), onboardingStore: s); await m.waitForPendingOperations(); await settle()
            expect(!f.helper.writes.contains(true) && !f.systemAssertions.contains(true) && f.config.keepAwakeOnLidClosed && !f.displayAssertions.contains(true) && f.config.keepDisplayAwake && !f.config.keepAwake, "pending stop restart keeps master OFF without losing either child preference")
            expect(m.onboarding!.hasStopResult && m.onboarding!.ordinaryResultKey != "onboarding.result.confirmed" && m.onboarding!.lidResultKey != "onboarding.result.confirmed",
                   "recovered stop result never exposes the pre-restart application journal as active")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            let m = AppModel(services: f.services(), onboardingStore: store("save-failed")); await m.waitForPendingOperations()
            let flow = m.onboarding!; await flow.refresh()
            f.configSaveError = NSError(domain: "fixture", code: 1)
            await flow.chooseReminder(false)
            expect(!flow.notificationResolved && flow.error == "config.saveFailed", "failed preference save cannot masquerade as completed preparation")
            expect(flow.notificationSummaryKey == "config.saveFailed", "failed reminder persistence is visible in the confirmation summary")
            f.configSaveError = nil; await flow.chooseReminder(false)
            expect(flow.notificationResolved, "preference persistence can be explicitly retried")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}
