import Darwin
import Foundation

protocol ThermalAnomalyObserving: AnyObject {
    func observe(
        status: ThermalStatus,
        maxTemp: Float,
        profileName: String,
        isCalibrating: Bool
    )
}

final class ThermalAnomalyObserver: ThermalAnomalyObserving {
    private struct ProcessSnapshot {
        let timestamp: String
        let processes: String
    }

    private let processCaptureFloor: Float
    private let historyCapacity: Int
    private let captureProcesses: () -> String
    private let timestamp: () -> String
    private let log: (String) -> Void

    private var temperatureHistory: [Float] = []
    private var processHistory: [ProcessSnapshot] = []

    convenience init() {
        let formatter = ISO8601DateFormatter()
        self.init(
            processCaptureFloor: 50,
            historyCapacity: 15,
            captureProcesses: Self.captureTopProcesses,
            timestamp: { formatter.string(from: Date()) },
            log: { TFLogger.shared.info($0) }
        )
    }

    init(
        processCaptureFloor: Float,
        historyCapacity: Int,
        captureProcesses: @escaping () -> String,
        timestamp: @escaping () -> String,
        log: @escaping (String) -> Void
    ) {
        self.processCaptureFloor = processCaptureFloor
        self.historyCapacity = historyCapacity
        self.captureProcesses = captureProcesses
        self.timestamp = timestamp
        self.log = log
    }

    func observe(
        status: ThermalStatus,
        maxTemp: Float,
        profileName: String,
        isCalibrating: Bool
    ) {
        updateProcessHistory(maxTemp: maxTemp)

        if !isCalibrating {
            detectAnomaly(
                status: status,
                maxTemp: maxTemp,
                profileName: profileName
            )
        }

        temperatureHistory.append(maxTemp)
        if temperatureHistory.count > historyCapacity {
            temperatureHistory.removeFirst()
        }
    }

    private func updateProcessHistory(maxTemp: Float) {
        if maxTemp >= processCaptureFloor {
            processHistory.append(ProcessSnapshot(
                timestamp: timestamp(),
                processes: captureProcesses()
            ))
            if processHistory.count > historyCapacity {
                processHistory.removeFirst()
            }
        } else if !processHistory.isEmpty {
            processHistory.removeAll()
        }
    }

    private func detectAnomaly(
        status: ThermalStatus,
        maxTemp: Float,
        profileName: String
    ) {
        var spikeDetected = false

        if let previousTemp = temperatureHistory.last {
            let instantDelta = maxTemp - previousTemp
            if abs(instantDelta) > 5 {
                let direction = instantDelta > 0 ? "spike" : "drop"
                let fan = status.fans.first
                log(
                    "Instant \(direction): \(String(format: "%.1f", previousTemp))→\(String(format: "%.1f", maxTemp))°C "
                        + "(\(String(format: "%+.1f", instantDelta))°C in 2s) | "
                        + "Fan0: \(fan?.actualRPM ?? 0) RPM (\(fan?.mode ?? "?")) | "
                        + "Profile: \(profileName)"
                )
                spikeDetected = true
            }
        }

        if temperatureHistory.count >= historyCapacity,
           let oldestTemp = temperatureHistory.first
        {
            let sustainedDelta = maxTemp - oldestTemp
            if abs(sustainedDelta) > 10 {
                let direction = sustainedDelta > 0 ? "spike" : "drop"
                let fan = status.fans.first
                log(
                    "Sustained \(direction): \(String(format: "%.1f", oldestTemp))→\(String(format: "%.1f", maxTemp))°C "
                        + "(\(String(format: "%+.1f", sustainedDelta))°C in 30s) | "
                        + "Fan0: \(fan?.actualRPM ?? 0) RPM (\(fan?.mode ?? "?")) | "
                        + "Profile: \(profileName)"
                )
                spikeDetected = true
                temperatureHistory.removeAll()
            }
        }

        if spikeDetected {
            log("Pre-spike process history (last \(processHistory.count) samples):")
            for entry in processHistory {
                log("  \(entry.timestamp): \(entry.processes)")
            }
        }
    }

    private static func captureTopProcesses() -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return "unavailable"
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else {
            return "unavailable"
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var results: [(name: String, cpu: Double)] = []

        for index in 0..<actualCount {
            let process = processes[index]
            let pid = process.kp_proc.p_pid
            guard pid > 0 else { continue }

            let name = withUnsafePointer(to: process.kp_proc.p_comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            guard !name.isEmpty, name != "kernel_task" else { continue }
            let cpuPercent = Double(process.kp_proc.p_pctcpu) / 100.0
            if cpuPercent > 0.1 {
                results.append((name, cpuPercent))
            }
        }

        let topProcesses = results.sorted { $0.cpu > $1.cpu }.prefix(5)
        if topProcesses.isEmpty { return "idle" }
        return topProcesses.map {
            "\($0.name)(\(String(format: "%.1f", $0.cpu))%)"
        }.joined(separator: ", ")
    }
}
