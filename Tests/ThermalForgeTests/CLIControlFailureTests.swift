import Foundation
import Testing
import ThermalForgeCore
@testable import thermalforge

private actor FailingCLIServer {
    var snapshot = BackendSnapshot(generation: "cli", acknowledgedControl: .apple, restoration: .verified)
    var acquired = false
    var restorationChecks = 0
    func transport(_ data: Data) throws -> Data {
        let request = try JSONDecoder().decode(BackendRequest.self, from: data)
        if request.operation == .acquire {
            acquired = true
            snapshot.owner = request.session
            snapshot.ownerKind = .cli
        } else if acquired {
            snapshot.owner = nil
            snapshot.lastSessionEndReason = .backendFailure
            snapshot.controlError = "SMC write failed: F1Tg: firmware result 0x85, status 0x02"
            restorationChecks += 1
            snapshot.restoration = restorationChecks < 3 ? .pending : .verified
        }
        snapshot.sequence = (snapshot.sequence ?? 0) + 1
        return try JSONEncoder().encode(BackendResponse(requestID: request.requestID, snapshot: snapshot))
    }
}

@Suite("Foreground CLI failures", .serialized)
struct CLIControlFailureTests {
    @Test("A revoked CLI waits for handback and reports the hardware cause instead of interruption")
    func hardwareFailureIsReportedAfterHandback() async throws {
        let server = FailingCLIServer()
        let client = BackendClient(transport: { try await server.transport($0) })
        _ = try await client.acquire(.maximum)
        do {
            try await runForegroundSession(client: client)
            Issue.record("A failed fan command must not report success")
        } catch {
            #expect(String(describing: error).contains("F1Tg: firmware result 0x85"))
        }
        #expect(await server.restorationChecks >= 3)
        #expect(await client.snapshot?.restoration == .verified)
        #expect(await client.ownsControl == false)
    }
}
