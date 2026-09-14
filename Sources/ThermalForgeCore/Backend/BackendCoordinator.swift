import Foundation

/// A short state lock serves clients independently of the serialized hardware
/// queue. Neither status requests nor client renewals can advance recovery.
public final class BackendCoordinator: BackendRequestHandling {
    private struct Owner {
        let session: ControlSession
        let peer: AuthenticatedPeer
        let kind: ControlClientKind
        let uid: UInt32
        let cancellation: CancellationToken
        var expiry: TimeInterval
        var intent: ControlIntent?
        var configuration: BackendConfiguration
    }
    private enum Failure: LocalizedError {
        case rejected(String), protection(String)
        var errorDescription: String? {
            switch self { case .rejected(let message), .protection(let message): return message }
        }
    }
    private let sensorProvider: SensorProvider
    private let actuator: BackendActuating
    private let recovery: RecoveryProtecting
    private let configurationStore: BackendConfigurationStoring
    private let calibrationStore: BackendCalibrationStoring
    private let lidStateProvider: any LidStateProvider
    private let now: () -> TimeInterval
    private let configurationUID: (AuthenticatedPeer) -> UInt32
    private let calibrationFactory: BackendCalibrationFactory
    private let onFatalFailure: (String) -> Void
    private let lock = NSLock()
    private let work = DispatchQueue(label: "com.thermalforge.backend.work", qos: .userInitiated)
    private let scheduling = DispatchQueue(label: "com.thermalforge.backend.leases", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var leaseTimer: DispatchSourceTimer?
    private var snapshot: BackendSnapshot
    private var owner: Owner?
    private var endedSessionOrder: [String] = []
    private var pendingEpochUIDs: Set<UInt32> = []
    private var knownEpochs: [UInt32: String] = [:]
    private var epochTasks: Set<UInt32> = []
    private var working = false
    private var stopped = true
    private var sleeping = false
    private var fatal = false
    private var protectionFailure: String?
    private var unsafeWorkloads = false
    private var needsRestoration = true
    private var calibrationActive = false
    // Accessed exclusively by work.
    private var engine: RuntimeControlDecisionEngine?
    private var engineSession: String?
    private var engineRevision: Int?
    private var engineIntent: ControlIntent?
    private var manualSafetyOverride = false
    private var tickInterval: Float = 1

    public init(sensorProvider: SensorProvider, actuator: BackendActuating,
                recovery: RecoveryProtecting,
                configurationStore: BackendConfigurationStoring = BackendConfigurationStore(),
                calibrationStore: BackendCalibrationStoring = BackendCalibrationStore(),
                lidStateProvider: any LidStateProvider = MacLidStateProvider(),
                generation: String = UUID().uuidString,
                now: @escaping () -> TimeInterval = { BackendTiming.monotonicNow },
                calibrationFactory: BackendCalibrationFactory? = nil,
                configurationUID: ((AuthenticatedPeer) -> UInt32)? = nil,
                onFatalFailure: @escaping (String) -> Void = { _ in }) {
        self.sensorProvider = sensorProvider
        self.actuator = actuator
        self.recovery = recovery
        self.configurationStore = configurationStore
        self.calibrationStore = calibrationStore
        self.lidStateProvider = lidStateProvider
        self.now = now
        self.configurationUID = configurationUID ?? { peer in
            peer.uid == 0 ? (UserHomeDirectoryResolver.activeConsoleUser()?.uid ?? peer.uid) : peer.uid
        }
        self.onFatalFailure = onFatalFailure
        snapshot = BackendSnapshot(generation: generation)
        self.calibrationFactory = calibrationFactory ?? { context in
            guard let mode = CalibrationMode(rawValue: context.parameters.mode),
                  let stress = CalibrationStressType(rawValue: context.parameters.stressType) else {
                throw Failure.rejected("Invalid calibration parameters")
            }
            let runner = CalibrationRunner(readStatus: context.readStatus, applyCommand: context.apply,
                mode: mode, stressType: stress, workloadIntensity: context.workloadIntensity,
                cancellationToken: context.cancellation,
                lidStateProvider: FixedCalibrationLid(isLidClosed: context.lidClosed),
                logDirectory: URL(fileURLWithPath: "/Library/Application Support/ThermalForge/calibration-logs", isDirectory: true))
            runner.onProgress = context.progress
            return runner
        }
    }

    private func state<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }

