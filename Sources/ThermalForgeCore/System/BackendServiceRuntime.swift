import Darwin
import Foundation

/// Liveness checks never advance the recovery work lease.
public final class BackendServiceRuntime {
    let coordinator: BackendCoordinator
    let recovery: RecoveryClient
    var signals: [DispatchSourceSignal] = []
    var health: DispatchSourceTimer?
    private let lock = NSLock()
    private var stopping = false

    public init(coordinator: BackendCoordinator, recovery: RecoveryClient) {
        self.coordinator = coordinator; self.recovery = recovery
    }
    public func start() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.stop(code: 0) }
            source.resume()
            signals.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.thermalforge.recovery.health"))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.recovery.checkConnection() }
            catch { self.stop(code: 1) }
        }
        timer.resume()
        health = timer
    }
    public func stop(code: Int32) {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true
        lock.unlock()
        coordinator.shutdown { exit(code) }
        // A hung hardware call must not leave an unprotected controller alive.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(code) }
    }
}
