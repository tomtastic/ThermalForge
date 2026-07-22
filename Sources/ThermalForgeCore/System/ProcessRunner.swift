import Foundation

public struct ProcessResult: Equatable {
    public let standardOutput: String
    public let standardError: String
    public let terminationStatus: Int32

    public var succeeded: Bool {
        terminationStatus == 0
    }
}

public struct ProcessCommand: Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?
    public let environment: [String: String]?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
    }
}

public protocol ProcessRunning {
    func run(_ command: ProcessCommand) throws -> ProcessResult
}

public extension ProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        try run(ProcessCommand(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        ))
    }
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ command: ProcessCommand) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        process.environment = command.environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()

        let outputCapture = DataCapture()
        let errorCapture = DataCapture()
        let readers = DispatchGroup()
        let readerQueue = DispatchQueue(
            label: "com.thermalforge.process-output",
            attributes: .concurrent
        )

        readers.enter()
        readerQueue.async {
            outputCapture.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        readerQueue.async {
            errorCapture.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        process.waitUntilExit()
        readers.wait()

        return ProcessResult(
            standardOutput: String(decoding: outputCapture.data, as: UTF8.self),
            standardError: String(decoding: errorCapture.data, as: UTF8.self),
            terminationStatus: process.terminationStatus
        )
    }
}

private final class DataCapture: @unchecked Sendable {
    var data = Data()
}
