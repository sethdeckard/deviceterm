# Daemon Wedge Recovery

Four checks on what the daemon does when something it depends on stops
answering: CoreSimulator wedges, the GUI stops consuming frames, or the machine
sleeps with a mirror running. The fourth exercises the menu item that clears
the first. Each needs a live sim and a real GUI, and one needs a sleep cycle,
so none of them is automatable.

The unit tests cover the pieces in isolation. `SimBackendAcquirerTests` and
`PaneDisplayBootstrapTests` exercise deadline behavior with an injected sleep
and slot accounting with a parked bridge, for acquisition and display startup
respectively; `DaemonFootprintMonitorTests` exercises sample formatting and
cadence with injected samples and reporters. None of them can see a real
CoreSimulator refuse to answer or a real GUI stop acknowledging frames. That is
what this procedure is for.

Run it before tagging a release, and after any change to the acquire path, the
surface pool, the GUI's retry policies, or the CoreSimulator restart.

## Preconditions

- CoreSimulator compatibility (`make probe` prints `OK`) and a bootable iOS
  runtime.
- `make run`, with one sim booted into a tab and its pane rendering.
- A terminal **outside** DeviceTerm, so you can still drive the machine when the
  app's own tabs are blocked. It needs bash or zsh for the `<<<` below.

The `pane list` and `devices list` commands below run **inside a DeviceTerm
terminal pane**. They authenticate against that pane's session and are refused
out of tab. Signals, `instance-guard.sh`, and the lock run in the **external**
terminal, which is what keeps them working when the app is stopped. In check 1
the GUI is untouched, so its tabs still work.

Two log streams are used below. Start them in separate windows and leave them
running:

```sh
log stream --style compact \
  --predicate 'subsystem == "com.deviceterm.daemon" AND (category == "attach" OR category == "footprint")'
```

```sh
log stream --level info --style compact \
  --predicate 'subsystem == "com.deviceterm" AND category == "reconnect"'
```

`--level info` is required on the second one. That line is logged at `.info`,
which a default `log show` or `log stream` drops, and an absent line reads
exactly like a GUI that never reconnected.

## Session setup

Run this in the external terminal and keep that shell for the whole procedure.

Check 1 is **login-wide**: every checkout, every Xcode, and every `simctl` on
your login stops with the service. It takes the same lock the live track takes.

```sh
# One cleanup covers everything. A second `trap` would silently replace this
# one, and the sim lock would then never be released.
./scripts/exclusive-lock.sh acquire sim $$

SUDO=                       # set to: SUDO=sudo   if the STOP in 1.1 is denied
APP_PID=
SIM_STOPPED=

# -U restricts to your own login. Unscoped, this can match another user's
# CoreSimulator, which a `sudo` STOP would suspend and which the per-user sim
# lock cannot coordinate with.
SIM_PIDS=$(pgrep -U "$(id -u)" -f com.apple.CoreSimulator.CoreSimulatorService)

# A read loop, not `kill $SIM_PIDS`: zsh does not word-split an unquoted scalar,
# so several pids would arrive as one argument. Returns non-zero on an empty set
# or any failed signal, so a silent no-op is impossible.
simsig() {
    local rc=0 n=0 p
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        n=$((n + 1))
        $SUDO kill "-$1" "$p" || rc=1
    done <<< "$SIM_PIDS"
    [ "$n" -gt 0 ] || { echo "simsig: no CoreSimulatorService pids captured" >&2; return 1; }
    return "$rc"
}

cleanup() {
    if [ -n "${SIM_STOPPED:-}" ]; then
        simsig CONT || echo "cleanup: a CoreSimulatorService may still be stopped" >&2
    fi
    if [ -n "${APP_PID:-}" ]; then
        kill -CONT "$APP_PID" 2>/dev/null || echo "cleanup: could not resume the app" >&2
    fi
    ./scripts/exclusive-lock.sh release sim $$
}
# Cleanup on EXIT only. A signal handler that cleaned up and returned would
# release the lock and leave this shell able to keep running the procedure
# unlocked, so INT and TERM exit instead.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
```

If acquiring the lock prints a `BUSY` block, the sim lock is unavailable. Stop
and report the complete block. Do not delete the lock directory or look for a
force flag.

Whatever you set `SUDO` to is what both the stop and the resume use, so the two
can never disagree.

