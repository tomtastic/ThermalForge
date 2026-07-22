import Foundation

struct CalibrationCPUStressPlan: Equatable {
    let fullThreads: Int
    let fractionalDutyCycle: Float
}

final class CPUStressWorkload: CalibrationWorkload {
    private let lock = NSLock()
    private var running = false
    private var threads: [Thread] = []

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    @discardableResult
    func start(intensity: Float) -> Bool {
        start(intensity: intensity, coreCount: ProcessInfo.processInfo.activeProcessorCount)
    }

    @discardableResult
    func start(
        intensity: Float,
        coreCount: Int
    ) -> Bool {
        lock.lock()
        guard !running else {
            lock.unlock()
            return false
        }
        running = true
        lock.unlock()

        let plan = Self.plan(intensity: intensity, coreCount: coreCount)
        for _ in 0..<plan.fullThreads {
            startWorker(dutyCycle: 1)
        }
        if plan.fractionalDutyCycle > 0 {
            startWorker(dutyCycle: plan.fractionalDutyCycle)
        }
        return true
    }

    @discardableResult
    func stop() -> Bool {
        stop(timeout: 2)
    }

    @discardableResult
    func stop(timeout: TimeInterval) -> Bool {
        lock.lock()
        let wasRunning = running
        running = false
        let activeThreads = threads
        lock.unlock()
        guard wasRunning else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while activeThreads.contains(where: { !$0.isFinished }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        lock.lock()
        threads.removeAll(where: \.isFinished)
        lock.unlock()
        return true
    }

    static func plan(intensity: Float, coreCount: Int) -> CalibrationCPUStressPlan {
        let clampedIntensity = min(max(intensity, 0), 1)
        let desiredCoreLoad = clampedIntensity * Float(max(coreCount, 1))
        let fullThreads = Int(desiredCoreLoad.rounded(.down))
        return CalibrationCPUStressPlan(
            fullThreads: fullThreads,
            fractionalDutyCycle: desiredCoreLoad - Float(fullThreads)
        )
    }

    private func startWorker(dutyCycle: Float) {
        let clampedDuty = min(max(dutyCycle, 0), 1)
        // Fine-grained fractional work avoids brief full-power single-core
        // bursts dominating peak CPU sensors at very low total intensities.
        let isFullWorker = clampedDuty >= 0.999
        let period: TimeInterval = isFullWorker ? 0.1 : 0.01
        let activeDuration = period * Double(clampedDuty)
        let workIterations = isFullWorker ? 10_000 : 250

        let thread = Thread { [weak self] in
            while self?.isRunning == true {
                let cycleStart = Date()
                repeat {
                    var x: Double = 1
                    for i in 1...workIterations {
                        x = sin(x) * cos(Double(i))
                    }
                    _ = x
                } while self?.isRunning == true
                    && Date().timeIntervalSince(cycleStart) < activeDuration

                let remaining = period - Date().timeIntervalSince(cycleStart)
                if remaining > 0 {
                    Thread.sleep(forTimeInterval: remaining)
                }
            }
        }
        thread.qualityOfService = .userInteractive

        lock.lock()
        threads.append(thread)
        lock.unlock()
        thread.start()
    }

    deinit {
        stop()
    }
}
