import Darwin
import Foundation
import Testing
@testable import ThermalForgeCore

@Suite struct UnixSocketTransportTests {
    @Test func stalledRequestDoesNotBlockOtherClients() throws {
        let path = "/private/tmp/tf-io-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocketListener(path: path, authorize: { $0.uid == getuid() }) { data, peer in
            #expect(peer.pid == getpid())
            return data
        }
        listener.start()
        defer { listener.stop() }
        let stalled = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(stalled) }
        var address = try UnixSocketTransport.socketAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(stalled, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
        let result = try UnixSocketTransport.roundTrip(Data("hello".utf8), path: path)
        #expect(String(decoding: result, as: UTF8.self) == "hello")
    }

    @Test func absoluteDeadlineExpiresDespiteTrickledBytes() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let reader = pair[0], writer = pair[1]
        defer { close(reader); close(writer) }
        try UnixSocketTransport.configure(reader)
        try UnixSocketTransport.configure(writer)
        let task = DispatchGroup()
        task.enter()
        DispatchQueue.global().async {
            defer { task.leave() }
            for _ in 0..<20 {
                var byte: UInt8 = 97
                _ = write(writer, &byte, 1)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let started = BackendTiming.monotonicNow
        #expect(throws: DaemonError.self) {
            _ = try UnixSocketTransport.readFrame(from: reader, deadline: started + 0.15)
        }
        #expect(BackendTiming.monotonicNow - started < 0.35)
        task.wait()
    }

    @Test func liveSocketCannotBeReplacedByAnotherListener() throws {
        let path = "/private/tmp/tf-io-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocketListener(path: path, authorize: { _ in true }) { data, _ in data }
        listener.start()
        defer { listener.stop() }
        #expect(throws: DaemonError.self) {
            _ = try UnixSocketListener(path: path, authorize: { _ in true }) { data, _ in data }
        }
        #expect(try UnixSocketTransport.roundTrip(Data("intact".utf8), path: path) == Data("intact".utf8))
    }

    @Test func rejectsUnauthenticatedPeerBeforeRouting() throws {
        let path = "/private/tmp/tf-io-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocketListener(path: path, authorize: { _ in false }) { _, _ in
            Issue.record("Unauthorized request reached handler")
            return Data()
        }
        listener.start()
        defer { listener.stop() }
        #expect(throws: DaemonError.self) { _ = try UnixSocketTransport.roundTrip(Data("request".utf8), path: path) }
    }

    @Test func legacyManualRequestsNeverReachBackend() throws {
        final class Backend: BackendRequestHandling {
            var operations: [BackendOperation] = []
            func handle(_ request: BackendRequest, peer: AuthenticatedPeer) -> BackendResponse {
                operations.append(request.operation)
                return .init(requestID: request.requestID, snapshot: .init(generation: "test"))
            }
        }
        let backend = Backend()
        let router = BackendRequestRouter(backend: backend)
        let peer = AuthenticatedPeer(uid: 501, pid: 1)
        for command in ["set 3000", "max", "heartbeat"] {
            let response = try JSONDecoder().decode(DaemonResponse.self, from: router.handle(Data(command.utf8), peer: peer))
            #expect(!response.ok)
            #expect(response.error?.code == "session_required")
        }
        #expect(backend.operations.isEmpty)
        _ = router.handle(Data("status".utf8), peer: peer)
        _ = router.handle(Data("auto".utf8), peer: peer)
        #expect(backend.operations == [.status, .restoreApple])
    }
}
