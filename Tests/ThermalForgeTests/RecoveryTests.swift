import Darwin
import Foundation
import Testing
@testable import ThermalForgeCore

private final class RecoveryJournal { var entries: [String] = [] }
private final class RecoveryClock { var value: TimeInterval = 0 }
private final class TestMarkerStore: RecoveryMarkerStoring {
    var value: RecoveryMarker?
    var failSave = false
    var failClear = false
    let journal: RecoveryJournal
    init(_ journal: RecoveryJournal) { self.journal = journal }
    func load() throws -> RecoveryMarker? { value }
    func save(_ marker: RecoveryMarker) throws {
        journal.entries.append("persist")
        if failSave { throw RecoveryError.failure("disk unavailable") }
        value = marker
    }
    func clear() throws {
        journal.entries.append("clear")
        if failClear { throw RecoveryError.failure("directory fsync failed") }
        value = nil
    }
}
private final class TestRecoveryProcesses: RecoveryProcessControlling {
    let journal: RecoveryJournal
    var identities = [Int32(42): BackendProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1)]
    var states: [Int32: BackendProcessState] = [42: .alive]
    var killExits = true
    init(_ journal: RecoveryJournal) { self.journal = journal }
    func identity(pid: Int32) -> BackendProcessIdentity? { identities[pid] }
    func state(of identity: BackendProcessIdentity) -> BackendProcessState {
        if let actual = identities[identity.pid], actual != identity { return .exited }
        return states[identity.pid] ?? .exited
    }
    func terminate(_ identity: BackendProcessIdentity, force: Bool) throws {
        journal.entries.append(force ? "kill" : "term")
        if force && killExits { states[identity.pid] = .exited; journal.entries.append("exit") }
    }
}
private final class RecoveryHarness {
    let journal = RecoveryJournal()
    let clock = RecoveryClock()
    let store: TestMarkerStore
    let processes: TestRecoveryProcesses
    var restorationWorks = true
    var core: RecoveryCoordinator!
    let peer = AuthenticatedPeer(uid: 0, pid: 42)
    init() throws {
        store = TestMarkerStore(journal)
        processes = TestRecoveryProcesses(journal)
        core = try makeCore()
    }
    func makeCore() throws -> RecoveryCoordinator {
        try RecoveryCoordinator(markerStore: store, processControl: processes, restore: { [unowned self] in
            journal.entries.append("restore")
            return RestorationResult(verified: restorationWorks, errors: restorationWorks ? [] : ["SMC unavailable"])
        }, now: { [clock] in clock.value })
    }
    @discardableResult func send(_ operation: RecoveryOperation, generation: String = "g1") -> RecoveryResponse {
        core.handle(RecoveryRequest(generation: generation, operation: operation), peer: peer)
    }
    func begin() {
        core.tick()
        #expect(send(.connect).ok)
        #expect(send(.authorizeManual).ok)
    }
}

@Suite("Independent recovery ordering")
struct RecoveryTests {
    @Test("Installer repair fences failed recovery before opening SMC and reconciles durable backend identity", arguments: [false, true])
    func installationRepairFencesBothWriters(outstandingBackend: Bool) throws {
        let h = try RecoveryHarness()
        if outstandingBackend { h.begin() }
        h.journal.entries = []
        let repair = RecoveryServiceRepair(stop: { h.journal.entries.append("recovery-exit") },
            makeCoordinator: { h.journal.entries.append("open-SMC"); return try h.makeCore() },
            restart: { h.journal.entries.append("restart-recovery") },
            now: { h.clock.value }, wait: { h.clock.value += $0 })

        #expect(repair.restore(timeout: 3).verified)
        let expected = outstandingBackend
            ? ["recovery-exit", "open-SMC", "term", "kill", "exit", "restore", "clear"]
            : ["recovery-exit", "open-SMC", "restore"]
        #expect(h.journal.entries == expected)
        #expect(h.store.value == nil)
    }

    @Test("Failed recovery fencing prevents local repair from opening SMC")
    func installationRepairRequiresRecoveryExit() throws {
        let h = try RecoveryHarness()
        let repair = RecoveryServiceRepair(stop: { throw RecoveryError.failure("recovery still alive") },
            makeCoordinator: { h.journal.entries.append("open-SMC"); return try h.makeCore() },
            restart: { h.journal.entries.append("retain-recovery") })

        let result = repair.restore()
        #expect(!result.verified)
        #expect(result.errors.contains("recovery still alive"))
        #expect(h.journal.entries == ["retain-recovery"])
    }

