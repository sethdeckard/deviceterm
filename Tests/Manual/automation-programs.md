# Configured Automation Programs Manual Checklist

This checklist covers what a person has to see: AppKit surfaces that render, and the real cross-process sequence behind
a program's first run.

Run `make verify` first. It proves the configuration parser, the backoff schedule and give-up cap, the probe's
composition, the supervision state machine, close-gate arm selection, the two CLI verbs' parsing and output, and the
intent chain behind them. None of that is repeated here.

What it cannot observe: whether the failure notice and the close prompt actually draw, whether a real grant lands
before a real shell runs the command, and whether the foreground probe reads a real `login`-rooted process tree the way
its synthetic trees say it does. Every row below is one of those three.

The automated path for the first two is the `deviceterm-uitest` harness, which can make pixel and accessibility
assertions about DeviceTerm's own chrome. The third needs a PTY with a real login shell, and no automated path is
known.

Run this checklist before a release that changes configured automation programs, the close gate, or terminal
foreground detection.

## Preconditions

- Run `make verify`.
- Stop this checkout's app and daemon with `make kill-daemon`.
- Write `<config home>/deviceterm/automation-programs`, where config home is `$XDG_CONFIG_HOME` when that is a
  non-empty absolute path and `~/.config` otherwise:

```text
program grant-check
  command sh -c 'deviceterm doctor; deviceterm tab open --command "echo opened by grant-check"; while :; do sleep 3600; done'

program clock
  command sh -c 'while :; do date; sleep 5; done'

program crasher
  command sh -c 'exit 1'
```

`grant-check` puts its grant-dependent calls at the front of its command on
purpose. A program that occupies the foreground leaves no prompt to type at,
and running the same calls by hand later would only show a grant at whatever
moment you happened to run them.

- Launch with `make run`. Stop if it prints a `deviceterm-make: BUSY:` line.

Supervision polls every second, allows a program five seconds to appear, and backs off 1, 2, 4, 8, 16, 32 then 60
seconds. Reaching the give-up cap takes about five minutes. A run lasting longer than a minute resets the count, so do
not leave a program up between kills when driving toward the cap.

## 1. Launch and the real grant

| # | Action | Expected |
|---|---|---|
| 1.1 | Look at the tab strip after launch. | Three bolt-marked tabs titled `grant-check`, `clock` and `crasher`, in file order. |
| 1.2 | Read the top of the `grant-check` tab. | Its `doctor` output, printed before anything else it did, shows `automationGrant  true`. |
| 1.3 | Count the tabs. | Five: one ordinary, three bolt-marked configured ones, and one more printing `opened by grant-check`. That last tab confirms a live grant when the startup command issued `tab open`. |
| 1.4 | Open an Automation tab by hand with ⇧⌘T. | It has a shell prompt and a live grant. Configured tabs run their program in the foreground and have no prompt, so every `deviceterm` command below runs here unless a row says otherwise. |

## 2. Supervision against a real shell

| # | Action | Expected |
|---|---|---|
| 2.1 | Ctrl-C the `clock` program. | It restarts within a few seconds. The probe read a real `login`-rooted tree to see the exit. |
| 2.2 | Run `deviceterm automation status`. | `clock` is `running` with a `restarts` count and a `pid` that changed. |
| 2.3 | Leave `crasher` alone for about five minutes. | It reaches `failed` and stops restarting. |
| 2.4 | Look at the titlebar of that window. | A notice reads `crasher stopped`, with a dismiss control. |
| 2.5 | Click the dismiss control. | The notice goes away and leaves no gap in the titlebar. |

## 3. The close prompt

| # | Action | Expected |
|---|---|---|
| 3.1 | Close the `clock` tab. | A prompt names `clock` and says closing stops supervision for it. |
| 3.2 | Cancel it. | The tab stays and the program keeps running. |
| 3.3 | Put `tab-close-multi-pane = close` in `<config home>/deviceterm/config`, relaunch, reopen the ⇧⌘T tab, and close the `clock` tab again. | The prompt still appears. That key suppresses the multi-pane confirm and must not reach this one. Cancel it. |
| 3.4 | Run `deviceterm tab list` to find the `clock` tab's reference, then `deviceterm tab close <ref>`. | It closes with no prompt. Supply the reference because an omitted one targets the caller's own tab; the live grant is what authorizes closing another. |
| 3.5 | Run `deviceterm automation status`. | `clock` is `stopped`. |
| 3.6 | With a program still running, quit with ⌘Q. | No extra prompt beyond the usual quit behavior. |

## 4. Restart against a live terminal

| # | Action | Expected |
|---|---|---|
| 4.1 | With `clock` running, run `deviceterm automation restart --name clock`. | `^C` appears in its tab, then the command runs again. The command never lands in the running program's input. |
| 4.2 | Kill `clock`, then open `vi` in its tab before the backoff elapses. | `vi` is untouched and `clock` does not return while it is open. Automatic supervision waits for the terminal to be its own shell again. Explicit `automation restart` would interrupt `vi` instead; that is the difference between the two paths. |
| 4.3 | Close a program's tab, then restart that program by name. | A fresh Automation tab opens for it. |
| 4.4 | Run `deviceterm automation restart --name nope`. | It fails, naming the program it could not find. |

## 5. Nothing configured

| # | Action | Expected |
|---|---|---|
| 5.1 | Move the configuration file aside and relaunch. | One ordinary tab. No bolt, no notice, nothing in the log. |
| 5.2 | Restore the configuration file, delete one block's `command` line, relaunch, and run `log show --predicate 'subsystem == "com.deviceterm"' --last 2m`. | One line naming the block and its line number. DeviceTerm starts normally. |

## Passing the checklist

A release passes this layer when every applicable row succeeds after `make verify` has passed. Do not commit a separate
run log; fixes and the release commit are the record.
