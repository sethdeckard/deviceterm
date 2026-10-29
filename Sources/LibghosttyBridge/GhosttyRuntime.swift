// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import GhosttyKit
import TerminalSurface

/// The process-wide libghostty app + event pump.
///
/// libghostty has exactly one global init (`ghostty_init`) and one
/// `ghostty_app_t` per process; surfaces are created against it. This
/// is that process singleton. It also owns the *only* run model
/// libghostty offers on macOS. There is no timer or run-loop hook;
/// libghostty calls `wakeup_cb` (from an arbitrary thread) whenever it
/// needs servicing, and the host must hop to main and call
/// `ghostty_app_tick`. Miss that and the terminal never renders or
/// drains its PTY. The renderer drives its own CVDisplayLink + Metal
/// layer internally, so we never call `ghostty_surface_draw`.
///
/// The C callbacks must be `@convention(c)` and therefore cannot
/// capture. State is recovered through the `userdata` pointers:
/// `runtime_config_s.userdata` → this object (wakeup); the close
/// callback uses the owning GhosttyTerminalSurface's pointer set in
/// `surface_config.userdata`. `passUnretained` is sound because the
/// app/harness holds a strong reference for the object's lifetime
/// (documented invariant; the runtime is a process singleton).
@MainActor
public final class GhosttyRuntime {
    public enum RuntimeError: Error, Equatable {
        case initFailed(
            code:
            Int32
            )
        case appCreationFailed
    }

    private static var instance: GhosttyRuntime?

    // Set immediately after `ghostty_app_new`. nil only during the
    // brief window between `init` and that call (the runtime_config
    // userdata must point at `self` before the app exists).
    private(set) var app: ghostty_app_t?
    private let config: ghostty_config_t

    private init(config: ghostty_config_t) {
        self.config = config
    }

    /// Idempotent process bootstrap. The first call performs
    /// `ghostty_init` + app creation; later calls return the same
    /// instance (`resourcesDirectory` and `loadUserConfig` are
    /// honoured only on the first).
    ///
    /// `resourcesDirectory` must be the resource root, which holds
    /// `terminfo/` and `ghostty/` side by side, so that both
    /// `terminfo/78/xterm-ghostty` and `ghostty/shell-integration`
    /// resolve beneath it. For a release libghostty this is read from
    /// `GHOSTTY_RESOURCES_DIR`, which must be set before
    /// `ghostty_init`; without it shell integration and
    /// `TERM=xterm-ghostty` won't resolve.
    ///
    /// `loadUserConfig: false` skips the user's ghostty config files
    /// entirely: the runtime keeps libghostty's built-in defaults and
    /// reads (and writes) no config on disk.
    public static func bootstrap(
        resourcesDirectory: URL?,
        loadUserConfig: Bool = true
    ) throws -> GhosttyRuntime {
        if let instance { return instance }

        if let resourcesDirectory {
            setenv("GHOSTTY_RESOURCES_DIR", resourcesDirectory.path, 1)
        }

        let code = ghostty_init(0, nil)
        guard code == GHOSTTY_SUCCESS else {
            throw RuntimeError.initFailed(code: code)
        }

        guard let config = ghostty_config_new() else {
            throw RuntimeError.appCreationFailed
        }
        // Honour ~/.config/ghostty/config so the user's font/theme is
        // picked up automatically (PHILOSOPHY: config minimal/optional).
        // The opt-out keeps built-in defaults and also skips ghostty's
        // template-config write when no config file exists.
        if loadUserConfig {
            ghostty_config_load_default_files(config)
        }
        ghostty_config_finalize(config)

        let runtime = GhosttyRuntime(config: config)
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(runtime).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeup,
            action_cb: ghosttyAction,
            read_clipboard_cb: ghosttyReadClipboard,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboard,
            write_clipboard_cb: ghosttyWriteClipboard,
            close_surface_cb: ghosttyCloseSurface
        )
        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw RuntimeError.appCreationFailed
        }
        runtime.app = app
        ghostty_app_set_focus(app, true)

        instance = runtime
        return runtime
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }
}

// MARK: - C callback trampolines (non-capturing, any-thread safe)

