# Code Simplification Plan

This document tracks the remaining work from the July 2026 code-simplification
audit. Completed audit fixes are recorded in git history; this file describes
future work only.

Current verified baseline:

- 136 tests pass across 28 suites.
- A production build succeeds.
- Calibration persistence, temperature classification, monitor timing, daemon
  client transport, cancellation cleanup, uninstall ownership, lid detection,
  CPU/GPU stress workloads, calibration cooldown, equilibrium sweep, and curve
  construction, rule persistence mutations, runtime anomaly observation, and
  runtime control decisions, and fan unlock/write paths have dedicated
  components or test seams. The CLI entry file now only registers commands.

## Working Rules

- Preserve observable behavior before changing it.
- Add a regression test before fixing a discovered correctness issue.
- Keep each independently verifiable fix or structural move in its own commit.
- Run `swift test` before every commit and a release build after each phase.
- Do not mix visualization, update notifications, or unrelated feature work
  into these refactors.

## Phase 6: Hardware and Transport Cleanup

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
