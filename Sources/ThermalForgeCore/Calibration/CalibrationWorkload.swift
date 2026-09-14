import Foundation

protocol CalibrationWorkload: AnyObject {
    @discardableResult
    func start(intensity: Float) -> Bool

    @discardableResult
    /// Returns true only when termination is confirmed (including already stopped).
    func stop() -> Bool
}

final class CalibrationWorkloadGroup: CalibrationWorkload {
    private let workloads: [any CalibrationWorkload]
    private let lock = NSLock()
    private var running = false
    private var shutdownIncomplete = false

    init(workloads: [any CalibrationWorkload]) {
        self.workloads = workloads
    }

    @discardableResult
    func start(intensity: Float) -> Bool {
        lock.lock()
        guard !running, !shutdownIncomplete else {
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
        let needsStop = running || shutdownIncomplete
        running = false
        lock.unlock()
        guard needsStop else { return true }

        var stopped = true
        for workload in workloads.reversed() {
            if !workload.stop() { stopped = false }
        }
        lock.lock()
        shutdownIncomplete = !stopped
        lock.unlock()
        return stopped
    }
}
