# Terminal Working Directory Projection Cost

`WorkspacePane.Terminal.cwd` requires a live process-table read for each
terminal. This record decides whether `pane list` and `tab show` may include
the field or must limit it to `pane show`.

Unit tests cover the authority gate, live-value source, omission behavior, and
collection policy. `deviceterm-e2e` scenario 9 covers startup directories,
ordinary `cd`, a nested interactive shell, return to the outer shell, ungranted
omission, and agreement across all three projection commands.

Neither layer measures the cost of reading several real terminal process trees
while a Simulator pane is rendering. This procedure remains manual because it
needs a running DeviceTerm GUI, real PTYs, and a live Simulator in one controlled
login session. Replace it with an automated performance target once that target
can provision and restore those resources without the UI harness.

Run the measurement again before changing
`WorkspaceProjection.includesTerminalCWDInCollections` or the process-selection
strategy. A run with a different terminal count or workload is not directly
comparable.

## Decision Rule

Keep CWD in both collection projections only when the added cost of each command
stays at or below:

- 16 ms median
- 33 ms p95

If either median reaches 12 ms or either p95 reaches 25 ms, also measure the
shell-fallback resolver path before deciding. Public projections cannot drive
that arm with a root-owned foreground process: their fresh anchor probe rejects
that process before resolution and omits `cwd`. Use temporary test-only timing
with verified anchor facts captured before the root-owned process takes the
foreground. That isolates the child-enumeration path without weakening the
production probe.

Measure the added cost as:

```text
includeNanoseconds - omitNanoseconds
```

Run both variants as a pair and alternate which one runs first. This controls
for a fixed warm-cache or order advantage.

## Recorded Result

Measured on 2026-09-12 with a debug bundle containing the terminal-CWD changes
in this record atop revision `0b1e210c88af71da62d34fcbd927124ca5d9bedf`.

The throwaway tab held 12 terminal panes and one rendering iPhone 17 Pro
Simulator pane. A secondary terminal ran `bash` while it waited on 40
`sleep 900` children.

Each operation received five warmup pairs followed by 30 measured pairs.
`include` ran first in 15 pairs and second in 15.

| Command | Added median | Added p95 | Min | Max | Include median / p95 | Omit median / p95 |
|---|---:|---:|---:|---:|---:|---:|
| `pane.list` | 8.726 ms | 12.686 ms | 3.295 ms | 17.519 ms | 9.482 / 13.570 ms | 0.868 / 1.011 ms |
| `tab.show` | 9.850 ms | 12.166 ms | 5.262 ms | 12.253 ms | 10.965 / 13.413 ms | 1.235 / 1.502 ms |

Both commands passed the decision rule. The largest median was 9.850 ms and
the largest p95 was 12.686 ms, so collection projections keep CWD enabled.

The fallback-resolver arm did not run. Neither near-budget trigger fired.

All 12 terminal rows carried `terminal.cwd` in both collection projections.

## Why the Child-Heavy Arm Stayed Fast

`TerminalWorkingDirectory` first tries the foreground process-group leader.
The test shell had the reader's effective UID and the anchored controlling TTY,
so the resolver accepted it after a fixed number of process reads.

The 40 children were never enumerated. `ProcInfo.childPids` belongs only to the
shell fallback, which runs when the foreground candidate cannot be used.

The production projection derives fresh anchor facts from the surface's current
foreground process before calling this resolver. A root-owned foreground process
fails that probe, so the public field is omitted instead of reaching the shell
fallback. The fallback can still run after successful anchor derivation when the
foreground candidate becomes unusable during resolution. If the ordinary result
approaches the budget, isolate that path with captured verified facts and
temporary test-only timing as described above.

## Workspace-Wide Listing

The recorded result covers one tab. `pane list --all` walks every
caller-visible tab, so its cost scales with the terminals in the whole
workspace rather than with the terminals in one tab.

This arm has not been measured. To do it, follow the procedure below with the
12 terminals spread across three windows instead of one tab, and build the
`pane.list` projection with `all` set to true.

## Repeating the Measurement

1. Add temporary timing around the `pane.list` and `tab.show` dispatch paths.
   Build both projections with `includeTerminalCWD` set to `true` and `false`.
   Emit one JSON Lines record per pair with `operation`, `includeFirst`,
   `includeNanoseconds`, and `omitNanoseconds`.
2. Build and launch a clean DeviceTerm session. Confirm the E2E preflight and
   record the window, tab, Simulator, and process baseline.
3. Open one throwaway tab and create 12 terminal panes, alternating right and
   down splits.
4. Boot one Simulator through the checkout's shim and wait until its pane
   reaches `rendering`.
5. In a secondary terminal, start a shell that waits on 40 `sleep 900`
   children. Record its process group so cleanup can target only those jobs.
6. Run five unrecorded pairs for each operation.
7. Clear the timing output, then run 30 recorded pairs for each operation.
   Alternate `includeFirst` so each order occurs 15 times.
8. Compute median as the mean of ranks 15 and 16. Compute p95 with nearest-rank
   selection, rank 29 for 30 samples.
9. If a near-budget trigger fires and `sudo -n` is available, capture verified
   anchor facts before a root-owned process takes the foreground. Add temporary
   test-only timing that calls `TerminalWorkingDirectory.resolve(for:)` with
   those facts while that process owns the foreground. Confirm the public
   projection omits `cwd`, and record the isolated resolver timing separately.
   Record the arm as not run when passwordless sudo is unavailable.
10. Stop the foreground job and kill only its verified `sleep 900` children.
    Close the throwaway tab, detach its Simulator pane, and shut down only the
    Simulator this run booted.
11. Confirm the workspace and Simulator fleet match the baseline. Remove the
    temporary instrumentation and timing output, then run `make verify`.

Do not commit the timing instrumentation or raw capture.
