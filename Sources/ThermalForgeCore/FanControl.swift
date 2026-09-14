//
//  FanControl.swift
//  ThermalForge
//
//  Core fan control operations: unlock, set speed, reset, status, discover.
//

import Foundation

// MARK: - Types

public enum ThermalForgeError: Error, CustomStringConvertible {
    case smcConnectionFailed
    case unlockFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case cancelled
    case restorationFailed([String])
    case rpmOutOfRange(requested: Float, min: Float, max: Float)

    public var description: String {
        switch self {
        case .cancelled: return "Fan operation cancelled"
        case .restorationFailed(let errors): return "Apple restoration unverified: " + errors.joined(separator: "; ")
        case .smcConnectionFailed:
            return "Failed to connect to AppleSMC. Is this a Mac with SMC?"
        case .unlockFailed(let detail):
            return "Fan unlock failed: \(detail)"
        case .readFailed(let key):
            return "Failed to read SMC key: \(key)"
        case .writeFailed(let key):
            return "Failed to write SMC key: \(key). Run with sudo."
        case .rpmOutOfRange(let req, let min, let max):
            return "RPM \(Int(req)) is out of range [\(Int(min))–\(Int(max))]"
        }
    }
}

public struct FanInfo {
    public let index: Int
    public let actualRPM: Float
    public let targetRPM: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let mode: String
}

public struct ThermalStatus: Codable, Equatable {
    public let fans: [FanStatus]
    public let temperatures: [String: Float]

    public struct FanStatus: Codable, Equatable {
        public let index: Int
        public let actualRPM: Int
        public let targetRPM: Int
        public let minRPM: Int
        public let maxRPM: Int
        public let mode: String
    }
}

public struct DiscoveredKey {
    public let key: String
    public let size: UInt32
    public let type: String
    public let bytes: [UInt8]
}

// MARK: - Fan Control

public final class FanControl {
    private let smc: SMCReading
    private let wait: (TimeInterval) -> Void
    /// Which mode key works on this hardware (detected at init)
    private var modeKeys: [Int: String] = [:]
    private let now: () -> TimeInterval

    // Hardware facts that never change for a session — read once, then cached.
    // FanControl is only ever accessed serially (monitor queue / daemon smcLock /
    // CLI), so these lazy caches need no locking of their own.
    private var cachedFanCount: Int?
    private var cachedLimits: [Int: (min: Float, max: Float)] = [:]
    private var liveTempKeys: [LiveTempKey]?

    /// Creates a FanControl backed by the real SMC. Throws if no SMC is present.
    public convenience init() throws {
        guard let connection = SMCConnection() else {
            throw ThermalForgeError.smcConnectionFailed
        }
        self.init(smc: connection)
    }

    /// Designated init — accepts any SMC backend (real or a test fake).
    public convenience init(smc: SMCReading) {
        self.init(smc: smc, wait: Thread.sleep(forTimeInterval:))
    }

    public init(smc: SMCReading, wait: @escaping (TimeInterval) -> Void,
                now: @escaping () -> TimeInterval = { BackendTiming.monotonicNow }) {
        self.smc = smc
        self.wait = wait
        self.now = now
    }

    private func modeKey(_ index: Int) -> String? {
        if let key = modeKeys[index] { return key }
        var knownPresent: String?
        for template in [SMCFanKey.modeLower, SMCFanKey.modeUpper] {
            let key = SMCFanKey.key(template, fan: index)
            let result = smc.readKey(key)
            if result.success, result.size == 1, result.bytes.count == 1 {
                modeKeys[index] = key
                return key
            }
            // Metadata can identify the mode key even when its current value
            // is unreadable. Recovery still attempts the write, then requires
            // a readable automatic/system value to verify handback.
            if case .present(size: 1) = smc.keyAvailability(key) { knownPresent = knownPresent ?? key }
        }
        if let knownPresent { modeKeys[index] = knownPresent }
        return knownPresent
    }

    // MARK: - Fan Count

    public func fanCount() throws -> Int {
        if let cached = cachedFanCount { return cached }
        let result = smc.readKey(SMCFanKey.count)
        guard result.success, result.size == 1, result.bytes.count == 1 else {
            throw ThermalForgeError.readFailed(SMCFanKey.count)
        }
        let count = Int(result.bytes[0])
        guard count <= 16 else { throw ThermalForgeError.readFailed(SMCFanKey.count) }
        cachedFanCount = count
        return count
    }