    @Test("Repair retains recovery and its marker when a backend cannot be fenced")
    func installationRepairCannotBypassOutstandingWriter() throws {
        let h = try RecoveryHarness()
        h.begin()
        h.processes.killExits = false
        h.journal.entries = []
        let repair = RecoveryServiceRepair(stop: { h.journal.entries.append("recovery-exit") },
            makeCoordinator: { try h.makeCore() },
            restart: { h.journal.entries.append("retain-recovery") },
            now: { h.clock.value }, wait: { h.clock.value += $0 })

        #expect(!repair.restore(timeout: 2).verified)
        #expect(!h.journal.entries.contains("restore"))
        #expect(!h.journal.entries.contains("clear"))
        #expect(h.journal.entries.last == "retain-recovery")
        #expect(h.store.value?.generation == "g1")
    }

    @Test("Repair preserves failed hardware restoration and recovery restart errors")
    func installationRepairReportsHandbackAndRestartFailure() throws {
        let h = try RecoveryHarness()
        h.restorationWorks = false
        let repair = RecoveryServiceRepair(stop: {}, makeCoordinator: { try h.makeCore() },
            restart: { throw RecoveryError.failure("bootstrap rejected") },
            now: { h.clock.value }, wait: { h.clock.value += $0 })

        let result = repair.restore(timeout: 1)
        #expect(!result.verified)
        #expect(result.errors.contains("SMC unavailable"))
        #expect(result.errors.contains { $0.contains("bootstrap rejected") })
    }

    @Test("Initial verified handback precedes registration and durable marker precedes permission")
    func initialReconciliationAndMarker() throws {
        let h = try RecoveryHarness()
        #expect(!h.send(.connect).ok)
        h.begin()
        h.journal.entries.append("manual write")
        #expect(h.journal.entries == ["restore", "persist", "persist", "manual write"])
        #expect(h.store.value?.generation == "g1")
    }

    @Test("Failed startup handback keeps registration blocked until verified retry")
    func startupFailure() throws {
        let h = try RecoveryHarness()
        h.restorationWorks = false
        h.core.tick()
        #expect(!h.send(.connect).ok)
        #expect(!h.core.snapshot().ready)
        h.restorationWorks = true
        h.core.tick()
        #expect(h.send(.connect).ok)
    }

    @Test("Inspection never registers or protects an observing process")
    func observerDoesNotRegister() throws {
        let h = try RecoveryHarness()
        h.core.tick()
        #expect(h.send(.inspect).ok)
        #expect(!h.send(.authorizeManual).ok)
        #expect(h.core.snapshot().generation == nil)
        #expect(h.store.value == nil)
        #expect(h.core.snapshot().readyForInstallation)
        #expect(h.send(.connect).ok)
        #expect(!h.core.snapshot().readyForInstallation)
    }

    @Test("Verified backend handback clears protection and idle work cannot recreate it")
    func normalHandback() throws {
        let h = try RecoveryHarness()
        h.begin()
        #expect(h.send(.restored).ok)
        h.clock.value = 100
        #expect(h.send(.completedWork).ok)
        h.core.tick()
        #expect(!h.core.snapshot().protected)
        #expect(h.core.snapshot().restoration.verified)
        #expect(h.store.value?.requiresProtection == false)
    }

    @Test("Recovery restart fences an idle backend before any independent hardware write")
    func idleRecoveryRestart() throws {
        let h = try RecoveryHarness()
        h.core.tick()
        #expect(h.send(.connect).ok)
        #expect(h.store.value?.requiresProtection == false)
        h.core = try h.makeCore()
        h.journal.entries = []
        h.core.tick()
        #expect(h.journal.entries == ["term"])
        #expect(!h.send(.authorizeManual).ok)
        h.clock.value = 1
        h.core.tick()
        h.core.tick()
        #expect(h.journal.entries == ["term", "kill", "exit", "restore", "clear"])
    }

    @Test("Registration persistence failure prevents backend admission")
    func failedRegistration() throws {
        let h = try RecoveryHarness()
        h.core.tick()
        h.store.failSave = true
        #expect(!h.send(.connect).ok)
        #expect(h.core.snapshot().generation == nil)
        #expect(!h.send(.authorizeManual).ok)
    }

    @Test("Failed durable marker never permits a manual write")
    func failedPersistence() throws {
        let h = try RecoveryHarness()
        h.core.tick()
        #expect(h.send(.connect).ok)
        h.store.failSave = true
        #expect(!h.send(.authorizeManual).ok)
        #expect(!h.core.snapshot().protected)
    }

    @Test("Responsive status and repeated permission requests cannot renew stalled work")
    func statusDoesNotRenew() throws {
        let h = try RecoveryHarness()
        h.begin()
        for second in 1...9 {
            h.clock.value = Double(second)
            #expect(h.send(.status).ok)
            #expect(h.send(.authorizeManual).ok)
        }
        h.clock.value = 10
        #expect(!h.send(.completedWork).ok)
        #expect(!h.send(.authorizeManual).ok)
        #expect(h.core.snapshot().revoked)
    }

