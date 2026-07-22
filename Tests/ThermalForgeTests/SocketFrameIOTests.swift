import Darwin
import Dispatch
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Socket framing")
struct SocketFrameIOTests {
    @Test("Partial reads assemble one newline-delimited frame")
    func partialRead() throws {
        let sockets = try socketPair()
        defer { sockets.close() }

        try SocketFrameIO.writeAll(Array("{\"command\":".utf8), to: sockets.writer)
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.01)
            try? SocketFrameIO.writeAll(
                Array("\"status\"}\nignored".utf8),
                to: sockets.writer
            )
        }

        let frame = try SocketFrameIO.readFrame(from: sockets.reader, maximumBytes: 1024)

        #expect(String(decoding: frame, as: UTF8.self) == "{\"command\":\"status\"}")
    }

    @Test("EOF preserves legacy frames without a newline")
    func legacyEOFFrame() throws {
        let sockets = try socketPair()
        defer { sockets.close() }

        try SocketFrameIO.writeAll(Array("status".utf8), to: sockets.writer)
        shutdown(sockets.writer, SHUT_WR)

        let frame = try SocketFrameIO.readFrame(from: sockets.reader, maximumBytes: 1024)

        #expect(String(decoding: frame, as: UTF8.self) == "status")
    }

    @Test("Frames larger than the explicit request limit are rejected")
    func oversizedFrame() throws {
        let sockets = try socketPair()
        defer { sockets.close() }
        let maximum = 32
        try SocketFrameIO.writeAll(
            [UInt8](repeating: 0x61, count: maximum + 1),
            to: sockets.writer
        )

        #expect(throws: SocketFrameIOError.frameTooLarge(maximumBytes: maximum)) {
            _ = try SocketFrameIO.readFrame(
                from: sockets.reader,
                maximumBytes: maximum
            )
        }
        #expect(DaemonServer.maximumRequestBytes == 64 * 1024)
    }

    @Test("Complete writes deliver payloads larger than the socket buffer")
    func completeWrite() throws {
        let sockets = try socketPair()
        defer { sockets.close() }
        var sendBuffer: Int32 = 1024
        setsockopt(
            sockets.writer,
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBuffer,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let payload = [UInt8](repeating: 0x5A, count: 256 * 1024)
        let completion = DispatchSemaphore(value: 0)
        let result = SocketWriteResult()
        DispatchQueue.global().async {
            do {
                try SocketFrameIO.writeAll(payload, to: sockets.writer)
            } catch {
                result.error = error
            }
            completion.signal()
        }

        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.count < payload.count {
            let count = read(sockets.reader, &buffer, buffer.count)
            guard count > 0 else {
                Issue.record("Socket closed before the complete payload arrived")
                break
            }
            received.append(contentsOf: buffer[0..<count])
        }
        completion.wait()

        #expect(result.error == nil)
        #expect(received == payload)
    }

    private func socketPair() throws -> SocketPair {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SocketFrameIOError.readFailed(errno)
        }
        return SocketPair(reader: descriptors[0], writer: descriptors[1])
    }
}

private struct SocketPair: @unchecked Sendable {
    let reader: Int32
    let writer: Int32

    func close() {
        Darwin.close(reader)
        Darwin.close(writer)
    }
}

private final class SocketWriteResult: @unchecked Sendable {
    var error: Error?
}