    // MARK: - Read Fan Info

    public func fanInfo(_ index: Int) throws -> FanInfo {
        let actual = readFanFloat(index, template: SMCFanKey.actual)
        let target = readFanFloat(index, template: SMCFanKey.target)
        let limits = fanLimits(index)

        return FanInfo(
            index: index,
            actualRPM: actual,
            targetRPM: target,
            minRPM: limits.min,
            maxRPM: limits.max,
            mode: readMode(index)
        )
    }

    /// Per-fan min/max RPM are firmware constants — read once, then cached.
    /// Only cached once a valid maximum (> 0) is seen, so a transient zero read
    /// at startup isn't latched.
    private func fanLimits(_ index: Int) -> (min: Float, max: Float) {
        if let cached = cachedLimits[index] { return cached }
        let minimum = readFanFloatValue(index, template: SMCFanKey.minimum)
        let maximum = readFanFloatValue(index, template: SMCFanKey.maximum)
        if let minimum, let maximum, maximum > 0, maximum >= minimum {
            cachedLimits[index] = (minimum, maximum)
        }
        return (minimum ?? 0, maximum ?? 0)
    }

    private func verifiedFanLimits(_ index: Int) throws -> (min: Float, max: Float) {
        let limits = fanLimits(index)
        guard cachedLimits[index] != nil else {
            throw ThermalForgeError.readFailed("fan \(index) RPM limits")
        }
        return limits
    }

    private func readMode(_ index: Int) -> String {
        guard let key = modeKey(index) else { return "unknown" }
        let result = smc.readKey(key)
        guard result.success, result.size == 1, result.bytes.count == 1 else { return "unknown" }
        switch result.bytes[0] {
        case 0: return "auto"
        case 1: return "manual"
        case 3: return "system"
        default: return "unknown(\(result.bytes[0]))"
        }
    }

    /// Min/max RPM of the primary fan (fan 0), cached. Falls back to typical
    /// Apple Silicon values when no fan is present or limits read as zero.
    public func primaryFanLimits() -> (minRPM: Float, maxRPM: Float) {
        guard let count = try? fanCount(), count > 0 else { return (2317, 7826) }
        let limits = fanLimits(0)
        return (limits.min > 0 ? limits.min : 2317, limits.max > 0 ? limits.max : 7826)
    }

    // MARK: - Unlock

    private func checkCancellation(_ cancellation: CancellationToken, deadline: TimeInterval) throws {
        guard !cancellation.isCancelled else { throw ThermalForgeError.cancelled }
        guard now() < deadline else { throw ThermalForgeError.unlockFailed("Eight-second preparation budget expired") }
    }

