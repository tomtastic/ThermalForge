import Foundation
import Testing
@testable import ThermalForgeCore

@Suite struct BackendProtocolTests {
    @Test func sessionAndIntentRoundTrip() throws {
        let session = ControlSession(generation: "generation-a")
        let request = BackendRequest(operation: .acquire, session: session,
                                     clientKind: .cli, intent: .rpm(3500), takeover: true)
        let decoded = try JSONDecoder().decode(BackendRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.version == 2)
        #expect(decoded.session == session)
        #expect(decoded.intent == .rpm(3500))
        #expect(decoded.takeover)
    }

    @Test func observationHasNoControlCredential() {
        let request = BackendRequest(operation: .status)
        #expect(request.session == nil)
        #expect(request.intent == nil)
    }

    @Test func requestedAndAcknowledgedStateRemainSeparate() throws {
        let snapshot = BackendSnapshot(generation: "a", requestedIntent: .maximum,
                                       acknowledgedControl: .unknown, restoration: .pending)
        let decoded = try JSONDecoder().decode(BackendSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.requestedIntent == .maximum)
        #expect(decoded.acknowledgedControl == .unknown)
        #expect(decoded.restoration == .pending)
    }
}
