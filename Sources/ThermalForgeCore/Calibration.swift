//
//  Calibration.swift
//  ThermalForge
//
//  Machine-specific thermal calibration data for the Smart profile.
//

import Foundation
import Metal
import AppKit
import CoreGraphics
import Darwin

// MARK: - Data Model

public struct CalibrationData: Codable {
    public let machine: String
    public let fans: Int
    public let maxRPM: Int
    public let minRPM: Int
    public let calibratedAt: String
    public let mode: String?
    /// Stress source and workload selected for the equilibrium sweep. Optional
    /// for backward compatibility with older calibration files.
    public let stressType: String?
    public let workloadIntensity: Float?
    public let ambientTemperature: Float?
    public let lidClosed: Bool  // true = clamshell mode, false = lid open
    public let measurements: [Measurement]

    public init(
        machine: String,
        fans: Int,
        maxRPM: Int,
        minRPM: Int,
        calibratedAt: String,
        mode: String? = nil,
        stressType: String? = nil,
        workloadIntensity: Float? = nil,
        ambientTemperature: Float? = nil,
        lidClosed: Bool = false,
        measurements: [Measurement]
    ) {
        self.machine = machine
        self.fans = fans
        self.maxRPM = maxRPM
        self.minRPM = minRPM
        self.calibratedAt = calibratedAt
        self.mode = mode
        self.stressType = stressType
        self.workloadIntensity = workloadIntensity
        self.ambientTemperature = ambientTemperature
        self.lidClosed = lidClosed
        self.measurements = measurements
    }

    /// Ranking for downgrade prevention: quick=1, standard=2, optimized=3
    public var modeRank: Int {
        switch mode {
        case "quick": return 1
        case "standard": return 2
        case "optimized": return 3
        default: return 0 // legacy data without mode field
        }
    }

    public struct Measurement: Codable {
        /// Target temperature this measurement was taken at
        public let targetTemp: Float
        /// Fan speed (0.0–1.0 of max RPM) that held temp at targetTemp
        public let holdingRPMPercent: Float
        /// How long (seconds) it took to find the holding speed
        public let settleTime: Float?

        public init(targetTemp: Float, holdingRPMPercent: Float, settleTime: Float? = nil) {
            self.targetTemp = targetTemp
            self.holdingRPMPercent = holdingRPMPercent
            self.settleTime = settleTime
        }
    }

    /// Look up the fan speed needed to hold a given temperature.
    /// Interpolates between measured points.
    public func fanPercentForTemp(_ temp: Float) -> Float? {
        guard measurements.count >= 2 else { return nil }
        let sorted = measurements.sorted { $0.targetTemp < $1.targetTemp }

        // Below lowest measured temp — use lowest fan speed
        if temp <= sorted.first!.targetTemp { return sorted.first!.holdingRPMPercent }
        // Above highest measured temp — use highest fan speed
        if temp >= sorted.last!.targetTemp { return sorted.last!.holdingRPMPercent }

        // Interpolate between bracketing measurements
        for i in 0..<(sorted.count - 1) {
            let low = sorted[i]
            let high = sorted[i + 1]
            if temp >= low.targetTemp && temp <= high.targetTemp {
                let t = (temp - low.targetTemp) / (high.targetTemp - low.targetTemp)
                return low.holdingRPMPercent + t * (high.holdingRPMPercent - low.holdingRPMPercent)
            }
        }
        return sorted.last!.holdingRPMPercent
    }

    /// Validate that calibration data is physically consistent.
    /// Returns nil if valid, or a description of what's wrong.
    public var validationError: String? {
        guard !measurements.isEmpty else {
            return "No measurements"
        }

        for m in measurements {
            // Target temp should be in sane range
            if m.targetTemp < 40 || m.targetTemp > 100 {
                return "Target temp \(m.targetTemp)°C is out of range (40-100°C)"
            }
            // Holding RPM should be 0-1
            if m.holdingRPMPercent < 0 || m.holdingRPMPercent > 1 {
                return "Holding RPM \(m.holdingRPMPercent) at \(Int(m.targetTemp))°C is out of range (0-1)"
            }
        }

        // Higher temps should need higher fan speeds
        let sorted = measurements.sorted { $0.targetTemp < $1.targetTemp }
        for i in 0..<(sorted.count - 1) {
            if sorted[i + 1].holdingRPMPercent < sorted[i].holdingRPMPercent - 0.05 {
                return "Fan speed decreases from \(Int(sorted[i].targetTemp))°C to \(Int(sorted[i + 1].targetTemp))°C — data inconsistent"
            }
        }

        // An all-maximum curve is produced when the calibration workload never
        // heats the machine into the control range. It is safe but contains no
        // useful fan-response information, so Smart must fall back instead.
        if measurements.allSatisfy({ $0.holdingRPMPercent >= 0.999 }) {
            return "All calibration points require maximum fan speed — temperature coverage was insufficient"
        }

        return nil
    }

    public var isValid: Bool { validationError == nil }
}

// MARK: - Lid State Detection

/// Detect whether the Mac is in clamshell (lid closed) mode.
///
/// In clamshell mode, the built-in display is off and at least one external
/// display is active. If no external display is present, the Mac sleeps when
/// the lid is closed, so we don't need to worry about that case for fan control.
///
/// Detection: In clamshell mode, the built-in display does NOT appear in
/// `NSScreen.screens`. So if there are screens but none is built-in → clamshell.
public func isClamshellMode() -> Bool {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return false }

    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
    let hasBuiltIn = screens.contains { screen in
        guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    // If there are active screens but the built-in display is not among them,
    // the lid must be closed (clamshell mode with external display).
    return !hasBuiltIn
}

// MARK: - Persistence

