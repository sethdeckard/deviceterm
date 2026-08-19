# CoreSimulatorBridge: As Tested

The **required-symbols** table lists every private class, selector, protocol,
framework, C symbol, and runtime service the bridge depends on. Each row names
the module that introduces the dependency.

Every new private-API dependency must add a row here and a matching check in
the compatibility probe. See the architecture-check review gates in
`AGENTS.md`. Release reviewers use this record to identify what must be
revalidated for a new macOS or Xcode version.

`make probe` checks every introspectable required symbol and exits non-zero
with a structured list when one is missing. Two categories do not fail that
gate: `PurpleWorkspacePort`, which cannot be introspected without a booted
device, and rows explicitly marked optional.

## Validation runs

| Date | Host | Xcode | Result | Scope |
|---|---|---|---|---|
| 2026-08-07 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 75 symbols present, 0 missing | `make probe`; symbol resolution only |
| 2026-08-17 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 81 symbols present, 0 missing | `make probe`; symbol resolution only |
| 2026-08-18 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 81 symbols present, 0 missing | `make probe`; symbol resolution only |

Behavioral findings that require a booted device stay in their relevant
sections below. A successful probe confirms that the active toolchain still
provides the bridge's introspectable dependencies; it does not replace the
live simulator test track, and it does not establish that the same Xcode can
compile DeviceTerm. Source-build toolchains are tracked in `docs/BUILDING.md`.

## Required symbols

