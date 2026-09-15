import Foundation

protocol CalibrationWorkload: AnyObject {
    var failure: String? { get }
    @discardableResult
    func start(intensity: Float) -> Bool

    @discardableResult
    /// Returns true only when termination is confirmed (including already stopped).
    func stop() -> Bool
}

extension CalibrationWorkload { var failure: String? { nil } }

final class CalibrationWorkloadGroup: CalibrationWorkload {
    private let workloads: [any CalibrationWorkload]
    private let lock = NSLock()
    private var running = false
    private var shutdownIncomplete = false
    var failure: String? { workloads.compactMap(\.failure).first }

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
            guard workload.start(intensity: intensity) else {
                _ = stop() // A failed shutdown is retained and retried by cleanup.
                return false
            }
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