extension CalibrationData {
    /// Legacy file path (pre-lid-state support). Kept for backward compatibility.
    public static var legacyFilePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/calibration.json")
    }

    /// Lid-state-specific calibration file path.
    /// Returns `~/Library/Application Support/ThermalForge/calibration_lid_open.json`
    /// or `calibration_lid_closed.json` depending on `lidClosed`.
    public static var filePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/calibration.json")
    }

    /// File path for a given lid state.
    public static func filePath(forLidClosed lidClosed: Bool) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/")
            .appendingPathComponent("calibration_\(lidClosed ? "lid_closed" : "lid_open").json")
    }

    /// Save calibration and return every path written.
    @discardableResult
    public func save() throws -> [URL] {
        let path = Self.filePath(forLidClosed: lidClosed)
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: path)

        // If running as root (daemon/CLI), also copy to the console user's
        // home directory so the app (running as the user) can find it.
        var savedPaths = [path]
        if geteuid() == 0,
           let userPath = try copyToConsoleUser(data: data, lidClosed: lidClosed)
        {
            savedPaths.append(userPath)
        }
        return savedPaths
    }

    /// Copy calibration JSON to the console user's home directory.
    /// When calibration runs as root (via sudo or the daemon), the app
    /// (running as the logged-in user) can't read root's home directory.
    private func copyToConsoleUser(data: Data, lidClosed: Bool) throws -> URL? {
        // Get console user UID from /dev/console
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0 else { return nil }

        // Get home directory from passwd
        guard let pw = getpwuid(st.st_uid), let home = String(validatingUTF8: pw.pointee.pw_dir) else { return nil }

        let userPath = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/ThermalForge/")
            .appendingPathComponent("calibration_\(lidClosed ? "lid_closed" : "lid_open").json")
        let userDir = userPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try data.write(to: userPath)
        // Files created by a sudo calibration otherwise remain root-owned in
        // the user's config directory. Give both the file and any newly-created
        // directory back to the active console user.
        _ = chown(userDir.path, st.st_uid, pw.pointee.pw_gid)
        _ = chown(userPath.path, st.st_uid, pw.pointee.pw_gid)
        _ = chmod(userPath.path, 0o644)
        TFLogger.shared.info("Copied calibration to console user: \(userPath.path)")
        return userPath
    }

    /// Load calibration data matching the current lid state.
    public static func load() -> CalibrationData? {
        load(forLidClosed: isClamshellMode())
    }

    /// Load calibration data for a specific lid state.
    /// A missing state-specific file means that state is uncalibrated. Legacy
    /// data is deliberately not substituted because it cannot reliably identify
    /// the lid state in which it was recorded.
    public static func load(forLidClosed lidClosed: Bool) -> CalibrationData? {
        let specificPath = Self.filePath(forLidClosed: lidClosed)
        return load(forLidClosed: lidClosed, from: specificPath)
    }

    /// Path-injectable loader used by tests and by the state-specific loader.
    static func load(forLidClosed lidClosed: Bool, from specificPath: URL) -> CalibrationData? {
        guard let calibration = loadFromFile(specificPath) else { return nil }
        guard calibration.lidClosed == lidClosed else {
            TFLogger.shared.error("Calibration file lid state does not match its filename — ignoring")
            return nil
        }
        return calibration
    }

    /// Check if any calibration data exists (lid-state-specific or legacy).
    public static var exists: Bool {
        FileManager.default.fileExists(atPath: Self.filePath(forLidClosed: false).path)
        || FileManager.default.fileExists(atPath: Self.filePath(forLidClosed: true).path)
        || FileManager.default.fileExists(atPath: Self.legacyFilePath.path)
    }

    /// Decode and validate calibration data from a file.
    static func loadFromFile(_ url: URL) -> CalibrationData? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        guard let data = try? Data(contentsOf: url) else {
            TFLogger.shared.error("Calibration file exists but couldn't be read — deleting")
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        guard let calibration = try? JSONDecoder().decode(CalibrationData.self, from: data) else {
            TFLogger.shared.error("Calibration file is corrupted (JSON decode failed) — deleting")
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return calibration
    }
}

// MARK: - Calibration Mode

/// Calibration modes based on thermal engineering research.
///
/// Apple Silicon MacBooks reach ~95% of thermal steady state in 4.5-6 minutes
/// under sustained load (thermal time constant ~90-120s, measured across M1-M5
/// by Notebookcheck, Max Tech). Mac Studio takes 5-7 minutes due to 2-3x
/// thermal mass. Cooling time constant is ~60-90s at max fan, 3-5 min at idle.
///
/// Sources:
/// - Notebookcheck MacBook Pro M1 Max, M2 Max, M3 Max, M4 Max stress tests
/// - Max Tech sustained performance testing methodology
/// - Thermal time constant = thermal mass × thermal resistance
///   ~20-50 J/K × 0.3-0.8 K/W = 60-180s for laptop heatsink assemblies
/// - 3 time constants = 95% of steady state, 5 time constants = 99.3%
public enum CalibrationMode: String, CaseIterable {
    /// Fastest convergence tolerances; still requires 60 seconds of evidence.
    case quick

    /// Moderate convergence tolerances and a longer timeout.
    case standard

    /// Tightest convergence tolerances and the longest timeout.
    case optimized

    public var description: String {
        switch self {
        case .quick: return "Quick (fast convergence)"
        case .standard: return "Standard (balanced convergence)"
        case .optimized: return "Optimized (tight convergence)"
        }
    }

    /// Ranking for downgrade prevention
    public var rank: Int {
        switch self {
        case .quick: return 1
        case .standard: return 2
        case .optimized: return 3
        }
    }

    /// All modes begin evaluating after 60 seconds. Accuracy comes from the
    /// convergence tolerances below rather than an arbitrary longer minimum.
    public var stabilizationWindowSize: Int {
        30 // 60 seconds at one reading every 2 seconds
    }

    /// Maximum accepted temperature trend over the stabilization window.
    var maximumSlopePerSecond: Float {
        switch self {
        case .quick: return 0.008
        case .standard: return 0.005
        case .optimized: return 0.003
        }
    }

    /// Maximum difference between the means of the first and second half.
    var maximumHalfMeanDelta: Float {
        switch self {
        case .quick: return 0.9
        case .standard: return 0.6
        case .optimized: return 0.4
        }
    }

    /// Maximum 95% confidence radius of the detrended mean.
    var maximumConfidenceRadius: Float {
        switch self {
        case .quick: return 0.90
        case .standard: return 0.65
        case .optimized: return 0.45
        }
    }

    func acceptsStability(_ metrics: CalibrationStabilityMetrics) -> Bool {
        abs(metrics.slopePerSecond) <= maximumSlopePerSecond
            && metrics.halfMeanDelta <= maximumHalfMeanDelta
            && metrics.confidenceRadius95 <= maximumConfidenceRadius
    }

    /// Maximum seconds to wait at each fan level for stabilization
    public var maxWaitPerLevel: Int {
        switch self {
        case .quick: return 150     // 2.5 minutes
        case .standard: return 240  // 4 minutes
        case .optimized: return 360 // 6 minutes
        }
    }

}

/// Errors that can occur during calibration
public enum CalibrationError: LocalizedError {
    case insufficientData(reason: String)

    public var errorDescription: String? {
        switch self {
        case .insufficientData(let reason):
            return reason
        }
    }
}

/// What to stress during calibration
public enum CalibrationStressType: String, CaseIterable {
    /// CPU + GPU simultaneously — real-world worst case (default)
    case combined
    /// CPU only — isolates CPU thermal contribution
    case cpu
    /// GPU only — isolates GPU thermal contribution (Metal compute)
    case gpu

