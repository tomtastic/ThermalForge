# `nextgen` component and interaction review

Reviewed against the central-backend implementation on `nextgen`, with the old
`main` flow at `87b66e2` documented in the README. This review combines source
inspection, regression tests and subprocess fault injection. It does not establish
physical firmware behavior or claim that all possible failures have been exhausted.

## Components

RC3 hardware testing on Mac17,7/macOS 27 reproduced an SMC write failure with
both Smart and the foreground maximum-speed command. The error's Foundation
description discarded the key and failure stage. Error descriptions now survive
the socket protocol; target failures include transport/firmware status or requested
versus observed RPM and ownership. The menu wraps the full error. No hardware
acknowledgement checks have been weakened: the precise firmware failure still
requires a run of the updated backend on the affected machine.

Actuator failure now revokes automatic profile recovery through the durable
configuration epoch and retains a separate control error after verified handback.
This stops repeated unlock/write/restore attempts, including from older v2 clients
and after restart. Explicit profile selection permits a fresh attempt. Tests use
the actual backend and shared GUI client together, cover failed restoration, and
retain the existing automatic-reconnection tests for communication outages.

The earlier component tests correctly rejected failed readbacks, but did not run
that failure through the GUI's recovery policy. The original subprocess broker
also echoed every accepted target exactly. `ControlPipelineTests` now injects at
the IOKit boundary and runs the actual SMC adapter, fan actuator, backend and GUI
client together. It separates transport acceptance, firmware acceptance, target
readback and mode changes, including delayed and partial writes.

This exposed a second defect: the actuator accepted a target within 1 RPM, while
subsequent backend sensing required exact integer equality. A -0.75 RPM readback
caused twelve target writes instead of two over five follow-up ticks. Both layers
now share the existing 1 RPM tolerance; a separate test still requires repair for
larger drift. Subprocess tests cover a GUI that misses the error across backend
restart, and the actual foreground CLI loop is tested for detailed error reporting
after completed handback. These tests check observable sequences and ownership,
not only whether an individual call throws.

| Component | Findings and changes | Verification |
| --- | --- | --- |
| Backend coordination | Serialized configuration mutations, publication and calibration admission separately from hardware and short request handling. Policy changes restore Apple ownership before replacing engine state. A normal policy handback preserves rule latches. Revocation persistence retries keep new control blocked until successful. | `BackendCoordinatorTests`: active-curve replacement, Apple-rule hysteresis, metadata edits, stalled sensing with responsive renewals, failed handback, sleep/wake and ownership revocation. |
| Policy and actuation | Shared RPM clamps to the intersection of all fans' limits. Steady manual sessions skip writes only when fresh modes and targets agree with acknowledged intent. Target/mode drift triggers repair or policy reconciliation. Missing idle sensors retain an error without repeated already-verified handback writes. | Steady-write count, target drift, unequal fan ranges, safety override/hysteresis, profile/rule and runtime decision suites. |
| SMC transport and sensing | Existing firmware-result and reply-size checks retained. Added bounded RPM decoding to prevent integer-conversion traps, exact temperature read sizes, cancellation checks around unlock discovery, and final manual-mode acknowledgement. Unknown sensor discovery is retried; confirmed absent keys stay cached. | `FanSafetyTests` and `FanControlTests`: oversized firmware values, transient CPU loss beside a working GPU, malformed readings, mode changes during target writes, both key variants, partial unlock and restoration. |
| Recovery | Found a restart gap when idle backend identity existed only in memory. Registration now persists even outside manual control; normal handback changes the record to idle and confirmed exit removes it. Manual authorization remains a separate durable transition. | Unit and real subprocess idle-restart tests; crash/stop fencing, PID reuse, unkillable/unknown process, marker persistence/clear failures and restoration retries. |
| Configuration and migration | Authoritative files now use bounded, ownership-checked, non-symlink reads and private fsynced replacements. Existing optimistic revisions, value-only imports, edit precedence, lid-specific migration and reset tombstones remain. | Storage suites cover repeated import, concurrent stale edits, corruption, symlinked files/directories, writable files, oversized files and reset across restart. |
| Calibration | Added an explicit saving boundary after completed measurements, confirmed workload exit and verified handback. Success waits for durable storage. Workload startup and GPU command failures abort instead of silently substituting CPU stress; GPU/combined jobs require the relevant sensor families. Workload shutdown deadlines use monotonic time. | Cancellation/client-death and shutdown-failure tests, a deliberately blocked save with responsive status/release, unavailable GPU, partial workload startup, runtime workload failure and missing stressed sensor family. |
| Shared client | Snapshot sequence and retired generations reject delayed observations. Observation during a pending mutation cannot discard its candidate ownership. Release and Apple restoration fence pending mutations; late responses cannot overwrite a newer ownership action. Owned lease maintenance needs one renewal response instead of status plus renewal. | `BackendClientTests`: delayed acquisition/release, observation during acquisition, reversed status replies, backend restart, explicit auto, takeover, lease expiry and observer termination. |
| Menu-bar app | Configuration edits are serialized and applied to current backend values; older configuration replies cannot replace newer UI state. Profile/auto tasks cancel superseded UI requests. Read-only outage sensing and explicit unknown ownership remain separate from backend control. | Shared client regressions plus app compilation and bundle smoke checks. No automated test claims to exercise real menu interaction or local firmware. |
| CLI | Foreground sessions still renew independently of display cadence and release only their own ownership. Calibration recognizes the saving phase. Status JSON remains compatible; unsupported per-fan sessions remain explicitly rejected. | Client, protocol, subprocess foreground-owner and bundle CLI smoke tests. |
| Socket transport | Reviewed absolute frame deadlines, credential authentication, live-socket collision checks, bounded frames and connection slots. Status does not refresh backend progress. | Slow-trickle deadline, stalled request beside another client, authentication, legacy-command rejection and disconnected socket tests. |
| Runtime and power lifecycle | Verified health polling cannot advance the work lease; shutdown cancels work and bounds backend lifetime when hardware blocks. Sleep invalidates owners; wake reconciles before fresh control. | Backend power tests and subprocess sensing stall, socket loss, backend death and recovery death/restart. |
| Installation and release | Added a persistent-inode installer lock, rejecting overlapping install/uninstall operations. Installer handback waits for exited registration reconciliation. Canonical executable symlinks are rejected. Uninstall removes a CLI symlink even after its target was deleted. Recovery remains on failed uninstall restoration. | Installer lock/order/failure tests, dangling-link cleanup, release build and signed app-bundle smoke checks. Fixtures remain excluded from the bundle. |