// wakeup fires from an arbitrary thread; the only safe action is to
// hop to main and tick. Recover the raw pointer (Sendable) inside the
// closure rather than passing the @MainActor object across.
private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    // Recover the (@MainActor, therefore Sendable) object here, in
    // the nonisolated callback, which is just a pointer cast. Capture
    // the object, not the raw pointer, across the main hop.
    let runtime = Unmanaged<GhosttyRuntime>
        .fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { runtime.tick() }
    }
}

// We own panes/tabs/splits ourselves, so most actions are "not
// handled" → false. The exceptions are the OSC-driven shell signals
// the TerminalSurfaceDelegate exposes: title (OSC 0/2), working
// directory (OSC 7), bell, plus SCROLLBAR, which is not
// OSC-driven but follows the same shape (engine asks the host to
// update something it owns; the renderer itself paints no
// scrollbar). action_cb runs on the main thread inside
// ghostty_app_tick, so MainActor.assumeIsolated is sound here
// (unlike wakeup/close which can be off-thread). The payload C
// strings are only valid for the call, so copy before dispatching.
//
// **Invariant: every path that returns false calls
// `reportUnhandledAction` first.** That includes arms that handle an
// action in general but reject a particular payload, such as a null title
// or a non-background color change. Stating it as "every false return"
// rather than "every unhandled tag" is what makes it checkable by reading
// this function, instead of by reasoning about which tags are handled.
private func ghosttyAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    // App-targeted actions never reach the switch below, and libghostty
    // dispatches a whole class of bindings that way, including quit,
    // open_config, reload_config, close_all_windows,
    // toggle_quick_terminal, toggle_visibility, check_for_updates,
    // show_gtk_inspector, undo, and redo (see `App.zig`'s
    // `performAction`). Reporting only from the `default:` arm would let
    // every one of them stay silent, which is precisely the failure this
    // diagnostic exists to catch.
    guard target.tag == GHOSTTY_TARGET_SURFACE,
        let surface = target.target.surface,
        let userdata = ghostty_surface_userdata(surface) else {
        reportUnhandledAction(action)
        return false
    }
    let owner = Unmanaged<GhosttyTerminalSurface>
        .fromOpaque(userdata).takeUnretainedValue()

    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        guard let cstr = action.action.set_title.title else {
            reportUnhandledAction(action)
            return false
        }
        let title = String(cString: cstr)
        MainActor.assumeIsolated { owner.engineDidChangeTitle(title) }
        return true

    case GHOSTTY_ACTION_PWD:
        guard let cstr = action.action.pwd.pwd else {
            reportUnhandledAction(action)
            return false
        }
        let path = String(cString: cstr)
        MainActor.assumeIsolated { owner.engineDidChangeWorkingDirectory(path) }
        return true

    case GHOSTTY_ACTION_RING_BELL:
        MainActor.assumeIsolated { owner.engineWantsBell() }
        return true

    case GHOSTTY_ACTION_SCROLLBAR:
        // The payload is a plain POD struct (three UInt64s); no
        // pointer or C string to outlive the call, so we can read
        // it directly. Copy into our Sendable mirror immediately so
        // the value is independent of the libghostty union storage.
        let payload = action.action.scrollbar
        let state = ScrollbarState(
            total: payload.total,
            offset: payload.offset,
            len: payload.len
        )
        MainActor.assumeIsolated { owner.engineDidUpdateScrollbar(state) }
        return true

    case GHOSTTY_ACTION_COLOR_CHANGE:
        // OSC 10/11/12 sequences flow through this action with the
        // kind discriminating FG / BG / cursor. Only background is
        // load-bearing for the scroll wrapper (scroller appearance
        // follows it); FG / cursor changes return false so libghostty
        // falls back to its own default. We don't suppress them, we
        // just don't have a host-side observer yet. They report like any
        // other false return, so the gap is visible rather than assumed
        // from this comment.
        let payload = action.action.color_change
        guard payload.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else {
            reportUnhandledAction(action)
            return false
        }
        let color = TerminalBackgroundColor(
            red: payload.r,
            green: payload.g,
            blue: payload.b
        )
        MainActor.assumeIsolated {
            owner.engineDidChangeBackgroundColor(color)
        }
        return true

    case GHOSTTY_ACTION_SECURE_INPUT:
        // Termios password detection sends `.on` when a prompt turns echo
        // off and `.off` when it's gone; the surface records it so a
        // terminal waiting at a password prompt stays out of saved
        // scrollback. The `toggle_secure_input` binding's `.toggle` isn't
        // recorded. macOS Secure Keyboard Entry isn't turned on either way,
        // so the action still goes unhandled and reports like any other.
        switch action.action.secure_input {
        case GHOSTTY_SECURE_INPUT_ON:
            MainActor.assumeIsolated { owner.engineDidChangeSecureInput(true) }

        case GHOSTTY_SECURE_INPUT_OFF:
            MainActor.assumeIsolated { owner.engineDidChangeSecureInput(false) }

        default:
            break
        }
        reportUnhandledAction(action)
        return false

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        // The child process is gone. Answering true suppresses the
        // "Process exited. Press any key to close the terminal." line
        // libghostty would otherwise print into the terminal.
        //
        // The host closes the pane, because the engine's two exit arms
        // reach `close()` differently. A fast exit treats the answered
        // action as the whole response and returns without closing. A
        // normal exit only skips the message, and then `wait-after-command`
        // decides; libghostty forces that on for any surface given a
        // command, which every pane here is, so it returns as well.
        // Waiting on `close_surface_cb` would hang the pane open. Were
        // that config to change, the engine would close too, and the
        // surface's exit latch collapses both signals into one exit.
        //
        // The payload carries an exit code, but libghostty's macOS launch
        // path reports 0 however the process died, so it says nothing and
        // is not read. Fast and slow exits are treated alike.
        MainActor.assumeIsolated { owner.engineDidReportChildExit() }
        return true

    default:
        // Everything deviceterm doesn't implement: workspace actions it
        // answers itself (tabs, windows, splits), plus surface and engine
        // events with no host observer here (search, rendering,
        // notifications, mouse state). Returning false is correct;
        // returning it silently is not, because a user binding that fires
        // one then looks broken with no trace.
        reportUnhandledAction(action)
        return false
    }
}

