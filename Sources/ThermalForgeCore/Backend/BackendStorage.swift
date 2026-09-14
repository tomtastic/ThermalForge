import Foundation

public enum BackendStorageError: LocalizedError {
    case invalid(String), conflict
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .conflict: return "Configuration changed; reload it before editing"
        }
    }
}

public protocol BackendConfigurationStoring: AnyObject {
    func load(uid: UInt32) throws -> BackendConfiguration
    func update(_ configuration: BackendConfiguration, uid: UInt32) throws -> BackendConfiguration
    func importLegacy(_ configuration: BackendConfiguration, uid: UInt32) throws -> BackendConfiguration
    func invalidateAutomaticRecovery(uid: UInt32) throws -> BackendConfiguration
}

/// A single atomic envelope records both values and migration precedence.
public final class BackendConfigurationStore: BackendConfigurationStoring {
    private struct Envelope: Codable {
        var version = 2
        var configuration: BackendConfiguration
        var editedFields: Set<String> = []
    }
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL = URL(fileURLWithPath: "/Library/Application Support/ThermalForge/users", isDirectory: true)) {
        self.directory = directory
    }
    private func path(_ uid: UInt32) -> URL { directory.appendingPathComponent(String(uid)).appendingPathComponent("configuration.json") }
    private func read(_ uid: UInt32) throws -> Envelope {
        let url = path(uid)
        guard FileManager.default.fileExists(atPath: url.path) else { return Envelope(configuration: BackendConfiguration()) }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 2 else { throw BackendStorageError.invalid("Unsupported configuration storage version") }
        try Self.validate(envelope.configuration)
        return envelope
    }
    private func write(_ envelope: Envelope, uid: UInt32) throws {
        let url = path(uid)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load(uid: UInt32) throws -> BackendConfiguration {
        lock.lock(); defer { lock.unlock() }
        return try read(uid).configuration
    }
    public func update(_ configuration: BackendConfiguration, uid: UInt32) throws -> BackendConfiguration {
        try Self.validate(configuration)
        lock.lock(); defer { lock.unlock() }
        var envelope = try read(uid)
        let old = envelope.configuration
        guard configuration.revision == old.revision else { throw BackendStorageError.conflict }
        if old.profiles != configuration.profiles { envelope.editedFields.insert("profiles") }
        if old.rules != configuration.rules { envelope.editedFields.insert("rules") }
        if old.selectedProfileID != configuration.selectedProfileID { envelope.editedFields.insert("selectedProfileID") }
        if old.rulesEnabled != configuration.rulesEnabled { envelope.editedFields.insert("rulesEnabled") }
        envelope.configuration = configuration
        envelope.configuration.importedLegacy = old.importedLegacy
        envelope.configuration.recoveryEpoch = old.recoveryEpoch
        envelope.configuration.revision = old.revision + 1
        try write(envelope, uid: uid)
        return envelope.configuration
    }
    public func importLegacy(_ configuration: BackendConfiguration, uid: UInt32) throws -> BackendConfiguration {
        try Self.validate(configuration)
        lock.lock(); defer { lock.unlock() }
        var envelope = try read(uid)
        guard !envelope.configuration.importedLegacy else { return envelope.configuration }
        var merged = envelope.configuration
        if !envelope.editedFields.contains("profiles") { merged.profiles = configuration.profiles }
        if !envelope.editedFields.contains("rules") { merged.rules = configuration.rules }
        if !envelope.editedFields.contains("selectedProfileID"), merged.profiles.contains(where: { $0.id == configuration.selectedProfileID }) {
            merged.selectedProfileID = configuration.selectedProfileID
        }
        if !envelope.editedFields.contains("rulesEnabled") { merged.rulesEnabled = configuration.rulesEnabled }
        merged.importedLegacy = true
        merged.revision += 1
        try Self.validate(merged)
        envelope.configuration = merged
        try write(envelope, uid: uid)
        return merged
    }
    public func invalidateAutomaticRecovery(uid: UInt32) throws -> BackendConfiguration {
        lock.lock(); defer { lock.unlock() }
        var envelope = try read(uid)
        envelope.configuration.recoveryEpoch = UUID().uuidString
        envelope.configuration.revision += 1
        try write(envelope, uid: uid)
        return envelope.configuration
    }

    public static func validate(_ configuration: BackendConfiguration) throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw BackendStorageError.invalid(message) }
        }
        try require(configuration.revision >= 0, "Invalid configuration revision")
        try require(!configuration.profiles.isEmpty && configuration.profiles.count <= 128, "Invalid profile count")
        try require(Set(configuration.profiles.map(\.id)).count == configuration.profiles.count, "Duplicate profile IDs")
        for profile in configuration.profiles {
            try require(!profile.id.isEmpty && profile.id.utf8.count <= 128 && !profile.name.isEmpty && profile.name.utf8.count <= 256, "Invalid profile identity")
            let curve = profile.curve
            let values = [curve.stopTemp, curve.startTemp, curve.ceilingTemp, curve.maxRPMPercent, curve.rampUpPerSec, curve.rampDownPerSec, curve.sustainedTriggerSec]
            try require(values.allSatisfy(\.isFinite), "Profile values must be finite")
            try require(curve.stopTemp >= 0 && curve.startTemp > curve.stopTemp && curve.ceilingTemp >= curve.startTemp && curve.ceilingTemp <= 120, "Invalid profile temperature bounds")
            try require((0...1).contains(curve.maxRPMPercent) && curve.rampUpPerSec > 0 && curve.rampDownPerSec > 0 && curve.sustainedTriggerSec >= 0 && curve.sustainedTriggerSec <= 300, "Invalid profile fan bounds")
        }
        try require(configuration.profiles.contains { $0.id == configuration.selectedProfileID }, "Selected profile is missing")
        try require(configuration.rules.count <= 256 && Set(configuration.rules.map(\.id)).count == configuration.rules.count, "Invalid or duplicate rules")
        for rule in configuration.rules {
            try require(!rule.id.isEmpty && rule.id.utf8.count <= 128 && !rule.name.isEmpty && rule.name.utf8.count <= 256, "Invalid rule identity")
            try require(rule.condition.valueCelsius.isFinite && (0...120).contains(rule.condition.valueCelsius), "Invalid rule threshold")
            if let until = rule.untilTempBelowC { try require(until.isFinite && (0...120).contains(until), "Invalid rule latch threshold") }
            switch rule.action {
            case .setRPM(let rpm): try require((1...30000).contains(rpm), "Invalid rule RPM")
            case .setFanPercent(let value): try require(value.isFinite && (0...1).contains(value), "Invalid rule fan percentage")
            case .selectProfile(let id): try require(configuration.profiles.contains { $0.id == id }, "Rule references missing profile")
            case .setMax, .resetAuto: break
            }
        }
    }
}

