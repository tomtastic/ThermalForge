import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Daemon heartbeat watchdog")
struct DaemonWatchdogTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("Manual control with a stale heartbeat resets")
    func staleManualControlResets() {
        #expect(HeartbeatWatchdog.shouldReset(
            lastHeartbeat: now.addingTimeInterval(-11),
            hasManualControl: true,
            now: now
        ))
    }

    @Test("A fresh heartbeat preserves manual control")
    func freshHeartbeatDoesNotReset() {
        #expect(!HeartbeatWatchdog.shouldReset(
            lastHeartbeat: now.addingTimeInterval(-9),
            hasManualControl: true,
            now: now
        ))
    }

    @Test("Idle daemon never asks for a reset")
    func idleDaemonDoesNotReset() {
        #expect(!HeartbeatWatchdog.shouldReset(
            lastHeartbeat: nil,
            hasManualControl: false,
            now: now
        ))
        #expect(!HeartbeatWatchdog.shouldReset(
            lastHeartbeat: now.addingTimeInterval(-60),
            hasManualControl: false,
            now: now
        ))
    }
}
