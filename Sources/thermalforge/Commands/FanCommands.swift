import ArgumentParser
import Foundation
import ThermalForgeCore

/// Lease maintenance is independent of display cadence, including --interval 60.
func runForegroundSession(client: BackendClient, interval: Double = 1,
                          onUpdate: @escaping (BackendSnapshot) -> Void = { _ in }) async throws {
    let cancellation = CancellationToken()
    let interrupts = InterruptSignalSource { _ = cancellation.cancel() }
    defer { interrupts.cancel() }
    let leaseTask = Task {
        do {
            while !Task.isCancelled && !cancellation.isCancelled {
                _ = try await client.maintain()
                guard await client.ownsControl else {
                    let state = await client.snapshot
                    throw ValidationError(state?.controlError ?? state?.restorationErrors.first
                        ?? "Control session ended; fan ownership is reported by the backend.")
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        } catch {
            _ = cancellation.cancel()
            throw error
        }
    }
    var failure: Error?
    do {
        var nextDisplay: TimeInterval = 0
        while !cancellation.isCancelled {
            if BackendTiming.monotonicNow >= nextDisplay {
                onUpdate(try await client.status())
                nextDisplay = BackendTiming.monotonicNow + interval
            }
            // A failed maintenance task stops foreground control promptly.
            if !(await client.ownsControl) { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    } catch { failure = error }
    leaseTask.cancel()
    do { try await leaseTask.value } catch is CancellationError {} catch { failure = failure ?? error }
    if let message = await client.snapshot?.controlError {
        failure = failure ?? ValidationError(message)
    }
    do {
        let released = try await client.release()
        let observed = await client.snapshot
        let state = released ?? observed
        if let state, state.owner == nil, state.restoration != .verified {
            _ = try await waitForRestoration(client)
        }
    } catch {
        throw ValidationError("Session ended; Apple restoration is unverified: \(error)")
    }
    if let failure { throw failure }
    if cancellation.isCancelled { throw ExitCode(130) }
}

@discardableResult
func waitForRestoration(_ client: BackendClient, timeout: TimeInterval = 15) async throws -> BackendSnapshot {
    let deadline = BackendTiming.monotonicNow + timeout
    while BackendTiming.monotonicNow < deadline {
        let state = try await client.status()
        if state.restoration == .verified { return state }
        if state.restoration == .failed {
            throw ValidationError("Apple restoration is unverified: \(state.restorationErrors.joined(separator: "; "))")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    throw ValidationError("Apple restoration remains pending; independent recovery continues.")
}

struct Max: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "max", abstract: "Hold all fans at maximum until interrupted")
    @Flag(name: .long, help: "Take control from the menu-bar app") var takeover = false
    func run() async throws {
        let client = BackendClient()
        _ = try await client.acquire(.maximum, takeover: takeover)
        print("Maximum fan session accepted. Ctrl-C to release to Apple control.")
        try await runForegroundSession(client: client)
    }
}

struct Auto: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auto", abstract: "Restore Apple control and revoke the current session")
    func run() async throws {
        let client = BackendClient()
        _ = try await client.restoreApple()
        _ = try await waitForRestoration(client)
        print("Apple fan control verified.")
    }
}

struct SetSpeed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Hold all fans at a target RPM until interrupted")
    @Argument(help: "Target RPM") var rpm: Int
    @Option(name: .shortAndLong, help: "Unsupported: central control sessions apply to all fans") var fan: Int?
    @Flag(name: .long, help: "Take control from the menu-bar app") var takeover = false
    func run() async throws {
        guard fan == nil else { throw ValidationError("--fan is unavailable with central control; omit it to control all fans.") }
        let client = BackendClient()
        _ = try await client.acquire(.rpm(rpm), takeover: takeover)
        print("\(rpm) RPM session accepted. Ctrl-C to release to Apple control.")
        try await runForegroundSession(client: client)
    }
}