    public var description: String {
        switch self {
        case .combined: return "CPU + GPU (recommended)"
        case .cpu: return "CPU only"
        case .gpu: return "GPU only"
        }
    }
}

struct CalibrationTemperatureSample: Equatable {
    let selected: Float
    let cpu: Float
    let gpu: Float
}

struct CalibrationStabilityMetrics: Equatable {
    let mean: Float
    let slopePerSecond: Float
    let rawStandardDeviation: Float
    let residualStandardDeviation: Float
    let halfMeanDelta: Float
    let confidenceRadius95: Float
}

struct CalibrationCPUStressPlan: Equatable {
    let fullThreads: Int
    let fractionalDutyCycle: Float
}

// MARK: - Calibration Runner

public final class CalibrationRunner {
    private let fanControl: FanControl
    private let mode: CalibrationMode
    private let stressType: CalibrationStressType
    private let workloadIntensityOverride: Float?
    private var stressThreads: [Thread] = []
    private let stressLock = NSLock()
    private var _stressRunning = false
    private var stressRunning: Bool {
        get { stressLock.lock(); defer { stressLock.unlock() }; return _stressRunning }
        set { stressLock.lock(); _stressRunning = newValue; stressLock.unlock() }
    }
    private let isoFormatter = ISO8601DateFormatter()

    public var onProgress: ((String) -> Void)?

    /// Path to the CSV log generated during calibration
    public private(set) var logPath: URL?

    // CSV log handle — written to in real time during calibration
    private var csvHandle: FileHandle?

    public init(
        fanControl: FanControl,
        mode: CalibrationMode = .standard,
        stressType: CalibrationStressType = .combined,
        workloadIntensity: Float? = nil
    ) {
        self.fanControl = fanControl
        self.mode = mode
        self.stressType = stressType
        self.workloadIntensityOverride = workloadIntensity
    }

    /// Check if running this mode would downgrade existing calibration
    public static func wouldDowngrade(mode: CalibrationMode) -> Bool {
        guard let existing = CalibrationData.load() else { return false }
        return mode.rank < existing.modeRank
    }

    /// Performance ceiling — stop increasing load if temp reaches this
    ///
    /// Phase 1 (intensity finding) targets an *equilibrium temperature* rather
    /// than a fixed heating rate. This works for both high and low ambient because
    /// it finds the maximum stress that still produces a stable equilibrium below
    /// `targetEquilTemp` at 100% fans — naturally adapting to the environment.
    static let targetEquilTemp: Float = 65.0 // target equilibrium at 100% fans during Phase 1
    static let phase1MaxIterations: Int = 8
    static let phase1InitialIntensity: Float = 0.05
    static let phase1CheckDuration: TimeInterval = 120 // seconds to observe each candidate
    static let phase1MinimumDecisionDuration: TimeInterval = 60
    static let phase1IntensityLow: Float = 0.001
    static let phase1IntensityHigh: Float = 0.50
    static let phase1UsefulEquilibriumMinimum: Float = 59.0
    /// Apple Silicon MacBook cooling time constant at max fans (60-90s per research).
    /// Used to estimate equilibrium temperature from finite observations.
    /// After time t, system reaches (1 - exp(-t/τ)) of equilibrium delta.
    static let phase1TimeConstant: TimeInterval = 90 // conservative upper bound

    /// Result of a rapid intensity safety check.
    private struct IntensityCheckResult {
        let maxTemp: Float           // highest observed temperature
        let estimatedEquilTemp: Float // estimated equilibrium from observation + time constant
        let slope: Float             // °C/s over last third of observation
        let hitCeiling: Bool
        let duration: TimeInterval

        var isSafe: Bool {
            !hitCeiling && estimatedEquilTemp < CalibrationRunner.targetEquilTemp
        }

        var isUseful: Bool {
            isSafe && estimatedEquilTemp >= CalibrationRunner.phase1UsefulEquilibriumMinimum
        }
    }

    private struct IntensitySelection {
        let intensity: Float
        /// True when the final trial was a hotter rejected probe rather than
        /// the selected workload, so its residual heat must not contaminate the
        /// first fan-level measurement.
        let requiresCooldown: Bool
    }

    /// Find a stress intensity that produces a useful, safe equilibrium at
    /// 100% fans.
    ///
    /// Start at 5%, move geometrically toward a safe bracket, then refine only
    /// when necessary. This avoids always running both the 0.1% and 50% probes.
    private func findSafeSweepIntensity(maxRPM: Float) -> IntensitySelection? {
        log("Finding max safe stress intensity (equilibrium < \(Int(Self.targetEquilTemp))°C at 100% fans)...")

        // Phase 0 immediately before this call established the baseline. Do
        // not repeat the same up-to-two-minute cooldown here.
        let baselineTemp = calibrationTemperature()?.selected ?? 0
        guard baselineTemp > 0 else {
            log("  Can't read temperature")
            return nil
        }
        log("  Baseline: \(String(format: "%.1f", baselineTemp))°C")

        // Set fans to 100% and keep them there for all checks —
        // this is the worst-case cooling scenario and provides fastest cooldown
        try? fanControl.setAllFans(rpm: maxRPM)

        var probe = Self.phase1InitialIntensity
        var safeIntensity: Float?
        var safeEquilibrium: Float?
        var unsafeIntensity: Float?
        var lastTestedIntensity: Float?

        for attempt in 1...Self.phase1MaxIterations {
            let result = checkIntensity(at: probe, baselineTemp: baselineTemp)
            lastTestedIntensity = probe
            logIntensityResult(result, intensity: probe, attempt: attempt)

            if result.isSafe {
                safeIntensity = probe
                safeEquilibrium = result.estimatedEquilTemp

                // Stop only when the safe probe is also hot enough to produce
                // useful coverage. A narrow safe/unsafe bracket alone is not
                // sufficient: the safe edge can still be badly underpowered.
                if result.isUseful {
                    break
                }

                if let high = unsafeIntensity {
                    probe = sqrt(probe * high)
                } else if probe >= Self.phase1IntensityHigh {
                    break
                } else {
                    probe = min(probe * 2, Self.phase1IntensityHigh)
                }
            } else {
                unsafeIntensity = probe
                if let low = safeIntensity {
                    probe = sqrt(low * probe)
                } else if probe <= Self.phase1IntensityLow {
                    return nil
                } else {
                    probe = max(probe / 2, Self.phase1IntensityLow)
                }
            }
        }

        guard let safeIntensity else { return nil }
        let requiresCooldown = lastTestedIntensity.map { abs($0 - safeIntensity) > 0.000_001 } ?? false
        if let safeEquilibrium, safeEquilibrium < Self.phase1UsefulEquilibriumMinimum {
            log("  No safe probe reached 59–65°C; sweeping with the strongest safe candidate and validating coverage")
        }
        log("  Selected safe intensity: \(String(format: "%.5f", safeIntensity))")
        return IntensitySelection(intensity: safeIntensity, requiresCooldown: requiresCooldown)
    }

