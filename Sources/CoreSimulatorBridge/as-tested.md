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
gate: Mach services in the simulator's bootstrap, which cannot be
introspected without a booted device, and rows explicitly marked optional.

## Validation runs

| Date | Host | Xcode | Result | Scope |
|---|---|---|---|---|
| 2026-08-07 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 75 symbols present, 0 missing | `make probe`; symbol resolution only |
| 2026-08-17 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 81 symbols present, 0 missing | `make probe`; symbol resolution only |
| 2026-08-18 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 81 symbols present, 0 missing | `make probe`; symbol resolution only |
| 2026-08-26 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 81 symbols present, 0 missing | `make probe`; symbol resolution only |
| 2026-09-06 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 81 symbols present, 0 missing | `make probe`; symbol resolution only |
| 2026-09-06 | macOS 26.5.2 | Xcode 27 beta 6 (27A5252f) | Passed: 81 symbols present, 0 missing | `make probe`; symbol resolution only; SimulatorKit loaded from `Contents/SharedFrameworks` |
| 2026-09-09 | macOS 26.5.2 | Xcode 26.6 (17F113) | Passed: 81 symbols present, 0 missing | `make probe` after the idb header re-snapshot; symbol resolution only |
| 2026-09-09 | macOS 26.5.2 | Xcode 27 beta 6 (27A5252f) | Passed: 81 symbols present, 0 missing | `make probe` after the idb header re-snapshot; symbol resolution only; SimulatorKit loaded from `Contents/SharedFrameworks` |

Behavioral findings that require a booted device stay in their relevant
sections below. A successful probe confirms that the active toolchain still
provides the bridge's introspectable dependencies; it does not replace the
live simulator test track, and it does not establish that the same Xcode can
compile DeviceTerm. Source-build toolchains are tracked in `docs/BUILDING.md`.