    public func start(interval: TimeInterval = 1) {
        state {
            guard stopped, !fatal else { return }
            stopped = false
            tickInterval = Float(max(interval, 0.05))
            snapshot.restoration = .pending
            work.async { [weak self] in _ = self?.restoreOnWorkQueue() }
            let timer = DispatchSource.makeTimerSource(queue: scheduling)
            timer.schedule(deadline: .now() + max(interval, 0.05), repeating: max(interval, 0.05))
            timer.setEventHandler { [weak self] in self?.requestTick() }
            self.timer = timer
            timer.resume()
            let leaseTimer = DispatchSource.makeTimerSource(queue: scheduling)
            leaseTimer.schedule(deadline: .now() + BackendTiming.expiryInterval, repeating: BackendTiming.expiryInterval)
            leaseTimer.setEventHandler { [weak self] in self?.expireClient() }
            self.leaseTimer = leaseTimer
            leaseTimer.resume()
        }
    }

    public func stop() { shutdown() }
    public func shutdown(completion: (() -> Void)? = nil) {
        state {
            stopped = true
            timer?.cancel(); timer = nil
            leaseTimer?.cancel(); leaseTimer = nil
            endSession(.released)
        }
        work.async { [weak self] in
            _ = self?.restoreOnWorkQueue()
            completion?()
        }
    }
    public func prepareForSleep() {
        state { sleeping = true; endSession(.sleep) }
        work.async { [weak self] in _ = self?.restoreOnWorkQueue() }
    }
    public func resumeAfterWake() {
        state { sleeping = false; needsRestoration = true; snapshot.restoration = .pending }
        work.async { [weak self] in _ = self?.restoreOnWorkQueue() }
    }

