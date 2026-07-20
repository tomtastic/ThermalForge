import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Calibration selection")
struct CalibrationSelectionTests {
    private func calibration(lidClosed: Bool) -> CalibrationData {
        CalibrationData(
            machine: "TestMac",
            fans: 2,
            maxRPM: 6000,
            minRPM: 2000,
            calibratedAt: "2026-07-20T00:00:00Z",
            lidClosed: lidClosed,
            measurements: [
                .init(targetTemp: 60, holdingRPMPercent: 0.4),
                .init(targetTemp: 80, holdingRPMPercent: 0.8),
            ]
        )
    }

    @Test("Missing calibration for requested lid state is uncalibrated")
    func missingStateIsUncalibrated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyPath = directory.appendingPathComponent("calibration.json")
        try JSONEncoder().encode(calibration(lidClosed: false)).write(to: legacyPath)

        let missingClosedPath = directory.appendingPathComponent("calibration_lid_closed.json")
        #expect(CalibrationData.load(forLidClosed: true, from: missingClosedPath) == nil)
    }

    @Test("Calibration must match the requested lid state")
    func mismatchedStateIsRejected() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }

        try JSONEncoder().encode(calibration(lidClosed: false)).write(to: path)

        #expect(CalibrationData.load(forLidClosed: true, from: path) == nil)
        #expect(CalibrationData.load(forLidClosed: false, from: path)?.lidClosed == false)
    }

    @Test("Reset covers root and console-user calibration files")
    func resetCoversBothHomes() throws {
        let rootHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootHome)
            try? FileManager.default.removeItem(at: userHome)
        }

        let paths = CalibrationData.resetFilePaths(currentHome: rootHome, consoleHome: userHome)
        #expect(paths.count == 6)
        #expect(paths.contains(CalibrationData.filePath(forLidClosed: false, homeDirectory: rootHome)))
        #expect(paths.contains(CalibrationData.filePath(forLidClosed: true, homeDirectory: userHome)))

        for path in paths {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: path)
        }

        let removed = try CalibrationData.removeCalibrationFiles(at: paths)
        #expect(Set(removed) == Set(paths))
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("Legacy settle-time metadata remains decodable")
    func legacySettleTimeIsIgnored() throws {
        let json = """
        {
          "machine": "TestMac",
          "fans": 2,
          "maxRPM": 6000,
          "minRPM": 2000,
          "calibratedAt": "2026-07-20T00:00:00Z",
          "lidClosed": false,
          "measurements": [
            {"targetTemp": 60, "holdingRPMPercent": 0.4, "settleTime": 120}
          ]
        }
        """

        let calibration = try JSONDecoder().decode(CalibrationData.self, from: Data(json.utf8))
        #expect(calibration.measurements.first?.targetTemp == 60)
        #expect(calibration.measurements.first?.holdingRPMPercent == 0.4)
    }
}

@Suite("Calibration workload and convergence")
struct CalibrationConvergenceTests {
    @Test("Calibration metadata preserves reusable workload intensity")
    func reusableWorkloadMetadataRoundTrips() throws {
        let original = CalibrationData(
            machine: "TestMac",
            fans: 2,
            maxRPM: 7800,
            minRPM: 2300,
            calibratedAt: "2026-07-20T00:00:00Z",
            mode: "optimized",
            stressType: "combined",
            workloadIntensity: 0.00221,
            ambientTemperature: 30.4,
            measurements: [
                .init(targetTemp: 60, holdingRPMPercent: 0.58),
                .init(targetTemp: 80, holdingRPMPercent: 0.95),
            ]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CalibrationData.self, from: encoded)

        #expect(decoded.stressType == "combined")
        #expect(decoded.workloadIntensity == 0.00221)
        #expect(decoded.ambientTemperature == 30.4)
    }

    @Test("Low CPU intensities use a fractional worker without a one-core jump")
    func fractionalCPUStressPlan() {
        let veryLow = CalibrationRunner.cpuStressPlan(intensity: 0.003, coreCount: 16)
        #expect(veryLow.fullThreads == 0)
        #expect(abs(veryLow.fractionalDutyCycle - 0.048) < 0.0001)

        let initialProbe = CalibrationRunner.cpuStressPlan(intensity: 0.05, coreCount: 16)
        #expect(initialProbe.fullThreads == 0)
        #expect(abs(initialProbe.fractionalDutyCycle - 0.8) < 0.0001)

        let higher = CalibrationRunner.cpuStressPlan(intensity: 0.10, coreCount: 16)
        #expect(higher.fullThreads == 1)
        #expect(abs(higher.fractionalDutyCycle - 0.6) < 0.0001)
    }

