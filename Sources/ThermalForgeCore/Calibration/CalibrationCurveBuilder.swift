import Foundation

struct CalibrationCurveBuilder {
    static let targetTemperatures: [Float] = [60, 65, 70, 75, 80, 85]

    let minimumFanPercent: Float

    /// A fitted curve must include measured behavior through 80°C. The 85°C
    /// point remains the hard maximum-fan anchor, but extrapolating every target
    /// from a sweep below the control range produces no useful machine-specific
    /// information.
    func coverageError(
        measurements: [CalibrationEquilibriumMeasurement]
    ) -> String? {
        guard let maximum = measurements
            .map(\.equilibriumTemperature)
            .max()
        else {
            return "No equilibrium temperatures were measured"
        }
        let requiredMaximum = Self.targetTemperatures.dropLast().last ?? 80
        guard maximum >= requiredMaximum else {
            return "Sweep reached only \(String(format: "%.1f", maximum))°C; "
                + "at least \(Int(requiredMaximum))°C is required"
        }
        return nil
    }

    /// Build a monotonically increasing Smart control curve. Higher equilibrium
    /// fan speed means lower equilibrium temperature, so the result inverts that
    /// relationship around the machine's minimum usable fan percentage.
    func build(
        measurements: [CalibrationEquilibriumMeasurement]
    ) -> [CalibrationData.Measurement] {
        guard measurements.count >= 2,
              coverageError(measurements: measurements) == nil
        else {
            return []
        }

        let sorted = measurements.sorted {
            $0.equilibriumTemperature < $1.equilibriumTemperature
        }
        var result: [CalibrationData.Measurement] = []
        var previousControlFan = minimumFanPercent

        for targetTemperature in Self.targetTemperatures {
            let equilibriumFan = interpolatedFanPercent(
                at: targetTemperature,
                measurements: sorted
            )
            var controlFan = (1 + minimumFanPercent) - equilibriumFan
            controlFan = min(max(controlFan, minimumFanPercent), 1)

            // Sensor noise can invert adjacent equilibrium points slightly. A
            // control curve must never slow fans as temperature rises.
            controlFan = max(controlFan, previousControlFan)
            previousControlFan = controlFan
            result.append(.init(
                targetTemp: targetTemperature,
                holdingRPMPercent: controlFan
            ))
        }

        return result
    }

    private func interpolatedFanPercent(
        at temperature: Float,
        measurements: [CalibrationEquilibriumMeasurement]
    ) -> Float {
        guard let first = measurements.first, let last = measurements.last else {
            return 0.5
        }
        if temperature <= first.equilibriumTemperature {
            return first.fanPercent
        }
        if temperature >= last.equilibriumTemperature {
            return last.fanPercent
        }

        for pair in zip(measurements, measurements.dropFirst()) {
            let lower = pair.0
            let upper = pair.1
            guard temperature >= lower.equilibriumTemperature,
                  temperature <= upper.equilibriumTemperature
            else {
                continue
            }
            let fraction = (temperature - lower.equilibriumTemperature)
                / (upper.equilibriumTemperature - lower.equilibriumTemperature)
            return lower.fanPercent + fraction * (upper.fanPercent - lower.fanPercent)
        }
        return last.fanPercent
    }
}
