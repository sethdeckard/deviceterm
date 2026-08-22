# `tab send-input` Manual Checklist

`WorkspaceCommandsTests` covers the CLI parse and `FakeDaemonClient`
covers the dispatch, but no automated test in this repo drives a live
libghostty surface, so nothing hermetic can tell whether injected bytes
actually reached the shell *and ran*. This checklist pins that.

Run before any release that touches
`Sources/LibghosttyBridge/GhosttyTerminalSurface.swift`,
`TerminalPaneViewController.sendInput`, or the `tab send-input`
dispatcher.

The headline case is a trailing newline executing the command.
`ghostty_surface_text` is documented upstream as "treated like a paste",
and with bracketed paste on — zsh's default — a pasted newline is
inserted into the line buffer *literally* instead of accepting the line.
Newlines therefore travel the key path. §1 and §4 are the regression
guards for that; everything else checks nothing else moved along with
it.

## Preconditions

- A clean build: `make build`.
- No leftover app or daemon from this checkout: `make kill-daemon` (the GUI lazy-spawns).
- Launch with `make run`.
- **Two tabs.** A driver opened with Shell → Open Automation Tab
  (⌘⇧T), and an ordinary recorded tab. `send-input` is
  automation-only; from a plain tab it fails `error.scope_violation`.
- The recorded tab's ref from `deviceterm tabs list`, used as `<ref>`
  throughout.

---

## 1. A trailing newline runs the command

| # | Action | Expected |
|---|--------|----------|
| 1.1 | From the driver: `deviceterm tab send-input --tab <ref> -- 'echo hello\n'` | In the recorded tab the command appears **and executes**: `hello` on its own line, then a fresh prompt. It must not sit unexecuted at the prompt. |
| 1.2 | Same again with `--type-delay 45`. | Identical outcome, but the characters appear one at a time. It still executes on its own. |
| 1.3 | Send a payload with **no** trailing newline: `-- 'echo hello'`. | The text appears at the prompt and stays there, unexecuted. Nothing runs until you press Return by hand. |
| 1.4 | Send a bare newline: `-- '\n'`. | The recorded tab advances to a new blank prompt line. |
| 1.5 | Start something slow first (`sleep 20`), then send a paced command **while it runs**. | The characters echo as they arrive and the command executes once `sleep` exits, as they would if you typed them by hand. Crucially there must be **no `^[[200~` / `^[[201~` markers** anywhere. Visible paste wrappers mean injection regressed to `ghostty_surface_text`. |

## 2. Multi-line payloads

| # | Action | Expected |
|---|--------|----------|
| 2.1 | `-- 'echo one\necho two\n'` | **Both** commands run, in order, each with its own output and prompt. |
| 2.2 | Same with `--type-delay 45`. | Same, typed out. The second line does not begin until the first has been submitted. |

## 3. Pacing behaves

| # | Action | Expected |
|---|--------|----------|
| 3.1 | `--type-delay 0` | Instant, same as omitting the flag. |
| 3.2 | `--type-delay 5000` | Clamped to 1000 ms/char. Slow, but it finishes and the pane stays responsive. |
| 3.3 | Start a long paced send, then close the recorded pane mid-animation. | Typing stops. No crash, no input delivered to a surviving sibling pane. |

## 4. Chained commands keep every character

Rapidly queued sends must type out in order, evenly paced, losing
nothing at the boundary between commands.

Keep this check even when the driver is not involved: presenter-file
consumption and an injection fault both surface as a missing leading
character, and this is the cheapest place to tell them apart. Losses
that reproduce through `deviceterm tab send-input` alone are injection;
losses that appear only under `demo-present.sh` are the driver.

| # | Action | Expected |
|---|--------|----------|
| 4.1 | Fire three paced sends back-to-back without waiting, each `-- 'deviceterm tabs current\n'` at `--type-delay 45`. | All three run. Every line reads `deviceterm`, never a truncated `eviceterm`. No `command not found`. |
| 4.2 | Read the recorded tab's scrollback for the whole run. | No missing or duplicated characters anywhere, at any command boundary. |

