import Foundation

struct CalibrationConvergenceMetrics: Equatable {
    let mean: Float
    let slopePerSecond: Float
    let rawStandardDeviation: Float
    let residualStandardDeviation: Float
    let halfMeanDelta: Float
    let confidenceRadius95: Float
}

struct CalibrationConvergenceModel {
    let windowSize: Int
    let maximumSlopePerSecond: Float
    let maximumHalfMeanDelta: Float
    let maximumConfidenceRadius: Float

    init(mode: CalibrationMode) {
        windowSize = 30
        switch mode {
        case .quick:
            maximumSlopePerSecond = 0.008
            maximumHalfMeanDelta = 0.9
            maximumConfidenceRadius = 0.90
        case .standard:
            maximumSlopePerSecond = 0.005
            maximumHalfMeanDelta = 0.6
            maximumConfidenceRadius = 0.65
        case .optimized:
            maximumSlopePerSecond = 0.003
            maximumHalfMeanDelta = 0.4
            maximumConfidenceRadius = 0.45
        }
    }

    /// Measure convergence over the most recent window. Raw standard deviation
    /// is diagnostic only: acceptance uses trend, half-window movement, and
    /// uncertainty after detrending.
    func metrics(
        readings: [Float],
        windowSize overrideWindowSize: Int? = nil,
        sampleInterval: Float = 2
    ) -> CalibrationConvergenceMetrics? {
        let selectedWindowSize = overrideWindowSize ?? windowSize
        guard readings.count >= selectedWindowSize, selectedWindowSize >= 4 else {
            return nil
        }
        let window = Array(readings.suffix(selectedWindowSize))
        let count = Float(window.count)

        let mean = window.reduce(0, +) / count
        let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / count
        let rawStandardDeviation = sqrt(variance)

        let xMean = (count - 1) / 2
        var numerator: Float = 0
        var denominator: Float = 0
        for index in window.indices {
            let x = Float(index) - xMean
            let y = window[index] - mean
            numerator += x * y
            denominator += x * x
        }
        let slopePerSample = denominator > 0 ? numerator / denominator : 0
        let slopePerSecond = slopePerSample / sampleInterval

        let residualVariance = window.enumerated().reduce(Float(0)) { partial, item in
            let predicted = mean + slopePerSample * (Float(item.offset) - xMean)
            let residual = item.element - predicted
            return partial + residual * residual
        } / count
        let residualStandardDeviation = sqrt(residualVariance)

        let half = window.count / 2
        let firstMean = window.prefix(half).reduce(0, +) / Float(half)
        let secondCount = window.count - half
        let secondMean = window.suffix(secondCount).reduce(0, +) / Float(secondCount)
        let halfMeanDelta = abs(secondMean - firstMean)

        // Thermal samples are autocorrelated. Treat each five-sample (10s)
        // block as one effective observation.
        let effectiveSampleCount = max(Float(window.count / 5), 2)
        let confidenceRadius95 = 1.96 * residualStandardDeviation
            / sqrt(effectiveSampleCount)

        return CalibrationConvergenceMetrics(
            mean: mean,
            slopePerSecond: slopePerSecond,
            rawStandardDeviation: rawStandardDeviation,
            residualStandardDeviation: residualStandardDeviation,
            halfMeanDelta: halfMeanDelta,
            confidenceRadius95: confidenceRadius95
        )
    }

    func accepts(_ metrics: CalibrationConvergenceMetrics) -> Bool {
        abs(metrics.slopePerSecond) <= maximumSlopePerSecond
            && metrics.halfMeanDelta <= maximumHalfMeanDelta
            && metrics.confidenceRadius95 <= maximumConfidenceRadius
    }

    func format(_ metrics: CalibrationConvergenceMetrics) -> String {
        "mean \(String(format: "%.2f", metrics.mean))°C, "
            + "slope \(String(format: "%+.4f", metrics.slopePerSecond))°C/s, "
            + "half Δ \(String(format: "%.2f", metrics.halfMeanDelta))°C, "
            + "noise σ \(String(format: "%.2f", metrics.residualStandardDeviation))°C, "
            + "95% ±\(String(format: "%.2f", metrics.confidenceRadius95))°C"
    }
}
