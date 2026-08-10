# Recording a DeviceTerm Demo

> **Run the driver from an orchestrator tab.** Open one with **Shell → Open
> Orchestrator Tab** (⌘⇧T). An ordinary tab cannot control another tab and
> receives `error.role_violation`.

DeviceTerm can type a prepared sequence of commands into a terminal while you
record it. The commands appear at a natural pace, and the off-camera driver
advances them one at a time.

## How It Works

The underlying command is:

```sh
deviceterm tab send-input --tab <ref> --type-delay <ms> -- '<command>\n'
```

`--type-delay` sets the delay between characters. Omit it for immediate input.
The trailing newline runs the command.

The `scripts/demo-present.sh` helper reads a file containing one command per
line. Each keypress in the driver sends the next command to the recorded tab.
Blank lines and lines beginning with `#` are skipped.

## Prepare the Recording

1. Open a normal tab for the recording and change to the directory where the
   demo should begin.

2. Find the tab reference:

   ```sh
   deviceterm tabs list
   ```

   Use its short ID, or assign a name with `deviceterm tab rename`.

3. Open an orchestrator tab with **Shell → Open Orchestrator Tab** (⌘⇧T).

4. Drag the orchestrator tab into a separate window and place it outside the
   recording frame.

5. Copy `scripts/demo-example.txt` and edit it. Put one shell command on each
   executable line. Use lines beginning with `#` for presenter notes.

## Record the Demo

Run the presenter helper from the off-camera orchestrator tab:

```sh
scripts/demo-present.sh scripts/demo-example.txt \
  --target <recorded-tab-ref> \
  --speed 45
```

`--target` identifies the recorded tab. You may omit it when the driver and
recorded tabs each contain one terminal session and the recorded session is the
sole other result from `deviceterm tabs list --json`. Automatic selection
requires `jq`.

`--speed` is the delay between characters in milliseconds. It defaults to `45`.
Use `0` for immediate input. Values above `1000` are capped at `1000`.

`--settle` is how long the recorded tab's visible screen must hold still before
the driver offers the next step, in milliseconds. It defaults to `1500`, and a
single wait gives up after 60,000 ms and offers the step anyway. The driver
compares successive `deviceterm tab capture` results, so it needs no knowledge
of what the recorded shell's prompt looks like. Raise it for a demo whose
commands pause between lines of output; pass `--no-settle` to turn the wait off
and advance whenever you like.

The gate exists because output from a still-running command interleaves
visually with the echoed input, which makes the recording look garbled. For
demo commands that do not read stdin the input stays queued and runs correctly;
it is the appearance that suffers. Two limits worth knowing: a foreground
command that runs long and prints nothing is indistinguishable from an idle
prompt, since nothing exposes a tab's foreground process, and a command that
*does* read stdin will consume the injected characters itself.

To record:

1. Start the screen recorder on the recorded window.
2. Keep keyboard focus in the driver window.
3. Press any key to type and run the next command.
4. Continue until the helper reports that every step is complete.

The driver shows the upcoming command before each keypress.

## Input Behavior and Limits

Without `--type-delay`, `send-input` returns after dispatch. With a positive
delay, it returns after the input is queued, not when animated typing finishes.
Positively paced commands sent to the same tab queue in order and do not
interleave. An unpaced command dispatches immediately and does not wait behind
that queue.

The presenter helper's settle gate normally stops you advancing into a command
that is still running. Pass `--no-settle` to queue steps early anyway: they
still type out in order, behind the command already animating.

Pacing applies to individual characters. Use plain shell commands followed by
a newline. Do not use paced input for hand-built multi-byte escape sequences
because their bytes would be separated by the delay.

Run `xcrun simctl` normally in the recorded tab. DeviceTerm's shim passes the
command to Apple's tool and watches for `simctl boot`, including the
`bootstatus -b` form that boots and waits in one step. The Simulator attaches
to that tab when the invocation actually transitions it to Booted, without a
separate `deviceterm device attach` command. An invocation that succeeds
without changing state, such as `bootstatus -b` against an already-booted
device, attaches nothing.

DeviceTerm provides `tab send-input` and its `--type-delay` option. The demo
file and presenter loop are repository helpers, not a separate recording
format or product subsystem. Keep your customized demo files with the material
for each recording.
