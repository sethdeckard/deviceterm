# DeviceTerm

> A macOS-native terminal that runs live Apple device panes beside your shell.

DeviceTerm keeps Apple-platform development in one workspace. Boot an iOS
Simulator with the normal `xcrun simctl` command from a DeviceTerm tab and a
live, Metal-rendered pane appears beside the shell. Click, drag, and type in the
pane directly. DeviceTerm passes Apple's command through unchanged and observes
the successful boot so there is no separate attach step.

The same pane model supports iPadOS, watchOS, and tvOS Simulators, plus connected
iPhones and iPads. Advanced integrations can use the `deviceterm` CLI for input,
accessibility, pane management, structured JSON, and operations that Apple's
tools do not expose.

<video src="https://github.com/user-attachments/assets/e9b6d789-a629-4237-80f3-1fe20074f445" controls muted></video>

*A one-minute demo. More at [deviceterm.com](https://deviceterm.com).*

## Install

Install the signed and notarized app with Homebrew:

```sh
brew install --cask sethdeckard/tap/deviceterm
```

Or download `deviceterm-0.1.0.dmg` from the
[latest release](https://github.com/sethdeckard/deviceterm/releases/latest) and
drag `DeviceTerm.app` to `/Applications`.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Xcode installed and selected as the active developer directory for Simulator
  and `xcrun` workflows.

Simulator-service and physical-device compatibility are runtime concerns; see
the [compatibility section in `USAGE.md`](docs/USAGE.md#runtime-compatibility).
For source builds, DeviceTerm has been verified with Xcode 26.4 and 26.6;
[`BUILDING.md`](docs/BUILDING.md) has the toolchain and build details.

## Quick Start

Open DeviceTerm and run the Apple command you already use:

```sh
xcrun simctl boot "iPhone 17 Pro"
```

The Simulator appears in the current tab. Use the mouse and host keyboard to
interact with it:

- click or drag for touch and swipe;
- hold Option while dragging for a two-finger pinch or rotation;
- type into the focused device pane; and
- scroll or drag the watch bezel to turn the Digital Crown.

Commands that DeviceTerm does not observe continue to behave exactly as Apple's
tools define them. A Simulator booted from Xcode, Simulator.app, or another
terminal remains independent until explicitly attached.

## Advanced CLI and JSON

The lowercase `deviceterm` command is for scripts, agents, and advanced device
control:

```sh
deviceterm tap 0.5 0.5
deviceterm text "hello"
deviceterm swipe 0.5 0.8 0.5 0.2
deviceterm ax tree
deviceterm panes list --json
```

Coordinates are normalized from `(0,0)` at the top left to `(1,1)` at the
bottom right. Run `deviceterm help`, `deviceterm help <command>`, or
`deviceterm agents` inside a tab for the command reference. The public CLI and
JSON contract follows SemVer; [`INTEGRATION.md`](docs/INTEGRATION.md) documents
the compatibility policy and parseable shapes, and
[`AUTOMATION.md`](docs/AUTOMATION.md) covers controlling DeviceTerm itself:
workspace commands, orchestration, and events.

## Features

- Live Simulator panes for iOS, iPadOS, watchOS, and tvOS.
- Physical iPhone and iPad mirroring over the CoreDevice tunnel.
- Direct mouse, keyboard, multi-touch, edge-swipe, and Digital Crown input.
- Automatic pane attachment for supported `xcrun simctl` and
  `xcrun devicectl` workflows inside a DeviceTerm tab.
- Tabs, terminal splits, device panes, windows, and keyboard-driven navigation.
- An advanced CLI for touch, keys, text, buttons, rotation, accessibility,
  workspace control, event streams, and structured JSON.
- Optional, hand-editable configuration with Ghostty settings for terminal
  appearance.

When a tab closes, DeviceTerm can detach its Simulators and leave them running or
shut them down. Simulators booted elsewhere are borrowed and are never claimed
without an explicit attach.

## Building

```sh
git clone https://github.com/sethdeckard/deviceterm.git
cd deviceterm
make hooks
make run
```

A fully launchable local bundle needs a Developer ID Application certificate
because the embedded daemon registers as a login item. A free Apple Account does
not provide that certificate. See [`BUILDING.md`](docs/BUILDING.md) for build,
test, signing, and release instructions.

## Documentation

- [`USAGE.md`](docs/USAGE.md): day-to-day tabs, panes, devices, input, and
  configuration.
- [`AUTOMATION.md`](docs/AUTOMATION.md): controlling DeviceTerm itself from
  the CLI; workspace commands, orchestration, and events.
- [`INTEGRATION.md`](docs/INTEGRATION.md): public CLI and JSON contracts for
  advanced integrations.
- [`PHILOSOPHY.md`](docs/PHILOSOPHY.md): product principles.
- [`ARCHITECTURE.md`](docs/ARCHITECTURE.md): processes, RPC schema, trust model,
  and data flow.
- [`AGENTS.md`](AGENTS.md): contributor conventions and verification policy.
- [`RELEASING.md`](docs/RELEASING.md): signing, notarization, and publishing
  checklist.

## Distribution and License

Private CoreSimulator APIs make live Simulator panes possible, so DeviceTerm is
distributed directly rather than through the App Store. Release builds are
Developer ID-signed and notarized.

DeviceTerm is free software under the
[GNU General Public License, version 3 or later](LICENSE). Third-party components
remain under their own licenses; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
