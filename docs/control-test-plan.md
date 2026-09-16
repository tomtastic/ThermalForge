# Fan-control regression and release test plan

This plan responds to the RC3/RC4 failures on Mac17,7 running macOS 27. It defines
tests for the observed failures and related classes of errors. Passing simulations
does not establish firmware compatibility or exhaust every possible failure.

## What was missed

RC4 reported `F0Tg: requested 2317.0 RPM, read back 4224.0 RPM` after the write call
succeeded. The actuator required the first target read to match. That assumption
was embedded in successful fake-hardware responses: accepted writes immediately
updated readable targets. Delayed writes were tested as failures requiring safe
handback, but there was no positive test requiring an eventually acknowledged write
to succeed. Testing safe failure did not establish successful control.

The screenshot proves an immediate mismatch, **not** that the physical firmware
eventually accepted the target. RC5's bounded acknowledgement wait addresses one
plausible cause. Persistent rejection, clamping or another hardware requirement
still needs physical diagnosis if the new candidate fails.

There were separate integration gaps:

- The GUI recovered automatically from local control errors as though they were
  communication outages. Component restoration tests did not exercise that policy
  through the real backend and client together.
- The actuator accepted fractional target readback within 1 RPM, but subsequent
  backend sensing compared integer values exactly, causing repeated writes.
- The menu displayed a remembered profile without requiring an active GUI session.
  A picker could also suppress a click on the already selected profile. Presentation
  and session ownership were not tested through that complete interaction.
- Earlier service tests used a synchronous fixture entry point, missing the actual
  asynchronous CLI/run-loop startup boundary.

The review should have challenged these assumptions explicitly. A growing test
count and successful builds were insufficient evidence for the user-visible flow.

## Required contract and evidence

Model transport acceptance, firmware acceptance, readable mode, readable target,
actual RPM, sensor freshness and client ownership independently. A successful write
call is not an acknowledgement; actual RPM need not immediately equal the target.
Fake responses must not automatically follow the state the implementation wants.

Every scenario must check both its expected outcome and forbidden intermediate
events. Record a monotonic journal of permission persistence, writer identity,
generation/session, mode/target reads and writes, cancellation, process exit,
restoration and client-visible snapshots. Keep the test oracle independent of the
production encoder and decision helper where practical.

Required invariants:

1. Durable recovery permission precedes every manual operation.
2. Manual success is published only after all affected fans acknowledge target and
   manual mode. Preparation cannot keep reporting previously verified Apple control.
3. An accepted target is written once while awaiting acknowledgement. Quantization
   accepted initially remains accepted on subsequent sensing cycles.
4. Cancellation, ownership loss and expired deadlines prevent further control
   writes. A blocking call returning late cannot turn timeout into success.
5. Local control failure pauses the session, preserves useful diagnostics and
   requires explicit retry. Genuine backend outages retain the intended recovery
   behaviour; takeover and explicit Apple control cannot be undone by reconnection.
6. Independent recovery writes only after confirmed controller exit. Unverified
   restoration blocks new manual control and retains recovery responsibility.
7. Status polling cannot advance the protection lease. Observers cannot acquire,
   renew or release another client's ownership.
8. Calibration workloads stop before handback; interrupted or incomplete work is
   never saved or restarted automatically.

## Test matrix

“Covered” describes current automated coverage, not a claim that every permutation
has run. Rows marked “expand” or “pending” remain work to complete before promotion.

