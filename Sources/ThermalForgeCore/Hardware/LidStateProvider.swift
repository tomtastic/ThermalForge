import AppKit
import CoreGraphics
import Foundation
import IOKit

public protocol LidStateProvider {
    var isLidClosed: Bool { get }
}

/// Reads the hardware clamshell state and falls back to active-display
/// topology only when the IOPM root-domain property is unavailable.
public struct MacLidStateProvider: LidStateProvider {
    private let hardwareState: () -> Bool?
    private let screenFallback: () -> Bool

    public init() {
        hardwareState = Self.readHardwareState
        screenFallback = Self.readScreenFallback
    }

    init(hardwareState: @escaping () -> Bool?, screenFallback: @escaping () -> Bool) {
        self.hardwareState = hardwareState
        self.screenFallback = screenFallback
    }

    public var isLidClosed: Bool {
        hardwareState() ?? screenFallback()
    }

    private static func readHardwareState() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }
        return property as? Bool
    }

    private static func readScreenFallback() -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }

        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let hasBuiltIn = screens.contains { screen in
            guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
        return !hasBuiltIn
    }
}
