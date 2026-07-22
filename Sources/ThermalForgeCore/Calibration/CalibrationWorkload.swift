import Foundation

protocol CalibrationWorkload: AnyObject {
    @discardableResult
    func start(intensity: Float) -> Bool

    @discardableResult
    func stop() -> Bool
}

final class CalibrationWorkloadGroup: CalibrationWorkload {
    private let workloads: [any CalibrationWorkload]
    private let lock = NSLock()
    private var running = false

    init(workloads: [any CalibrationWorkload]) {
        self.workloads = workloads
    }

    @discardableResult
    func start(intensity: Float) -> Bool {
        lock.lock()
        guard !running else {
            lock.unlock()
            return false
        }
        running = true
        lock.unlock()

        for workload in workloads {
            workload.start(intensity: intensity)
        }
        return true
    }

    @discardableResult
    func stop() -> Bool {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return false }

        for workload in workloads.reversed() {
            workload.stop()
        }
        return true
    }
}
