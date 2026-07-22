import Darwin
import Foundation

enum SocketFrameIOError: Error, Equatable {
    case closed
    case timedOut
    case frameTooLarge(maximumBytes: Int)
    case readFailed(Int32)
    case writeFailed(Int32)
}

enum SocketFrameIO {
    static func readFrame(from fd: Int32, maximumBytes: Int) throws -> Data {
        precondition(maximumBytes > 0)
        var frame: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let bytes = buffer[0..<count]
                if let newline = bytes.firstIndex(of: 0x0A) {
                    frame.append(contentsOf: bytes[..<newline])
                    guard frame.count <= maximumBytes else {
                        throw SocketFrameIOError.frameTooLarge(maximumBytes: maximumBytes)
                    }
                    return Data(frame)
                }

                frame.append(contentsOf: bytes)
                guard frame.count <= maximumBytes else {
                    throw SocketFrameIOError.frameTooLarge(maximumBytes: maximumBytes)
                }
                continue
            }

            if count == 0 {
                guard !frame.isEmpty else { throw SocketFrameIOError.closed }
                return Data(frame)
            }

            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                throw SocketFrameIOError.timedOut
            default:
                throw SocketFrameIOError.readFailed(errno)
            }
        }
    }

    static func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBufferPointer { buffer in
                write(
                    fd,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
            }

            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw SocketFrameIOError.writeFailed(count < 0 ? errno : 0)
            }
        }
    }
}
