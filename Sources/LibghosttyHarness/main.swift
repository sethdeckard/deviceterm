// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import GhosttyKitResources
import LibghosttyBridge
import TerminalSurface

// LibghosttyHarness: a standalone AppKit window hosting one
// GhosttyTerminalSurface running a login shell.
//
// Purpose: prove libghostty rendering + input dispatch in isolation
// of the full GUI shell. A standalone debugging surface, not shipped
// and not signed; run it via `make run-libghostty-harness`.
//
// Not a bundled .app, so NSApplication is driven programmatically and
// libghostty is pointed at the resource tree shipped by the
// libghostty-spm package (`GhosttyKitResources`, via Bundle.module).
// Release libghostty reads GHOSTTY_RESOURCES_DIR; the bridge sets it
// before ghostty_init.

@MainActor
final class HarnessDelegate: NSObject, NSApplicationDelegate, TerminalSurfaceDelegate {
    private var window: NSWindow?
    private var surface: GhosttyTerminalSurface?

    // GHOSTTY_RESOURCES_DIR must point at the resource root, holding
    // terminfo/ and ghostty/ side by side. Env override wins (handy
    // for pointing at a local Ghostty checkout); otherwise the tree
    // shipped by the libghostty-spm package via Bundle.module.
    private static func resourcesDirectory() -> URL? {
        if let override = ProcessInfo.processInfo
            .environment["DEVICETERM_LIBGHOSTTY_RESOURCES"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return GhosttyKitResources.directoryURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "libghostty harness"
        window.center()
        self.window = window

        let surface = GhosttyTerminalSurface(
            resourcesDirectory: Self.resourcesDirectory()
        )
        surface.delegate = self
        self.surface = surface

        let host = surface.view
        host.translatesAutoresizingMaskIntoConstraints = false
        // Own the content view so libghostty gets a clean container
        // (its renderer takes over the host view's layer).
        let content = NSView()
        window.contentView = content
        content.addSubview(host)
        NSLayoutConstraint.activate(
            [
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ]
            )

        do {
            try surface.attach(command: .loginShell())
        } catch {
            FileHandle.standardError.write(
                Data("harness: attach failed: \(error)\n".utf8)
            )
            NSApp.terminate(nil)
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool { true }

    // MARK: - TerminalSurfaceDelegate

    func terminalSurface(_ surface: any TerminalSurface, didChangeTitle title: String) {
        window?.title = title
    }

    func terminalSurface(
        _ surface: any TerminalSurface,
        didChangeWorkingDirectory path: String
    ) {
        window?.representedFilename = path
    }

    func terminalSurface(
        _ surface: any TerminalSurface,
        didExitWithCode code: Int32?
    ) {
        NSApp.terminate(nil)
    }

    func terminalSurfaceWantsBell(_ surface: any TerminalSurface) {
        NSSound.beep()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = HarnessDelegate()
app.delegate = delegate
app.run()
