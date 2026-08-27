# Device Mirror Performance

Off-by-default measurement of the physical-device frame path: the decode
hand-off, the copy into the surface pool, and how long the GUI holds a surface
before acknowledging it. Each arriving frame that closes a window of at least
one second emits one row, so output stays far below per-frame volume.

`LatencyHistogramTests`, `DeviceFrameMetricsTests`, and
`LeasedSurfacePoolHoldAgeTests` cover the quantiles, the accumulator, and which
releases get timed. None of them can see a real frame rate, a real copy
duration, or a real lease round trip, because all three need a device streaming
HEVC into VideoToolbox. That is what this procedure is for.

Run it before and after any change to the frame path, with the same device and
the same workloads both times. A number without a matching baseline says
nothing.

The summary cannot see CPU or GPU residency, energy, or memory bandwidth. Those
come from `powermetrics` and Instruments over the same run. A change that moves
work off the CPU onto dedicated hardware can look free in a time profile while
still costing power and bandwidth, so a CPU delta on its own is not the verdict.

## Preconditions

- A connected, unlocked, trusted device with a working CoreDevice tunnel.
- A scrollable, detail-dense app on the device, a long list or a map, so the
  animating workload sustains frame production.
- The device thermally settled. One that throttles mid-run invalidates the
  comparison.

## Turning it on

The daemon is launched on demand by launchd, so a variable set in a shell, an
Xcode scheme, or the app's environment never reaches it. Set it in the launchd
session instead. Use a fresh base path per run, because the sink appends and
rows from an earlier run would otherwise mix into the comparison.

```sh
base="$HOME/frame-metrics-$(date +%s)"
launchctl setenv DEVICETERM_FRAME_METRICS "$base"
```

Then stop the daemon (`make kill-daemon`, or let it idle-exit) so it restarts
and inherits the variable. Only the daemon reads it, and only physical-device
panes are measured; simulator panes never reach this code.

## Confirming it is measuring

An unset or unpropagated variable produces no rows at all, which reads exactly
like a run with nothing to report. Before trusting any result, mirror the device
and check that rows are arriving:

```sh
log stream --level debug --style compact \
  --predicate 'subsystem == "com.deviceterm.daemon" AND category == "mirror"'
```

`--level debug` is required, not optional. The daemon logs these at debug
level, and without it a healthy capture shows nothing at all, which is the
same thing a disabled one shows. The file-open and write diagnostics are on
the same level.

You want `frame-metrics:` lines arriving while frames flow, with
`decode-metrics:` lines alongside them. If neither appears while the mirror is
visibly updating, the daemon did not inherit the variable. Restart it and check
again.

## The two workloads

Run both, and run the same two before and after.

1. **Static.** Device on its home screen, untouched, 60 s. This is the floor:
   what the pipeline costs with almost no inter-frame motion. How many frames
   a still screen produces is the device's decision, not the daemon's, which
   copies every frame it receives. A static run with no frames flowing is
   inconclusive, not a floor of zero.
2. **Animating.** A scripted scroll over the detail-dense view, 60 s:

    ```sh
    end=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$end" ]; do
      deviceterm swipe 0.5 0.75 0.5 0.25 --duration 250
      sleep 0.15
      deviceterm swipe 0.5 0.25 0.5 0.75 --duration 250
      sleep 0.15
    done
    ```

    Run it from a terminal in the tab holding the device pane, or target the
    pane with `--pane <ref>`; `deviceterm panes list` prints the refs.

Do not scroll by hand. Velocity and duration vary between runs, and both change
the frame rate the device's encoder produces, which changes every number below.

## Reading the summary

One JSON row per closed window in `$base.<deviceId>.frames.jsonl`, plus a
human-readable `frame-metrics:` summary of it. The log line is a digest: window
duration, sample counts, means, and the exact byte total are in the JSON only.
Each mirrored device writes its own file, so two device panes never interleave
rows into one.

