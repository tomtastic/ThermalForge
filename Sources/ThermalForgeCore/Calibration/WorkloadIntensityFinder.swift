import Foundation

struct WorkloadIntensitySelection: Equatable {
    let intensity: Float
    /// The final trial was a hotter rejected probe, so its residual heat must
    /// not contaminate the first fan-level measurement.
    let requiresCooldown: Bool
}

final class WorkloadIntensityFinder {
    struct Configuration {
        var targetEquilibriumTemperature: Float = 65
        var usefulEquilibriumMinimum: Float = 59
        var ceilingTemperature: Float = 84
        var maximumIterations = 8
        var initialIntensity: Float = 0.05
        var minimumIntensity: Float = 0.001
        var maximumIntensity: Float = 0.5
        var checkDuration: TimeInterval = 120
        var minimumDecisionDuration: TimeInterval = 60
        var thermalTimeConstant: TimeInterval = 90
        var observationInterval: TimeInterval = 2
        var cooldownMaximumWait: TimeInterval = 120
        var cooldownTolerance: Float = 3
        var cooldownPollInterval: TimeInterval = 2
        var cooldownStabilitySamples = 3
        var cooldownStabilityDelta: Float = 0.5
        var cooldownStabilityInterval: TimeInterval = 1
    }

    private struct CheckResult {
        let maxTemperature: Float
        let estimatedEquilibriumTemperature: Float
        let slopePerSecond: Float
        let hitCeiling: Bool
        let duration: TimeInterval

        func isSafe(configuration: Configuration) -> Bool {
            !hitCeiling
                && estimatedEquilibriumTemperature < configuration.targetEquilibriumTemperature
        }

        func isUseful(configuration: Configuration) -> Bool {
            isSafe(configuration: configuration)
                && estimatedEquilibriumTemperature >= configuration.usefulEquilibriumMinimum
        }
    }

    private let configuration: Configuration
    private let stressDescription: String
    private let temperature: () -> Float?
    private let workload: any CalibrationWorkload
    private let workloadWarning: () -> String?
    private let setMaximumFans: () throws -> Void
    private let now: () -> TimeInterval
    private let wait: (TimeInterval) throws -> Void
    private let checkCancellation: () throws -> Void
    private let log: (String) -> Void

    init(
        configuration: Configuration = Configuration(),
        stressDescription: String,
        temperature: @escaping () -> Float?,
        workload: any CalibrationWorkload,
        workloadWarning: @escaping () -> String? = { nil },
        setMaximumFans: @escaping () throws -> Void,
        now: @escaping () -> TimeInterval,
        wait: @escaping (TimeInterval) throws -> Void,
        checkCancellation: @escaping () throws -> Void,
        log: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.stressDescription = stressDescription
        self.temperature = temperature
        self.workload = workload
        self.workloadWarning = workloadWarning
        self.setMaximumFans = setMaximumFans
        self.now = now
        self.wait = wait
        self.checkCancellation = checkCancellation
        self.log = log
    }

    func find() throws -> WorkloadIntensitySelection? {
        log(
            "Finding max safe stress intensity (equilibrium < "
                + "\(Int(configuration.targetEquilibriumTemperature))°C at 100% fans)..."
        )

        guard let baselineTemperature = temperature(), baselineTemperature > 0 else {
            log("  Can't read temperature")
            return nil
        }
        log("  Baseline: \(format(baselineTemperature, decimals: 1))°C")

        // Maximum cooling is retained for every probe and its cooldown.
        try? setMaximumFans()

        var probe = configuration.initialIntensity
        var safeIntensity: Float?
        var safeEquilibrium: Float?
        var unsafeIntensity: Float?
        var lastTestedIntensity: Float?

        for attempt in 1...configuration.maximumIterations {
            try checkCancellation()
            let result = try check(intensity: probe, baselineTemperature: baselineTemperature)
            lastTestedIntensity = probe
            log(result: result, intensity: probe, attempt: attempt)

            if result.isSafe(configuration: configuration) {
                safeIntensity = probe
                safeEquilibrium = result.estimatedEquilibriumTemperature

                if result.isUseful(configuration: configuration) {
                    break
                }

                if let unsafeIntensity {
                    probe = sqrt(probe * unsafeIntensity)
                } else if probe >= configuration.maximumIntensity {
                    break
                } else {
                    probe = min(probe * 2, configuration.maximumIntensity)
                }
            } else {
                unsafeIntensity = probe
                if let safeIntensity {
                    probe = sqrt(safeIntensity * probe)
                } else if probe <= configuration.minimumIntensity {
                    return nil
                } else {
                    probe = max(probe / 2, configuration.minimumIntensity)
                }
            }
        }

        guard let safeIntensity else { return nil }
        let requiresCooldown = lastTestedIntensity.map {
            abs($0 - safeIntensity) > 0.000_001
        } ?? false
        if let safeEquilibrium,
           safeEquilibrium < configuration.usefulEquilibriumMinimum
        {
            log(
                "  No safe probe reached "
                    + "\(Int(configuration.usefulEquilibriumMinimum))–"
                    + "\(Int(configuration.targetEquilibriumTemperature))°C; "
                    + "sweeping with the strongest safe candidate and validating coverage"
            )
        }
        log("  Selected safe intensity: \(format(safeIntensity, decimals: 5))")
        return WorkloadIntensitySelection(
            intensity: safeIntensity,
            requiresCooldown: requiresCooldown
        )
    }