## 5. End-to-end through the demo driver

| # | Action | Expected |
|---|--------|----------|
| 5.1 | From the driver, `scripts/demo-present.sh scripts/demo-example.txt --target <ref>`, advancing each step. | Each keypress types **and runs** one command. One prompt per command; commands never stack up in a single buffer. |
| 5.2 | Re-run with `--no-settle` and advance a step early, while a previous paced command is still typing. | The next command queues behind it and types out after. Order preserved, no interleaving, no lost characters. **`--no-settle` is required**: by default the driver waits for the recorded tab's screen to hold still before offering a step, so it will not let you advance mid-typing. Two back-to-back `deviceterm tab send-input` calls by hand test the same thing. |
| 5.3 | Run without `--no-settle` and try to advance during the boot step. | The driver refuses to offer the next step until the tab goes quiet, printing `waiting for the recorded tab display to settle…`. |

## 6. Control bytes and binding independence

Injection is entirely key events; nothing takes a paste path. The
consequences below are worth checking directly, because they all fail
silently.

| # | Action | Expected |
|---|--------|----------|
| 6.1 | In the recorded tab run `cat -v`. From the driver send `-- 'a\0b\n'`. Ctrl-C to quit `cat`. | `a^@b`, the `^@` being the NUL intact. `a b` means the paste encoder replaced NUL with a space; a bare `a` means the input truncated at the terminator. NUL is delivered as a synthesized Ctrl+Space, so this reflects the legacy encoder; an app using the Kitty keyboard protocol gets a CSI-u event instead, exactly as it would for a real Ctrl+Space. |
| 6.2 | In the recorded tab run `cat -v`. Send `-- 'x\ty\ez\n'`. | `x^Iy^[z`: tab and escape arrive as themselves, not as spaces. The paste path would have replaced ESC with a space. |
| 6.3 | Add `keybind = a=text:hello` to `~/.config/ghostty/config` and restart. Send `-- 'a\n'` paced, then send a payload **ending** in NUL: `-- 'echo hi\0'`. Now click and drag in the recorded pane to select text, and hover a URL if one is on screen. Remove the binding afterwards. | Ordinary selection and hovering; ctrl must not still read as held. This setup verifies that the modifier reset uses `.control_left`: the paced `a` fires the `.unicode` binding and stores a `bindingHash` that omits utf8, so an `.unidentified` release would collide with it and be dropped before `modsChanged` ran, stranding ctrl. Only a trailing NUL exposes it, since in `a\0b` the following `b` clears the state anyway. |
| 6.4 | Add an unmodified single-key binding to `~/.config/ghostty/config` (e.g. `keybind = a=text:hello`), restart, and send a command containing that letter **with** `--type-delay 45`, then **without**. | **Known limitation, record what you see rather than expecting a pass.** A multi-codepoint payload cannot match a single-codepoint binding and types literally; a one-codepoint payload can be swallowed. Paced input sends one Swift `Character` per event, and a `Character` may span several codepoints, so only the single-codepoint ones are exposed. An unpaced whole line is exposed only when the line itself is a single codepoint. `unmappedKeycode` only defeats *physical*-key triggers. Remove the binding afterwards. |

---

## Pass criteria

- §1.1 and §1.2 execute the command. This is the whole reason the file
  exists; a failure here means injected newlines regressed to the paste
  path.
- §1.3 does **not** execute. Injecting text without a newline must stay
  inert.
- §1.5 shows no bracketed-paste markers. Injection uses the key path
  end to end; nothing should ever be framed as a paste.
- §4 shows no character loss at any command boundary.
- §6.1 and §6.2 show the control bytes intact. Spaces in their place mean
  injection fell back to a paste, which sanitizes them.
- No crash, beep, or wedged pane in any row.

There is no committed run-log: the fix commits are the record.
