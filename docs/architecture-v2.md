# Architecture v2

## Layers

1. Hardware
- `FanControl` for SMC reads/writes
- `SensorProvider` and the injectable SMC backend for testability

2. Control
- `ThermalMonitor` runtime loop with adaptive polling: 1s while active, 2s
  while a fan-controlling profile is steady, and 5s while Silent is idle
- `RuntimeControlDecisionEngine` for deterministic safety, rule, and profile
  decisions without hardware or daemon I/O
- `ControlService` and `ControlStateMachine`
- `RuleEngine` and persistent rules

3. Transport
- `DaemonRequest` / `DaemonResponse` typed protocol
- `DaemonCodec` JSON serialization
- bounded newline-delimited socket frames with complete writes
- backward-compatible legacy text command fallback

4. Observability
- `TFLogger` rotating text logs
- `ThermalEvent` JSONL event stream
- `ThermalLogger` research session export
- `ThermalAnomalyObserver` with bounded temperature and process histories

## Runtime Flow

- App/CLI issues command -> daemon socket
- Daemon authorizes peer UID -> executes command
- App monitor polls sensors -> decision engine evaluates safety/profile/rules
- App monitor applies returned fan commands through the daemon boundary
- Rule evaluation happens after safety override check and before profile curve logic

## Safety Ordering

1. Hard safety override (95°C)
2. Rule engine decisions
3. Profile curve logic
4. Idle/hysteresis behavior