// Note an unhandled action on stderr, once per tag. Called before every
// false return in `ghosttyAction`. Main-actor isolation is sound for the
// same reason the handled arms' is: action_cb runs on the main thread
// inside `ghostty_app_tick`.
//
// Takes the whole action, not just its tag, for the two cases below.
// `GhosttyActionDisposition` classifies nothing, because a tag alone
// cannot settle an action's origin. These two are different in kind:
// libghostty states the origin in the payload, so reading it is a fact
// rather than a guess. Each union member is read only under its own tag,
// which is what keeps the read valid.
private func reportUnhandledAction(_ action: ghostty_action_s) {
    switch action.tag {
    case GHOSTTY_ACTION_RELOAD_CONFIG:
        // Two producers: the user's `reload_config` binding, and the
        // engine's own reload after a color-scheme flip, which `App.zig`
        // and `Surface.zig` both emit as `.{ .soft = true }`.
        if action.action.reload_config.soft { return }

    case GHOSTTY_ACTION_SECURE_INPUT:
        // Two producers as well: `toggle_secure_input` sends `.toggle`,
        // while termios password detection sends `.on` / `.off`, so
        // typing `sudo` raises this with no shortcut involved.
        if action.action.secure_input != GHOSTTY_SECURE_INPUT_TOGGLE { return }

    default:
        break
    }
    MainActor.assumeIsolated {
        guard let message = GhosttyActionDisposition.unhandledMessage(
            for: action.tag.rawValue
        ) else { return }
        FileHandle.standardError.write(Data(message.utf8))
    }
}

// Clipboard read/write are surface-scoped: libghostty passes the
// *surface* userdata (the GhosttyTerminalSurface owner set in
// surface_config.userdata), not the app userdata. Both fire on the
// main thread (⌘V/⌘C are processed inside a main-thread key event;
// OSC 52 during the main-thread tick), so MainActor.assumeIsolated
// is sound, the same contract as ghosttyAction.

