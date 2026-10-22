import Foundation

extension IntegrationTests {
    @MainActor static func hardwareRefreshRecoveryTests() async {
        for key in ["error.hardwareTimeout", "error.hardwarePending", "read failed"] {
            let fixture = ModelFixture(); defer { fixture.clean() }
            let model = AppModel(services: fixture.services())
            await model.waitForPendingOperations()
            fixture.hardwareReadError = HardwareFailure(message: key, awaitingRecovery: true)
            model.refresh(); await model.waitForPendingOperations()
            expect(model.lastError == key, "failed hardware refresh exposes its error: \(key)")
            fixture.hardwareReadError = nil
            fixture.battery.percent = 79
            model.refresh(); await model.waitForPendingOperations()
            expect(model.battery.percent == 79, "recovered refresh accepts a fresh hardware snapshot")
            expect(model.lastError == nil, "recovered hardware refresh clears its obsolete error: \(key)")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        do {
            let fixture = ModelFixture(); defer { fixture.clean() }
            let model = AppModel(services: fixture.services())
            await model.waitForPendingOperations()
            fixture.hardwareReadError = HardwareFailure(message: "error.hardwarePending", awaitingRecovery: true)
            model.refresh(); await model.waitForPendingOperations()
            model.lastError = "error.hardwarePending"
            fixture.hardwareReadError = nil
            model.refresh(); await model.waitForPendingOperations()
            expect(model.lastError == "error.hardwarePending", "hardware recovery preserves a newer error even when its text is identical")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        do {
            let fixture = ModelFixture(); defer { fixture.clean() }
            let model = AppModel(services: fixture.services())
            await model.waitForPendingOperations()
            fixture.hardwareReadError = HardwareFailure(message: "error.hardwarePending", awaitingRecovery: true)
            model.refresh(); await model.waitForPendingOperations()
            model.lastError = "A newer unrelated failure"
            fixture.hardwareReadError = nil
            model.refresh(); await model.waitForPendingOperations()
            expect(model.lastError == "A newer unrelated failure", "hardware recovery preserves a newer unrelated error")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        do {
            let fixture = ModelFixture(); defer { fixture.clean() }
            fixture.supportsLimit = true
            fixture.battery.externalConnected = true
            let model = AppModel(services: fixture.services())
            await model.waitForPendingOperations()
            fixture.hardwareReadError = HardwareFailure(message: "error.hardwarePending", awaitingRecovery: true)
            model.refresh(); await model.waitForPendingOperations()
            fixture.hardwareReadError = nil
            fixture.nextLimitError = "error.hardwarePending"
            model.applyLimit(85); await model.waitForPendingOperations()
            expect(model.chargeFeedbackError == "error.hardwarePending", "charge failure can share the hardware-read error text")
            expect(model.lastError == "error.hardwarePending", "successful reads must preserve an unresolved charge failure with identical text")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
    }
}