| Layer | Scenarios and required assertions | Coverage and next step |
| --- | --- | --- |
| Target acknowledgement | Immediate success; delayed success with stale initial target; never-applied write; rejection; clamping; unreadable/malformed target; mode lost while waiting. Delayed success must complete with one write per fan; persistent failure must pause and restore. | Covered by `FanSafetyTests` and `ControlPipelineTests`. The pipeline explicitly starts at 4224 RPM and eventually acknowledges a requested 2317 RPM. |
| Time boundaries | Acknowledgement just before, exactly at and just after the two-second deadline; unlock consumes most of the eight-second shared budget; cancellation during each wait; a read blocks past its deadline. Use injected monotonic time. | Delayed success, cancellation, shared budget exhaustion and late blocking reads covered. Expand the exact-boundary matrix, including cancellation concurrent with the final matching read. |
| Multiple fans and capabilities | First fan acknowledges, second is delayed/rejects; unequal fan limits; both mode-key variants; `Ftst` present, absent and unreadable; unreadable fan count; partial mode unlock. No overall success after only one fan. | Component and pipeline cases covered. Expand the delayed-success combinations across mode variants and `Ftst`, rather than assuming their independent tests establish every interaction. |
| Steady control and sensing | Fractional readbacks inside/outside the 1 RPM tolerance; actual RPM settles slowly while target is correct; target/mode drifts; CPU disappears while GPU remains; sensor/policy data returns after a paused failure. | Quantization, drift and sensor/policy failure covered. Add explicit independent actual-RPM lag and exact tolerance-boundary cases. Restored data must not silently restart a failed session. |
| Complete software control path | Real SMC adapter → actuator → backend → shared client, including JSON transport. Exercise manual RPM, Smart curve evaluation and Smart thermal override. During acknowledgement, status stays responsive and ownership stays unverified; subsequent ticks do not rewrite a stable target. | Delayed manual and Smart thermal-override success, eight fault models, fractional readbacks, drift and paused recovery covered. Expand delayed acknowledgement through ordinary Smart curve transitions and rule hysteresis. |
| GUI ownership and display | Remembered Smart without owner; live Smart idle under Apple; applying; acknowledged manual; failure; explicit Apple; CLI takeover; stale configuration reply. Display must reflect the live session and verified ownership. | Six tests use the actual `ControlPresentation` implementation. Pure presentation tests do not establish real AppState wiring or click delivery. |
| GUI interaction sequence | Select Smart → failure → same-row retry; explicit Apple → remembered Smart → select Smart; CLI takeover → GUI observer → CLI exit; restart/reconnect and configuration refresh between each step. Assert the command/session created by each click and the resulting visible state. | **Pending actual UI interaction coverage.** Build a hardware-free test harness with injected AppState/client dependencies and isolated services. Do not add production fake-hardware command switches. Before automation exists, run and record these interactions manually on the candidate. |
| Client races | Delayed/reversed replies, stale generations, expiry versus renewal, release during acquisition, takeover during a pending write, observer termination, backend restart after the GUI missed an error. | Shared-client, coordinator and subprocess tests cover these classes. Expand deterministic event-order permutations around acknowledgement and cancellation. |
| Independent recovery | Backend kill/stop; stalled sensing despite responsive status; client socket loss; recovery restart while idle/manual; failed marker persistence; partial restoration; unkillable/unknown process. Check journal ordering, retained markers and blocked replacement control. | Real-service subprocess and recovery component tests covered. Release fixtures use the actual async CLI entry boundary and optimized build configuration. |
| Calibration | Cancellation/client death/backend death, recovery communication loss, workload startup/shutdown failure, unavailable stressed sensors and saving races. No partial save; workloads stop before verified handback, or backend exits before independent recovery. | Component and subprocess coverage exists. Expand cancellation at every stage using the same acknowledgement delay/failure model. |
| Persistence and installation | Repeat migration, edits before import, concurrent revisions, reset tombstones, corrupt or unsafe files, missing launchd service, unreachable old recovery, install/uninstall handback failure. | Component tests cover ordering and failure retention. Actual launchd upgrade/removal remains a separate system test. |
| Candidate packaging | Build optimized production executables; run optimized tests with the matching fixture; inspect extracted archives, version/source identity, signature and CLI help; exclude fixtures. | Automated RC packaging checks. A passing source test suite cannot substitute for checking the delivered app. |

## Scenarios that would have caught this regression

Run the following as required positive acceptance tests, alongside failure tests:

1. Start two automatic fans with readable targets of 4224 RPM. Accept a request for
   2317 RPM immediately, but expose the new target only after 200 ms per fan. Keep
   actual RPM independent. Expect pending ownership while waiting, then acknowledged
   manual control, exactly two nonzero target writes and no error or handback loop.
2. Repeat through a live Smart session with temperatures crossing the configured
   curve trigger and then the thermal override. Check both successful control and
   subsequent idle handback without losing the armed profile.
3. Never expose the requested target. Expect bounded failure with key, requested and
   observed value preserved through the socket and menu, verified handback when
   possible, and no automatic reacquisition after later sensor updates or restart.
