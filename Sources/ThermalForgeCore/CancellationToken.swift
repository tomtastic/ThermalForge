//
//  CancellationToken.swift
//  ThermalForge
//
//  Cooperative cancellation for blocking command-line workflows.
//

import Foundation

public final class CancellationToken: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    /// Request cancellation. Returns true only for the first request.
    @discardableResult
    public func cancel() -> Bool {
        condition.lock()
        defer { condition.unlock() }

        guard !cancelled else { return false }
        cancelled = true
        condition.broadcast()
        return true
    }

    /// Wait for cancellation or until the interval expires.
    /// Returns true when cancellation was requested.
    public func waitUntilCancelled(for interval: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }

        guard !cancelled else { return true }
        guard interval > 0 else { return false }

        let deadline = Date().addingTimeInterval(interval)
        while !cancelled {
            if !condition.wait(until: deadline) {
                break
            }
        }
        return cancelled
    }
}
