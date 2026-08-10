// SPDX-License-Identifier: GPL-3.0-or-later
//
// GhosttySurfaceView: the bare NSView libghostty renders into, plus
// the AppKit→libghostty input bridge.
//
// Contract (from Ghostty's own SurfaceView, the canonical embedder):
// hand libghostty a *plain* NSView and never touch its layer.
// libghostty installs and owns a CAMetalLayer and runs its own
// CVDisplayLink. We do NOT set wantsLayer, override draw(), or run a
// display link. We only: forward input, keep it first-responder, and
// push pixel size + content scale on geometry/backing changes.
//
// Sizing is in framebuffer PIXELS, not points. Passing point sizes
// yields a doll-house terminal on Retina. Always convertToBacking.
//
// Keyboard follows the reference's text-vs-key split: keyDown primes
// an accumulator, runs interpretKeyEvents (which drives this view as
// an NSTextInputClient for IME / dead keys), then emits one
// ghostty_surface_key per committed string (or a bare key event for
// non-text keys). International layouts reach the engine through that
// NSTextInputClient path. Media keys are not covered.

import AppKit
import GhosttyKit

@MainActor
final class GhosttySurfaceView: NSView, @MainActor NSTextInputClient {
    private enum MouseButton {
        case left, right, middle
        var cValue: ghostty_input_mouse_button_e {
            switch self {
            case .left:
                return GHOSTTY_MOUSE_LEFT

            case .right:
                return GHOSTTY_MOUSE_RIGHT

            case .middle:
                return GHOSTTY_MOUSE_MIDDLE
            }
        }
    }

    // Set by GhosttyTerminalSurface once ghostty_surface_new returns.
    var surface: ghostty_surface_t?

    // Non-nil only for the duration of a keyDown: interpretKeyEvents
    // re-enters via insertText, which appends here instead of sending
    // text immediately so keyDown can pair it with the key event.
    private var keyTextAccumulator: [String]?

