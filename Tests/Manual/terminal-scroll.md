# Terminal Pane Scroll Manual Checklist

The unit tests for `ScrollMods.pack` + `ScrollMomentum.from(NSEvent.Phase)`
pin the wire layout for trackpad/wheel events; `SurfaceScrollMath`
and `ColorLuma` tests pin the scroll-indicator geometry math + the
light/dark threshold. This checklist covers the *end-to-end feel* the
unit tests can't see: trackpad velocity matches Ghostty.app, inertial
coasting works after a lift, mechanical mouse-wheel events scroll
line-by-line, the Cmd / Opt scroll pass-through (pinch gestures) still
works on sim panes, and the overlay scrollbar appears + drags + adapts
to the terminal background.

Run before any release that touches `GhosttySurfaceView.scrollWheel`,
`ScrollMods`, `ScrollMomentum`, `SurfaceScrollView`,
`SurfaceScrollMath`, `ColorLuma`, or `GhosttyTerminalSurface.cellSize`.

## Preconditions

- A clean build: `make build`.
- No leftover daemon: `pkill -f deviceterm-daemon`.
- Launch with `make run`. Open one tab.
- A trackpad attached (precision deltas) AND, if available, a
  mechanical mouse wheel for §3. If you only have one input device,
  document that in the run notes.
- A reference for comparison: native Ghostty.app, iTerm2, or stock
  Terminal.app open in another window.

---

## 1. Trackpad scroll velocity (precision deltas)

| # | Action | Expected |
|---|--------|----------|
| 1.1 | In a tab, run `find /usr -type f 2>/dev/null \| head -2000`. The screen fills. | Output scrolls past; lands at the bottom of the scrollback. |
| 1.2 | Two-finger trackpad scroll up at a moderate pace. | Scrollback scrolls up at a feel comparable to Ghostty.app — not noticeably slower. |
| 1.3 | Compare side-by-side with Ghostty.app (same TUI / scrollback content if practical). | The two terminals' scroll speed and responsiveness match within a hair. |
| 1.4 | Two-finger scroll back down to the bottom. | Reaches the bottom (last line of `find` output); doesn't over-shoot or stick. |

## 2. Inertial / kinetic scroll (momentum)