Confirm the pid set before going further. `-0` sends no signal, so this cannot
resume a service that you, or an interrupted earlier run, deliberately left
suspended:

```sh
simsig 0 && echo "pid set ok" || echo "ABORT: cannot signal the CoreSimulatorService set"
```

**Do not proceed on ABORT.** `simsig` prints its own line when nothing was
captured; otherwise the failure is a `kill -0` that was denied, or a process
that has exited since the capture. A denial is the common one, and it is what
tells you to set `SUDO=sudo` and take the capture again. Using `-0` is how you
learn which of those it is without having signalled anything.

An interactive shell does not necessarily run an EXIT trap when you press
Ctrl-C, so after any interruption confirm nothing is left suspended:

```sh
pgrep -U "$(id -u)" -f com.apple.CoreSimulator.CoreSimulatorService | while read -r p; do ps -o pid,stat= -p "$p"; done
```

A `T` in the state column means still stopped. An interrupt exits the setup
shell, and `simsig` goes with it, so resume from any terminal with:

```sh
pgrep -U "$(id -u)" -f com.apple.CoreSimulator.CoreSimulatorService | while read -r p; do kill -CONT "$p"; done
```

Prefix `kill` with `sudo` if that is what the stop needed. Then start over from
Session setup; the lock was released when the shell exited.

## 1. Wedged CoreSimulator

Stopping the service models the post-wake state where CoreSimulator accepts
calls and never returns.

| # | Action | Expected |
|---|--------|----------|
| 1.1 | `SIM_STOPPED=1; simsig STOP` | Exits 0. The already-rendering pane keeps showing its last frame. The flag is what tells `cleanup` there is something to resume; without it cleanup resumes nothing. |
| 1.2 | `deviceterm pane list` | Answers promptly with the live GUI projection. Nothing on the read path calls CoreSimulator to serve it. A slow answer means the GUI back-channel or workspace projection is blocked; capture app and daemon samples before attributing it. |
| 1.3 | `deviceterm devices list`, repeating for at least 3s | Eventually blocks or fails. The daemon caches its device snapshot for 2s, so a call right after 1.1 can still answer from cache. Repeat until it stops answering; that is what confirms the service is really wedged. |
| 1.4 | Repeat 1.2 several times over the next minute | Answers promptly every time. A `pane list` that starts hanging means the CoreSimulator wedge has leaked into the GUI projection path. |
| 1.5 | `simsig CONT && SIM_STOPPED=` | Exits 0. Service resumes, and clearing the flag stops cleanup from sending a second, pointless `CONT`. |
| 1.6 | `deviceterm devices list` | Answers again. |

**You cannot reach the acquire or display-start deadline this way, so don't
try.** `xcrun simctl boot` runs through the shim, which snapshots every
device's state with `simctl list devices -j` before spawning the real `simctl`.
With the service stopped that snapshot blocks, so no boot is ever reported, no
attach is requested, and neither bound is ever approached. Both default to a
10s deadline and three slots; `SimBackendAcquirerTests` and
`PaneDisplayBootstrapTests` cover their timeout and saturation behavior with
injected values.

## 2. Stalled consumer

A stopped GUI is a consumer that holds leased surfaces and never acknowledges
them. The daemon must fail the pane rather than grow.

Give the sim something that keeps producing frames before you stop the GUI. The
pane fails only after 120 dropped acquisitions, one pool rotation, then 120
more, and an idle SpringBoard may not emit damage callbacks anywhere near 60 Hz.
A scrolling list, a video, or a continuous animation in the guest is what makes
2.3 land in seconds; without one it can wait indefinitely.

Resolve the pids for **this checkout**. A bare `pkill -f DeviceTerm` would stop
another worktree's app, or the installed cask:

```sh
./scripts/instance-guard.sh status
```

Rows are `pid<TAB>kind<TAB>executable`. Only `mine` rows belong to this
checkout. The app's executable basename is `deviceterm` (lowercase), the
daemon's is `deviceterm-daemon`:

```sh
APP_PID=$(./scripts/instance-guard.sh status | awk -F'\t' '$2=="mine" && $3 ~ /\/deviceterm$/    {print $1}')
DAEMON_PID=$(./scripts/instance-guard.sh status | awk -F'\t' '$2=="mine" && $3 ~ /deviceterm-daemon$/ {print $1}')
```

