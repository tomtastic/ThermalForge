import Foundation

public struct TemperatureSummary: Equatable {
    public private(set) var cpu: Float?
    public private(set) var gpu: Float?
    public private(set) var ram: Float?
    public private(set) var ssd: Float?
    public private(set) var ambient: Float?

    public init(_ temperatures: [String: Float]) {
        for (key, temperature) in temperatures {
            if key.hasPrefix("TC") || key.hasPrefix("Tp") {
                cpu = Self.higher(cpu, temperature)
            } else if key.hasPrefix("TG") || key.hasPrefix("Tg") {
                gpu = Self.higher(gpu, temperature)
            } else if key.hasPrefix("TR") || key.hasPrefix("Tm") || key.hasPrefix("TM") {
                ram = Self.higher(ram, temperature)
            } else if key.hasPrefix("TH") {
                ssd = Self.higher(ssd, temperature)
            } else if key.hasPrefix("TA") {
                ambient = Self.higher(ambient, temperature)
            }
        }
    }

    public var controlPeak: Float? {
        [cpu, gpu].compactMap { $0 }.max()
    }

    private static func higher(_ current: Float?, _ candidate: Float) -> Float {
        max(current ?? candidate, candidate)
    }
}