    @Test("Completed sensing work renews the protection lease")
    func completedWorkRenewal() throws {
        let h = try RecoveryHarness()
        h.begin()
        h.clock.value = 8
        #expect(h.send(.completedWork).ok)
        h.clock.value = 12
        h.core.tick()
        #expect(!h.core.snapshot().revoked)
        h.clock.value = 18
        h.core.tick()
        #expect(h.core.snapshot().revoked)
    }

    @Test("Revoke then TERM then one-second KILL then confirmed exit then restoration")
    func fencingOrder() throws {
        let h = try RecoveryHarness()
        h.begin()
        h.journal.entries = []
        h.clock.value = 10
        h.core.tick()
        #expect(h.journal.entries == ["term"])
        #expect(!h.send(.restored).ok)
        h.clock.value = 10.9
        h.core.tick()
        #expect(h.journal.entries == ["term"])
        h.clock.value = 11
        h.core.tick()
        #expect(h.journal.entries == ["term", "kill", "exit"])
        h.core.tick()
        #expect(h.journal.entries == ["term", "kill", "exit", "restore", "clear"])
        #expect(h.core.snapshot().ready)
        #expect(!h.core.snapshot().protected)
    }

    @Test("Unknown or unkillable process keeps restoration and replacement control blocked")
    func unkillableProcess() throws {
        let h = try RecoveryHarness()
        h.begin()
        h.processes.killExits = false
        h.processes.states[42] = .unknown
        h.journal.entries = []
        for second in 10...15 { h.clock.value = Double(second); h.core.tick() }
        #expect(!h.journal.entries.contains("restore"))
        #expect(!h.core.snapshot().ready)
        #expect(!h.send(.connect, generation: "g2").ok)
    }

    @Test("Recovery restart reconciles the durable marker without accepting old progress")
    func recoveryRestart() throws {
        let h = try RecoveryHarness()
        h.begin()
        h.core = try h.makeCore()
        #expect(!h.send(.completedWork).ok)
        h.journal.entries = []
        h.core.tick()
        #expect(h.journal.entries == ["term"])
        h.clock.value = 1
        h.core.tick()
        h.core.tick()
        #expect(h.core.snapshot().ready)
    }

    @Test("Failed restoration is retried before a new backend can connect")
    func retryRestoration() throws {
        let h = try RecoveryHarness()
        h.begin()
        h.processes.states[42] = .exited
        h.restorationWorks = false
        h.core.tick()
        #expect(h.store.value != nil)
        #expect(!h.send(.connect, generation: "g2").ok)
        #expect(!h.core.snapshot().restoration.verified)
        h.restorationWorks = true
        h.core.tick()
        #expect(h.store.value == nil)
        #expect(h.core.snapshot().restoration.verified)
    }

    @Test("Failed marker clear remains blocked even after hardware handback")
    func failedClear() throws {
        let h = try RecoveryHarness()
        h.begin()
        h.processes.states[42] = .exited
        h.store.failClear = true
        h.core.tick()
        #expect(!h.core.snapshot().ready)
        #expect(h.core.snapshot().protected)
        h.store.failClear = false
        h.core.tick()
        #expect(h.core.snapshot().ready)
    }

    @Test("Stale generations and different live backend identities are rejected")
    func staleIdentity() throws {
        let h = try RecoveryHarness()
        h.begin()
        #expect(!h.send(.completedWork, generation: "other").ok)
        h.processes.identities[43] = BackendProcessIdentity(pid: 43, startSeconds: 200, startMicroseconds: 1)
        let response = h.core.handle(RecoveryRequest(generation: "g2", operation: .connect),
                                     peer: AuthenticatedPeer(uid: 0, pid: 43))
        #expect(!response.ok)
    }

    @Test("PID reuse permits recovery without signaling the unrelated replacement")
    func pidReuse() throws {
        let h = try RecoveryHarness()
        h.begin()
        h.journal.entries = []
        h.processes.identities[42] = BackendProcessIdentity(pid: 42, startSeconds: 200, startMicroseconds: 1)
        h.core.tick()
        #expect(h.journal.entries == ["restore", "clear"])
    }

    @Test("Durable marker round-trips and removes atomically")
    func fileMarkerStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileRecoveryMarkerStore(directory: directory)
        #expect(try store.load() == nil)
        let marker = RecoveryMarker(identity: BackendProcessIdentity(pid: 42, startSeconds: 99, startMicroseconds: 7), generation: "gen")
        try store.save(marker)
        #expect(try FileRecoveryMarkerStore(directory: directory).load() == marker)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test("Client propagates recovery communication loss")
    func clientLoss() throws {
        let client = RecoveryClient(generation: "gen", transport: { _ in throw RecoveryError.failure("disconnected") })
        #expect(throws: RecoveryError.self) { try client.completedWork() }
        #expect(throws: RecoveryError.self) { try client.authorizeManual() }
    }
}
