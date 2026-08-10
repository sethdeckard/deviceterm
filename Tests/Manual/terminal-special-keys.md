# Terminal Special-Keys Manual Checklist

The unit test for `KeyText.forwardable` covers the *decision rule* —
whether an `NSEvent.characters` codepoint should be forwarded to
libghostty as `text`. This checklist covers the *end-to-end behavior*:
every special key produces the expected terminal escape sequence and
the consuming TUI sees it. Run before any release that touches
`GhosttySurfaceView` or `KeyText`.

The Claude Code `1/2/3 + arrow + Enter` prompt is the headline case:
it exercises arrow navigation, Enter, and number shortcuts in one
surface. The rest of the checks verify nothing else regressed along
the same code path.

## Preconditions

- A clean build: `make build`.
- No leftover daemon: `pkill -f deviceterm-daemon` (the GUI lazy-spawns).
- Launch with `make run`. Open one tab; you'll drive everything from
  inside it.

---

## 1. Arrow keys in interactive menus

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Inside the tab, run `claude` (Claude Code CLI) and reach any prompt that shows `1/2/3` numbered options with arrow navigation. | The prompt renders. |
| 1.2 | Press **↑** then **↓** to move the selection. | Selection cursor moves up/down between options. No silent drop, no AppKit beep. |
| 1.3 | Press **←** / **→** if the menu supports horizontal navigation. | Selection moves accordingly. |
| 1.4 | Press **Enter**. | The highlighted option is chosen. |
| 1.5 | Press a number key (e.g. **2**) directly. | Option 2 is chosen by shortcut. |

## 2. Arrow keys in classic TUIs

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Run `vim file.txt`; press **i** to enter insert mode; press the arrow keys. | Cursor moves; no `[A` `[B` `[C` `[D` literal characters inserted. |
| 2.2 | Exit vim. Run `less /etc/services`; press the arrow keys. | Scrolls one line per arrow press (Up/Down). |
| 2.3 | In `less`, press **PgUp** / **PgDn**. | Scrolls one page per press. |
| 2.4 | In `less`, press **Home** / **End** (or **g** / **G** if no Home/End key on this keyboard). | Jumps to start / end. |
| 2.5 | Exit `less`. Run `htop` (or `top` if not installed); press the arrow keys. | Selection cursor moves through process rows. |

## 3. Editing keys at the shell prompt

| # | Action | Expected |
|---|--------|----------|
| 3.1 | At the zsh prompt, type a command but don't run it. Press **←** / **→**. | Cursor moves within the line; no literal characters appear. |
| 3.2 | Press **Home** then **End**. | Cursor jumps to start, then end of line. |
| 3.3 | Press **Option+←** / **Option+→**. | Cursor jumps by word (zsh default with libghostty's modifier mapping). |
| 3.4 | Press **Ctrl+A** / **Ctrl+E**. | Cursor jumps to start / end (POSIX control-byte path). |
| 3.5 | Type some characters, press **Backspace**, then **Forward Delete** (fn+Delete on a Mac keyboard). | Both delete as expected. |

## 4. Control bytes and Esc

| # | Action | Expected |
|---|--------|----------|
| 4.1 | At the prompt, press **Tab** twice (zsh menu completion). | Completion list appears. No `\t` literal printed. |
| 4.2 | Press **Esc** at the prompt. | No-op (or zsh's vi-mode toggle if configured); no `^[` literal. |
| 4.3 | Start a long-running command like `sleep 100`; press **Ctrl+C**. | Terminates; shell returns. |
| 4.4 | Press **Enter** on an empty prompt. | New blank prompt line. (Spot-check.) |

## 5. Function keys (PUA upper end)

| # | Action | Expected |
|---|--------|----------|
| 5.1 | In `vim`, press **F1** through **F4** if the keyboard surfaces them. | vim binding fires (help, etc.) — or vim shows the key as `<F1>` in command-line mode. No literal Private-Use codepoint printed. |
| 5.2 | If a function-key TUI app is handy (e.g., `mc`, `nano`'s F-key shortcuts). | F-key bindings work. |

## 6. Higher Unicode (regression spot-check)

| # | Action | Expected |
|---|--------|----------|
| 6.1 | At the prompt, type Hebrew / CJK / emoji via the macOS input source switch or an emoji picker. | Characters appear correctly at the prompt. (Regression check that the broader filter didn't accidentally clobber non-PUA Unicode.) |

---

## Pass criteria

- Every row in §1.1–1.5 (the original arrow-key reproducer) passes.
- Every row in §2–6 passes or is documented as a known-not-yet-supported
  case (link to the relevant issue).
- No AppKit beep on any tested key.

There is no committed run-log: the fix commits are the record.