| # | Action | Expected |
|---|--------|----------|
| 2.1 | At the bottom of the `find` output, perform a quick two-finger swipe up and *lift* your fingers. | Scrollback continues coasting after the lift, gradually slowing — same as Ghostty.app, Safari, or any other macOS app with momentum. |
| 2.2 | While coasting, tap to land. | Coasting stops immediately. |
| 2.3 | Repeat 2.1 several times in rapid succession (swipe-lift, swipe-lift). | Each swipe re-accelerates the coast (the `.began`/`.changed`/`.ended` phases compose). No jitter. |
| 2.4 | Swipe quickly downward at the bottom of the buffer. | No coast (you can't go past the bottom); does not jitter or beep. |

## 3. Mechanical mouse wheel (discrete steps)

> Skip §3 if no mechanical mouse is attached.

| # | Action | Expected |
|---|--------|----------|
| 3.1 | Spin the wheel up one click at a time. | Scrolls one or two lines per click; consistent. |
| 3.2 | Spin the wheel quickly. | Scrolls proportionally faster, still discrete steps. |
| 3.3 | Compare to Ghostty.app or iTerm2 with the same wheel. | Step size and responsiveness comparable. |

## 4. Edge cases

| # | Action | Expected |
|---|--------|----------|
| 4.1 | At a fresh prompt (no scrollback). Two-finger scroll up. | No-op (no scrollback to reveal); does not beep or scroll into garbage. |
| 4.2 | Run `vim` or `less` (full-screen TUI). Two-finger scroll inside. | TUI receives the scroll wheel events (libghostty translates to up/down arrow per app convention) — vim moves cursor; `less` advances pages. |
| 4.3 | Run a process that produces continuous output (e.g. `while :; do date; sleep 0.5; done`). Two-finger scroll up. | Scrollback unsticks from the bottom; new lines accumulate but the view stays where you scrolled to. (Lock-to-bottom on new output is libghostty's default.) |
| 4.4 | Scroll back to the bottom (or press End). | View re-locks to bottom; new output appears as it arrives. |

## 5. Sim-pane pass-through (regression check)

A sim pane's `SimulatorContentView` consumes every scroll event it
receives. Cmd or Opt held drives the pinch / rotation gestures; a bare
scroll goes to the pane's crown hook, which the view controller forwards
on a watch sim and drops on any other family. Nothing falls through to
the terminal pane below.

| # | Action | Expected |
|---|--------|----------|
| 5.1 | Boot a phone sim into a tab. Two-finger scroll over the sim pane (no modifier). | Nothing happens. The sim pane does NOT pinch-zoom, and the terminal below does NOT scroll: the pane consumes the event and the phone family has no crown to drive. |
| 5.2 | Hold ⌘ and two-finger scroll over the sim pane. | Pinch gesture fires (zoom in / out the rendered sim). Terminal pane below does NOT receive the scroll. |
| 5.3 | Hold ⌥ and two-finger scroll over the sim pane. | Rotation gesture (or whatever the Opt+scroll handler is wired to). Terminal pane below does NOT receive the scroll. |

## 6. Scroll indicator

The overlay scrollbar appears when the terminal pane has more
scrollback than the viewport. Trackpad / wheel events flow through
NSScrollView's clip view rather than directly through
`GhosttySurfaceView.scrollWheel` — §§1–4 still need to pass against
this path.

### 6a. Visibility + drag-to-scroll

| # | Action | Expected |
|---|--------|----------|
| 6.1 | At a fresh prompt (no scrollback), look at the right edge of the terminal pane. | No scroller visible (NSScrollView has nothing to indicate). |
| 6.2 | Run `find /usr -type f 2>/dev/null \| head -2000` to fill the scrollback, then hover near the right edge of the terminal pane. | The overlay scroller (a thin pill) fades in. Its proportion roughly matches "viewport rows / total rows". |
| 6.3 | Click and drag the scroller upward. | The terminal scrolls back through its scrollback as you drag. Releasing the drag keeps the new position; the engine reflects the row libghostty reported. |
| 6.4 | Drag the scroller back to the very bottom. | View re-locks to bottom; new output appears as it arrives (same lock-to-bottom semantics as §4.4). |
| 6.5 | Quickly drag the scroller all the way up. | Scrollback re-renders responsively — no visible jitter; the wrapper's `lastSentRow` guard suppresses `scroll_to_row` spam (one dispatch per row change). |

### 6b. Appearance + light/dark

| # | Action | Expected |
|---|--------|----------|
| 6.6 | With the default Ghostty dark theme (or a dark `background = …` in `~/.config/ghostty/config`), look at the scroller while dragging. | Light scroller pill against the dark terminal background (NSAppearance falls back to system; if system is dark mode, scroller is the bright/light variant). |
| 6.7 | If you have a light Ghostty theme available (e.g. Solarized Light), switch to it and reopen a tab. From inside that tab, fire a runtime OSC 11 (e.g. `printf '\e]11;rgb:fd/f6/e3\e\\'`). | Within one render tick, the scroller flips to the dark-pill variant (`.aqua` appearance) so it stays visible against the light terminal background. |
| 6.8 | (Optional) System Settings → Appearance → Show scroll bars: set to **Always**. Move the mouse over the scroller's track without touching the wheel. | Scroller briefly flashes when the mouse enters the tracking area (legacy-style hover hint). |

### 6c. Coordinate accuracy (Retina sanity check)

| # | Action | Expected |
|---|--------|----------|
| 6.9 | On a Retina (2×) display, fill the scrollback (`yes \| head -5000` works), then drag the scroller to a known row — e.g. count visible lines from the top. | The row you land on matches what you expect; the scroller's thumb proportion is correct (not 2× too tall or 2× too small). This confirms the `cellSize` backing-scale divide is correct. |

---

## Pass criteria

- Trackpad scroll feel in §1 matches Ghostty.app within reasonable
  subjective tolerance.
- Inertial coasting in §2 works (the headline scroll-polish fix).
- Mechanical wheel (§3) and edge cases (§4) behave; sim pane
  pass-through (§5) is intact.
- The scroll indicator (§6) appears + drags + adapts.
  Specifically: 6.1–6.5 cover visibility + drag-to-scroll, 6.6–6.8
  cover appearance, 6.9 covers Retina coordinate accuracy.

There is no committed run-log: the fix commits are the record.
