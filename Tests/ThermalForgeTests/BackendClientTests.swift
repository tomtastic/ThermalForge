import Foundation
import Testing
@testable import ThermalForgeCore

private actor ClientTestBackend {
    var state = BackendSnapshot(generation: "one", recoveryEpoch: "epoch-one", acknowledgedControl: .apple, restoration: .verified)
    var configuration = BackendConfiguration()
    var requests: [BackendRequest] = []
    var failNext = false
    var wrongRequestID = false
    var rejectUpdates = false
    var acquireDelay: UInt64 = 0
    var acquireEntered = false
    var delayStatus = false
    var statusEntered = false
    var restoreDelay: UInt64 = 0
    var restoreEntered = false

    func transport(_ data: Data) async throws -> Data {
        let request = try JSONDecoder().decode(BackendRequest.self, from: data)
        requests.append(request)
        if failNext { failNext = false; throw DaemonError.timedOut }
        var response = BackendResponse(requestID: wrongRequestID ? "wrong" : request.requestID)
        switch request.operation {
        case .acquire, .startCalibration:
            acquireEntered = true
            if acquireDelay > 0 { try await Task.sleep(nanoseconds: acquireDelay) }
            if request.automaticRecovery && request.recoveryEpoch != state.recoveryEpoch {
                response.ok = false
                response.error = DaemonErrorPayload(code: "recoveryRevoked", message: "Automatic recovery was revoked")
            } else if let owner = state.owner, owner != request.session,
               !(request.takeover && state.ownerKind == .gui) {
                response.ok = false
                response.error = DaemonErrorPayload(code: "busy", message: "Another session owns control")
            } else {
                state.owner = request.session
                state.ownerKind = request.clientKind
                state.requestedIntent = request.intent
                if request.operation == .startCalibration {
                    state.calibration = CalibrationJobSnapshot(id: "job", phase: .running)
                }
            }
        case .release:
            if request.session == state.owner { state.owner = nil; state.lastSessionEndReason = .released }
        case .restoreApple:
            restoreEntered = true
            if restoreDelay > 0 { try await Task.sleep(nanoseconds: restoreDelay) }
            state.owner = nil; state.lastSessionEndReason = .explicitAuto
        case .updateConfiguration:
            if rejectUpdates {
                response.ok = false
                response.error = DaemonErrorPayload(code: "revisionConflict", message: "Concurrent edit")
            } else if var proposed = request.configuration { proposed.revision += 1; configuration = proposed }
        case .importLegacy:
            if !configuration.importedLegacy, let imported = request.legacyImport?.configuration {
                configuration = imported; configuration.importedLegacy = true
            }
        default: break
        }
        state.sequence = (state.sequence ?? 0) + 1
        response.snapshot = state
        response.configuration = configuration
        if request.operation == .status, delayStatus {
            delayStatus = false
            statusEntered = true
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try JSONEncoder().encode(response)
    }

    func delayAcquisition() { acquireDelay = 100_000_000 }
    func delayNextStatus() { delayStatus = true; statusEntered = false }
    func hasEnteredStatus() -> Bool { statusEntered }
    func delayRestoration() { restoreDelay = 100_000_000 }
    func hasEnteredRestoration() -> Bool { restoreEntered }
    func hasEnteredAcquire() -> Bool { acquireEntered }
    func currentOwner() -> ControlSession? { state.owner }
    func setFailure() { failNext = true }
    func setWrongID() { wrongRequestID = true }
    func setConflict() { rejectUpdates = true }
    func end(_ reason: SessionEndReason) {
        if let owner = state.owner { state.endedSessions[owner.id] = reason }
        state.owner = nil; state.ownerKind = nil; state.lastSessionEndReason = reason
        if reason == .explicitAuto { state.recoveryEpoch = UUID().uuidString }
    }
    func restart() {
        state = BackendSnapshot(generation: "two", recoveryEpoch: state.recoveryEpoch, acknowledgedControl: .apple, restoration: .verified)
    }
    func takeover() {
        if let owner = state.owner { state.endedSessions[owner.id] = .takeover }
        state.recoveryEpoch = UUID().uuidString
        state.owner = ControlSession(id: "other", generation: state.generation)
        state.ownerKind = .cli
        state.lastSessionEndReason = .takeover
    }
    func operations() -> [BackendOperation] { requests.map(\.operation) }
}

@Suite struct BackendClientTests {
    @Test func supersedingAutoBeforeDispatchRetainsTheExistingSession() async throws {
        let server = ClientTestBackend()
        let client = BackendClient(transport: { try await server.transport($0) })
        let original = try await client.acquire(.maximum).owner
        await server.delayNextStatus()
        let restoring = Task { try await client.restoreApple() }
        while !(await server.hasEnteredStatus()) { await Task.yield() }
        restoring.cancel()
        _ = try await client.acquire(.rpm(3000))
        _ = try? await restoring.value
        #expect(await client.ownsControl)
        #expect(await server.currentOwner() == original)
        #expect(await server.operations().contains(.restoreApple) == false)
    }
    @Test func laterSelectionWaitsForPendingAppleRestoration() async throws {
        let server = ClientTestBackend()
        await server.delayRestoration()
        let client = BackendClient(transport: { try await server.transport($0) })
        _ = try await client.acquire(.maximum)
        let restoring = Task { try await client.restoreApple() }
        while !(await server.hasEnteredRestoration()) { await Task.yield() }
        _ = try await client.acquire(.rpm(3000))
        _ = try await restoring.value
        #expect(await client.ownsControl)
        #expect(await client.snapshot?.requestedIntent == .rpm(3000))
        #expect(await server.currentOwner() == client.snapshot?.owner)
    }
    @Test func outOfOrderStatusCannotReplaceNewerOwnershipOrGeneration() async throws {
        for restart in [false, true] {
            let server = ClientTestBackend()
            let client = BackendClient(transport: { try await server.transport($0) })
            _ = try await client.acquire(.maximum)
            await server.delayNextStatus()
            let old = Task { try await client.status() }
            while !(await server.hasEnteredStatus()) { await Task.yield() }
            if restart { await server.restart() } else { await server.end(.explicitAuto) }
            let current = try await client.status()
            _ = try await old.value
            #expect(await client.snapshot?.owner == nil)
            #expect(await client.snapshot?.generation == current.generation)
            #expect(await client.ownsControl == false)
        }
    }

    @Test func observationDuringAcquisitionDoesNotDiscardCandidateSession() async throws {
        let server = ClientTestBackend()
        await server.delayAcquisition()
        let client = BackendClient(transport: { try await server.transport($0) })
        let acquisition = Task { try await client.acquire(.maximum) }
        while !(await server.hasEnteredAcquire()) { await Task.yield() }
        _ = try await client.status()
        _ = try await acquisition.value
        #expect(await client.ownsControl)
        _ = try await client.release()
        #expect(await server.currentOwner() == nil)
    }

    @Test func observationNeverAcquiresOrRenews() async throws {
        let server = ClientTestBackend()
        let client = BackendClient(transport: { try await server.transport($0) })
        _ = try await client.status()
        _ = try await client.maintain()
        _ = try await client.release()
        #expect(await server.operations() == [.status, .status])
    }

    @Test func releaseWaitsForPendingAcquisition() async throws {
        let server = ClientTestBackend()
        await server.delayAcquisition()
        let client = BackendClient(transport: { try await server.transport($0) })
        let acquisition = Task { try await client.acquire(.maximum) }
        while !(await server.hasEnteredAcquire()) { await Task.yield() }
        _ = try await client.release()
        _ = try await acquisition.value
        #expect(await server.currentOwner() == nil)
        #expect(await client.ownsControl == false)
        #expect(await server.operations() == [.status, .acquire, .release])
    }

    @Test func statusDoesNotRenewOwnedSession() async throws {
        let server = ClientTestBackend()
        let client = BackendClient(transport: { try await server.transport($0) })
        _ = try await client.acquire(.rpm(3000))
        _ = try await client.status()
        #expect(await server.operations() == [.status, .acquire, .status])
        _ = try await client.maintain()
        #expect(await server.operations() == [.status, .acquire, .status, .renew])
    }

    @Test func takeoverLeavesGUIObservingAfterCLIExit() async throws {
        let server = ClientTestBackend()
        let gui = BackendClient(kind: .gui, transport: { try await server.transport($0) })
        _ = try await gui.acquire(.profile("smart"))
        await server.takeover()
        _ = try await gui.maintain()
        #expect(await gui.ownsControl == false)
        _ = try await gui.release()
        await server.end(.released)
        _ = try await gui.maintain()
        #expect(await server.operations().filter { $0 == .acquire }.count == 1)
        #expect(await server.operations().contains(.release) == false)
        _ = try await gui.acquire(.profile("balanced"))
        #expect(await gui.ownsControl)
    }

    @Test func explicitAutoBeatsCommunicationRecovery() async throws {
        let server = ClientTestBackend()
        let gui = BackendClient(kind: .gui, transport: { try await server.transport($0) })
        _ = try await gui.acquire(.profile("smart"))
        await server.setFailure()
        do { _ = try await gui.status(); Issue.record("Expected timeout") } catch {}
        await server.end(.explicitAuto)
        _ = try await gui.maintain()
        _ = try await gui.maintain()
        #expect(await server.operations().filter { $0 == .acquire }.count == 1)
    }

    @Test func missedTakeoverAndCLIExpiryNeverReacquires() async throws {
        let server = ClientTestBackend()
        let gui = BackendClient(kind: .gui, transport: { try await server.transport($0) })
        _ = try await gui.acquire(.profile("smart"))
        await server.setFailure()
        do { _ = try await gui.status() } catch {}
        await server.takeover()
        await server.end(.clientExpired)
        _ = try await gui.maintain()
        #expect(await gui.ownsControl == false)
        #expect(await server.operations().filter { $0 == .acquire }.count == 1)
    }

    @Test func missedAutoSurvivesBackendRestart() async throws {
        let server = ClientTestBackend()
        let gui = BackendClient(kind: .gui, transport: { try await server.transport($0) })
        _ = try await gui.acquire(.profile("smart"))
        await server.end(.explicitAuto)
        await server.restart()
        do { _ = try await gui.maintain(); Issue.record("Expected recovery revoked") } catch {}
        _ = try await gui.maintain()
        #expect(await gui.ownsControl == false)
        #expect(await server.operations().filter { $0 == .acquire }.count == 2)
        _ = try await gui.acquire(.profile("smart"))
        #expect(await gui.ownsControl)
    }

    @Test func guiRecoversProfileAfterBackendRestart() async throws {
        let server = ClientTestBackend()
        let gui = BackendClient(kind: .gui, transport: { try await server.transport($0) })
        _ = try await gui.acquire(.profile("smart"))
        await server.restart()
        let state = try await gui.maintain()
        #expect(state.owner?.generation == "two")
        #expect(state.requestedIntent == .profile("smart"))
        #expect(await server.operations().filter { $0 == .acquire }.count == 2)
    }

    @Test func cliManualDoesNotRestartAfterBackendFailure() async throws {
        let server = ClientTestBackend()
        let client = BackendClient(transport: { try await server.transport($0) })
        _ = try await client.acquire(.maximum)
        await server.restart()
        _ = try await client.maintain()
        #expect(await client.ownsControl == false)
        #expect(await server.operations().filter { $0 == .acquire }.count == 1)
    }

    @Test func leaseExpiryWithoutCommunicationFailureNeedsExplicitSelection() async throws {
        let server = ClientTestBackend()
        let gui = BackendClient(kind: .gui, transport: { try await server.transport($0) })
        _ = try await gui.acquire(.profile("smart"))
        await server.end(.clientExpired)
        _ = try await gui.maintain()
        #expect(await gui.ownsControl == false)
        #expect(await server.operations().filter { $0 == .acquire }.count == 1)
    }

    @Test func busyDoesNotRetainOwnership() async throws {
        let server = ClientTestBackend()
        await server.takeover()
        let client = BackendClient(transport: { try await server.transport($0) })
        do { _ = try await client.acquire(.maximum, takeover: true); Issue.record("Expected busy") } catch {}
        _ = try await client.release()
        #expect(await server.operations().contains(.release) == false)
    }

    @Test func responseIdentityMismatchIsRejected() async throws {
        let server = ClientTestBackend()
        await server.setWrongID()
        let client = BackendClient(transport: { try await server.transport($0) })
        do { _ = try await client.status(); Issue.record("Expected identity rejection") } catch {}
    }

    @Test func configurationConflictIsNotRetried() async throws {
        let server = ClientTestBackend()
        await server.setConflict()
        let client = BackendClient(transport: { try await server.transport($0) })
        var configuration = try await client.configuration()
        configuration.rulesEnabled = false
        do { _ = try await client.updateConfiguration(configuration); Issue.record("Expected conflict") } catch {}
        #expect(await server.operations() == [.configuration, .updateConfiguration])
    }

    @Test func calibrationIsSessionBoundAndObserversDoNotRenewIt() async throws {
        let server = ClientTestBackend()
        let controller = BackendClient(transport: { try await server.transport($0) })
        let state = try await controller.startCalibration(CalibrationJobParameters())
        #expect(state.calibration?.id == "job")
        let observer = BackendClient(transport: { try await server.transport($0) })
        _ = try await observer.maintain()
        _ = try await observer.release()
        #expect(await server.operations().contains(.renew) == false)
        #expect(await server.operations().contains(.release) == false)
    }
}

@Suite struct LegacyConfigurationReaderTests {
    @Test func importPreservesFilesAndDefaultsAndExportsValues() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent("Library/Application Support/ThermalForge")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("profiles"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "ThermalForgeClientMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("custom", forKey: "lastProfileID")
        defaults.set(false, forKey: "rulesEnabled")
        defaults.set(true, forKey: "customRuleEnabled")
        defaults.set(70, forKey: "customRuleTriggerTempC")
        defaults.set(65, forKey: "customRuleReleaseTempC")
        defaults.set(80, forKey: "customRuleFanPercent")
        let profile = FanProfile(id: "custom", name: "Custom", curve: FanProfile.balanced.curve)
        let profileBytes = try JSONEncoder().encode(profile)
        let profileFile = directory.appendingPathComponent("profiles/custom.json")
        try profileBytes.write(to: profileFile)
        let corruptFile = directory.appendingPathComponent("calibration_lid_open.json")
        let corrupt = Data("bad calibration".utf8)
        try corrupt.write(to: corruptFile)
        let legacy = LegacyConfigurationReader.read(homeDirectory: home, defaults: defaults)
        #expect(legacy.configuration.selectedProfileID == "custom")
        #expect(!legacy.configuration.rulesEnabled)
        #expect(legacy.configuration.rules.first?.condition.valueCelsius == 70)
        #expect(legacy.configuration.rules.first?.action == .setFanPercent(0.8))
        #expect(legacy.calibration.isEmpty)
        #expect(try Data(contentsOf: profileFile) == profileBytes)
        #expect(try Data(contentsOf: corruptFile) == corrupt)
        #expect(defaults.string(forKey: "lastProfileID") == "custom")
        #expect(defaults.object(forKey: "legacyTemperatureRuleMigrationVersion") == nil)
        let second = LegacyConfigurationReader.read(homeDirectory: home, defaults: defaults)
        #expect(second.configuration == legacy.configuration)
    }

    @Test func ambiguousCalibrationNeverImported() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent("Library/Application Support/ThermalForge")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = Data("{\"machine\":\"Mac\",\"fans\":2,\"maxRPM\":6000,\"minRPM\":1000,\"calibratedAt\":\"2026-01-01\",\"measurements\":[]}".utf8)
        let path = directory.appendingPathComponent("calibration_lid_open.json")
        try legacy.write(to: path)
        #expect(LegacyConfigurationReader.read(homeDirectory: home).calibration.isEmpty)
        #expect(try Data(contentsOf: path) == legacy)
    }
}
