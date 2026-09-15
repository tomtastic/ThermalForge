import Foundation

/// Service commands can be invoked on a worker thread by AsyncParsableCommand.
/// Run that thread's loop and retain an input source even when the service uses
/// only Dispatch sources. An empty or another thread's loop can return at once.
public enum ServiceRunLoop {
    public static func run() {
        let loop = CFRunLoopGetCurrent()
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        guard let keepAlive = CFRunLoopSourceCreate(nil, 0, &context) else {
            preconditionFailure("Cannot create service run-loop source")
        }
        CFRunLoopAddSource(loop, keepAlive, .defaultMode)
        defer {
            CFRunLoopRemoveSource(loop, keepAlive, .defaultMode)
            CFRunLoopSourceInvalidate(keepAlive)
        }
        CFRunLoopRun()
    }
}
