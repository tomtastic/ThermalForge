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
}
