# Code Simplification Plan

This document tracks the remaining work from the July 2026 code-simplification
audit. Completed audit fixes are recorded in git history; this file describes
future work only.

Current verified baseline:

- 107 tests pass across 21 suites.
- A production build succeeds.
- Calibration persistence, temperature classification, monitor timing, daemon
  client transport, cancellation cleanup, uninstall ownership, lid detection,
  and CPU/GPU stress workloads have dedicated components or test seams.

## Working Rules

- Preserve observable behavior before changing it.
- Add a regression test before fixing a discovered correctness issue.
- Keep each independently verifiable fix or structural move in its own commit.
- Run `swift test` before every commit and a release build after each phase.
- Do not mix visualization, update notifications, or unrelated feature work
  into these refactors.

## Phase 3: Split Calibration by Responsibility

`Calibration.swift` still combines intensity discovery, equilibrium
measurement, curve construction, CSV logging, and top-level orchestration.

### 8. Extract intensity discovery

- Move bracketing, cooldown decisions, equilibrium projection, and safe/useful
  classification into `WorkloadIntensityFinder`.
- Inject temperature sampling, workload control, fan control, and time/sleep
  behavior.
- Add deterministic tests for hot rejection, safe selection, cooldown timeout,
  and minimum-intensity failure.

Commit boundary: finder extraction and deterministic phase-one tests.

### 9. Extract equilibrium sweep and curve construction

- Move fan-level stabilization into `EquilibriumSweep`.
- Move stability metrics and acceptance thresholds into a focused convergence
  model.
- Move interpolation, monotonic enforcement, and coverage validation into
  `CalibrationCurveBuilder`.
- Keep raw measurements separate from generated 60–85°C control points.
- Test timeout exclusion, ceiling termination, insufficient coverage, and
  monotonic output.

Commit boundaries: convergence model, sweep coordinator, then curve builder.

### 10. Reduce `CalibrationRunner` to orchestration

After extraction, `CalibrationRunner` should coordinate phases, progress
messages, CSV recording, and final `CalibrationData` assembly. It should not
own sensor-family knowledge, Metal resources, worker threads, persistence, or
curve mathematics.

Commit boundary: final wiring and removal of superseded private helpers.

## Phase 4: Split the CLI and System Coordination

`Sources/thermalforge/ThermalForge.swift` still contains every command and the
launchd/application lifecycle helpers.

### 11. Split command implementations

Suggested layout:

```text
Sources/thermalforge/
  ThermalForge.swift
  Commands/
    FanCommands.swift
    StatusCommands.swift
    WatchCommand.swift
    CalibrationCommand.swift
    LoggingCommand.swift
    RuleCommands.swift
    InstallCommand.swift
    UninstallCommand.swift
    DaemonCommand.swift
  System/
    ProcessRunner.swift
    LaunchdCoordinator.swift
```

Move code without changing command names, options, output, or exit behavior.
Keep the root file limited to the `@main` declaration and command registration.

Commit boundaries should follow command groups so each move remains easy to
review and revert.

### 12. Consolidate repeated command mutations

- Give rule persistence tested add, remove, enable, disable, and replace
  operations instead of repeating array mutation in the CLI, GUI, and daemon.
- Share duration parsing and formatting where it is genuinely reused.
- Keep user-facing output in command types rather than core storage objects.

Commit boundary: one store/API consolidation at a time.

## Phase 5: Narrow the Runtime Control Loop

### 13. Separate observation from fan decisions

`ThermalMonitor.tick()` still performs sensor acquisition, safety evaluation,
rule preemption, profile control, anomaly logging, cadence changes, and UI
publication.

Plan:

- Keep sensor polling and scheduling in `ThermalMonitor`.
- Extract a pure control decision input/output model for safety, rules, and
  profiles.
- Keep actual daemon/SMC commands at the outer boundary.
- Move anomaly/process-history recording behind a separate observer.
- Add sequence tests covering safety trigger/clear, rule preemption, Smart
  ramping, hysteresis, and idle cadence transitions before moving logic.

Commit boundaries:

1. Sequence-test harness.
2. Anomaly observer extraction.
3. Control decision extraction.

## Phase 6: Hardware and Transport Cleanup

### 14. Simplify fan unlock and write paths

- Consolidate `unlockFans` and `unlockSingleFan` around one per-fan unlock
  primitive.
- Share RPM validation and target-key writes.
- Validate requested all-fan RPM against every fan's limits rather than only
  fan zero.
- Preserve the Ftst and M5 direct-mode hardware branches with fake-SMC tests.

Commit boundary: fan-control helper consolidation and per-fan limit tests.

### 15. Harden daemon server framing

- Reuse a complete-write helper for daemon responses.
- Define an explicit maximum request size and newline framing behavior.
- Handle interrupted and partial reads without changing the current JSON/text
  compatibility policy.
- Keep peer-UID authorization and serialized SMC access unchanged.

Commit boundary: server transport hardening with Unix-socket integration tests.

## Completion Criteria

The audit remediation is complete when:

- Only one rule model and one authoritative rule store remain.
- Calibration phases are independently testable without SMC hardware, Metal,
  launchd, real waiting, or attached displays.
- The CLI entry file only registers commands.
- `ThermalMonitor` scheduling, observation, and decision logic have clear test
  boundaries.
- Privileged operations consistently report failures and target both root and
  console-user state where appropriate.
- No tracked generated app bundle or superseded design document remains.
- The full test suite and production build pass after every phase.
