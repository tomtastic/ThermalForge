import ArgumentParser
import ThermalForgeCore

struct Max: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "max",
        abstract: "Set all fans to maximum speed"
    )

    func run() throws {
        let fc = try FanControl()
        try fc.setMax()

        let status = try fc.status()
        for fan in status.fans {
            print("Fan \(fan.index): \(fan.actualRPM) RPM → max (\(fan.maxRPM) RPM)")
        }
    }
}

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Reset fans to Apple defaults"
    )

    func run() throws {
        // Kill the menu bar app first — if it's running with a profile active,
        // it will override the fan reset within seconds
        _ = try ApplicationLifecycleCoordinator().stop(applicationName: "ThermalForgeApp")

        let fc = try FanControl()
        try fc.resetAuto()
        print("Fans reset to Apple defaults")
    }
}

struct SetSpeed: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set fan speed to a specific RPM"
    )

    @Argument(help: "Target RPM")
    var rpm: Int

    @Option(name: .shortAndLong, help: "Fan index (default: all fans)")
    var fan: Int?

    func run() throws {
        let fc = try FanControl()
        let target = Float(rpm)

        if let index = fan {
            try fc.setSpeed(fan: index, rpm: target)
            print("Fan \(index) → \(rpm) RPM")
        } else {
            try fc.setAllFans(rpm: target)
            let count = try fc.fanCount()
            for index in 0..<count {
                print("Fan \(index) → \(rpm) RPM")
            }
        }
    }
}
