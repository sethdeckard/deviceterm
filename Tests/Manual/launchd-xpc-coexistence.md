# launchd and XPC Coexistence Manual Checklist

User-visible items the hermetic gate cannot cover. Walk through
before tagging a release.

## 1. First-launch background-activity notification

**Setup.** Install a fresh build (`make bundle`) on a machine
that has never run DeviceTerm before.

**Action.** Launch the app from the Dock or Finder.

**Expected.** macOS shows a notification banner with the title
"App Background Activity" and body "'deviceterm' can run in the
background." The notification fires once per fresh registration;
subsequent launches stay silent.

**Why automated tests can't cover this.** The notification is
delivered by `notificationd` to the user. Automation can confirm
that `SMAppService.agent(...).register()` didn't throw, but cannot
see whether the system actually surfaced the banner.

## 2. DaemonStatusSheet deep-link visual

**Setup.** Open System Settings → Login Items & Extensions and
toggle deviceterm under the Background section to *off*.

**Action.** Relaunch DeviceTerm. When the GUI fails to connect to
the daemon it shows the `DaemonStatusSheet`. Click "Open Login
Items & Extensions".

**Expected.** System Settings opens directly to the Login Items
& Extensions pane with deviceterm's row visible. The user can
toggle it back on without further navigation.

**Why automated tests can't cover this.** The CTA opens
`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
via NSWorkspace; a snapshot test asserts the URL but cannot
verify what System Settings actually displays.

## 3. Visual frame parity

**Setup.** Build a release bundle, install it, boot a sim, and open the
sim in DeviceTerm.

**Action.** Exercise the mirror across content that stresses color
and motion:

- Open Safari in the booted sim and scroll through a page.
- Open the watchOS Activity rings on a watch sim.
- Open the iPhone Camera app and walk to a window.

**Expected.** Colors match what the sim's own window shows, with no
perceptible color-space drift, and motion stays smooth under a
continuous scroll or animation. Compare against Simulator.app on the
same device if you want a reference.

**Why automated tests can't cover this.** Pixel-byte equality is in
the live-simulator track (`make test-live`), but human-perceptible
smoothness isn't: it depends on display refresh, GPU pipeline, and the
viewer's eyes.

## 4. Production-build orchestrator gate

**Setup.** Build a Developer-ID-signed + notarized + stapled
bundle via `scripts/build-release.sh`. Install on a clean
machine.

**Action.** Open an orchestrator tab via Shell → Open
Orchestrator Tab.

**Expected.** The orchestrator tab opens. Inside it,
`echo $DEVICETERM_SESSION_ROLE` prints `orchestrator`.

**Negative case.** Re-sign the GUI bundle ad-hoc (or with a
different developer id) and relaunch. Retry the same action.

**Expected.** The mint is rejected, so no tab opens. The
`session.create` fails with `-32011` and the reason is `peer team
<id> != daemon team <id>` or `peer is ad-hoc-signed but daemon is
Developer-ID`.

Check the GUI outcome — the daemon keeps no persistent record of
either result.

**Why automated tests can't cover this.** The unit tests
(`PeerIdentityTests`) exercise the `PeerIdentity` helpers' pure logic;
the actual `SecCodeCopyGuestWithAttributes` → `SecCodeCopyStaticCode`
path needs real signed binaries.

## 5. BTM auto-allow with notarized build

**Setup.** A fully clean machine (no prior DeviceTerm install).
Reset Background Task Management state if reusing a machine:

```sh
sfltool resetbtm
```

**Action.** Install the notarized + stapled release bundle and
launch it once.

**Expected.** `sfltool dumpbtm` lists the LaunchAgent with the
disposition `enabled, allowed, notified` automatically — no
manual toggle in System Settings required.

**Why automated tests can't cover this.** BTM auto-allow is an
Apple notarization-service property; it only fires for builds
the service has accepted. Release builds are notarized locally, so the
auto-allow check belongs to the maintainer running the release walkthrough.
