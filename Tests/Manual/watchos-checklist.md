# watchOS Manual Checklist

This checklist is the release gate for visible watch-pane and Digital Crown
behavior. Automated tests verify that crown events send successfully, but they
cannot observe the watch display or confirm scrolling.

Run the checklist from beginning to end before creating a release tag. The
bridge mechanism and tested-environment record live in
`Sources/CoreSimulatorBridge/as-tested.md`; this checklist records measured
response behavior. Do not commit a separate run log.

## Setup

- [ ] Install Xcode with at least one bootable watchOS runtime.

- [ ] Run the compatibility probe:

  ```sh
  make probe
  ```

  Find `C IndigoHIDMessageForDigitalCrownEvent (optional)` in the successful
  symbol list. If it instead says `optional: absent; feature disabled`, this
  environment cannot pass the crown steps.

> **The watch live track shuts down every running Simulator.** Save any work
> in them before continuing.

- [ ] Run the automated watch track first:

  ```sh
  DEVICETERM_LIVE_DEVICE_FAMILY=watch make test-live
  ```

  The track boots one watch, verifies that crown events send without wedging
  HID, and shuts down the watch when it finishes. Visual movement remains a
  manual check.

- [ ] Find a stock watch Simulator:

  ```sh
  xcrun simctl list devices available | grep -i 'Apple Watch'
  ```

  Choose the UDID of a Simulator in the `Shutdown` state. Avoid a custom watch
  you use for other work.

- [ ] Build and launch DeviceTerm:

  ```sh
  make run
  ```

  This rebuilds the app and stops any running DeviceTerm app and embedded
  daemon before launching the new bundle.

- [ ] Open a normal tab. Commands run in that shell pass through DeviceTerm's
  `xcrun` shim, which associates successful boots with the tab.

The menu-bar badge, a monochrome iPhone glyph followed by a count, reports
the number of owned booted Simulators. The glyph is fixed: it does not change
with the booted device's family, so a booted watch still shows the phone
glyph.

## Manual Release Gate

### 1. Attach and Size the Watch Pane

| # | Action | Expected |
|---|---|---|
| 1.1 | Run `xcrun simctl boot <watch-udid>` in the tab. | A Simulator pane attaches within a few seconds. The badge reads `1`. |
| 1.2 | Inspect the pane. | The watch face renders with the model's correct round or rectangular shape. It is not stranded as a small image in a wide black pane. |
| 1.3 | Drag the split divider inward. | The watch pane reaches a minimum width near 220 points. An iPhone pane stops near 380 points. |
| 1.4 | Run `deviceterm panes list`. | One row contains `<paneId>  <udid>  rendering  watch  sim`. |
| 1.5 | In another tab, attach an iPhone or iPad Simulator and run `deviceterm panes list`. | Its family column reads `phone` or `pad`, and its type column reads `sim`. |

### 2. Rotate the Digital Crown

| # | Action | Expected |
|---|---|---|
| 2.1 | Run `deviceterm button digitalCrown` from the clock face. | The watch opens the app view or app grid, providing content that can scroll. |
| 2.2 | Run `deviceterm crown 30`. | Content scrolls forward, upward, or toward the end of the list. |
| 2.3 | Run `deviceterm crown -30`. | Content scrolls in the opposite direction. |
| 2.4 | Run `deviceterm crown 5`, then `deviceterm crown 80`. | The larger magnitude produces visibly greater movement. |
| 2.5 | Run `deviceterm crown 200 --duration 400`. | The content scrolls smoothly for about 0.4 seconds instead of moving in one jump. |

### 3. Press Watch Hardware Buttons

| # | Action | Expected |
|---|---|---|
| 3.1 | Run `deviceterm button digitalCrown` from inside an app. | The watch returns to the clock face or app grid. |
| 3.2 | Run `deviceterm button side`. | Control Center or the current watchOS side-button surface opens. |

### 4. Resolve the Target Pane

| # | Action | Expected |
|---|---|---|
| 4.1 | With the watch pane as your tab's only device pane, run `deviceterm crown 20` without `--pane`. | The command selects the sole device pane and scrolls it. |
| 4.2 | Boot a second Simulator from the same terminal, then run `deviceterm crown 20`. | The command fails with `multiple panes in this tab; pass --pane <ref>`. |
| 4.3 | Run `deviceterm crown 20 --pane <watch-udid>`. | The command selects the watch pane and scrolls it. |
| 4.4 | From inside a DeviceTerm tab, run `env -u DEVICETERM_SESSION -u DEVICETERM_SESSION_CAP deviceterm crown 20`. | The command reports that it is not inside a DeviceTerm tab because the two session credential variables are unset. |

### Pass Criteria

All steps in sections 1 through 4 must pass. If a step fails, fix the behavior,
rerun the affected section, then complete the checklist again from the
beginning.

Do not commit a run log. The fixes and release commit are the execution record.
Keep mechanism, constants, and tested environments in the Digital Crown section
of `Sources/CoreSimulatorBridge/as-tested.md`.

