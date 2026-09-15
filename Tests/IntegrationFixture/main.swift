import Darwin
import Foundation
import ThermalForgeCore

private struct FixtureLid: LidStateProvider { let isLidClosed = false }

// This executable is never installed or bundled. Hardware state is owned by
// the parent test broker and survives the death of either subprocess.
private struct BrokerRequest: Codable {
    var operation: String
    var key: String = ""
    var bytes: [UInt8] = []
    var index: UInt32 = 0
    var writer: String
}
private struct BrokerResponse: Codable {
    var success: Bool
    var bytes: [UInt8]
    var size: UInt32
    var type: String
    var key: String?
    var count: UInt32
    var availability: String
}
private final class BrokerSMC: SMCReading {
    let path: String
    let writer: String
    init(path: String, writer: String) { self.path = path; self.writer = writer }
    func exchange(_ operation: String, key: String = "", bytes: [UInt8] = [], index: UInt32 = 0) -> BrokerResponse? {
        let request = BrokerRequest(operation: operation, key: key, bytes: bytes, index: index, writer: writer)
        guard let data = try? JSONEncoder().encode(request),
              let result = try? UnixSocketTransport.roundTrip(data, path: path) else { return nil }
        return try? JSONDecoder().decode(BrokerResponse.self, from: result)
    }
    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32) {
        guard let result = exchange("read", key: key) else { return (false, [], 0) }
        return (result.success, result.bytes, result.size)
    }
    func writeKey(_ key: String, bytes: [UInt8]) -> Bool { exchange("write", key: key, bytes: bytes)?.success ?? false }
    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        guard let result = exchange("info", key: key), result.success else { return nil }
        return (result.size, result.type)
    }
    func keyAvailability(_ key: String) -> SMCKeyAvailability {
        guard let result = exchange("info", key: key) else { return .unknown }
        switch result.availability {
        case "present": return .present(size: result.size)
        case "absent": return .absent
        default: return .unknown
        }
    }
    func getKeyCount() -> UInt32 { exchange("count")?.count ?? 0 }
    func getKeyAtIndex(_ index: UInt32) -> String? { exchange("index", index: index)?.key }
}

private final class FixtureSensors: SensorProvider {
    let fan: FanControl
    let directory: URL
    init(fan: FanControl, directory: URL) { self.fan = fan; self.directory = directory }
    func status() throws -> ThermalStatus {
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("stall-sensors").path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try fan.status()
    }
}

private final class FixtureCalibration: BackendCalibrationRunning {
    let context: BackendCalibrationContext
    let broker: BrokerSMC
    let directory: URL
    init(context: BackendCalibrationContext, broker: BrokerSMC, directory: URL) {
        self.context = context; self.broker = broker; self.directory = directory
    }
    func run() throws -> CalibrationData {
        _ = try context.readStatus()
        try context.apply(.setMax)
        _ = broker.exchange("workload-start")
        while !context.cancellation.isCancelled {
            _ = try context.readStatus()
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CalibrationError.cancelled
    }
    func stopWorkloads() -> Bool {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("fail-workload-stop").path) {
            _ = broker.exchange("workload-stop-failed")
            return false
        }
        _ = broker.exchange("workload-stopped")
        return true
    }
}

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("fixture <backend|recovery|owner> <isolated-directory> <broker-socket>") }
let role = args[1]
let directory = URL(fileURLWithPath: args[2], isDirectory: true)
private let broker = BrokerSMC(path: args[3], writer: role)
let recoveryPath = directory.appendingPathComponent("r.sock").path
let backendPath = directory.appendingPathComponent("b.sock").path
let fan = FanControl(smc: broker)

do {
    if role == "recovery" {
        try RecoveryService(fanControl: fan, socketPath: recoveryPath,
            stateDirectory: directory.appendingPathComponent("recovery"), authorize: { $0.uid == getuid() }).run()
    } else if role == "backend" {
        let generation = UUID().uuidString
        let recovery = try RecoveryClient(generation: generation, socketPath: recoveryPath)
        let coordinator = BackendCoordinator(sensorProvider: FixtureSensors(fan: fan, directory: directory),
            actuator: fan, recovery: recovery,
            configurationStore: BackendConfigurationStore(directory: directory.appendingPathComponent("users")),
            calibrationStore: BackendCalibrationStore(directory: directory, legacyRoot: nil),
            lidStateProvider: FixtureLid(),
            generation: generation, calibrationFactory: { context in
                FixtureCalibration(context: context, broker: broker, directory: directory)
            }, configurationUID: { $0.uid }, onFatalFailure: { _ in exit(3) })
        let runtime = BackendServiceRuntime(coordinator: coordinator, recovery: recovery)
        let router = BackendRequestRouter(backend: coordinator)
        let listener = try UnixSocketListener(path: backendPath, authorize: { $0.uid == getuid() }, handler: router.handle)
        coordinator.start(interval: 0.1)
        runtime.start()
        listener.start()
        RunLoop.main.run()
        withExtendedLifetime((coordinator, runtime, listener)) {}
    } else if role == "owner" {
        func send(_ request: BackendRequest) throws -> BackendResponse {
            try JSONDecoder().decode(BackendResponse.self, from:
                UnixSocketTransport.roundTrip(JSONEncoder().encode(request), path: backendPath))
        }
        let initial = try send(BackendRequest(operation: .status))
        guard let generation = initial.snapshot?.generation else { exit(4) }
        let session = ControlSession(generation: generation)
        let calibration = FileManager.default.fileExists(atPath: directory.appendingPathComponent("owner-calibration").path)
        let acquired = try send(BackendRequest(operation: calibration ? .startCalibration : .acquire,
            session: session, clientKind: .cli, intent: calibration ? nil : .maximum,
            calibration: calibration ? .init(mode: "quick") : nil))
        guard acquired.ok else { exit(5) }
        while true {
            Thread.sleep(forTimeInterval: 1)
            guard try send(BackendRequest(operation: .renew, session: session)).ok else { exit(6) }
        }
    } else { exit(2) }
} catch {
    FileHandle.standardError.write(Data("fixture failed: \(error)\n".utf8))
    exit(1)
}
