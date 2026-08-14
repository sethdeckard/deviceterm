# Using DeviceTerm

DeviceTerm is a terminal first. Use it like any other terminal, boot
Simulators with `xcrun simctl` and watch them appear beside your shell,
interact with device panes directly, and use the lowercase `deviceterm` CLI
for what Apple's tools don't cover.

Run the CLI commands in this guide from a shell inside a DeviceTerm tab. The
tab provides the session context used to select panes and authorize commands.

For command syntax, run:

```sh
deviceterm help
deviceterm help <command>
```

This guide covers working inside a tab. For controlling DeviceTerm itself
from the CLI (tabs, windows, orchestration, events), see
[`AUTOMATION.md`](AUTOMATION.md). For JSON formats, completion semantics,
exit codes, and stability guarantees, see [`INTEGRATION.md`](INTEGRATION.md).

## Contents

- [Use DeviceTerm as a Terminal](#use-deviceterm-as-a-terminal)
- [Boot Simulators From the Shell](#boot-simulators-from-the-shell)
- [Understand Simulator Ownership](#understand-simulator-ownership)
- [Work With Tabs and Panes](#work-with-tabs-and-panes)
- [Drive a Device Directly](#drive-a-device-directly)
- [Drive a Device From the CLI](#drive-a-device-from-the-cli)
- [Use Accessibility](#use-accessibility)
- [Mirror a Physical Device](#mirror-a-physical-device)
- [Simulate Locations and Routes](#simulate-locations-and-routes)
- [Install Shell Completions](#install-shell-completions)
- [Configure DeviceTerm](#configure-deviceterm)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [Runtime Compatibility](#runtime-compatibility)
- [Troubleshoot](#troubleshoot)

## Use DeviceTerm as a Terminal

DeviceTerm renders terminal panes with libghostty, the terminal engine behind
Ghostty.

Terminal appearance and terminal-local key bindings come from your Ghostty
configuration, including `~/.config/ghostty/config`; libghostty loads its
default configuration files whole. If you already use Ghostty, DeviceTerm
picks up your font, theme, and key bindings with no DeviceTerm-side setup.

Window chrome, the focus ring, and the drag overlay read theme colors only
from `<config home>/ghostty/config`, normally `~/.config/ghostty/config`. A
Ghostty configuration that lives elsewhere (`config.ghostty`, Application
Support) still themes the terminal itself, but those accents fall back to
system colors.

DeviceTerm's own configuration file controls DeviceTerm behavior only. The
two domains are disjoint and neither overrides the other; see
[Configure DeviceTerm](#configure-deviceterm).

An enabled DeviceTerm menu shortcut wins over a Ghostty key binding for the
same chord. A Ghostty binding for an action DeviceTerm answers itself, such
as a new tab or split, goes unanswered rather than being reinterpreted.

## Boot Simulators From the Shell

### Boot With xcrun simctl

List the Simulators installed with the active Xcode:

```sh
xcrun simctl list devices available
```

Choose an available Simulator and boot it from a DeviceTerm tab:

```sh
xcrun simctl boot "iPhone 17 Pro"
```

Replace the example name with one listed on your Mac. DeviceTerm passes the
command to Apple's tool and observes the successful state transition. The
Simulator appears as a device pane in the current tab, beside your shell.

### Understand the xcrun Shim

The interception is a per-session `xcrun` shim. Every terminal pane's shell
starts with its session's `bin/` directory first on `PATH` (exported as
`DEVICETERM_SHIM_DIR`) whose `xcrun` and `simctl` entries point at the shim.

The shim is transparent. It runs the real binary with your original
arguments, inherited stdin, stdout, and stderr, and the shim directory
removed from the child's `PATH`; it forwards signals and mirrors the exit
status. Your command behaves exactly as Apple defines it, whether or not
DeviceTerm recognizes it.

When a recognized command succeeds, the shim reports it to DeviceTerm so the
device is attributed to the calling session and its pane appears in that
session's tab. The recognized Simulator forms are:

- `simctl boot <device>`
- `simctl shutdown <device>`
- `simctl bootstatus <device> -b`, the boot-and-wait form common in CI
  scripts; bare `bootstatus` only polls and is not intercepted

`xcrun` flags such as `--sdk` are handled. Bare `simctl` also routes through
the shim, but it still needs the real `simctl` findable on your `PATH`,
which it usually is not outside Xcode's developer directory; the shim points
you at `xcrun simctl` in that case.

Attribution requires a real state transition. The shim compares the device
list from before and after the command, so a successful no-op, such as
`bootstatus -b` against an already booted Simulator, attaches nothing, and a
concurrent transition of an unrelated device is not attributed to your
command.

The report is best-effort. A failed report never changes your command's
output or exit status; the worst case is a booted Simulator without a pane,
which you can [attach by UDID](#attach-an-external-simulator).

### Trigger a Physical-Device Mirror From devicectl

The shim also recognizes two `devicectl` workflows when they run through
`xcrun` inside a DeviceTerm tab and include `--device`:

- `xcrun devicectl device install`
- `xcrun devicectl device process launch`

After Apple's command succeeds, DeviceTerm resolves the target and asks the
GUI to mirror it in the calling tab.

Other `devicectl` operations do not trigger attachment, and bare `devicectl`
does not route through the shim. An unresolved device or absent GUI also
leaves the original command successful without creating a pane. Use the
picker or `deviceterm device attach` when you need an explicit result; see
[Mirror a Physical Device](#mirror-a-physical-device).

### Verify the Shim

`deviceterm doctor` reports whether `xcrun` resolves through the shim:

```sh
deviceterm doctor
```

If the shim is no longer first on `PATH` (a shell profile that rewrites
`PATH`, a nested shell from another terminal), boots bypass the intercept:
Apple's commands still work, but no pane appears. Open a fresh tab, or attach
the already booted Simulator by UDID.

### Attach an External Simulator

A Simulator booted from Xcode, Simulator.app, or another terminal remains
independent. Attach it explicitly by UDID:

```sh
xcrun simctl list devices booted
```

Copy the required UDID from that output, then run:

```sh
SIMULATOR_UDID="A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6"
deviceterm device attach "$SIMULATOR_UDID"
```

Use the UDID, not the device name. Externally booted Simulators are absent
from `deviceterm devices list` until DeviceTerm claims them, so a name has
nothing to resolve against; see
[device roster rows](INTEGRATION.md#device-roster-rows).

## Understand Simulator Ownership

DeviceTerm distinguishes Simulators it controls from devices that remain under
another tool's control.

| State | Meaning | Next Action |
|---|---|---|
| Owned | DeviceTerm observed the boot inside a tab or you explicitly attached the Simulator. | Use, detach, or shut it down from DeviceTerm. |
| Borrowed | Another tool booted the Simulator and DeviceTerm has not claimed it. | Leave it independent or attach it explicitly by UDID. |
| Detached | Its DeviceTerm surface was closed, but the Simulator remains booted and owned. | Reattach it by UDID or use the status item. |
| Unlinked | The owning terminal session no longer exists, but the owned Simulator is still booted. | Reattach it, shut it down, or leave it running. |
| Orphaned | DeviceTerm finds an unlinked Simulator during cold-start recovery. | Choose an action in the recovery prompt. |
| Shutdown | The Simulator stopped and DeviceTerm released its ownership. | Boot it again when needed. |

Physical devices are always borrowed. Mirroring one does not give DeviceTerm
ownership of the device or permission to shut it down.

### Close a Device Pane

Close a Simulator pane to remove its DeviceTerm surface while leaving the
Simulator booted and owned. Closing a physical-device pane ends the mirror and
releases its tunnel when nothing else needs it.

Closing a device pane does not close the tab. Closing the last terminal pane
does close the tab.

### Close a Tab or Window

When a tab owns booted Simulators, DeviceTerm offers these choices:

- **Detach (Keep Sims Running)** closes the tab and leaves its Simulators
  booted.
- **Shut Down Sims** stops its owned Simulators before closing.
- **Cancel** leaves the tab open.

Closing a window applies the same decision to the owned Simulators associated
with its tabs.

Use the prompt's **Don't ask again** controls when you want a default for a
particular scope. Persistent defaults can also be set in the configuration
file.

### Quit DeviceTerm

When DeviceTerm has at least one open window and any owned Simulators are
booted, quitting offers:

- **Keep Running** closes the GUI surfaces and leaves the Simulators under the
  daemon and menu bar status item.
- **Shut Down All & Quit** stops every owned Simulator before quitting.

This check covers the daemon's complete owned roster. A detached or unlinked
Simulator can trigger the prompt even when the remaining window has no device
panes.

Closing the last window does not quit DeviceTerm. If no windows remain when you
quit, DeviceTerm exits without presenting another window-scoped Simulator
prompt. Detached Simulators continue running.

### Use the Status Item

The daemon shows a menu bar status item while at least one owned Simulator is
booted. It remains available when the main DeviceTerm GUI has exited.

The menu opens with a **DeviceTerm** title row, so the menu identifies itself
even after the main GUI has exited. Below it, the menu groups live sessions by
name and places Simulators without a live session under **Unlinked**. Each
Simulator provides:

- **Shut Down**
- **Open in Simulator.app**
- **Reveal in Finder**

Use **Shut Down All** when more than one owned Simulator is booted. The status
item disappears after the final owned Simulator shuts down.

Physical devices do not affect the status item count.

### Recover Orphaned Simulators

On a cold launch, DeviceTerm checks its recovery records against the
Simulators that are still booted. It silently removes records for devices that
are no longer running.

When booted orphaned Simulators remain, choose:

- **Re-attach** to adopt them into the first new tab.
- **Shut Down All** to stop them and remove their recovery records.
- **Leave Running** to keep them booted and offer the choice again on a later
  launch.

You can also reclaim one explicitly with `deviceterm device attach` and its
UDID.

## Work With Tabs and Panes

A tab is a workspace. It contains one or more terminal sessions, their working
directories, and any device panes attached to the tab.

A terminal split creates another terminal session inside the same tab. Each
session has its own CLI identity, but the GUI treats them as one workspace for
layout and Simulator close decisions.

### Build a Workspace in the GUI

Use the **Shell** menu to create:

- a window;
- a tab;
- an orchestrator tab;
- a terminal split to the right or below; or
- a physical-device mirror.

Boot a Simulator from any terminal in the tab to add its device pane. Click a
pane to focus it.

Drag a pane's header and use the drop preview to reposition it within the tab.
Use **View ▸ Toggle Split Direction** to change a split between horizontal and
vertical. Use **View ▸ Reset Pane Layout** to restore the default proportions.

Panes do not move between tabs. Move or reorder the whole tab when the
workspace belongs in another position or window.

### Focus and Close Panes

Use ⌘] and ⌘[ to select the next or previous pane. These shortcuts wrap around
the tab.

Use ⌥⌘ plus an arrow key to select a pane in that direction. Directional
selection stops when no pane exists in that direction.

Use ⇧⌘← and ⇧⌘→ to move the focused pane past its neighbor.

Press ⌘W to close the focused pane. If the focused pane is the tab's final
terminal, DeviceTerm closes the tab and applies its Simulator close decision.

Press ⌥⌘W to close the tab directly. Press ⇧⌘W to close the window.

A script or agent can create and arrange the same surfaces with the workspace
commands in [`AUTOMATION.md`](AUTOMATION.md#control-the-workspace).

## Drive a Device Directly

Click or drag inside a device pane to send touch input. Type on the host
keyboard to send keys and text.

On a Simulator, hold Option while dragging to create a two-finger pinch or
rotation. Drag upward from the bottom edge to send the system edge gesture.

On a watchOS pane, scroll over the display or drag on the bezel to turn the
Digital Crown.

On a Simulator pane, the **Device** menu offers buttons, rotation, reboot,
shutdown, erase, screenshots, screen recording, app installation, location
simulation, and Simulator.app or Finder access. On a physical-device pane the
menu enables only the operations the device's services support; see
[Know the Physical-Device Limits](#know-the-physical-device-limits).

Device menu actions select the focused device pane; if a terminal is focused,
clicking a Device menu item can still target the device pane in that tab.

### Choose a View Mode

Use the **View** menu to choose Physical Size, Point Accurate, Pixel Accurate,
or Fit Screen. The shortcuts are ⌃⌘1 through ⌃⌘4.

## Drive a Device From the CLI

The `deviceterm` CLI drives the device pane from the same shell. This is how
an agent running inside a tab interacts with the device: the tab supplies the
target, and the agent speaks the same commands you would type.

### Send Touch Input

CLI coordinates are normalized. `(0,0)` is the top-left corner and `(1,1)` is
the bottom-right corner regardless of pixel dimensions.

```sh
deviceterm tap 0.5 0.5
deviceterm swipe 0.5 0.8 0.5 0.2 --duration 250
deviceterm long-press 0.5 0.5 --duration 800
deviceterm pinch 0.45 0.5 0.55 0.5 0.30 0.5 0.70 0.5
deviceterm app-switcher
```

`swipe` defaults to 200 milliseconds and emits movement at about 60 Hz. A
duration below the 32-millisecond frame floor becomes a tap. Its receipt
reports `dispatched=tap`.

Use `--hold` to keep the finger at the final coordinate before lifting:

```sh
deviceterm swipe 0.5 0.8 0.5 0.2 --duration 250 --hold 300
```

On a Simulator, `app-switcher` sends an edge swipe with a dwell. On a physical
device, DeviceTerm uses the app-switcher gesture when available and otherwise
uses a Home double-press.

### Send Keys, Text, Buttons, and Rotation

```sh
deviceterm button home
deviceterm key 0x30 down
deviceterm key 0x30 up
deviceterm text "hello world"
deviceterm rotate landscape-left
deviceterm rotate left
```

`button` accepts:

```text
home | lock | side | apple-pay | siri | digital-crown
```

Button and orientation names accept kebab-case, snake_case, camelCase, or
lowercase spellings.

`key` takes an `NSEvent.keyCode` and a `down` or `up` transition. Pair every
key-down with its corresponding key-up.

`text` supports ASCII and sends one keypress per character. It reports an
unsupported character instead of silently dropping it.

`rotate` accepts an absolute orientation:

```text
portrait | portrait-upside-down | landscape-left | landscape-right
```

or a relative direction, which turns the device 90 degrees from wherever
DeviceTerm last put it:

```text
left | right
```

DeviceTerm tracks only the rotations it performed. Attach to a device that is
already turned and the first `left` or `right` steps from the wrong place, then
lands on the orientation it assumed, which puts the two back in step. Anything
that rotates the device without going through DeviceTerm, an app forcing its
own orientation included, puts them out of step again.

### Turn the Digital Crown

Use `crown` with a watchOS Simulator:

```sh
deviceterm crown 5
deviceterm crown 100 --duration 1500
```

The sign controls direction and the magnitude controls distance in the
bridge's raw crown unit.

Omit `--duration` to send one event. A positive duration divides the movement
into events sent at about 60 Hz.

`--velocity` is accepted but ignored because the SimulatorKit crown builder
accepts only a delta.

Tight SwiftUI crown bindings can ignore streamed events whose individual
deltas fall below the watchOS recognizer's transition. Remove `--duration`
first when a tight binding does not move.

For fine placement on a binding such as
`.digitalCrownRotation(in: 0...1, by: 0.005)`, use a single event with a value
from 1 through 8. Those values produced a useful range in the recorded test
environment, but they are not a cross-runtime guarantee.

The measured response curves and environment are recorded in
[`watchos-checklist.md`](../Tests/Manual/watchos-checklist.md).

### Select a Device Pane

Input and accessibility commands resolve against the panes your session
owns, normally the ones booted or attached from your terminal pane. When
your session owns exactly one device pane, commands select it automatically;
when it owns several, pass `--pane`.

A sibling terminal split's pane belongs to that split's session and is not
yours to drive, even inside the same tab; see
[Know Your Session](AUTOMATION.md#know-your-session).

Input and accessibility references accept a pane short ID, pane name,
Simulator UDID, physical-device ID, or pane ID prefix. Workspace commands use
narrower tab, pane, and window reference forms.

Run these help topics for the exact rules:

```sh
deviceterm help targeting
deviceterm help refs
```

Resolve one pane for a group of nested commands with `with-pane`:

```sh
deviceterm panes list
PANE_REF="abc123"
deviceterm with-pane "$PANE_REF" sh -c 'deviceterm tap 0.5 0.5'
```

Replace `abc123` with the short ID printed by `panes list`. Nested
`deviceterm` commands inherit the resolved target; the environment contract
and exit forwarding are defined in
[`INTEGRATION.md`](INTEGRATION.md#run-a-child-with-a-pane-target).

## Use Accessibility

Accessibility commands operate on Simulator panes:

```sh
deviceterm ax tree
deviceterm ax point 0.5 0.5
deviceterm ax sweep --step 0.04
```

`ax tree` reads the frontmost application's accessibility tree. `ax point`
reads the element at one normalized coordinate. `ax sweep` samples the
display with point queries and removes duplicate elements.

All three always emit JSON. The wrapper fields are DeviceTerm contracts; the
nested accessibility nodes come from Apple frameworks and can vary by
runtime. See [Accessibility](INTEGRATION.md#accessibility) before building an
integration around them.

On watchOS, the child walk used by `ax tree` can return an empty tree. Use
`ax sweep` to sample the display, or `ax point` when you need the element at
one known coordinate.

Physical-device panes do not expose an accessibility service. All three
accessibility commands return an unsupported-operation error for them; see
[Know the Physical-Device Limits](#know-the-physical-device-limits).

Use **View ▸ Toggle AX Inspector** to inspect accessibility information in the
GUI.

## Mirror a Physical Device

DeviceTerm can mirror a connected physical iPhone or iPad through its
CoreDevice tunnel.

Connect the device, unlock it, and trust the Mac. Then open
**Shell ▸ Mirror Physical Device…**.

Select a device in the picker and choose **Mirror**. Use **Refresh** after
connecting or unlocking a device while the picker is already open.

The picker performs a cheap connected-device enumeration. A device can appear
before DeviceTerm has tested whether it exposes the services required for
mirroring.

DeviceTerm brings up the tunnel during attachment and then checks for the
display and human-input services. Attachment reports a specific error if the
device is locked, the tunnel cannot start, the service catalog is unavailable,
the OS is too old for mirroring, or the required human-input service is
missing.

### Attach From the CLI

List the aggregate device roster:

```sh
deviceterm devices list
```

Copy the physical device's `deviceId`, then run:

```sh
PHYSICAL_DEVICE_ID="00008130-001C195E0C10802E"
deviceterm device attach "$PHYSICAL_DEVICE_ID"
```

The physical `deviceId` is the stable CoreDevice UDID. It is not a tunnel IP
address.

A successful `xcrun devicectl device install` or `process launch` inside a
tab also mirrors its target automatically; see
[Trigger a Physical-Device Mirror From devicectl](#trigger-a-physical-device-mirror-from-devicectl).

### Know the Physical-Device Limits

Single-finger touch, text, keys, and the app switcher are available through the
required human-input service. Hardware buttons and rotation are available only
when their optional services open successfully.

Location actions use the physical-device location service when it is
available.

These operations do not have physical-device implementations:

- `pinch`
- `crown`
- `ax tree`
- `ax point`
- `ax sweep`

Closing the pane ends the mirror. It does not shut down, reboot, erase, or
claim ownership of the physical device.

A mirror pane does not survive a daemon restart, but you do not have to
re-attach it. Once the daemon reconnects, DeviceTerm mirrors the device again
in the same pane. A device that is no longer reachable leaves that pane showing
the attachment error with **Retry** and **Close**.

DeviceTerm does not claim one blanket iOS or iPadOS compatibility range.
Support depends on the services advertised by the connected device and is
tested during attachment.

## Simulate Locations and Routes

Use **Device ▸ Location** with the device pane you want to control.

When a device pane has focus, location actions apply to it. When a terminal has
focus, choosing a location from the menu targets the device pane in that tab.

### Choose a Location

The menu provides:

- **None** to clear DeviceTerm's simulated location.
- **Use My Location** to take one snapshot of the Mac's current location.
- saved coordinates and GPX routes.
- **Trips** reported by the device.
- **Custom Coordinates…** to enter a latitude, longitude, and optional name.

macOS requests location permission the first time you use **Use My Location**.
If permission is denied, use **Custom Coordinates…** or enable permission in
System Settings.

When developing from source, launch the bundled app with `make run`.
A loose executable does not have the bundle identity needed for the location
permission prompt.

The coordinate sheet accepts the decimal separator for your current locale.
The on-disk locations file always uses a period for the decimal point.

### Save Locations

DeviceTerm stores saved locations in:

```text
$XDG_CONFIG_HOME/deviceterm/locations
```

When `XDG_CONFIG_HOME` is unset, it uses:

```text
~/.config/deviceterm/locations
```

Enter one coordinate or GPX route per line:

```text
# <latitude>,<longitude> [name]
37.7749,-122.4194 San Francisco
51.5072,-0.1276 London
64.1466,-21.9426

# <path>.gpx [name]
~/routes/commute.gpx
~/routes/marathon.gpx Boston Marathon
"~/my routes/sunday run.gpx" Sunday Long Run
```

Names are optional. An unnamed coordinate displays its values. An unnamed
route displays its filename without the extension.

File order determines menu order. DeviceTerm appends new coordinates but does
not reorder, cap, or remove entries. Edit the file to rearrange or delete
them.

Comments, blank lines, and lines DeviceTerm does not recognize remain
unchanged. Coordinates that render to the same six-decimal value are treated
as the same saved location, and the first saved name is retained.

**Use My Location** does not save its first reading automatically. Select the
resulting unsaved coordinate row if you want to record it.

### Play a GPX Route

Add a route by placing its `.gpx` path in the locations file. DeviceTerm does
not provide a separate add-route command.

Relative paths resolve from the directory containing the locations file. A
leading `~` expands to your home directory. Put double quotes around paths that
contain spaces.

DeviceTerm prefers:

1. track points in `<trkpt>`;
2. route points in `<rtept>`; then
3. standalone waypoints in `<wpt>`.

A file containing one point sets a fixed location. A moving route can contain
at most 10,000 points.

DeviceTerm uses one continuous sequence from the highest-priority point type
present. It rejects multiple tracks or track segments when using track points,
and multiple routes when using route points.

When every point has a timestamp and both elapsed time and total distance are
positive, DeviceTerm calculates one constant speed from them. Otherwise it
uses 20 meters per second.

Both Simulator and physical-device backends accept one speed for the entire
route. Changes of pace in the original recording are not reproduced. DeviceTerm
publishes position updates once per second.

### Interpret Location Checkmarks

A checkmark records the last location DeviceTerm successfully applied to that
pane. DeviceTerm cannot query the device's current simulated location.

A location changed by another tool can therefore make the checkmark stale.
Transferring a pane, rebooting a device, or losing the daemon's claim clears
the checkmark without sending a location-clear command.

Location remains a GUI workflow. DeviceTerm does not provide a
`deviceterm location` command because `xcrun simctl location` already covers
Simulator CLI control.

## Install Shell Completions

Install completions from a DeviceTerm tab for the shell you use:

```sh
deviceterm completions install zsh
```

Supported values are `zsh`, `bash`, and `fish`.

The command writes the completion script to that shell's conventional autoload
directory. It honors `XDG_DATA_HOME` or `XDG_CONFIG_HOME` where the shell's
layout uses them.

Follow the printed activation hint. Zsh may require adding the directory to
`fpath`, Bash may require sourcing the file from its completion setup, and
Fish loads the installed file in a new shell.

The app bundle and Homebrew cask do not install the man page. To read the
repository copy from a source checkout:

```sh
man -l share/man/man1/deviceterm.1
```

## Configure DeviceTerm

DeviceTerm works without a configuration file.

Choose **DeviceTerm ▸ Settings…** to open the configuration file in a new
terminal tab running `$EDITOR`. DeviceTerm asks before creating the file when
it does not exist.

The file lives at:

```text
$XDG_CONFIG_HOME/deviceterm/config
```

When `XDG_CONFIG_HOME` is unset, it uses:

```text
~/.config/deviceterm/config
```

Use `key = value` lines and `#` comments.

Inspect every active value and its source with:

```sh
deviceterm dump-config
```

The command also warns about unrecognized keys. The two prompt keys
report `unset` while you haven't set them: their Default column below is
the choice a present key selects, and leaving the key out keeps the
prompt.

| Key | Default | Values | Effect |
|---|---|---|---|
| `tab-close-default` | `detach` | `detach`, `shutdown` | Chooses what closing a tab does with its owned Simulators. Setting it suppresses the Close Tab prompt. |
| `quit-with-sims-default` | `keep` | `keep`, `shutdown` | Chooses what quitting does while owned Simulators remain booted. Setting it suppresses the Quit prompt. |
| `simulator-app-advisory` | `show` | `show`, `suppress` | Controls the warning shown when Simulator.app is running while a Simulator is attached. |
| `auto-update` | `check` | `off`, `check`, `download` | Controls automatic update checks and downloads. `off` leaves manual update checks available. |

Terminal appearance and terminal-local key bindings remain in the Ghostty
configuration domain; see
[Use DeviceTerm as a Terminal](#use-deviceterm-as-a-terminal).

Saved locations use the separate `locations` file described in
[Simulate Locations and Routes](#simulate-locations-and-routes).

## Keyboard Shortcuts

Every shortcut also appears in a menu. **Shell** creates and closes workspace
surfaces. **Edit** handles text. **View** controls presentation and pane
layout. **Window** handles navigation and rearrangement. **Device** controls
the selected device pane.

### DeviceTerm

| Shortcut | Action |
|---|---|
| ⌘, | Settings… |
| ⌘H | Hide DeviceTerm |
| ⌥⌘H | Hide Others |
| ⌘Q | Quit |

### Shell

| Shortcut | Action |
|---|---|
| ⌘N | New Window |
| ⌘T | New Tab |
| ⇧⌘T | Open Orchestrator Tab |
| ⌘D | Split Right |
| ⇧⌘D | Split Down |
| ⌘W | Close Pane |
| ⌥⌘W | Close Tab |
| ⇧⌘W | Close Window |

⌘W closes the focused pane. If the focused terminal is the tab's last
terminal, it closes the tab instead. The menu item changes its title to show
which action will run.

### Edit

| Shortcut | Action |
|---|---|
| ⌘X | Cut |
| ⌘C | Copy |
| ⌘V | Paste |
| ⌘A | Select All |
| ⌘K | Clear Buffer |

### View

| Shortcut | Action |
|---|---|
| ⌘= | Zoom In |
| ⌘- | Zoom Out |
| ⌘0 | Reset Zoom |
| ⌃⌘1 | Physical Size |
| ⌃⌘2 | Point Accurate |
| ⌃⌘3 | Pixel Accurate |
| ⌃⌘4 | Fit Screen |
| ⌃⇧D | Toggle Split Direction |
| ⌥⌘A | Toggle AX Inspector |
| ⌃⌘F | Enter Full Screen |

### Device

| Shortcut | Action |
|---|---|
| ⇧⌘H | Home |
| ⌘L | Lock |
| ⌘← | Rotate Left |
| ⌘→ | Rotate Right |
| ⌘S | Screenshot |
| ⌘R | Record Screen |

### Window

| Shortcut | Action |
|---|---|
| ⌘M | Minimize |
| ⇧⌘] | Select Next Tab |
| ⇧⌘[ | Select Previous Tab |
| ⌃⇧← | Move Tab Left |
| ⌃⇧→ | Move Tab Right |
| ⌥⌘↑ | Select Pane Above |
| ⌥⌘↓ | Select Pane Below |
| ⌥⌘← | Select Pane Left |
| ⌥⌘→ | Select Pane Right |
| ⌘] | Next Pane |
| ⌘[ | Previous Pane |
| ⇧⌘← | Move Pane Left |
| ⇧⌘→ | Move Pane Right |
| ⌘1 through ⌘8 | Select Tab 1 through Tab 8 |
| ⌘9 | Select Last Tab |

### Understand Focused Shortcuts

Device shortcuts act directly only when a device pane has focus. For example,
⌘← moves the terminal cursor when a terminal has focus.

Choosing **Device ▸ Rotate Left** from the menu still selects the device action
when a terminal is focused. This lets terminal applications retain their own
meanings for shortcuts such as ⌘←, ⌘→, ⌘S, and ⌘R.

DeviceTerm reserves ⌥⌘ plus the arrow keys for directional pane navigation.
Terminal applications do not receive those shortcuts, even when no pane exists
in the selected direction.

⌘` is the macOS shortcut for moving focus to the next window. DeviceTerm does
not override it. Change it in **System Settings ▸ Keyboard** if needed.

## Runtime Compatibility

Runtime compatibility is separate from the Xcode versions that can compile
DeviceTerm. See [`BUILDING.md`](BUILDING.md) for source-build requirements and
the verified build toolchains.

Simulator panes use CoreSimulator and SimulatorKit from the active developer
directory. The compatibility probe checks the private symbols DeviceTerm
requires.

Recorded environments and live observations are in
[`Sources/CoreSimulatorBridge/as-tested.md`](../Sources/CoreSimulatorBridge/as-tested.md).
A successful symbol probe does not establish live behavior or guarantee that
the same Xcode release can compile DeviceTerm.

Physical-device panes use CoreDevice tunnel services instead of
CoreSimulator. DeviceTerm tests the required services during attachment and
does not claim a blanket iOS or iPadOS compatibility range.

Release validation tests Simulator services and physical-device streams
separately. See [`RELEASING.md`](RELEASING.md).

## Troubleshoot

Start with:

```sh
deviceterm doctor
```

Use the JSON form in a script:

```sh
deviceterm doctor --json
```

### Restart the Background Helper

DeviceTerm's Simulator and device work runs in a background daemon, which its
menus and alerts call the helper. When it stops answering, tabs, windows, and
device panes can all stop responding at once.

DeviceTerm notices on its own and offers **Restart Helper**. Choose **Keep
Waiting** to leave it alone; after two minutes, another unanswered request can
bring the offer back.

You can also restart it deliberately with **DeviceTerm ▸ Restart Helper…**.

A restart leaves your Simulators booted and your terminal panes untouched,
including their scrollback and anything running in them. Device panes
re-attach themselves once the helper is back. A pane that cannot re-attach,
because its Simulator shut down or its physical device disconnected while the
helper was gone, shows the error in its own slot with **Retry** and
**Close**.

A Simulator whose pane you closed keeps running and stays DeviceTerm's across
the restart, so it still counts in the status item and still appears in its
tab's close prompt and the quit prompt.

Closing a whole tab with **Detach** also leaves its Simulators running and
DeviceTerm's, listed as Unlinked because the session that booted them is gone.
Those survive a restart too. They have no tab left to prompt for, but they
still count in the status item and at quit.

A Simulator that is still shut down when the helper processes the restore is
not reclaimed: DeviceTerm won't claim one that isn't running.

DeviceTerm reports a restart it could not perform rather than claiming one.

| Symptom | Likely Cause | Next Action |
|---|---|---|
| `no device pane in this session` | Your session owns no attached device pane, or the command is running outside the owning terminal pane. | Boot a Simulator from this terminal, mirror a physical device, or attach one explicitly. |
| `xcrun simctl boot` succeeds but no pane appears | The command bypassed DeviceTerm's per-session `xcrun` shim, or it did not produce a new boot transition. | Run `deviceterm doctor` and check the shim result; see [Understand the xcrun Shim](#understand-the-xcrun-shim). Attach an already booted Simulator by UDID. |
| A Simulator was booted from Xcode or Simulator.app | External boots are not claimed automatically. | Find the Simulator with `xcrun simctl list devices booted` and pass its UDID to `deviceterm device attach`. |
| Attaching an external Simulator by name fails | `devices list` contains only owned booted Simulators, so it cannot resolve an unclaimed external name. | Use the Simulator UDID rather than its name. |
| `multiple panes in this session; pass --pane <ref>` | Your session owns more than one device pane. | Run `deviceterm panes list`, pass a pane reference with `--pane`, or use `with-pane`. |
| No physical devices appear in the picker | The device is disconnected, locked, untrusted, or was connected after the picker opened. | Connect and unlock it, trust the Mac, then choose **Refresh**. |
| A physical device appears but attachment fails | Enumeration succeeded, but a required tunnel, display, or input service did not. | Read the attachment error, unlock and trust the device, then retry. A device with unsupported services cannot be mirrored by this build. |
| The GUI and CLI disagree after an upgrade | The live daemon wire version differs from the bundled RPC wire version, or the version probe failed. | Run `deviceterm version --json` and compare `daemon` with `rpcWire`; see [the version report](INTEGRATION.md#version-report). Quit and reopen DeviceTerm. |
| Tabs, windows, and device panes all stop responding | The background helper stopped answering. | Wait for DeviceTerm's restart prompt, or choose **DeviceTerm ▸ Restart Helper…**; see [Restart the Background Helper](#restart-the-background-helper). |
| `ax tree` is empty on watchOS | The watch accessibility bridge returned no children. | Use `ax sweep` to sample the display or `ax point` for a known coordinate. |
| A Digital Crown command does not move a tight SwiftUI binding | Positively paced events are below the recognizer's transition in that environment. | Remove `--duration` first. For fine placement, try a single value from 1 through 8. |
| A Simulator pane shows a shutdown overlay | The Simulator shut down outside DeviceTerm while its pane remained open. | Choose **Reboot**, boot the same UDID from the owning tab, or close the pane. |
| Simulator.app opens a second presentation of the same Simulator | Simulator.app is running while DeviceTerm owns the display pane. | Quit Simulator.app, or set `simulator-app-advisory = suppress` when the duplicate presentation is intentional. |

Run `deviceterm agents` for additional automation recipes and command-specific
input diagnostics.
