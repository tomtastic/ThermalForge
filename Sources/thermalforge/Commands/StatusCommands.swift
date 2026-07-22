import ArgumentParser
import Foundation
import ThermalForgeCore

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print current fan speeds and temperatures as JSON"
    )

    func run() throws {
        let fc = try FanControl()
        let status = try fc.status()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try encoder.encode(status)
        print(String(data: json, encoding: .utf8)!)
    }
}

struct Discover: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Dump all SMC keys (run first on new hardware)"
    )

    @Option(name: .shortAndLong, help: "Filter keys by prefix (e.g., F for fans, T for temps)")
    var filter: String?

    @Option(name: .shortAndLong, help: "Write output to file")
    var output: String?

    func run() throws {
        let fc = try FanControl()
        let keys = fc.discover(prefix: filter)

        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machineModel = String(cString: modelBuf)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var lines: [String] = []
        lines.append("ThermalForge Key Dump")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Machine: \(machineModel)")
        lines.append("macOS: \(osVersion)")
        lines.append("Keys found: \(keys.count)")
        lines.append(String(repeating: "\u{2500}", count: 72))
        lines.append("Key    Type   Size  Value")
        lines.append(String(repeating: "\u{2500}", count: 72))

        for entry in keys {
            let hex = entry.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")

            var note = ""
            if entry.size == 4 && entry.bytes.count >= 4 && entry.type == "flt " {
                let floatVal = smcBytesToFloat(entry.bytes, size: entry.size)
                if entry.key.hasPrefix("F") && floatVal >= 0 && floatVal <= 10000 {
                    note = " = \(Int(floatVal)) RPM"
                } else if entry.key.hasPrefix("T") && floatVal > 0 && floatVal < 150 {
                    note = " = \(String(format: "%.1f", floatVal)) C"
                }
            } else if entry.size == 8 && entry.bytes.count >= 4 && entry.type == "ioft" {
                let floatVal = ioftBytesToFloat(entry.bytes)
                if floatVal > 0 && floatVal < 150 {
                    note = " = \(String(format: "%.1f", floatVal)) C"
                }
            } else if entry.size == 1 && !entry.bytes.isEmpty {
                note = " = \(entry.bytes[0])"
            }

            let key = entry.key.padding(toLength: 6, withPad: " ", startingAt: 0)
            let type = entry.type.padding(toLength: 6, withPad: " ", startingAt: 0)
            let sizeString = String(
                repeating: " ",
                count: max(0, 4 - "\(entry.size)".count)
            ) + "\(entry.size)"
            lines.append("\(key) \(type) \(sizeString)  \(hex)\(note)")
        }

        let report = lines.joined(separator: "\n")

        if let path = output {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(keys.count) keys to \(path)")
        } else {
            print(report)
        }
    }
}
