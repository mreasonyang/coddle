import Foundation

/// Test state used exclusively across the main actor and the blocking storage worker.
private final class PersistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedValue = false
    private var failureValue = false
    private var values: [Int] = []
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return requestedValue }
    var failWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failureValue }
        set { lock.lock(); failureValue = newValue; lock.unlock() }
    }
    var saved: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    func markRequested() { lock.lock(); requestedValue = true; lock.unlock() }
    func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
    func clear() { lock.lock(); values.removeAll(); lock.unlock() }
}

extension IntegrationTests {
    @MainActor static func persistenceTests() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-persistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        // The delay is a real blocking operation on the production persistence
        // executor. The UI must continue while defaults remain unable to write.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            var loaded = f.config; loaded.smartEnabled = true; loaded.holdLimit = 85
            let snapshot = loaded
            var services = f.services()
            services.loadConfig = {
                try await PersistenceIO.shared.run {
                    Thread.sleep(forTimeInterval: 0.25)
                    return snapshot
                }
            }
            let model = AppModel(services: services)
            await Task.yield()
            let started = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(20))
            expect(ContinuousClock.now - started < .milliseconds(150) && model.startupLoading,
                   "slow configuration load leaves the main actor responsive")
            expect(f.limitWrites.isEmpty && !f.systemAssertions.contains(true) && !f.helper.writes.contains(true),
                   "startup placeholders never apply a default charging or keep-awake intent")
            await model.waitForPendingOperations()
            expect(f.limitWrites == [85] && !model.startupLoading,
                   "only the loaded charging intent is applied after storage startup")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // Three immediate UI edits retain FIFO persistence despite a slow first
        // write; disk and visible model end with the newest complete snapshot.
        do {
            let f = ModelFixture(); defer { f.clean() }
            let probe = PersistenceProbe()
            let file = root.appendingPathComponent("ordered/config.json")
            var services = f.services()
            services.saveConfig = { snapshot in
                try await PersistenceIO.shared.run {
                    if snapshot.lowBatteryWarnPercent == 21 { Thread.sleep(forTimeInterval: 0.2) }
                    try ConfigStore.save(snapshot, at: file)
                    probe.append(snapshot.lowBatteryWarnPercent)
                }
            }
            let model = AppModel(services: services); await model.waitForPendingOperations()
            probe.clear()
            model.lowBatteryWarnPercent = 21
            model.lowBatteryWarnPercent = 22
            model.lowBatteryWarnPercent = 23
            let started = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(20))
            expect(ContinuousClock.now - started < .milliseconds(150), "slow configuration save never occupies the main actor")
            await model.waitForPendingOperations()
            let stored = try? await ConfigStore.readAsync(at: file)
            expect(probe.saved == [21, 22, 23] && stored?.lowBatteryWarnPercent == 23 && model.configError == nil,
                   "ordered configuration writes persist the newest snapshot last")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            let store = OnboardingStore(directory: root.appendingPathComponent("failed-apply"))
            let model = AppModel(services: f.services(), onboardingStore: store)
            await model.waitForPendingOperations()
            f.configSaveError = NSError(domain: "storage-test", code: 1)
            let result = await model.applySetupCharge(habit: .desk, target: 85)
            let awake = await model.applySetupAwake(.open)
            expect(result == .failed && awake.0 == .failed && f.limitWrites.isEmpty && !f.systemAssertions.contains(true),
                   "failed intent persistence prevents setup charge and awake effects")
            expect(model.configError == "config.saveFailed", "asynchronous save failure remains visible")
            f.configSaveError = nil
            _ = await model.saveConfig().value
            expect(model.configError == nil, "explicit successful save retry clears storage error")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            let probe = PersistenceProbe()
            var store = OnboardingStore(directory: root.appendingPathComponent("slow-journal"))
            store.writeData = { data, url in
                let record = try JSONDecoder().decode(OnboardingRecord.self, from: data)
                if record.ordinary == .requested {
                    probe.markRequested()
                    Thread.sleep(forTimeInterval: 0.2)
                }
                try data.write(to: url, options: .atomic)
            }
            let model = AppModel(services: f.services(), onboardingStore: store)
            await model.waitForPendingOperations()
            let flow = model.onboarding!
            await flow.refresh(); flow.chooseHabit(.unchanged); flow.chooseTask(.open); flow.skipHelper()
            await flow.chooseLogin(false); await flow.chooseReminder(false)
            let applying = Task { await flow.apply() }
            for _ in 0..<100 where !probe.requested { try? await Task.sleep(for: .milliseconds(5)) }
            let started = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(20))
            expect(probe.requested && ContinuousClock.now - started < .milliseconds(150),
                   "journal atomic writes run outside the main actor")
            expect(!f.systemAssertions.contains(true), "setup waits for the requested journal to finish before enabling awake")
            await applying.value; await model.waitForPendingOperations()
            expect(flow.record.completed && f.systemAssertions.contains(true), "successful journal commit permits setup and durable completion")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.installed = true; f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            let probe = PersistenceProbe()
            var store = OnboardingStore(directory: root.appendingPathComponent("failed-stop"))
            store.writeData = { data, url in
                if probe.failWrites { throw NSError(domain: "journal-test", code: 1) }
                try data.write(to: url, options: .atomic)
            }
            var record = OnboardingRecord(); record.completed = true; record.existingUser = true; record.task = .lid
            let model = AppModel(services: f.services(), startup: OnboardingStartup(record: record), onboardingStore: store)
            await model.waitForPendingOperations()
            probe.failWrites = true; f.configSaveError = NSError(domain: "storage-test", code: 2)
            model.restoreSystemDefaults(); await model.waitForPendingOperations()
            expect(f.helper.sleepDisabled == false && f.systemAssertions.last == false,
                   "stop still performs safe OFF when configuration and journal writes fail")
            expect(model.taskStopStatus == "onboarding.stopSaveFailed" && model.onboarding!.record.stopPending,
                   "failed stop persistence leaves a visible durable-recovery obligation")
            probe.failWrites = false; f.configSaveError = nil
            model.restoreSystemDefaults(); await model.waitForPendingOperations()
            expect(model.taskStopStatus == "onboarding.stopped" && !model.onboarding!.record.stopPending,
                   "stop retry clears the obligation only after persistence and OFF readback succeed")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            var loaded = f.config; loaded.keepAwake = true; loaded.keepAwakeOnLidClosed = true
            let snapshot = loaded
            var services = f.services()
            services.loadConfig = {
                try await PersistenceIO.shared.run { Thread.sleep(forTimeInterval: 0.1); return snapshot }
            }
            let model = AppModel(services: services)
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
            expect(!f.systemAssertions.contains(true) && !f.helper.writes.contains(true) && f.limitWrites.isEmpty,
                   "quitting during startup cannot apply a late persisted ON intent")
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.lowBatteryReminder = .undecided
            let probe = PersistenceProbe()
            var services = f.services()
            services.saveConfig = { snapshot in
                try await PersistenceIO.shared.run {
                    if snapshot.lowBatteryReminder == .enabled {
                        probe.markRequested()
                        Thread.sleep(forTimeInterval: 0.15)
                        throw NSError(domain: "old-save", code: 1)
                    }
                }
                f.config = snapshot
            }
            let model = AppModel(services: services); await model.waitForPendingOperations()
            let oldSave = Task { await model.setSetupReminder(.enabled) }
            for _ in 0..<100 where !probe.requested { try? await Task.sleep(for: .milliseconds(5)) }
            // This is a direct settings edit, so the old async method cannot
            // rely only on a method-local generation to detect supersession.
            model.lowBatteryReminder = .disabled
            _ = await oldSave.value; await model.waitForPendingOperations()
            expect(model.lowBatteryReminder == .disabled && f.config.lowBatteryReminder == .disabled && model.configError == nil,
                   "a failed old reminder save cannot roll back a newer successful configuration")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            var failLoad = true
            var services = f.services()
            services.loadConfig = {
                if failLoad { throw NSError(domain: "bad-config", code: 1) }
                var config = f.config; config.smartEnabled = true; config.holdLimit = 85
                return config
            }
            let model = AppModel(services: services); await model.waitForPendingOperations()
            expect(model.configError == "config.loadFailed" && f.limitWrites.isEmpty,
                   "failed startup configuration keeps device mutation gated")
            failLoad = false; model.reloadConfig(); await model.waitForPendingOperations()
            expect(model.configError == nil && f.limitWrites == [85],
                   "repairing and reloading configuration restores device gates using the loaded intent")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            let probe = PersistenceProbe()
            var slowReload = false
            var services = f.services()
            services.loadConfig = {
                guard slowReload else { return f.config }
                var config = f.config
                config.smartEnabled = true; config.holdLimit = 85; config.keepAwake = true
                let snapshot = config
                return try await PersistenceIO.shared.run {
                    probe.markRequested()
                    Thread.sleep(forTimeInterval: 0.15)
                    return snapshot
                }
            }
            let model = AppModel(services: services); await model.waitForPendingOperations()
            slowReload = true; model.reloadConfig()
            for _ in 0..<100 where !probe.requested { try? await Task.sleep(for: .milliseconds(5)) }
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
            expect(!model.smartEnabled && f.limitWrites.isEmpty && !f.systemAssertions.contains(true) && model.configReloadTask == nil,
                   "quit cancels a pending reload without applying its late intent or retaining a completed task")
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.config.smartEnabled = true; f.config.holdLimit = 85; f.config.keepAwake = true
            f.hardwareLimit = (100, false)
            let store = OnboardingStore(directory: root.appendingPathComponent("recovery-read-failure"))
            try! await ConfigStore.saveAsync(f.config, at: store.configURL)
            var services = f.services()
            services.loadConfig = {
                throw NSError(domain: "recovery-read", code: 1)
            }
            let startup = OnboardingStartup(record: OnboardingRecord(), error: "onboarding.storageFailed")
            let model = AppModel(services: services, startup: startup, onboardingStore: store)
            await model.waitForPendingOperations()
            await model.onboarding!.retryStorage()
            model.refresh(); await model.waitForPendingOperations()
            expect(model.configError == "config.loadFailed" && !model.setupAllowsCharge && !model.setupAllowsAwake,
                   "journal recovery does not reopen device gates when its following configuration read fails")
            expect(f.limitWrites.isEmpty && !f.systemAssertions.contains(true),
                   "failed recovery config read cannot apply a prior or default hardware intent")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
    }
}
