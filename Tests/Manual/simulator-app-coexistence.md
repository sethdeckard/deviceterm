# Simulator.app coexistence manual checklist

`WelcomeSelection`, `WelcomeSeenStore`, `HeadlessAdvisoryDecision`, and the
gate ordering in `HeadlessAdvisoryViewModel` are covered by unit tests. What
those can't reach is anything needing a window server or another application.

Two things sit entirely outside them. The welcome is a launch gate: it opens
before the first DeviceTerm window and that window opens when the welcome
closes, which is `AppDelegate` ordering rather than a value a test can read.
And Simulator.app's shutdown behavior is Apple's, decided by preferences in
another app's domain and observable only by quitting it and seeing what
survived.

Run before any release that touches `Sources/App/Welcome/`,
`Sources/App/HeadlessAdvisory*.swift`, `Sources/App/SimulatorDetachPolicy.swift`,
or the launch sequence in `Sources/App/AppDelegate.swift`.

## What the preferences do

Verified on macOS 26 with Xcode 26 (CoreSimulator 1063.4), iPhone 17 Pro on
iOS 26.5. Both keys live in `com.apple.iphonesimulator`. Their menu items sit
under Simulator.app's AppleInternal-gated Internal menu, so most machines have
no UI for them, but they're ordinary persisted preferences and they honor an
external `defaults write`.

| # | `DetachOnWindowClose` | `DetachOnAppQuit` | Sim after ⌘W on the last device window |
|---|---|---|---|
| 1 | `YES` | unset | Shutdown |
| 2 | `YES` | `YES` | Booted |
| 3 | `YES` | `YES` at launch, `NO` while running | Shutdown |
| 4 | `YES` | `NO` at launch, `YES` while running | Booted |

Four things follow.

Closing the last device window quits Simulator.app outright, so that gesture
runs the quit path. Trials 1 and 2 differ only in `DetachOnAppQuit` and the
outcome flips, so that key governs it; `DetachOnWindowClose` alone doesn't save
the sim.

An external `defaults write` is honored, so you don't need the Internal menu.

The value is read at quit time, not cached at launch. Trials 3 and 4 change it
while Simulator.app is running and it takes effect in both directions with no
relaunch.

Simulator.app doesn't overwrite the on-disk value when it quits.

`DetachOnWindowClose` has never been confirmed on its own. Closing the last
window always routes through quit, so nothing here isolated it. Confirming it
needs two device windows open and a close of one that isn't the last. Treat the
DeviceTerm copy mentioning it as documented rather than verified.

## Preconditions

- A clean build launched as a bundle: **`make run`, not `swift run`**.
- No sims booted and Simulator.app not running:

  ```sh
  xcrun simctl list devices booted
  pgrep -x Simulator
  ```

- Your current values recorded, so you can put them back:

  ```sh
  defaults read com.apple.iphonesimulator DetachOnAppQuit
  defaults read com.apple.iphonesimulator DetachOnWindowClose
  ```

- A scratch sim, so no sim of yours is at risk:

  ```sh
  xcrun simctl create "DeviceTerm Scratch" \
      com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
      com.apple.CoreSimulator.SimRuntime.iOS-26-5
  ```

Delete the scratch sim and restore both preferences when you're done.

## 1. Preference behavior

| # | Action | Expected |
|---|--------|----------|
| 1.1 | `DetachOnWindowClose` `YES`, `DetachOnAppQuit` unset. Boot the scratch sim, open Simulator.app, ⌘W its window. | Simulator.app quits. `xcrun simctl list devices` shows the sim `Shutdown`. |
| 1.2 | Set `DetachOnAppQuit` `YES` too. Boot, open, ⌘W. | Simulator.app quits. The sim stays `Booted`. |
| 1.3 | With Simulator.app running, flip `DetachOnAppQuit` to `NO`, then ⌘W. | The sim shuts down. The pref was read at quit, not cached. |
| 1.4 | Read the key back after Simulator.app quits. | Still the value you wrote. Simulator.app didn't clobber it. |

## 2. Welcome launch gate

Clear the seen cache first, or nothing appears:

```sh
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/deviceterm/welcome-seen"
```

`XDG_CACHE_HOME` has to be an absolute path. DeviceTerm ignores a relative one
and falls back to `~/.cache`, so the command above would clear a file the app
never reads.

| # | Action | Expected |
|---|--------|----------|
| 2.1 | `make run` on a machine with no seen cache. | The welcome appears. **No DeviceTerm window yet.** |
| 2.2 | Click the DeviceTerm Dock icon while the welcome is up. | The welcome comes forward. No terminal window opens behind it. |
| 2.3 | Press ⌘N and ⌘T while the welcome is up. | Same: the welcome surfaces, no window opens. |
| 2.4 | Click Continue. | The first DeviceTerm window opens. |
| 2.5 | Quit and relaunch. | No welcome, and the window opens immediately. |
| 2.6 | Choose Help ▸ Working with Apple's Simulator.app. | The welcome opens again, even though it's been seen. |
| 2.7 | Set `welcome-messages = suppress`, clear the cache, relaunch. | No welcome. The window opens immediately. Help still opens it. |

## 3. Advisory copy

The advisory fires on sim-pane attach while Simulator.app is running. It reads
Simulator.app's preferences to decide which route to name. Whether that read
picks up a change made after DeviceTerm launched hasn't been tested, so relaunch
DeviceTerm after each `defaults write` rather than relying on it.

| # | `DetachOnAppQuit` | `DetachOnWindowClose` | Expected |
|---|---|---|---|
| 3.1 | unset | unset | Names both closing the device window and quitting. |
| 3.2 | `YES` | unset | Names only closing a window while others stay open. |
| 3.3 | unset | `YES` | Names quitting, and says it includes closing the last device window. |
| 3.4 | `YES` | `YES` | No advisory at all. |

| # | Action | Expected |
|---|--------|----------|
| 3.5 | Click Learn More… on the advisory. | The coexistence welcome opens. |
| 3.6 | Tick "Don't show again", then click Learn More…. | The welcome opens and `simulator-app-advisory = suppress` is written. Both happen. |
| 3.7 | In one session, let the welcome appear, then attach a sim with Simulator.app running. | No advisory. A welcome already explained it this session. |