4. Restore the target behaviour, then click the same Smart row. Expect one fresh
   controlling session. A remembered profile or a UI highlight cannot count as an
   active session, and a repeated click must not be discarded.

The current pipeline automates scenario 1 and the thermal-override portion of 2;
failure tests cover 3. Ordinary curve transitions with delayed firmware and actual
click delivery in 4 still require the expansions identified above.

## Verify that the tests detect broken behaviour

In an isolated source copy, run the new delayed-success tests with the old RC4
`FanControl` implementation. They must fail because it rejects the first mismatching
readback; run the same tests on RC5 and require success. Never run this experiment
against installed services or physical hardware.

**Executed:** RC5 tests with only `FanControl.swift` replaced by RC4's version from
`c8bac2173b85968ae82ba6bd666c31dbc7ac8a1b` failed all three delayed-success cases
(two test functions). The manual pipeline reproduced the exact reported error:
`F0Tg: requested 2317.0 RPM, read back 4224.0 RPM`. All three cases passed with RC5's
actuator in the full release suite. This proves detection of the immediate-readback
assumption under simulated delay, not the cause of the physical firmware response.

The isolated check used:

```sh
swift test -c release --disable-automatic-resolution \
  --filter 'delayed(Target|Firmware)Acknowledgement'
```

Further mutation checks to add to the test workflow:

| Deliberate regression | Test that must reject it |
| --- | --- |
| Skip polling or accept a write without readable acknowledgement | Delayed positive success and never-applied negative tests respectively |
| Accept a matching read after timeout or cancellation | Deadline/cancellation boundary matrix |
| Ignore manual-mode loss or publish after the first fan | Ownership-loss and delayed/failed second-fan cases |
| Leave cached Apple acknowledgement during preparation | Pending snapshot assertions in pipeline/subprocess tests |
| Restore exact integer comparisons or rewrite during polling | Fractional readback and operation-count assertions |
| Treat local hardware failure as an outage eligible for automatic recovery | GUI failure/restart tests with a durable revocation epoch |
| Bind menu selection to saved configuration or suppress repeated selection | Actual UI sequence tests once implemented |
| Refresh protection from status requests or restore before backend exit | Stalled-work and journal-ordering subprocess assertions |

An automated mutation campaign is not currently implemented. Merely listing these
checks is not evidence that they detect regressions.

## Physical and release gates

Before promoting a candidate beyond hardware testing, record results on direct-mode
and `Ftst` hardware. Include machine model, OS build, app/backend versions and source
commit; sensor freshness; each fan's mode, requested/readable target and actual RPM;
acknowledgement timing; session/restoration state; and complete errors.

- Verify foreground maximum control, explicit Apple restoration, ordinary Smart
  activation/idle hysteresis and repeated explicit selection after a paused failure.
  Confirm profile curves are actually evaluated, not just the emergency override.
- Verify CLI takeover leaves the GUI observing, CLI exit returns to Apple, observer
  termination preserves another owner and explicit Apple survives reconnect.
- Verify sleep/wake, calibration cancellation and installed-service upgrade/removal
  on the same release payload. Inspect handback for every fan and `Ftst` where present.
- If targets never acknowledge or handback remains unreadable, keep the candidate
  unverified and preserve diagnostics. Do not widen acceptance criteria simply to
  make the physical test pass.

Physical fault injection needs a controlled test session. Automated tests use fake
hardware, isolated sockets and state; they must not replace installed services.

## Current evidence

RC5 source: `fd0edcf41647d5d6937e9395811c3a3b5b1626ac`.

- Optimized release suite: **298 tests across 41 suites passed**, including 16
  subprocess scenarios: 14 faults, one delayed success and one startup check.
- Old-actuator replay: all three delayed-success cases failed as expected; the
  same cases passed in RC5's full release suite.
- Delayed-success regression tests, actual menu presentation tests and bounded
  acknowledgement changes are implemented.
- Actual GUI click automation, the matrix expansions above and physical RC5
  validation remain pending. The software suite is not a firmware compatibility
  certificate.

Promotion evidence must include outcomes for these outstanding gates, not simply
another passing test count. Update this document when a gate has actually run.
