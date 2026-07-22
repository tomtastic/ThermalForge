//
//  Calibration.swift
//  ThermalForge
//
//  Machine-specific thermal calibration data for the Smart profile.
//

import Foundation
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

        public init(targetTemp: Float, holdingRPMPercent: Float) {
            self.targetTemp = targetTemp
            self.holdingRPMPercent = holdingRPMPercent
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
        CalibrationConvergenceModel(mode: self).windowSize
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
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .insufficientData(let reason):
            return reason
        case .cancelled:
            return "Calibration was interrupted"
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

// MARK: - Calibration Runner

public final class CalibrationRunner {
    private let fanControl: FanControl
    private let mode: CalibrationMode
    private let stressType: CalibrationStressType
    private let workloadIntensityOverride: Float?
    private let cancellationToken: CancellationToken
    private let lidStateProvider: any LidStateProvider
    private let convergenceModel: CalibrationConvergenceModel
    private let calibrationWorkload: any CalibrationWorkload
    private let gpuStressWorkload: GPUStressWorkload?
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
        workloadIntensity: Float? = nil,
        cancellationToken: CancellationToken = CancellationToken(),
        lidStateProvider: any LidStateProvider = MacLidStateProvider()
    ) {
        self.fanControl = fanControl
        self.mode = mode
        self.stressType = stressType
        self.workloadIntensityOverride = workloadIntensity
        self.cancellationToken = cancellationToken
        self.lidStateProvider = lidStateProvider
        self.convergenceModel = CalibrationConvergenceModel(mode: mode)

        let cpuWorkload = CPUStressWorkload()
        switch stressType {
        case .cpu:
            self.calibrationWorkload = cpuWorkload
            self.gpuStressWorkload = nil
        case .gpu:
            let gpuWorkload = GPUStressWorkload()
            self.calibrationWorkload = gpuWorkload
            self.gpuStressWorkload = gpuWorkload
        case .combined:
            let gpuWorkload = GPUStressWorkload()
            self.calibrationWorkload = CalibrationWorkloadGroup(
                workloads: [cpuWorkload, gpuWorkload]
            )
            self.gpuStressWorkload = gpuWorkload
        }
    }

    /// Check if running this mode would downgrade existing calibration
    public static func wouldDowngrade(
        mode: CalibrationMode,
        lidStateProvider: any LidStateProvider = MacLidStateProvider()
    ) -> Bool {
        guard let existing = CalibrationData.load(lidStateProvider: lidStateProvider) else { return false }
        return mode.rank < existing.modeRank
    }

    private func findSafeSweepIntensity(maxRPM: Float) throws -> WorkloadIntensitySelection? {
        let finder = WorkloadIntensityFinder(
            stressDescription: stressType.description,
            temperature: { [self] in calibrationTemperature()?.selected },
            workload: calibrationWorkload,
            workloadWarning: { [self] in gpuStressWorkload?.lastWarning },
            setMaximumFans: { [self] in try fanControl.setAllFans(rpm: maxRPM) },
            now: {
                TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            },
            wait: { [self] interval in try wait(for: interval) },
            checkCancellation: { [self] in try throwIfCancelled() },
            log: { [self] message in log(message) }
        )
        return try finder.find()
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
        let summary = TemperatureSummary(temperatures)
        let cpu = summary.cpu ?? 0
        let gpu = summary.gpu ?? 0

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
        calibrationWorkload.stop()
        try? fanControl.resetAuto()
        csvHandle?.closeFile()
        csvHandle = nil
        if cancellationToken.isCancelled {
            Self.discardPartialLog(at: logPath)
            logPath = nil
        }
    }

    static func discardPartialLog(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func throwIfCancelled() throws {
        if cancellationToken.isCancelled {
            throw CalibrationError.cancelled
        }
    }

    private func wait(for interval: TimeInterval) throws {
        if cancellationToken.waitUntilCancelled(for: interval) {
            throw CalibrationError.cancelled
        }
    }

    /// Fan levels to test (high to low). 5 levels cover the useful cooling range.
    private static func fanLevels(minPct: Float) -> [Float] {
        [1.0, 0.80, 0.60, 0.45, minPct]
    }

    /// Ceiling: record data and skip remaining lower fan levels
    private static let ceilingTemp: Float = 84.0

    /// Run full calibration. Blocks until complete.
    public func run() throws -> CalibrationData {
        defer { cleanup() }
        try throwIfCancelled()

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
        let clamshell = lidStateProvider.isLidClosed

        let levels = Self.fanLevels(minPct: minPct)
        log("Mode: \(mode.description)")
        log("Stress: \(stressType.description)")
        log("Approach: fan-first with stabilization (set fan speed, wait for equilibrium)")
        log("Fan levels: \(levels.map { "\(Int($0 * 100))%" }.joined(separator: " → "))")
        log("Stabilization evidence: \(mode.stabilizationWindowSize * 2)s minimum, max wait: \(mode.maxWaitPerLevel)s/level")

        // Record ambient temperature
        var ambientTemp: Float = 0
        if let status = try? fanControl.status() {
            ambientTemp = TemperatureSummary(status.temperatures).ambient ?? 0
        }
        if ambientTemp > 0 {
            log("Ambient: \(String(format: "%.1f", ambientTemp))°C \(clamshell ? "(lid closed / clamshell)" : "(lid open)")")
        } else if clamshell {
            log("Mode: lid closed / clamshell")
        }

        // Phase 0: Cooldown to baseline
        log("Phase 0: Cooling to baseline...")
        try waitForCooldown(below: 45)

        let baselineIntensity: Float
        if let workloadIntensityOverride {
            baselineIntensity = workloadIntensityOverride
            log("Phase 1: Using supplied/reused safe workload intensity \(String(format: "%.5f", baselineIntensity))")
            try fanControl.setMax()
        } else {
            // Phase 1: Find max safe stress intensity
            log("Phase 1: Finding max safe stress intensity...")
            guard let intensitySelection = try findSafeSweepIntensity(maxRPM: Float(maxRPM)) else {
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
                try waitForCooldown(below: 45)
            } else {
                // Preserve the useful final safe-probe state instead of resetting
                // to Apple auto and paying for an unnecessary cooldown/reheat.
                try fanControl.setMax()
            }
        }

        // Set up CSV log
        let logDir = CalibrationData.applicationSupportDirectory
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
        let sweep = EquilibriumSweep(
            configuration: .init(maximumWaitPerLevel: TimeInterval(mode.maxWaitPerLevel)),
            levels: levels,
            minimumRPM: minRPM,
            maximumRPM: maxRPM,
            workloadIntensity: baselineIntensity,
            workload: calibrationWorkload,
            workloadWarning: { [self] in gpuStressWorkload?.lastWarning },
            convergence: convergenceModel,
            setFanRPM: { [self] rpm in try fanControl.setAllFans(rpm: rpm) },
            setMaximumFans: { [self] in try fanControl.setMax() },
            sample: { [self] in calibrationTemperature() },
            onSample: { [self] fanPercent, temperature in
                let fan0RPM = (try? fanControl.fanInfo(0))?.actualRPM ?? 0
                let fan1RPM = fanCount > 1
                    ? ((try? fanControl.fanInfo(1))?.actualRPM ?? 0)
                    : 0
                let timestamp = isoFormatter.string(from: Date())
                csvWrite(
                    "\(timestamp),\(String(format: "%.2f", fanPercent)),"
                        + "\(String(format: "%.1f", temperature.selected)),"
                        + "\(String(format: "%.1f", temperature.cpu)),"
                        + "\(String(format: "%.1f", temperature.gpu)),"
                        + "\(Int(fan0RPM)),\(Int(fan1RPM)),stabilizing"
                )
            },
            now: {
                TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            },
            wait: { [self] interval in try wait(for: interval) },
            checkCancellation: { [self] in try throwIfCancelled() },
            log: { [self] message in log(message) }
        )
        let sweepResult = try sweep.run()
        let rawData = sweepResult.measurements
        let unstableFanLevels = sweepResult.unstableFanLevels
        try throwIfCancelled()

        // Phase 3: Build control curve from raw equilibrium data
        log("Phase 3: Building control curve...")

        // Three converged points are the minimum for a useful fitted curve.
        if rawData.count < 3 {
            log("")
            log("CALIBRATION FAILED: Insufficient converged data (\(rawData.count) point(s), need 3+).")
            if rawData.first?.equilibriumTemperature ?? 0 >= Self.ceilingTemp {
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

        let curveBuilder = CalibrationCurveBuilder(minimumFanPercent: minPct)
        if let coverageError = curveBuilder.coverageError(measurements: rawData) {
            log("")
            log("CALIBRATION FAILED: \(coverageError)")
            log("The workload was too weak to measure the Smart control range.")
            log("No calibration data was saved. Rerun with --rediscover-intensity.")
            throw CalibrationError.insufficientData(reason: coverageError)
        }

        let measurements = curveBuilder.build(measurements: rawData)

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

        try throwIfCancelled()

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

    private func waitForCooldown(below threshold: Float) throws {
        // Calibration owns fan control while the app/daemon are stopped. Use
        // maximum cooling instead of Apple auto to reach the baseline quickly.
        try? fanControl.setMax()
        var readings: [Float] = []
        for _ in 0..<60 {
            try throwIfCancelled()
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
                if let metrics = convergenceModel.metrics(readings: readings, windowSize: 15),
                   abs(metrics.slopePerSecond) <= 0.005,
                   metrics.halfMeanDelta <= 0.5
                {
                    log("Baseline stabilized at \(String(format: "%.1f", metrics.mean))°C")
                    return
                }
            }
            try wait(for: 2)
        }
        let temp = calibrationTemperature()?.selected ?? 0
        log("Cooldown limit reached at \(String(format: "%.1f", temp))°C — continuing with maximum fans")
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
