import Foundation

public protocol SensorProvider {
    func status() throws -> ThermalStatus
}
