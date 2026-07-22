import Foundation

struct CalibrationEquilibriumMeasurement: Equatable {
    let fanPercent: Float
    let equilibriumTemperature: Float
}

struct EquilibriumSweepResult: Equatable {
    let measurements: [CalibrationEquilibriumMeasurement]
    let unstableFanLevels: [Int]
}

final class EquilibriumSweep {
    struct Configuration {
        var maximumWaitPerLevel: TimeInterval
        var ceilingTemperature: Float = 84
        var safetyTemperature: Float = 90
        var sampleInterval: TimeInterval = 2
        var safetyCooldown: TimeInterval = 30
        var progressSampleInterval = 15
    }

    private let configuration: Configuration
    private let levels: [Float]
    private let minimumRPM: Float
    private let maximumRPM: Float
    private let workloadIntensity: Float
    private let workload: any CalibrationWorkload
    private let workloadWarning: () -> String?
    private let convergence: CalibrationConvergenceModel
    private let setFanRPM: (Float) throws -> Void
    private let setMaximumFans: () throws -> Void
    private let sample: () -> CalibrationTemperatureSample?
    private let onSample: (Float, CalibrationTemperatureSample) -> Void
    private let now: () -> TimeInterval
    private let wait: (TimeInterval) throws -> Void
    private let checkCancellation: () throws -> Void
    private let log: (String) -> Void

    init(
        configuration: Configuration,
        levels: [Float],
        minimumRPM: Float,
        maximumRPM: Float,
        workloadIntensity: Float,
        workload: any CalibrationWorkload,
        workloadWarning: @escaping () -> String? = { nil },
        convergence: CalibrationConvergenceModel,
        setFanRPM: @escaping (Float) throws -> Void,
        setMaximumFans: @escaping () throws -> Void,
        sample: @escaping () -> CalibrationTemperatureSample?,
        onSample: @escaping (Float, CalibrationTemperatureSample) -> Void = { _, _ in },
        now: @escaping () -> TimeInterval,
        wait: @escaping (TimeInterval) throws -> Void,
        checkCancellation: @escaping () throws -> Void,
        log: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.levels = levels
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.workloadIntensity = workloadIntensity
        self.workload = workload
        self.workloadWarning = workloadWarning
        self.convergence = convergence
        self.setFanRPM = setFanRPM
        self.setMaximumFans = setMaximumFans
        self.sample = sample
        self.onSample = onSample
        self.now = now
        self.wait = wait
        self.checkCancellation = checkCancellation
        self.log = log
    }

    func run() throws -> EquilibriumSweepResult {
        _ = workload.start(intensity: workloadIntensity)
        if let warning = workloadWarning() {
            log(warning)
        }
        defer { workload.stop() }

        var measurements: [CalibrationEquilibriumMeasurement] = []
        var unstableFanLevels: [Int] = []

        for fanPercent in levels {
            try checkCancellation()
            let targetRPM = max(maximumRPM * fanPercent, minimumRPM)
            let levelPercent = Int(fanPercent * 100)
            log(
                "[\(levelPercent)%] Setting fans to \(Int(targetRPM)) RPM "
                    + "— waiting for stabilization..."
            )
            try setFanRPM(targetRPM)

            let levelStart = now()
            let deadline = levelStart + configuration.maximumWaitPerLevel
            var readings: [Float] = []
            var stabilized = false
            var stopLowerLevels = false

            while now() < deadline {
                try checkCancellation()
                let elapsedSeconds = Int(now() - levelStart)
                guard let temperature = sample() else {
                    try wait(configuration.sampleInterval)
                    continue
                }
                readings.append(temperature.selected)
                onSample(fanPercent, temperature)

                if temperature.selected >= configuration.safetyTemperature {
                    log(
                        "[\(levelPercent)%] Safety at "
                            + "\(String(format: "%.0f", temperature.selected))°C "
                            + "— maxing fans, skipping lower levels"
                    )
                    try setMaximumFans()
                    try wait(configuration.safetyCooldown)
                    measurements.append(.init(
                        fanPercent: fanPercent,
                        equilibriumTemperature: configuration.ceilingTemperature
                    ))
                    stopLowerLevels = true
                    break
                }

                if temperature.selected >= configuration.ceilingTemperature {
                    log(
                        "[\(levelPercent)%] Ceiling reached at "
                            + "\(String(format: "%.1f", temperature.selected))°C"
                    )
                    measurements.append(.init(
                        fanPercent: fanPercent,
                        equilibriumTemperature: configuration.ceilingTemperature
                    ))
                    stopLowerLevels = true
                    break
                }

                if let metrics = convergence.metrics(readings: readings),
                   convergence.accepts(metrics)
                {
                    log(
                        "[\(levelPercent)%] Stabilized at "
                            + "\(String(format: "%.1f", metrics.mean))°C "
                            + "(\(elapsedSeconds)s)"
                    )
                    log("  \(convergence.format(metrics))")
                    measurements.append(.init(
                        fanPercent: fanPercent,
                        equilibriumTemperature: metrics.mean
                    ))
                    stabilized = true
                    break
                }

                if readings.count >= convergence.windowSize,
                   readings.count.isMultiple(of: configuration.progressSampleInterval),
                   let metrics = convergence.metrics(readings: readings)
                {
                    log(
                        "[\(levelPercent)%] Still converging (\(elapsedSeconds)s): "
                            + convergence.format(metrics)
                    )
                }

                try wait(configuration.sampleInterval)
            }

            if !stabilized && !stopLowerLevels {
                unstableFanLevels.append(levelPercent)
                let elapsedSeconds = Int(now() - levelStart)
                if let metrics = convergence.metrics(readings: readings) {
                    log(
                        "[\(levelPercent)%] Timeout — excluded unstable level "
                            + "(\(elapsedSeconds)s): \(convergence.format(metrics))"
                    )
                } else {
                    log("[\(levelPercent)%] Timeout — excluded level with insufficient readings")
                }
            }

            if stopLowerLevels {
                break
            }
        }

        return EquilibriumSweepResult(
            measurements: measurements,
            unstableFanLevels: unstableFanLevels
        )
    }
}
