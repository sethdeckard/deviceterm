// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
//
// deviceterm — macOS-native terminal with first-class iOS Simulator panes.
// See docs/PHILOSOPHY.md, docs/ARCHITECTURE.md, docs/BUILDING.md for design context.

import PackageDescription

// First-party targets treat compiler warnings as errors in debug and release
// builds through SwiftPM and Xcode. Per-target settings leave GhosttyKit and
// Sparkle unchanged. If an SDK deprecation blocks a release, add
// `.treatWarning("DeprecatedDeclaration", as: .warning)` to the affected
// warning settings.
let strictWarnings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]
let strictCWarnings: [CSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "deviceterm",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "deviceterm-probe", targets: ["CompatProbe"]),
        .executable(name: "deviceterm-daemon", targets: ["DeviceTermDaemon"]),
        .executable(name: "deviceterm-shim", targets: ["Shim"]),
        .executable(name: "deviceterm-cli", targets: ["DeviceTermCLI"]),
        .executable(name: "deviceterm", targets: ["App"]),
        // Dev/test-only out-of-process UI-test instrument. Holds the
        // Screen Recording + Accessibility grants so DeviceTerm.app never
        // has to; an in-tab agent drives it to screenshot / introspect /
        // gesture-drive the GUI. Never bundled into the release DMG.
        .executable(name: "deviceterm-uitest", targets: ["DeviceTermUITest"]),
    ],
    dependencies: [
        // libghostty (Ghostty's renderer + input + parser + surface C
        // API) as a prebuilt, checksummed SwiftPM binary package —
        // GhosttyKit.xcframework + the runtime resource tree. No zig,
        // no Ghostty source, no local build on the deviceterm side.
        .package(
            url: "https://github.com/sethdeckard/libghostty-spm.git",
            exact: "0.1.1"
        ),
        // Sparkle 2 — macOS auto-update framework (signed EdDSA appcasts).
        // Linked into the App target only; the daemon/CLI never update
        // themselves. Ghostty uses Sparkle the same way.
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.6.0"
        ),
    ],
    targets: [
        // Quarantine for private CoreSimulator types. Swift code outside this
        // module never sees private selectors or protocols; the module
        // exposes Swift-friendly wrappers via include/.
        .target(
            name: "CoreSimulatorBridge",
            path: "Sources/CoreSimulatorBridge",
            exclude: [
                "as-tested.md",
                "PrivateHeaders/LICENSE",
                "PrivateHeaders/UPSTREAM.md",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // Vendored idb headers for the private-API types we cast to.
                .headerSearchPath("PrivateHeaders"),
                // Allow the dynamic id-returning objc_msgSend calls that
                // SimDisplayHandle's renderable picker will need. Set here
                // so the whole bridge compiles uniformly.
                .define("OBJC_OLD_DISPATCH_PROTOTYPES", to: "1"),
            ] + strictCWarnings
        ),

        // Unit + integration tests for CoreSimulatorBridge. Integration
        // tests hit the live framework on the host — they require a
        // working Xcode install.
        .testTarget(
            name: "CoreSimulatorBridgeTests",
            dependencies: ["CoreSimulatorBridge"],
            path: "Tests/CoreSimulatorBridgeTests",
            swiftSettings: strictWarnings
        ),

        // Compatibility probe — dlopens CoreSimulator, enumerates required
        // classes/protocols/selectors, prints OK or a structured failure
        // report. Run explicitly with `make probe`, through `make verify`,
        // and before release tags. The production app never invokes it.
        .executableTarget(
            name: "CompatProbe",
            dependencies: ["CoreSimulatorBridge"],
            path: "Sources/CompatProbe",
            swiftSettings: strictWarnings
        ),

        // Tiny C shim over the system zlib so the media negotiator offer can
        // compress its blob at a chosen deflate level. MirrorPipeline is its
        // sole consumer.
        .target(
            name: "CZlibShim",
            path: "Sources/CZlibShim",
            publicHeadersPath: "include",
            cSettings: strictCWarnings,
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),

        // Correlating a selected device to the live OS `utun` that carries it:
        // the tunnel census plus the bounded poll that yields a `DeviceRoute`.
        // Foundation-only; the daemon injects a `devicectl`-backed address
        // source, so this target owns no subprocess or device enumeration.
        .target(
            name: "DeviceReachability",
            path: "Sources/DeviceReachability",
            swiftSettings: strictWarnings
        ),

        .testTarget(
            name: "DeviceReachabilityTests",
            dependencies: ["DeviceReachability"],
            path: "Tests/DeviceReachabilityTests",
            swiftSettings: strictWarnings
        ),

        // Byte transport, HTTP/2 framing subset, binary object coding, session
        // handshake, directory discovery, and role-based channel acquisition —
        // everything between a resolved route and a usable set of device
        // channels. The transport vocabulary (service identifiers, framing,
        // envelope keys) stays private here; the package-facing surface is the
        // `ChannelBroker`, roles, channels, `DeviceObject`, identity, and the
        // typed `ChannelBrokerError`/`WireCompatibilityError`. Feature/message
        // selectors are opaque strings the consuming target supplies and keeps
        // private.
        .target(
            name: "ChannelBootstrap",
            dependencies: ["DeviceReachability"],
            path: "Sources/ChannelBootstrap",
            swiftSettings: strictWarnings
        ),

        .testTarget(
            name: "ChannelBootstrapTests",
            dependencies: ["ChannelBootstrap"],
            path: "Tests/ChannelBootstrapTests",
            resources: [.process("Fixtures")],
            swiftSettings: strictWarnings
        ),

        // Typed interaction intents (touch, keyboard, buttons, orientation) over
        // device channels. Owns the HID report layouts, gesture trailers, swipe
        // geometry, and the per-channel FIFO ordering that keeps a multi-report
        // gesture from interleaving.
        .target(
            name: "InteractionRelay",
            dependencies: ["ChannelBootstrap"],
            path: "Sources/InteractionRelay",
            swiftSettings: strictWarnings
        ),

        .testTarget(
            name: "InteractionRelayTests",
            dependencies: ["InteractionRelay"],
            path: "Tests/InteractionRelayTests",
            swiftSettings: strictWarnings
        ),

        // Mirror negotiation, UDP ingress, loss recovery, HEVC assembly, and
        // VideoToolbox decode — ending at decoded pixel buffers. It owns no
        // surface pool, publishing, trace, or lease bookkeeping; the daemon does.
        .target(
            name: "MirrorPipeline",
            dependencies: ["ChannelBootstrap", "DeviceReachability", "CZlibShim"],
            path: "Sources/MirrorPipeline",
            swiftSettings: strictWarnings,
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),

        .testTarget(
            name: "MirrorPipelineTests",
            dependencies: ["MirrorPipeline"],
            path: "Tests/MirrorPipelineTests",
            resources: [.process("Fixtures")],
            swiftSettings: strictWarnings
        ),

        // Off-by-default surface instrumentation shared by the daemon
        // producer and the GUI consumer, so both run one tested pixel
        // stamp/scan + JSONL sink instead of duplicating it.
        .target(
            name: "SurfaceTrace",
            dependencies: [],
            path: "Sources/SurfaceTrace",
            swiftSettings: strictWarnings,
            linkerSettings: [
                .linkedFramework("IOSurface"),
            ]
        ),

        .testTarget(
            name: "SurfaceTraceTests",
            dependencies: ["SurfaceTrace"],
            path: "Tests/SurfaceTraceTests",
            swiftSettings: strictWarnings
        ),

        // Kernel-backed terminal provenance shared by the GUI and daemon:
        // peer identity, verified ancestry, terminal probing, and the pure
        // authorization matcher. Foundation + Darwin only; importing it never
        // pulls the daemon or CoreSimulator into the GUI.
        .target(
            name: "TerminalProvenance",
            path: "Sources/TerminalProvenance",
            swiftSettings: strictWarnings,
            linkerSettings: [
                // The documented audit-token accessors decode the kernel's
                // LOCAL_PEERTOKEN identity without relying on token layout.
                .linkedLibrary("bsm"),
            ]
        ),

        .testTarget(
            name: "TerminalProvenanceTests",
            dependencies: ["TerminalProvenance"],
            path: "Tests/TerminalProvenanceTests",
            swiftSettings: strictWarnings
        ),

        // The shared RPC wire contract: length-prefixed framing, the
        // request/response/event envelope, the `{ok:true}` ack, the
        // client socket, and client-facing result/event Codable shapes.
        // Foundation-only by hard constraint — the GUI client and
        // `deviceterm-cli` link this without transitively pulling
        // `CoreSimulatorBridge`. `Daemon` re-exports it (umbrella) so
        // the relocation is source-transparent to existing consumers.
        .target(
            name: "DaemonProtocol",
            path: "Sources/DaemonProtocol",
            swiftSettings: strictWarnings
        ),

        // Unit tests for the shared wire contract — pure, Foundation-only.
        // RPCMethod rawValue exactness + count (the canonical method set),
        // and Codable round-trips / lenient decodes for the shared enums
        // as they relocate here. The registry-drift guard (keys ==
        // RPCMethod) lives in DaemonTests, which sees both modules.
        .testTarget(
            name: "DaemonProtocolTests",
            dependencies: ["DaemonProtocol"],
            path: "Tests/DaemonProtocolTests",
            swiftSettings: strictWarnings
        ),

        // deviceterm-daemon's library substance. Hosts the device
        // coordinator, the session manager, the RPC server/dispatch,
        // and the status-item host. The wire layer lives in
        // `DaemonProtocol` (re-exported via `DaemonProtocolReexport`).
        // Pure library so it can be exercised by Swift Testing without
        // spinning up an actual NSApp / UDS process.
        //
        // Security framework supplies `SecCodeCopySelf`,
        // `SecCodeCopyStaticCode`, and `SecCodeCopySigningInformation`,
        // used at startup for self-mirror peer identity validation
        // (the automation-mint + automation-scope gate reads the
        // daemon's own team identifier from its signature, then
        // matches it against the XPC peer's audit-token-derived
        // signature). The daemon does NOT link ServiceManagement —
        // only the GUI calls `SMAppService.register()`.
        .target(
            name: "Daemon",
            dependencies: [
                "CoreSimulatorBridge",
                "DaemonProtocol",
                "DeviceReachability",
                "ChannelBootstrap",
                "InteractionRelay",
                "MirrorPipeline",
                "SurfaceTrace",
                "TerminalProvenance",
            ],
            path: "Sources/Daemon",
            swiftSettings: strictWarnings,
            linkerSettings: [
                .linkedFramework("Security"),
                // libbsm vends the documented audit_token_to_pid /
                // audit_token_to_pidversion accessors used to key the
                // GUI-verdict cache, instead of poking the token's
                // opaque layout.
                .linkedLibrary("bsm"),
            ]
        ),

        // Shared test harness (RPC server bring-up + UDS client +
        // helpers) used by both `DaemonTests` and the deliberate
        // `CoreSimulatorLiveTests` track. A plain library (public Daemon
        // API only, no `@testable`) because two test targets can't share
        // sources directly. Lives under Tests/ and is depended on only
        // by test targets, so it never enters a shipped product.
        .target(
            name: "DaemonTestSupport",
            dependencies: ["Daemon"],
            path: "Tests/DaemonTestSupport",
            swiftSettings: strictWarnings
        ),

        .testTarget(
            name: "DaemonTests",
            dependencies: [
                "Daemon",
                "DaemonTestSupport",
                "ChannelBootstrap",
                "InteractionRelay",
                "MirrorPipeline",
            ],
            path: "Tests/DaemonTests",
            resources: [.process("Fixtures")],
            swiftSettings: strictWarnings
        ),

        // Deliberate live-simulator track. Holds every test that needs a
        // *booted* sim and drives real HID/AX/display I/O or boots a
        // device — kept out of the default gate (which `--skip`s this
        // target) because such tests are non-hermetic: they depend on
        // sim state and block on slow CoreSimulator calls. Run with
        // `make test-live`, which sets up a clean booted sim first.
        .testTarget(
            name: "CoreSimulatorLiveTests",
            dependencies: [
                "CoreSimulatorBridge",
                "Daemon",
                "DaemonTestSupport",
            ],
            path: "Tests/CoreSimulatorLiveTests",
            swiftSettings: strictWarnings
        ),

        // Deliberate live-physical-device track. Drives RealDeviceBackend
        // against a real connected iPhone/iPad over the OS CoreDevice
        // tunnel (the split physical-device pipeline) — non-hermetic (needs the device + an
        // active tunnel), so the default gate `--skip`s it. Run with
        // `make test-device-live`, which prechecks the tunnel and fails
        // loudly if absent. Never reboots/shuts down the device.
        .testTarget(
            name: "DeviceLiveTests",
            dependencies: [
                "Daemon",
                "DeviceReachability",
                "ChannelBootstrap",
                "InteractionRelay",
                "MirrorPipeline",
            ],
            path: "Tests/DeviceLiveTests",
            swiftSettings: strictWarnings
        ),

        // deviceterm-daemon's executable wrapper. Thin: builds the four
        // service actors, starts RPCServer, wires StatusItemController
        // + IdleMonitor, then hands off to NSApp.run(). Everything
        // testable lives in the `Daemon` library target.
        .executableTarget(
            name: "DeviceTermDaemon",
            dependencies: ["Daemon"],
            path: "Sources/DeviceTermDaemon",
            swiftSettings: strictWarnings
        ),

        // Engine-agnostic terminal-pane contract. libghostty-free so
        // the GUI can depend on the protocol without transitively
        // linking the C framework; LibghosttyBridge provides the
        // concrete conformance. See `docs/ARCHITECTURE.md` for why the
        // surface (not the daemon) owns the terminal PTY.
        .target(
            name: "TerminalSurface",
            path: "Sources/TerminalSurface",
            swiftSettings: strictWarnings
        ),

        // Concrete TerminalSurface conformance against libghostty's C
        // API. The only target that imports GhosttyKit / sees ghostty.h
        // — the CoreSimulatorBridge-style quarantine pattern applied to
        // libghostty. GhosttyKit is the prebuilt xcframework vended by
        // the libghostty-spm package. linkerSettings carry the
        // frameworks libghostty's static lib needs (Metal/Carbon/etc.);
        // a binary target does not propagate them.
        .target(
            name: "LibghosttyBridge",
            dependencies: [
                "TerminalSurface",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
            path: "Sources/LibghosttyBridge",
            swiftSettings: strictWarnings,
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                // libghostty bundles C++ (glslang, spirv-cross, imgui);
                // its objects need the C++ runtime.
                .linkedLibrary("c++"),
            ]
        ),

        // The test bundle links LibghosttyBridge's objects, which
        // reference libghostty symbols — so it must link the binary
        // target + libghostty's frameworks too (binary-target linkage
        // doesn't propagate transitively to a test bundle through a
        // library target).
        .testTarget(
            name: "LibghosttyBridgeTests",
            dependencies: [
                "LibghosttyBridge",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
            path: "Tests/LibghosttyBridgeTests",
            swiftSettings: strictWarnings,
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                // libghostty bundles C++ (glslang, spirv-cross, imgui);
                // its objects need the C++ runtime.
                .linkedLibrary("c++"),
            ]
        ),

        // Standalone AppKit smoke harness: one window hosting a
        // GhosttyTerminalSurface running a login shell. Proves
        // libghostty rendering + input dispatch in isolation, before
        // the GUI shell exists. Not shipped.
        .executableTarget(
            name: "LibghosttyHarness",
            dependencies: [
                "LibghosttyBridge",
                "TerminalSurface",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(
                    name: "GhosttyKitResources",
                    package: "libghostty-spm"
                ),
            ],
            path: "Sources/LibghosttyHarness",
            swiftSettings: strictWarnings,
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                // libghostty bundles C++ (glslang, spirv-cross, imgui);
                // its objects need the C++ runtime.
                .linkedLibrary("c++"),
            ]
        ),

        // deviceterm-shim — argv[0]-driven shim for xcrun/simctl. Runs in
        // every deviceterm tab's shell. Depends only on `DaemonProtocol`
        // (Foundation-only) for the canonical framing/envelope — no
        // `CoreSimulatorBridge` in a binary that runs every time the
        // user types `xcrun`. (It links only the shared, Foundation-only
        // `DaemonProtocol` wire vocabulary the daemon, GUI, CLI, and
        // shim all share.)
        .executableTarget(
            name: "Shim",
            dependencies: ["DaemonProtocol"],
            path: "Sources/Shim",
            swiftSettings: strictWarnings
        ),

        // Unit tests for the shim's pure argv-detection layer
        // (`detectEvent`). Subprocess-level coverage (stdio
        // passthrough, signal forwarding) is out of scope here.
        .testTarget(
            name: "ShimTests",
            dependencies: ["Shim", "DaemonProtocol"],
            path: "Tests/ShimTests",
            swiftSettings: strictWarnings
        ),

        // DeviceTerm.app — the AppKit GUI shell. Hosts the libghostty
        // terminal surface, the DaemonClient, tabs/windows. Links the
        // same frameworks LibghosttyBridge needs (a binary target's
        // linkage does not propagate). `Resources/` holds bundle
        // metadata consumed by scripts/make-app-bundle.sh, not SwiftPM
        // resources — excluded so SwiftPM doesn't treat the plists as
        // unhandled files.
        .executableTarget(
            name: "App",
            dependencies: [
                "DaemonProtocol",
                "TerminalSurface",
                "LibghosttyBridge",
                "SurfaceTrace",
                "TerminalProvenance",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyKitResources", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/App",
            exclude: ["Resources"],
            swiftSettings: strictWarnings,
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                // ServiceManagement vends SMAppService for daemon
                // registration; Security vends the framework wraps
                // for `SFAuthorization`-style integration the GUI may
                // surface from the helper-disabled sheet.
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
                // CoreLocation backs Device ▸ Location ▸ Use My
                // Location. The GUI is its only client: the daemon
                // never links it and never touches TCC.
                .linkedFramework("CoreLocation"),
                .linkedLibrary("c++"),
            ]
        ),

        // App unit tests. SwiftPM builds an executable target as a
        // testable module, so ConfigFile (pure logic) is reachable
        // via `@testable import App` without a separate library.
        .testTarget(
            name: "AppTests",
            dependencies: ["App", "DaemonProtocol", "TerminalProvenance"],
            path: "Tests/AppTests",
            resources: [.process("Fixtures")],
            swiftSettings: strictWarnings
        ),

        // deviceterm-cli — short-lived RPC client symlinked into each
        // tab's per-session bin/. Speaks the canonical `DaemonProtocol`
        // wire over the daemon's single Unix-domain socket.
        .executableTarget(
            name: "DeviceTermCLI",
            dependencies: ["DaemonProtocol"],
            path: "Sources/DeviceTermCLI",
            swiftSettings: strictWarnings
        ),

        // Unit tests for the CLI's pure layer (argv parsing, wire
        // request shape). Subprocess-level integration tests
        // (stdio/exit/signal passthrough) are a follow-up.
        .testTarget(
            name: "CLITests",
            dependencies: ["DeviceTermCLI", "DaemonProtocol"],
            path: "Tests/CLITests",
            swiftSettings: strictWarnings
        ),

        // deviceterm-uitest — out-of-process UI-test instrument. Runs
        // resident (holds the Screen Recording + Accessibility grants)
        // or as a one-shot client over its own private UDS socket. Links
        // only `DaemonProtocol` (Foundation-only) for the shared framing
        // + client-socket primitives; the capture/AX/drive frameworks
        // land with those surfaces. Dev/test-only — never a dependency
        // of any shipped product.
        .executableTarget(
            name: "DeviceTermUITest",
            dependencies: ["DaemonProtocol"],
            path: "Sources/DeviceTermUITest",
            swiftSettings: strictWarnings,
            linkerSettings: [
                // ScreenCaptureKit captures the composited window-server
                // output (so Metal panes appear); ImageIO encodes the PNG;
                // AppKit supplies the per-display backing scale.
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                // AXIsProcessTrusted / AXUIElement.
                .linkedFramework("ApplicationServices"),
            ]
        ),

        // Hermetic unit tests for the harness: argv parsing, reply
        // shaping, framing round-trips, and an in-process socket
        // round-trip (bind a resident on a temp path, send a ping;
        // assert a silent peer can't wedge it). The capture/AX/drive
        // paths need a live GUI plus TCC grants, so they stay out of
        // the hermetic gate.
        .testTarget(
            name: "DeviceTermUITestTests",
            dependencies: ["DeviceTermUITest", "DaemonProtocol"],
            path: "Tests/DeviceTermUITestTests",
            swiftSettings: strictWarnings,
            linkerSettings: [
                // The test bundle links the target's objects, which
                // reference these frameworks; a target's linkage doesn't
                // propagate to a test bundle.
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                // AXIsProcessTrusted / AXUIElement.
                .linkedFramework("ApplicationServices"),
            ]
        ),

    ]
)
