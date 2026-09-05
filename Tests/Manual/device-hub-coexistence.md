# Device Hub coexistence manual checklist

Xcode 27 drops Simulator.app and ships Device Hub instead. Device Hub behaves
nothing like Simulator.app, so the Simulator checklist doesn't transfer and this
one exists alongside it.

`WelcomeSelection`, `WelcomeSeenStore`, and the advisory decision types are
covered by unit tests. What they can't reach is Device Hub, because its shutdown
behavior is Apple's and you learn it only by quitting Device Hub and seeing what
survived.

Run before any release that touches `Sources/App/Welcome/`.

## What quitting does

Observed on macOS 26 with Xcode 27 beta 4 (Device Hub 27.0, build 252.61),
iPhone 17 Pro on iOS 26.5. Steps 1.1 and 1.4 were run as written. 1.2 and 1.3
record the ⌥ behavior as seen at the keyboard rather than from a scripted run,
so confirm the wording still matches when you get there.

**Quitting Device Hub shuts down every booted Simulator.** Not only ones it
started, and not only ones you selected in it. A sim booted with
`xcrun simctl boot` and never touched in Device Hub is shut down the same.

Apple's naming misleads here. The preference is `shutdownStartedDevicesOnQuit`
and the menu string says "started simulators", but Device Hub lists every
simulator and device in one sidebar and keeps no subset of its own. Read
"started" as "booted".

Holding ⌥ with the Device Hub menu open swaps Quit for **Quit and Keep
Simulators Running** (⌥⌘Q). That's the only escape, and it's one-time: the next
quit shuts sims down again.

A persistent setting exists but no way to reach it was found. DeviceKit carries
`shutdownStartedDevicesOnQuit`, and the alternate menu item is described against
a saved default, so the value persists somewhere. What's missing is UI: no
Settings menu item, and ⌘, does nothing, though the panes are compiled into the
app and DeviceKit gates some UI behind an AppleInternal check. Repeat steps
1.2 to 1.4 against the exact Xcode build you ship against.

## What contends on a physical device

Section 2 has never been run end to end. The behavior below was observed in
normal use; the claims about DeviceTerm's own code were read from source. Treat
the steps as the first execution.

Video isn't exclusive. Device Hub and DeviceTerm both mirror the same phone at
once, and both keep working.

Touch appears exclusive. Only one side drives the phone: tap from the other and
nothing happens for a while, then that side takes control and the first goes
dead. Keep tapping and control ping-pongs.

Only tapping was exercised. Keyboard, button, and rotation arbitration are
unverified.

Nothing reports the takeover as such. Touch and buttons are fire-and-forget:
`InteractionRelay.sendTouch` emits the HID report and returns `.acknowledged`
once the emit succeeds, which means the report reached the wire, not that the
phone acted on it. It throws only when the channel itself fails, which a
takeover isn't.

An absolute rotation is the closest thing to a signal, and it is not a reliable
one. `sendRotation` asks the device and reads back `currentDeviceOrientation`,
and `RealDeviceBackend` converges toward the target, reporting `.unconfirmed`
when it never arrives. A relative rotation never can: it reports
`.confirmed(target: observed)` from whatever came back, so it cannot disagree
with itself.

That matters for rotation, which was never exercised on its own. Whether it
behaves like touch here is untested, and it is plausible it doesn't: rotation
goes over the device-control channel while touch goes over human input, so it
may not share that arbitration at all.

`.unconfirmed` does not identify contention, because it also covers any other
failure to reach the target. A rotation that works doesn't identify contention
either. The absolute path also sends one probe rotation plus up to four
convergence requests, and repeated input is what transfers control, so the
command could take control back part-way through and report confirmed. Step 2.4
is there to find out which happens. Until it has been run, don't build anything
on it.

DeviceTerm does not implement a Device Hub warning. The available signals cannot
observe a takeover, so such a warning could only be an attach-time advisory.

Drive the phone from one app. Closing the other isn't required.

## Preconditions

- Xcode 27 installed, for Device Hub itself. It lives at
  `<your Xcode 27>.app/Contents/Applications/DeviceHub.app`, not under
  `Developer/Applications/`, which is where Xcode 26 keeps Simulator.app.

  Which Xcode is selected doesn't matter for the `simctl` steps. CoreSimulator
  lives at `/Library/Developer/PrivateFrameworks/`, and the default device set
  (`~/Library/Developer/CoreSimulator/Devices`) is shared across toolchains, so
  Device Hub sees sims booted under any Xcode. That set is per-user, not
  per-machine, and `simctl --set` can point at another one; if you use an
  alternate set, Device Hub won't be looking at it. These steps were run with
  Xcode 26.6 selected and Device Hub from Xcode 27 beta 4.
- No sims booted, and Device Hub not running:

  ```sh
  xcrun simctl list devices booted
  pgrep -f MacOS/DeviceHub
  ```

  Match the path, not the bundle name. The bundle's executable is
  `DevicesTrampoline` but the running process is `DeviceHub`, so
  `pgrep -x DevicesTrampoline` finds nothing.

- A scratch sim, so no sim of yours is at risk. Pick a runtime you actually
  have rather than copying the one below:

  ```sh
  xcrun simctl list runtimes
  xcrun simctl create "DeviceTerm Scratch" \
      com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
      com.apple.CoreSimulator.SimRuntime.iOS-26-5
  ```

Delete the scratch sim when you're done.

