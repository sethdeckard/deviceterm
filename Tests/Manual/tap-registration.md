# Tap Registration Manual Checklist

`make verify` checks the discrete-tap dwell, down/up ordering, coordinate
validation, selector resolution, authorization, and receipt shapes.
`make test-live` sends touch down and up through the real Simulator HID bridge,
but it cannot observe whether the guest acted on them.

The `deviceterm-device-e2e` playbook's scenario 1 closes that gap for the CLI
path. It runs both selector and coordinate taps, waits for the guest to settle,
and compares accessibility state before and after each tap.

This checklist retains the GUI mouse path, several UIKit control classes,
tap-versus-hold behavior, comparison with Simulator.app, and physical-device
behavior.

Run it before a release that changes `Sources/Daemon/Input/`,
`Sources/Daemon/Pane/PaneCoordinator.swift`,
`Sources/App/SimulatorPane/SimulatorContentView.swift`, or
`Sources/CoreSimulatorBridge/SimHIDClient.m`.

## Preconditions

- Install Xcode with an available iPhone or iPad Simulator runtime.
- Run `make verify`.
- Confirm that every running Simulator is disposable, then run
  `make test-live`. This track shuts down the entire Simulator fleet before
  testing and shuts down its test Simulator afterward.
- If testing the physical-device section, run `make test-device-live` with a
  connected, unlocked, trusted iPhone or iPad and Device Hub closed.
- Stop this checkout's app and daemon with `make kill-daemon`.
- Launch with `make run`. Stop if any command prints a
  `deviceterm-make: BUSY:` line.
- From a DeviceTerm tab, boot a shutdown iPhone or iPad Simulator and wait for
  its pane to render.
- From an agent running in that tab, invoke the `deviceterm-device-e2e` skill
  and run playbook scenario 1. Its selector and coordinate variants must both
  pass before continuing.
- Open a Settings screen containing a switch, such as Airplane Mode.

`make test-live` and `make test-device-live` prove that their respective
backends accept touch sends. They do not replace the visible guest assertions
below.

## 1. A click toggles a switch

| # | Action | Expected |
|---|---|---|
| 1.1 | Click the switch once. | It changes state on the first click. |
| 1.2 | Click it ten times while counting state changes. | It changes state ten times. The even count leaves it where it started. |
| 1.3 | Click while keeping the pointer still. | The switch changes state. Movement must stay below the tap threshold so the gesture does not become a live drag. |

## 2. Other control classes

| # | Action | Expected |
|---|---|---|
| 2.1 | Click a button, a list row, and a tab-bar item once each. | Every control responds on its first click. |

A failure in any control class fails the checklist. A switch is especially
important because dragging its thumb can still work when ordinary taps do not.

The E2E prerequisite proves a named reactive control through the CLI. This
section checks distinct control classes through DeviceTerm's GUI path.

## 3. A tap does not become a hold

| # | Action | Expected |
|---|---|---|
| 3.1 | Watch the switch during one ordinary click. | It changes state directly. Its thumb does not enter tracking mode before release. |
| 3.2 | Press and hold the switch for about one second, then release. | The switch enters slide mode. The long-press path remains distinct from an ordinary tap. |

## 4. Simulator.app comparison

| # | Action | Expected |
|---|---|---|
| 4.1 | Open the same booted device in Simulator.app and click the same switch. | It behaves the same as row 1.1. |

Simulator.app forwards the native mouse interaction and provides the reference
behavior for the same guest control.

## 5. Physical device

This section needs a mirrored physical device pane and may be skipped when no
device is available.

| # | Action | Expected |
|---|---|---|
| 5.1 | Repeat row 1.1 on the physical device pane. | The switch changes state on the first click. |
| 5.2 | Repeat row 2.1 on the physical device pane. | Each control responds on the first click. |

The physical backend uses the same discrete-tap synthesis, including the dwell.
`make test-device-live` proves that touch reaches the device's human-input
channel without error. These rows prove the visible result.

## 6. Measuring contact duration

`SimInputSynthesis.tapDwellMs` is two nominal display frames. Re-run this
procedure when changing that value or the pacing implementation. The
host-requested duration is not the duration the guest necessarily observes.

Build a throwaway UIKit app whose `UIWindow` subclass overrides
`sendEvent(_:)`. Log each touch's `.began` and `.ended` timestamps and the
interval between them. Intercept at the window instead of adding a gesture
overlay, so the logger observes touches even when the target view does not
react.

Give the app four independently counted targets:

- a `UISwitch`
- a `UIButton`
- a bare `UIControl` subclass that counts `beginTracking` and `endTracking`
- a view with a bare `UITapGestureRecognizer`

Drive them three ways:

- Ordinary clicks in a DeviceTerm pane.
- `deviceterm long-press <x> <y> --duration 0` for the no-dwell baseline.
  A zero duration sends down and up without a hold interval.
- `deviceterm long-press <x> <y> --duration <ms>` across several durations.
  Observed contact is noisy, so collect several samples rather than assuming
  one clean threshold.

The following measurements were recorded on an iPhone 17 Pro running iOS 27
on 2026-08-15:

| Input | Observed contact | Result |
|---|---|---|
| Tap with the dwell removed | 0.1 to 6.6 ms | No reaction from any target |
| Ten ordinary clicks | 33 to 86 ms | All ten registered |
| `--duration` sweep near the boundary | 12.3 ms and 14.2 ms | The 12.3 ms contact registered; the 14.2 ms contact did not |
| `--duration 50` | 154 to 194 ms | Registered, and the switch entered drag tracking |

The first row used the tap path with `tapDwellMs` set to zero.

These figures came from the earlier per-interval-sleep pacing implementation.
Current gesture pacing uses fixed deadlines so scheduler lateness does not
compound into the planned release time. Treat the table as design history, not
a current timing benchmark. Re-run the procedure before making a claim about
current observed contact duration.

The remaining difference between requested and observed duration may include
the synchronous HID sends on contact down and contact up. That latency has not
been measured separately.

## Passing the checklist

A release passes this layer when:

- `make verify` and `make test-live` pass.
- Both variants of `deviceterm-device-e2e` scenario 1 pass.
- Every applicable single-click row succeeds on the first click.
- Ten switch clicks produce ten state changes.
- An ordinary click does not enter slide mode.
- The optional physical-device rows pass when that hardware is part of the
  release test.

Do not commit a separate run log. Fixes and the release commit are the record.