    private func unlockFans(_ indices: [Int], cancellation: CancellationToken) throws {
        let deadline = now() + BackendTiming.unlockBudget
        try checkCancellation(cancellation, deadline: deadline)
        let ftstAvailability = smc.keyAvailability(SMCFanKey.forceTest)
        switch ftstAvailability {
        case .absent, .present(size: 1): break
        default: throw ThermalForgeError.readFailed(SMCFanKey.forceTest)
        }
        var lockedIndices: [Int] = []
        for index in indices {
            let mode = readMode(index)
            guard ["auto", "manual", "system"].contains(mode) else {
                throw ThermalForgeError.unlockFailed("Fan \(index) mode is unreadable or unsupported")
            }
            if mode != "manual" { lockedIndices.append(index) }
        }
        guard !lockedIndices.isEmpty else { return }
        // Resolve every mode before enabling the diagnostic override.
        for index in lockedIndices {
            guard modeKey(index) != nil else { throw ThermalForgeError.readFailed("fan \(index) mode") }
        }
        switch ftstAvailability {
        case .present(size: 1):
            guard smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
                throw ThermalForgeError.unlockFailed("Ftst write rejected")
            }
            for _ in 0..<5 {
                try checkCancellation(cancellation, deadline: deadline)
                wait(0.1)
            }
        case .absent: break
        default: throw ThermalForgeError.readFailed(SMCFanKey.forceTest)
        }
        for index in lockedIndices {
            guard let key = modeKey(index) else { throw ThermalForgeError.readFailed("fan mode") }
            while true {
                try checkCancellation(cancellation, deadline: deadline)
                if smc.writeKey(key, bytes: [1]), readMode(index) == "manual" { break }
                wait(0.1)
            }
        }
    }

    // MARK: - Set Speed

    private func validate(rpm: Float, limits: (min: Float, max: Float)) throws {
        guard rpm.isFinite, limits.min.isFinite, limits.max.isFinite,
              limits.min >= 0, limits.max > 0 else { throw ThermalForgeError.readFailed("fan RPM limits") }
        if limits.min > 0, rpm < limits.min {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm,
                min: limits.min,
                max: limits.max
            )
        }
        if limits.max > 0, rpm > limits.max {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm,
                min: limits.min,
                max: limits.max
            )
        }
    }

    private func writeTarget(fan index: Int, rpm: Float) throws {
        let targetKey = SMCFanKey.key(SMCFanKey.target, fan: index)
        guard smc.writeKey(targetKey, bytes: floatToSMCBytes(rpm)) else {
            throw ThermalForgeError.writeFailed(targetKey)
        }
        let acknowledged = smc.readKey(targetKey)
        guard acknowledged.success, acknowledged.size == 4, acknowledged.bytes.count == 4,
              abs(smcBytesToFloat(acknowledged.bytes, size: acknowledged.size) - rpm) <= 1 else {
            throw ThermalForgeError.writeFailed("\(targetKey) acknowledgement")
        }
    }

    /// Set all fans to maximum RPM
    public func setMax(cancellation: CancellationToken = CancellationToken()) throws {
        let count = try fanCount()
        guard count > 0 else { throw ThermalForgeError.unlockFailed("No controllable fans") }
        var maxima: [Float] = []
        for index in 0..<count {
            let limits = try verifiedFanLimits(index)
            try validate(rpm: limits.max, limits: limits)
            maxima.append(limits.max)
        }
        try unlockFans(Array(0..<count), cancellation: cancellation)
        for index in 0..<count {
            guard !cancellation.isCancelled else { throw ThermalForgeError.cancelled }
            try writeTarget(fan: index, rpm: maxima[index])
            log("Set fan \(index) to max (\(Int(maxima[index])) RPM)")
        }
    }

    /// Set a single fan to a specific RPM
    public func setSpeed(fan index: Int, rpm: Float, cancellation: CancellationToken = CancellationToken()) throws {
        guard index >= 0, index < (try fanCount()) else { throw ThermalForgeError.readFailed("fan index") }
        try validate(rpm: rpm, limits: verifiedFanLimits(index))

        try unlockFans([index], cancellation: cancellation)

        guard !cancellation.isCancelled else { throw ThermalForgeError.cancelled }
        try writeTarget(fan: index, rpm: rpm)
        log("Set fan \(index) to \(Int(rpm)) RPM")
    }

    /// Set all fans to a specific RPM
    public func setAllFans(rpm: Float, cancellation: CancellationToken = CancellationToken()) throws {
        let count = try fanCount()
        guard count > 0 else { throw ThermalForgeError.unlockFailed("No controllable fans") }

        for index in 0..<count {
            let limits = try verifiedFanLimits(index)
            try validate(rpm: rpm, limits: limits)
        }

        try unlockFans(Array(0..<count), cancellation: cancellation)

        for i in 0..<count {
            guard !cancellation.isCancelled else { throw ThermalForgeError.cancelled }
            try writeTarget(fan: i, rpm: rpm)
            log("Set fan \(i) to \(Int(rpm)) RPM")
        }
    }

    // MARK: - Reset

    /// Continue through every fan and Ftst even after partial failure. A stale
    /// target is cleared only after its fan is observed outside manual mode.
    public func restoreApple() -> RestorationResult {
        var errors: [String] = []
        var indices: [Int] = []
        do { indices = Array(0..<(try fanCount())) }
        catch { errors.append(String(describing: error)) }
        for index in indices {
            guard let key = modeKey(index) else {
                errors.append("Fan \(index) mode unreadable")
                continue
            }
            if !smc.writeKey(key, bytes: [0]) { errors.append("Failed restoring \(key)") }
        }
        // This is independent of fan enumeration and individual mode failures.
        let ftst = smc.keyAvailability(SMCFanKey.forceTest)
        switch ftst {
        case .present(size: 1):
            if !smc.writeKey(SMCFanKey.forceTest, bytes: [0]) { errors.append("Failed clearing Ftst") }
        case .absent: break
        default: errors.append("Ftst capability unreadable")
        }
        for index in indices {
            let mode = readMode(index)
            guard mode == "auto" || mode == "system" else {
                errors.append("Fan \(index) restoration unverified (\(mode))")
                continue
            }
            let key = SMCFanKey.key(SMCFanKey.target, fan: index)
            if !smc.writeKey(key, bytes: floatToSMCBytes(0)) { errors.append("Failed clearing \(key)") }
        }
        // Clearing targets is itself a firmware write. Verify final ownership
        // again afterwards rather than relying on the prerequisite read.
        for index in indices {
            let mode = readMode(index)
            if mode != "auto" && mode != "system" {
                errors.append("Fan \(index) final ownership unverified (\(mode))")
            }
        }
        if case .present = ftst {
            let result = smc.readKey(SMCFanKey.forceTest)
            if !result.success || result.size != 1 || result.bytes != [0] {
                errors.append("Ftst restoration unverified")
            }
        }
        return RestorationResult(verified: errors.isEmpty, errors: errors)
    }

    public func resetAuto() throws {
        let result = restoreApple()
        guard result.verified else { throw ThermalForgeError.restorationFailed(result.errors) }
        log("Verified Apple fan ownership")
    }

    // MARK: - Status

    /// Read current fan speeds and temperatures
    public func status() throws -> ThermalStatus {
        let count = try fanCount()
        var fans: [ThermalStatus.FanStatus] = []

        for i in 0..<count {
            let info = try fanInfo(i)
            fans.append(ThermalStatus.FanStatus(
                index: i,
                actualRPM: Int(info.actualRPM),
                targetRPM: Int(info.targetRPM),
                minRPM: Int(info.minRPM),
                maxRPM: Int(info.maxRPM),
                mode: info.mode
            ))
        }

        // Read every live sensor (the subset present on this machine). Labels
        // use the raw SMC key name — no assumptions about what a key means on
        // hardware we haven't verified.
        var temps: [String: Float] = [:]
        for liveKey in liveTemperatureKeys() {
            if let temp = readTemp(liveKey) {
                temps[liveKey.key] = temp
            }
        }

        return ThermalStatus(fans: fans, temperatures: temps)
    }

    // MARK: - Temperatures

    /// Which subsystem a temperature key reports — used to keep the hot control
    /// read down to just the sensors the controller and 95°C override consume.
    private enum TempGroup { case cpu, gpu, other }
    private struct LiveTempKey { let key: String; let isIoft: Bool; let group: TempGroup }
    private struct TempCandidate { let key: String; let isIoft: Bool; let group: TempGroup }

    /// All known thermal keys across M1–M5. Probed once to find the live subset.
    /// Grouping mirrors the prefixes the monitor uses: CPU = TC/Tp, GPU = TG/Tg.
    private static let tempCandidates: [TempCandidate] = {
        func flt(_ keys: [String], _ group: TempGroup) -> [TempCandidate] {
            keys.map { TempCandidate(key: $0, isIoft: false, group: group) }
        }
        var c: [TempCandidate] = []
        // CPU — aggregate (M5 Max) + per-core (Tp, M1–M5)
        c += flt(["TCDX", "TCHP", "TCMb",
                  "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
                  "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
                  "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b"], .cpu)
        // GPU — flt (M1–M4)
        c += flt(["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j"], .gpu)
        // Memory / power / SSD / ambient / proximity / battery — display only
        c += flt(["Tm02", "Tm06", "Tm08", "Tm09", "TRDX", "TMVR", "TPDX",
                  "TH0x", "TH0A", "TH0B", "TAOL", "TA0P", "TS0P", "TB0T"], .other)
        // GPU — ioft 16.16 fixed-point, 8 bytes (M5 Max)
        c += ["TG0B", "TG0H", "TG0V"].map { TempCandidate(key: $0, isIoft: true, group: .gpu) }
        return c
    }()

    /// The temperature keys actually present on this machine. Probed once (a
    /// non-empty result is cached); absent keys are never read again, so the
    /// hot path stops paying IOKit calls for other generations' sensors.
    private func liveTemperatureKeys() -> [LiveTempKey] {
        if let cached = liveTempKeys, !cached.isEmpty { return cached }
        var live: [LiveTempKey] = []
        for cand in Self.tempCandidates {
            let result = smc.readKey(cand.key)
            let present = cand.isIoft ? (result.success && result.size == 8)
                                      : (result.success && result.size == 4)
            if present {
                live.append(LiveTempKey(key: cand.key, isIoft: cand.isIoft, group: cand.group))
            }
        }
        if !live.isEmpty { liveTempKeys = live }
        return live
    }

    private func readTemp(_ liveKey: LiveTempKey) -> Float? {
        let result = smc.readKey(liveKey.key)
        guard result.success else { return nil }
        let temp = liveKey.isIoft
            ? ioftBytesToFloat(result.bytes)
            : smcBytesToFloat(result.bytes, size: result.size)
        guard temp > 0 && temp < 150 else { return nil }
        return (temp * 10).rounded() / 10
    }

    /// Cheap read for the control loop: peak CPU and GPU temperature only.
    /// Skips the ~14 display-only sensors (RAM/SSD/ambient/…) and all fan reads.
    /// Returns nil when no CPU/GPU sensor could be read (treat as a failed tick).
    public func controlTemps() -> (cpu: Float, gpu: Float)? {
        let keys = liveTemperatureKeys()
        guard !keys.isEmpty else { return nil }
        var cpu: Float = 0
        var gpu: Float = 0
        var read = false
        for liveKey in keys where liveKey.group != .other {
            guard let temp = readTemp(liveKey) else { continue }
            read = true
            if liveKey.group == .cpu { cpu = max(cpu, temp) } else { gpu = max(gpu, temp) }
        }
        return read ? (cpu, gpu) : nil
    }

    // MARK: - Discover

    /// Enumerate SMC keys. Optional prefix filter skips reads for non-matching keys.
    public func discover(prefix: String? = nil) -> [DiscoveredKey] {
        let count = smc.getKeyCount()
        var keys: [DiscoveredKey] = []

        for i: UInt32 in 0..<count {
            guard let keyName = smc.getKeyAtIndex(i) else { continue }

            // Skip non-matching keys early
            if let prefix = prefix, !keyName.hasPrefix(prefix) { continue }

            let info = smc.getKeyInfo(keyName)
            let result = smc.readKey(keyName)

            keys.append(DiscoveredKey(
                key: keyName,
                size: info?.size ?? 0,
                type: info?.type ?? "????",
                bytes: result.success ? result.bytes : []
            ))
        }

        return keys
    }

    // MARK: - Hardware Info

    /// Returns detected hardware capabilities
    public var hardwareInfo: String {
        let capability: String
        switch smc.keyAvailability(SMCFanKey.forceTest) {
        case .present: capability = "present"
        case .absent: capability = "absent (direct mode)"
        case .unknown: capability = "unknown"
        }
        return "Ftst unlock: \(capability), Mode key: \(modeKey(0) ?? "unknown")"
    }

    // MARK: - Private Helpers

    private func readFanFloat(_ fan: Int, template: String) -> Float {
        readFanFloatValue(fan, template: template) ?? 0
    }

    private func readFanFloatValue(_ fan: Int, template: String) -> Float? {
        let key = SMCFanKey.key(template, fan: fan)
        let result = smc.readKey(key)
        guard result.success, result.size == 4, result.bytes.count == 4 else { return nil }
        let value = smcBytesToFloat(result.bytes, size: result.size)
        return value.isFinite && value >= 0 ? value : nil
    }

    private func log(_ message: String) {
        TFLogger.shared.fan(message)
    }
}

// Only the backend coordinator calls this actuator during normal operation.
// Recovery uses restoreApple only after fencing the backend process.
extension FanControl: BackendActuating {
    public func apply(_ command: FanCommand, cancellation: CancellationToken) throws {
        guard !cancellation.isCancelled else { throw ThermalForgeError.cancelled }
        switch command {
        case .setMax: try setMax(cancellation: cancellation)
        case .setRPM(let rpm): try setAllFans(rpm: rpm, cancellation: cancellation)
        case .resetAuto: try resetAuto()
        }
    }
}
