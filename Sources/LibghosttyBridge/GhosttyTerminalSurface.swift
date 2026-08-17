// SPDX-License-Identifier: GPL-3.0-or-later
//
// GhosttyTerminalSurface: the libghostty-backed TerminalSurface.
//
// Ties the process runtime (GhosttyRuntime), the render/input view
// (GhosttySurfaceView), and the engine-agnostic contract
// (TerminalSurface) together. `attach` marshals a TerminalCommand
// into ghostty_surface_config_s and spawns the shell *inside
// libghostty*; there is no daemon PTY for terminal panes.
//
// String-lifetime rule (libghostty copies config strings during
// ghostty_surface_new, then they may be freed): we strdup the
// command / cwd / env into C buffers, hold them across the single
// ghostty_surface_new call, and free immediately after. Do NOT keep
// the config struct around: its pointers are dead post-call.

import AppKit
import Foundation
import GhosttyKit
import TerminalSurface

@MainActor
public final class GhosttyTerminalSurface: TerminalSurface {
    /// A macOS virtual keycode no physical key uses, so libghostty
    /// resolves it to `.unidentified`.
    ///
    /// Injected text must not claim a physical key. `Surface.keyCallback`
    /// runs `maybeHandleBinding`, including key tables, against the
    /// *physical* key before the event's text is written, and libghostty
    /// derives that key by looking the keycode up in
    /// `input/keycodes.zig`. Keycode 0 is `KeyA` on macOS (its row is
    /// `.{ 0x070004, 0x001e, 0x0026, 0x001e, 0x0000, "KeyA" }`), so zero
    /// would let a binding on `a` swallow an injected character.
    ///
    /// 0xFFFE is absent from that table, so the lookup falls through to
    /// its explicit `.unidentified` branch. Prefer it over 0xFFFF, which
    /// the table uses as its "absent on this platform" sentinel and
    /// therefore matches real rows.
    private static let unmappedKeycode: UInt32 = 0xFFFE

    /// `kVK_Control`, which libghostty maps to `.control_left` (its row
    /// is `.{ 0x0700e0, 0x001d, 0x0025, 0x001d, 0x003b, "ControlLeft" }`
    /// in `input/keycodes.zig`). Used to end a synthesized chord the way
    /// a real keyboard does; see `sendNul`.
    private static let controlLeftKeycode: UInt32 = 0x3B

    public weak var delegate: TerminalSurfaceDelegate?

    private let resourcesDirectory: URL?
    private let loadUserConfig: Bool
    private let surfaceView = GhosttySurfaceView(frame: .zero)
    private var surface: ghostty_surface_t?
    private var didNotifyExit = false

    public var view: NSView { surfaceView }

    /// Terminal cell metrics in **points** (AppKit's coordinate
    /// space). libghostty stores `cell_*_px` in backing-store
    /// pixels because `GhosttySurfaceView.pushSize` feeds it
    /// `convertToBacking(bounds)`; on Retina that's `2 × points`,
    /// so dividing by the view's backing scale recovers points.
    /// Falls back to `NSScreen.main?.backingScaleFactor ?? 2`
    /// before the view is in a window (same fallback chain
    /// `attach()` uses for the initial content scale). `.zero`
    /// until `attach` succeeds; the host treats that as "no
    /// math available yet" rather than asserting.
    public var cellSize: CGSize {
        guard let surface else { return .zero }
        let size = ghostty_surface_size(surface)
        let scale = surfaceView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        guard scale > 0 else { return .zero }
        return CGSize(
            width: CGFloat(size.cell_width_px) / scale,
            height: CGFloat(size.cell_height_px) / scale
        )
    }

    /// `resourcesDirectory` is the libghostty resource root, holding
    /// `terminfo/` and `ghostty/` side by side. `loadUserConfig: false`
    /// keeps libghostty's built-in defaults instead of the user's
    /// ghostty config. The first surface to attach supplies both
    /// values to the process-wide runtime; later surfaces cannot
    /// change them.
    public init(resourcesDirectory: URL?, loadUserConfig: Bool = true) {
        self.resourcesDirectory = resourcesDirectory
        self.loadUserConfig = loadUserConfig
    }

