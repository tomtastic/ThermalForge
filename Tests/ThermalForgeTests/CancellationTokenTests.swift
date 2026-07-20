import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Cancellation token")
struct CancellationTokenTests {
    @Test("Cancellation is idempotent")
    func cancellationIsIdempotent() {
        let token = CancellationToken()

        #expect(!token.isCancelled)
        #expect(token.cancel())
        #expect(token.isCancelled)
        #expect(!token.cancel())
    }

    @Test("A timed wait expires without cancellation")
    func waitExpires() {
        let token = CancellationToken()

        #expect(!token.waitUntilCancelled(for: 0.01))
        #expect(!token.isCancelled)
    }

    @Test("Cancellation wakes a blocked wait promptly")
    func cancellationWakesWait() async {
        let token = CancellationToken()
        let startedAt = Date()

        let task = Task.detached {
            token.waitUntilCancelled(for: 10)
        }
        try? await Task.sleep(for: .milliseconds(20))
        token.cancel()

        #expect(await task.value)
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }
}
