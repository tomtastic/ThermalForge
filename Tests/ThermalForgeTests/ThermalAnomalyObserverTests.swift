import Testing

@testable import ThermalForgeCore

@Suite("Thermal anomaly observer")
struct ThermalAnomalyObserverTests {
    @Test("Instant spikes include the buffered process history")
    func instantSpike() {
        let recorder = AnomalyRecorder()
        let observer = makeObserver(recorder: recorder)

        observer.observe(status: status(), maxTemp: 60, profileName: "Smart", isCalibrating: false)
        observer.observe(status: status(), maxTemp: 66, profileName: "Smart", isCalibrating: false)

        #expect(recorder.captureCount == 2)
        #expect(recorder.messages.contains { $0.contains("Instant spike: 60.0→66.0°C") })
        #expect(recorder.messages.contains("Pre-spike process history (last 2 samples):"))
        #expect(recorder.messages.contains { $0.contains("compile(75.0%)") })
        #expect(recorder.messages.contains { $0.contains("Profile: Smart") })
    }

    @Test("Calibration suppresses anomaly messages while retaining history")
    func calibrationSuppression() {
        let recorder = AnomalyRecorder()
        let observer = makeObserver(recorder: recorder)

        observer.observe(status: status(), maxTemp: 60, profileName: "Smart", isCalibrating: true)
        observer.observe(status: status(), maxTemp: 70, profileName: "Smart", isCalibrating: true)
        observer.observe(status: status(), maxTemp: 71, profileName: "Smart", isCalibrating: false)

        #expect(recorder.captureCount == 3)
        #expect(recorder.messages.isEmpty)
    }

    @Test("Sustained changes use bounded temperature and process histories")
    func sustainedChange() {
        let recorder = AnomalyRecorder()
        let observer = makeObserver(recorder: recorder, historyCapacity: 3)

        for temperature: Float in [60, 64, 68, 72] {
            observer.observe(
                status: status(),
                maxTemp: temperature,
                profileName: "Balanced",
                isCalibrating: false
            )
        }

        #expect(recorder.messages.contains { $0.contains("Sustained spike: 60.0→72.0°C") })
        #expect(recorder.messages.contains("Pre-spike process history (last 3 samples):"))
    }

    private func makeObserver(
        recorder: AnomalyRecorder,
        historyCapacity: Int = 15
    ) -> ThermalAnomalyObserver {
        ThermalAnomalyObserver(
            processCaptureFloor: 50,
            historyCapacity: historyCapacity,
            captureProcesses: {
                recorder.captureCount += 1
                return "compile(75.0%)"
            },
            timestamp: { "2026-07-22T14:00:00Z" },
            log: { recorder.messages.append($0) }
        )
    }

    private func status() -> ThermalStatus {
        ThermalStatus(
            fans: [
                ThermalStatus.FanStatus(
                    index: 0,
                    actualRPM: 4000,
                    targetRPM: 4000,
                    minRPM: 2000,
                    maxRPM: 8000,
                    mode: "forced"
                ),
            ],
            temperatures: [:]
        )
    }
}

private final class AnomalyRecorder {
    var captureCount = 0
    var messages: [String] = []
}