    public func handle(_ request: BackendRequest, peer: AuthenticatedPeer) -> BackendResponse {
        guard request.version == 2 else { return error(request, "unsupportedVersion", "Protocol version 2 is required") }
        if request.operation == .status {
            return state { BackendResponse(requestID: request.requestID, snapshot: snapshot) }
        }
        if let session = request.session, session.generation != state({ snapshot.generation }) {
            return error(request, "staleGeneration", "The session belongs to another backend generation")
        }
        do {
            let uid = configurationUID(peer)
            switch request.operation {
            case .configuration:
                let config = try configurationStore.load(uid: uid)
                state { if owner == nil || owner?.uid == uid { snapshot.recoveryEpoch = config.recoveryEpoch } }
                return BackendResponse(requestID: request.requestID, snapshot: state { snapshot }, configuration: config)
            case .updateConfiguration, .importLegacy:
                if state({ calibrationActive }) { return error(request, "busy", "Calibration is exclusive") }
                let config: BackendConfiguration
                if request.operation == .updateConfiguration {
                    guard let supplied = request.configuration else { return error(request, "invalidRequest", "Missing configuration") }
                    config = try configurationStore.update(supplied, uid: uid)
                } else {
                    guard let supplied = request.legacyImport else { return error(request, "invalidRequest", "Missing legacy import") }
                    try BackendConfigurationStore.validate(supplied.configuration)
                    // Import calibration first; both operations are idempotent. The
                    // configuration envelope is the atomic completion marker.
                    if !(try configurationStore.load(uid: uid)).importedLegacy {
                        try calibrationStore.importLegacy(supplied.calibration)
                    }
                    config = try configurationStore.importLegacy(supplied.configuration, uid: uid)
                }
                state {
                    if owner?.uid == uid { owner?.configuration = config; snapshot.configurationRevision = config.revision }
                }
                requestTick()
                return BackendResponse(requestID: request.requestID, snapshot: state { snapshot }, configuration: config)
            case .resetCalibration:
                if state({ calibrationActive }) { return error(request, "busy", "Cancel calibration before resetting stored data") }
                try calibrationStore.reset()
                state { snapshot.calibrationLidClosed = nil }
                return state { BackendResponse(requestID: request.requestID, snapshot: snapshot) }
            case .renew:
                return state {
                    guard owns(request.session, peer: peer), let current = owner, current.expiry > now(), !current.cancellation.isCancelled else {
                        return errorLocked(request, "notOwner", "The controlling session has expired or was revoked")
                    }
                    owner?.expiry = now() + BackendTiming.clientLease
                    return BackendResponse(requestID: request.requestID, snapshot: snapshot)
                }
            case .release:
                return state {
                    guard owns(request.session, peer: peer) else { return errorLocked(request, "notOwner", "Only the owning client may release this session") }
                    endSession(.released)
                    work.async { [weak self] in _ = self?.restoreOnWorkQueue() }
                    return BackendResponse(requestID: request.requestID, accepted: true, snapshot: snapshot)
                }
            case .restoreApple:
                return state {
                    let affectedUID = owner?.uid ?? uid
                    queueEpochInvalidation(uid: affectedUID)
                    endSession(.explicitAuto)
                    work.async { [weak self] in _ = self?.restoreOnWorkQueue() }
                    return BackendResponse(requestID: request.requestID, accepted: true, snapshot: snapshot)
                }
            case .cancelCalibration:
                return state {
                    guard calibrationActive, owns(request.session, peer: peer) else {
                        return errorLocked(request, "notOwner", "Only the calibration owner may cancel it; Apple restoration is available to all clients")
                    }
                    endSession(.released)
                    return BackendResponse(requestID: request.requestID, accepted: true, snapshot: snapshot)
                }
            case .acquire, .startCalibration:
                let config = try configurationStore.load(uid: uid)
                if request.operation == .acquire {
                    guard let intent = request.intent else { return error(request, "invalidRequest", "Missing control intent") }
                    try validate(intent, configuration: config)
                } else {
                    try validateCalibration(request.calibration)
                }
                let response = state { () -> BackendResponse in
                    guard !stopped, !sleeping, !fatal else { return errorLocked(request, "unavailable", "Backend control is unavailable") }
                    if request.automaticRecovery, pendingEpochUIDs.contains(uid) || request.recoveryEpoch != (knownEpochs[uid] ?? config.recoveryEpoch) {
                        return errorLocked(request, "recoveryRevoked", "Automatic profile recovery was revoked by an explicit control action")
                    }
                    guard !calibrationActive else { return errorLocked(request, "busy", "Calibration is exclusive") }
                    guard snapshot.restoration != .failed else { return errorLocked(request, "restorationRequired", "Apple restoration is unverified") }
                    guard let session = request.session, session.generation == snapshot.generation, !session.id.isEmpty,
                          let kind = request.clientKind else { return errorLocked(request, "staleGeneration", "A session for this backend generation is required") }
                    guard snapshot.endedSessions[session.id] == nil else {
                        return errorLocked(request, "revokedSession", "An ended session cannot acquire control again; create a new session")
                    }
                    if let current = owner, !owns(session, peer: peer) {
                        guard request.takeover, kind == .cli, current.kind == .gui else { return errorLocked(request, "busy", "Another client owns control") }
                        let affectedUID = current.uid
                        queueEpochInvalidation(uid: affectedUID)
                        endSession(.takeover)
                    }
                    if let current = owner, owns(session, peer: peer) {
                        current.cancellation.cancel()
                    }
                    let newOwner = Owner(session: session, peer: peer, kind: kind, uid: uid,
                        cancellation: CancellationToken(), expiry: now() + BackendTiming.clientLease,
                        intent: request.intent, configuration: config)
                    if kind == .cli, owner == nil, !pendingEpochUIDs.contains(uid) {
                        queueEpochInvalidation(uid: uid)
                    }
                    if kind == .cli {
                        for (id, previous) in snapshot.endedSessions where previous == .backendFailure || previous == .clientExpired {
                            snapshot.endedSessions[id] = .takeover
                        }
                    }
                    owner = newOwner
                    snapshot.owner = session
                    snapshot.ownerKind = kind
                    snapshot.requestedIntent = request.intent
                    snapshot.configurationRevision = config.revision
                    snapshot.recoveryEpoch = knownEpochs[uid] ?? config.recoveryEpoch
                    snapshot.activeProfileID = nil
                    if case .profile = request.intent, request.operation == .acquire {
                        // A fresh policy engine starts with Apple ownership;
                        // it must not inherit a previous manual RPM assumption.
                        needsRestoration = true
                        snapshot.restoration = .pending
                        work.async { [weak self] in self?.persistSelection(owner: newOwner) }
                    }
                    if request.operation == .startCalibration {
                        calibrationActive = true
                        let jobID = UUID().uuidString
                        snapshot.calibration = CalibrationJobSnapshot(id: jobID, phase: .pending)
                        work.async { [weak self] in self?.runCalibration(owner: newOwner, parameters: request.calibration!, jobID: jobID) }
                    }
                    return BackendResponse(requestID: request.requestID, accepted: true, snapshot: snapshot)
                }
                if response.ok { requestTick() }
                return response
            case .status: fatalError("Status is handled before mutation dispatch")
            }
        } catch BackendStorageError.conflict {
            return error(request, "conflict", "Configuration changed; reload it before editing")
        } catch {
            return self.error(request, "invalidRequest", error.localizedDescription)
        }
    }

