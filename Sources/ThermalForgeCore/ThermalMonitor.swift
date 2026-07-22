//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Polling engine that reads temperatures and applies fan profiles.
//
//  Dual-cadence design:
//  - Thermal tick (adaptive): read temps, calculate curve, apply ramp governor, write fan speed
//  - Monitor tick (2s): process capture, anomaly detection, history logging
//

import Darwin
import Foundation

// MARK: - Fan Commands

public enum FanCommand: Equatable {
    case setMax
    case setRPM(Float)
    case resetAuto
}

// MARK: - Monitor State

public enum MonitorState: Equatable {
    case idle
    case active(profileName: String)
    case safetyOverride
}

// MARK: - Calibration State

/// Lightweight snapshot of calibration status reported to the UI.
public struct CalibrationState: Equatable {
    /// Whether a calibration curve is loaded for the current lid state.
    public let active: Bool
    /// True if the calibration was generated in clamshell (lid-closed) mode.
    public let lidClosed: Bool

    public static let none = CalibrationState(active: false, lidClosed: false)

    public init(active: Bool, lidClosed: Bool) {
        self.active = active
        self.lidClosed = lidClosed
    }
}

struct ElapsedCadence {
    static func isDue(lastRun: TimeInterval?, now: TimeInterval, interval: TimeInterval) -> Bool {
        guard let lastRun else { return true }
        return now - lastRun >= interval
    }
}

struct TemperatureRateHistory {
    private let capacity: Int
    private var samples: [(time: TimeInterval, temperature: Float)] = []

    init(capacity: Int = 4) {
        self.capacity = max(capacity, 2)
    }

    mutating func record(_ temperature: Float, at time: TimeInterval) {
        samples.append((time, temperature))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    mutating func removeAll() {
        samples.removeAll()
    }

    var ratePerSecond: Float {
        guard let oldest = samples.first, let newest = samples.last else { return 0 }
        let elapsed = newest.time - oldest.time
        guard elapsed > 0 else { return 0 }
        return (newest.temperature - oldest.temperature) / Float(elapsed)
    }
}

// MARK: - Thermal Monitor

public final class ThermalMonitor {
    private let sensorProvider: SensorProvider
    private let controlService: ControlService
    private let lidStateProvider: any LidStateProvider
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor", qos: .utility)

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

    // MARK: - Tick Timing

    /// Thermal tick interval in seconds. Fan control runs at this rate.
    /// Set from `start(interval:)` so the ramp / sustained-trigger math (which
    /// divides by it) always matches the real timer rate.
    private var tickInterval: Float = 1.0

    private static let fullStatusInterval: TimeInterval = 0.5
    private static let monitorInterval: TimeInterval = 2.0
    private var lastFullStatusAt: TimeInterval?
    private var lastMonitorTickAt: TimeInterval?

    /// Below this peak temperature the rolling process buffer isn't worth its
    /// sysctl sweep — skip process capture at idle. (°C)
    private static let processCaptureFloor: Float = 50.0

    // MARK: - Adaptive cadence

    /// Fast poll rate, from `start(interval:)`. Used while warm or active.
    private var activeInterval: Float = 1.0
    /// Slow poll rate while idle. Idle CPU is dominated by SMC reads, so fewer
    /// ticks ≈ proportionally less idle CPU.
    private static let idleInterval: Float = 2.0
    /// Hands-off profiles (Silent) never control fans — Apple's thermald does —
    /// so we only poll for the menu-bar readout and the 95°C safety backup.
    /// Both tolerate a much slower idle poll, which is the single biggest idle
    /// CPU lever for the default profile.
    private static let handsOffIdleInterval: Float = 5.0
    /// Stay fast at/above this temp regardless of profile, so the 95°C safety
    /// override reacts promptly. Apple Silicon idles ~45–60°C — overlapping the
    /// profile start temps — so a plain temp threshold can never relax. The real
    /// "can slow down" signal is state-based: fans off, idle, and below this
    /// profile's start temp (sustainedAboveCount == 0).
    private static let safetyWatchTemp: Float = 85.0
    /// Require this many consecutive idle ticks before relaxing, so hovering at a
    /// start temp doesn't flap the timer. Returns to fast immediately on activity.
    private static let idleConfirmTicks = 8
    private var consecutiveIdleTicks = 0

