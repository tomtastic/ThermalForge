import Foundation

/// One logical client. Observing status never acquires or extends ownership.
/// The transport is injectable without adding production fake-hardware options.
public actor BackendClient {
    public typealias Transport = (Data) async throws -> Data

    private let kind: ControlClientKind
    private let transport: Transport
    private var session: ControlSession?
    private var desiredProfile: String?
    private var profileRecoveryEpoch: String?
    private var communicationFailed = false
    private var ownershipEpoch = 0
    private var pendingAcquisition: (epoch: Int, task: Task<BackendResponse, Error>)?
    public private(set) var snapshot: BackendSnapshot?

    public init(kind: ControlClientKind = .cli,
                socketPath: String = ThermalForgeDaemon.socketPath,
                transport: Transport? = nil) {
        self.kind = kind
        self.transport = transport ?? { data in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try UnixSocketTransport.roundTrip(data, path: socketPath,
                            timeout: BackendTiming.requestDeadline)
                    })
                }
            }
        }
    }

    public var ownsControl: Bool { session != nil && snapshot?.owner == session }

    private func send(_ request: BackendRequest) async throws -> BackendResponse {
        let data: Data
        do { data = try await transport(JSONEncoder().encode(request)) }
        catch {
            communicationFailed = true
            throw error
        }
        let response: BackendResponse
        do { response = try JSONDecoder().decode(BackendResponse.self, from: data) }
        catch { communicationFailed = true; throw DaemonError.protocolError("Invalid backend response") }
        guard response.version == 2, response.requestID == request.requestID else {
            communicationFailed = true
            throw DaemonError.protocolError("Backend version or request identity mismatch")
        }
        guard response.ok else {
            let error = response.error ?? DaemonErrorPayload(code: "backend_error", message: "Request rejected")
            throw DaemonError.commandFailed(code: error.code, message: error.message)
        }
        return response
    }

    /// Pure observation, including when this client happens to own a session.
    @discardableResult public func status() async throws -> BackendSnapshot {
        let epoch = ownershipEpoch
        let response = try await send(BackendRequest(operation: .status))
        guard let value = response.snapshot else { throw DaemonError.protocolError("Missing backend snapshot") }
        if epoch == ownershipEpoch { observe(value) }
        return value
    }

    private func observe(_ value: BackendSnapshot) {
        let previousGeneration = snapshot?.generation
        snapshot = value
        guard let owned = session, value.owner != owned else { return }
        let endReason = value.endedSessions[owned.id] ?? value.lastSessionEndReason
        // Explicit user actions always beat automatic profile reconnection,
        // even if another session subsequently expired while this client was away.
        if value.owner != nil || [.takeover, .explicitAuto, .released, .sleep].contains(endReason) {
            session = nil
            desiredProfile = nil
            communicationFailed = false
        } else if endReason == .backendFailure || previousGeneration != value.generation {
            communicationFailed = true
            session = nil
        } else if !communicationFailed {
            session = nil
            desiredProfile = nil
        }
    }

    @discardableResult public func acquire(_ intent: ControlIntent, takeover: Bool = false) async throws -> BackendSnapshot {
        try await acquire(intent, takeover: takeover, automaticRecovery: false)
    }

    private func acquire(_ intent: ControlIntent, takeover: Bool, automaticRecovery: Bool) async throws -> BackendSnapshot {
        let epoch = ownershipEpoch
        if let pending = pendingAcquisition { _ = try? await pending.task.value }
        let current = try await status()
        try Task.checkCancellation()
        guard epoch == ownershipEpoch else { throw CancellationError() }
        let candidate = session ?? ControlSession(generation: current.generation)
        ownershipEpoch += 1
        let acquisitionEpoch = ownershipEpoch
        session = candidate
        if kind == .gui, case let .profile(id) = intent { desiredProfile = id }
        else { desiredProfile = nil }
        do {
            let response = try await sendAcquisition(BackendRequest(operation: .acquire, session: candidate,
                clientKind: kind, intent: intent, takeover: takeover,
                automaticRecovery: automaticRecovery, recoveryEpoch: automaticRecovery ? profileRecoveryEpoch : nil))
            guard let value = response.snapshot, value.owner == candidate else {
                throw DaemonError.protocolError("Acquisition did not return the requested session")
            }
            if acquisitionEpoch == ownershipEpoch {
                snapshot = value
                communicationFailed = false
                if !automaticRecovery { profileRecoveryEpoch = value.recoveryEpoch }
            }
            return value
        } catch let error as DaemonError {
            if acquisitionEpoch == ownershipEpoch, case .commandFailed = error { session = nil; desiredProfile = nil }
            throw error
        }
    }

    private func sendAcquisition(_ request: BackendRequest) async throws -> BackendResponse {
        let epoch = ownershipEpoch
        let task = Task { try await self.send(request) }
        pendingAcquisition = (epoch, task)
        defer { if pendingAcquisition?.epoch == epoch { pendingAcquisition = nil } }
        return try await task.value
    }

    /// Call about every two seconds, independently of display/printing cadence.
    @discardableResult public func maintain() async throws -> BackendSnapshot {
        var current = try await status()
        try Task.checkCancellation()
        if let owned = session, current.owner == owned {
            let epoch = ownershipEpoch
            let response = try await send(BackendRequest(operation: .renew, session: owned))
            if epoch == ownershipEpoch, let value = response.snapshot { observe(value); current = value }
            communicationFailed = false
        } else if kind == .gui, communicationFailed, let profile = desiredProfile,
                  current.owner == nil, current.restoration == .verified {
            session = nil
            current = try await acquire(.profile(profile), takeover: false, automaticRecovery: true)
        }
        return current
    }

    /// Release only the identity created by this client, never a global reset.
    @discardableResult public func release() async throws -> BackendSnapshot? {
        ownershipEpoch += 1
        let owned = session
        session = nil
        desiredProfile = nil
        communicationFailed = false
        guard let owned else { return nil }
        // Fence an accepted-but-not-yet-answered acquisition before releasing it.
        if let pending = pendingAcquisition { _ = try? await pending.task.value }
        let response = try await send(BackendRequest(operation: .release, session: owned))
        if let value = response.snapshot { snapshot = value }
        return response.snapshot
    }

    @discardableResult public func restoreApple() async throws -> BackendSnapshot {
        ownershipEpoch += 1
        desiredProfile = nil
        session = nil
        communicationFailed = false
        if let pending = pendingAcquisition { _ = try? await pending.task.value }
        let current = try await status()
        let response = try await send(BackendRequest(operation: .restoreApple,
            session: ControlSession(generation: current.generation), clientKind: kind))
        guard let value = response.snapshot else { throw DaemonError.protocolError("Missing restoration snapshot") }
        snapshot = value
        return value
    }

    public func configuration() async throws -> BackendConfiguration {
        let response = try await send(BackendRequest(operation: .configuration))
        guard let value = response.configuration else { throw DaemonError.protocolError("Missing configuration") }
        return value
    }

    /// Revision conflicts are returned to the caller; never overwrite an intervening edit.
    public func updateConfiguration(_ configuration: BackendConfiguration) async throws -> BackendConfiguration {
        let response = try await send(BackendRequest(operation: .updateConfiguration, configuration: configuration))
        guard let value = response.configuration else { throw DaemonError.protocolError("Missing updated configuration") }
        return value
    }

    public func importLegacy(_ values: LegacyConfigurationImport) async throws -> BackendConfiguration {
        let response = try await send(BackendRequest(operation: .importLegacy, legacyImport: values))
        guard let value = response.configuration else { throw DaemonError.protocolError("Missing imported configuration") }
        return value
    }

    @discardableResult public func startCalibration(_ parameters: CalibrationJobParameters,
                                                   takeover: Bool = false) async throws -> BackendSnapshot {
        let epoch = ownershipEpoch
        if let pending = pendingAcquisition { _ = try? await pending.task.value }
        let current = try await status()
        try Task.checkCancellation()
        guard epoch == ownershipEpoch else { throw CancellationError() }
        let candidate = ControlSession(generation: current.generation)
        ownershipEpoch += 1
        let acquisitionEpoch = ownershipEpoch
        session = candidate
        desiredProfile = nil
        do {
            let response = try await sendAcquisition(BackendRequest(operation: .startCalibration, session: candidate,
                clientKind: kind, takeover: takeover, calibration: parameters))
            guard let value = response.snapshot, value.owner == candidate else {
                throw DaemonError.protocolError("Missing calibration ownership")
            }
            if acquisitionEpoch == ownershipEpoch {
                snapshot = value
                communicationFailed = false
            }
            return value
        } catch let error as DaemonError {
            if acquisitionEpoch == ownershipEpoch, case .commandFailed = error { session = nil }
            throw error
        }
    }

    @discardableResult public func cancelCalibration() async throws -> BackendSnapshot {
        let current = try await status()
        let response = try await send(BackendRequest(operation: .cancelCalibration,
            session: session ?? ControlSession(generation: current.generation), clientKind: kind))
        guard let value = response.snapshot else { throw DaemonError.protocolError("Missing calibration snapshot") }
        snapshot = value
        return value
    }

    public func resetCalibration() async throws {
        _ = try await send(BackendRequest(operation: .resetCalibration))
    }
}

