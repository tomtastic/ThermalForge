//
//  Calibration.swift
//  ThermalForge
//
//  Machine-specific thermal calibration data for the Smart profile.
//

import Foundation
import Metal
import AppKit
import Darwin

// MARK: - Data Model

public struct CalibrationData: Codable {
    public let machine: String
    public let fans: Int
    public let maxRPM: Int
    public let minRPM: Int
    public let calibratedAt: String
    public let mode: String?
    public let lidClosed: Bool  // true = clamshell mode, false = lid open
    public let measurements: [Measurement]

    public init(machine: String, fans: Int, maxRPM: Int, minRPM: Int, calibratedAt: String, mode: String? = nil, lidClosed: Bool = false, measurements: [Measurement]) {
        self.machine = machine
        self.fans = fans
        self.maxRPM = maxRPM
        self.minRPM = minRPM
        self.calibratedAt = calibratedAt
        self.mode = mode
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

    let hasBuiltIn = screens.first { desc in
        let dict = desc.deviceDescription as NSDictionary
        return (dict.object(forKey: "com.apple.screenIsBuiltIn") as? NSNumber)?.boolValue == true
    } != nil

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

    public func save() throws {
        let path = Self.filePath(forLidClosed: lidClosed)
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: path)

        // If running as root (daemon/CLI), also copy to the console user's
        // home directory so the app (running as the user) can find it.
        if geteuid() == 0 {
            try copyToConsoleUser(data: data, lidClosed: lidClosed)
        }
    }

    /// Copy calibration JSON to the console user's home directory.
    /// When calibration runs as root (via sudo or the daemon), the app
    /// (running as the logged-in user) can't read root's home directory.
    private func copyToConsoleUser(data: Data, lidClosed: Bool) throws {
        // Get console user UID from /dev/console
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0 else { return }

        // Get home directory from passwd
        guard let pw = getpwuid(st.st_uid), let home = String(validatingUTF8: pw.pointee.pw_dir) else { return }

        let userPath = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/ThermalForge/")
            .appendingPathComponent("calibration_\(lidClosed ? "lid_closed" : "lid_open").json")
        let userDir = userPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try data.write(to: userPath)
        TFLogger.shared.info("Copied calibration to console user: \(userPath.path)")
    }

    /// Load calibration data matching the current lid state.
    /// Falls back to legacy `calibration.json` if no lid-state-specific file exists.
    public static func load() -> CalibrationData? {
        load(forLidClosed: isClamshellMode())
    }