    private var markedTextRange = NSRange(location: NSNotFound, length: 0)
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        // Non-zero initial frame so the Metal layer's bounds are
        // non-zero before the first real layout (avoids a blank flash).
        super.init(
            frame: frameRect.isEmpty
            ? NSRect(x: 0, y: 0, width: 800, height: 480)
            : frameRect
            )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GhosttySurfaceView is not NSCoder-instantiable")
    }

    static func mods(
        from flags: NSEvent.ModifierFlags
    ) -> ghostty_input_mods_e {
        var raw = UInt32(GHOSTTY_MODS_NONE.rawValue)
        if flags.contains(.shift) { raw |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { raw |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { raw |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { raw |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { raw |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
        // Sided modifier bits, matching stock Ghostty.app's
        // `Ghostty.ghosttyMods` (Ghostty.Input.swift). AppKit's
        // ModifierFlags surfaces left/right via the IOKit
        // NX_DEVICER*KEYMASK bits packed in the raw flags value;
        // libghostty consumes the sided info for keybinding state
        // tracking. Both can be set when both sides are held; we
        // pass that through and let libghostty interpret.
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 {
            raw |= UInt32(GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
        }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 {
            raw |= UInt32(GHOSTTY_MODS_CTRL_RIGHT.rawValue)
        }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 {
            raw |= UInt32(GHOSTTY_MODS_ALT_RIGHT.rawValue)
        }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 {
            raw |= UInt32(GHOSTTY_MODS_SUPER_RIGHT.rawValue)
        }
        return ghostty_input_mods_e(raw)
    }

    // Modifiers actually consumed in producing `text`. Per
    // libghostty's contract (and the heuristic stock Ghostty.app
    // has used for years), control and command never contribute to
    // text translation: Ctrl+C produces \x03 only because
    // libghostty re-applies the control modifier on encode, not
    // because AppKit baked it into `event.characters`. Marking
    // those as "unconsumed" tells libghostty's KeyEncoder it still
    // needs to apply them, which is the load-bearing piece for
    // raw-mode TUIs reading Ctrl-letter. Shift / option / capslock
    // DO contribute (they shift the typed character), so we leave
    // them in `consumed_mods`.
    static func consumedMods(
        from flags: NSEvent.ModifierFlags
    ) -> ghostty_input_mods_e {
        Self.mods(from: flags.subtracting([.control, .command]))
    }

    // The unshifted codepoint: `event.characters` with no
    // modifiers applied. libghostty uses this together with
    // `mods` / `consumed_mods` to encode Ctrl-letter sequences
    // correctly (without it, a non-US keyboard layout can land
    // on the wrong byte for, e.g., Ctrl+/). Zero when AppKit
    // doesn't expose an unshifted form (flagsChanged, non-letter
    // function keys).
    static func unshiftedCodepoint(for event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
            let chars = event.characters(byApplyingModifiers: []),
            let first = chars.unicodeScalars.first else { return 0 }
        return first.value
    }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

    // MARK: - Geometry → libghostty (pixels + scale)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }
        let scale = Double(
            window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
            )
        ghostty_surface_set_content_scale(surface, scale, scale)
        pushSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func pushSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds)
        let widthPx = UInt32(max(0, backing.width))
        let heightPx = UInt32(max(0, backing.height))
        guard widthPx > 0, heightPx > 0 else { return }
        ghostty_surface_set_size(surface, widthPx, heightPx)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let accumulated = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        let action: ghostty_input_action_e =
            event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Mirrors stock Ghostty.app's keyDown branch
        // (SurfaceView_AppKit.swift): forward each accumulated
        // commit when interpretKeyEvents routed something through
        // insertText, otherwise fall back to event.characters via
        // `printableText`. The accumulator can also capture raw
        // control bytes (Tab \t, Ctrl-letter on some macOS versions).
        // Those are filtered at the sendKey boundary via
        // `KeyText.shouldForwardText`, so libghostty's KeyEncoder
        // owns control-byte synthesis from keycode + mods +
        // unshifted_codepoint instead of double-encoding atop pre-
        // cooked bytes. This is what makes Tab / Shift+Tab / Ctrl+
        // Enter / raw-mode Ctrl-letter work uniformly.
        if accumulated.isEmpty {
            sendKey(event, action: action, text: printableText(event))
        } else {
            for text in accumulated {
                sendKey(event, action: action, text: text)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
    }

    override func flagsChanged(with event: NSEvent) {
        // Ported verbatim from stock Ghostty.app's
        // SurfaceView_AppKit.flagsChanged. Map the changed keycode
        // to its Ghostty mod bit; if that bit is set in the current
        // mods AND (for sided modifiers) the matching NX_DEVICER*
        // KEYMASK is set, it's a PRESS for *this* side. Releasing
        // the right side while the left is still held leaves the
        // combined .shift / .control / etc. bit set, so a naive
        // `modifierFlags.contains(mask)` check would mis-send PRESS
        // for the released side and leave libghostty's modifier
        // state stuck. The sided check disambiguates.
        let mod: UInt32
        switch event.keyCode {
        case 0x39:
            mod = UInt32(GHOSTTY_MODS_CAPS.rawValue)

        case 0x38, 0x3C:
            mod = UInt32(GHOSTTY_MODS_SHIFT.rawValue)

        case 0x3B, 0x3E:
            mod = UInt32(GHOSTTY_MODS_CTRL.rawValue)

        case 0x3A, 0x3D:
            mod = UInt32(GHOSTTY_MODS_ALT.rawValue)

        case 0x37, 0x36:
            mod = UInt32(GHOSTTY_MODS_SUPER.rawValue)

        default:
            return
        }

        if hasMarkedText() { return }

        let currentMods = Self.mods(from: event.modifierFlags)

        var action: ghostty_input_action_e = GHOSTTY_ACTION_RELEASE
        if currentMods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue
                    & UInt(NX_DEVICERSHIFTKEYMASK) != 0

            case 0x3E:
                sidePressed = event.modifierFlags.rawValue
                    & UInt(NX_DEVICERCTLKEYMASK) != 0

            case 0x3D:
                sidePressed = event.modifierFlags.rawValue
                    & UInt(NX_DEVICERALTKEYMASK) != 0

            case 0x36:
                sidePressed = event.modifierFlags.rawValue
                    & UInt(NX_DEVICERCMDKEYMASK) != 0

            default:
                sidePressed = true
            }
            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        sendKey(event, action: action, text: nil)
    }

    private func sendKey(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        text: String?
    ) {
        guard let surface else { return }
        let mods = Self.mods(from: event.modifierFlags)
        let consumedMods = Self.consumedMods(from: event.modifierFlags)
        let unshiftedCodepoint = Self.unshiftedCodepoint(for: event)
        func emit(_ textPtr: UnsafePointer<CChar>?) {
            var key = ghostty_input_key_s()
            key.action = action
            key.mods = mods
            key.consumed_mods = consumedMods
            key.keycode = UInt32(event.keyCode)
            key.text = textPtr
            key.unshifted_codepoint = unshiftedCodepoint
            key.composing = hasMarkedText()
            _ = ghostty_surface_key(surface, key)
        }
        // Stock Ghostty's keyAction (SurfaceView_AppKit.swift) only
        // sets `key.text` when the leading UTF-8 byte is >= 0x20.
        // Control bytes leak as pre-cooked text without this filter:
        // Tab \t, Shift+Tab \t (same scalar; Shift shouldn't shift
        // Tab), Enter \r, Esc \x1B, Backspace \x08, and any raw
        // Ctrl-letter the accumulator might capture. libghostty's
        // KeyEncoder then re-encodes from keycode + mods on top,
        // losing modifier context (Shift+Tab → \t instead of CSI Z)
        // or double-emitting (Ctrl+Enter → wrong byte). With the
        // filter, libghostty owns control-byte synthesis from
        // keycode + mods + unshifted_codepoint, the canonical path
        // raw-mode TUIs depend on.
        if KeyText.shouldForwardText(text), let text {
            text.withCString { emit($0) }
        } else {
            emit(nil)
        }
    }

    // Resolve `event.characters` into the `text` field for
    // libghostty per `KeyText.disposition(scalar:)`. PUA function
    // keys drop (libghostty synthesizes from keycode); control
    // bytes strip the control modifier and return the unshifted
    // letter so libghostty's KeyEncoder re-applies ctrl, the
    // Ctrl-letter path that raw-mode TUIs depend on. Everything
    // else (printable ASCII, higher Unicode) forwards as-is.
    private func printableText(_ event: NSEvent) -> String? {
        guard let chars = event.characters,
            let first = chars.unicodeScalars.first else { return nil }
        switch KeyText.disposition(scalar: first.value) {
        case .drop:
            return nil

        case .stripControl:
            return event.characters(
                byApplyingModifiers: event.modifierFlags.subtracting(.control)
            )

        case .forward:
            return chars
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { mouseButton(event, .left, true) }
    override func mouseUp(with event: NSEvent) { mouseButton(event, .left, false) }
    override func rightMouseDown(with event: NSEvent) {
        // Forward to libghostty AND call super so AppKit's default
        // right-click flow runs to pop the contextual menu. Matches
        // stock Ghostty's `SurfaceView_AppKit.rightMouseDown` shape.
        // Dropping super here suppresses
        // the contextual menu entirely on the surface view, which
        // hosts the right-click target.
        mouseButton(event, .right, true)
        super.rightMouseDown(with: event)
    }

    /// Promote ourselves to first responder before AppKit reads the
    /// contextual menu. The host (`TerminalPaneViewController`)
    /// installs the menu directly on this view, and its items
    /// dispatch nil-targeted through the responder chain, so the
    /// chain MUST start at this surface (whose enclosing VC owns
    /// the @objc selectors) and not at whatever pane was already
    /// focused. `super.rightMouseDown` alone is not a guaranteed
    /// FR-promotion path (NSView's default impl doesn't make the
    /// hit view first responder), so we do it explicitly here.
    /// Mirrors the existing deviceterm pattern on the sim pane,
    /// `SimulatorContentView.menu(for:)`.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, .right, false) }
    override func otherMouseDown(with event: NSEvent) { mouseButton(event, .middle, true) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, .middle, false) }
    override func mouseDragged(with event: NSEvent) { mousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { mousePos(event) }
    override func mouseMoved(with event: NSEvent) { mousePos(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(from: event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // Match Ghostty.app's canonical SurfaceView: a subjective
            // 2x amplifier on precision (trackpad / Magic Mouse) deltas
            // so deviceterm's scroll feel matches stock Ghostty.app
            // (without it, raw AppKit deltas feel sluggish in a
            // terminal). Mechanical wheel events are not amplified.
            deltaX *= 2
            deltaY *= 2
        }
        // The third argument is a packed Int32, not a modifier-flags
        // value: bit 0 = precision, bits 1-3 = momentum phase. The
        // phase bits are what keep inertial scrolling alive; see
        // `ScrollMods.pack` for the wire layout.
        let mods = ScrollMods.pack(
            precision: precision,
            momentum: ScrollMomentum.from(event.momentumPhase)
        )
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, mods)
    }

    private func mouseButton(
        _ event: NSEvent,
        _ button: MouseButton,
        _ down: Bool
    ) {
        guard let surface else { return }
        mousePos(event)
        _ = ghostty_surface_mouse_button(
            surface,
            down ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE,
            button.cValue,
            Self.mods(from: event.modifierFlags)
        )
    }

    private func mousePos(_ event: NSEvent) {
        guard let surface else { return }
        let local = convert(event.locationInWindow, from: nil)
        // libghostty wants top-left origin; AppKit is bottom-left.
        ghostty_surface_mouse_pos(
            surface,
            local.x,
            bounds.height - local.y,
            Self.mods(from: event.modifierFlags)
        )
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as String:
            text = value

        case let value as NSAttributedString:
            text = value.string

        default:
            return
        }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface {
            text.withCString {
                ghostty_surface_text(surface, $0, UInt(strlen($0)))
            }
        }
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        let text: String
        switch string {
        case let value as String:
            text = value

        case let value as NSAttributedString:
            text = value.string

        default:
            text = ""
        }
        markedTextRange = text.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: text.utf16.count)
        guard let surface else { return }
        text.withCString {
            ghostty_surface_preedit(surface, $0, UInt(strlen($0)))
        }
    }

    func unmarkText() {
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    func hasMarkedText() -> Bool {
        markedTextRange.location != NSNotFound
    }

    func markedRange() -> NSRange { markedTextRange }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let surface else { return .zero }
        var posX = 0.0, posY = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &posX, &posY, &width, &height)
        let local = NSRect(
            x: posX,
            y: bounds.height - posY - height,
            width: width,
            height: height
        )
        let windowRect = convert(local, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    // Swallow command selectors (arrows, delete, etc.); libghostty
    // handles them from the keycode. Not overriding this makes AppKit
    // NSBeep on every such key.
    override func doCommand(by selector: Selector) {}
}
