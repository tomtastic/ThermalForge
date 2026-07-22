import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Lid state provider")
struct LidStateProviderTests {
    @Test("Hardware state takes precedence over screen topology")
    func hardwareStateTakesPrecedence() {
        let closed = MacLidStateProvider(
            hardwareState: { true },
            screenFallback: { false }
        )
        let open = MacLidStateProvider(
            hardwareState: { false },
            screenFallback: { true }
        )

        #expect(closed.isLidClosed)
        #expect(!open.isLidClosed)
    }

    @Test("Screen topology is used only when hardware state is unavailable")
    func screenFallback() {
        let provider = MacLidStateProvider(
            hardwareState: { nil },
            screenFallback: { true }
        )

        #expect(provider.isLidClosed)
    }

    @Test("Injected lid state selects the matching calibration")
    func injectedStateSelectsCalibration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let openPath = directory.appendingPathComponent("open.json")
        let closedPath = directory.appendingPathComponent("closed.json")
        try JSONEncoder().encode(calibration(lidClosed: false)).write(to: openPath)
        try JSONEncoder().encode(calibration(lidClosed: true)).write(to: closedPath)

        let selected = CalibrationData.load(
            lidStateProvider: FixedLidStateProvider(isLidClosed: true),
            pathForLidState: { $0 ? closedPath : openPath }
        )

        #expect(selected?.lidClosed == true)
        #expect(selected?.machine == "ClosedMac")
    }

    private func calibration(lidClosed: Bool) -> CalibrationData {
        CalibrationData(
            machine: lidClosed ? "ClosedMac" : "OpenMac",
            fans: 2,
            maxRPM: 8_000,
            minRPM: 2_000,
            calibratedAt: "2026-07-22T00:00:00Z",
            lidClosed: lidClosed,
            measurements: [
                .init(targetTemp: 60, holdingRPMPercent: 0.5),
                .init(targetTemp: 80, holdingRPMPercent: 0.9),
            ]
        )
    }
}

private struct FixedLidStateProvider: LidStateProvider {
    let isLidClosed: Bool
}