private func ghosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mimeCount: Int,
    _ list: Bool
) -> ghostty_clipboard_read_result_e {
    // Only the standard pasteboard: there's no X11-style selection
    // clipboard on macOS (supports_selection_clipboard is false).
    guard let userdata, location == GHOSTTY_CLIPBOARD_STANDARD else {
        return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }
    let owner = Unmanaged<GhosttyTerminalSurface>
        .fromOpaque(userdata).takeUnretainedValue()
    // The MIME strings are only valid for the call, so copy them now.
    // libghostty has already folded text aliases into "text/plain".
    var requested: [String] = []
    if let mimes {
        for index in 0..<mimeCount {
            if let mime = mimes[index] { requested.append(String(cString: mime)) }
        }
    }
    // `state` is a non-Sendable raw pointer; pass it through the
    // (synchronous) main-actor closure as a bit pattern to satisfy
    // strict concurrency without changing the value.
    let stateBits = UInt(bitPattern: state)
    return MainActor.assumeIsolated {
        owner.provideClipboard(
            mimes: requested,
            list: list,
            state: UnsafeMutableRawPointer(bitPattern: stateBits)
        )
    }
}

// libghostty's confirmation gate, invoked when a request needs user
// approval: a program's OSC 52 or Kitty clipboard read, a Kitty
// clipboard write (whose contents arrive here, and reach the write
// callback only once approved), or an unsafe paste. Without handling
// this, such requests would silently stall.
private func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata else { return }
    let owner = Unmanaged<GhosttyTerminalSurface>
        .fromOpaque(userdata).takeUnretainedValue()
    // Copy the borrowed C representations: the prompt is asynchronous.
    // Approval completes with the captured payload without rereading the
    // pasteboard.
    var contents: [GhosttyTerminalSurface.ClipboardRepresentation] = []
    var available: [String] = []
    if let payload = confirm?.pointee {
        if let entries = payload.contents {
            for index in 0..<payload.contents_len {
                let entry = entries[index]
                guard let mime = entry.mime else { continue }
                let data = entry.len > 0 && entry.data != nil
                    ? Data(bytes: entry.data, count: entry.len)
                    : Data()
                contents.append(.init(mime: String(cString: mime), data: data))
            }
        }
        if let mimes = payload.available {
            for index in 0..<payload.available_len {
                if let mime = mimes[index] { available.append(String(cString: mime)) }
            }
        }
    }
    let stateBits = UInt(bitPattern: state)
    let hasPayload = confirm != nil
    MainActor.assumeIsolated {
        owner.confirmClipboardRequest(
            hasPayload
                ? GhosttyTerminalSurface.ClipboardPayload(contents: contents, available: available)
                : nil,
            state: UnsafeMutableRawPointer(bitPattern: stateBits),
            request: request
        )
    }
}

private func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard let userdata, location == GHOSTTY_CLIPBOARD_STANDARD,
        let content, count > 0 else { return }
    // Only a text/plain entry is written: this pasteboard holds text, and a
    // Kitty clipboard write can carry other types (an image), whose bytes
    // would land on the pasteboard as garbage text. The data is
    // length-delimited and not necessarily NUL-terminated, so exactly `len`
    // bytes are decoded, copied because they're only valid for the call.
    // Text that isn't valid UTF-8 writes nothing.
    var picked: String?
    for index in 0..<count {
        let entry = content[index]
        guard let mimePtr = entry.mime,
            String(cString: mimePtr).hasPrefix("text/plain") else { continue }
        guard let dataPtr = entry.data else {
            picked = ""
            break
        }
        picked = String(bytes: UnsafeRawBufferPointer(start: dataPtr, count: entry.len), encoding: .utf8)
        break
    }
    guard let text = picked else { return }
    let owner = Unmanaged<GhosttyTerminalSurface>
        .fromOpaque(userdata).takeUnretainedValue()
    // `confirm` reflects libghostty's clipboard-write policy: when
    // true the write needs user approval (don't silently overwrite).
    MainActor.assumeIsolated { owner.writeClipboard(text, confirm: confirm) }
}

// Fires when the surface should close, including when the child
// process exits on its own (the reliable child-exit signal). The
// userdata is the surface's, set in ghostty_surface_config_s.
private func ghosttyCloseSurface(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let userdata else { return }
    let owner = Unmanaged<GhosttyTerminalSurface>
        .fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            owner.engineDidRequestClose(processAlive: processAlive)
        }
    }
}
