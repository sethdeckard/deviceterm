# Pane Snapshot Manual Check

This checks that the dev seat's debug build captures what a simulator pane
really draws. `make verify` covers which build counts as the seat, request
handling and refusals, the off-screen refusal, the writer's PNG and
`frames.json` output, and a burst ending cleanly with no window. It can't
observe a Metal readback from a live pane, or whether the bezel composite
lines up with the picture. Both need a running app with a simulator pane on
screen.

A live-simulator test could replace this check by capturing a booted sim's
pane and comparing frames, but none exists yet.

## Preconditions

- `make bless` in this checkout, then `make kill-daemon && make run`. Stop if
  either prints a `deviceterm-make: BUSY:` line.
- A simulator pane on screen in the selected tab. Record its UDID from
  `deviceterm pane list`.
- For row 3, an iPhone Duo pane, with `lock:sim` held for the run.

## Checks

| # | Action | Expected |
|---|---|---|
| 1 | Run `scripts/pane-snapshot.sh <udid> 1 /tmp/snap`. | It prints `"ok":true` and a frame count near the display's refresh rate. `/tmp/snap` holds `NNNN.png` files and `frames.json`. |
| 2 | Open one of the PNGs. | It shows the pane as drawn: the screen inside its bezel, upright, at the drawable's pixel size. |
| 3 | On a Duo, start the snapshot with `5` seconds, then run `deviceterm fold 30` while it runs. | Successive frames show the bend deepening. `frames.json` reports the angle and `creased` for each frame. |

Any process running as you can drop a request into the seat directory, just as
it can already read every session's cap. Only the seat's debug build answers,
and it writes only to the directory a request names.
