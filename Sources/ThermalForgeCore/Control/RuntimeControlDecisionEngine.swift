import Foundation

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

struct RuntimeFanLimits: Equatable {
    let minRPM: Float
    let maxRPM: Float
}

struct RuntimeControlInput {
    let status: ThermalStatus?
    let maxTemp: Float
    let fanLimits: RuntimeFanLimits
    let now: TimeInterval
    let tickInterval: Float
    let recordTemperatureRate: Bool
    let calibration: CalibrationData?
}

enum RuntimeControlNotice: Equatable {
    case safetyTriggered(Float)
    case safetyCleared(Float)
    case ruleTriggered(id: String, name: String)
    case fan(String)
}

struct RuntimeControlOutput: Equatable {
    let command: FanCommand?
    let fanChanged: Bool
    let shouldApplyCadence: Bool
    let isEngaging: Bool
    let notices: [RuntimeControlNotice]
}

final class RuntimeControlDecisionEngine {
    private static let commandRefreshInterval: TimeInterval = 5
    private static let smartCeiling: Float = 85
    private static let smartFloor: Float = 53
    private static let smartStopTemp: Float = 50

    private let controlService: ControlService

    private(set) var activeProfile: FanProfile
    private(set) var state: MonitorState = .idle

    private var lastAppliedRPMPercent: Float = 0
    private var fansCurrentlyRunning = false
    private var sustainedAboveCount = 0
    private var lastRuleDecision: RuleDecision?
    private var lastRuleCommandAppliedAt: TimeInterval?
    private var lastSafetyCommandAppliedAt: TimeInterval?
    private var temperatureHistory = TemperatureRateHistory()

    init(profile: FanProfile, controlService: ControlService) {
        activeProfile = profile
        self.controlService = controlService
    }

    var isEngaging: Bool {
        !activeProfile.curve.handsOff
            && !fansCurrentlyRunning
            && sustainedAboveCount > 0
    }

    func replaceRules(_ rules: [ThermalRule], enabled: Bool) {
        controlService.replaceRules(rules, enabled: enabled)
    }

    func switchProfile(_ profile: FanProfile) {
        activeProfile = profile
        lastAppliedRPMPercent = 0
        fansCurrentlyRunning = false
        sustainedAboveCount = 0
        lastRuleDecision = nil
        lastRuleCommandAppliedAt = nil
        lastSafetyCommandAppliedAt = nil
        if profile.id == "smart" {
            temperatureHistory.removeAll()
        }
        state = controlService.transition(.idle)
    }

    func evaluate(_ input: RuntimeControlInput) -> RuntimeControlOutput {
        if input.recordTemperatureRate, activeProfile.id == "smart" {
            temperatureHistory.record(input.maxTemp, at: input.now)
        }

        if input.maxTemp >= FanProfile.safetyTempThreshold {
            return holdSafety(input: input, triggerIfNeeded: true)
        }

        var notices: [RuntimeControlNotice] = []
        if state == .safetyOverride {
            if input.maxTemp < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees {
                state = controlService.transition(.safetyCleared)
                lastSafetyCommandAppliedAt = nil
                notices.append(.safetyCleared(input.maxTemp))
            } else {
                return holdSafety(input: input, triggerIfNeeded: false)
            }
        }

        if input.maxTemp >= activeProfile.curve.startTemp {
            sustainedAboveCount += 1
        } else {
            sustainedAboveCount = 0
        }

        if let ruleOutput = evaluateRule(input: input, notices: notices) {
            return ruleOutput
        }

        lastRuleDecision = nil
        lastRuleCommandAppliedAt = nil

        let appliedBefore = lastAppliedRPMPercent
        let runningBefore = fansCurrentlyRunning
        let profileResult: (command: FanCommand?, notices: [RuntimeControlNotice])
        if activeProfile.id == "smart" {
            profileResult = evaluateSmart(input: input)
        } else {
            profileResult = evaluateCurve(input: input)
        }
        notices.append(contentsOf: profileResult.notices)

        return RuntimeControlOutput(
            command: profileResult.command,
            fanChanged: lastAppliedRPMPercent != appliedBefore
                || fansCurrentlyRunning != runningBefore,
            shouldApplyCadence: true,
            isEngaging: isEngaging,
            notices: notices
        )
    }

    private func holdSafety(
        input: RuntimeControlInput,
        triggerIfNeeded: Bool
    ) -> RuntimeControlOutput {
        lastRuleDecision = nil
        lastRuleCommandAppliedAt = nil
        let shouldApplyCommand = lastSafetyCommandAppliedAt.map {
            input.now - $0 >= Self.commandRefreshInterval
        } ?? true

        if shouldApplyCommand {
            lastSafetyCommandAppliedAt = input.now
        }

        var notices: [RuntimeControlNotice] = []
        if triggerIfNeeded, state != .safetyOverride {
            state = controlService.transition(.safetyTriggered)
            fansCurrentlyRunning = true
            lastAppliedRPMPercent = 1
            notices.append(.safetyTriggered(input.maxTemp))
        }

        return RuntimeControlOutput(
            command: shouldApplyCommand ? .setMax : nil,
            fanChanged: shouldApplyCommand,
            shouldApplyCadence: true,
            isEngaging: isEngaging,
            notices: notices
        )
    }

