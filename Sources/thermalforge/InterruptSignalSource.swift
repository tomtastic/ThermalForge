//
//  InterruptSignalSource.swift
//  ThermalForge
//
//  Converts SIGINT/SIGTERM into a normal Dispatch callback. No application work is
//  performed from a POSIX signal handler.
//

import Darwin
import Dispatch
import Foundation

final class InterruptSignalSource {
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var handled = false
    private var stopped = false

    init(handler: @escaping @Sendable () -> Void) {
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number,
                queue: DispatchQueue(label: "com.thermalforge.cli-interrupt"))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let shouldHandle = !self.handled && !self.stopped
                self.handled = true
                self.lock.unlock()
                if shouldHandle { handler() }
            }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        lock.lock()
        let shouldCancel = !stopped
        stopped = true
        lock.unlock()

        if shouldCancel {
            for source in sources { source.cancel() }
        }
        Darwin.signal(SIGINT, SIG_DFL)
        Darwin.signal(SIGTERM, SIG_DFL)
    }

    deinit {
        cancel()
    }
}