    @Test("All-maximum calibration curves are rejected")
    func allMaximumCurveIsInvalid() {
        let calibration = CalibrationData(
            machine: "TestMac",
            fans: 2,
            maxRPM: 7800,
            minRPM: 2300,
            calibratedAt: "2026-07-20T00:00:00Z",
            mode: "optimized",
            measurements: [60, 65, 70, 75, 80, 85].map {
                .init(targetTemp: Float($0), holdingRPMPercent: 1)
            }
        )

        #expect(!calibration.isValid)
        #expect(calibration.validationError?.contains("maximum fan speed") == true)
    }

    @Test("A sweep below the Smart control range is rejected")
    func insufficientTemperatureCoverageIsRejected() {
        let rawData: [(fanPct: Float, equilTemp: Float)] = [
            (1.0, 50.8),
            (0.8, 51.6),
            (0.6, 52.7),
            (0.45, 54.4),
            (0.29, 58.1),
        ]

        #expect(CalibrationRunner.temperatureCoverageError(rawData: rawData) != nil)
        #expect(CalibrationRunner.buildControlCurve(rawData: rawData, minPct: 0.29).isEmpty)
    }

    @Test("Calibration selects temperatures that match the stress source")
    func stressSpecificTemperatureSelection() {
        let temperatures: [String: Float] = [
            "TC0P": 62,
            "Tp01": 64,
            "TG0P": 71,
        ]

        #expect(CalibrationRunner.calibrationTemperature(from: temperatures, stressType: .cpu)?.selected == 64)
        #expect(CalibrationRunner.calibrationTemperature(from: temperatures, stressType: .gpu)?.selected == 71)
        #expect(CalibrationRunner.calibrationTemperature(from: temperatures, stressType: .combined)?.selected == 71)
    }

    @Test("Stable noisy readings converge after detrending")
    func stableNoiseConverges() throws {
        let readings: [Float] = (0..<30).map { $0.isMultiple(of: 2) ? 59.5 : 60.5 }
        let metrics = try #require(CalibrationRunner.stabilityMetrics(readings: readings))

        #expect(metrics.rawStandardDeviation >= 0.5)
        #expect(CalibrationMode.optimized.acceptsStability(metrics))
    }

    @Test("Smooth temperature drift is not accepted as equilibrium")
    func driftDoesNotConverge() throws {
        let readings: [Float] = (0..<30).map { 58 + Float($0) * 0.05 }
        let metrics = try #require(CalibrationRunner.stabilityMetrics(readings: readings))

        #expect(metrics.residualStandardDeviation < 0.001)
        #expect(!CalibrationMode.optimized.acceptsStability(metrics))
    }

    @Test("Old transients age out of the convergence window")
    func convergenceUsesRecentWindow() throws {
        let transient: [Float] = [64, 66, 63, 65, 62, 64]
        let plateau = [Float](repeating: 59, count: 30)
        let metrics = try #require(CalibrationRunner.stabilityMetrics(readings: transient + plateau))

        #expect(metrics.mean == 59)
        #expect(CalibrationMode.optimized.acceptsStability(metrics))
    }

    @Test("Generated control curve never slows fans as temperature rises")
    func generatedCurveIsMonotonic() {
        let measurements = CalibrationRunner.buildControlCurve(
            rawData: [
                (fanPct: 1.0, equilTemp: 61.1),
                (fanPct: 0.8, equilTemp: 60.5),
                (fanPct: 0.6, equilTemp: 71.8),
                (fanPct: 0.45, equilTemp: 74.8),
                (fanPct: 0.29, equilTemp: 84.0),
            ],
            minPct: 0.29
        )

        for pair in zip(measurements, measurements.dropFirst()) {
            #expect(pair.1.holdingRPMPercent >= pair.0.holdingRPMPercent)
        }
    }
}