Device Hub registers no login item on this machine. Its binary references a
`DevicesMenu.app` menu bar extra, but that app doesn't ship in Xcode 27 beta 4
and Device Hub logs "DevicesMenu.app is not available. Skipping menu extra
initialization." Two launches added nothing to System Settings ▸ General ▸
Login Items. Check again against a later Xcode.

The first `xcrun simctl boot` after an idle CoreSimulator can fail with
`Invalid argument`. Retrying worked. Seen once, so treat it as an annoyance to
retry through rather than a finding.

## 1. Quit behavior

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Boot the scratch sim with `xcrun simctl boot`. Open Device Hub without selecting the sim. ⌘Q. | The sim is `Shutdown`. Device Hub kills sims it never touched. |
| 1.2 | Boot again. Open Device Hub, select the sim, then ⌥⌘Q ("Quit and Keep Simulators Running"). | The sim stays `Booted`. |
| 1.3 | Open Device Hub again and ⌘Q normally. | The sim is `Shutdown`. The ⌥ choice didn't persist. |
| 1.4 | Press ⌘, with Device Hub frontmost. | Nothing opens. There's no setting to recommend. |

## 2. Physical-device control

Needs a connected, unlocked, trusted iPhone or iPad.

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Attach the phone in DeviceTerm. In Device Hub, click View Screen. | Both mirror. Neither drops. |
| 2.2 | Tap repeatedly in DeviceTerm, on something with obvious feedback (scroll a Settings list). Then tap repeatedly in Device Hub. Then back to DeviceTerm. | Input dies on whichever side lost control, then transfers after continued tapping. One tap each way may show nothing, so keep going. Note whether the frame rate changes. |
| 2.3 | **Button trial.** Hand control to Device Hub (see below). Then, from DeviceTerm and touching nothing else, press one hardware button. | Record whether the phone reacts. That press is two reports, press and release, so it is itself two contending inputs. |
| 2.4 | **Rotation trial.** Hand control to Device Hub again. Read the phone's current orientation and pick a target at least 90° from it. Then, from DeviceTerm and touching nothing else, run the **absolute** rotate: `deviceterm rotate landscape-left` from a portrait phone. | Record what the rotate reports and whether the screen visibly rotated. |
| 2.5 | Straight after 2.4, tap once in DeviceTerm, then once in Device Hub. | Record what each tap does. Read it as what happened during the probe, not as who owned touch beforehand. |

**Handing control to Device Hub** means tapping in Device Hub until the phone
visibly responds, and sending nothing from DeviceTerm. Don't confirm it by
tapping in DeviceTerm to see nothing happen: that tap is a contending input and
may take ownership, which is the state you were trying to establish. Device Hub
visibly driving the phone is the evidence.

Each trial gets its own hand-off, and sends exactly one thing from DeviceTerm.
Running the button and the rotate in one pass means the rotate no longer starts
from known Device Hub control, because the button may have taken it.

2.3 to 2.5 are an open question, not a pass/fail. Record every part: what the
button did, what the rotate reported, whether the screen moved, and what each
tap in 2.5 did.

`unconfirmed` means the rotate never reached the target, which points at Device
Hub having kept control. `confirmed` with the screen rotating means the rotate
reached the target. `confirmed` without the screen rotating is a real result,
not a broken run: `RealDeviceBackend` confirms the device's reported attitude,
not the framebuffer, and its own comment says so, so the device can change
attitude while the mirror shows the old frame.

None of those says whether rotation took control away from Device Hub. Rotation
might have worked while Device Hub kept touch throughout.

2.5 doesn't settle it either, and can't. Touch is the only probe available, and
touch is the operation that moves ownership, so either tap may take control
before showing anything and both sides can respond in turn. It reports who
answered during the probe, not who held touch when the rotate finished.

Nothing available closes that gap. Nothing reports arbitration: `perform` throws
on transport failure and an absolute rotate can come back `.unconfirmed` or
`.confirmationUnsupported`, but none of those distinguishes "another app has
control" from any other reason it didn't work. `InteractionRelaying` exposes no
read-only arbitration query and no read-only orientation query, so this
checklist cannot determine ownership after a rotation. Record what you saw and
leave the causal question open.

Pick a target in 2.4 different from the starting orientation. The absolute path
opens with a left probe and learns the orientation only from that reply, so it
never knows where the phone started. If the probe is ignored but the reply still
names the requested target, the backend returns confirmed without having
controlled anything.

Use the absolute form. A relative rotation reports confirmed whenever the reply
carries an orientation, because that observation becomes its own target, so it
cannot disagree with itself. A reply without one reports
`.confirmationUnsupported`, and transport failures throw.

## 3. Which welcome appears

Both coexistence welcomes are gated on their app being installed, and only one
appears per launch. On a machine with both Xcodes, that means two launches.

```sh
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/deviceterm/welcome-seen"
```

| # | Action | Expected |
|---|--------|----------|
| 3.1 | Clear the seen cache, then `make run`. | The Simulator.app welcome appears. The Device Hub one waits. |
| 3.2 | Quit and relaunch. | The Device Hub welcome appears. |
| 3.3 | Quit and relaunch again. | No welcome. |
| 3.4 | Choose Help ▸ Working with Apple's Device Hub. | It opens, whether or not Device Hub is installed. |

A machine with only one of the two Xcodes sees only that app's welcome, and the
other stays out of the seen cache, so installing the other Xcode later arms it.
Confirming that needs a machine without Xcode 27, which these steps don't
cover.
