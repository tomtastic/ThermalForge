import Foundation

/// Version two separates client liveness from completed controller progress.
public enum BackendTiming {
    public static let requestDeadline: TimeInterval = 2
    public static let clientLease: TimeInterval = 10
    public static let protectionLease: TimeInterval = 10
    public static let progressInterval: TimeInterval = 2
    public static let expiryInterval: TimeInterval = 1
    public static let terminationGrace: TimeInterval = 1
    public static let unlockBudget: TimeInterval = 8
    public static let maximumFrameBytes = 1024 * 1024
    public static var monotonicNow: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

public struct ControlSession: Codable, Equatable {
    public var id: String
    public var generation: String
    public init(id: String = UUID().uuidString, generation: String) {
        self.id = id
        self.generation = generation
    }
}

public enum ControlClientKind: String, Codable { case gui, cli }

public enum ControlIntent: Codable, Equatable {
    case profile(String)
    case rpm(Int)
    case maximum
}

public struct BackendConfiguration: Codable, Equatable {
    public var revision: Int
    public var profiles: [FanProfile]
    public var rules: [ThermalRule]
    public var selectedProfileID: String
    public var rulesEnabled: Bool
    public var importedLegacy: Bool
    public var recoveryEpoch: String?

    public init(revision: Int = 0, profiles: [FanProfile] = FanProfile.builtIn,
                rules: [ThermalRule] = [], selectedProfileID: String = "silent",
                rulesEnabled: Bool = true, importedLegacy: Bool = false, recoveryEpoch: String? = nil) {
        self.revision = revision
        self.profiles = profiles
        self.rules = rules
        self.selectedProfileID = selectedProfileID
        self.rulesEnabled = rulesEnabled
        self.importedLegacy = importedLegacy
        self.recoveryEpoch = recoveryEpoch
    }
}

/// Values only: the privileged backend never follows client-supplied paths.
public struct LegacyConfigurationImport: Codable {
    public var configuration: BackendConfiguration
    public var calibration: [CalibrationData]
    public init(configuration: BackendConfiguration, calibration: [CalibrationData] = []) {
        self.configuration = configuration
        self.calibration = calibration
    }
}

public struct CalibrationJobParameters: Codable, Equatable {
    public var mode: String
    public var stressType: String
    public var force: Bool
    public var rediscoverIntensity: Bool
    public var workloadIntensity: Float?
    public init(mode: String = "standard", stressType: String = "cpu", force: Bool = false,
                rediscoverIntensity: Bool = false, workloadIntensity: Float? = nil) {
        self.mode = mode
        self.stressType = stressType
        self.force = force
        self.rediscoverIntensity = rediscoverIntensity
        self.workloadIntensity = workloadIntensity
    }
}

public enum BackendOperation: String, Codable {
    case status, configuration, updateConfiguration, importLegacy
    case acquire, renew, release, restoreApple
    case startCalibration, cancelCalibration, resetCalibration
}

public struct BackendRequest: Codable {
    public var version: Int
    public var requestID: String
    public var operation: BackendOperation
    public var session: ControlSession?
    public var clientKind: ControlClientKind?
    public var intent: ControlIntent?
    public var takeover: Bool
    public var automaticRecovery: Bool
    public var recoveryEpoch: String?
    public var configuration: BackendConfiguration?
    public var legacyImport: LegacyConfigurationImport?
    public var calibration: CalibrationJobParameters?

