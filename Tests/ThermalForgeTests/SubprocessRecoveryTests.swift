import Darwin
import Foundation
import Testing
@testable import ThermalForgeCore

private struct BrokerCommand: Codable {
    var operation: String
    var key: String
    var bytes: [UInt8]
    var index: UInt32
    var writer: String
}
private struct BrokerReply: Codable {
    var success = true
    var bytes: [UInt8] = []
    var size: UInt32 = 0
    var type = "ui8 "
    var key: String?
    var count: UInt32 = 0
    var availability = "absent"
}
private final class HardwareBroker: @unchecked Sendable {
    struct Entry {
        let operation: String
        let writer: String
        let pid: Int32
        let key: String
        let bytes: [UInt8]
    }
    private let lock = NSLock()
    private var keys: [String: [UInt8]] = [:]
    private var entries: [Entry] = []
    private var failures: Set<String> = []
    private var unknown: Set<String> = []
    private var ignoredTargets: Set<String> = []
    private var backendIdentity: BackendProcessIdentity?
    private var orderingErrors: [String] = []
    let directory: URL
    var listener: UnixSocketListener!
    let modeTemplate: String

    init(directory: URL, lowerMode: Bool = false, ftst: Bool = false) throws {
        self.directory = directory
        modeTemplate = lowerMode ? "F%dmd" : "F%dMd"
        keys["FNum"] = [2]
        for fan in 0..<2 {
            keys[String(format: modeTemplate, fan)] = [0]
            for (suffix, rpm) in [("Ac", Float(2500)), ("Tg", 0), ("Mn", 2000), ("Mx", 6000)] {
                keys["F\(fan)\(suffix)"] = withUnsafeBytes(of: rpm) { Array($0) }
            }
        }
        keys["Tp01"] = withUnsafeBytes(of: Float(60)) { Array($0) }
        keys["Tg0f"] = withUnsafeBytes(of: Float(55)) { Array($0) }
        if ftst { keys["Ftst"] = [0] }
        listener = try UnixSocketListener(path: directory.appendingPathComponent("h.sock").path,
            authorize: { $0.uid == getuid() }, handler: { [weak self] data, peer in
                guard let self, let command = try? JSONDecoder().decode(BrokerCommand.self, from: data) else { return Data() }
                return (try? JSONEncoder().encode(self.handle(command, peer: peer))) ?? Data()
            })
        listener.start()
    }
    func handle(_ command: BrokerCommand, peer: AuthenticatedPeer) -> BrokerReply {
        lock.lock(); defer { lock.unlock() }
        entries.append(.init(operation: command.operation, writer: command.writer,
                             pid: peer.pid, key: command.key, bytes: command.bytes))
        var reply = BrokerReply()
        let bytes = keys[command.key]
        reply.bytes = bytes ?? []
        reply.size = UInt32(reply.bytes.count)
        reply.availability = unknown.contains(command.key) ? "unknown" : (bytes == nil ? "absent" : "present")
        reply.type = reply.size == 4 ? "flt " : "ui8 "
        reply.success = bytes != nil && !unknown.contains(command.key)
        switch command.operation {
        case "read", "info": break
        case "write":
            if command.writer == "recovery", let backendIdentity,
               SystemRecoveryProcessControl().state(of: backendIdentity) != .exited {
                orderingErrors.append("Independent write before controller exit: \(command.key)")
            }
            let manualWrite = (command.bytes == [1] && (command.key == "Ftst" || command.key.hasSuffix("Md") || command.key.hasSuffix("md")))
                || (command.key.hasSuffix("Tg") && command.bytes.count == 4 && smcBytesToFloat(command.bytes, size: 4) > 0)
            if command.writer == "backend", manualWrite {
                let marker = (try? Data(contentsOf: directory.appendingPathComponent("recovery/recovery.json")))
                    .flatMap { try? JSONDecoder().decode(RecoveryMarker.self, from: $0) }
                if marker?.requiresProtection != true || marker?.identity != backendIdentity {
                    orderingErrors.append("Manual write before durable permission for this backend")
                }
            }
            if failures.contains(command.key), command.bytes == [0] { reply.success = false }
            let ignored = ignoredTargets.contains(command.key) && command.bytes.count == 4
                && smcBytesToFloat(command.bytes, size: 4) > 0
            if reply.success, !ignored { keys[command.key] = command.bytes }
        case "count": reply.count = UInt32(keys.count); reply.success = true
        case "index":
            let names = keys.keys.sorted()
            reply.key = Int(command.index) < names.count ? names[Int(command.index)] : nil
            reply.success = reply.key != nil
        default: reply.success = true
        }
        return reply
    }
    func track(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        backendIdentity = SystemRecoveryProcessControl().identity(pid: process.processIdentifier)
    }
    func failRestoration(_ key: String, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled { failures.insert(key) } else { failures.remove(key) }
    }
    func unreadable(_ key: String, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled { unknown.insert(key) } else { unknown.remove(key) }
    }
    func ignoreTarget(_ key: String) {
        lock.lock(); defer { lock.unlock() }; ignoredTargets.insert(key)
    }
    func setTemperature(_ value: Float) {
        lock.lock(); defer { lock.unlock() }
        keys["Tp01"] = withUnsafeBytes(of: value) { Array($0) }
    }
    func manual() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (0..<2).allSatisfy { keys[String(format: modeTemplate, $0)] == [1] }
    }
    func automatic() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (0..<2).allSatisfy { keys[String(format: modeTemplate, $0)] == [0] } && (keys["Ftst"] == nil || keys["Ftst"] == [0])
    }
    func journal() -> [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    func errors() -> [String] { lock.lock(); defer { lock.unlock() }; return orderingErrors }
    deinit { listener.stop() }
}

