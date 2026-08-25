# Tap registration manual checklist

`PaneCoordinatorBackendTests` asserts a tap call takes at least the dwell, and
`HIDClientLiveTests` asserts the sends themselves succeed against a booted sim.
Neither can see the thing that matters: whether the guest *acted* on the tap.

That gap is what this file covers. A contact too short to act on still reaches
the right view with gesture recognizers attached, so delivery succeeds and the
control stays silent, which no automated check in this repo can tell apart from
a working tap. A `UISwitch` is the case to watch: dragging its thumb works
either way, so the pane keeps feeling half functional.

Run before any release that touches `Sources/Daemon/Input/`,
`Sources/Daemon/Pane/PaneCoordinator.swift`,
`Sources/App/SimulatorContentView.swift`, or
`Sources/CoreSimulatorBridge/SimHIDClient.m`.

## Preconditions

- A current debug build of this checkout, launched as a bundle: `make run`. Its
  pre-flight (`instance-guard.sh ensure-clear`) stops this checkout's own app
  and daemon. If it reports BUSY, a foreign instance holds the singleton: quit
  the named one, from its checkout where it has one. Do not reach for `pkill`,
  which cannot tell the two apart.
- The daemon matters here specifically. The dwell lives in it, and it is
  lazy-spawned, so a daemon left over from an older build has no dwell and
  every row below fails for the wrong reason.
- One tab, with a sim booted from inside it.
- An iPhone or iPad simulator, on a Settings screen with a switch, such as
  Airplane Mode.

---

## 1. A click toggles a switch

| # | Action | Expected |
|---|--------|----------|
| 1.1 | One ordinary click on the switch. | It flips, on the first click. |
| 1.2 | Ten clicks, counting flips. | Ten flips. An even count leaves the switch where it started, which is the second way to check. |
| 1.3 | A click with the pointer held still. | It flips. Keep movement under the tap threshold: crossing it routes the gesture to the live-touch stream, which works regardless and would prove nothing. |

## 2. Every control kind, not only switches

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Single click a button, a list row, and a tab bar item. | Each responds on the first click. |

The dwell has to register across switches, buttons, rows, and tab items. A
failure in any control class fails this checklist.

## 3. The CLI path

| # | Action | Expected |
|---|--------|----------|
| 3.1 | Locate the switch with `deviceterm ax tree` or `deviceterm ax sweep`, then `deviceterm tap <x> <y>` at the centre of its normalized frame. | It flips. Same synthesis as a GUI click, and the path agents use. |

## 4. It stays a tap, not a hold

| # | Action | Expected |
|---|--------|----------|
| 4.1 | Watch the switch during a single click. | It flips outright. The thumb must not track the pointer and commit on release, which is what a press long enough to read as a hold does. |
| 4.2 | Press and hold about a second, then release. | The switch enters slide mode. That is the long-press promotion, a separate path from the tap. |

## 5. Simulator.app agrees

| # | Action | Expected |
|---|--------|----------|
| 5.1 | Open the same booted device in Simulator.app and click the same switch. | Same result as 1.1. Simulator.app forwards the real click, so it is the reference for what a tap should do. |

## 6. Physical device

Repeat 1.1 and 2.1 on a mirrored physical device pane
(Shell ▸ Mirror Physical Device…). Device panes share the synthesis, so the
dwell applies there too.

## 7. Measuring contact duration

`SimInputSynthesis.tapDwellMs` was chosen from the figures below. Re-run this
when the constant is in question: DeviceTerm has no built-in instrumentation
for contact duration, and the host-side request is not the duration the guest
sees.

Build a throwaway UIKit app that subclasses `UIWindow`, overrides
`sendEvent(_:)`, and logs each touch's `.began` and `.ended` `UIEvent.timestamp`
along with the interval between them. Intercept at the window rather than with
a gesture recognizer or an overlay, because the case being measured is a touch
that reaches a view and draws no reaction.

Give it four targets, each with its own counter: a `UISwitch`, a `UIButton`, a
bare `UIControl` subclass counting `beginTracking` and `endTracking`, and a
view carrying a bare `UITapGestureRecognizer`. Those exercise both gesture
recognition and `UIControl` tracking, and the counters separate what was
delivered from what reacted.

Drive it three ways:

- Ordinary clicks in a pane, for the tap path at the current dwell.
- `deviceterm long-press <x> <y> --duration 0`, for the no-dwell baseline. A
  zero duration skips the hold loop, leaving the down and up back to back with
  no suspension between them: the same backend sequence as a zero-dwell tap.
- `deviceterm long-press <x> <y> --duration <ms>` across a spread of holds, to
  sample where registration becomes reliable. Observed contact is noisy and not
  monotonic in the request, so sample several rather than looking for one
  crossover.

Recorded on an iPhone 17 Pro, iOS 27, 2026-08-15. Timing mode: per-interval
sleeps.

| Input | Observed contact | Result |
|---|---|---|
| Tap with the dwell removed | 0.1 to 6.6 ms | No reaction from any of the four targets |
| Ten ordinary clicks | 33 to 86 ms | All ten registered |
| `--duration` sweep, near the boundary | 12.3 ms / 14.2 ms | The 12.3 ms registered, the 14.2 ms did not |
| `--duration 50` | 154 to 194 ms | Registered, and the switch entered drag tracking |

The first row was collected from the tap path with `tapDwellMs` set to zero.

Observed contact ran several times the requested hold in that sweep. At least
two mechanisms can contribute. The daemon added each sleep's scheduler lateness
to a running nominal total, so a longer hold compounded more of it; the paced
loops sleep to absolute deadlines instead, which removes that one. The other is
the synchronous HID send, one on the down and one on the up, whose latency has
never been measured.

These figures characterize the per-interval-sleep implementation. Rerun the
procedure to characterize absolute-deadline pacing.

---

## Pass criteria

- 1.1 flips on the first click.
- 1.2 is ten for ten. A dropped click fails the checklist. Reproduce it and
  measure the observed contact (§7) before adjusting `tapDwellMs`. The
  duration is what separates a contact that was too short from a failure with
  some other cause.
- 2.1 responds on one click.
- 4.1 shows no slide.
- No row needs a second click to register.
