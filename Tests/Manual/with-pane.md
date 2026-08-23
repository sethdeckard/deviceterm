# `deviceterm with-pane` Manual Checklist

The parser, ref resolution (PaneRefResolver), and signal-to-exit-code
mapping (`CLICommands.mapChildExitCode(status:reason:)`) are covered by
unit tests in `Tests/CLITests/WithPaneTests.swift`. This checklist
covers the *end-to-end runner path* the unit tests can't see: the
actual subprocess spawn, env injection, stdin/stdout/stderr passthrough,
and signal propagation through the spawned child.

Run before any release that touches `Sources/DeviceTermCLI/main.swift`'s
`.withPane` dispatch case or `CLICommands.mapChildExitCode`.

## Preconditions

- A clean build: `make build`.
- Launch with `make run`. Open one tab.
- Boot at least one sim from inside the tab so `deviceterm panes list`
  shows a row. Note its UDID + shortId.

---

## 1. Resolution paths

| # | Action | Expected |
|---|--------|----------|
| 1.1 | `deviceterm panes list` — copy the UDID. Run `deviceterm with-pane <UDID> deviceterm tap 0.5 0.5`. | Tap fires on the sim. Receipt printed: `ok udid=<UDID> pane=<shortId> x=0.5 y=0.5`. |
| 1.2 | Copy the shortId (e.g. `phn001`). Run `deviceterm with-pane phn001 deviceterm tap 0.5 0.5`. | Same as 1.1. |
| 1.3 | Copy the first 4-8 chars of the paneId UUID. Run `deviceterm with-pane <prefix> deviceterm tap 0.5 0.5`. | Same as 1.1. |
| 1.4 | `deviceterm with-pane no-such-thing bash`. | Stderr: `deviceterm: no device pane matching 'no-such-thing' in this tab`, then a hint to run `deviceterm panes list`; exit 1. |

## 2. Env injection

| # | Action | Expected |
|---|--------|----------|
| 2.1 | `deviceterm with-pane <UDID> bash -c 'echo $DEVICETERM_TARGET_PANE'`. | Stdout: the resolved UDID. |
| 2.2 | `deviceterm with-pane <UDID> bash -c 'deviceterm tap 0.5 0.5'`. | Tap fires; the inner `deviceterm tap` auto-targeted via the env (no `--pane` needed). |
| 2.3 | `deviceterm with-pane <UDID> bash -c 'deviceterm tap 0.5 0.5 --pane <OTHER-UDID>'` (if you have a 2nd sim). | Tap fires on the OTHER sim — explicit `--pane` overrides the env fallback. |

## 3. Stdio passthrough

| # | Action | Expected |
|---|--------|----------|
| 3.1 | `deviceterm with-pane <UDID> cat` — type some lines + Ctrl-D. | The lines echo back; cat's stdin is the terminal's stdin. |
| 3.2 | `echo hello \| deviceterm with-pane <UDID> cat`. | Stdout: `hello`. Piped stdin reaches the child. |
| 3.3 | `deviceterm with-pane <UDID> bash -c 'echo out; echo err >&2'`. | `out` on stdout, `err` on stderr (test by `2>/dev/null`). |
| 3.4 | `deviceterm with-pane <UDID> ls /no-such-dir; echo "exit=$?"`. | ls prints its error to stderr; exit code propagates from ls (typically 2 on macOS). |

## 4. `--json` precedence vs. child argv

| # | Action | Expected |
|---|--------|----------|
| 4.1 | `deviceterm with-pane <UDID> bash -c 'echo got --json'` (no `--json` to deviceterm). | Stdout: `got --json` — the literal string. deviceterm does not interpret the child's flags. |
| 4.2 | `deviceterm with-pane <UDID> myscript --json`. | The child `myscript` receives `--json` as its arg. deviceterm's strip respects with-pane's literal tail. |
| 4.3 | `deviceterm --json with-pane <UDID> myscript --json`. | Same as 4.2 — the trailing `--json` reaches the child even when a global `--json` precedes `with-pane`. |

## 5. Signal propagation

| # | Action | Expected |
|---|--------|----------|
| 5.1 | `deviceterm with-pane <UDID> bash -c 'exit 0'; echo "exit=$?"`. | `exit=0`. Orderly exit passes through. |
| 5.2 | `deviceterm with-pane <UDID> bash -c 'exit 15'; echo "exit=$?"`. | `exit=15`. Orderly non-zero exit passes through unchanged (NOT mapped to 143). |
| 5.3 | `deviceterm with-pane <UDID> bash -c 'kill -TERM $$'; echo "exit=$?"`. | `exit=143`. A SIGTERM-terminated child surfaces as `128 + 15 = 143` per shell convention, rather than the misleading `exit 15`. |
| 5.4 | `deviceterm with-pane <UDID> bash -c 'kill -INT $$'; echo "exit=$?"`. | `exit=130`. SIGINT → `128 + 2 = 130`. |
| 5.5 | Run `deviceterm with-pane <UDID> sleep 60` in a tab, then Ctrl-C. | deviceterm-cli exits; the printed `$?` (if you wrap it: `deviceterm with-pane ... sleep 60; echo $?`) shows `130`. (Or run in a script that captures exit.) |

## 6. Combination flows

| # | Action | Expected |
|---|--------|----------|
| 6.1 | `deviceterm with-pane <UDID> bash -c 'deviceterm tap 0.5 0.5 && deviceterm crown 5 && deviceterm ax tree \| jq -r .tree.role'`. | All three nested deviceterm calls run against the same sim; the final pipeline prints the tree's root role (e.g. `AXApplication`). Exit 0. |
| 6.2 | `deviceterm with-pane <UDID> --json bash -c '...'`. | Note: `--json` after with-pane's verb is the child's arg, NOT deviceterm's; bash receives `--json` literally. Confirm that with-pane's `outputMode` is .human (no JSON output from deviceterm itself). |

---

## Pass criteria

- §1 — All four refs resolve correctly; ambiguous/notFound errors are clear.
- §2 — Env injection survives subshells; explicit `--pane` overrides env.
- §3 — Stdin/stdout/stderr are transparent; exit code of orderly children propagates.
- §4 — Child argv preservation works regardless of pre-verb `--json` position.
- §5 — **Signal-terminated children report `128 + signum`, not the raw signal number.**
- §6 — Composition with other deviceterm commands works inside the child.

There is no committed run-log: the fix commits are the record.