    private func check(
        intensity: Float,
        baselineTemperature: Float
    ) throws -> CheckResult {
        try waitForTemperatureReturn(to: baselineTemperature)
        let actualStartTemperature = temperature() ?? 0

        log(
            "  → intensity \(format(intensity, decimals: 5)) "
                + "(\(stressDescription))..."
        )

        _ = workload.start(intensity: intensity)
        if let warning = workloadWarning() {
            log(warning)
        }
        defer { workload.stop() }

        var readings: [(time: TimeInterval, temperature: Float)] = []
        let startTime = now()

        while true {
            try checkCancellation()
            let elapsed = now() - startTime
            let currentTemperature = temperature() ?? 0
            readings.append((elapsed, currentTemperature))

            if currentTemperature >= configuration.ceilingTemperature {
                return CheckResult(
                    maxTemperature: currentTemperature,
                    estimatedEquilibriumTemperature: currentTemperature,
                    slopePerSecond: .infinity,
                    hitCeiling: true,
                    duration: elapsed
                )
            }

            let result = intensityResult(
                readings: readings,
                actualStartTemperature: actualStartTemperature
            )
            if elapsed >= configuration.minimumDecisionDuration {
                let clearlyUnsafe = result.estimatedEquilibriumTemperature
                    >= configuration.targetEquilibriumTemperature + 5
                let clearlySafe = result.estimatedEquilibriumTemperature
                    <= configuration.targetEquilibriumTemperature - 3
                    && abs(result.slopePerSecond) <= 0.01
                if clearlyUnsafe || clearlySafe {
                    return result
                }
            }

            if elapsed >= configuration.checkDuration {
                return result
            }

            try wait(configuration.observationInterval)
        }
    }

    private func intensityResult(
        readings: [(time: TimeInterval, temperature: Float)],
        actualStartTemperature: Float
    ) -> CheckResult {
        let tailStart = readings.count * 2 / 3
        let tail = Array(readings.suffix(from: tailStart))
        let slope = Self.slope(readings: tail)
        let tailTemperatureAverage = tail
            .map { Double($0.temperature) }
            .reduce(0, +) / Double(tail.count)
        let tailTimeMidpoint = (tail.first!.time + tail.last!.time) / 2
        let fractionReached = 1 - exp(
            -tailTimeMidpoint / configuration.thermalTimeConstant
        )

        let estimatedEquilibriumTemperature: Float
        if fractionReached > 0.1 {
            let observedRise = tailTemperatureAverage - Double(actualStartTemperature)
            let estimatedRise = observedRise / fractionReached
            estimatedEquilibriumTemperature = Float(
                Double(actualStartTemperature) + estimatedRise
            )
        } else {
            estimatedEquilibriumTemperature = readings
                .map(\.temperature)
                .max()!
        }

        return CheckResult(
            maxTemperature: readings.map(\.temperature).max()!,
            estimatedEquilibriumTemperature: estimatedEquilibriumTemperature,
            slopePerSecond: slope,
            hitCeiling: false,
            duration: readings.last?.time ?? 0
        )
    }

    private func waitForTemperatureReturn(to target: Float) throws {
        let deadline = now() + configuration.cooldownMaximumWait

        while now() < deadline {
            try checkCancellation()
            guard let currentTemperature = temperature(), currentTemperature > 0 else {
                return
            }

            if currentTemperature <= target + configuration.cooldownTolerance {
                var stable = true
                for _ in 0..<configuration.cooldownStabilitySamples {
                    let sample = temperature() ?? 0
                    if abs(sample - currentTemperature) > configuration.cooldownStabilityDelta {
                        stable = false
                        break
                    }
                    try wait(configuration.cooldownStabilityInterval)
                }
                if stable {
                    return
                }
            }
            try wait(configuration.cooldownPollInterval)
        }

        let finalTemperature = temperature() ?? 0
        log(
            "  Cooldown timeout: \(format(finalTemperature, decimals: 1))°C vs target "
                + "\(format(target, decimals: 1))°C — proceeding anyway"
        )
    }

    private func log(result: CheckResult, intensity: Float, attempt: Int) {
        let verdict = result.isUseful(configuration: configuration)
            ? "✓ useful and safe"
            : result.isSafe(configuration: configuration)
                ? "△ safe but underpowered"
                : "✗ too hot"
        log(
            "  Step \(attempt): intensity \(format(intensity, decimals: 5)) → "
                + "max \(format(result.maxTemperature, decimals: 1))°C, "
                + "est. equil \(format(result.estimatedEquilibriumTemperature, decimals: 1))°C, "
                + "slope \(String(format: "%+.3f", result.slopePerSecond))°C/s, "
                + "\(verdict) (\(Int(result.duration))s)"
        )
    }

    private static func slope(
        readings: [(time: TimeInterval, temperature: Float)]
    ) -> Float {
        guard readings.count >= 4 else { return 0 }
        let count = Double(readings.count)
        let times = readings.map(\.time)
        let temperatures = readings.map { Double($0.temperature) }
        let sumTime = times.reduce(0, +)
        let sumTemperature = temperatures.reduce(0, +)
        let sumProducts = zip(times, temperatures).map(*).reduce(0, +)
        let sumSquares = times.map { $0 * $0 }.reduce(0, +)
        let denominator = count * sumSquares - sumTime * sumTime
        guard denominator > 0 else { return 0 }
        let numerator = count * sumProducts - sumTime * sumTemperature
        return Float(numerator / denominator)
    }

    private func format(_ value: Float, decimals: Int) -> String {
        String(format: "%.*f", decimals, value)
    }
}