| Field | What it is |
|---|---|
| `sourceWidth`, `sourceHeight` | The decoded surface, encoder padding included. |
| `contentWidth`, `contentHeight` | The cropped content rect the copy actually moves. |
| `pixelFormat` | The decoder's output as a four-character code, for example `BGRA`. |
| `windowNanoseconds` | The window this row covers. Rates derive from it, not from an assumed 60 fps. |
| `framesConsumed`, `framesPublished` | Taken off the decoder's stream, and reaching the pane. |
| `framesDroppedNoSurface`, `framesDroppedExhaustion` | The shortfall between those two. |
| `bytesMoved` | What the copies actually moved this window, summed and reported by the copy itself. An uncropped copy spans the whole row stride, so this exceeds the visible pixels by the surface's alignment padding. |
| `geometryChanges` | How many times the geometry above changed within this window. Above zero means the row mixes geometries. |
| `copy` | The CPU copy: `sampleCount`, `meanNanoseconds`, `p50Nanoseconds`, `p95Nanoseconds`, `maxNanoseconds`. |
| `leaseHold` | Grant to release watermark, how long the GUI held a surface. Same five fields. |

Quantiles are bucket upper bounds, so read them as "at most". Resolution is
25%; `maxNanoseconds` is exact.

`leaseHold` starts its clock when the pool grants the hold, which is before the
surface is sent, so it brackets the publish-to-ack round trip rather than
isolating it. It is an aggregate distribution and not a per-frame record, so
there is no way to line an individual round trip up against an Instruments
timeline.

Report `p50`, `p95`, and `max` for both series. An average hides the tail a
frame pipeline is judged on.

The `decode-metrics:` lines come from the decode pipeline rather than the
backend accumulator. Their `dropped` count is the one-deep buffer evicting a
frame no consumer took, which means decode outran downstream frame handling.
That consumer acquires a pool slot, copies, traces, and publishes, so the
counter cannot single out the copy; a slower copy is one possible cause. Watch
it either way.

`contentWidth` equals `sourceWidth` until the content rect locks. The daemon
probes for it on the first frame and every 60th frame after that until one
succeeds, and a frame too dark to size returns nothing, so a device starting on
a black screen reports the uncropped size for the first second or more.

The window the rect locks in, and any window containing a rotation, carries
frames of two different geometries. Its `sourceWidth` and `contentWidth` name
the last of them while its counts and timings span all of them, so
`geometryChanges` is what identifies it, not the dimensions. The log line marks
the same row `(mixed xN)`.

## OS-level capture

Over the same runs, in a separate terminal:

```sh
sudo powermetrics --samplers cpu_power,gpu_power -i 5000 -n 12
```

`sudo powermetrics -h` lists the samplers your machine supports if those two are
not available.

For memory bandwidth and per-frame attribution, record an Instruments trace
against `deviceterm-daemon` with the Time Profiler and the Metal/GPU
instruments. The daemon emits signposts under subsystem `com.deviceterm.daemon`,
category `mirror`: a `decode` interval from the pipeline and a `copy` interval
from the backend. They appear as an interval track, which is what lets a spike
be attributed instead of guessed at.

## Comparing

Compare like against like:

- Same device, same iOS build, same app, same scripted cadence, same duration.
- Same `sourceWidth`, `sourceHeight`, and `pixelFormat` in both runs. A device
  that renegotiated a different resolution invalidates the comparison.
- Discard every row with `geometryChanges` above zero. Those span a content
  rect locking or a rotation, and their per-frame figures describe no single
  geometry.
- Report `framesPublished` next to any timing improvement. A copy that got
  faster while publishing fewer frames is not an improvement.

The run is inconclusive if frames were not flowing, if `framesConsumed` differs
markedly between the two runs, or if `powermetrics` shows the machine in a
different thermal state.

## Cleanup

```sh
launchctl unsetenv DEVICETERM_FRAME_METRICS
```