/// A read-only migration bridge. It exports values and never follows paths on
/// behalf of the privileged backend or mutates/deletes a legacy source file.
public enum LegacyConfigurationReader {
    public static func read(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                            defaults: UserDefaults = .standard) -> LegacyConfigurationImport {
        let directory = homeDirectory.appendingPathComponent("Library/Application Support/ThermalForge")
        let profilesDirectory = directory.appendingPathComponent("profiles")
        var profiles = FanProfile.builtIn
        let files = (try? FileManager.default.contentsOfDirectory(at: profilesDirectory,
            includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? JSONDecoder().decode(FanProfile.self, from: data),
                  (try? BackendConfigurationStore.validate(BackendConfiguration(profiles: [profile], selectedProfileID: profile.id))) != nil else { continue }
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
            else if profiles.count < 128 { profiles.append(profile) }
        }
        var rules: [ThermalRule] = []
        if let data = try? Data(contentsOf: directory.appendingPathComponent("rules.json")) {
            rules = (try? JSONDecoder().decode([ThermalRule].self, from: data)) ?? []
        }
        let legacyKeys = ["customRuleEnabled", "customRuleTriggerTempC", "customRuleReleaseTempC", "customRuleFanPercent"]
        if !rules.contains(where: { $0.id == LegacyTemperatureRuleMigration.ruleID }),
           legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            func number(_ key: String, fallback: Double, lower: Double, upper: Double) -> Double {
                let value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
                return min(max(value.isFinite ? value : fallback, lower), upper)
            }
            let trigger = number("customRuleTriggerTempC", fallback: 55, lower: 40, upper: 95)
            let release = number("customRuleReleaseTempC", fallback: 50, lower: 35, upper: trigger - 1)
            let percent = number("customRuleFanPercent", fallback: 100, lower: 20, upper: 100)
            rules.append(ThermalRule(id: LegacyTemperatureRuleMigration.ruleID,
                name: "IF temp ≥ \(Int(trigger))°C THEN \(Int(percent))% until ≤ \(Int(release))°C",
                enabled: defaults.bool(forKey: "customRuleEnabled"), priority: 1_000,
                condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: Float(trigger)),
                action: .setFanPercent(Float(percent / 100)), untilTempBelowC: Float(release)))
        }
        var seenRuleIDs = Set<String>()
        rules = rules.filter { rule in
            guard seenRuleIDs.insert(rule.id).inserted,
                  (try? BackendConfigurationStore.validate(BackendConfiguration(profiles: profiles, rules: [rule]))) != nil else { return false }
            return true
        }
        rules = Array(rules.prefix(256))
        let selected = defaults.string(forKey: "lastProfileID") ?? "silent"
        let configuration = BackendConfiguration(profiles: profiles, rules: rules,
            selectedProfileID: profiles.contains(where: { $0.id == selected }) ? selected : "silent",
            rulesEnabled: defaults.object(forKey: "rulesEnabled") as? Bool ?? true)
        let calibration: [CalibrationData] = [false, true].compactMap { lidClosed in
            let file = directory.appendingPathComponent("calibration_\(lidClosed ? "lid_closed" : "lid_open").json")
            guard let data = try? Data(contentsOf: file),
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  fields["lidClosed"] is Bool,
                  let value = try? JSONDecoder().decode(CalibrationData.self, from: data),
                  value.lidClosed == lidClosed, value.isValid else { return nil }
            return value
        }
        return LegacyConfigurationImport(configuration: configuration, calibration: calibration)
    }
}