    /// Re-apply an active rule command periodically for resilience without saturating daemon I/O.
    private static let ruleCommandRefreshInterval: TimeInterval = 5

    // MARK: - Fan State

    private var lastAppliedRPMPercent: Float = 0
    private var fansCurrentlyRunning = false
    private var sustainedAboveCount = 0
    private var lastRuleDecision: RuleDecision?
    private var lastRuleCommandAppliedAt: Date?

    // MARK: - Smart Profile State

    private var tempHistory = TemperatureRateHistory()

    // MARK: - Anomaly Detection

    /// Tracks the 15 most recent monitor readings.
    private var anomalyHistory: [Float] = []
    private var isCalibrating = false

    // MARK: - Process Buffer

    /// Rolling buffer — captures what was running BEFORE a spike.
    /// Retains the 15 most recent monitor snapshots.
    private var processBuffer: [(timestamp: String, processes: String)] = []
    private let isoFormatter = ISO8601DateFormatter()

    /// Call this to suppress anomaly logging during calibration.
    public func setCalibrating(_ value: Bool) {
        queue.async { self.isCalibrating = value }
    }

    private var calibration: CalibrationData?

    /// Track which lid state the current calibration was loaded for,
    /// so we can reload when the lid state flips.
    private var calibrationLidClosed: Bool

    /// Snapshot of calibration status for the UI.
    private var calibrationState: CalibrationState {
        if let cal = calibration {
            return CalibrationState(active: true, lidClosed: cal.lidClosed)
        }
        return .none
    }

    /// How often (in seconds) to recheck lid state. Lid changes are rare —
    /// checking every 60s is plenty and avoids hardware queries on every tick.
    private let lidCheckInterval: Int = 60
    private var lastLidCheckTimestamp: UInt64 = 0

    /// Reload calibration data if the lid state has changed.
    /// Throttled to `lidCheckInterval` seconds to avoid frequent lid-state queries.
    private func syncCalibration() {
        let now = UInt64(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        guard now - lastLidCheckTimestamp >= lidCheckInterval else { return }
        lastLidCheckTimestamp = now
        let currentLidClosed = lidStateProvider.isLidClosed
        guard currentLidClosed != calibrationLidClosed else { return }

        TFLogger.shared.info("Lid state changed (clamshell: \(currentLidClosed)) — reloading calibration")
        calibrationLidClosed = currentLidClosed

        guard let data = CalibrationData.load(forLidClosed: currentLidClosed) else {
            calibration = nil
            TFLogger.shared.info("No calibration data for current lid state — using fallback curve")
            return
        }
        if let error = data.validationError {
            TFLogger.shared.error("Calibration data rejected on lid-state reload: \(error)")
            calibration = nil
            return
        }
        calibration = data
    }

    /// Called on the UI cadence, targeting 500ms but bounded by the thermal poll.
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState, CalibrationState) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege).
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public init(
        sensorProvider: SensorProvider,
        profile: FanProfile = .silent,
        controlService: ControlService = ControlService(),
        lidStateProvider: any LidStateProvider = MacLidStateProvider()
    ) {
        self.sensorProvider = sensorProvider
        self.activeProfile = profile
        self.controlService = controlService
        self.lidStateProvider = lidStateProvider
        calibrationLidClosed = lidStateProvider.isLidClosed

        let loaded = CalibrationData.load(forLidClosed: calibrationLidClosed)
        if let error = loaded?.validationError {
            TFLogger.shared.error("Calibration data rejected: \(error)")
            calibration = nil
        } else {
            calibration = loaded
        }
    }

    public convenience init(
        fanControl: FanControl,
        profile: FanProfile = .silent,
        controlService: ControlService = ControlService(),
        lidStateProvider: any LidStateProvider = MacLidStateProvider()
    ) {
        self.init(
            sensorProvider: fanControl,
            profile: profile,
            controlService: controlService,
            lidStateProvider: lidStateProvider
        )
    }

    public func updateRules(_ rules: [ThermalRule], enabled: Bool) {
        queue.async { [self] in
            controlService.replaceRules(rules, enabled: enabled)
        }
    }

    // MARK: - Lifecycle