## Measured Behavior Reference

The following observations are not additional release steps. They document
measured watchOS behavior so operators can choose an appropriate command shape.

The measurements were recorded on 2026-05-24 with macOS 26.4.1, Xcode 26.5,
watchOS 26.5, and an Apple Watch Series 11 (46mm). Treat the values as results
from that environment, not as a cross-runtime guarantee.

### Crown Response With a Tight SwiftUI Binding

The test binding was:

```swift
.digitalCrownRotation(_:in: 0...1, by: 0.005, sensitivity: .medium)
```

Use a single crown event for precise placement on a tight floating-point
binding. Streamed events sent with `--duration` can fall below the watchOS
recognizer's per-event transition and produce no movement.

#### Single-Event Response

Reset the binding to `0` before each command:

| `deviceterm crown N` | Binding value |
|---|---|
| `1` | ~0.18 |
| `5` | ~0.5 |
| `7` | ~0.7 |
| `8` | ~0.95 |
| `9` | 1.0, saturated |
| `10` or greater | 1.0, saturated |

Values from 1 through 8 produced a smooth, approximately linear range. Values
of 9 or greater saturated this binding.

#### Streamed Response

| Command | Approximate delta per event | Result |
|---|---|---|
| `crown 5 --duration 500` (31 events) | ~0.16 | No movement |
| `crown 5 --duration 100` (6 events) | ~0.83 | No movement |
| `crown 5 --duration 50` (3 events) | ~1.67 | Moved to ~0.13 |
| `crown 60 --duration 1000` (62 events) | ~0.97 | No movement |
| `crown 100 --duration 1500` (93 events) | ~1.08 | Saturated at 1.0 |
| `crown 100 --duration 100` (6 events) | ~16.7 | Saturated at 1.0 |
| `crown 100` without duration | 100 | Saturated at 1.0 |

At approximately 60 Hz, this run observed no movement at a per-event delta of
`0.97` and movement at `1.08`. That places the transition between those values
for this binding and environment. It does not establish a fixed watchOS
constant.

A single event of magnitude `1.0` still moved the binding to approximately
`0.18`. Cadence, not only magnitude, affects whether watchOS accepts the
event.

For large totals such as `crown 100`, the binding saturates once enough
accepted movement reaches its maximum.

#### Practical Guidance

- For fine placement on a tight floating-point binding, omit `--duration` and
  use `deviceterm crown N` with `N` from 1 through 8.
- For coarse integer bindings and scrollable lists, streamed movement works
  when each event is large enough. Manual steps 2.4 and 2.5 cover this case.
- If a tight binding does not move, remove `--duration` before changing other
  parameters. The `deviceterm agents` guide carries the same troubleshooting
  advice.
- `--velocity` does not affect the current implementation because the
  SimulatorKit builder accepts only a delta.

### Swipe Behavior Across SwiftUI Gestures

The baseline command passed across nine SwiftUI configurations on the same
watchOS Simulator:

```sh
deviceterm swipe 0.5 0.8 0.5 0.2 --duration 400
```

Each variant wrapped `DragGesture(minimumDistance: N)` around a target view and
recorded `DRAG_CHANGED`, the final translation, and `DRAG_ENDED`.

| Variant | Configuration | Result |
|---|---|---|
| Baseline | `minimumDistance: 0`, Rectangle | 26 changes, `(0, -134)`, ended |
| A | `minimumDistance: 12`, Rectangle | 23 changes, `(0, -152)`, ended |
| B | `minimumDistance: 10`, Rectangle | 24 changes |
| C | `minimumDistance: 50`, Rectangle | 16 changes, accumulating correctly |
| D | `minimumDistance: 0`, ScrollView | 26 changes |
| E | `minimumDistance: 0`, List | 26 changes |
| F | `minimumDistance: 0`, `simultaneousGesture` | 26 changes |
| G | `minimumDistance: 0`, Circle target | 26 changes |
| H | `minimumDistance: 0`, `.focusable()`, and `.digitalCrownRotation` | 26 changes; crown remained at `0.289` before and after `crown 3` |

Variant C produced fewer change callbacks because the recognizer accumulated
motion until it crossed the larger minimum distance. The final gesture still
represented a path rather than an endpoint jump.

Variant H combined a focused crown control with a drag gesture. In this run,
the crown HID path and touch path did not interfere with each other.

#### Untested Gesture Configurations

The matrix does not cover these configurations:

- `.updating` with `@GestureState`, which uses different state-update
  machinery from `.onChanged` and `.onEnded`;
- modal hosts such as `.sheet`, `.fullScreenCover`, and
  `.confirmationDialog`, which can introduce another hit-test or focus layer;
  and
- `.highPriorityGesture` competing with `.gesture`, which can change
  recognizer ordering.

If a failure depends on one of these configurations, create a watchOS probe
view that logs `DRAG_CHANGED`, `DRAG_ENDED`, and the running translation. Add
the configuration as another matrix row once it has been measured.