    private func owns(_ session: ControlSession?, peer: AuthenticatedPeer) -> Bool {
        guard let owner, let session else { return false }
        return owner.session == session && owner.peer == peer
    }
    private func error(_ request: BackendRequest, _ code: String, _ message: String) -> BackendResponse {
        state { errorLocked(request, code, message) }
    }
    private func errorLocked(_ request: BackendRequest, _ code: String, _ message: String) -> BackendResponse {
        BackendResponse(requestID: request.requestID, ok: false, snapshot: snapshot,
            error: DaemonErrorPayload(code: code, message: message))
    }
    private func validate(_ intent: ControlIntent, configuration: BackendConfiguration) throws {
        switch intent {
        case .profile(let id):
            guard configuration.profiles.contains(where: { $0.id == id }) else { throw Failure.rejected("Unknown profile") }
        case .rpm(let rpm):
            guard (1...30000).contains(rpm) else { throw Failure.rejected("RPM must be between 1 and 30000") }
        case .maximum: break
        }
    }
    private func validateCalibration(_ parameters: CalibrationJobParameters?) throws {
        guard let parameters, let mode = CalibrationMode(rawValue: parameters.mode),
              CalibrationStressType(rawValue: parameters.stressType) != nil else { throw Failure.rejected("Invalid calibration mode or stress type") }
        if let intensity = parameters.workloadIntensity, !intensity.isFinite || intensity < 0.001 || intensity > 0.5 {
            throw Failure.rejected("Workload intensity must be between 0.001 and 0.5")
        }
        if parameters.workloadIntensity != nil, parameters.rediscoverIntensity {
            throw Failure.rejected("Explicit workload intensity cannot be combined with rediscovery")
        }
        let existing = try calibrationStore.load(lidClosed: lidStateProvider.isLidClosed)
        if let existing, mode.rank < existing.modeRank, !parameters.force { throw Failure.rejected("Calibration would downgrade existing data; force is required") }
    }

    /// Caller holds state lock. Cancellation is visible immediately to the
    /// hardware queue, even when that queue is inside unlock or a calibration.
    private func endSession(_ reason: SessionEndReason) {
        if let session = owner?.session {
            if snapshot.endedSessions[session.id] == nil { endedSessionOrder.append(session.id) }
            snapshot.endedSessions[session.id] = reason
            while endedSessionOrder.count > 256 {
                snapshot.endedSessions.removeValue(forKey: endedSessionOrder.removeFirst())
            }
        }
        if reason == .explicitAuto {
            // A deliberate global handback also overrides earlier recoverable
            // outages whose clients have not reconnected yet.
            for (id, previous) in snapshot.endedSessions where previous == .backendFailure || previous == .clientExpired {
                snapshot.endedSessions[id] = .explicitAuto
            }
        }
        owner?.cancellation.cancel()
        owner = nil
        snapshot.owner = nil
        snapshot.ownerKind = nil
        snapshot.requestedIntent = nil
        snapshot.activeProfileID = nil
        snapshot.lastSessionEndReason = reason
        snapshot.restoration = .pending
        needsRestoration = true
        if calibrationActive { snapshot.calibration?.phase = .cancelling }
    }