public protocol BackendCalibrationStoring: AnyObject {
    func load(lidClosed: Bool) throws -> CalibrationData?
    func save(_ calibration: CalibrationData) throws
    func importLegacy(_ calibrations: [CalibrationData]) throws
    func reset() throws
}

/// Machine calibration is an atomic two-lid envelope. The reset tombstone makes
/// both root legacy migration and subsequent user imports permanently ineligible.
public final class BackendCalibrationStore: BackendCalibrationStoring {
    private struct Envelope: Codable {
        var version = 2
        var reset = false
        var checkedRoot = false
        var open: CalibrationData?
        var closed: CalibrationData?
    }
    private let directory: URL
    private let legacyRoot: URL?
    private let lock = NSLock()
    public init(directory: URL = URL(fileURLWithPath: "/Library/Application Support/ThermalForge", isDirectory: true),
                legacyRoot: URL? = URL(fileURLWithPath: "/var/root/Library/Application Support/ThermalForge", isDirectory: true)) {
        self.directory = directory
        self.legacyRoot = legacyRoot
    }
    private var path: URL { directory.appendingPathComponent("machine-calibration-v2.json") }
    private func write(_ envelope: Envelope) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(envelope).write(to: path, options: .atomic)
    }
    private func read() throws -> Envelope {
        var envelope: Envelope
        if FileManager.default.fileExists(atPath: path.path) {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: path))
            guard envelope.version == 2 else { throw BackendStorageError.invalid("Unsupported calibration storage version") }
        } else { envelope = Envelope() }
        if !envelope.checkedRoot {
            if !envelope.reset, let legacyRoot {
                // Only state-specific filenames with an explicit matching value qualify.
                for lidClosed in [false, true] {
                    let url = legacyRoot.appendingPathComponent("calibration_\(lidClosed ? "lid_closed" : "lid_open").json")
                    if let data = try? Data(contentsOf: url),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let explicitLid = object["lidClosed"] as? Bool, explicitLid == lidClosed,
                       let calibration = try? JSONDecoder().decode(CalibrationData.self, from: data),
                       calibration.isValid {
                        if lidClosed { envelope.closed = envelope.closed ?? calibration }
                        else { envelope.open = envelope.open ?? calibration }
                    }
                }
            }
            envelope.checkedRoot = true
            try write(envelope)
        }
        return envelope
    }
    public func load(lidClosed: Bool) throws -> CalibrationData? {
        lock.lock(); defer { lock.unlock() }
        let envelope = try read()
        let result = lidClosed ? envelope.closed : envelope.open
        guard let result else { return nil }
        guard result.lidClosed == lidClosed, result.isValid else { throw BackendStorageError.invalid("Invalid stored calibration") }
        return result
    }
    public func save(_ calibration: CalibrationData) throws {
        if let error = calibration.validationError { throw BackendStorageError.invalid(error) }
        lock.lock(); defer { lock.unlock() }
        var envelope = try read()
        if calibration.lidClosed { envelope.closed = calibration } else { envelope.open = calibration }
        try write(envelope)
    }
    public func importLegacy(_ calibrations: [CalibrationData]) throws {
        guard calibrations.count <= 2 else { throw BackendStorageError.invalid("At most one calibration per lid state can be imported") }
        for calibration in calibrations {
            if let error = calibration.validationError { throw BackendStorageError.invalid(error) }
        }
        lock.lock(); defer { lock.unlock() }
        var envelope = try read()
        guard !envelope.reset else { return }
        for calibration in calibrations {
            if calibration.lidClosed { envelope.closed = envelope.closed ?? calibration }
            else { envelope.open = envelope.open ?? calibration }
        }
        try write(envelope)
    }
    public func reset() throws {
        lock.lock(); defer { lock.unlock() }
        // A reset never reads/imports old values first.
        try write(Envelope(reset: true, checkedRoot: true))
    }
}