    private func evaluateRule(
        input: RuntimeControlInput,
        notices: [RuntimeControlNotice]
    ) -> RuntimeControlOutput? {
        guard let status = input.status else { return nil }
        let temperatures = TemperatureSummary(status.temperatures)
        let context = RuleEvaluationContext(
            cpuTemp: temperatures.cpu ?? 0,
            gpuTemp: temperatures.gpu ?? 0,
            maxTemp: input.maxTemp
        )
        guard let decision = controlService.evaluateRules(context: context) else {
            return nil
        }

        let decisionChanged = decision != lastRuleDecision
        var preempted = false
        var command: FanCommand?
        var updatedNotices = notices

        if let profileID = decision.profileID,
           let targetProfile = FanProfile.builtIn.first(where: { $0.id == profileID })
        {
            if decisionChanged || activeProfile.id != targetProfile.id {
                activeProfile = targetProfile
            }
            preempted = true
        }

        let ruleLimits = status.fans.first.map {
            RuntimeFanLimits(minRPM: Float($0.minRPM), maxRPM: Float($0.maxRPM))
        } ?? RuntimeFanLimits(minRPM: 2317, maxRPM: 7826)
        if let resolvedCommand = decision.resolvedFanCommand(
            minRPM: ruleLimits.minRPM,
            maxRPM: ruleLimits.maxRPM
        ) {
            let shouldReapply = decisionChanged || lastRuleCommandAppliedAt.map {
                input.now - $0 >= Self.commandRefreshInterval
            } ?? true
            if shouldReapply {
                command = resolvedCommand
                lastRuleCommandAppliedAt = input.now
            }

            applyRuleState(command: resolvedCommand, decision: decision, status: status)
            preempted = true
        }

        guard preempted else { return nil }
        if decisionChanged {
            updatedNotices.append(.ruleTriggered(
                id: decision.sourceRuleID,
                name: decision.sourceRuleName
            ))
        }
        lastRuleDecision = decision

        return RuntimeControlOutput(
            command: command,
            fanChanged: command != nil,
            shouldApplyCadence: false,
            isEngaging: isEngaging,
            notices: updatedNotices
        )
    }

    private func applyRuleState(
        command: FanCommand,
        decision: RuleDecision,
        status: ThermalStatus
    ) {
        switch command {
        case .setMax:
            lastAppliedRPMPercent = 1
            fansCurrentlyRunning = true
            state = controlService.transition(.profileActive("Rule: \(decision.sourceRuleName)"))
        case let .setRPM(rpm):
            let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
            lastAppliedRPMPercent = min(max(rpm / maxRPM, 0), 1)
            fansCurrentlyRunning = rpm > 0
            state = controlService.transition(.profileActive("Rule: \(decision.sourceRuleName)"))
        case .resetAuto:
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            state = controlService.transition(.idle)
        }
    }

    private func evaluateSmart(
        input: RuntimeControlInput
    ) -> (command: FanCommand?, notices: [RuntimeControlNotice]) {
        let minPercent = input.fanLimits.minRPM / input.fanLimits.maxRPM

        if input.maxTemp < Self.smartStopTemp,
           fansCurrentlyRunning,
           temperatureHistory.ratePerSecond <= 0
        {
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            state = controlService.transition(.idle)
            return (
                .resetAuto,
                [.fan("Smart fans off: \(Self.temperature(input.maxTemp))°C below \(Int(Self.smartStopTemp))°C")]
            )
        }

        if input.maxTemp < Self.smartFloor, !fansCurrentlyRunning {
            return (nil, [])
        }

        let sustainedTicksNeeded = Int(activeProfile.curve.sustainedTriggerSec / input.tickInterval)
        if !fansCurrentlyRunning, sustainedAboveCount < sustainedTicksNeeded {
            let notices: [RuntimeControlNotice] = sustainedAboveCount == 1
                ? [.fan("Sustained trigger: \(Self.temperature(input.maxTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [Smart]")]
                : []
            return (nil, notices)
        }

        let rate = temperatureHistory.ratePerSecond
        var targetPercent: Float
        if let calibration = input.calibration,
           let calibratedPercent = calibration.fanPercentForTemp(input.maxTemp)
        {
            targetPercent = calibratedPercent
            if rate > 0 {
                let urgency = min(max(
                    (input.maxTemp - Self.smartFloor) / (Self.smartCeiling - Self.smartFloor),
                    0
                ), 1)
                targetPercent = min(calibratedPercent + rate * 0.15 * (1 + urgency), 1)
            }
        } else {
            let range = Self.smartCeiling - Self.smartFloor
            let position = min(max((input.maxTemp - Self.smartFloor) / range, 0), 1)
            targetPercent = position * position * (3 - 2 * position)
            if rate > 0 {
                targetPercent = min(targetPercent + rate * 0.2, 1)
            }
        }

        if input.maxTemp > Self.smartCeiling {
            targetPercent = 1
        }
        targetPercent = min(max(targetPercent, 0), 1)
        if targetPercent > 0, targetPercent < minPercent {
            targetPercent = minPercent
        }

        targetPercent = governedTarget(
            targetPercent,
            curve: activeProfile.curve,
            tickInterval: input.tickInterval,
            allowsInstantEngage: false
        )

        guard abs(targetPercent - lastAppliedRPMPercent) > 0.002 else {
            if fansCurrentlyRunning {
                state = controlService.transition(.profileActive("Smart"))
            }
            return (nil, [])
        }

        let targetRPM = max(input.fanLimits.maxRPM * targetPercent, input.fanLimits.minRPM)
        let wasRunning = fansCurrentlyRunning
        lastAppliedRPMPercent = targetPercent
        fansCurrentlyRunning = true
        state = controlService.transition(.profileActive("Smart"))
        let notices: [RuntimeControlNotice] = wasRunning
            ? []
            : [.fan("Smart fans on: \(Int(targetRPM)) RPM at \(Self.temperature(input.maxTemp))°C")]
        return (.setRPM(targetRPM), notices)
    }

