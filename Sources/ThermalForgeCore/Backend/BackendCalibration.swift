import Foundation

public protocol BackendCalibrationRunning: AnyObject {
    func run() throws -> CalibrationData
    /// True only after all workload threads/commands have actually stopped.
    func stopWorkloads() -> Bool
}

public struct BackendCalibrationContext {
    public let parameters: CalibrationJobParameters
    public let workloadIntensity: Float?
    public let cancellation: CancellationToken
    public let lidClosed: Bool
    public let readStatus: () throws -> ThermalStatus
    public let apply: (FanCommand) throws -> Void
    public let progress: (String) -> Void
}
public typealias BackendCalibrationFactory = (BackendCalibrationContext) throws -> any BackendCalibrationRunning

struct FixedCalibrationLid: LidStateProvider {
    let isLidClosed: Bool
}

extension CalibrationRunner: BackendCalibrationRunning {}