    public func start(interval: TimeInterval = 1.0) {
        stop()

        activeInterval = Float(interval)
        tickInterval = activeInterval
        consecutiveIdleTicks = 0
        lastFullStatusAt = nil
        lastMonitorTickAt = nil

        let timer = DispatchSource.makeTimerSource(queue: queue)
        scheduleTimer(timer, interval: tickInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Stop polling and wait for any monitor callback already queued to finish.
    /// Callers can safely perform final fan cleanup after this returns.
    public func stopAndWait() {
        stop()
        queue.sync {}
    }

    /// (Re)schedule the repeating timer. Leeway lets the OS coalesce wakeups —
    /// a big idle-CPU win for a low-frequency poll; ±20% is invisible to fans.
    private func scheduleTimer(_ timer: DispatchSourceTimer, interval: Float) {
        timer.schedule(
            deadline: .now() + Double(interval),
            repeating: Double(interval),
            leeway: .milliseconds(Int(interval * 200))
        )
    }

    /// Adjust the poll rate to match thermal activity. Fast while warm/active so
    /// fan control and the 95°C override stay responsive; slow while cool & idle
    /// to keep idle CPU near zero. Reschedules the timer only on a real change.
    private func applyCadence(maxTemp: Float, fanChanged: Bool) {
        // Fast polling is only useful when something is *moving*: the fan speed
        // just changed (ramping), we're counting toward turning fans on, or
        // we're near the safety ceiling. Fans merely running at a STEADY speed
        // doesn't need 4–10 Hz — so a warm idle on Performance (fans holding at
        // minimum at ~56°C) relaxes to the slow rate instead of polling fast.
        let engaging = !activeProfile.curve.handsOff && !fansCurrentlyRunning && sustainedAboveCount > 0
        let busy = fanChanged
            || engaging
            || state == .safetyOverride
            || maxTemp >= Self.safetyWatchTemp

        if busy {
            consecutiveIdleTicks = 0
        } else if consecutiveIdleTicks < Self.idleConfirmTicks {
            consecutiveIdleTicks += 1
        }

        // handsOff profiles never adjust fans → slowest idle rate; fan-controlling
        // profiles holding steady use the medium rate so they still catch a rise.
        let idleRate = activeProfile.curve.handsOff ? Self.handsOffIdleInterval : Self.idleInterval
        let wantFast = busy || consecutiveIdleTicks < Self.idleConfirmTicks
        let desired = wantFast ? activeInterval : max(idleRate, activeInterval)
        guard desired != tickInterval, let timer else { return }
        tickInterval = desired
        scheduleTimer(timer, interval: desired)
    }

    /// Update the active profile.
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            activeProfile = profile
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            sustainedAboveCount = 0
            lastFullStatusAt = nil
            lastMonitorTickAt = nil
            lastRuleDecision = nil
            lastRuleCommandAppliedAt = nil

            if profile.id == "smart" {
                // Reset Smart state and reload calibration data for current lid state.
                tempHistory.removeAll()
                calibrationLidClosed = lidStateProvider.isLidClosed
                let loaded = CalibrationData.load(forLidClosed: calibrationLidClosed)
                if let error = loaded?.validationError {
                    TFLogger.shared.error("Calibration data rejected on reload: \(error)")
                    calibration = nil
                } else {
                    calibration = loaded
                }
            }

            state = controlService.transition(.idle)
        }
    }

    // MARK: - Polling