## Interactions and failure ordering

The parent-owned fake SMC broker retains hardware state across real process exits.
Its journal checks every manual mode, diagnostic-override and nonzero target write
against durable manual permission for the correct backend identity. Every independent
recovery write requires positive evidence that the tracked backend exited.

Subprocess scenarios cover backend `SIGKILL`, backend `SIGSTOP`, stalled sensing
despite responsive requests, disconnected clients, recovery death/restart both idle
and manual, partial restoration, absent sensors, failed marker persistence, calibration
owner death, unconfirmed workload shutdown, and recovery loss during calibration.
These tests execute the actual service coordinators with isolated sockets, state and
fake hardware; they neither replace installed services nor control physical fans.

Component tests cover additional boundaries that are easier to control precisely:
stale generations, late renewals/replies, GUI takeover followed by CLI exit, explicit
auto followed by restart, observer release, configuration revision conflicts, failed
save admission, partial unlock, unreadable `Ftst`, and saving versus cancellation.

## Verification result

- `swift test`: **266 tests across 38 suites passed**, including 12 real subprocess
  fault scenarios. This adds 27 regression tests to the initial `nextgen` implementation.
- `./Scripts/ci-smoke.sh`: release build, required production executables, CLI help,
  bundle metadata, fixture exclusion and strict signature verification passed.
- `git diff --check`: passed.

The full suite also exposed a test that checked protection between hardware mode
restoration and durable acknowledgement. It now waits for completion through the
independent recovery socket, because that scenario deliberately removes the backend socket.

## RC startup regression

Live RC2 installation exposed a service that exited cleanly after startup. The CLI
uses an asynchronous ArgumentParser entry point, which can invoke synchronous
service commands on a worker thread. Those commands tried to run the main thread's
run loop. The original subprocess fixture had a synchronous entry point and missed
this boundary.

Both services now run their calling thread's Core Foundation loop, retain a loop
source and keep their service objects alive for its duration. Power notifications
use that same loop. An explicit source also avoids the empty-loop return described
in [Apple's run-loop documentation](https://developer.apple.com/documentation/foundation/runloop/run()).
The fixture now uses the production async command boundary and actual backend
server lifetime, and selects the fixture matching Debug/Release test configuration.
The cold-start regression reproduced the premature return before the fix.

Installer retry now handles a loaded but unreachable old recovery job: stop and
confirm its exit, reconcile the durable backend identity using the recovery
coordinator, then verify handback. Failed process fencing or restoration retains
recovery and prevents replacement. Tests cover both absent and outstanding markers,
unkillable processes, failed handback and failed recovery restart.

## Release boundaries

- Direct-mode and `Ftst` machines still need physical handback, sleep/wake and
  calibration checks. Readable firmware acknowledgement is the software criterion;
  actual RPM can take time to settle.
- An unkillable controller or permanent SMC failure leaves restoration unverified
  and new control blocked. Simulations verify this behavior, not OS termination guarantees.
- Filesystem errors fail closed. Fsync and atomic rename are exercised by tests;
  sudden-power-loss behavior requires a separate environment and is not simulated here.
- Real GPU driver hangs, platform-specific sensor availability, GUI interaction and
  live launchd upgrade/removal still need system-level release testing.