| Kind               | Symbol                                                               | Introduced by         | Notes                                                          |
|--------------------|----------------------------------------------------------------------|-----------------------|----------------------------------------------------------------|
| class              | `SimServiceContext`                                                  | `CoreSimulatorLoader` | Framework entry point; every subsequent module fans out from it. |
| class selector     | `+[SimServiceContext sharedServiceContextForDeveloperDir:error:]`    | `CoreSimulatorLoader` | Singleton accessor; the first call after `loadFramework()`.    |
| class              | `SimDeviceSet`                                                       | `SimDeviceHandle`     | Device enumeration root.                                       |
| class              | `SimDevice`                                                          | `SimDeviceHandle`     | One per simulator device.                                      |
| class              | `SimRuntime`                                                         | `SimDeviceHandle`     | iOS/tvOS/watchOS runtime descriptor reachable via `SimDevice.runtime`. |
| class              | `SimDeviceType`                                                      | `SimDeviceHandle`     | Device-type descriptor reachable via `SimDevice.deviceType`.   |
| instance selector  | `-[SimServiceContext defaultDeviceSetWithError:]`                    | `SimDeviceHandle`     | Resolves the user's default device set.                        |
| instance selector  | `-[SimDeviceSet devices]`                                            | `SimDeviceHandle`     | All known devices in the set, regardless of state.             |
| instance selector  | `-[SimDeviceSet registerNotificationHandlerOnQueue:handler:]`        | `SimDeviceNotifier`   | Set-level subscription via the `SimDeviceNotifier` protocol. One registration covers every device in the default set, including ones created later. Returns a non-zero token. |
| instance selector  | `-[SimDeviceSet unregisterNotificationHandler:error:]`               | `SimDeviceNotifier`   | Cancels the registration returned above. The wrapper is idempotent.  |
| instance selector  | `-[SimDevice UDID]`                                                  | `SimDeviceHandle`     | Device identity.                                               |
| instance selector  | `-[SimDevice name]`                                                  | `SimDeviceHandle`     | Human-readable name.                                           |
| instance selector  | `-[SimDevice state]`                                                 | `SimDeviceHandle`     | Raw `SimDeviceState`; normalize via `CSBSimState` enum.        |
| instance selector  | `-[SimDevice runtime]`                                               | `SimDeviceHandle`     | Reachable runtime descriptor (may be nil on unavailable runtimes). |
| instance selector  | `-[SimDevice runtimeIdentifier]`                                     | `SimDeviceHandle`     | String fallback when `runtime` is nil.                         |
| instance selector  | `-[SimDevice deviceType]`                                            | `SimDeviceHandle`     | Reachable device-type descriptor.                              |
| instance selector  | `-[SimDevice deviceTypeIdentifier]`                                  | `SimDeviceHandle`     | String fallback when `deviceType` is nil.                      |
| instance selector  | `-[SimDevice bootWithOptions:error:]`                                | `SimDeviceHandle`     | Boot intent; returns when accepted, not when SpringBoard renders. |
| instance selector  | `-[SimDevice shutdownWithError:]`                                    | `SimDeviceHandle`     | Synchronous shutdown.                                          |
| instance selector  | `-[SimRuntime identifier]`                                           | `SimDeviceHandle`     | e.g. `com.apple.CoreSimulator.SimRuntime.iOS-26-4`.            |
| instance selector  | `-[SimDeviceType identifier]`                                        | `SimDeviceHandle`     | e.g. `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`.    |
| instance selector  | `-[SimDeviceType name]`                                              | `SimDeviceHandle`     | Human-readable type name (e.g. "Apple Watch Ultra 3 (49mm)"); drives the chrome's "Name · Type" composition. |
| class              | `SimDeviceIOClient`                                                  | `SimDisplayHandle`    | Concrete `device.io` type; carries `ioPorts`.                  |
| instance selector  | `-[SimDevice io]`                                                    | `SimDisplayHandle`    | Accessor for the per-device IO client (returns `SimDeviceIOClient`). |
| instance selector  | `-[SimDeviceIOClient ioPorts]`                                       | `SimDisplayHandle`    | Port enumeration; renderable proxies live here.                |
| protocol           | `SimDisplayRenderable`                                               | `SimDisplayHandle`    | Base renderable protocol carrying `displaySize` and the damage-rectangles callback. |
| protocol           | `SimDisplayIOSurfaceRenderable`                                      | `SimDisplayHandle`    | Picker's primary conformance test; carries the IOSurface accessors and the surface-change callbacks. |
| protocol method    | `-<SimDisplayRenderable> displaySize`                                | `SimDisplayHandle`    | Picker prefers candidates with non-zero `displaySize`.         |
| protocol method    | `-<SimDisplayRenderable> registerCallbackWithUUID:damageRectanglesCallback:` | `SimDisplayHandle` | Required on iOS 26.4; without it the proxy never allocates its IOSurface. |
| protocol method    | `-<SimDisplayRenderable> unregisterDamageRectanglesCallbackWithUUID:` | `SimDisplayHandle`    | Teardown counterpart; called on `stop` to prevent block-registration leaks across start/stop cycles. |
| protocol method    | `-<SimDisplayIOSurfaceRenderable> framebufferSurface`                | `SimDisplayHandle`    | Primary IOSurface accessor (modern slot).                      |
| protocol method    | `-<SimDisplayIOSurfaceRenderable> ioSurface`                         | `SimDisplayHandle`    | Legacy IOSurface accessor (fallback when `framebufferSurface` is nil). |
| protocol method    | `-<SimDisplayIOSurfaceRenderable> registerCallbackWithUUID:ioSurfaceChangeCallback:`  | `SimDisplayHandle` | One of two callback shapes — register both because the proxy's `respondsToSelector` lies. |
| protocol method    | `-<SimDisplayIOSurfaceRenderable> registerCallbackWithUUID:ioSurfacesChangeCallback:` | `SimDisplayHandle` | The other callback shape; co-registered with the singular variant. |
| protocol method    | `-<SimDisplayIOSurfaceRenderable> unregisterIOSurfaceChangeCallbackWithUUID:`  | `SimDisplayHandle` | Teardown counterpart for the singular callback.                |
| protocol method    | `-<SimDisplayIOSurfaceRenderable> unregisterIOSurfacesChangeCallbackWithUUID:` | `SimDisplayHandle` | Teardown counterpart for the plural callback.                  |
| protocol           | `SimScreen`                                                          | `SimDisplayHandle`    | Carried by the same display descriptor the picker selects; source of the presented orientation. |
| protocol           | `SimScreenProperties`                                                | `SimDisplayHandle`    | Snapshot vended by `screenProperties`; carries `uiOrientation`. |
| protocol method    | `-<SimScreen> screenProperties`                                      | `SimDisplayHandle`    | Bounded one-shot read; seeds a pane's display orientation and is re-read inside every change callback. |
| protocol method    | `-<SimScreen> registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:` | `SimDisplayHandle` | Push channel for orientation. **All three blocks must be non-nil**: CoreSimulator invokes them unconditionally, so a nil frame callback dereferences NULL and takes the simulator down. |
| protocol method    | `-<SimScreen> unregisterScreenCallbacksWithUUID:`                    | `SimDisplayHandle`    | Teardown counterpart; called on `stopOrientation` and `stop`.  |
| protocol method    | `-<SimScreenProperties> uiOrientation`                               | `SimDisplayHandle`    | The presented orientation, as a `UIInterfaceOrientation`. Mapped to device-orientation vocabulary in the bridge, **swapping the landscape pair** (see the orientation findings below). |
| framework          | `SimulatorKit.framework`                                             | `SimHIDClient`        | Hosts `SimDeviceLegacyHIDClient` and the Indigo wire-format helpers; loaded by `CoreSimulatorLoader.loadSimulatorKit()`. |
| class              | `SimulatorKit.SimDeviceLegacyHIDClient`                              | `SimHIDClient`        | Swift-bridged subclass instantiated by the bridge; carries the `initWithDevice:error:` and `sendWithMessage:…` selectors inherited from `SimDeviceLegacyClient`. |
| instance selector  | `-[SimulatorKit.SimDeviceLegacyHIDClient initWithDevice:error:]`     | `SimHIDClient`        | Construct a HID client bound to a specific `SimDevice`.        |
| instance selector  | `-[SimulatorKit.SimDeviceLegacyHIDClient sendWithMessage:freeWhenDone:completionQueue:completion:]` | `SimHIDClient` | Submit an Indigo binary message; ownership of the buffer transfers when `freeWhenDone:YES`. |
| C symbol           | `IndigoHIDMessageForButton`                                          | `SimHIDClient`        | `IndigoMessage * (^)(int eventSource, int op, int target)` — builds a hardware-button event. |
| C symbol           | `IndigoHIDMessageForKeyboardArbitrary`                               | `SimHIDClient`        | `IndigoMessage * (^)(int keyCode, int op)` — builds a keyboard event. |
| C symbol           | `IndigoHIDMessageForMouseNSEvent`                                    | `SimHIDClient`        | True prototype (from the framework's embedded type string): `IndigoMessage * (^)(CGPoint *p0, CGPoint *p1, IndigoHIDTarget target, NSEventType eventType, NSSize size, IndigoHIDEdge edge)`. Bound **twice**: (1) the legacy 5-arg `fnMouse` typedef `(…, int eventType, BOOL flag)` for plain touches — short by `NSSize`+`IndigoHIDEdge`, so it sends `edge = 0` with a garbage `NSSize`, harmless for taps/drags (ratio fields overwritten); (2) the full 6-arg `fnMouseEdge` typedef for the **edge-tagged system-gesture** path (home / App Switcher), where `IndigoHIDEdge` (bottom = 3, live-confirmed) routes the drag to SpringBoard and a `MouseDragged` build needs a valid `NSSize` (a short call returns NULL / crashes the sim). `edge` lands at `IndigoTouch.field11` (0x6c). |
| C symbol           | `IndigoHIDMessageForHIDArbitrary`                                    | `SimHIDClient`        | `IndigoMessage * (^)(int target, int usagePage, int usage, int op)` — builds an arbitrary-usage HID event. Used for Siri (Consumer page `0x0C` / usage `0xCF` "Voice Command"); arg order reverse-engineered vs. `IndigoHIDMessageForButton`. |
| C symbol (optional) | `IndigoHIDMessageForDigitalCrownEvent`                             | `SimHIDClient`        | `IndigoMessage * (^)(double delta)` — builds a watchOS Digital Crown rotary event; signed `delta` is the rotation (sign = direction). **Optional / best-effort**: watchOS-only, absent on older SimulatorKit; the probe reports but does not fail on its absence, and only `rotateCrown(delta:)` requires it (other HID is unaffected). Single-`double` signature reverse-engineered + live-confirmed (see "Digital Crown (watchOS)" below). |
| instance selector  | `-[SimDevice lookup:error:]`                                         | `SimPurpleHID`        | Look up a named Mach service in the simulator's bootstrap namespace; used to resolve `PurpleWorkspacePort`. |
| Mach service       | `PurpleWorkspacePort` (runtime-only)                                 | `SimPurpleHID`        | Sim-side Mach port that accepts GSEvent payloads (notably device-orientation messages). Existence verified at use time — the probe can't introspect bootstrap names without a booted device. |
| instance selector  | `-[SimDevice availableLocationScenarios]`                            | `SimLocation`         | The runtime's built-in location "trips". **Declared as bare `id`** with no error out-param; the live-verified shape (Xcode 26.5 / iOS 26) is an `NSArray` of `NSDictionary`, each with `name` and `localizedName` (both `NSString`, identical for the four built-ins on an English host). The wrapper vends `name` — what `setLocationScenario:` consumes — and keeps string-array / dictionary-key fallbacks since the declared type guarantees nothing. **Requires a booted device**: shut down it returns an empty array, matching `xcrun simctl location <udid> list`, which prints only the table header. The four on this runtime are City Run, City Bicycle Ride, Freeway Drive, Apple. |
| instance selector  | `-[SimDevice setLocationWithLatitude:andLongitude:error:]`           | `SimLocation`         | Pins the device to a fixed coordinate until cleared. |
| instance selector  | `-[SimDevice setLocationScenario:error:]`                            | `SimLocation`         | Starts a named scenario from `availableLocationScenarios`. Playback runs sim-side; the call returns on acceptance, not completion. **Does not validate the name** — an unknown scenario is accepted silently with no error and no effect (live-verified). `simctl` appears to validate only because it checks the list client-side first. Callers must validate against `availableScenarios()` or a typo silently no-ops. |
| instance selector  | `-[SimDevice clearSimulatedLocationWithError:]`                      | `SimLocation`         | Stops any running scenario or route and drops the simulated position. **Note there is no corresponding getter** anywhere on the category — nothing reads the active location back, so callers must track what they set. |
| instance selector  | `-[SimDevice startLocationSimulationWithDistance:speed:waypoints:error:]` | `SimLocation`    | Walks the device along a user-supplied route, publishing a position every `distance` metres. **`waypoints` is declared as a bare `NSArray` and is a flat list of alternating latitude/longitude `NSNumber`s** — `@[@37.77, @-122.41, @40.71, @-74.00]` is *two* waypoints. Recovered from `simctl`'s machine code, not guessed: its parser splits each `lat,lon` argument, calls `+[NSNumber numberWithDouble:]` on both halves, and `addObject:`s each into one array, then reports `count / 2` as the waypoint total and rejects `count <= 3`. `CLLocation` was never a candidate — neither `simctl` nor CoreSimulator links CoreLocation. The array is secure-coded (`sim_securelyArchivedDataWithRootObject:`) and sent over MIG, so elements must be plist classes. **Validates nothing**: an odd count or a non-`NSNumber` element reaches Apple's archiver, so `SimLocation` checks arity and element class first. |
| instance selector  | `-[SimDevice startLocationSimulationWithInterval:speed:waypoints:error:]` | `SimLocation`    | Same as the distance form, publishing every `interval` seconds instead. `simctl`'s defaults, read from the same disassembly, are speed `20.0` m/s and interval `1.0` s; it picks the distance selector only when `distance > 0`. |
| framework          | `AccessibilityPlatformTranslation.framework`                         | `SimAccessibility`    | Hosts `AXPTranslator` and the `AXPTranslationTokenDelegateHelper` protocol; lives at `/System/Library/PrivateFrameworks/`. Loaded by `CoreSimulatorLoader.loadAccessibilityPlatformTranslation()`. |
| class              | `AXPTranslator`                                                      | `SimAccessibility`    | Singleton entry point; brokers tree requests between macOS and the iOS-side AX server. |
| class              | `AXPTranslatorResponse`                                              | `SimAccessibility`    | Response object; `+emptyResponse` is the delegate's fallback when the request times out or has no device. |
| class              | `AXPMacPlatformElement`                                              | `SimAccessibility`    | macOS-side wrapper for one iOS-side accessibility element. |
| class selector     | `+[AXPTranslator sharedInstance]`                                    | `SimAccessibility`    | Process-wide singleton accessor. |
| class selector     | `+[AXPTranslatorResponse emptyResponse]`                             | `SimAccessibility`    | Sentinel returned on no-device or timeout from the shared delegate. |
| instance selector  | `-[AXPTranslator frontmostApplicationWithDisplayId:bridgeDelegateToken:]` | `SimAccessibility` | Entry point for whole-app tree walks. |
| instance selector  | `-[AXPTranslator objectAtPoint:displayId:bridgeDelegateToken:]`      | `SimAccessibility`    | Hit-test lookup at a normalized point. |
| instance selector  | `-[AXPTranslator macPlatformElementFromTranslation:]`                | `SimAccessibility`    | Converts a translation into a usable `AXPMacPlatformElement`. |
| instance selector  | `-[AXPTranslator setBridgeTokenDelegate:]`                           | `SimAccessibility`    | Installs the shared delegate; idempotent because every client assigns the same singleton. |
| instance selector  | `-[AXPMacPlatformElement accessibilityRole]`                         | `SimAccessibility`    | Element kind; serialized as `role` (with the `AX` prefix stripped). |
| instance selector  | `-[AXPMacPlatformElement accessibilityLabel]`                        | `SimAccessibility`    | Localized human-readable label. |
| instance selector  | `-[AXPMacPlatformElement accessibilityIdentifier]`                   | `SimAccessibility`    | Developer-set identifier — the iOS-side `UIAccessibilityIdentification` value. |
| instance selector  | `-[AXPMacPlatformElement accessibilitySubrole]`                      | `SimAccessibility`    | Refinement of role (e.g. "secure text field" within "text field"). |
| instance selector  | `-[AXPMacPlatformElement accessibilityValue]`                        | `SimAccessibility`    | Current value (text content, slider position, etc.). |
| instance selector  | `-[AXPMacPlatformElement accessibilityFrame]`                        | `SimAccessibility`    | Element frame in simulator-coordinate space. |
| instance selector  | `-[AXPMacPlatformElement accessibilityChildren]`                     | `SimAccessibility`    | Child elements; the recursive tree walk hangs off this. |
| instance selector  | `-[AXPMacPlatformElement translation]`                               | `SimAccessibility`    | The underlying `AXPTranslationObject`; the bridge re-stamps its token per element so AXP routes child callbacks correctly. |
| instance selector  | `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]` | `SimAccessibility` | The async sim-side AX server round-trip; the shared delegate waits on it (5s timeout) per request. |
| protocol           | `AXPTranslationTokenDelegateHelper`                                  | `SimAccessibility`    | Three-method delegate protocol AXP calls back through. The shared `CSBAccessibilityDelegate` implements all three; skipping any crashes the first translation request. |
| protocol method    | `-<AXPTranslationTokenDelegateHelper> accessibilityTranslationDelegateBridgeCallbackWithToken:` | `SimAccessibility` | Returns the per-token sync-over-async callback block. |
| protocol method    | `-<AXPTranslationTokenDelegateHelper> accessibilityTranslationConvertPlatformFrameToSystem:withToken:` | `SimAccessibility` | Coordinate-space conversion hook; the bridge uses identity (sim-space = render-space). |
| protocol method    | `-<AXPTranslationTokenDelegateHelper> accessibilityTranslationRootParentWithToken:` | `SimAccessibility` | Host-parent lookup; the bridge returns nil (the iOS-side tree is the whole world). |

## Display orientation

This section records the presented-orientation source, its mapping, and the
approaches ruled out.

- **When / where:** 2026-08-13 · macOS 26.5.2 · Xcode 26.6 · iOS 26.5 ·
  iPhone 17 Pro (simulator).
- **Mechanism — `SimScreen` on the display descriptor.** The live
  `com.apple.framebuffer.display` descriptor conforms to `SimScreen`
  alongside the `SimDisplayIOSurfaceRenderable` the picker already selects
  on, so orientation rides the object the surface subscription resolved. No
  second lookup and no new framework.
- **Ruled out: `SimDisplayRotationAngleDelegate`.** It declares
  `didChangeDisplayAngle:(double)` and looks like the obvious source. No
  `device.io` port or descriptor vends it, and no proxy answers
  `displayAngle`.
- **`uiOrientation` is a `UIInterfaceOrientation`**, while
  `CSBDeviceOrientation` / `CSBDisplayOrientation` are `UIDeviceOrientation`.
  **The landscape pair is swapped.** Pinned by rotating a device running an
  app that follows it:

  | device orientation | `uiOrientation` |
  |---|---|
  | portrait | 1 |
  | landscapeLeft | 4 |
  | landscapeRight | 3 |

  The direction was confirmed against what the renderer already draws
  correctly rather than derived from the UIKit convention, because a
  hand-derivation of this swap inverts without anything failing loudly.
- **Cadence: no debounce needed.** Exactly one `propertiesChangedCallback`
  per rotation, ~50 ms after the command returns. No animated or
  non-cardinal intermediates were observed, but the bridge re-reads
  `screenProperties` inside the callback rather than trusting the block's
  arguments, so a runtime that did animate would still settle correctly.
- **All three callback blocks must be non-nil.** Passing nil for the frame
  and surfaces callbacks to observe properties only **kills the simulator**:
  CoreSimulator invokes them unconditionally, so the first frame after
  registration dereferences NULL and takes the device down. Reproduced twice
  in the environment above.
- **Display orientation is not device attitude, and diverges in ordinary
  use.** The iPhone Home Screen never rotates at all; Safari tracked one
  rotation and then refused upside-down, leaving the display in landscape
  while the device continued to `portraitUpsideDown`. This is why the
  daemon keeps control and display as two values.
- **There is no control-orientation (attitude) source for a simulator, and
  this is not a gap in the search.** A simulator has no physical attitude,
  no sensor, and no ground truth; its device orientation is whatever rotate
  command was last sent, and nothing in CoreSimulator or SimulatorKit
  accumulates that. The bridge's own rotate is a one-way GSEvent with no
  reply and no getter. So `controlOrientation` is command-sourced by
  construction, not by preference.

## Digital Crown (watchOS)

Durable reverse-engineering record for the watchOS Digital Crown, so the
constants survive review/rebase independent of any commit body.

- **When / where:** 2026-05-24 · macOS 26.4.1 (25E253), arm64e · Xcode 26.5
  (17F42) · watchOS 26.5 (23T570) · Apple Watch Series 11 (46mm).
- **Mechanism — outcome (a), dedicated builder.** SimulatorKit exports
  `IndigoHIDMessageForDigitalCrownEvent` (sibling: `…ForDigitalDialEvent`).
  No `IndigoHIDMessageForHIDArbitrary` guessing and no hand-constructed
  `IndigoWheel` payload required.
- **Optional / best-effort.** The builder is watchOS-only and absent on
  older SimulatorKit. `SimHIDClient.clientForUDID:` dlsym's it but does NOT
  fail when it's missing — only `rotateCrown(delta:)` errors in that case, so
  iOS HID (touch/keyboard/Siri/buttons) is unaffected. The probe reports it
  in the `optionalCSymbols` list and never fails the gate on its absence.
- **Signature** (`otool -arch arm64e -tV` of SimulatorKit, cross-referenced
  against `IndigoHIDMessageForButton`): `IndigoMessage *
  IndigoHIDMessageForDigitalCrownEvent(double delta)` — a **single `double`**
  in `d0`. The builder `calloc`s `0xC0` bytes and writes: eventType `1`
  @`0x1c`, innerSize `0xa0` @`0x18`, payload kind **`6`** @`0x20`, the delta
  @`0x3c`, constant `0x10` @`0x2c`, crown discriminator `0x34` @`0x4c` (the
  Dial builder is byte-identical but writes `0xc8` there). No `target`/`op`/
  `usage` args — the crown event is self-targeted (unlike the button builder).
- **Sign / unit (live):** positive `delta` scrolls forward (content moves up
  / toward a list's end); negative scrolls back. `delta = 10` per send × ~6
  sends ≈ one screen of the watch app grid. The unit is a coarse scroll
  magnitude; the daemon/CLI layer calibrates it.
- **Crown press + Side button:** the crown *press* is the Home equivalent.
  `IndigoHIDMessageForButton(ButtonEventSourceHomeButton 0x0, …)` returns the
  watch from the clock face to the app grid. The watch Side button is the
  existing `ButtonEventSourceSideButton 0xbb8` and opens Control Center. Both
  confirmed live.
- **How confirmed:** a throwaway live test drove crown deltas + presses
  against the booted watch and screenshotted each step (`xcrun simctl io
  <udid> screenshot`): the app grid scrolled with rotation, crown-press
  returned Home, Side opened Control Center. Sends route through
  `SimHIDClient`'s existing `_sendBuiltMessage:` (disconnect-recovery) path.
