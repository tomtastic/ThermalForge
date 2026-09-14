import Darwin
import Foundation

public final class RecoveryService {
    public static let socketPath = "/var/run/thermalforge-recovery.sock"
    public static let stateDirectory = URL(fileURLWithPath: "/Library/Application Support/ThermalForge/recovery", isDirectory: true)
    public let coordinator: RecoveryCoordinator
    private let listener: UnixSocketListener
    private var timer: DispatchSourceTimer?

    public convenience init(fanControl: FanControl, socketPath: String = RecoveryService.socketPath,
                            stateDirectory: URL = RecoveryService.stateDirectory,
                            authorize: @escaping (AuthenticatedPeer) -> Bool = { $0.uid == 0 }) throws {
        let store = try FileRecoveryMarkerStore(directory: stateDirectory)
        let coordinator = try RecoveryCoordinator(markerStore: store,
            processControl: SystemRecoveryProcessControl(), restore: { fanControl.restoreApple() })
        try self.init(coordinator: coordinator, socketPath: socketPath, authorize: authorize)
    }

    /// Injectable core is used by the subprocess fixtures; production has no
    /// fake-hardware command or environment switch.
    public init(coordinator: RecoveryCoordinator, socketPath: String,
                authorize: @escaping (AuthenticatedPeer) -> Bool = { $0.uid == 0 }) throws {
        self.coordinator = coordinator
        listener = try UnixSocketListener(path: socketPath, mode: 0o600, authorize: authorize) { data, peer in
            guard let request = try? JSONDecoder().decode(RecoveryRequest.self, from: data) else {
                return Data("{\"ok\":false,\"error\":\"invalid request\"}".utf8)
            }
            return (try? JSONEncoder().encode(coordinator.handle(request, peer: peer))) ?? Data()
        }
    }
    public func start() {
        // Complete initial reconciliation before admitting a new backend.
        coordinator.tick()
        listener.start()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.thermalforge.recovery.expiry"))
        timer.schedule(deadline: .now() + BackendTiming.expiryInterval, repeating: BackendTiming.expiryInterval)
        timer.setEventHandler { [coordinator] in coordinator.tick() }
        self.timer = timer
        timer.resume()
    }
    public func stop() { timer?.cancel(); timer = nil; listener.stop() }
    public func run() { start(); RunLoop.main.run() }
    deinit { stop() }
}

public final class RecoveryClient: RecoveryProtecting {
    private let generation: String
    private let transport: (Data) throws -> Data
    private let lock = NSLock()
    public convenience init(generation: String, socketPath: String = RecoveryService.socketPath) throws {
        self.init(generation: generation, transport: {
            try UnixSocketTransport.roundTrip($0, path: socketPath)
        })
        try connect()
    }
    public init(generation: String, transport: @escaping (Data) throws -> Data) {
        self.generation = generation
        self.transport = transport
    }
    public static func inspect(socketPath: String = RecoveryService.socketPath) throws -> RecoverySnapshot {
        let request = RecoveryRequest(generation: "inspection", operation: .inspect)
        let response = try JSONDecoder().decode(RecoveryResponse.self,
            from: UnixSocketTransport.roundTrip(JSONEncoder().encode(request), path: socketPath))
        guard response.ok else { throw RecoveryError.failure(response.error ?? "Recovery inspection failed") }
        return response.snapshot
    }
    public func connect() throws { try send(.connect) }
    public func checkConnection() throws { try send(.status) }
    public func authorizeManual() throws { try send(.authorizeManual) }
    public func completedWork() throws { try send(.completedWork) }
    public func restored() throws { try send(.restored) }
    private func send(_ operation: RecoveryOperation) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(RecoveryRequest(generation: generation, operation: operation))
        let response = try JSONDecoder().decode(RecoveryResponse.self, from: transport(data))
        guard response.ok else { throw RecoveryError.failure(response.error ?? "Recovery denied permission") }
    }
}
