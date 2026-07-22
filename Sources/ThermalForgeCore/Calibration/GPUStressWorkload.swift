import Foundation
import Metal

final class GPUStressWorkload: CalibrationWorkload {
    private let deviceProvider: () -> MTLDevice?
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private var device: MTLDevice?
    private var pipeline: MTLComputePipelineState?
    private var queue: MTLCommandQueue?
    private var buffer: MTLBuffer?
    private var elementCount = 0
    private var _lastWarning: String?

    init(deviceProvider: @escaping () -> MTLDevice? = { MTLCreateSystemDefaultDevice() }) {
        self.deviceProvider = deviceProvider
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var lastWarning: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastWarning
    }

    @discardableResult
    func start(intensity: Float) -> Bool {
        lock.lock()
        guard !running else {
            lock.unlock()
            return false
        }
        running = true
        _lastWarning = nil
        lock.unlock()

        guard let device = deviceProvider() else {
            failStartup("Warning: Metal device not available, running CPU-only stress")
            return false
        }

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void stress(device float *data [[buffer(0)]],
                          uint id [[thread_position_in_grid]]) {
            float x = data[id];
            for (int i = 0; i < 2000; i++) {
                x = sin(x) * cos(x) + tan(x * 0.01);
                x = fma(x, x, float(i) * 0.001);
                x = sqrt(abs(x) + 1.0);
            }
            data[id] = x;
        }
        """

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let function = library.makeFunction(name: "stress"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue()
        else {
            failStartup("Warning: Metal pipeline setup failed, running CPU-only stress")
            return false
        }

        let baseCount = 1024 * 1024 * 4
        let clampedIntensity = min(max(intensity, 0), 1)
        let elementCount = max(Int(Float(baseCount) * clampedIntensity), 1024)
        let bufferSize = elementCount * MemoryLayout<Float>.stride
        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            failStartup("Warning: Metal buffer allocation failed, running CPU-only stress")
            return false
        }

        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: elementCount)
        for index in 0..<elementCount {
            pointer[index] = Float(index % 1000) * 0.001
        }

        let thread = Thread { [weak self] in
            while let resources = self?.dispatchResources() {
                Self.dispatch(resources)
            }
        }
        thread.qualityOfService = .userInteractive

        lock.lock()
        guard running else {
            lock.unlock()
            return false
        }
        self.device = device
        self.pipeline = pipeline
        self.queue = queue
        self.buffer = buffer
        self.elementCount = elementCount
        self.thread = thread
        lock.unlock()
        thread.start()
        return true
    }

    @discardableResult
    func stop() -> Bool {
        lock.lock()
        let wasRunning = running
        running = false
        let activeThread = thread
        lock.unlock()
        guard wasRunning else { return false }

        let deadline = Date().addingTimeInterval(2)
        while activeThread?.isFinished == false, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        lock.lock()
        thread = nil
        buffer = nil
        pipeline = nil
        queue = nil
        device = nil
        elementCount = 0
        lock.unlock()
        return true
    }

    private func dispatchResources() -> (
        pipeline: MTLComputePipelineState,
        queue: MTLCommandQueue,
        buffer: MTLBuffer,
        elementCount: Int
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard running, let pipeline, let queue, let buffer else { return nil }
        return (pipeline, queue, buffer, elementCount)
    }

    private static func dispatch(_ resources: (
        pipeline: MTLComputePipelineState,
        queue: MTLCommandQueue,
        buffer: MTLBuffer,
        elementCount: Int
    )) {
        let groupSize = MTLSize(
            width: resources.pipeline.maxTotalThreadsPerThreadgroup,
            height: 1,
            depth: 1
        )
        let gridSize = MTLSize(width: resources.elementCount, height: 1, depth: 1)
        guard let commandBuffer = resources.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        encoder.setComputePipelineState(resources.pipeline)
        encoder.setBuffer(resources.buffer, offset: 0, index: 0)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: groupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func failStartup(_ warning: String) {
        lock.lock()
        running = false
        _lastWarning = warning
        lock.unlock()
    }
}
