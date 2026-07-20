# Code Simplification Plan

This document tracks the remaining work from the July 2026 code-simplification
audit. Completed audit fixes are recorded in git history; this file describes
future work only.

Baseline after the first audit batch:

- 68 tests pass across 14 suites.
- A production build succeeds.
- Calibration persistence, temperature classification, monitor timing, and
  daemon client transport have dedicated components or test seams.

## Working Rules

- Preserve observable behavior before changing it.
- Add a regression test before fixing a discovered correctness issue.
- Keep each independently verifiable fix or structural move in its own commit.
- Run `swift test` before every commit and a release build after each phase.
- Do not mix visualization, update notifications, or unrelated feature work
  into these refactors.

## Phase 1: Remaining Lifecycle and Ownership Fixes

### 1. Resume the daemon after interrupted calibration

Calibration currently stops the daemon and relies on `defer` to restart it.
The SIGINT handler calls `Darwin.exit`, which bypasses that `defer`, so Ctrl-C
can leave the daemon stopped.

Plan:

- Convert SIGINT into cooperative cancellation using a dispatch signal source;
  never run SMC, logging, or process operations inside a POSIX signal handler.
- Make normal completion, thrown errors, and interruption unwind through the
  same cleanup and daemon-restoration path.
- Make calibration waits interruptible so stress and fan cleanup begin promptly.
- Delete partial CSV output on interruption without touching the last completed
  calibration profile.
- Add tests for success, failure, and interruption cleanup decisions without
  requiring real SMC hardware or launchd.

Commit boundary: lifecycle coordinator, regression tests, and CLI integration.

### 2. Correct uninstall data ownership

`sudo thermalforge uninstall` resolves the effective home directory as root and
can leave the console user's application-support data and logs behind.

Plan:

- Reuse a shared root/console-user path resolver.
- Enumerate every removal target before deleting anything.
- Remove root and console-user ThermalForge data while retaining explicit,
  narrow paths.
- Report which locations were removed and which were already absent.
- Add path-injected tests; do not exercise real user directories in tests.

Commit boundary: shared user-path resolver and complete uninstall cleanup.

### 3. Make process and launchd failures explicit

Calibration, installation, and uninstallation repeat `Process` setup and often
discard launch errors or non-zero termination statuses with `try?`.

Plan:

- Add a small process runner returning stdout, stderr, and termination status.
- Add a launchd coordinator for list, bootout, and bootstrap operations.
- Centralize stopping the menu-bar app.
- Distinguish expected conditions such as "process not running" from actual
  command failures.
- Ensure failed install/resume operations produce a non-zero CLI exit status.

Commit boundaries:

1. Tested process runner.
2. Calibration lifecycle migration.
3. Install/uninstall migration.

## Phase 2: Consolidate Rule Handling

### 4. Replace the legacy custom temperature rule

The GUI currently exposes both the persistent priority rule engine and a
separate `TemperatureRule` path stored in `UserDefaults`. When the legacy rule
is enabled, it runs before and bypasses the persistent rule engine.

Plan:

- Represent the quick IF/THEN rule as a normal `ThermalRule` with a stable ID.
- Perform a one-time migration of the existing enabled state, trigger
  temperature, release temperature, and fan percentage.
- Preserve hysteresis by mapping the release temperature to
  `untilTempBelowC`.
- Remove `TemperatureRule`, `temperatureRuleEngaged`, its monitor branch, and
  the four legacy settings after migration.
- Present a single Rules section in the menu-bar UI.
- Verify that hard safety still preempts every rule and that priority/latching
  behavior remains deterministic.

Commit boundaries:

1. Settings-to-rule migration with tests.
2. GUI conversion to the persistent rule model.
3. Legacy monitor path removal.

### 5. Resolve the unused daemon rule API

The app and CLI read and write `rules.json` directly. The daemon's rule mutation
endpoints have no callers and resolve persistence under root's home, creating a
second disconnected rule store.

Recommended decision: remove `fetchRules`, `rules.list`, `rules.put`,
`rules.remove`, `rules.enable`, and `rules.disable` from the daemon protocol.
Also remove the now-unused rule payload fields from daemon request/response
models.

If external daemon rule clients must be supported instead, route all rule
storage through an explicitly selected console-user store and make the app and
CLI use that API. Do not retain two authoritative stores.

Commit boundary: protocol simplification, codec fixtures, and removal of daemon
mutation code.

Keep the legacy text fallback for basic fan commands until a deliberate 1.0
compatibility review.

## Phase 3: Split Calibration by Responsibility

`Calibration.swift` still combines lid detection, workload discovery, CPU/GPU
stress generation, equilibrium measurement, curve construction, CSV logging,
and top-level orchestration.

### 6. Isolate lid-state detection

- Introduce a `LidStateProvider` protocol.
- Put AppKit/CoreGraphics or IOKit-specific detection in a macOS implementation.
- Inject the provider into calibration and the monitor.
- Test lid-specific selection without depending on attached displays.
- Evaluate `AppleClamshellState` as the primary hardware signal, with a
  documented screen-based fallback if necessary.

Commit boundary: provider extraction with no calibration behavior change.

### 7. Extract stress workload ownership

- Move CPU worker planning and execution into `CPUStressWorkload`.
- Move Metal setup and dispatch into `GPUStressWorkload`.
- Combine them behind a small `CalibrationWorkload` interface.
- Make start/stop idempotent and keep resource cleanup deterministic.
- Retain the existing fractional CPU-load and selected-sensor tests.

Commit boundaries: CPU workload extraction, then GPU workload extraction.

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