Check each holds exactly one pid before going on. Empty means the guard could
not see the process; two means something else from this checkout is running.

Assigning `APP_PID` is what arms the resume in `cleanup`. Do not add a `trap`
here; it would replace the one from setup and leave the sim lock held.

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Read `footprint=` from the next `footprint` line | A baseline in MiB. Use this rather than `ps` RSS: the daemon reports `phys_footprint`, which accounts for IOSurface and compressed memory that resident size may not. |
| 2.2 | `kill -STOP "$APP_PID"` | The window stops redrawing. The daemon keeps running. |
| 2.3 | Watch the attach stream for a few seconds | `surface pool unavailable; recovery will retry on the next frame` appears. That notice is the only log signal this check gets. The pool's fatal reason is **not** logged: `markPaneFailed` takes it and discards it. |
| 2.4 | Read `footprint=` across the next three lines (about three minutes) | Plateaus. A value that keeps climbing is the failure this check exists for. |
| 2.5 | Read the rest of that `footprint` line | `panes` still counts the pane. Its pool counters no longer contribute: failing the pane tore down its backend, so `surfaceDrops` will be flat or zero here rather than rising. |
| 2.6 | `kill -CONT "$APP_PID" && APP_PID=` | The GUI resumes and the pane shows a buttonless overlay reading `Failed: daemon reported pane failure`. It does not catch up to live frames, and the text is generic because the daemon's failure event carries no reason. Clearing `APP_PID` disarms the resume: the restart below replaces that process, and a stale pid would make final cleanup report a false failure or signal something unrelated. |

Because the pane fails within seconds and the footprint sampler runs once a
minute, the sampler is not how you observe the drops. It is how you confirm what
is left afterwards.

Section 2 leaves the pane failed with no buttons on it, and the sim itself is
**still Booted**. Restarting while it stays Booted can offer orphan recovery and
reattach it without a new boot event, and booting an already-Booted sim produces
no causal boot claim either way. Shut it down first, so section 3 starts from a
fresh boot rather than a recovered orphan:

```sh
xcrun simctl shutdown <udid>      # in a DeviceTerm tab
```

Then `make run`, boot the sim again from a tab, and wait for it to render.

## 3. Sleep and wake

Leave something animating continuously in the guest before you sleep, as in
section 2. A `.rendering` pane keeps its last frame on screen, so a static home
screen cannot distinguish a pane that resumed from one that froze with the
resubscribe loop retrying behind it.

| # | Action | Expected |
|---|--------|----------|
| 3.1 | With the sim pane mirroring, sleep the machine and wait at least a minute | The display sleeps. |
| 3.2 | Wake it and watch the pane | The pane returns to **moving** frames. If it doesn't, a sim that shut down shows `Simulator shut down.` with a Reboot button, and a failed one shows `Failed: …` with no buttons. "Reconnecting…" is physical-device text and will not appear for a sim. |
| 3.3 | Watch the `reconnect` stream | **If** the XPC connection dropped, `handshake generation=N` lines appear with N increasing once per reconnection rather than continuously. A local XPC connection can survive sleep and wake, so no line at all is a legitimate pass, not a failure. |
| 3.4 | Watch for 3 minutes without touching anything | The pane settles: either showing moving frames, or a terminal overlay. A pane frozen on one frame while claiming to render is the failure. Do not count attempts. A wake can produce several reconnections, and the resubscribe loop keeps retrying at its 8s cadence for as long as the pane is `.booting` or `.rendering`, which is intended. |
| 3.5 | Read `panes=` and `retiring=` in the footprint lines | `panes` matches the number of visible mirrored-device panes; terminal panes are not counted. `retiring` at a nonzero value across several samples means teardown is stuck. |

The budgets bound repeated failure rather than a single wake: 5 automatic attach
retries (immediate, then 1s, 2s, 4s, 8s) and 5 automatic resurrections per sim
(2s, 4s, 8s, 16s). Both run out before their policy caps of 30s and 60s, so
those intervals never appear. Exhausting either needs a target that keeps
failing, which this step does not produce. The resubscribe backoff is separate
and unbudgeted: it doubles from 500ms to an 8s ceiling and stops only when the
pane reaches `.shutdown` or `.failed`.

## 4. Restart Simulator Services

Check 1 proves the wedge is survivable. This one proves the menu item clears
it. Login-wide, like check 1, and it takes the same lock.