    /// Load calibration data for a specific lid state.
    /// Falls back to legacy `calibration.json` if no lid-state-specific file exists.
    public static func load(forLidClosed lidClosed: Bool) -> CalibrationData? {
        // Try lid-state-specific file first
        let specificPath = Self.filePath(forLidClosed: lidClosed)
        if let result = loadFromFile(specificPath) {
            return result
        }

        // Fall back to legacy file (no lid state info, treat as lid-open)
        if FileManager.default.fileExists(atPath: Self.legacyFilePath.path) {
            return loadFromFile(Self.legacyFilePath)
        }

        return nil
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
    /// 5 fan levels × up to 2.5 min each + intensity finding + cooldowns
    /// 60-second stabilization window (~80% accuracy)
    case quick

    /// 5 fan levels × up to 4 min each + overhead
    /// 90-second window (near one time constant, ~90% accuracy)
    case standard

    /// 5 fan levels × up to 6 min each + overhead
    /// 120-second window (full time constant, ~95% accuracy)
    case optimized

    public var description: String {
        switch self {
        case .quick: return "Quick (up to 17 min)"
        case .standard: return "Standard (up to 25 min)"
        case .optimized: return "Optimized (up to 35 min)"
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

    /// Number of readings in stabilization window (2s per reading)
    /// Based on thermal time constant research (90-120s):
    /// - Quick: 60s ≈ ~80% of steady state
    /// - Standard: 90s ≈ near one time constant
    /// - Optimized: 120s ≈ one full time constant, ~95% accuracy
    public var stabilizationWindowSize: Int {
        switch self {
        case .quick: return 30      // 60 seconds
        case .standard: return 45   // 90 seconds
        case .optimized: return 60  // 120 seconds
        }
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

// MARK: - Calibration Runner

public final class CalibrationRunner {
    private let fanControl: FanControl
    private let mode: CalibrationMode
    private let stressType: CalibrationStressType
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

    public init(fanControl: FanControl, mode: CalibrationMode = .standard, stressType: CalibrationStressType = .combined) {
        self.fanControl = fanControl
        self.mode = mode
        self.stressType = stressType
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
    static let phase1MaxIterations: Int = 8 // 8 steps covers 500x range with ratio < 2.0
    static let phase1CheckDuration: TimeInterval = 120 // seconds to observe each candidate
    static let phase1IntensityLow: Float = 0.001 // GPU-only below 0.01 — finer granularity
    static let phase1IntensityHigh: Float = 0.50
    static let phase1MaxRatio: Float = 2.0 // stop when high/low < 2.0 (ratio-based convergence)
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
    }

    /// Find the maximum stress intensity that still produces a safe equilibrium
    /// at 100% fans.
    ///
    /// Instead of targeting a fixed heating rate (which varies with ambient),
    /// this finds the intensity that produces an equilibrium below `targetEquilTemp`
    /// (~65°C) at 100% fans. This naturally adapts:
    /// - High ambient (35°C): returns ~0.005-0.015 (low stress)
    /// - Low ambient (22°C): returns ~0.03-0.08 (moderate stress)
    ///
    /// Returns nil if even minimum stress is too hot for the environment.
    private func findMaxSafeIntensity(maxRPM: Float) -> Float? {
        log("Finding max safe stress intensity (equilibrium < \(Int(Self.targetEquilTemp))°C at 100% fans)...")

        // Establish a stable baseline temperature
        waitForCooldown(below: 45)
        let baselineTemp = peakCPUTemp()
        guard baselineTemp > 0 else {
            log("  Can't read temperature")
            return nil
        }
        log("  Baseline: \(String(format: "%.1f", baselineTemp))°C")

        // Set fans to 100% and keep them there for all checks —
        // this is the worst-case cooling scenario and provides fastest cooldown
        try? fanControl.setAllFans(rpm: maxRPM)

        // Feasibility check: can minimum intensity stabilize below target?
        log("  Checking minimum intensity (\(Self.phase1IntensityLow))...")
        let minCheck = checkIntensity(at: Self.phase1IntensityLow, baselineTemp: baselineTemp)
        if minCheck.hitCeiling || minCheck.estimatedEquilTemp >= Self.targetEquilTemp + 10 {
            log("  Minimum stress too hot (est. equil \(String(format: "%.1f", minCheck.estimatedEquilTemp))°C) — calibration impossible")
            return nil
        }
        log("  Minimum: max \(String(format: "%.1f", minCheck.maxTemp))°C, est. equil \(String(format: "%.1f", minCheck.estimatedEquilTemp))°C, slope \(String(format: "%.3f", minCheck.slope))°C/s")

        // Check if max intensity is safe (cool machine / excellent cooling)
        log("  Checking maximum intensity (\(Self.phase1IntensityHigh))...")
        let maxCheck = checkIntensity(at: Self.phase1IntensityHigh, baselineTemp: baselineTemp)
        if !maxCheck.hitCeiling && maxCheck.estimatedEquilTemp < Self.targetEquilTemp - 5 {
            log("  Maximum safe: est. equil \(String(format: "%.1f", maxCheck.estimatedEquilTemp))°C — using \(Self.phase1IntensityHigh)")
            return Self.phase1IntensityHigh
        }
        log("  Maximum too hot: max \(String(format: "%.1f", maxCheck.maxTemp))°C, est. equil \(String(format: "%.1f", maxCheck.estimatedEquilTemp))°C")

        // Logarithmic bisection between known-safe (min) and known-unsafe (max)
        var low: Float = Self.phase1IntensityLow
        var high: Float = Self.phase1IntensityHigh

        for iteration in 0..<Self.phase1MaxIterations {
            let ratio = high / low
            if ratio < Self.phase1MaxRatio {
                log("  Bracket ratio converged (\(String(format: "%.1f", ratio))) — stopping")
                break
            }

            let mid = sqrt(low * high)  // logarithmic midpoint
            let result = checkIntensity(at: mid, baselineTemp: baselineTemp)

            let isSafe = !result.hitCeiling &&
                         result.estimatedEquilTemp < Self.targetEquilTemp

            if isSafe {
                low = mid  // safe, try higher
            } else {
                high = mid // too hot, try lower
            }

            log("  Step \(iteration + 1): intensity \(String(format: "%.3f", mid)) → " +
                "max \(String(format: "%.1f", result.maxTemp))°C, " +
                "est. equil \(String(format: "%.1f", result.estimatedEquilTemp))°C, " +
                "\(isSafe ? "✓ safe" : "✗ too hot") " +
                "→ bracket [\(String(format: "%.3f", low)), \(String(format: "%.3f", high))]")
        }

        log("  Max safe intensity: \(String(format: "%.3f", low))")
        return low  // last known safe intensity
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

        let actualStartTemp = peakCPUTemp()

        // Log stress mode so we know what's active
        let stressModeLabel: String
        if intensity < 0.01 {
            stressModeLabel = "GPU-only"
        } else {
            stressModeLabel = stressType == .combined ? "CPU+GPU" : stressType == .cpu ? "CPU" : "GPU"
        }
        log("  → intensity \(String(format: "%.3f", intensity)) (\(stressModeLabel))...")

        startStress(intensity: intensity)

        // Observe, sampling every 2s
        let samples = Int(Self.phase1CheckDuration / 2)
        var readings: [(time: Double, temp: Float)] = []
        let startUptime = DispatchTime.now().uptimeNanoseconds

        for _ in 0..<samples {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startUptime) / 1_000_000_000.0
            let temp = peakCPUTemp()
            readings.append((elapsed, temp))

            // Early exit: ceiling hit
            if temp >= Self.ceilingTemp {
                stopStress()
                return IntensityCheckResult(
                    maxTemp: temp,
                    estimatedEquilTemp: temp,
                    slope: .infinity,
                    hitCeiling: true
                )
            }

            Thread.sleep(forTimeInterval: 2)
        }

        stopStress()

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
            hitCeiling: false
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
            let temp = peakCPUTemp()
            guard temp > 0 else { return }

            if abs(temp - target) <= tolerance {
                // Verify stability: 3 quick samples within 0.5°C of each other
                var stable = true
                for _ in 0..<3 {
                    let t = peakCPUTemp()
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
        log("  Cooldown timeout: \(String(format: "%.1f", peakCPUTemp()))°C vs target \(String(format: "%.1f", target))°C — proceeding anyway")
    }

    /// Read peak CPU temperature right now
    private func peakCPUTemp() -> Float {
        guard let status = try? fanControl.status() else { return 0 }
        return status.temperatures
            .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
            .values.max() ?? 0
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
        log("Stabilization window: \(mode.stabilizationWindowSize * 2)s, max wait: \(mode.maxWaitPerLevel)s/level")

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

        // Phase 1: Find max safe stress intensity
        log("Phase 1: Finding max safe stress intensity...")
        guard let baselineIntensity = findMaxSafeIntensity(maxRPM: Float(maxRPM)) else {
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
        log("Baseline intensity: \(String(format: "%.3f", baselineIntensity))")

        // Phase 1.5: Cool again after intensity finding
        stopStress()
        try fanControl.resetAuto()
        waitForCooldown(below: 45)

        // Set up CSV log
        let logDir = CalibrationData.filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let timestamp = isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let csvURL = logDir.appendingPathComponent("calibration_\(timestamp).csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        csvHandle = try FileHandle(forWritingTo: csvURL)
        logPath = csvURL
        csvWrite("timestamp,fan_pct,actual_temp,fan0_rpm,fan1_rpm,phase")

        // Phase 2: Fan-level stabilization sweep (high to low)
        log("Phase 2: Starting fan-level sweep (intensity: \(String(format: "%.3f", baselineIntensity)))...")
        startStress(intensity: baselineIntensity)

        var rawData: [(fanPct: Float, equilTemp: Float)] = []
        var abortLowerLevels = false

        for (_, fanPct) in levels.enumerated() {
            guard !abortLowerLevels else { break }

            let targetRPM = Swift.max(maxRPM * fanPct, minRPM)
            log("[\(Int(fanPct * 100))%] Setting fans to \(Int(targetRPM)) RPM — waiting for stabilization...")

            try fanControl.setAllFans(rpm: targetRPM)

            var readings: [Float] = []
            let deadline = Date().addingTimeInterval(TimeInterval(mode.maxWaitPerLevel))
            var stabilized = false

            while Date() < deadline {
                let temp = peakCPUTemp()
                readings.append(temp)

                // CSV logging
                let fan0rpm = (try? fanControl.fanInfo(0))?.actualRPM ?? 0
                let fan1rpm = fanCount > 1 ? ((try? fanControl.fanInfo(1))?.actualRPM ?? 0) : 0
                let ts = isoFormatter.string(from: Date())
                csvWrite("\(ts),\(String(format: "%.2f", fanPct)),\(String(format: "%.1f", temp)),\(Int(fan0rpm)),\(Int(fan1rpm)),stabilizing")

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
                if isStabilized(readings: readings) {
                    let window = readings.suffix(mode.stabilizationWindowSize)
                    let equilTemp = window.reduce(0, +) / Float(window.count)
                    log("[\(Int(fanPct * 100))%] Stabilized at \(String(format: "%.1f", equilTemp))°C (\(readings.count * 2)s)")
                    rawData.append((fanPct: fanPct, equilTemp: equilTemp))
                    stabilized = true
                    break
                }

                Thread.sleep(forTimeInterval: 2)
            }

            // Timeout: use best estimate
            if !stabilized && !abortLowerLevels {
                let windowSize = min(readings.count, mode.stabilizationWindowSize)
                let window = readings.suffix(windowSize)
                let equilTemp = window.isEmpty ? peakCPUTemp() : window.reduce(0, +) / Float(window.count)
                log("[\(Int(fanPct * 100))%] Timeout — best estimate: \(String(format: "%.1f", equilTemp))°C (\(readings.count * 2)s)")
                rawData.append((fanPct: fanPct, equilTemp: equilTemp))
            }
        }

        stopStress()

        // Phase 3: Build control curve from raw equilibrium data
        log("Phase 3: Building control curve...")

        // Check if we have enough data — need at least 2 distinct equilibrium points
        if rawData.count < 2 {
            log("")
            log("CALIBRATION FAILED: Insufficient data (\(rawData.count) point(s) needed 2+).")
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
            throw CalibrationError.insufficientData(reason: "Only \(rawData.count) fan level(s) produced data before hitting \(Int(Self.ceilingTemp))°C ceiling. High ambient temperature prevents calibration.")
        }

        let measurements = buildControlCurve(rawData: rawData, minPct: minPct)

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
            lidClosed: clamshell,
            measurements: measurements
        )
    }

    /// Check if temperature readings have stabilized.
    /// Stable = stdev < 0.5°C AND slope < 0.05°C/sec over the window.
    private func isStabilized(readings: [Float]) -> Bool {
        guard readings.count >= mode.stabilizationWindowSize else { return false }
        let window = Array(readings.suffix(mode.stabilizationWindowSize))
        let n = Float(window.count)

        // Standard deviation
        let mean = window.reduce(0, +) / n
        let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
        let stdev = sqrt(variance)

        // Linear regression slope (least squares)
        let xMean = (n - 1) / 2
        var numerator: Float = 0
        var denominator: Float = 0
        for i in 0..<window.count {
            let x = Float(i) - xMean
            let y = window[i] - mean
            numerator += x * y
            denominator += x * x
        }
        let slope = denominator > 0 ? numerator / denominator : 0
        let slopePerSecond = slope / 2.0 // readings are 2 seconds apart

        return stdev < 0.5 && abs(slopePerSecond) < 0.05
    }

    /// Build monotonically increasing control curve from raw equilibrium data.
    /// Raw data: (fanPct, equilTemp) — higher fan = lower equilibrium (physically correct).
    /// Control curve: (targetTemp, holdingRPMPercent) — higher temp = higher fan (for Smart).
    /// Formula: fan_control(T) = (1.0 + minPct) - F_equil(T)
    private func buildControlCurve(rawData: [(fanPct: Float, equilTemp: Float)], minPct: Float) -> [CalibrationData.Measurement] {
        guard rawData.count >= 2 else { return [] }

        // Sort raw data by equilibrium temp ascending
        let sorted = rawData.sorted { $0.equilTemp < $1.equilTemp }

        var measurements: [CalibrationData.Measurement] = []

        for target in Self.controlCurveTemps {
            // Interpolate equilibrium fan speed for this target temp
            let fEquil = interpolateEquilFanSpeed(temp: target, data: sorted)

            // Flip: control fan speed = (1.0 + minPct) - equilibrium fan speed
            var controlFan = (1.0 + minPct) - fEquil
            controlFan = min(max(controlFan, minPct), 1.0)

            measurements.append(CalibrationData.Measurement(
                targetTemp: target,
                holdingRPMPercent: controlFan
            ))
        }

        return measurements
    }

    /// Interpolate the equilibrium fan speed for a given temperature from raw data.
    private func interpolateEquilFanSpeed(temp: Float, data: [(fanPct: Float, equilTemp: Float)]) -> Float {
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
        for _ in 0..<60 {
            let temp = peakCPUTemp()
            if temp > 0 && temp < threshold {
                log("Cooled to \(String(format: "%.1f", temp))°C")
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    // MARK: - Stress (CPU + GPU combined)
    //
    // Combined stress matches real-world worst case on Apple Silicon where
    // CPU, GPU, and Neural Engine share the same die and unified memory.
    // This is the Notebookcheck standard (Prime95 + FurMark simultaneously).

    /// Start stress at a given intensity (0.0–1.0).
    /// CPU: intensity * coreCount threads active.
    /// GPU: intensity * 4M grid size.
    ///
    /// At very low intensities (< 0.01), CPU stress is skipped because
    /// `max(Int(cores * intensity), 1)` always gives 1 fully busy core —
    /// too much heat for fine-grained control. GPU stress scales continuously
    /// by element count and provides sufficient granular heat on its own.
    private func startStress(intensity: Float = 1.0) {
        guard !stressRunning else { return }
        stressRunning = true

        // CPU stress: use intensity * cores.
        // Skip at very low intensities — 1 busy core is too much heat
        // when we need granular control (GPU stress handles this range).
        let cpuThreshold: Float = 0.01 // below this, cores would round to 1 regardless
        if (stressType == .combined || stressType == .cpu) && intensity >= cpuThreshold {
            let coreCount = ProcessInfo.processInfo.activeProcessorCount
            let activeCores = Swift.max(Int(Float(coreCount) * intensity), 1)
            for _ in 0..<activeCores {
                let thread = Thread {
                    while self.stressRunning {
                        var x: Double = 1.0
                        for i in 1...10000 {
                            x = sin(x) * cos(Double(i))
                        }
                        _ = x
                    }
                }
                thread.qualityOfService = .userInteractive
                thread.start()
                stressThreads.append(thread)
            }
        }

        // GPU stress: scale grid size by intensity
        if stressType == .combined || stressType == .gpu {
            startGPUStress(intensity: intensity)
        }
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
        // Wait for threads to notice the flag and exit
        Thread.sleep(forTimeInterval: 2)
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
