import Foundation

final class CalibrationCooldown {
    struct Configuration {
        var maximumSamples = 60
        var sampleInterval: TimeInterval = 2
        var thresholdStabilitySamples = 3
        var thresholdStabilityDelta: Float = 0.5
        var equilibriumWindowSize = 15
        var maximumEquilibriumSlope: Float = 0.005
        var maximumEquilibriumHalfMeanDelta: Float = 0.5
    }

    private let configuration: Configuration
    private let convergence: CalibrationConvergenceModel
    private let setMaximumFans: () throws -> Void
    private let temperature: () -> Float?
    private let wait: (TimeInterval) throws -> Void
    private let checkCancellation: () throws -> Void
    private let log: (String) -> Void

    init(
        configuration: Configuration = Configuration(),
        convergence: CalibrationConvergenceModel,
        setMaximumFans: @escaping () throws -> Void,
        temperature: @escaping () -> Float?,
        wait: @escaping (TimeInterval) throws -> Void,
        checkCancellation: @escaping () throws -> Void,
        log: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.convergence = convergence
        self.setMaximumFans = setMaximumFans
        self.temperature = temperature
        self.wait = wait
        self.checkCancellation = checkCancellation
        self.log = log
    }

    func run(below threshold: Float) throws {
        try? setMaximumFans()
        var readings: [Float] = []

        for _ in 0..<configuration.maximumSamples {
            try checkCancellation()
            let currentTemperature = temperature() ?? 0
            if currentTemperature > 0 {
                readings.append(currentTemperature)

                let recent = readings.suffix(configuration.thresholdStabilitySamples)
                if recent.count == configuration.thresholdStabilitySamples,
                   recent.max()! - recent.min()! <= configuration.thresholdStabilityDelta,
                   currentTemperature < threshold
                {
                    log("Cooled to \(String(format: "%.1f", currentTemperature))°C")
                    return
                }

                if let metrics = convergence.metrics(
                    readings: readings,
                    windowSize: configuration.equilibriumWindowSize
                ),
                   abs(metrics.slopePerSecond) <= configuration.maximumEquilibriumSlope,
                   metrics.halfMeanDelta <= configuration.maximumEquilibriumHalfMeanDelta
                {
                    log("Baseline stabilized at \(String(format: "%.1f", metrics.mean))°C")
                    return
                }
            }
            try wait(configuration.sampleInterval)
        }

        let finalTemperature = temperature() ?? 0
        log(
            "Cooldown limit reached at \(String(format: "%.1f", finalTemperature))°C "
                + "— continuing with maximum fans"
        )
    }
}