    private func logIntensityResult(_ result: IntensityCheckResult, intensity: Float, attempt: Int) {
        let verdict = result.isUseful
            ? "✓ useful and safe"
            : result.isSafe ? "△ safe but underpowered" : "✗ too hot"
        log("  Step \(attempt): intensity \(String(format: "%.5f", intensity)) → " +
            "max \(String(format: "%.1f", result.maxTemp))°C, " +
            "est. equil \(String(format: "%.1f", result.estimatedEquilTemp))°C, " +
            "slope \(String(format: "%+.3f", result.slope))°C/s, " +
            "\(verdict) (\(Int(result.duration))s)")
    }

    /// Equilibrium check: observe temperature at a given intensity and 100% fans.
    /// Estimates the true equilibrium temperature using the thermal time constant.
    ///
    /// The thermal time constant for Apple Silicon MacBooks at max fans is 60-90s.
    /// After observing for time t, the system has reached (1 - exp(-t/τ)) of its
    /// equilibrium delta. We use this to estimate the actual equilibrium temperature
    /// from finite observations, avoiding the need to wait for full stabilization.
    ///
    /// Formula: T_eq ≈ T_baseline + (T_final - T_baseline) / (1 - exp(-t/τ))
    /// This assumes exponential approach to equilibrium (Newton's law of cooling).
    private func checkIntensity(at intensity: Float, baselineTemp: Float) -> IntensityCheckResult {
        // Cooldown to baseline (fans already at 100% from caller)
        waitForTempReturn(to: baselineTemp, tolerance: 3.0)

        let actualStartTemp = calibrationTemperature()?.selected ?? 0

        log("  → intensity \(String(format: "%.5f", intensity)) (\(stressType.description))...")

        startStress(intensity: intensity)

        // Observe, sampling every 2s
        var readings: [(time: Double, temp: Float)] = []
        let startUptime = DispatchTime.now().uptimeNanoseconds

        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startUptime) / 1_000_000_000.0
            let temp = calibrationTemperature()?.selected ?? 0
            readings.append((elapsed, temp))

            // Early exit: ceiling hit
            if temp >= Self.ceilingTemp {
                stopStress()
                return IntensityCheckResult(
                    maxTemp: temp,
                    estimatedEquilTemp: temp,
                    slope: .infinity,
                    hitCeiling: true,
                    duration: elapsed
                )
            }

            let result = intensityResult(readings: readings, actualStartTemp: actualStartTemp)
            if elapsed >= Self.phase1MinimumDecisionDuration {
                let clearlyUnsafe = result.estimatedEquilTemp >= Self.targetEquilTemp + 5
                let clearlySafe = result.estimatedEquilTemp <= Self.targetEquilTemp - 3
                    && abs(result.slope) <= 0.01
                if clearlyUnsafe || clearlySafe {
                    stopStress()
                    return result
                }
            }

            if elapsed >= Self.phase1CheckDuration {
                stopStress()
                return result
            }

            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func intensityResult(
        readings: [(time: Double, temp: Float)],
        actualStartTemp: Float
    ) -> IntensityCheckResult {
        // Compute slope over last third of readings
        let tailStart = readings.count * 2 / 3
        let tail = Array(readings.suffix(from: tailStart))
        let slope = computeSlope(readings: tail)

        // Estimate equilibrium temperature using thermal time constant.
        // The system approaches equilibrium exponentially: T(t) = T_eq - (T_eq - T_0) * exp(-t/τ)
        // Rearranging: T_eq ≈ T_0 + (T(t) - T_0) / (1 - exp(-t/τ))
        // Use the LAST THIRD of data for the estimate (closest to equilibrium).
        // Average the temps in the tail and use the midpoint time of the tail.
        let tailTempAvg = tail.map { Double($0.temp) }.reduce(0, +) / Double(tail.count)
        let tailTimeMid = (Double(tail.first!.time) + Double(tail.last!.time)) / 2.0
        let tau = Double(Self.phase1TimeConstant)
        let fractionReached = 1.0 - exp(-tailTimeMid / tau)

        // Estimated equilibrium: how far will the temp go from baseline?
        let estimatedEquilTemp: Float
        if fractionReached > 0.1 {
            let riseObserved = tailTempAvg - Double(actualStartTemp)
            let riseEstimated = riseObserved / fractionReached
            estimatedEquilTemp = Float(Double(actualStartTemp) + riseEstimated)
        } else {
            // Not enough time elapsed — use max observed as conservative estimate
            estimatedEquilTemp = readings.map { $0.temp }.max()!
        }

        return IntensityCheckResult(
            maxTemp: readings.map { $0.temp }.max()!,
            estimatedEquilTemp: estimatedEquilTemp,
            slope: slope,
            hitCeiling: false,
            duration: readings.last?.time ?? 0
        )
    }

    /// Compute linear regression slope (°C/s) from time-temperature readings.
    private func computeSlope(readings: [(time: Double, temp: Float)]) -> Float {
        guard readings.count >= 4 else { return 0 }
        let n = Double(readings.count)
        let times = readings.map { $0.time }
        let temps = readings.map { Double($0.temp) }
        let sumX = times.reduce(0, +)
        let sumY = temps.reduce(0, +)
        let sumXY = zip(times, temps).map { $0 * $1 }.reduce(0, +)
        let sumX2 = times.map { $0 * $0 }.reduce(0, +)
        let denom = n * sumX2 - sumX * sumX
        guard denom > 0 else { return 0 }
        let numer = n * sumXY - sumX * sumY
        return Float(numer / denom)
    }