    func expireClient() {
        state {
            guard let owner, owner.expiry <= now() else { return }
            endSession(.clientExpired)
            work.async { [weak self] in _ = self?.restoreOnWorkQueue() }
        }
    }
    func requestTick() {
        state {
            guard !stopped, !sleeping, !fatal, !working, !calibrationActive else { return }
            working = true
            work.async { [weak self] in
                guard let self else { return }
                self.controlCycle()
                self.state { self.working = false }
            }
        }
    }
    /// Test seam: drains actual implementation work; production never waits on SMC from request handling.
    func drainWork() { work.sync {} }

    private func validOwner(_ expected: Owner) throws {
        try state {
            guard !fatal, !stopped, !sleeping, let owner,
                  owner.cancellation === expected.cancellation, owner.expiry > now(),
                  !expected.cancellation.isCancelled else { throw CalibrationError.cancelled }
        }
    }
    private func sample(owner expected: Owner? = nil) throws -> ThermalStatus {
        if let expected { try validOwner(expected) }
        let result = try sensorProvider.status()
        guard let peak = TemperatureSummary(result.temperatures).controlPeak, peak.isFinite, peak > 0,
              !result.fans.isEmpty, result.fans.allSatisfy({ $0.maxRPM > 0 && $0.minRPM >= 0 && $0.minRPM <= $0.maxRPM }) else {
            throw Failure.rejected("Fresh control sensors and readable fan limits are required")
        }
        if let expected { try validOwner(expected) }
        state { snapshot.sensors = result; snapshot.sampledAt = now() }
        return result
    }
    private func protect(_ operation: () throws -> Void) throws {
        do { try operation() } catch {
            state {
                protectionFailure = error.localizedDescription
                owner?.cancellation.cancel()
            }
            throw Failure.protection(error.localizedDescription)
        }
    }
    private func apply(_ command: FanCommand, owner expected: Owner) throws {
        try validOwner(expected)
        if command == .resetAuto {
            guard restoreOnWorkQueue() else { throw Failure.rejected("Apple restoration failed") }
            return
        }
        guard !state({ needsRestoration || pendingEpochUIDs.contains(expected.uid) }) else {
            throw Failure.rejected("Recovery and durable control revocation must complete before manual control")
        }
        try protect { try recovery.authorizeManual() }
        try validOwner(expected)
        let appliedCommand: FanCommand
        if case .setRPM(let rpm) = command, let fan = state({ snapshot.sensors?.fans.first }) {
            appliedCommand = .setRPM(min(max(rpm, Float(fan.minRPM)), Float(fan.maxRPM)))
        } else { appliedCommand = command }
        try actuator.apply(appliedCommand, cancellation: expected.cancellation)
        try validOwner(expected)
        state {
            snapshot.restoration = .unknown
            snapshot.restorationErrors = []
            switch appliedCommand {
            case .setMax: snapshot.acknowledgedControl = .maximum
            case .setRPM(let rpm): snapshot.acknowledgedControl = .manualRPM(Int(rpm))
            case .resetAuto: break
            }
        }
    }
    // Called with the state lock; duplicate pending explicit handbacks share
    // one durable invalidation, so no gap can admit a stale automatic request.
    private func queueEpochInvalidation(uid: UInt32) {
        pendingEpochUIDs.insert(uid)
        guard epochTasks.insert(uid).inserted else { return }
        work.async { [weak self] in self?.persistRecoveryEpoch(uid: uid) }
    }

    private func persistRecoveryEpoch(uid: UInt32) {
        do {
            let configuration = try configurationStore.invalidateAutomaticRecovery(uid: uid)
            state {
                pendingEpochUIDs.remove(uid)
                epochTasks.remove(uid)
                if let epoch = configuration.recoveryEpoch { knownEpochs[uid] = epoch }
                if owner == nil || owner?.uid == uid {
                    snapshot.recoveryEpoch = configuration.recoveryEpoch
                    snapshot.configurationRevision = configuration.revision
                }
                if owner?.uid == uid { owner?.configuration = configuration }
            }
        } catch {
            // Keep automatic recovery blocked until durable invalidation succeeds.
            state {
                epochTasks.remove(uid)
                snapshot.restorationErrors.append("Could not persist control revocation: \(error.localizedDescription)")
            }
        }
    }

