//
//  InterruptSignalSource.swift
//  ThermalForge
//
//  Converts SIGINT into a normal Dispatch callback. No application work is
//  performed from a POSIX signal handler.
//

import Darwin
import Dispatch
import Foundation

final class InterruptSignalSource {
    private let source: DispatchSourceSignal
    private let lock = NSLock()
    private var handled = false
    private var stopped = false

    init(handler: @escaping @Sendable () -> Void) {
        Darwin.signal(SIGINT, SIG_IGN)

        source = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: DispatchQueue(label: "com.thermalforge.cli-interrupt")
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock()
            let shouldHandle = !handled && !stopped
            handled = true
            lock.unlock()

            if shouldHandle {
                handler()
            }
        }
        source.resume()
    }

    func cancel() {
        lock.lock()
        let shouldCancel = !stopped
        stopped = true
        lock.unlock()

        if shouldCancel {
            source.cancel()
        }
        Darwin.signal(SIGINT, SIG_DFL)
    }

    deinit {
        cancel()
    }
}
