# Code Simplification Plan

This document tracks the remaining work from the July 2026 code-simplification
audit. Completed audit fixes are recorded in git history; this file describes
future work only.

Current verified baseline:

- 115 tests pass across 24 suites.
- A production build succeeds.
- Calibration persistence, temperature classification, monitor timing, daemon
  client transport, cancellation cleanup, uninstall ownership, lid detection,
  CPU/GPU stress workloads, calibration cooldown, equilibrium sweep, and curve
  construction have dedicated components or test seams. The CLI fan mutation
  commands have moved out of the root entry file.

## Working Rules

- Preserve observable behavior before changing it.
- Add a regression test before fixing a discovered correctness issue.
- Keep each independently verifiable fix or structural move in its own commit.
- Run `swift test` before every commit and a release build after each phase.
- Do not mix visualization, update notifications, or unrelated feature work
  into these refactors.

## Phase 4: Split the CLI and System Coordination

`Sources/thermalforge/ThermalForge.swift` still contains the watch, calibration,
logging, rule, install, uninstall, and daemon commands.

### 11. Split remaining command implementations

Suggested layout:

```text
Sources/thermalforge/
  ThermalForge.swift
  Commands/
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
