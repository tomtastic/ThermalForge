import Foundation
import Testing
@testable import ThermalForgeCore

private final class BackendJournal {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}
private final class BackendClock {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; time += interval }
}
private enum BackendTestError: Error { case failed }
private final class BackendSensors: SensorProvider {
    var temperatures: [String: Float] = ["TC0P": 60, "TG0P": 55, "TA0P": 25]
    var entered: DispatchSemaphore?
    var unblock: DispatchSemaphore?
    var fans: [ThermalStatus.FanStatus] = [.init(index: 0, actualRPM: 2000, targetRPM: 2000, minRPM: 2000, maxRPM: 6000, mode: "auto")]
    func status() throws -> ThermalStatus {
        entered?.signal()
        if let unblock { _ = unblock.wait(timeout: .now() + 5) }
        return ThermalStatus(fans: fans, temperatures: temperatures)
    }
}
private final class BackendActuator: BackendActuating {
    let journal: BackendJournal
    var failApply = false
    var restored = true
    init(_ journal: BackendJournal) { self.journal = journal }
    func apply(_ command: FanCommand, cancellation: CancellationToken) throws {
        journal.append("apply:\(command)")
        if failApply { throw BackendTestError.failed }
    }
    func restoreApple() -> RestorationResult {
        journal.append("restore")
        return RestorationResult(verified: restored, errors: restored ? [] : ["restore failed"])
    }
}
private final class BackendProtection: RecoveryProtecting {
    let journal: BackendJournal
    var denied = false
    var failProgress = false
    init(_ journal: BackendJournal) { self.journal = journal }
    func authorizeManual() throws { journal.append("authorize"); if denied { throw BackendTestError.failed } }
    func completedWork() throws { journal.append("progress"); if failProgress { throw BackendTestError.failed } }
    func restored() throws { journal.append("clear-marker") }
}
private final class BackendJob: BackendCalibrationRunning {
    let context: BackendCalibrationContext
    let journal: BackendJournal
    var terminationConfirmed: Bool
    let waitForCancellation: Bool
    let started: (() -> Void)?
    init(_ context: BackendCalibrationContext, journal: BackendJournal, terminationConfirmed: Bool = true, waitForCancellation: Bool = true, started: (() -> Void)? = nil) {
        self.context = context; self.journal = journal
        self.terminationConfirmed = terminationConfirmed; self.waitForCancellation = waitForCancellation; self.started = started
    }
    func run() throws -> CalibrationData {
        _ = try context.readStatus()
        try context.apply(.setMax)
        journal.append("workload-start")
        started?()
        if waitForCancellation {
            _ = context.cancellation.waitUntilCancelled(for: 5)
            throw CalibrationError.cancelled
        }
        return backendCalibration()
    }
    func stopWorkloads() -> Bool { journal.append("workload-stop"); return terminationConfirmed }
}
private func backendCalibration(mode: String = "standard", lidClosed: Bool = false, intensity: Float? = 0.05) -> CalibrationData {
    CalibrationData(machine: "TestMac", fans: 1, maxRPM: 6000, minRPM: 2000, calibratedAt: "2026-09-14", mode: mode,
        stressType: "cpu", workloadIntensity: intensity, ambientTemperature: 24, lidClosed: lidClosed,
        measurements: [.init(targetTemp: 60, holdingRPMPercent: 0.4), .init(targetTemp: 80, holdingRPMPercent: 0.8)])
}
private final class SavingCalibrationStore: BackendCalibrationStoring {
    let store: BackendCalibrationStore
    let beforeSave: () -> Void
    init(_ store: BackendCalibrationStore, beforeSave: @escaping () -> Void) { self.store = store; self.beforeSave = beforeSave }
    func load(lidClosed: Bool) throws -> CalibrationData? { try store.load(lidClosed: lidClosed) }
    func save(_ calibration: CalibrationData) throws { beforeSave(); try store.save(calibration) }
    func importLegacy(_ calibrations: [CalibrationData]) throws { try store.importLegacy(calibrations) }
    func reset() throws { try store.reset() }
}
private final class BackendHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let journal = BackendJournal()
    let sensors = BackendSensors()
    let clock = BackendClock()
    let actuator: BackendActuator
    let recovery: BackendProtection
    let configuration: BackendConfigurationStore
    let calibration: BackendCalibrationStore
    let backend: BackendCoordinator
    let gui = AuthenticatedPeer(uid: 501, pid: 101)
    let cli = AuthenticatedPeer(uid: 501, pid: 102)
    let observer = AuthenticatedPeer(uid: 501, pid: 103)
    init(beforeSave: (() -> Void)? = nil, factory: ((BackendCalibrationContext, BackendJournal) throws -> any BackendCalibrationRunning)? = nil) {
        actuator = BackendActuator(journal)
        recovery = BackendProtection(journal)
        configuration = BackendConfigurationStore(directory: directory.appendingPathComponent("users"))
        calibration = BackendCalibrationStore(directory: directory.appendingPathComponent("machine"), legacyRoot: nil)
        let clock = clock, journal = journal, calibration = calibration
        backend = BackendCoordinator(sensorProvider: sensors, actuator: actuator, recovery: recovery,
            configurationStore: configuration, calibrationStore: beforeSave.map { SavingCalibrationStore(calibration, beforeSave: $0) } ?? calibration as any BackendCalibrationStoring,
            lidStateProvider: FixedCalibrationLid(isLidClosed: false), generation: "generation", now: { clock.now },
            calibrationFactory: factory.map { factory in { try factory($0, journal) } },
            configurationUID: { $0.uid }, onFatalFailure: { _ in journal.append("fatal") })
        backend.start(interval: 3600)
        backend.drainWork()
    }
    func request(_ operation: BackendOperation, session: ControlSession? = nil, peer: AuthenticatedPeer? = nil,
                 kind: ControlClientKind? = nil, intent: ControlIntent? = nil, takeover: Bool = false,
                 parameters: CalibrationJobParameters? = nil) -> BackendResponse {
        backend.handle(BackendRequest(operation: operation, session: session, clientKind: kind,
            intent: intent, takeover: takeover, calibration: parameters), peer: peer ?? gui)
    }
    func acquire(kind: ControlClientKind = .gui, peer: AuthenticatedPeer? = nil, intent: ControlIntent = .maximum, takeover: Bool = false) -> BackendResponse {
        request(.acquire, session: .init(generation: "generation"), peer: peer, kind: kind, intent: intent, takeover: takeover)
    }
    var snapshot: BackendSnapshot { request(.status).snapshot! }
    func tick() { backend.requestTick(); backend.drainWork() }
    func close() { backend.shutdown(); backend.drainWork(); try? FileManager.default.removeItem(at: directory) }
}