private final class ServiceFixture {
    let directory: URL
    let broker: HardwareBroker
    private(set) var processes: [Process] = []
    private var errorLogs: [URL] = []
    var backend: Process!
    var recovery: Process!
    let executable: URL

    init(lowerMode: Bool = false, ftst: Bool = false) throws {
        directory = URL(fileURLWithPath: "/private/tmp/tf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        broker = try HardwareBroker(directory: directory, lowerMode: lowerMode, ftst: ftst)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let candidates = [repository.appendingPathComponent(".build/\(configuration.lowercased())/ThermalForgeFixture"),
                          repository.appendingPathComponent(".build/out/Products/\(configuration)/ThermalForgeFixture")]
        executable = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }, "Build the test-only ThermalForgeFixture target")
    }
    func spawn(_ role: String) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = [role, directory.path, directory.appendingPathComponent("h.sock").path]
        process.standardOutput = FileHandle.nullDevice
        let log = directory.appendingPathComponent("\(role)-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorFile = try FileHandle(forWritingTo: log)
        defer { try? errorFile.close() }
        process.standardError = errorFile
        try process.run()
        processes.append(process)
        errorLogs.append(log)
        return process
    }
    func start() throws {
        recovery = try spawn("recovery")
        try waitFor { (try? self.recoveryState().ready) == true }
        backend = try spawn("backend")
        broker.track(backend)
        try waitFor { (try? self.status().restoration) == .verified }
    }
    func recoveryState() throws -> RecoverySnapshot {
        try RecoveryClient.inspect(socketPath: directory.appendingPathComponent("r.sock").path)
    }
    func send(_ request: BackendRequest) throws -> BackendResponse {
        try JSONDecoder().decode(BackendResponse.self, from:
            UnixSocketTransport.roundTrip(JSONEncoder().encode(request), path: directory.appendingPathComponent("b.sock").path))
    }
    func status() throws -> BackendSnapshot { try #require(send(.init(operation: .status)).snapshot) }
    func acquire(calibration: Bool = false) throws -> ControlSession {
        let session = ControlSession(generation: try status().generation)
        let response = try send(.init(operation: calibration ? .startCalibration : .acquire,
            session: session, clientKind: .cli, intent: calibration ? nil : .maximum,
            calibration: calibration ? .init(mode: "quick") : nil))
        #expect(response.ok, "\(String(describing: response.error))")
        try waitFor { self.broker.manual() }
        return session
    }
    func waitFor(timeout: TimeInterval = 8, _ condition: () throws -> Bool) throws {
        let deadline = BackendTiming.monotonicNow + timeout
        while BackendTiming.monotonicNow < deadline {
            if (try? condition()) == true { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        struct Expired: Error {}
        let exits = processes.filter { !$0.isRunning }.map { "pid \($0.processIdentifier): exit \($0.terminationStatus)" }
        let errors = errorLogs.compactMap { try? Data(contentsOf: $0) }
            .map { String(decoding: $0.suffix(4096), as: UTF8.self) }
        Issue.record("Timed out waiting for isolated service state. \((exits + errors).joined(separator: "; "))")
        throw Expired()
    }
    func flag(_ name: String) throws { try Data().write(to: directory.appendingPathComponent(name)) }
    func stop(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }
    deinit {
        for process in processes.reversed() { stop(process) }
        broker.listener.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Subprocess backend and independent recovery", .serialized)
struct SubprocessRecoveryTests {
    @Test("Hardware failure cannot restart GUI control, including a missed error across backend restart",
          arguments: [false, true])
    func failedTargetCannotAutomaticallyReacquire(_ restart: Bool) async throws {
        let fixture = try ServiceFixture(lowerMode: true)
        try fixture.start()
        fixture.broker.setTemperature(96)
        fixture.broker.ignoreTarget("F1Tg") // first fan succeeds; second reports success without applying
        let client = BackendClient(kind: .gui, socketPath: fixture.directory.appendingPathComponent("b.sock").path)
        _ = try await client.acquire(.profile("smart"))
        try fixture.waitFor {
            let state = try fixture.status()
            return state.controlError != nil && state.restoration == .verified
        }
        let error = try #require(fixture.status().controlError)
        #expect(error.contains("F1Tg"))
        #expect(fixture.broker.automatic())
        let writes = fixture.broker.journal().filter { $0.operation == "write" && $0.key.hasSuffix("Tg") && smcBytesToFloat($0.bytes, size: 4) > 0 }.count
        #expect(writes == 2)
        if restart {
            // The GUI never sees the failed snapshot. Durable revocation still
            // prevents its reconnection policy from retrying on a new backend.
            fixture.stop(fixture.backend)
            try fixture.waitFor { try fixture.recoveryState().ready && fixture.recoveryState().generation == nil }
            fixture.backend = try fixture.spawn("backend")
            fixture.broker.track(fixture.backend)
            try fixture.waitFor { (try? fixture.status().restoration) == .verified }
            do {
                _ = try await client.maintain()
                Issue.record("A missed hardware failure must revoke automatic recovery")
            } catch let DaemonError.commandFailed(code, _) {
                #expect(code == "recoveryRevoked")
            }
        } else {
            #expect(try await client.maintain().controlError == error)
        }
        for _ in 0..<3 { _ = try await client.maintain() }
        #expect(await client.ownsControl == false)
        #expect(fixture.broker.journal().filter { $0.operation == "write" && $0.key.hasSuffix("Tg") && smcBytesToFloat($0.bytes, size: 4) > 0 }.count == writes)
        #expect(fixture.broker.automatic())
        #expect(fixture.broker.errors().isEmpty, "\(fixture.broker.errors())")
    }

    @Test func coldRecoveryRemainsAliveWithoutIncidentalRunLoopSources() throws {
        let fixture = try ServiceFixture()
        let recovery = try fixture.spawn("recovery-cold")
        try fixture.waitFor { (try? fixture.recoveryState().ready) == true }
        // Observe through more than one expiry tick, without registering a writer.
        Thread.sleep(forTimeInterval: BackendTiming.expiryInterval * 2)
        #expect(recovery.isRunning)
        #expect(try fixture.recoveryState().ready)
        #expect(try fixture.recoveryState().generation == nil)
    }

    @Test func killedControllerIsFencedBeforeRestoration() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        _ = try fixture.acquire()
        fixture.stop(fixture.backend)
        try fixture.waitFor { try fixture.broker.automatic() && fixture.recoveryState().restoration.verified }
        #expect(fixture.broker.errors().isEmpty, "\(fixture.broker.errors())")
        #expect(fixture.broker.journal().contains { $0.writer == "recovery" && $0.operation == "write" })
    }

    @Test func stoppedControllerExpiresAndIsKilledBeforeRestoration() throws {
        let fixture = try ServiceFixture(lowerMode: true, ftst: true)
        try fixture.start()
        _ = try fixture.acquire()
        #expect(kill(fixture.backend.processIdentifier, SIGSTOP) == 0)
        try fixture.waitFor(timeout: 16) { !fixture.backend.isRunning && fixture.broker.automatic() }
        #expect(fixture.broker.errors().isEmpty, "\(fixture.broker.errors())")
    }

    @Test func stalledSensingWithResponsiveStatusCannotRenewProtection() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        let session = try fixture.acquire()
        try fixture.flag("stall-sensors")
        let deadline = BackendTiming.monotonicNow + 16
        var successfulStatusRequests = 0
        while fixture.backend.isRunning && BackendTiming.monotonicNow < deadline {
            if (try? fixture.send(.init(operation: .renew, session: session)).ok) == true { successfulStatusRequests += 1 }
            _ = try? fixture.status()
            Thread.sleep(forTimeInterval: 0.2)
        }
        #expect(successfulStatusRequests >= 10)
        try fixture.waitFor { !fixture.backend.isRunning && fixture.broker.automatic() }
        #expect(fixture.broker.errors().isEmpty, "\(fixture.broker.errors())")
    }

    @Test func recoveryDeathAndRestartReconcilesDurableMarker() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        _ = try fixture.acquire()
        // Keep the backend unable to clean up so restart must use its durable marker.
        #expect(kill(fixture.backend.processIdentifier, SIGSTOP) == 0)
        fixture.stop(fixture.recovery)
        fixture.recovery = try fixture.spawn("recovery")
        try fixture.waitFor(timeout: 10) {
            try !fixture.backend.isRunning && fixture.broker.automatic() && fixture.recoveryState().ready
        }
        #expect(try fixture.recoveryState().ready)
        #expect(fixture.broker.errors().isEmpty, "\(fixture.broker.errors())")
        fixture.backend = try fixture.spawn("backend")
        fixture.broker.track(fixture.backend)
        try fixture.waitFor { (try? fixture.status().restoration) == .verified }
        _ = try fixture.acquire()
        #expect(fixture.broker.errors().isEmpty)
    }

    @Test func recoveryRestartFencesIdleBackendBeforeWriting() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        #expect(try !fixture.recoveryState().protected)
        #expect(kill(fixture.backend.processIdentifier, SIGSTOP) == 0)
        fixture.stop(fixture.recovery)
        fixture.recovery = try fixture.spawn("recovery")
        try fixture.waitFor(timeout: 10) {
            try !fixture.backend.isRunning && fixture.broker.automatic() && fixture.recoveryState().ready
        }
        #expect(fixture.broker.errors().isEmpty, "\(fixture.broker.errors())")
    }

    @Test func partialRestorationKeepsNewBackendBlockedUntilVerified() throws {
        let fixture = try ServiceFixture(ftst: true)
        try fixture.start()
        _ = try fixture.acquire()
        fixture.broker.failRestoration("F1Md", enabled: true)
        fixture.stop(fixture.backend)
        try fixture.waitFor { try fixture.recoveryState().revoked && !fixture.recoveryState().restoration.verified }
        let denied = try fixture.spawn("backend")
        try fixture.waitFor { !denied.isRunning }
        #expect(denied.terminationStatus != 0)
        let writes = fixture.broker.journal().filter { $0.writer == "recovery" && $0.operation == "write" }
        #expect(writes.contains { $0.key == "Ftst" && $0.bytes == [0] })
        fixture.broker.failRestoration("F1Md", enabled: false)
        try fixture.waitFor { try fixture.broker.automatic() && fixture.recoveryState().ready }
        #expect(fixture.broker.errors().isEmpty)
    }

    @Test func missingSensorsRestoreInsteadOfKeepingManualControlAlive() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        _ = try fixture.acquire()
        fixture.broker.unreadable("Tp01", enabled: true)
        fixture.broker.unreadable("Tg0f", enabled: true)
        try fixture.waitFor { try fixture.broker.automatic() && fixture.status().owner == nil }
        #expect(try fixture.status().lastSessionEndReason == .backendFailure)
    }

    @Test func ownerDeathCancelsCalibrationAndNeverSavesPartialResults() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        try fixture.flag("owner-calibration")
        let owner = try fixture.spawn("owner")
        try fixture.waitFor { fixture.broker.journal().contains { $0.operation == "workload-start" } }
        fixture.stop(owner)
        try fixture.waitFor(timeout: 14) { try fixture.broker.automatic() && fixture.status().calibration?.phase == .cancelled }
        let journal = fixture.broker.journal()
        let stopped = try #require(journal.firstIndex { $0.operation == "workload-stopped" })
        let laterWrites = journal[(stopped + 1)...].filter { $0.operation == "write" && $0.writer == "backend" }
        #expect(laterWrites.contains { $0.bytes == [0] && $0.key.hasSuffix("Md") })
        let store = BackendCalibrationStore(directory: fixture.directory, legacyRoot: nil)
        #expect(try store.load(lidClosed: false) == nil)
        #expect(try store.load(lidClosed: true) == nil)
    }

    @Test func calibrationShutdownFailureExitsBeforeIndependentRestore() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        try fixture.flag("fail-workload-stop")
        let session = try fixture.acquire(calibration: true)
        #expect(try fixture.send(.init(operation: .cancelCalibration, session: session)).ok)
        try fixture.waitFor { !fixture.backend.isRunning && fixture.broker.automatic() }
        #expect(fixture.broker.journal().contains { $0.operation == "workload-stop-failed" })
        #expect(fixture.broker.errors().isEmpty)
        #expect(try BackendCalibrationStore(directory: fixture.directory, legacyRoot: nil).load(lidClosed: false) == nil)
    }

    @Test func disconnectedClientSocketExpiresForegroundOwnership() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        _ = try fixture.acquire()
        #expect(unlink(fixture.directory.appendingPathComponent("b.sock").path) == 0)
        try fixture.waitFor(timeout: 13) {
            // The backend socket was deliberately removed; completion is
            // observed through the independent recovery endpoint.
            let state = try fixture.recoveryState()
            return fixture.broker.automatic() && state.restoration.verified && !state.protected
        }
        #expect(fixture.backend.isRunning)
        #expect(try !fixture.recoveryState().protected)
    }

    @Test func persistenceFailurePreventsFirstManualHardwareWrite() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        let directory = fixture.directory.appendingPathComponent("recovery").path
        #expect(chmod(directory, 0o500) == 0)
        defer { _ = chmod(directory, 0o700) }
        let session = ControlSession(generation: try fixture.status().generation)
        #expect(try fixture.send(.init(operation: .acquire, session: session, clientKind: .cli, intent: .maximum)).ok)
        try fixture.waitFor { !fixture.backend.isRunning }
        #expect(fixture.broker.automatic())
        #expect(!fixture.broker.journal().contains {
            $0.writer == "backend" && $0.operation == "write" && $0.bytes == [1]
        })
        #expect(fixture.broker.errors().isEmpty)
    }

    @Test func recoveryCommunicationLossStopsBackendWithoutRestartingCalibration() throws {
        let fixture = try ServiceFixture()
        try fixture.start()
        _ = try fixture.acquire(calibration: true)
        fixture.stop(fixture.recovery)
        try fixture.waitFor { !fixture.backend.isRunning }
        #expect(fixture.broker.journal().contains { $0.operation == "workload-stopped" })
        fixture.recovery = try fixture.spawn("recovery")
        try fixture.waitFor { try fixture.recoveryState().ready && fixture.broker.automatic() }
        #expect(fixture.broker.errors().isEmpty)
        #expect(try BackendCalibrationStore(directory: fixture.directory, legacyRoot: nil).load(lidClosed: false) == nil)
    }
}