    private func evaluateCurve(
        input: RuntimeControlInput
    ) -> (command: FanCommand?, notices: [RuntimeControlNotice]) {
        let curve = activeProfile.curve

        if curve.handsOff {
            guard fansCurrentlyRunning else { return (nil, []) }
            fansCurrentlyRunning = false
            lastAppliedRPMPercent = 0
            state = controlService.transition(.idle)
            return (.resetAuto, [])
        }

        guard let rawTarget = curve.targetPercent(
            at: input.maxTemp,
            fansCurrentlyRunning: fansCurrentlyRunning
        ) else {
            guard fansCurrentlyRunning else { return (nil, []) }
            fansCurrentlyRunning = false
            lastAppliedRPMPercent = 0
            state = controlService.transition(.idle)
            return (
                .resetAuto,
                [.fan("Fans off: \(Self.temperature(input.maxTemp))°C below \(Int(curve.stopTemp))°C [\(activeProfile.name)]")]
            )
        }

        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / input.tickInterval)
        if !fansCurrentlyRunning, sustainedAboveCount < sustainedTicksNeeded {
            let notices: [RuntimeControlNotice] = sustainedAboveCount == 1
                ? [.fan("Sustained trigger: \(Self.temperature(input.maxTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [\(activeProfile.name)]")]
                : []
            return (nil, notices)
        }

        var targetPercent = rawTarget <= 0.001
            ? input.fanLimits.minRPM / input.fanLimits.maxRPM
            : rawTarget
        targetPercent = min(
            max(targetPercent, input.fanLimits.minRPM / input.fanLimits.maxRPM),
            curve.maxRPMPercent
        )
        targetPercent = governedTarget(
            targetPercent,
            curve: curve,
            tickInterval: input.tickInterval,
            allowsInstantEngage: curve.instantEngage
        )

        guard abs(targetPercent - lastAppliedRPMPercent) > 0.002 else {
            if fansCurrentlyRunning {
                state = controlService.transition(.profileActive(activeProfile.name))
            }
            return (nil, [])
        }

        let targetRPM = max(input.fanLimits.maxRPM * targetPercent, input.fanLimits.minRPM)
        let wasRunning = fansCurrentlyRunning
        lastAppliedRPMPercent = targetPercent
        fansCurrentlyRunning = true
        state = controlService.transition(.profileActive(activeProfile.name))
        let notices: [RuntimeControlNotice] = wasRunning
            ? []
            : [.fan("Fans on: \(Int(targetRPM)) RPM at \(Self.temperature(input.maxTemp))°C [\(activeProfile.name)]")]
        return (.setRPM(targetRPM), notices)
    }

    private func governedTarget(
        _ target: Float,
        curve: FanProfile.Curve,
        tickInterval: Float,
        allowsInstantEngage: Bool
    ) -> Float {
        if target > lastAppliedRPMPercent {
            guard !allowsInstantEngage else { return target }
            return min(target, lastAppliedRPMPercent + curve.rampUpPerSec * tickInterval)
        }
        if target < lastAppliedRPMPercent {
            return max(target, lastAppliedRPMPercent - curve.rampDownPerSec * tickInterval)
        }
        return target
    }

    private static func temperature(_ value: Float) -> String {
        String(format: "%.1f", value)
    }
}
