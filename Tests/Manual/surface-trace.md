# Surface Trace Manual GPU Verification

Off-by-default instrumentation for the physical-device surface path. The
daemon stamps each device frame's pool generation into the surface pixels;
after the command buffer completes, the GUI scans the surface back and
records what it intended to render against what it observed. The hermetic
`SurfaceTraceTests` cover the pixel stamp/scan and the JSONL sink; the Metal
completion-handler path can only be exercised against a real GPU, so it is
verified here.

This trace answers *which* frame a consumer rendered. For how long each stage
took (decode, copy, and the lease round trip) use `DEVICETERM_FRAME_METRICS`
and `device-mirror-perf.md` instead. The two are independent and can be set
together.

## Cross-process activation (required)

The daemon is launched on demand by launchd, so a setting present only in an
Xcode scheme or the app's own environment never reaches the daemon — its
frames go unstamped and the consumer logs ordinary pixels as trace ids. Set
the variables in the launchd session so **both** processes inherit them, and
use a fresh base path per run: the sink appends, so stale rows from an
earlier run would otherwise mix in and can falsely satisfy the positive
control.

```sh
base="$HOME/surface-trace-$(date +%s)"
launchctl setenv DEVICETERM_SURFACE_TRACE "$base"
# Optional adversarial consumer delay (ms) that lets the daemon reuse a
# slot before the scan runs:
launchctl setenv DEVICETERM_SURFACE_CONSUMER_DELAY_MS 8
```

Then fully restart the daemon and the app so both pick up the environment
(quit the app; let the daemon idle-exit or kill it). Only physical-device
panes are traced; simulator panes leave their frames unstamped and are not
scanned.

## Run

1. Mirror a physically-connected device and interact so frames flow.
2. Stop and inspect `$base.producer.jsonl` and `$base.consumer.jsonl`:
   - Producer — one row per **accepted** generation. Frames the pool dropped
     under exhaustion, or that upstream buffering discarded, have no row.
     `traceId` = the generation, `monotonicNanoseconds` = produced time.
   - Consumer — one row per **successfully traced** delivered sequence. The
     continuous draw loop repaints a frame many times but traces it at most
     once, and a superseded frame may go untraced. `traceId` = the generation
     the GUI intended to render, `observedTraceId` = the low 32 bits it
     scanned back, `mismatchRows` = internally inconsistent rows,
     `monotonicNanoseconds` = the command-buffer completion time (stamped
     before the delay, so it is the render-complete time, not the scan time).
3. Join by `(paneId, traceId)` — `traceId` is the full generation on both
   sides, so the join is exact:
   - `observedTraceId != (traceId mod 2^32)` → a coherent wrong-generation
     swap (the slot was fully reused before the scan). Compare against the
     low 32 bits, since `observedTraceId` is the pixel-stamp width.
   - `mismatchRows > 0` → a partial overwrite (tearing).
   - `consumer.monotonicNanoseconds - producer.monotonicNanoseconds` → the
     produce-to-render-complete latency. It excludes the adversarial delay,
     which is applied only to the scan, not the timestamp.

Limitation: the scan detects mutation of the surface up to the moment it
runs; it does not observe the bytes the GPU actually sampled. The completion
handler fires on any terminal command-buffer state, including error.

## Positive control

A clean run means something only once you know the instrument can report a
fault and that reuse actually had a chance to happen. Before trusting a
clean result:

- Confirm frames are flowing — the joined producer/consumer rows are
  non-empty.
- Provoke reuse with a large delay (`DEVICETERM_SURFACE_CONSUMER_DELAY_MS=200`)
  under a high frame rate, and confirm at least some consumer rows show
  `observedTraceId != (traceId mod 2^32)` and/or non-zero `mismatchRows`.

A clean result is inconclusive when frames aren't flowing, the frame rate is
low, the pool never exhausts, or ownership protection prevents reuse — so
treat "no mismatches" as detector failure only when reuse was demonstrably
possible.

## Cleanup

```sh
launchctl unsetenv DEVICETERM_SURFACE_TRACE
launchctl unsetenv DEVICETERM_SURFACE_CONSUMER_DELAY_MS
```