@Suite("Central backend coordination")
struct BackendCoordinatorTests {
    @Test("Oversized session IDs cannot inflate durable ownership snapshots")
    func boundedSessionIdentity() {
        let h = BackendHarness(); defer { h.close() }
        let response = h.request(.acquire, session: .init(id: String(repeating: "x", count: 129), generation: "generation"), kind: .cli, intent: .maximum)
        #expect(response.error?.code == "invalidSession")
        #expect(h.snapshot.owner == nil)
    }
    @Test("A missing GPU reading cannot protect or run GPU calibration using CPU temperature")
    func missingCalibrationSensorFamily() throws {
        let h = BackendHarness(factory: { BackendJob($0, journal: $1, waitForCancellation: false) })
        defer { h.close() }
        h.sensors.temperatures = ["TC0P": 60]
        #expect(h.request(.startCalibration, session: .init(generation: "generation"), kind: .cli,
                          parameters: .init(stressType: "gpu")).ok)
        h.backend.drainWork()
        #expect(!h.journal.values.contains("workload-start"))
        #expect(!h.journal.values.contains("authorize"))
        #expect(try h.calibration.load(lidClosed: false) == nil)
        #expect(h.snapshot.restoration == .verified)
    }
    @Test("Missing idle sensors retain the error without repeatedly writing already-verified Apple modes")
    func idleSensorFailureAvoidsRepeatedWrites() {
        let h = BackendHarness(); defer { h.close() }
        h.sensors.temperatures = [:]
        let initial = h.journal.values.filter { $0 == "restore" }.count
        h.tick(); h.tick()
        #expect(h.journal.values.filter { $0 == "restore" }.count == initial)
        #expect(!h.snapshot.restorationErrors.isEmpty)
    }
    @Test("Steady manual control skips unchanged writes but repairs target drift")
    func steadyManualControl() {
        let h = BackendHarness(); defer { h.close() }
        #expect(h.acquire(intent: .rpm(3000)).ok)
        h.backend.drainWork()
        let initial = h.journal.values.filter { $0.hasPrefix("apply:") }.count
        h.sensors.fans = [.init(index: 0, actualRPM: 2500, targetRPM: 3000, minRPM: 2000, maxRPM: 6000, mode: "manual")]
        h.tick(); h.tick()
        #expect(h.journal.values.filter { $0.hasPrefix("apply:") }.count == initial)
        h.sensors.fans = [.init(index: 0, actualRPM: 2500, targetRPM: 2000, minRPM: 2000, maxRPM: 6000, mode: "manual")]
        h.tick()
        #expect(h.journal.values.filter { $0.hasPrefix("apply:") }.count == initial + 1)
    }

    @Test("Shared RPM is clamped to the intersection of every fan's limits")
    func unequalFanLimits() {
        let h = BackendHarness(); defer { h.close() }
        h.sensors.fans = [
            .init(index: 0, actualRPM: 2000, targetRPM: 2000, minRPM: 2000, maxRPM: 6000, mode: "auto"),
            .init(index: 1, actualRPM: 2500, targetRPM: 2500, minRPM: 2500, maxRPM: 5000, mode: "auto")]
        #expect(h.acquire(intent: .rpm(1000)).ok)
        h.backend.drainWork()
        #expect(h.snapshot.acknowledgedControl == .manualRPM(2500))
    }

    @Test("Saving has a defined cancellation cutoff and never publishes success before disk completion")
    func calibrationSaveBoundary() throws {
        let entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        let h = BackendHarness(beforeSave: { entered.signal(); _ = unblock.wait(timeout: .now() + 3) }, factory: {
            BackendJob($0, journal: $1, waitForCancellation: false)
        })
        defer { h.close() }
        let session = ControlSession(generation: "generation")
        #expect(h.request(.startCalibration, session: session, kind: .cli, parameters: .init()).ok)
        #expect(entered.wait(timeout: .now() + 2) == .success)
        #expect(h.snapshot.calibration?.phase == .saving)
        #expect(h.snapshot.acknowledgedControl == .apple)
        #expect(h.request(.cancelCalibration, session: session).error?.code == "alreadyFinishing")
        #expect(h.request(.release, session: session).ok)
        #expect(h.snapshot.calibration?.phase == .saving)
        unblock.signal(); h.backend.drainWork()
        #expect(h.snapshot.calibration?.phase == .completed)
        #expect(try h.calibration.load(lidClosed: false) != nil)
    }

    @Test("Replacing an active curve with hands-off restores its previous manual target")
    func policyReplacementRestoresOwnership() throws {
        let h = BackendHarness(); defer { h.close() }
        var config = try h.configuration.load(uid: h.gui.uid)
        config.profiles.append(FanProfile(id: "custom", name: "Custom", curve: .init(alwaysOn: true)))
        _ = try h.configuration.update(config, uid: h.gui.uid)
        #expect(h.acquire(intent: .profile("custom")).ok)
        h.backend.drainWork()
        #expect(h.snapshot.acknowledgedControl != .apple)
        config = try h.configuration.load(uid: h.gui.uid)
        config.profiles[config.profiles.firstIndex { $0.id == "custom" }!] = FanProfile(id: "custom", name: "Custom", curve: .init(handsOff: true))
        #expect(h.backend.handle(.init(operation: .updateConfiguration, configuration: config), peer: h.gui).ok)
        h.backend.drainWork()
        #expect(h.snapshot.acknowledgedControl == .apple)
        #expect(h.snapshot.owner != nil)
    }

    @Test("An Apple-control rule retains its latch through handback and metadata edits")
    func appleRuleKeepsLatch() throws {
        let h = BackendHarness(); defer { h.close() }
        var config = try h.configuration.load(uid: h.gui.uid)
        config.profiles.append(FanProfile(id: "custom", name: "Custom", curve: .init(alwaysOn: true)))
        config.rulesEnabled = true
        config.rules = [.init(name: "Apple until cool", condition: .init(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 70), action: .resetAuto, untilTempBelowC: 50)]
        _ = try h.configuration.update(config, uid: h.gui.uid)
        h.sensors.temperatures = ["TC0P": 75]
        #expect(h.acquire(intent: .profile("custom")).ok)
        h.backend.drainWork()
        #expect(h.snapshot.acknowledgedControl == .apple)
        h.sensors.temperatures = ["TC0P": 60]
        config = try h.configuration.load(uid: h.gui.uid)
        #expect(h.backend.handle(.init(operation: .updateConfiguration, configuration: config), peer: h.gui).ok)
        h.backend.drainWork()
        h.tick()
        #expect(h.snapshot.acknowledgedControl == .apple)
        #expect(!h.journal.values.contains("authorize"))
        h.sensors.temperatures = ["TC0P": 45]
        h.tick()
        #expect(h.snapshot.acknowledgedControl != .apple)
    }

    @Test("Delayed acquire cannot reuse a session ended by explicit Apple restoration")
    func delayedAcquisitionCannotReviveEndedSession() throws {
        let h = BackendHarness()
        defer { h.close() }
        let session = try #require(h.acquire().snapshot?.owner)
        h.backend.drainWork()
        #expect(h.request(.restoreApple).ok)
        h.backend.drainWork()
        let stale = h.request(.acquire, session: session, kind: .gui, intent: .maximum)
        #expect(stale.error?.code == "revokedSession")
        #expect(h.snapshot.owner == nil)
        #expect(h.acquire().ok)
    }
    @Test("Manual writes require durable authorization and acknowledged hardware success")
    func authorizationOrder() {
        let h = BackendHarness(); defer { h.close() }
        let result = h.acquire()
        #expect(result.accepted)
        h.backend.drainWork()
        let events = h.journal.values
        #expect(events.firstIndex(of: "authorize")! < events.firstIndex(of: "apply:setMax")!)
        #expect(events.firstIndex(of: "apply:setMax")! < events.firstIndex(of: "progress")!)
        #expect(h.snapshot.acknowledgedControl == .maximum)
    }
    @Test("Failed actuation restores Apple and revokes intent without publishing manual success")
    func failedActuation() {
        let h = BackendHarness(); defer { h.close() }
        h.actuator.failApply = true
        _ = h.acquire(); h.backend.drainWork()
        #expect(h.snapshot.owner == nil)
        #expect(h.snapshot.acknowledgedControl == .apple)
        #expect(h.snapshot.lastSessionEndReason == .backendFailure)
        #expect(!h.journal.values.contains("progress"))
    }
    @Test("Protection persistence failure prevents even the first manual write")
    func authorizationFailure() {
        let h = BackendHarness(); defer { h.close() }
        h.recovery.denied = true
        _ = h.acquire(); h.backend.drainWork()
        #expect(!h.journal.values.contains(where: { $0.hasPrefix("apply:") }))
        #expect(h.journal.values.contains("fatal"))
        #expect(h.snapshot.owner == nil)
    }
    @Test("Status and renewals remain responsive while sensing stalls and cannot advance protection")
    func stalledSensing() {
        let h = BackendHarness(); defer { h.close() }
        let entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        h.sensors.entered = entered; h.sensors.unblock = unblock
        let owner = h.acquire().snapshot!.owner!
        #expect(entered.wait(timeout: .now() + 2) == .success)
        let baseline = h.journal.values.filter { $0 == "progress" }.count
        let before = BackendTiming.monotonicNow
        #expect(h.request(.status).ok)
        #expect(h.request(.renew, session: owner).ok)
        #expect(BackendTiming.monotonicNow - before < 0.2)
        #expect(h.journal.values.filter { $0 == "progress" }.count == baseline)
        h.clock.advance(11)
        h.backend.expireClient()
        #expect(h.snapshot.owner == nil)
        unblock.signal(); h.backend.drainWork()
        h.sensors.entered = nil; h.sensors.unblock = nil
        #expect(!h.journal.values.contains(where: { $0.hasPrefix("apply:") }))
    }
    @Test("Observer release cannot affect the active owner")
    func observerCannotRelease() {
        let h = BackendHarness(); defer { h.close() }
        let owner = h.acquire().snapshot!.owner!
        h.backend.drainWork()
        #expect(!h.request(.release, session: owner, peer: h.observer).ok)
        #expect(h.snapshot.owner == owner)
    }
    @Test("CLI takeover revokes GUI, blocks another CLI, and ends with Apple control")
    func takeover() {
        let h = BackendHarness(); defer { h.close() }
        let gui = h.acquire().snapshot!.owner!; h.backend.drainWork()
        let response = h.acquire(kind: .cli, peer: h.cli, takeover: true)
        #expect(response.ok)
        let cli = response.snapshot!.owner!
        h.backend.drainWork()
        #expect(h.snapshot.lastSessionEndReason == .takeover)
        #expect(!h.request(.renew, session: gui).ok)
        #expect(!h.acquire(kind: .cli, peer: h.observer, takeover: true).ok)
        #expect(!h.request(.release, session: gui).ok)
        #expect(h.request(.release, session: cli, peer: h.cli).ok)
        h.backend.drainWork()
        #expect(h.snapshot.acknowledgedControl == .apple)
        #expect(h.snapshot.owner == nil)
    }
    @Test("Explicit Apple restoration revokes the owner and records an intentional end")
    func explicitAuto() {
        let h = BackendHarness(); defer { h.close() }
        _ = h.acquire(); h.backend.drainWork()
        #expect(h.request(.restoreApple, peer: h.observer).accepted)
        h.backend.drainWork()
        #expect(h.snapshot.lastSessionEndReason == .explicitAuto)
        #expect(h.snapshot.owner == nil)
        #expect(h.snapshot.restoration == .verified)
    }
    @Test("Stale generations and delayed renewals cannot acquire or revive sessions")
    func staleAndExpired() {
        let h = BackendHarness(); defer { h.close() }
        let old = h.request(.acquire, session: .init(generation: "old"), kind: .cli, intent: .maximum)
        #expect(old.error?.code == "staleGeneration")
        let session = h.acquire().snapshot!.owner!; h.backend.drainWork()
        h.clock.advance(11)
        #expect(!h.request(.renew, session: session).ok)
        h.backend.expireClient(); h.backend.drainWork()
        #expect(h.snapshot.lastSessionEndReason == .clientExpired)
    }
    @Test("Missing sensors are unknown and cannot keep manual control alive")
    func missingSensors() {
        let h = BackendHarness(); defer { h.close() }
        h.sensors.temperatures = [:]
        _ = h.acquire(intent: .profile("silent")); h.backend.drainWork()
        #expect(h.snapshot.sensors == nil)
        #expect(h.snapshot.owner == nil)
        #expect(!h.journal.values.contains("authorize"))
        #expect(!h.journal.values.contains("progress"))
    }
    @Test("No live client means even the temperature override cannot write")
    func observingSafety() {
        let h = BackendHarness(); defer { h.close() }
        h.sensors.temperatures = ["TC0P": 100]
        h.tick()
        #expect(!h.journal.values.contains("authorize"))
        #expect(h.snapshot.owner == nil)
    }
    @Test("Sleep invalidates ownership and wake requires a new session")
    func sleepWake() {
        let h = BackendHarness(); defer { h.close() }
        let owner = h.acquire().snapshot!.owner!; h.backend.drainWork()
        h.backend.prepareForSleep(); h.backend.drainWork()
        h.backend.resumeAfterWake(); h.backend.drainWork()
        #expect(!h.request(.renew, session: owner).ok)
        #expect(h.snapshot.lastSessionEndReason == .sleep)
        #expect(h.snapshot.acknowledgedControl == .apple)
    }
    @Test("Failed restoration blocks new control and retries before another manual write")
    func restorationFailure() {
        let h = BackendHarness(); defer { h.close() }
        _ = h.acquire(); h.backend.drainWork()
        h.actuator.restored = false
        _ = h.request(.restoreApple); h.backend.drainWork()
        #expect(h.snapshot.restoration == .failed)
        #expect(h.acquire().error?.code == "restorationRequired")
        h.actuator.restored = true; h.tick()
        #expect(h.snapshot.restoration == .verified)
        #expect(h.acquire().ok); h.backend.drainWork()
    }
    @Test("Calibration is exclusive and cancellation confirms workload stop before handback")
    func calibrationCancellation() {
        let started = DispatchSemaphore(value: 0)
        let h = BackendHarness(factory: { BackendJob($0, journal: $1, started: { started.signal() }) }); defer { h.close() }
        let response = h.request(.startCalibration, session: .init(generation: "generation"), peer: h.cli, kind: .cli, parameters: .init())
        let owner = response.snapshot!.owner!
        #expect(response.accepted)
        #expect(started.wait(timeout: .now() + 2) == .success)
        #expect(!h.acquire().ok)
        #expect(h.request(.status, peer: h.observer).ok)
        #expect(h.request(.cancelCalibration, session: owner, peer: h.cli).accepted)
        h.backend.drainWork()
        #expect(h.snapshot.calibration?.phase == .cancelled)
        #expect((try? h.calibration.load(lidClosed: false)) == nil)
        let events = h.journal.values
        #expect(events.lastIndex(of: "workload-stop")! < events.lastIndex(of: "restore")!)
    }
    @Test("Unterminated calibration workload triggers exit without backend restoration")
    func calibrationWorkloadFailure() {
        let started = DispatchSemaphore(value: 0)
        let h = BackendHarness(factory: { context, journal in
            started.signal()
            return BackendJob(context, journal: journal, terminationConfirmed: false, waitForCancellation: false)
        })
        _ = h.request(.startCalibration, session: .init(generation: "generation"), peer: h.cli, kind: .cli, parameters: .init())
        #expect(started.wait(timeout: .now() + 2) == .success)
        h.backend.drainWork()
        let events = h.journal.values
        #expect(events.contains("fatal"))
        let stop = events.lastIndex(of: "workload-stop")!
        #expect(!events.suffix(from: stop).contains("restore"))
        #expect((try? h.calibration.load(lidClosed: false)) == nil)
        // A failed process is exited by its host; shutdown must not be invoked
        // by this test as that is a different lifecycle operation.
        try? FileManager.default.removeItem(at: h.directory)
    }
    @Test("Calibration downgrade and intensity validation live in the backend")
    func calibrationValidation() throws {
        let h = BackendHarness(); defer { h.close() }
        try h.calibration.save(backendCalibration(mode: "optimized"))
        let session = ControlSession(generation: "generation")
        #expect(!h.request(.startCalibration, session: session, peer: h.cli, kind: .cli, parameters: .init(mode: "quick")).ok)
        #expect(!h.request(.startCalibration, session: session, peer: h.cli, kind: .cli, parameters: .init(mode: "bad")).ok)
        #expect(!h.request(.startCalibration, session: session, peer: h.cli, kind: .cli, parameters: .init(workloadIntensity: 2)).ok)
    }
    @Test("Client loss cancels calibration and cannot save partial data")
    func calibrationClientLoss() {
        let started = DispatchSemaphore(value: 0)
        let h = BackendHarness(factory: { BackendJob($0, journal: $1, started: { started.signal() }) }); defer { h.close() }
        _ = h.request(.startCalibration, session: .init(generation: "generation"), peer: h.cli, kind: .cli, parameters: .init())
        #expect(started.wait(timeout: .now() + 2) == .success)
        h.clock.advance(11); h.backend.expireClient(); h.backend.drainWork()
        #expect(h.snapshot.calibration?.phase == .cancelled)
        #expect(h.snapshot.lastSessionEndReason == .clientExpired)
        #expect((try? h.calibration.load(lidClosed: false)) == nil)
        let events = h.journal.values
        #expect(events.lastIndex(of: "workload-stop")! < events.lastIndex(of: "restore")!)
    }
    @Test("Completed calibration reuses workload intensity and saves only after handback")
    func calibrationSuccess() throws {
        let h = BackendHarness(factory: { context, journal in
            journal.append("intensity:\(context.workloadIntensity ?? -1)")
            return BackendJob(context, journal: journal, waitForCancellation: false)
        }); defer { h.close() }
        try h.calibration.save(backendCalibration(intensity: 0.02))
        #expect(h.request(.startCalibration, session: .init(generation: "generation"), peer: h.cli, kind: .cli, parameters: .init()).accepted)
        h.backend.drainWork()
        #expect(h.snapshot.calibration?.phase == .completed)
        #expect(h.journal.values.contains("intensity:0.02"))
        #expect(try h.calibration.load(lidClosed: false)?.workloadIntensity == 0.05)
        #expect(h.snapshot.owner == nil)
        #expect(h.snapshot.restoration == .verified)
    }
    @Test("Profile selections persist in authoritative per-user configuration")
    func selectedProfilePersistence() throws {
        let h = BackendHarness(); defer { h.close() }
        #expect(h.acquire(intent: .profile("smart")).ok)
        h.backend.drainWork()
        #expect(try h.configuration.load(uid: 501).selectedProfileID == "smart")
    }
    @Test("Requested RPM and acknowledged clamped RPM remain distinct")
    func clampedAcknowledgement() {
        let h = BackendHarness(); defer { h.close() }
        #expect(h.acquire(intent: .rpm(1)).ok); h.backend.drainWork()
        #expect(h.snapshot.requestedIntent == .rpm(1))
        #expect(h.snapshot.acknowledgedControl == .manualRPM(2000))
    }

    @Test("Manual RPM respects the thermal override and its hysteresis")
    func manualThermalOverride() {
        let h = BackendHarness(); defer { h.close() }
        h.sensors.temperatures = ["TC0P": 96]
        _ = h.acquire(intent: .rpm(3000)); h.backend.drainWork()
        #expect(h.snapshot.requestedIntent == .rpm(3000))
        #expect(h.snapshot.acknowledgedControl == .maximum)
        h.sensors.temperatures = ["TC0P": 92]; h.tick()
        #expect(h.snapshot.acknowledgedControl == .maximum)
        h.sensors.temperatures = ["TC0P": 89]; h.tick()
        #expect(h.snapshot.acknowledgedControl == .manualRPM(3000))
    }
    @Test("A fresh hands-off profile cannot inherit prior manual fan ownership")
    func profileSelectionRestoresPreviousManualControl() {
        let h = BackendHarness(); defer { h.close() }
        let owner = h.acquire().snapshot!.owner!; h.backend.drainWork()
        #expect(h.snapshot.acknowledgedControl == .maximum)
        #expect(h.request(.acquire, session: owner, kind: .gui, intent: .profile("silent")).accepted)
        h.backend.drainWork()
        #expect(h.snapshot.acknowledgedControl == .apple)
        #expect(h.snapshot.activeProfileID == "silent")
    }
    @Test("Per-session takeover tombstones survive the CLI release")
    func persistentTakeoverReason() {
        let h = BackendHarness(); defer { h.close() }
        let gui = h.acquire().snapshot!.owner!; h.backend.drainWork()
        let cli = h.acquire(kind: .cli, peer: h.cli, takeover: true).snapshot!.owner!; h.backend.drainWork()
        _ = h.request(.release, session: cli, peer: h.cli); h.backend.drainWork()
        #expect(h.snapshot.lastSessionEndReason == .released)
        #expect(h.snapshot.endedSessions[gui.id] == .takeover)
        #expect(h.snapshot.endedSessions[cli.id] == .released)
    }
    @Test("Explicit auto durably revokes automatic recovery while explicit selection remains available")
    func explicitAutoRevokesRecoveryEpoch() throws {
        let h = BackendHarness(); defer { h.close() }
        let previousEpoch = try h.configuration.load(uid: 501).recoveryEpoch
        _ = h.acquire(); h.backend.drainWork()
        _ = h.request(.restoreApple)
        let request = BackendRequest(operation: .acquire, session: .init(generation: "generation"),
            clientKind: .gui, intent: .profile("smart"), automaticRecovery: true, recoveryEpoch: previousEpoch)
        #expect(h.backend.handle(request, peer: h.gui).error?.code == "recoveryRevoked")
        h.backend.drainWork()
        #expect(h.backend.handle(request, peer: h.gui).error?.code == "recoveryRevoked")
        let reopened = BackendConfigurationStore(directory: h.directory.appendingPathComponent("users"))
        #expect(try reopened.load(uid: 501).recoveryEpoch != previousEpoch)
        #expect(h.acquire(intent: .profile("smart")).accepted); h.backend.drainWork()
    }

}