    /// Wait until temperature returns close to a target baseline.
    /// Verifies stability (3 consecutive samples within 0.5°C) before returning.
    /// Caps at 120s — cooling time constant is 60-90s (one τ ≈ 63% of delta).
    private func waitForTempReturn(to target: Float, tolerance: Float) {
        let maxWait: TimeInterval = 120
        let deadline = Date().addingTimeInterval(maxWait)

        while Date() < deadline {
            let temp = calibrationTemperature()?.selected ?? 0
            guard temp > 0 else { return }

            // Starting cooler than the original baseline is safe and useful;
            // do not wait for a max-fan cooldown to warm back up to the target.
            if temp <= target + tolerance {
                // Verify stability: 3 quick samples within 0.5°C of each other
                var stable = true
                for _ in 0..<3 {
                    let t = calibrationTemperature()?.selected ?? 0
                    if abs(t - temp) > 0.5 {
                        stable = false
                        break
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
                if stable {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        let finalTemp = calibrationTemperature()?.selected ?? 0
        log("  Cooldown timeout: \(String(format: "%.1f", finalTemp))°C vs target \(String(format: "%.1f", target))°C — proceeding anyway")
    }

    /// Select the sensor family that matches the generated workload. Combined
    /// calibration follows the hotter CPU/GPU family, matching Smart's input.
    private func calibrationTemperature() -> CalibrationTemperatureSample? {
        guard let status = try? fanControl.status() else { return nil }
        return Self.calibrationTemperature(from: status.temperatures, stressType: stressType)
    }

    static func calibrationTemperature(
        from temperatures: [String: Float],
        stressType: CalibrationStressType
    ) -> CalibrationTemperatureSample? {
        let cpu = temperatures
            .filter { key, _ in key.hasPrefix("TC") || key.hasPrefix("Tp") }
            .values.max() ?? 0
        let gpu = temperatures
            .filter { key, _ in key.hasPrefix("TG") || key.hasPrefix("Tg") }
            .values.max() ?? 0

        let selected: Float
        switch stressType {
        case .cpu:
            selected = cpu
        case .gpu:
            selected = gpu > 0 ? gpu : cpu
        case .combined:
            selected = max(cpu, gpu)
        }
        guard selected > 0 else { return nil }
        return CalibrationTemperatureSample(selected: selected, cpu: cpu, gpu: gpu)
    }

    /// Cleanup: always stop stress, reset fans, close CSV on any exit path
    private func cleanup() {
        stopStress()
        try? fanControl.resetAuto()
        csvHandle?.closeFile()
        csvHandle = nil
    }

    /// Fan levels to test (high to low). 5 levels cover the useful cooling range.
    private static func fanLevels(minPct: Float) -> [Float] {
        [1.0, 0.80, 0.60, 0.45, minPct]
    }

    /// Temperature targets for the control curve output
    private static let controlCurveTemps: [Float] = [60, 65, 70, 75, 80, 85]

    /// Ceiling: record data and skip remaining lower fan levels
    private static let ceilingTemp: Float = 84.0

    /// Safety: abort and max fans
    private static let safetyTemp: Float = 90.0

    /// Run full calibration. Blocks until complete.
    public func run() throws -> CalibrationData {
        defer { cleanup() }

        let fanCount = try fanControl.fanCount()
        let fan0 = try fanControl.fanInfo(0)
        let maxRPM = fan0.maxRPM > 0 ? fan0.maxRPM : 7826
        let minRPM = fan0.minRPM > 0 ? fan0.minRPM : 2317
        let minPct = minRPM / maxRPM

        // Machine info
        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: Swift.max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machine = String(cString: modelBuf)

        // Detect lid state once — used for logging and file naming
        let clamshell = isClamshellMode()

        let levels = Self.fanLevels(minPct: minPct)
        log("Mode: \(mode.description)")
        log("Stress: \(stressType.description)")
        log("Approach: fan-first with stabilization (set fan speed, wait for equilibrium)")
        log("Fan levels: \(levels.map { "\(Int($0 * 100))%" }.joined(separator: " → "))")
        log("Stabilization evidence: \(mode.stabilizationWindowSize * 2)s minimum, max wait: \(mode.maxWaitPerLevel)s/level")

        // Record ambient temperature
        var ambientTemp: Float = 0
        if let status = try? fanControl.status() {
            ambientTemp = status.temperatures.filter { k, _ in k.hasPrefix("TA") }.values.first ?? 0
        }
        if ambientTemp > 0 {
            log("Ambient: \(String(format: "%.1f", ambientTemp))°C \(clamshell ? "(lid closed / clamshell)" : "(lid open)")")
        } else if clamshell {
            log("Mode: lid closed / clamshell")
        }

        // Phase 0: Cooldown to baseline
        log("Phase 0: Cooling to baseline...")
        waitForCooldown(below: 45)

        let baselineIntensity: Float
        if let workloadIntensityOverride {
            baselineIntensity = workloadIntensityOverride
            log("Phase 1: Using supplied/reused safe workload intensity \(String(format: "%.5f", baselineIntensity))")
            try fanControl.setMax()
        } else {
            // Phase 1: Find max safe stress intensity
            log("Phase 1: Finding max safe stress intensity...")
            guard let intensitySelection = findSafeSweepIntensity(maxRPM: Float(maxRPM)) else {
                // Even minimum stress is too hot for this environment
                if ambientTemp > 0 {
                    log("At \(String(format: "%.1f", ambientTemp))°C ambient, even minimum stress at 100% fans")
                    log("exceeded safe temperature. Calibration cannot proceed.")
                } else {
                    log("Even minimum stress at 100% fans exceeded safe temperature.")
                }
                log("")
                log("Options:")
                log("  1. Wait for ambient temperature to drop below 30°C and retry.")
                log("  2. Run in a cooler environment (air-conditioned room).")
                log("  3. Use the default Smart profile (built-in conservative curve).")
                throw CalibrationError.insufficientData(
                    reason: "Even minimum stress at 100% fans exceeded safe temperature. " +
                            "Ambient too high for calibration. Wait for cooler conditions or use default Smart profile."
                )
            }
            baselineIntensity = intensitySelection.intensity
            log("Baseline intensity: \(String(format: "%.5f", baselineIntensity))")

            if intensitySelection.requiresCooldown {
                log("Cooling after rejected hotter probe before the sweep...")
                waitForCooldown(below: 45)
            } else {
                // Preserve the useful final safe-probe state instead of resetting
                // to Apple auto and paying for an unnecessary cooldown/reheat.
                try fanControl.setMax()
            }
        }

        // Set up CSV log
        let logDir = CalibrationData.filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let timestamp = isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let csvURL = logDir.appendingPathComponent("calibration_\(timestamp).csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        csvHandle = try FileHandle(forWritingTo: csvURL)
        logPath = csvURL
        csvWrite("timestamp,fan_pct,selected_temp,cpu_temp,gpu_temp,fan0_rpm,fan1_rpm,phase")

        // Phase 2: Fan-level stabilization sweep (high to low)
        log("Phase 2: Starting fan-level sweep (intensity: \(String(format: "%.5f", baselineIntensity)))...")
        startStress(intensity: baselineIntensity)

        var rawData: [(fanPct: Float, equilTemp: Float)] = []
        var abortLowerLevels = false
        var unstableFanLevels: [Int] = []

        for (_, fanPct) in levels.enumerated() {
            guard !abortLowerLevels else { break }

            let targetRPM = Swift.max(maxRPM * fanPct, minRPM)
            log("[\(Int(fanPct * 100))%] Setting fans to \(Int(targetRPM)) RPM — waiting for stabilization...")

            try fanControl.setAllFans(rpm: targetRPM)

            var readings: [Float] = []
            let levelStart = DispatchTime.now().uptimeNanoseconds
            let deadline = Date().addingTimeInterval(TimeInterval(mode.maxWaitPerLevel))
            var stabilized = false

            while Date() < deadline {
                let elapsedSeconds = Int(
                    (DispatchTime.now().uptimeNanoseconds - levelStart) / 1_000_000_000
                )
                guard let temperature = calibrationTemperature() else {
                    Thread.sleep(forTimeInterval: 2)
                    continue
                }
                let temp = temperature.selected
                readings.append(temp)

                // CSV logging
                let fan0rpm = (try? fanControl.fanInfo(0))?.actualRPM ?? 0
                let fan1rpm = fanCount > 1 ? ((try? fanControl.fanInfo(1))?.actualRPM ?? 0) : 0
                let ts = isoFormatter.string(from: Date())
                csvWrite("\(ts),\(String(format: "%.2f", fanPct)),\(String(format: "%.1f", temp)),\(String(format: "%.1f", temperature.cpu)),\(String(format: "%.1f", temperature.gpu)),\(Int(fan0rpm)),\(Int(fan1rpm)),stabilizing")

                // Safety: abort if too hot
                if temp >= Self.safetyTemp {
                    log("[\(Int(fanPct * 100))%] Safety at \(String(format: "%.0f", temp))°C — maxing fans, skipping lower levels")
                    try fanControl.setMax()
                    Thread.sleep(forTimeInterval: 30)
                    rawData.append((fanPct: fanPct, equilTemp: Self.ceilingTemp))
                    abortLowerLevels = true
                    break
                }

                // Ceiling: record and skip lower levels
                if temp >= Self.ceilingTemp {
                    log("[\(Int(fanPct * 100))%] Ceiling reached at \(String(format: "%.1f", temp))°C")
                    rawData.append((fanPct: fanPct, equilTemp: Self.ceilingTemp))
                    abortLowerLevels = true
                    break
                }

                // Check stabilization
                if let metrics = stabilityMetrics(readings: readings), isStabilized(metrics: metrics) {
                    let equilTemp = metrics.mean
                    log("[\(Int(fanPct * 100))%] Stabilized at \(String(format: "%.1f", equilTemp))°C (\(elapsedSeconds)s)")
                    log("  \(formatStability(metrics))")
                    rawData.append((fanPct: fanPct, equilTemp: equilTemp))
                    stabilized = true
                    break
                }

                if readings.count >= mode.stabilizationWindowSize,
                   readings.count % 15 == 0,
                   let metrics = stabilityMetrics(readings: readings)
                {
                    log("[\(Int(fanPct * 100))%] Still converging (\(elapsedSeconds)s): \(formatStability(metrics))")
                }

                Thread.sleep(forTimeInterval: 2)
            }

            // Never turn an arbitrary timeout average into calibration data.
            if !stabilized && !abortLowerLevels {
                unstableFanLevels.append(Int(fanPct * 100))
                let elapsedSeconds = Int(
                    (DispatchTime.now().uptimeNanoseconds - levelStart) / 1_000_000_000
                )
                if let metrics = stabilityMetrics(readings: readings) {
                    log("[\(Int(fanPct * 100))%] Timeout — excluded unstable level (\(elapsedSeconds)s): \(formatStability(metrics))")
                } else {
                    log("[\(Int(fanPct * 100))%] Timeout — excluded level with insufficient readings")
                }
            }
        }

        stopStress()

        // Phase 3: Build control curve from raw equilibrium data
        log("Phase 3: Building control curve...")

        // Three converged points are the minimum for a useful fitted curve.
        if rawData.count < 3 {
            log("")
            log("CALIBRATION FAILED: Insufficient converged data (\(rawData.count) point(s), need 3+).")
            if rawData.first?.equilTemp ?? 0 >= Self.ceilingTemp {
                log("Even 100% fans + minimum stress hit the \(Int(Self.ceilingTemp))°C ceiling.")
                if ambientTemp > 0 {
                    log("At \(String(format: "%.1f", ambientTemp))°C ambient, this machine cannot dissipate")
                    log("enough heat for calibration to complete.")
                } else {
                    log("This machine cannot dissipate enough heat for calibration to complete.")
                }
                log("")
                log("Options:")
                log("  1. Wait for ambient temperature to drop below 30°C and retry.")
                log("  2. Run in a cooler environment (air-conditioned room).")
                log("  3. Use the default Smart profile (built-in conservative curve).")
            }
            // Don't save — empty measurements would break the Smart profile.
            let unstable = unstableFanLevels.isEmpty ? "" : " Unstable levels: \(unstableFanLevels.map { "\($0)%" }.joined(separator: ", "))."
            throw CalibrationError.insufficientData(reason: "Only \(rawData.count) fan levels produced converged data; at least 3 are required.\(unstable)")
        }

        if let coverageError = Self.temperatureCoverageError(rawData: rawData) {
            log("")
            log("CALIBRATION FAILED: \(coverageError)")
            log("The workload was too weak to measure the Smart control range.")
            log("No calibration data was saved. Rerun with --rediscover-intensity.")
            throw CalibrationError.insufficientData(reason: coverageError)
        }

        let measurements = Self.buildControlCurve(rawData: rawData, minPct: minPct)

        // Validate we got something useful
        if measurements.isEmpty {
            log("Warning: Control curve is empty despite having \(rawData.count) raw data points.")
        }

        for m in measurements {
            log("  \(Int(m.targetTemp))°C → \(Int(m.holdingRPMPercent * 100))% fans")
        }

        if clamshell {
            log("  (calibrated in clamshell / lid-closed mode)")
        }

        return CalibrationData(
            machine: machine,
            fans: fanCount,
            maxRPM: Int(maxRPM),
            minRPM: Int(minRPM),
            calibratedAt: isoFormatter.string(from: Date()),
            mode: mode.rawValue,
            stressType: stressType.rawValue,
            workloadIntensity: baselineIntensity,
            ambientTemperature: ambientTemp > 0 ? ambientTemp : nil,
            lidClosed: clamshell,
            measurements: measurements
        )
    }

    /// Measure convergence over the most recent 60 seconds. Raw standard
    /// deviation is diagnostic only: it mixes real drift with sensor noise and
    /// previously caused flat-but-noisy levels to wait forever. Acceptance uses
    /// trend, half-window movement, and uncertainty after detrending.
    static func stabilityMetrics(
        readings: [Float],
        windowSize: Int = 30,
        sampleInterval: Float = 2
    ) -> CalibrationStabilityMetrics? {
        guard readings.count >= windowSize, windowSize >= 4 else { return nil }
        let window = Array(readings.suffix(windowSize))
        let n = Float(window.count)

        let mean = window.reduce(0, +) / n
        let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
        let rawStandardDeviation = sqrt(variance)

        let xMean = (n - 1) / 2
        var numerator: Float = 0
        var denominator: Float = 0
        for i in 0..<window.count {
            let x = Float(i) - xMean
            let y = window[i] - mean
            numerator += x * y
            denominator += x * x
        }
        let slopePerSample = denominator > 0 ? numerator / denominator : 0
        let slopePerSecond = slopePerSample / sampleInterval

        let residualVariance = window.enumerated().reduce(Float(0)) { partial, item in
            let predicted = mean + slopePerSample * (Float(item.offset) - xMean)
            let residual = item.element - predicted
            return partial + residual * residual
        } / n
        let residualStandardDeviation = sqrt(residualVariance)

        let half = window.count / 2
        let firstMean = window.prefix(half).reduce(0, +) / Float(half)
        let secondCount = window.count - half
        let secondMean = window.suffix(secondCount).reduce(0, +) / Float(secondCount)
        let halfMeanDelta = abs(secondMean - firstMean)
        // Thermal samples are autocorrelated. Treat each five-sample (10s)
        // block as one effective observation instead of claiming all 30 samples
        // are independent.
        let effectiveSampleCount = max(Float(window.count / 5), 2)
        let confidenceRadius95 = 1.96 * residualStandardDeviation / sqrt(effectiveSampleCount)

        return CalibrationStabilityMetrics(
            mean: mean,
            slopePerSecond: slopePerSecond,
            rawStandardDeviation: rawStandardDeviation,
            residualStandardDeviation: residualStandardDeviation,
            halfMeanDelta: halfMeanDelta,
            confidenceRadius95: confidenceRadius95
        )
    }

    private func stabilityMetrics(readings: [Float]) -> CalibrationStabilityMetrics? {
        Self.stabilityMetrics(readings: readings, windowSize: mode.stabilizationWindowSize)
    }

    private func isStabilized(metrics: CalibrationStabilityMetrics) -> Bool {
        mode.acceptsStability(metrics)
    }

    private func formatStability(_ metrics: CalibrationStabilityMetrics) -> String {
        "mean \(String(format: "%.2f", metrics.mean))°C, " +
            "slope \(String(format: "%+.4f", metrics.slopePerSecond))°C/s, " +
            "half Δ \(String(format: "%.2f", metrics.halfMeanDelta))°C, " +
            "noise σ \(String(format: "%.2f", metrics.residualStandardDeviation))°C, " +
            "95% ±\(String(format: "%.2f", metrics.confidenceRadius95))°C"
    }

    /// Build monotonically increasing control curve from raw equilibrium data.
    /// Raw data: (fanPct, equilTemp) — higher fan = lower equilibrium (physically correct).
    /// Control curve: (targetTemp, holdingRPMPercent) — higher temp = higher fan (for Smart).
    /// Formula: fan_control(T) = (1.0 + minPct) - F_equil(T)
    static func buildControlCurve(rawData: [(fanPct: Float, equilTemp: Float)], minPct: Float) -> [CalibrationData.Measurement] {
        guard rawData.count >= 2, temperatureCoverageError(rawData: rawData) == nil else { return [] }

        // Sort raw data by equilibrium temp ascending
        let sorted = rawData.sorted { $0.equilTemp < $1.equilTemp }

        var measurements: [CalibrationData.Measurement] = []
        var previousControlFan = minPct

        for target in Self.controlCurveTemps {
            // Interpolate equilibrium fan speed for this target temp
            let fEquil = interpolateEquilFanSpeed(temp: target, data: sorted)

            // Flip: control fan speed = (1.0 + minPct) - equilibrium fan speed
            var controlFan = (1.0 + minPct) - fEquil
            controlFan = min(max(controlFan, minPct), 1.0)

            // Sensor noise can slightly invert adjacent equilibrium points. A
            // calibrated control curve must never slow the fans as temperature
            // rises, so retain the previous (more conservative) percentage.
            controlFan = max(controlFan, previousControlFan)
            previousControlFan = controlFan

            measurements.append(CalibrationData.Measurement(
                targetTemp: target,
                holdingRPMPercent: controlFan
            ))
        }

        return measurements
    }

    /// A fitted curve must include measured behavior through 80°C. The 85°C
    /// point remains the hard maximum-fan anchor, but extrapolating every target
    /// from a sweep that stayed below the control range only produces an
    /// all-maximum curve with no useful machine-specific information.
    static func temperatureCoverageError(rawData: [(fanPct: Float, equilTemp: Float)]) -> String? {
        guard let maximum = rawData.map(\.equilTemp).max() else {
            return "No equilibrium temperatures were measured"
        }
        let requiredMaximum = controlCurveTemps.dropLast().last ?? 80
        guard maximum >= requiredMaximum else {
            return "Sweep reached only \(String(format: "%.1f", maximum))°C; at least \(Int(requiredMaximum))°C is required"
        }
        return nil
    }

    /// Interpolate the equilibrium fan speed for a given temperature from raw data.
    private static func interpolateEquilFanSpeed(temp: Float, data: [(fanPct: Float, equilTemp: Float)]) -> Float {
        guard !data.isEmpty else { return 0.5 }
        if temp <= data.first!.equilTemp { return data.first!.fanPct }
        if temp >= data.last!.equilTemp { return data.last!.fanPct }

        for i in 0..<(data.count - 1) {
            if temp >= data[i].equilTemp && temp <= data[i + 1].equilTemp {
                let t = (temp - data[i].equilTemp) / (data[i + 1].equilTemp - data[i].equilTemp)
                return data[i].fanPct + t * (data[i + 1].fanPct - data[i].fanPct)
            }
        }
        return data.last!.fanPct
    }

    private func waitForCooldown(below threshold: Float) {
        // Calibration owns fan control while the app/daemon are stopped. Use
        // maximum cooling instead of Apple auto to reach the baseline quickly.
        try? fanControl.setMax()
        var readings: [Float] = []
        for _ in 0..<60 {
            let temp = calibrationTemperature()?.selected ?? 0
            if temp > 0 {
                readings.append(temp)

                // Preserve the fast path when the requested baseline is
                // reachable, but ensure it is not just a single sensor dip.
                let recent = readings.suffix(3)
                if recent.count == 3,
                   recent.max()! - recent.min()! <= 0.5,
                   temp < threshold
                {
                    log("Cooled to \(String(format: "%.1f", temp))°C")
                    return
                }

                // In warm rooms the fixed 45°C target may be unreachable. A
                // stable baseline is what the equilibrium model actually needs.
                if let metrics = Self.stabilityMetrics(readings: readings, windowSize: 15),
                   abs(metrics.slopePerSecond) <= 0.005,
                   metrics.halfMeanDelta <= 0.5
                {
                    log("Baseline stabilized at \(String(format: "%.1f", metrics.mean))°C")
                    return
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        let temp = calibrationTemperature()?.selected ?? 0
        log("Cooldown limit reached at \(String(format: "%.1f", temp))°C — continuing with maximum fans")
    }

    // MARK: - Stress (CPU + GPU combined)
    //
    // Combined stress matches real-world worst case on Apple Silicon where
    // CPU, GPU, and Neural Engine share the same die and unified memory.
    // This is the Notebookcheck standard (Prime95 + FurMark simultaneously).

    /// Start stress at a given intensity (0.0–1.0).
    /// CPU: intensity * coreCount, including a duty-cycled fractional thread.
    /// GPU: intensity * 4M grid size.
    private func startStress(intensity: Float = 1.0) {
        guard !stressRunning else { return }
        stressRunning = true

        if stressType == .combined || stressType == .cpu {
            let coreCount = ProcessInfo.processInfo.activeProcessorCount
            let plan = Self.cpuStressPlan(intensity: intensity, coreCount: coreCount)
            for _ in 0..<plan.fullThreads {
                startCPUStressThread(dutyCycle: 1)
            }
            if plan.fractionalDutyCycle > 0 {
                startCPUStressThread(dutyCycle: plan.fractionalDutyCycle)
            }
        }

        // GPU stress: scale grid size by intensity
        if stressType == .combined || stressType == .gpu {
            startGPUStress(intensity: intensity)
        }
    }

    static func cpuStressPlan(intensity: Float, coreCount: Int) -> CalibrationCPUStressPlan {
        let clampedIntensity = min(max(intensity, 0), 1)
        let desiredCoreLoad = clampedIntensity * Float(max(coreCount, 1))
        let fullThreads = Int(desiredCoreLoad.rounded(.down))
        let fractionalDutyCycle = desiredCoreLoad - Float(fullThreads)
        return CalibrationCPUStressPlan(
            fullThreads: fullThreads,
            fractionalDutyCycle: fractionalDutyCycle
        )
    }

    private func startCPUStressThread(dutyCycle: Float) {
        let clampedDuty = min(max(dutyCycle, 0), 1)
        // Fractional work must be fine-grained: a 100ms cycle with a large
        // minimum batch created short full-power single-core bursts that peak
        // CPU sensors reported as 65–76°C even at ~0.15% total intensity.
        // A 10ms period and small batches distribute the same average work much
        // more evenly. Full workers retain large batches for efficiency.
        let isFullWorker = clampedDuty >= 0.999
        let period: TimeInterval = isFullWorker ? 0.1 : 0.01
        let activeDuration = period * Double(clampedDuty)
        let workIterations = isFullWorker ? 10_000 : 250

        let thread = Thread {
            while self.stressRunning {
                let cycleStart = Date()
                repeat {
                    var x: Double = 1.0
                    for i in 1...workIterations {
                        x = sin(x) * cos(Double(i))
                    }
                    _ = x
                } while self.stressRunning
                    && Date().timeIntervalSince(cycleStart) < activeDuration

                let elapsed = Date().timeIntervalSince(cycleStart)
                let remaining = period - elapsed
                if remaining > 0 {
                    Thread.sleep(forTimeInterval: remaining)
                }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        stressThreads.append(thread)
    }

    private func startGPUStress(intensity: Float = 1.0) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log("Warning: Metal device not available, running CPU-only stress")
            return
        }

        // Compile a compute shader at runtime that does dense FP32 math
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void stress(device float *data [[buffer(0)]],
                          uint id [[thread_position_in_grid]]) {
            float x = data[id];
            for (int i = 0; i < 2000; i++) {
                x = sin(x) * cos(x) + tan(x * 0.01);
                x = fma(x, x, float(i) * 0.001);
                x = sqrt(abs(x) + 1.0);
            }
            data[id] = x;
        }
        """

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let function = library.makeFunction(name: "stress"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue()
        else {
            log("Warning: Metal pipeline setup failed, running CPU-only stress")
            return
        }

        // Scale GPU work by intensity — grid size controls utilization
        let baseCount = 1024 * 1024 * 4 // 4M floats at 100%
        let elementCount = Swift.max(Int(Float(baseCount) * intensity), 1024)
        let bufferSize = elementCount * MemoryLayout<Float>.stride
        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            log("Warning: Metal buffer allocation failed, running CPU-only stress")
            return
        }

        // Fill with initial values
        let ptr = buffer.contents().bindMemory(to: Float.self, capacity: elementCount)
        for i in 0..<elementCount {
            ptr[i] = Float(i % 1000) * 0.001
        }

        self.gpuDevice = device
        self.gpuPipeline = pipeline
        self.gpuQueue = queue
        self.gpuBuffer = buffer
        self.gpuElementCount = elementCount

        // Run GPU dispatches on a background thread
        let thread = Thread {
            self.gpuStressLoop()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        stressThreads.append(thread)
    }

    private var gpuDevice: MTLDevice?
    private var gpuPipeline: MTLComputePipelineState?
    private var gpuQueue: MTLCommandQueue?
    private var gpuBuffer: MTLBuffer?
    private var gpuElementCount: Int = 0

    private func gpuStressLoop() {
        guard let pipeline = gpuPipeline,
              let queue = gpuQueue,
              let buffer = gpuBuffer
        else { return }

        let threadGroupSize = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
        let gridSize = MTLSize(width: gpuElementCount, height: 1, depth: 1)

        while stressRunning {
            guard let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder()
            else { continue }

            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
    }

    private func stopStress() {
        stressRunning = false
        // Most workers exit within one 100ms duty-cycle period. Poll briefly
        // instead of imposing a fixed two-second delay on every Phase 1 trial.
        let deadline = Date().addingTimeInterval(2)
        while stressThreads.contains(where: { !$0.isFinished }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        stressThreads.removeAll()
        // Release Metal resources — stops GPU dispatches
        gpuBuffer = nil
        gpuPipeline = nil
        gpuQueue = nil
        gpuDevice = nil
    }

    // MARK: - Helpers

    // MARK: - Logging

    private func csvWrite(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            csvHandle?.write(data)
        }
    }

    private func log(_ message: String) {
        onProgress?(message)
    }
}