    public init(operation: BackendOperation, session: ControlSession? = nil,
                clientKind: ControlClientKind? = nil, intent: ControlIntent? = nil,
                takeover: Bool = false, automaticRecovery: Bool = false, recoveryEpoch: String? = nil,
                configuration: BackendConfiguration? = nil,
                legacyImport: LegacyConfigurationImport? = nil,
                calibration: CalibrationJobParameters? = nil,
                version: Int = 2, requestID: String = UUID().uuidString) {
        self.version = version
        self.requestID = requestID
        self.operation = operation
        self.session = session
        self.clientKind = clientKind
        self.intent = intent
        self.takeover = takeover
        self.automaticRecovery = automaticRecovery
        self.recoveryEpoch = recoveryEpoch
        self.configuration = configuration
        self.legacyImport = legacyImport
        self.calibration = calibration
    }
}

public enum AcknowledgedControl: Codable, Equatable {
    case unknown, apple, manualRPM(Int), maximum
}

public enum RestorationState: String, Codable { case unknown, pending, verified, failed }

public struct RestorationResult: Codable, Equatable {
    public var verified: Bool
    public var errors: [String]
    public init(verified: Bool, errors: [String] = []) {
        self.verified = verified
        self.errors = errors
    }
}

public enum SessionEndReason: String, Codable {
    case released, takeover, explicitAuto, clientExpired, backendFailure, sleep
}

public enum CalibrationJobPhase: String, Codable {
    case pending, running, cancelling, completed, cancelled, failed
}

public struct CalibrationJobSnapshot: Codable {
    public var id: String
    public var phase: CalibrationJobPhase
    public var message: String
    public init(id: String, phase: CalibrationJobPhase, message: String = "") {
        self.id = id
        self.phase = phase
        self.message = message
    }
}

public struct BackendSnapshot: Codable {
    public var generation: String
    public var recoveryEpoch: String?
    public var requestedIntent: ControlIntent?
    public var acknowledgedControl: AcknowledgedControl
    public var sensors: ThermalStatus?
    public var sampledAt: TimeInterval?
    public var owner: ControlSession?
    public var ownerKind: ControlClientKind?
    public var restoration: RestorationState
    public var restorationErrors: [String]
    public var lastSessionEndReason: SessionEndReason?
    public var endedSessions: [String: SessionEndReason]
    public var calibration: CalibrationJobSnapshot?
    public var configurationRevision: Int
    public var activeProfileID: String?
    public var calibrationLidClosed: Bool?

    public init(generation: String, recoveryEpoch: String? = nil, requestedIntent: ControlIntent? = nil,
                acknowledgedControl: AcknowledgedControl = .unknown,
                sensors: ThermalStatus? = nil, sampledAt: TimeInterval? = nil,
                owner: ControlSession? = nil, ownerKind: ControlClientKind? = nil,
                restoration: RestorationState = .unknown, restorationErrors: [String] = [],
                lastSessionEndReason: SessionEndReason? = nil,
                endedSessions: [String: SessionEndReason] = [:],
                calibration: CalibrationJobSnapshot? = nil, configurationRevision: Int = 0,
                activeProfileID: String? = nil, calibrationLidClosed: Bool? = nil) {
        self.generation = generation
        self.recoveryEpoch = recoveryEpoch
        self.requestedIntent = requestedIntent
        self.acknowledgedControl = acknowledgedControl
        self.sensors = sensors
        self.sampledAt = sampledAt
        self.owner = owner
        self.ownerKind = ownerKind
        self.restoration = restoration
        self.restorationErrors = restorationErrors
        self.lastSessionEndReason = lastSessionEndReason
        self.endedSessions = endedSessions
        self.calibration = calibration
        self.configurationRevision = configurationRevision
        self.activeProfileID = activeProfileID
        self.calibrationLidClosed = calibrationLidClosed
    }
}

public struct BackendResponse: Codable {
    public var version: Int = 2
    public var requestID: String
    public var ok: Bool
    public var accepted: Bool
    public var snapshot: BackendSnapshot?
    public var configuration: BackendConfiguration?
    public var error: DaemonErrorPayload?
    public init(requestID: String, ok: Bool = true, accepted: Bool = false,
                snapshot: BackendSnapshot? = nil, configuration: BackendConfiguration? = nil,
                error: DaemonErrorPayload? = nil) {
        self.requestID = requestID
        self.ok = ok
        self.accepted = accepted
        self.snapshot = snapshot
        self.configuration = configuration
        self.error = error
    }
}

/// Populated from the socket, never decoded from a request body.
public struct AuthenticatedPeer: Equatable {
    public var uid: UInt32
    public var pid: Int32
    public init(uid: UInt32, pid: Int32) { self.uid = uid; self.pid = pid }
}

public protocol BackendRequestHandling: AnyObject {
    /// Must return cached state / accepted work promptly, without waiting on SMC.
    func handle(_ request: BackendRequest, peer: AuthenticatedPeer) -> BackendResponse
}

/// All normal writes and calibration writes go through the same serialized gate.
public protocol BackendActuating: AnyObject {
    func apply(_ command: FanCommand, cancellation: CancellationToken) throws
    func restoreApple() -> RestorationResult
}

public protocol RecoveryProtecting: AnyObject {
    /// Persist the marker before returning permission for any manual write.
    func authorizeManual() throws
    /// Called only after completed sensing/control, never by client status/renewal.
    func completedWork() throws
    /// Clear protection only after hardware restoration is verified.
    func restored() throws
}