    private func tick() {
        // Check if lid state changed and reload calibration accordingly.
        syncCalibration()

        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let monitorDue = ElapsedCadence.isDue(
            lastRun: lastMonitorTickAt,
            now: now,
            interval: Self.monitorInterval
        )
        let fullStatusDue = monitorDue || ElapsedCadence.isDue(
            lastRun: lastFullStatusAt,
            now: now,
            interval: Self.fullStatusInterval
        )

        // Build the full sensor snapshot only when UI or monitor work is due.
        // On those ticks, derive the control
        // peak from it instead of re-reading the CPU/GPU sensors; on the other
        // (control-only) ticks do the cheap CPU/GPU-only read.
        let status: ThermalStatus?
        let maxTemp: Float
        if fullStatusDue, let fullStatus = try? sensorProvider.status() {
            status = fullStatus
            latestStatus = fullStatus
            lastFullStatusAt = now
            maxTemp = TemperatureSummary(fullStatus.temperatures).controlPeak ?? 0
        } else if let fc = sensorProvider as? FanControl, let temps = fc.controlTemps() {
            status = nil
            maxTemp = max(temps.cpu, temps.gpu)
        } else {
            return
        }

        // Monitor cadence: process capture + anomaly detection (target ~2 seconds)
        if monitorDue, let status {
            monitorTick(status: status, maxTemp: maxTemp)
            lastMonitorTickAt = now
            if activeProfile.id == "smart" {
                tempHistory.record(maxTemp, at: now)
            }
        }

        // Safety override: any CPU/GPU sensor > 95°C
        if maxTemp >= FanProfile.safetyTempThreshold {
            lastRuleDecision = nil
            lastRuleCommandAppliedAt = nil
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = controlService.transition(.safetyTriggered)
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
                TFLogger.shared.safety("Override triggered: \(String(format: "%.1f", maxTemp))°C — fans maxed")
                TFLogger.shared.event(ThermalEvent(type: .safetyOverrideTriggered, details: "maxTemp=\(String(format: "%.1f", maxTemp))"))
            }
            if let status { onUpdate?(status, activeProfile, state, calibrationState) }
            applyCadence(maxTemp: maxTemp, fanChanged: true)
            return
        }

        // Clear safety override with hysteresis.
        if state == .safetyOverride
            && maxTemp < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees
        {
            state = controlService.transition(.safetyCleared)
            TFLogger.shared.event(ThermalEvent(type: .safetyOverrideCleared, details: "maxTemp=\(String(format: "%.1f", maxTemp))"))
        }

        // Sustained trigger: track consecutive ticks above start threshold.
        let startThreshold = activeProfile.curve.startTemp
        if maxTemp >= startThreshold {
            sustainedAboveCount += 1
        } else {
            sustainedAboveCount = 0
        }

        // Rule engine preemption (after safety, before profile curve).
        if let status {
            let temperatures = TemperatureSummary(status.temperatures)
            let context = RuleEvaluationContext(
                cpuTemp: temperatures.cpu ?? 0,
                gpuTemp: temperatures.gpu ?? 0,
                maxTemp: maxTemp
            )
            if let decision = controlService.evaluateRules(context: context) {
                let decisionChanged = decision != lastRuleDecision
                var preempted = false

                if let profileID = decision.profileID,
                   let targetProfile = FanProfile.builtIn.first(where: { $0.id == profileID })
                {
                    if decisionChanged || activeProfile.id != targetProfile.id {
                        activeProfile = targetProfile
                    }
                    preempted = true
                }

                let fanLimits = status.fans.first
                    .map { (min: Float($0.minRPM), max: Float($0.maxRPM)) }
                    ?? (min: 2317, max: 7826)
                if let command = decision.resolvedFanCommand(
                    minRPM: fanLimits.min,
                    maxRPM: fanLimits.max
                ) {
                    let shouldReapply: Bool
                    if decisionChanged {
                        shouldReapply = true
                    } else if let lastAppliedAt = lastRuleCommandAppliedAt {
                        shouldReapply = Date().timeIntervalSince(lastAppliedAt) >= Self.ruleCommandRefreshInterval
                    } else {
                        shouldReapply = true
                    }

                    if shouldReapply {
                        applyCommand(command)
                        lastRuleCommandAppliedAt = Date()
                    }

                    switch command {
                    case .setMax:
                        lastAppliedRPMPercent = 1.0
                        fansCurrentlyRunning = true
                        state = controlService.transition(.profileActive("Rule: \(decision.sourceRuleName)"))
                    case .setRPM(let rpm):
                        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
                        lastAppliedRPMPercent = min(max(rpm / maxRPM, 0), 1)
                        fansCurrentlyRunning = rpm > 0
                        state = controlService.transition(.profileActive("Rule: \(decision.sourceRuleName)"))
                    case .resetAuto:
                        lastAppliedRPMPercent = 0
                        fansCurrentlyRunning = false
                        state = controlService.transition(.idle)
                    }
                    preempted = true
                }

                if preempted {
                    if decisionChanged {
                        TFLogger.shared.event(ThermalEvent(type: .ruleTriggered, details: "rule=\(decision.sourceRuleID) name=\(decision.sourceRuleName)"))
                    }
                    lastRuleDecision = decision
                    onUpdate?(status, activeProfile, state, calibrationState)
                    return
                }
            }
        }