Xcode 26.6 stores SimulatorKit below `Contents/Developer`. Xcode 27 beta 6
stores it below `Contents/SharedFrameworks`. The loader tries both locations
in the active Xcode before its machine-wide fallbacks.

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
| instance selector  | `-[SimDeviceType capabilities]`                                      | `SimDeviceHandle`     | Device-type profile. `capabilities.HomeButtonType` is 1 on a device with a physical Home button (every iPhone SE), 2 without one, 0 on a watch. Drives which button Apple Pay double-presses. |
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
| method             | `-[SimDevice spawnAsyncWithPath:options:terminationQueue:terminationHandler:completionQueue:completionHandler:]` | `SimFoldControl`      | Runs the guest-side helper's hinge and orientation commands. The hinge watcher uses simctl spawn. The async form, not `spawnWithPath:`: the vendored header types that one's termination handler as taking no arguments, while this one declares the real `void (^)(int)` the exit status arrives in. `stdout`/`stderr` in `options` are **file descriptors**; a path string is read as a descriptor and aborts the process. |
| protocol method    | `-<SimScreen> unregisterScreenCallbacksWithUUID:`                    | `SimDisplayHandle`    | Teardown counterpart; called on `stopOrientation` and `stop`.  |
| protocol method    | `-<SimScreenProperties> uiOrientation`                               | `SimDisplayHandle`    | The presented orientation, as a `UIInterfaceOrientation`. Mapped to device-orientation vocabulary in the bridge, **swapping the landscape pair** (see the orientation findings below). On a foldable it tracks the *device*, not the panel: both panels report the same value. |
| protocol method    | `-<SimScreenProperties> screenID`                                    | `SimDisplayHandle`    | Small integer panel id, the same one `simctl io --display` accepts. Recorded as `boundScreenID` so a pane can name the panel it mirrors. |
| protocol method    | `-<SimScreenProperties> uniqueId`                                    | `SimDisplayHandle`    | Stable per-panel identifier, unchanged across a fold. Recorded as `boundScreenUniqueId`. |
| framework          | `SimulatorKit.framework`                                             | `SimHIDClient`        | Hosts `SimDeviceLegacyHIDClient` and the Indigo wire-format helpers. `CoreSimulatorLoader.loadSimulatorKit()` tries the active Xcode's `Contents/Developer` and `Contents/SharedFrameworks` layouts first, then machine-wide and default-Xcode fallbacks. |
| class              | `SimulatorKit.SimDeviceLegacyHIDClient`                              | `SimHIDClient`        | Swift-bridged subclass instantiated by the bridge; carries the `initWithDevice:error:` and `sendWithMessage:…` selectors inherited from `SimDeviceLegacyClient`. |
| instance selector  | `-[SimulatorKit.SimDeviceLegacyHIDClient initWithDevice:error:]`     | `SimHIDClient`        | Construct a HID client bound to a specific `SimDevice`.        |
| instance selector  | `-[SimulatorKit.SimDeviceLegacyHIDClient sendWithMessage:freeWhenDone:completionQueue:completion:]` | `SimHIDClient` | Submit an Indigo binary message; ownership of the buffer transfers when `freeWhenDone:YES`. |
| C symbol           | `IndigoHIDMessageForButton`                                          | `SimHIDClient`        | `IndigoMessage * (^)(int eventSource, int op, int target)` — builds a hardware-button event. |
| C symbol           | `IndigoHIDMessageForKeyboardArbitrary`                               | `SimHIDClient`        | `IndigoMessage * (^)(int keyCode, int op)` — builds a keyboard event. |
| C symbol           | `IndigoHIDMessageForMouseNSEvent`                                    | `SimHIDClient`        | True prototype (from the framework's embedded type string): `IndigoMessage * (^)(CGPoint *p0, CGPoint *p1, IndigoHIDTarget target, NSEventType eventType, NSSize size, IndigoHIDEdge edge)`. Bound **twice**: (1) the legacy 5-arg `fnMouse` typedef `(…, int eventType, BOOL flag)` for plain touches, short by `NSSize`+`IndigoHIDEdge`, so it sends `edge = 0` with a garbage `NSSize`, harmless for taps/drags (ratio fields overwritten); (2) the full 6-arg `fnMouseEdge` typedef for the **edge-tagged system-gesture** path (home / App Switcher), where `IndigoHIDEdge` (bottom = 3, live-confirmed) routes the drag to SpringBoard. The builder accepts only the four down/up `NSEventType` values (`LeftMouseDown` 1, `LeftMouseUp` 2, and the right-button twins 3 and 4, which build byte-identical messages); **every motion type returns NULL** (`MouseMoved`, `LeftMouseDragged`, and the rest, through either prototype, whatever `NSSize` and `IndigoHIDEdge` accompany them), so a move is sent as a repeated down at the new point, the same continued-contact convention the plain-touch drag uses. `NSSize` is read only to scale the ratio fields, which the bridge overwrites, so zero is safe. `edge` lands in the **high bytes of `IndigoTouch.eventMask` (0x38)**, above the `IOHIDDigitizerEventMask` bits the untagged path also writes there; `field11` (0x6c) holds the `IndigoHIDTarget`. |
| C symbol           | `IndigoHIDMessageForHIDArbitrary`                                    | `SimHIDClient`        | `IndigoMessage * (^)(int target, int usagePage, int usage, int op)` — builds an arbitrary-usage HID event. Used for Siri (Consumer page `0x0C` / usage `0xCF` "Voice Command"); arg order reverse-engineered vs. `IndigoHIDMessageForButton`. |
| C symbol (optional) | `IndigoHIDMessageForDigitalCrownEvent`                             | `SimHIDClient`        | `IndigoMessage * (^)(double delta)` — builds a watchOS Digital Crown rotary event; signed `delta` is the rotation (sign = direction). **Optional / best-effort**: watchOS-only, absent on older SimulatorKit; the probe reports but does not fail on its absence, and only `rotateCrown(delta:)` requires it (other HID is unaffected). Single-`double` signature reverse-engineered + live-confirmed (see "Digital Crown (watchOS)" below). |
| instance selector  | `-[SimDevice lookup:error:]`                                         | `SimPurpleHID`        | Look up a named Mach service in the simulator's bootstrap namespace; used to resolve `PurpleWorkspacePort`. Also resolves `dtuhidd`'s services for `SimRemoteHIDChannel`. |
| Mach service       | `PurpleWorkspacePort` (runtime-only)                                 | `SimPurpleHID`        | Sim-side Mach port that accepts GSEvent payloads (notably device-orientation messages). Existence verified at use time — the probe can't introspect bootstrap names without a booted device. |
| C symbol (optional) | `xpc_endpoint_create_mach_port_4sim`                                | `SimRemoteHIDChannel` | libSystem SPI. Wraps a Mach port from the simulator's bootstrap as an XPC endpoint. Absent, every input goes through Indigo. |
| C symbol (optional) | `xpc_connection_enable_sim2host_4sim`                               | `SimRemoteHIDChannel` | libSystem SPI. Marks the connection as host-to-simulator. Without it, `dtuhidd` drops the peer as soon as it activates. |
| Mach service       | `com.apple.coredevice.feature.remote.universalhidservice` (runtime-only) | `SimRemoteHIDChannel` | `dtuhidd`'s touch service. Same request vocabulary as a device's `universalhidservice`. |
| Mach service       | `com.apple.coredevice.feature.remote.hid.button` (runtime-only)      | `SimRemoteHIDChannel` | `dtuhidd`'s hardware-button service; takes `IndigoButtonEvent`. |
| Mach service       | `com.apple.coredevice.feature.remote.hid.keyboard` (runtime-only)    | `SimRemoteHIDChannel` | `dtuhidd`'s keyboard service; takes `IndigoKeyboardButtonEvent` and types through `dtuhidd`'s own keyboard. |
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
- **watchOS observation:** 2026-09-11 · macOS 26.5.2 · Xcode 27 beta 6
  (27A5252f) · Apple Watch SE 3 (40mm). Callback registration succeeded, but
  `currentDisplayOrientation` returned unknown (`uiOrientation == 0`) both
  after registration and after landscape/portrait Purple HID events. Surface
  binding, display size, and AX reads still succeeded in the same live run.
  The watch presentation is fixed, so the cardinal-orientation live test is
  family-gated. This records the tested environment; it does not require future
  watchOS runtimes to keep returning zero.
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
  while the device continued to `portraitUpsideDown`.
- **There is no control-orientation (attitude) source for a simulator, and
  this is not a gap in the search.** A simulator has no physical attitude,
  no sensor, and no ground truth; its device orientation is whatever rotate
  command was last sent, and nothing in CoreSimulator or SimulatorKit
  accumulates that. The bridge's own rotate is a one-way GSEvent with no
  reply and no getter. `pane.input.rotate` therefore confirms Simulator
  outcomes through the existing `SimScreen.uiOrientation` observation. An
  orientation-locked app leaves that observation unchanged, so the command
  reports an unconfirmed outcome.
- **A foldable ignores the GSEvent rotate.** On the iPhone Duo it changes the
  device orientation (`devicectl device orientation get` reports it), but the
  UI doesn't re-lay out until the next fold. Device Hub rotates a Duo through
  `CoreDevicePopCoreDeviceExtension`, which posts a vendor HID event on page
  `0xFF61` usage `0x5B` (the hinge's usage) carrying an `IOCFSerialize`d
  `{provider: com.apple.Virtualization.VirtualMachines, source:
  orientation-picker-control, type: enum, value}`, with `value` one of
  `portrait`, `pud`, `landscape-left`, `landscape-right`, `faceup`,
  `facedown`. The fold helper sends
  the same payload, and the UI follows at once. Measured on two boots: with the
  cover lit, `uiOrientation` equals the device orientation; with the inner
  panel lit, it reads a quarter turn clockwise (a device in portrait reads
  `landscapeRight`). A `pud` request with Safari in front on the cover changed
  nothing. `faceup` and `facedown` change the device orientation and leave
  `uiOrientation` alone, and `devicectl device orientation get` reports them
  one request late on the Duo. An ordinary Simulator ignores the whole payload,
  but takes `devicectl device orientation set faceUp`, after which `get` reports
  `faceUp` at once (iPhone 18 Pro, CoreDevice 651.13.5).
- **The guest sees every orientation control event, whoever sends it.** A HID
  monitor client inside the Duo receives Device Hub's
  `orientation-picker-control` events, one per press, with the target in
  `value` (rotate right from portrait steps `landscape-right`, `pud`,
  `landscape-left`, `portrait`), and `IOCFUnserializeBinary` reads the payload
  back. Each press is followed by a page `0xFF0C` usage `0x22` event and a
  hinge event at the unchanged angle. Rotating the closed Duo changes no
  `uiOrientation`, since the cover's Home Screen doesn't rotate, so these
  events are the only sign of it.
- **`devicectl` right after a boot.** `device orientation get` blocked for 212 s
  on a freshly booted Duo, then answered in 0.09 s. `device info displays`
  answered, but briefly reported the inner panel `active` with the hinge shut
  before the cover lit (iOS 27.1).
- **Relative Simulator requests use the latest confirmed presented
  orientation.** This avoids a command-only base drifting from the screen, but
  does not turn display orientation into proof of physical attitude.

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

## Simulator HID daemon (dtuhidd)

- **When / where:** 2026-10-24 · Xcode 27.1 RC · iOS 27.0 iPhone 17 and
  iPad Pro 11 (M5), iOS 26.5 and iOS 18.1 iPhones, watchOS 27.0, iOS 27.1
  iPhone Duo. Keyboard findings 2026-10-25, iOS 27.0 iPhone 17.
- **The gate.** The guest's `SimulatorHID.framework` (loaded by
  backboardd) watches the notify state `com.apple.coredevice.dtuhidd.active`.
  While it's set, `_locked_updateDTUHIDDAffectedServices` disconnects the
  keyboard, MainScreenButtons, and ScreenTouchService services. Indigo
  events to a disconnected service are dropped, and the send still
  succeeds. `ensureServiceActiveForIndigoHIDData:` reconnects a service when
  an Indigo event of the right kind reaches it, and marks it claimed. A
  claimed service is then left alone in both directions. The crown's
  DigitalDialService is never disconnected.
- **Reaching dtuhidd.** Resolve the service with
  `-[SimDevice lookup:error:]`, wrap the port with
  `xpc_endpoint_create_mach_port_4sim`, connect with
  `xpc_connection_create_from_endpoint`, then call
  `xpc_connection_enable_sim2host_4sim`. This is what CoreDevice's
  `SimulatorCoreDevicePlugin` does.
- **The first message on a touch connection must be a request.**
  `dtuhidd` keeps a session only once it has answered one. Otherwise it logs
  "Event received for deallocated peer" after every message and rebuilds the
  session's services, about half a second each time. The bridge sends
  `connectedServices`, which changes nothing and lists every service with
  its `_ServiceID` and, for a touchscreen, its `displayUUID`.
- **Touch report (id 0x09).** Byte 1 counts the contacts, and each takes
  five bytes from byte 3: state, then x and y. A state's top two bits mark
  the contact touching, and its low six are the contact's identity
  (backboardd's `pathIndex`). Two contacts with different identities in one
  report are two fingers. Byte 2 is always `0x05`; its meaning is unknown.
- **One touchscreen per screen.** Each serves one display, at `0x100` plus
  the screen id; the main one is 257. A screen's `SimScreenProperties.uniqueId`
  equals the `displayUUID` `dtuhidd` lists, which is how the bridge
  addresses a foldable's panels.
- **Top-edge swipes** need no gesture trailer. A plain contact from the top
  opens Notification Center, and from the top right Control Center.
- **Apple Pay.** The Indigo Apple Pay source never reaches SpringBoard on
  iOS 27. Two side-button presses through `dtuhidd` do, logged as two
  `C/30` button events. The Wallet sheet wasn't checked, because the test
  sims had no cards.
- **Keys and the on-screen keyboard.** A keyboard registered with
  `createService` counts as attached hardware, so the simulator hides its
  on-screen keyboard until that keyboard goes away. Closing the connection
  that registered it removes it, and so does a `removeService` request
  naming its service id.
- **`removeService` replies with an error when it works.** The reply is an
  XPC "Connection interrupted" dictionary, but the connection stays up and
  `dtuhidd` logs "Removed HID service". Judge the removal by that log line or
  by the on-screen keyboard, not by the reply.
- **`hid.keyboard` types without hiding anything.** An
  `IndigoKeyboardButtonEvent` (`usagePage` 7, `state` 1 to press and 2 to
  release) goes to `dtuhidd`'s own `mainKeyboard(0x200)`, which every
  session already has. Typed text matched, Shift included, with
  `dtuhidd.active` set, and the on-screen keyboard stayed up. No request or
  reply is needed first, unlike the touch connection.
- **Device Hub at the same time.** Device Hub's input arrives through its own
  session. During one roughly ten-second overlap, its drags and
  DeviceTerm's once-a-second taps both landed, every second.
- **Hazard.** An Indigo touch to a target SimulatorHID doesn't know trips an
  assertion in `serviceForIndigoHIDData:` and crashes backboardd.
- **How confirmed:** throwaway live tests and a standalone XPC client,
  judged by backboardd's `new contact` and `digitizer:` debug lines,
  SpringBoard's button log, accessibility reads, and screenshots. `lldb`
  can't attach to the guest `dtuhidd`.

## Two-panel foldables (iPhone Duo)

`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo` (iPhone19,4, iOS 27.1+) is
the first simulator that vends **two sized display descriptors** on one
device, one per panel:

| Panel | `screenID` | `deviceName` | Pixels | `chromeIdentifier` |
|---|---|---|---|---|
| Cover | 1 | `primary` | 1398×2034 | `…chrome.phone15` |
| Inner | 3 | `primary-1` | 2007×2853 | `…chrome.phone14` |

**Exactly one panel is lit at a time.** `screenID` and `uniqueId` identify
each panel; none of the measured state properties identify which one is lit.
Measured on a booted Duo at hinge 0°, 45°, 130° and 180°:

| Field | Cover | Inner | Separates lit from dark? |
|---|---|---|---|
| `powerState` | 1 | 1 | no |
| `displayClass` | 0 | 0 | no |
| `uiOrientation` | 1→3 | 1→3 | no — moves on both together |
| `backlight.state` | 2 | −101 | no — static per panel, unchanged by a fold |
| `backlight.brightnessFactor` | 1.0 | 1.0 | no |
| `seed` | advances | advances | no — a global counter |
| `regionOfInterest` | 0×0 | 0×0 | no |

Both keep a full-size IOSurface in every posture, so a bound-surface test does
not separate them either.

**What does separate them is content.** All sampled colour channels on the
dark panel were zero in both measured postures — ~4,400 pixels on a coarse
grid, maximum channel sum 0 — while the lit panel's maximum was 765. The
picker uses non-zero sampled colour channels as a heuristic for visible
content, as the tiebreaker for the initial selection only. Neither the
measurement nor the check establishes that every byte of the surface is
zero.

**Frame traffic is the authority once streaming.** The dark panel delivers
zero `damageRectanglesCallback` deliveries under real UI activity, verified in
both directions: with the cover lit, a forced redraw produced 3 on the cover
and 0 on the inner; with the inner lit, the same produced 3 on the inner and 0
on the cover, and launching Settings produced 83 on the inner and 0 on the
cover. **An idle device delivers nothing on either panel**, which is why
content is needed for the first bind and traffic cannot do it alone.

**The guest can read the hinge.** The Xcode 27.1 RC's `devicectl` (CoreDevice
651.13.5) ships without the `device motion` group, although CoreDevice still
contains the hinge action. The guest's
`CoreMotion_DeviceStateRelay_Crane` HID service emits IOHIDEvent type 44 on
every hinge change: the angle is field index 1, the mechanical angle is index
2, and the state is index 4 (2 while open). `IOHIDServiceClientCopyEvent(service,
44, …)` returns the current one. A monitor-type event system client (type 1)
reads both with no entitlement. Terminating the host's `simctl spawn` with
SIGTERM ends the guest process.

**A fold announces itself through `propertiesChangedCallback`, on both
panels.** Screen callbacks registered on each panel independently both fired
within 8 ms of each other at every fold, the panel going dark included, and
`uiOrientation` moved 1→3 unfolding and 3→1 folding. That delivery is the only
event a fold produces: there is no fold or panel-power notification, and frame
callbacks stay silent because the device is idle.

**The panels swap slowly, and in between neither is lit.** Measured from the
`propertiesChanged` delivery: the old panel sampled black after 50 ms and 69 ms,
and the new one sampled lit after 246 ms and 507 ms. So a single content sample
taken when the event arrives reports no change, and a consumer following a fold
has to keep asking across that window rather than reading once.

**A panel with something on it fades out over about a second, and `devicectl`
names the new panel before the fade ends.** Measured on 2026-10-15 (macOS
26.7.1, Xcode 27.1 RC, iOS 27.1) with fast folds 120 → 35, 35 → 120 and
120 → 70: `devicectl device info displays` reported the new panel
`active: true` on its first read after each fold returned, within about
0.3 s of the fold, while both panels still read `backlightState: activeOn`.
The old panel kept non-black pixels until its fade ended, so a content check
on it waits out the fade and then draws black.

`SimDisplayLane` follows the `active` flag: it rebinds through
`rebindToScreenID:` as soon as `devicectl` names another panel, and falls
back to the content search when `devicectl` can't answer. Each read is a
process and takes about 0.5 s. Nothing in-process carries the same answer,
because `backlight.state` is fixed per panel (table above).

**Accessibility hit-testing addresses a panel, and display `0` is the cover
panel rather than whichever one is lit.** Taking one settled tree and
hit-testing the centres of eight of its own elements, varying only the
`displayId` passed to `objectAtPoint:displayId:bridgeDelegateToken:`:

| Posture | via display `0` | via the lit panel's `screenID` |
|---|---|---|
| Folded (cover lit, screen 1) | 8 of 8 | 8 of 8 |
| Unfolded (inner lit, screen 3) | **0 of 8** | 4 of 8 |

So a pane mirroring the inner panel finds nothing under any point unless it
names that panel. The 4 that still miss when unfolded have frames beyond the
width the tree reports as its interface size, so they miss on either display:
that is a coordinate-space problem, not a display-addressing one, and it is
not fixed here. `frontmostTree` takes no display and tracks the lit panel on
its own.

**The lit panel is path-dependent, not a function of the angle.** Opening
switched to the inner panel between 100° and 105°. Closing did not mirror it:
`0 → 100 → 105 → 60 → 30` stayed on the inner panel, reproduced twice with 8s
settling and confirmed at 30° by `simctl io screenshot` per display, which
showed the cover panel black. Going straight from 100 → 60, or 120 → 45, does
switch, in about a second. So a test that asserts "below 90° means the cover
panel" is flaky depending on the route taken to get there. Bind by content,
never by angle; the picker already does.

**Touch input addresses the bound panel.** Indigo's fixed digitizer target
(`0x32`) reaches only one of the Duo's panels, and which one varies from boot
to boot. Within one boot, a tap at the same point through three targets, each
judged against a settled tree, gave:

| Lit panel | `0x32` | `0x40000001` | `0x40000003` |
|---|---|---|---|
| Cover (screen 1) | missed | opened the row | missed |
| Inner (screen 3) | opened the row | missed | opened the row |

The screen-based target (`screenID | 0x40000000`) reached the panel it named
and no other. On a two-panel device, `SimDeviceBackend` addresses every touch,
edge and two-finger contact to a panel's screen-based target: the bound panel
for a new contact, and the panel it went down on for a held one. A one-panel
device keeps the fixed target, and keys and buttons address no panel. Only taps
and single-finger swipes have been measured through the screen-based target.

The earlier result here, the fixed target delivering to a folded Duo five runs
out of five, came from a single boot in which `0x32` happened to reach the
cover. A single boot can't show a property that varies by boot, so check a
foldable input result on a second boot before trusting it.

Every run had a pane attached, so the display handle held screen callbacks on
the panel being tapped. Whether the screen-based target needs that
registration was not tested.

A contact held across a fold stays on the panel it went down on: its moves and
its release are addressed to that panel's screen id, not the newly bound one.
Checked by hand once in each direction, holding a still press in the GUI pane
through `deviceterm fold open` and through `deviceterm fold 0`. After each
release, the newly lit panel took the next tap normally.

**A delivery check is only as good as the tree it is judged against.** Settings
keeps animating for seconds after launch, so a tree read too early differs from
the next read on its own, and both a "nothing changed" and a "something
changed" verdict against it are worthless. Wait for two reads to agree before
attributing any change to input.

- **How confirmed:** host-side probes against a booted Duo (iOS 27.1 /
  24A94401) driving the hinge between postures, sampling `SimScreenProperties`
  through the same ROCK proxies the bridge uses, locking each candidate's
  IOSurface to sample it, counting callback deliveries over timed windows, and
  timestamping screen callbacks registered on both panels at once across a
  0° → 130° → 0° round trip. The input and hit-test runs held the sim lock,
  because another checkout's `make test-live` shuts the fleet down and will
  otherwise pull the device out from under a measurement.

Touches to a foldable now go to `dtuhidd`'s touchscreen for the bound
panel's display UUID; see Simulator HID daemon. The screen-based Indigo
target above remains the fallback when `dtuhidd` can't be reached.