| # | Action | Expected |
|---|--------|----------|
| 4.1 | `SIM_STOPPED=1; simsig STOP` | Exits 0. The rendering pane holds its last frame. |
| 4.2 | `deviceterm devices list`, repeating past the 2s cache | Blocks or fails, which confirms the wedge is live before you try to clear it. |
| 4.3 | **DeviceTerm ▸ Restart Simulator Services…** | The confirmation names the booted count and how many DeviceTerm owns, or says the roster could not be read. Both are correct here; which one you get depends on whether the 2s snapshot cache had expired. |
| 4.4 | Choose **Cancel** | Nothing stops. The prompt is the only thing between the menu item and every Simulator on the login. |
| 4.5 | Repeat 4.3, then choose **Restart CoreSimulator** | The service stops, then the helper. Set `SIM_STOPPED=` now: the stopped process was killed rather than resumed, and cleanup would otherwise send `CONT` to a pid that no longer exists. |
| 4.6 | Watch the reconnect log stream | The GUI reconnects. Each Simulator pane reports its lost sim rather than holding the stale frame, either as the re-attach error slot with **Retry** and **Close** or as a shutdown overlay. Record which. A pane still showing a live-looking last frame is a failure, and is the state this feature exists to escape. |
| 4.7 | `deviceterm devices list` | Answers again, against the replacement service launchd started on demand. |
| 4.8 | Boot a sim from a tab | Boots and renders. |
| 4.9 | With that sim still booted, run `xcrun simctl shutdown <udid>` from the external terminal | The pane retires to its shutdown state within a second or two. This is the check that the replacement helper's CoreSimulator notifier is live: a pane that keeps rendering its last frame means the helper came up holding a registration against the service that was killed, which is the defect this ordering exists to prevent. |

## Finishing

Exit the external shell when you are done. That is what runs `cleanup`: it
resumes anything this procedure stopped and releases `lock:sim`. Leaving the
terminal open holds the lock, and the next `make test-live` in any checkout
fails with BUSY.

```sh
exit
```

Confirm from another terminal that the lock is gone. `free` is what you want;
anything else names the holder:

```sh
./scripts/exclusive-lock.sh status sim
```

## What these checks cannot show

The GUI's attach backoff and resurrect cooldown emit no log lines. `Router`,
`PaneResurrect`, and `SimulatorPaneViewModel` do not log retry attempts or delay
decisions, so 3.4 and the timing note above must be judged from the clock and
from pane behavior. That is the weakest part of this procedure.

A pane in `.rendering` proves the daemon thinks it is streaming, not that frames
are arriving. Only visible motion in the guest distinguishes those, which is why
sections 2 and 3 both require it.

The pool's fatal reason reaches nothing you can read. `markPaneFailed` accepts
it and drops it, and the daemon's `.failed` lifecycle event carries no message,
so the GUI substitutes `daemon reported pane failure`. To find out why a pane
failed you need the `.recovered` notice that preceded it, or a debugger.

`surfaceNoticesConflated` does not rise just because a consumer stopped. XPC
delivery drains the pane event channel as soon as `xpc_connection_send_message`
accepts the message; it never waits for the peer to consume it. The daemon-side
channel stays empty against a stopped GUI, so that counter is not a signal here.
Conflation is what protects a slow reader, which this procedure has no way to
produce.

`surfaceDrops` and `surfaceReuseInUse` are summed across every pane's pool, and
`delinquentSightings` is a cumulative count from the physical-device watchdog
only. A simulator-only run reports zero sightings, and that is not evidence of
anything.

Check 1 cannot exercise backend acquisition or display startup at all, for the
shim reason given in its own section. What it does test is that the coordinator
stays answerable while CoreSimulator does not.

Pane creation does not hold `PaneCoordinator` across the display's
CoreSimulator calls. Starting frames, registering the orientation observer, and
reading the display's seed orientation and pixel dimensions all run together on
the pane's display lane, off the actor, under their own deadline and slot cap.
Teardown runs off the actor on that lane too, but it has no deadline, and only
the teardown of an abandoned start keeps holding a startup slot.

So this check has no known way to hang 1.2 or 1.4. A hang there is something
else, and it is worth capturing rather than guessing at. Run `sample
deviceterm-daemon 5` while it is stuck and keep the output.