    // Isolated so we can read `surface` and free it on the main actor
    // (libghostty frees must be on main; deinit is otherwise
    // nonisolated and can't touch the non-Sendable handle).
    isolated deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    // Build ghostty_surface_config_s with all C strings alive for the
    // duration of `body` (the single ghostty_surface_new call), then
    // free them. The env array is variable-length so the recursive
    // withCString pyramid doesn't fit, so strdup + free is the clean
    // equivalent given libghostty copies during the call.
    private static func withConfig<R>(
        command: TerminalCommand,
        view: GhosttySurfaceView,
        owner: GhosttyTerminalSurface,
        _ body: (UnsafePointer<ghostty_surface_config_s>) -> R
    ) -> R {
        let commandC = strdup(ShellCommandLine.commandString(for: command))
        let cwdC = command.workingDirectory.flatMap { strdup($0) }
        let initialInputC = command.initialInput.flatMap { strdup($0) }
        let pairs = ShellCommandLine.environmentPairs(for: command)
        let envC: [(UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?)] =
            pairs.map { (strdup($0.key), strdup($0.value)) }
        defer {
            free(commandC)
            if let cwdC { free(cwdC) }
            if let initialInputC { free(initialInputC) }
            for (key, value) in envC { free(key); free(value) }
        }

        var envVars = envC.map {
            ghostty_env_var_s(key: $0.0, value: $0.1)
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        )
        config.userdata = Unmanaged.passUnretained(owner).toOpaque()
        config.scale_factor = Double(
            view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
            )
        config.font_size = 0  // inherit from ghostty config
        config.command = UnsafePointer(commandC)
        config.working_directory = cwdC.map { UnsafePointer($0) }
        config.initial_input = initialInputC.map { UnsafePointer($0) }
        config.wait_after_command = false
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        return envVars.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return withUnsafePointer(to: &config) { body($0) }
        }
    }

    public func attach(command: TerminalCommand) throws {
        guard surface == nil else { throw TerminalSurfaceError.alreadyAttached }

        let runtime: GhosttyRuntime
        do {
            runtime = try GhosttyRuntime.bootstrap(
                resourcesDirectory: resourcesDirectory,
                loadUserConfig: loadUserConfig
            )
        } catch {
            throw TerminalSurfaceError.surfaceCreationFailed(
                detail: "runtime bootstrap: \(error)"
            )
        }
        guard let app = runtime.app else {
            throw TerminalSurfaceError.surfaceCreationFailed(
                detail: "runtime has no app handle"
            )
        }

        let made = Self.withConfig(
            command: command,
            view: surfaceView,
            owner: self
        ) { configPtr in
            ghostty_surface_new(app, configPtr)
        }
        guard let made else {
            throw TerminalSurfaceError.surfaceCreationFailed(
                detail: "ghostty_surface_new returned NULL"
            )
        }

        surface = made
        surfaceView.surface = made

        let scale = Double(
            surfaceView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
            )
        ghostty_surface_set_content_scale(made, scale, scale)
        let backing = surfaceView.convertToBacking(surfaceView.bounds)
        if backing.width > 0, backing.height > 0 {
            ghostty_surface_set_size(
                made,
                UInt32(backing.width),
                UInt32(backing.height)
            )
        }
        ghostty_surface_set_focus(made, true)
        ghostty_surface_refresh(made)
    }

    public func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    /// Inject `text` into the engine's input pipeline as if typed.
    ///
    /// Everything goes through the **key** path, never
    /// `ghostty_surface_text`. That entry point is not an "as if typed"
    /// call: libghostty documents it as "treated like a paste ... this
    /// isn't useful for sending escape sequences. For that, individual
    /// key input should be used" (`src/apprt/embedded.zig`), and it
    /// routes to `completeClipboardPaste`.
    ///
    /// It breaks typed-input semantics in two ways. A newline inside a
    /// bracketed paste, which zsh enables by default, is inserted into
    /// the line buffer *literally* instead of accepting the line, since
    /// refusing to execute pasted newlines is the entire security
    /// purpose of the mode; a trailing `\n` cannot run the command.
    /// And paced injection sends one character per call, so each
    /// character becomes its own paste: with a foreground process
    /// holding the tty there is no line editor to consume the wrappers,
    /// and `ESC[200~`/`ESC[201~` echo between the characters.
    ///
    /// Throws `.notAttached` when `attach` hasn't installed the surface
    /// yet (caller sees a typed failure rather than a silent drop); an
    /// empty string is a no-op.
    public func sendInput(_ text: String) throws {
        guard let surface else { throw TerminalSurfaceError.notAttached }
        guard !text.isEmpty else { return }
        // `omittingEmptySubsequences: false` keeps the run count equal
        // to newline count + 1, so a trailing "\n" yields a final empty
        // run whose only effect is the Return before it.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 { sendReturn(surface) }
            let chunks = line.split(separator: "\0", omittingEmptySubsequences: false)
            for (chunkIndex, chunk) in chunks.enumerated() {
                if chunkIndex > 0 { sendNul(surface) }
                guard !chunk.isEmpty else { continue }
                sendText(surface, String(chunk))
            }
        }
    }

    /// Deliver `text` as a synthesized key press carrying it verbatim.
    ///
    /// Ported from stock Ghostty's `committedPreeditTextAction`
    /// (`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`),
    /// which is upstream's own way to inject text with no `NSEvent` in
    /// hand: an otherwise-zeroed event whose only populated field is
    /// `text`, so libghostty's KeyEncoder writes the characters through
    /// without any paste framing. Upstream leaves `keycode` at 0; we
    /// send `unmappedKeycode` instead, for the reason documented on
    /// that constant.
    ///
    /// Binding exposure is reduced, not eliminated. `Set.getEvent`
    /// (`src/input/Binding.zig`) tries the physical key first, which
    /// `unmappedKeycode` defeats, but then tries the event's text when
    /// that text is exactly one codepoint, and finally the unshifted
    /// codepoint. Any chunk that is exactly one codepoint stays exposed
    /// to an unmodified single-key binding or key table; anything longer
    /// skips that branch entirely. Paced injection sends one Swift
    /// `Character` per chunk, and a `Character` is a grapheme cluster
    /// that may span several codepoints, so only the single-codepoint
    /// ones are exposed. An unpaced whole-line payload is exposed only
    /// when the line itself is a single codepoint.
    private func sendText(_ surface: ghostty_surface_t, _ text: String) {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = Self.unmappedKeycode
        key.unshifted_codepoint = 0
        key.composing = false
        text.withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// Synthesize Ctrl+Space, press then release, which is how a
    /// terminal produces NUL.
    ///
    /// NUL survives neither bulk path. `key.text` is a NUL-terminated C
    /// string, so it truncates there; `ghostty_surface_text` replaces
    /// NUL with a space before it ever reaches the PTY, because
    /// libghostty copies xterm's strip set and applies it "regardless of
    /// bracketed paste mode" (`src/input/paste.zig`). The keystroke is
    /// the route that remains: `ctrlSeq` maps `' '` to 0 when ctrl is
    /// the only modifier (`src/input/key_encode.zig`).
    ///
    /// That mapping lives in the **legacy** encoder. Under the Kitty
    /// keyboard protocol the chord produces a CSI-u event rather than
    /// byte 0x00, matching a physical Ctrl+Space and so honoring the
    /// "as if typed" contract this method implements. Callers wanting a
    /// literal byte regardless of the client's mode have no path here,
    /// by design.
    ///
    /// Emit the complete chord (ctrl down, space down, space up, ctrl
    /// up) because `report_all` includes modifier events. A bare
    /// trailing ctrl release would hand such a client a key it never
    /// saw pressed.
    ///
    /// This is reachable input, not a hypothetical:
    /// `CLICommands.decodeEscapes` accepts both `\0` and `\x00`.
    private func sendNul(_ surface: ghostty_surface_t) {
        var key = ghostty_input_key_s()
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false

        // Ctrl down. `mods` reports the state *after* this event, which
        // is what a real flagsChanged carries.
        key.keycode = Self.controlLeftKeycode
        key.mods = GHOSTTY_MODS_CTRL
        key.unshifted_codepoint = 0
        key.text = nil
        key.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, key)

        // Space down and up, with ctrl held. This is the pair `ctrlSeq`
        // turns into the NUL byte.
        key.keycode = Self.unmappedKeycode
        key.unshifted_codepoint = 0x20
        " ".withCString { ptr in
            key.text = ptr
            key.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(surface, key)
            key.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, key)
        }

        // Ctrl up, returning modifier state to none. libghostty tracks
        // that state from every event's `mods` (`Surface.keyCallback`
        // compares it against `self.mouse.mods` and updates), and it
        // drives mouse selection, link hovering, and mouse reporting.
        //
        // Use the real control keycode, not `unmappedKeycode`.
        // `keyCallback` consumes a release whose `bindingHash` matches
        // the stored `last_trigger`, and that hash covers key, unshifted
        // codepoint, and mods but not utf8 (`input/key.zig`), so a paced
        // character that fired a `.unicode` binding stores
        // `hash(.unidentified, 0, none)`. An `.unidentified` release
        // collides with it and is dropped before `modsChanged` runs.
        //
        // Release after every NUL rather than only a trailing one, so
        // the behavior is position-independent.
        key.text = nil
        key.mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 0
        key.keycode = Self.controlLeftKeycode
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

    /// Synthesize a Return keypress, press then release.
    ///
    /// Field handling follows stock Ghostty's key path (`keyAction` /
    /// `ghosttyKeyEvent`, `macos/Sources/Ghostty/Surface
    /// View/SurfaceView_AppKit.swift`). `0x24` is `kVK_Return`, which
    /// libghostty maps to `.enter` (`Ghostty.Input.Key.keyCode`), and
    /// `text` stays nil so its KeyEncoder synthesizes the control byte
    /// from the keycode. Stock applies the same rule from the other
    /// direction, setting `key.text` only for codepoints >= 0x20, which
    /// keeps a pre-cooked byte from being encoded twice.
    private func sendReturn(_ surface: ghostty_surface_t) {
        var key = ghostty_input_key_s()
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = 0x24
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false
        key.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, key)
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

    /// The foreground process pid + controlling tty of the surface's PTY,
    /// read from libghostty (`ghostty_surface_foreground_pid` /
    /// `ghostty_surface_tty_name`). Returns nil before the shell has spawned
    /// (pid <= 0) or when libghostty reports no tty (empty string), so the
    /// host retries binding rather than sending an unverifiable anchor. The
    /// tty string is heap-owned by libghostty and freed via
    /// `ghostty_string_free` after copying.
    public func terminalIdentity() -> TerminalIdentity? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0, pid <= UInt64(Int32.max) else { return nil }
        let ttyStruct = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(ttyStruct) }
        guard let ptr = ttyStruct.ptr, ttyStruct.len > 0 else { return nil }
        let buffer = UnsafeBufferPointer(start: ptr, count: Int(ttyStruct.len))
        let tty = buffer.withMemoryRebound(to: UInt8.self) { String(bytes: $0, encoding: .utf8) }
        guard let tty, !tty.isEmpty else { return nil }
        return TerminalIdentity(foregroundPid: Int32(pid), ttyName: tty)
    }

    /// Read the currently-visible viewport as plain text. Constructs
    /// a viewport-spanning `ghostty_selection_s` (top-left → bottom-
    /// right of the active viewport) and hands it to
    /// `ghostty_surface_read_text`. libghostty fills the
    /// `ghostty_text_s` with a heap-owned `ptr` + `len` that we
    /// copy into a Swift `String` and immediately release via
    /// `ghostty_surface_free_text`. Returns the rendered cell
    /// contents with `"\n"` separating rows. Throws
    /// `.notAttached` when the surface isn't installed, or
    /// `.captureFailed` when libghostty refuses the read.
    public func readScreenText() throws -> String {
        guard let surface else { throw TerminalSurfaceError.notAttached }
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )
        var textStruct = ghostty_text_s(
            tl_px_x: 0,
            tl_px_y: 0,
            offset_start: 0,
            offset_len: 0,
            text: nil,
            text_len: 0
        )
        guard ghostty_surface_read_text(surface, selection, &textStruct) else {
            throw TerminalSurfaceError.captureFailed(
                detail: "ghostty_surface_read_text returned false"
            )
        }
        defer { ghostty_surface_free_text(surface, &textStruct) }
        guard let ptr = textStruct.text else { return "" }
        // String(cString:) requires NUL-termination guarantees we
        // can't make about libghostty's buffer; round-trip via Data
        // + String(bytes:encoding:) keeps it byte-accurate.
        let buffer = UnsafeBufferPointer(
            start: ptr,
            count: Int(textStruct.text_len)
        )
        let data = buffer.withMemoryRebound(to: UInt8.self) {
            Data($0)
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: - Clipboard (driven by the runtime's clipboard callbacks)

    /// Fulfil a libghostty clipboard *read* (⌘V / OSC 52 read): pull
    /// the macOS pasteboard string and hand it back through
    /// `ghostty_surface_complete_clipboard_request` with
    /// `confirmed: false`. False is deliberate: it lets libghostty
    /// apply its read/paste policy and call back into
    /// `confirm_read_clipboard_cb` for anything that needs approval
    /// (a program's OSC 52 read, or an unsafe multi-line paste). If we
    /// passed `true` here we'd bypass that gate and let any process in
    /// the shell silently exfiltrate the pasteboard. An empty
    /// pasteboard completes with "" rather than stalling the request.
    func provideClipboard(state: UnsafeMutableRawPointer?) {
        guard let surface else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        text.withCString {
            ghostty_surface_complete_clipboard_request(surface, $0, state, false)
        }
    }

    /// libghostty's confirmation gate for a clipboard read it deemed
    /// unsafe/unauthorized (reached because `provideClipboard`
    /// completes with `confirmed: false`).
    ///
    /// `PASTE` is a user-initiated ⌘V whose content libghostty flagged
    /// (e.g. it spans multiple lines). The user asked for it, so
    /// allow it without a second prompt. Anything else (OSC 52 read
    /// from a program) requires explicit approval; on deny we resolve
    /// the request with an empty string so the program gets nothing.
    func confirmClipboardRead(
        text: String,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE {
            completeClipboardRead(text: text, state: state, confirmed: true)
            return
        }
        let stateBits = UInt(bitPattern: state)
        presentConfirmSheet(
            message: "Allow clipboard read?",
            info: "A program running in this terminal is trying to read "
                + "the system clipboard."
        ) { [weak self] allowed in
            self?.completeClipboardRead(
                text: allowed ? text : "",
                state: UnsafeMutableRawPointer(bitPattern: stateBits),
                confirmed: true
            )
        }
    }

    /// Fulfil a libghostty clipboard *write* (⌘C / OSC 52 write). When
    /// `confirm` is true libghostty's policy requires approval before
    /// the system clipboard is replaced (a program's OSC 52 write
    /// under an "ask" policy); prompt and only write on approval.
    /// `confirm == false` (⌘C, or an "allow" policy) writes directly.
    func writeClipboard(_ text: String, confirm: Bool) {
        guard confirm else {
            writeToPasteboard(text)
            return
        }
        presentConfirmSheet(
            message: "Allow clipboard change?",
            info: "A program running in this terminal is trying to change "
                + "the system clipboard."
        ) { [weak self] allowed in
            if allowed { self?.writeToPasteboard(text) }
        }
    }

    private func completeClipboardRead(
        text: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) {
        guard let surface else { return }
        text.withCString {
            ghostty_surface_complete_clipboard_request(surface, $0, state, confirmed)
        }
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Window-anchored, async confirmation. Async (not `runModal`) so
    /// we never spin a nested runloop inside libghostty's tick: the
    /// callbacks that reach here can fire during `ghostty_app_tick`
    /// (OSC 52), and a re-entrant tick is unsafe. Falls back to an
    /// app-modal alert if the surface has no window yet.
    private func presentConfirmSheet(
        message: String,
        info: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        if let window = surfaceView.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard let surface, cols > 0, rows > 0 else { return }
        // No cell-grid C API; convert through the current cell metrics
        // and set pixels (libghostty re-derives cols/rows from that).
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return }
        let widthPx = UInt32(cols) * size.cell_width_px
        let heightPx = UInt32(rows) * size.cell_height_px
        ghostty_surface_set_size(surface, widthPx, heightPx)
    }

    /// Drive libghostty's `scroll_to_row` binding action. `row` is
    /// 0-based from the top of the scrollback; the engine clamps if
    /// out of range and re-emits SCROLLBAR with the new viewport. We
    /// pass the byte length per Ghostty.app's `perform(action:)`
    /// wrapper convention (the third arg counts UTF-8 bytes,
    /// excluding the trailing NUL).
    public func scroll(toRow row: Int) {
        guard let surface else { return }
        let action = "scroll_to_row:\(row)"
        action.withCString { cstr in
            _ = ghostty_surface_binding_action(
                surface,
                cstr,
                UInt(strlen(cstr))
            )
        }
    }

    /// Trigger libghostty's `copy_to_clipboard` binding action. The
    /// engine handles selection state, OSC 52 policy, and the
    /// runtime's `write_clipboard_cb` (which lands back in
    /// `writeClipboard(_:confirm:)` above). Best-effort: matches
    /// stock Ghostty's menu-handler convention of logging on
    /// failure rather than throwing.
    public func copyToClipboard() {
        performBinding("copy_to_clipboard")
    }

    /// Trigger libghostty's `paste_from_clipboard` binding action.
    /// The engine pulls the pasteboard via `read_clipboard_cb` /
    /// `provideClipboard(state:)` and applies its unsafe-paste
    /// policy (multi-line content may surface a confirm sheet via
    /// `confirmClipboardRead`).
    public func pasteFromClipboard() {
        performBinding("paste_from_clipboard")
    }

    /// Trigger libghostty's `select_all` binding action, which selects
    /// the scrollback and viewport together. Stock Ghostty.app wires its
    /// own Select All menu item to the same action string.
    public func selectAll() {
        performBinding("select_all")
    }

    /// Trigger libghostty's `clear_screen` binding action, which wipes
    /// the visible viewport AND the scrollback history (libghostty
    /// queues `{ .clear_screen = .{ .history = true } }`). Matches
    /// the macOS Terminal.app ⌘K / iTerm2 "Clear Buffer" convention
    /// users expect from a Clear menu item. On the alternate screen
    /// the engine rejects the action and `performBinding` logs it.
    public func clearScreen() {
        performBinding("clear_screen")
    }

    /// Triggers libghostty's `increase_font_size:1` binding. Step
    /// of 1 matches stock Ghostty's default menu wiring; half-
    /// steps and arbitrary deltas are accessible via the binding
    /// system if a user wants finer control.
    public func zoomIn() {
        performBinding("increase_font_size:1")
    }

    /// Triggers libghostty's `decrease_font_size:1` binding.
    public func zoomOut() {
        performBinding("decrease_font_size:1")
    }

    /// Triggers libghostty's `reset_font_size` binding, restoring
    /// the size declared in the loaded Ghostty config (or the
    /// engine default when unset).
    public func resetZoom() {
        performBinding("reset_font_size")
    }

    /// Common wrapper around `ghostty_surface_binding_action` for
    /// no-payload action strings. Matches stock Ghostty.app's
    /// `perform(action:)` convention: pass the UTF-8 byte length
    /// (excluding NUL) and log when the engine rejects the action.
    private func performBinding(_ action: String) {
        guard let surface else { return }
        action.withCString { cstr in
            let ok = ghostty_surface_binding_action(
                surface,
                cstr,
                UInt(strlen(cstr))
            )
            if !ok {
                FileHandle.standardError.write(
                    Data("deviceterm: ghostty action failed: \(action)\n".utf8)
                )
            }
        }
    }

    // Called by the runtime's close_surface_cb (already hopped to
    // main). Fires when the surface should close, including the
    // child process exiting on its own, the reliable exit signal.
    func engineDidRequestClose(processAlive: Bool) {
        guard !didNotifyExit else { return }
        didNotifyExit = true
        // close_surface_cb carries no exit code; nil = "unknown",
        // which the contract documents.
        // DEFERRED: a real exit code needs the
        // GHOSTTY_ACTION_CHILD_EXITED action, which carries one.
        delegate?.terminalSurface(self, didExitWithCode: nil)
    }

    // Called by the runtime's action_cb (on main, during tick) for
    // OSC-driven shell-integration events. Without these the delegate
    // contract is dead (tab title / cwd / bell never fire).
    func engineDidChangeTitle(_ title: String) {
        delegate?.terminalSurface(self, didChangeTitle: title)
    }

    func engineDidChangeWorkingDirectory(_ path: String) {
        delegate?.terminalSurface(self, didChangeWorkingDirectory: path)
    }

    func engineWantsBell() {
        delegate?.terminalSurfaceWantsBell(self)
    }

    /// libghostty's scrollback geometry snapshot, emitted whenever
    /// `total` (history rows) grows, the viewport `offset` moves, or
    /// the visible row `len` changes. The host turns this into the
    /// scrollbar's document size + visible-rect position (the
    /// `SurfaceScrollView` wrapper).
    func engineDidUpdateScrollbar(_ state: ScrollbarState) {
        delegate?.terminalSurface(self, didUpdateScrollbar: state)
    }

    /// OSC 11 (or equivalent) reported a new terminal background
    /// color. The host's scroll wrapper picks the matching scroller
    /// appearance from the luma threshold.
    func engineDidChangeBackgroundColor(_ color: TerminalBackgroundColor) {
        delegate?.terminalSurface(self, didChangeBackgroundColor: color)
    }
}