    private func persistSelection(owner expected: Owner) {
        guard case .profile(let id) = expected.intent else { return }
        do {
            try validOwner(expected)
            var configuration = try configurationStore.load(uid: expected.uid)
            if configuration.selectedProfileID != id {
                configuration.selectedProfileID = id
                do { configuration = try configurationStore.update(configuration, uid: expected.uid) }
                catch BackendStorageError.conflict {
                    configuration = try configurationStore.load(uid: expected.uid)
                    configuration.selectedProfileID = id
                    configuration = try configurationStore.update(configuration, uid: expected.uid)
                }
            }
            state {
                if owner?.cancellation === expected.cancellation {
                    owner?.configuration = configuration
                    snapshot.configurationRevision = configuration.revision
                }
            }
        } catch { failControl(error, expected: expected) }
    }

    private func controlCycle() {
        let expected = state { owner }
        do {
            if state({ needsRestoration }), !restoreOnWorkQueue() { return }
            let status = try sample(owner: expected)
            if let expected, let intent = expected.intent {
                let command: FanCommand?
                switch intent {
                case .rpm(let rpm):
                    let peak = TemperatureSummary(status.temperatures).controlPeak!
                    if peak >= FanProfile.safetyTempThreshold { manualSafetyOverride = true }
                    else if peak < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees { manualSafetyOverride = false }
                    command = manualSafetyOverride ? .setMax : .setRPM(Float(rpm))
                case .maximum: command = .setMax
                case .profile(let profileID):
                    let config = expected.configuration
                    if engineSession != expected.session.id || engineRevision != config.revision || engineIntent != intent {
                        let profile = config.profiles.first { $0.id == profileID } ?? .silent
                        let service = ControlService()
                        service.replaceRules(config.rules, enabled: config.rulesEnabled)
                        engine = RuntimeControlDecisionEngine(profile: profile, controlService: service, profiles: config.profiles)
                        engineSession = expected.session.id
                        engineRevision = config.revision
                        engineIntent = intent
                    }
                    let lidClosed = lidStateProvider.isLidClosed
                    let calibration = try calibrationStore.load(lidClosed: lidClosed)
                    let fan = status.fans[0]
                    let output = engine!.evaluate(RuntimeControlInput(status: status,
                        maxTemp: TemperatureSummary(status.temperatures).controlPeak!,
                        fanLimits: RuntimeFanLimits(minRPM: Float(fan.minRPM), maxRPM: Float(fan.maxRPM)),
                        now: now(), tickInterval: tickInterval, recordTemperatureRate: true, calibration: calibration))
                    command = output.command
                    state { snapshot.activeProfileID = engine?.activeProfile.id; snapshot.calibrationLidClosed = calibration?.lidClosed }
                }
                if let command { try apply(command, owner: expected) }
                try validOwner(expected)
            }
            try protect { try recovery.completedWork() }
        } catch {
            failControl(error, expected: expected)
        }
    }

    @discardableResult
    private func restoreOnWorkQueue() -> Bool {
        // Calibration owns this queue until its runner confirms workload exit.
        guard !state({ unsafeWorkloads }) else { return false }
        engine = nil; engineSession = nil; engineRevision = nil; engineIntent = nil; manualSafetyOverride = false
        let result = actuator.restoreApple()
        state {
            snapshot.restoration = result.verified ? (pendingEpochUIDs.isEmpty ? .verified : .pending) : .failed
            if result.verified, !pendingEpochUIDs.isEmpty {
                snapshot.restorationErrors = result.errors + ["Durable control revocation is pending"]
            } else { snapshot.restorationErrors = result.errors }
            snapshot.acknowledgedControl = result.verified ? .apple : .unknown
            needsRestoration = !result.verified
        }
        guard result.verified else { return false }
        do { try recovery.restored() }
        catch { fatalFailure("Recovery communication failed after restoration: \(error.localizedDescription)"); return false }
        return true
    }

    private func failControl(_ error: Error, expected: Owner?) {
        state {
            if let expected, owner?.cancellation === expected.cancellation { endSession(.backendFailure) }
            snapshot.restorationErrors = [error.localizedDescription]
        }
        _ = restoreOnWorkQueue()
        if let message = state({ protectionFailure }) { fatalFailure(message) }
    }
    private func fatalFailure(_ message: String) {
        let notify = state { () -> Bool in
            guard !fatal else { return false }
            fatal = true
            endSession(.backendFailure)
            snapshot.restorationErrors.append(message)
            timer?.cancel(); timer = nil
            leaseTimer?.cancel(); leaseTimer = nil
            return true
        }
        if notify { onFatalFailure(message) }
    }