        lastRuleDecision = nil
        lastRuleCommandAppliedAt = nil

        // Profile-specific logic — fan min/max are firmware-static (cached).
        // Track whether the applied fan speed actually moved this tick: that's
        // the signal for fast polling (ramping) vs relaxing (holding steady).
        let appliedBefore = lastAppliedRPMPercent
        let runningBefore = fansCurrentlyRunning
        let limits = (sensorProvider as? FanControl)?.primaryFanLimits() ?? (2317, 7826)
        let (minRPM, maxRPM) = limits

        if activeProfile.id == "smart" {
            tickSmart(peakTemp: maxTemp, minRPM: minRPM, maxRPM: maxRPM)
        } else {
            tickCurve(peakTemp: maxTemp, minRPM: minRPM, maxRPM: maxRPM)
        }
        let fanChanged = lastAppliedRPMPercent != appliedBefore || fansCurrentlyRunning != runningBefore

        // Publish whenever this tick produced the full UI status snapshot.
        if let status { onUpdate?(status, activeProfile, state, calibrationState) }

        applyCadence(maxTemp: maxTemp, fanChanged: fanChanged)
    }

    // MARK: - Monitor Cadence (target ~2 seconds)

    /// Heavy operations: process capture + anomaly detection.
    /// Targets 2-second intervals, bounded by the adaptive thermal poll.
    private func monitorTick(status: ThermalStatus, maxTemp: Float) {
        // Rolling process buffer — captures what was running BEFORE a spike, but
        // only while the machine is warm enough for one to matter. At true idle
        // the sysctl(KERN_PROC_ALL) sweep is pure overhead, so skip it and drop
        // any stale snapshots. Anomaly detection below still runs every cycle.
        if maxTemp >= Self.processCaptureFloor {
            let currentProcs = captureTopProcesses()
            let ts = isoFormatter.string(from: Date())
            processBuffer.append((timestamp: ts, processes: currentProcs))
            if processBuffer.count > 15 { processBuffer.removeFirst() }
        } else if !processBuffer.isEmpty {
            processBuffer.removeAll()
        }

        if !isCalibrating {
            var spikeDetected = false

            // Tier 1: instant spike — >5°C between consecutive monitor readings.
            if let prevTemp = anomalyHistory.last {
                let instantDelta = maxTemp - prevTemp
                if abs(instantDelta) > 5 {
                    let direction = instantDelta > 0 ? "spike" : "drop"
                    let fan0 = status.fans.first
                    TFLogger.shared.info(
                        "Instant \(direction): \(String(format: "%.1f", prevTemp))→\(String(format: "%.1f", maxTemp))°C " +
                            "(\(String(format: "%+.1f", instantDelta))°C in 2s) | " +
                            "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                            "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                }
            }

            // Tier 2: sustained change — >10°C over 30 seconds.
            if anomalyHistory.count >= 15 {
                let oldest = anomalyHistory.first!
                let sustainedDelta = maxTemp - oldest
                if abs(sustainedDelta) > 10 {
                    let direction = sustainedDelta > 0 ? "spike" : "drop"
                    let fan0 = status.fans.first
                    TFLogger.shared.info(
                        "Sustained \(direction): \(String(format: "%.1f", oldest))→\(String(format: "%.1f", maxTemp))°C " +
                            "(\(String(format: "%+.1f", sustainedDelta))°C in 30s) | " +
                            "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                            "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                    anomalyHistory.removeAll()
                }
            }

            if spikeDetected {
                TFLogger.shared.info("Pre-spike process history (last \(processBuffer.count) samples):")
                for entry in processBuffer {
                    TFLogger.shared.info("  \(entry.timestamp): \(entry.processes)")
                }
            }
        }

        anomalyHistory.append(maxTemp)
        if anomalyHistory.count > 15 { anomalyHistory.removeFirst() }
    }

    // MARK: - Smart Profile

    private static let smartCeiling: Float = 85.0
    private static let smartFloor: Float = 53.0
    private static let smartStopTemp: Float = 50.0

    private func tickSmart(peakTemp: Float, minRPM: Float, maxRPM: Float) {
        let minPct = minRPM / maxRPM

        if peakTemp < Self.smartStopTemp && fansCurrentlyRunning && rateOfChange() <= 0 {
            applyCommand(.resetAuto)
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            state = controlService.transition(.idle)
            TFLogger.shared.fan("Smart fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(Self.smartStopTemp))°C")
            return
        }

        if peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        if peakTemp >= Self.smartStopTemp && peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        let sustainedTicksNeeded = Int(activeProfile.curve.sustainedTriggerSec / tickInterval)
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [Smart]")
            }
            return
        }

        let rate = rateOfChange()
        var targetPct: Float

        if let cal = calibration, let calPct = cal.fanPercentForTemp(peakTemp) {
            targetPct = calPct
            if rate > 0 {
                let urgency = min(max((peakTemp - Self.smartFloor) / (Self.smartCeiling - Self.smartFloor), 0), 1)
                targetPct = min(targetPct + rate * 0.15 * (1 + urgency), 1.0)
            }
        } else {
            let range = Self.smartCeiling - Self.smartFloor
            let position = min(max((peakTemp - Self.smartFloor) / range, 0), 1)
            targetPct = position * position * (3 - 2 * position)
            if rate > 0 {
                targetPct = min(targetPct + rate * 0.2, 1.0)
            }
        }

        if peakTemp > Self.smartCeiling {
            targetPct = 1.0
        }

        targetPct = min(max(targetPct, 0), 1.0)
        if targetPct > 0 && targetPct < minPct {
            targetPct = minPct
        }

        let rampUp = activeProfile.curve.rampUpPerSec * tickInterval
        let rampDown = activeProfile.curve.rampDownPerSec * tickInterval

        if targetPct > lastAppliedRPMPercent {
            targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
        } else if targetPct < lastAppliedRPMPercent {
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Smart fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = controlService.transition(.profileActive("Smart"))
        } else if fansCurrentlyRunning {
            state = controlService.transition(.profileActive("Smart"))
        }
    }

    /// Temperature rate of change in °C per second (smoothed over history).
    private func rateOfChange() -> Float {
        tempHistory.ratePerSecond
    }

    // MARK: - Curve-Based Profiles

    private func tickCurve(peakTemp: Float, minRPM: Float, maxRPM: Float) {
        let curve = activeProfile.curve

        if curve.handsOff {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = controlService.transition(.idle)
            }
            return
        }

        guard let rawTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning) else {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = controlService.transition(.idle)
                TFLogger.shared.fan("Fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(curve.stopTemp))°C [\(activeProfile.name)]")
            }
            return
        }

        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / tickInterval)
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [\(activeProfile.name)]")
            }
            return
        }

        var targetPct = rawTarget <= 0.001 ? minRPM / maxRPM : rawTarget
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        let rampUp = curve.rampUpPerSec * tickInterval
        let rampDown = curve.rampDownPerSec * tickInterval

        if targetPct > lastAppliedRPMPercent {
            if !curve.instantEngage {
                targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
            }
        } else if targetPct < lastAppliedRPMPercent {
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C [\(activeProfile.name)]")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = controlService.transition(.profileActive(activeProfile.name))
        } else if fansCurrentlyRunning {
            state = controlService.transition(.profileActive(activeProfile.name))
        }
    }

    // MARK: - Process Capture

    /// Capture top 5 processes by CPU for anomaly logging.
    private func captureTopProcesses() -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return "unavailable" }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var results: [(name: String, cpu: Double)] = []

        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }

            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            guard !name.isEmpty, name != "kernel_task" else { continue }
            let cpuPct = Double(proc.kp_proc.p_pctcpu) / 100.0
            if cpuPct > 0.1 {
                results.append((name, cpuPct))
            }
        }

        let top5 = results.sorted { $0.cpu > $1.cpu }.prefix(5)
        if top5.isEmpty { return "idle" }
        return top5.map { "\($0.name)(\(String(format: "%.1f", $0.cpu))%)" }.joined(separator: ", ")
    }

    // MARK: - Helpers

    private func applyCommand(_ command: FanCommand) {
        do {
            try onFanCommand?(command)
        } catch {
            TFLogger.shared.error("Fan command failed: \(command) — \(error)")
        }
    }
}
