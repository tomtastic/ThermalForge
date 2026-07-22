struct CalibrationTemperatureSelector {
    let stressType: CalibrationStressType

    /// Select the sensor family matching the generated workload. Combined
    /// calibration follows the hotter CPU/GPU family, matching Smart's input.
    func select(from temperatures: [String: Float]) -> CalibrationTemperatureSample? {
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

    func ambient(from temperatures: [String: Float]) -> Float? {
        TemperatureSummary(temperatures).ambient
    }
}