    private func runCalibration(owner expected: Owner, parameters: CalibrationJobParameters, jobID: String) {
        var runner: (any BackendCalibrationRunning)?
        var result: Result<CalibrationData, Error>
        let lidClosed = lidStateProvider.isLidClosed
        do {
            try validOwner(expected)
            guard restoreOnWorkQueue() else { throw Failure.rejected("Calibration requires verified Apple restoration") }
            let existing = try calibrationStore.load(lidClosed: lidClosed)
            let initialStatus = try sample(owner: expected)
            try protect { try recovery.completedWork() }
            let currentAmbient = TemperatureSummary(initialStatus.temperatures).ambient
            let reused: Float?
            if !parameters.rediscoverIntensity,
               let existing, existing.stressType == parameters.stressType,
               let intensity = existing.workloadIntensity, (0.001...0.5).contains(intensity),
               let previousAmbient = existing.ambientTemperature, previousAmbient.isFinite,
               let currentAmbient, currentAmbient.isFinite,
               abs(previousAmbient - currentAmbient) <= 3 {
                reused = intensity
            } else { reused = nil }
            let context = BackendCalibrationContext(parameters: parameters,
                workloadIntensity: parameters.workloadIntensity ?? reused,
                cancellation: expected.cancellation, lidClosed: lidClosed,
                readStatus: { [self] in
                    do {
                        let status = try sample(owner: expected)
                        try protect { try recovery.completedWork() }
                        return status
                    } catch {
                        expected.cancellation.cancel()
                        throw error
                    }
                },
                apply: { [self] command in try apply(command, owner: expected) },
                progress: { [weak self] message in self?.state { self?.snapshot.calibration?.message = message } })
            runner = try calibrationFactory(context)
            state { snapshot.calibration?.phase = .running }
            result = .success(try runner!.run())
        } catch { result = .failure(error) }

        if let runner, !runner.stopWorkloads() {
            state { unsafeWorkloads = true; snapshot.calibration?.phase = .failed; snapshot.calibration?.message = CalibrationError.workloadShutdownFailed.localizedDescription; calibrationActive = false }
            // Do not restore while a workload may still be executing. Exiting the
            // process stops it; independent recovery writes only after confirmed exit.
            fatalFailure(CalibrationError.workloadShutdownFailed.localizedDescription)
            return
        }
        // A runner reporting failed shutdown cannot be treated as an ordinary
        // calibration failure even if a subsequent stop happens to succeed.
        if case .failure(CalibrationError.workloadShutdownFailed) = result {
            state { unsafeWorkloads = true; snapshot.calibration?.phase = .failed; calibrationActive = false }
            fatalFailure(CalibrationError.workloadShutdownFailed.localizedDescription)
            return
        }
        let restored = restoreOnWorkQueue()
        do {
            let calibration = try result.get()
            try validOwner(expected)
            guard restored, calibration.lidClosed == lidClosed, lidStateProvider.isLidClosed == lidClosed else {
                throw Failure.rejected("Calibration handback or lid-state verification failed")
            }
            try calibrationStore.save(calibration)
            state { snapshot.calibration?.phase = .completed; snapshot.calibration?.message = "Calibration saved"; snapshot.calibrationLidClosed = lidClosed }
        } catch {
            state {
                snapshot.calibration?.phase = expected.cancellation.isCancelled ? .cancelled : .failed
                snapshot.calibration?.message = error.localizedDescription
            }
            if case Failure.protection = error { fatalFailure(error.localizedDescription) }
        }
        if let message = state({ protectionFailure }) { fatalFailure(message) }
        state {
            calibrationActive = false
            if owner?.cancellation === expected.cancellation {
                snapshot.endedSessions[expected.session.id] = .released
                endedSessionOrder.append(expected.session.id)
                while endedSessionOrder.count > 256 {
                    snapshot.endedSessions.removeValue(forKey: endedSessionOrder.removeFirst())
                }
                owner = nil; snapshot.owner = nil; snapshot.ownerKind = nil; snapshot.requestedIntent = nil
                snapshot.lastSessionEndReason = .released
            }
        }
    }
}
