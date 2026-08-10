// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeyModsTests: pin GhosttySurfaceView's `mods(from:)` and
// `consumedMods(from:)` translation to stock Ghostty.app's
// `Ghostty.ghosttyMods` (Ghostty.Input.swift) row-by-row.
//
// Why pin per-row rather than spot-check: a silent divergence from
// upstream on a single shape drops one TUI keystroke and shows no
// other symptom. Arrow keys, Ctrl-letter, and Shift+Tab each broke
// that way. The bridge matches stock Ghostty's NSEvent translation
// verbatim and this matrix is what holds it there, so a libghostty
// bump that changes a mod-bit layout trips here rather than in a
// user-reported TUI symptom.
//
// Sided-modifier coverage is exercised via raw bit construction.
// AppKit's `NSEvent.ModifierFlags(rawValue:)` preserves the IOKit
// NX_DEVICER*KEYMASK bits packed in the same raw value, so a
// fabricated flags value lets us test the sided detection without
// driving real hardware events. Stock Ghostty does this same check
// (`rawFlags & UInt(NX_DEVICER...)`) so the parity is exact.

import AppKit
import GhosttyKit
@testable import LibghosttyBridge
import Testing

@MainActor
struct KeyModsTests {
    // MARK: - Base modifier bits

    @Test
    func emptyFlagsProduceNoMods() {
        let mods = GhosttySurfaceView.mods(from: [])
        #expect(mods.rawValue == GHOSTTY_MODS_NONE.rawValue)
    }

    @Test(
        "base flag → mod bit",
        arguments: [
        (NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT),
        (NSEvent.ModifierFlags.control, GHOSTTY_MODS_CTRL),
        (NSEvent.ModifierFlags.option, GHOSTTY_MODS_ALT),
        (NSEvent.ModifierFlags.command, GHOSTTY_MODS_SUPER),
        (NSEvent.ModifierFlags.capsLock, GHOSTTY_MODS_CAPS)
        ]
        )
    func baseFlagMapsToGhosttyBit(
        flag: NSEvent.ModifierFlags,
        expected: ghostty_input_mods_e
    ) {
        let mods = GhosttySurfaceView.mods(from: flag)
        #expect(mods.rawValue & expected.rawValue != 0)
    }

    @Test
    func combinedFlagsProduceCombinedBits() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = GhosttySurfaceView.mods(from: flags)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    // MARK: - Sided modifiers (Divergence 1)

    @Test(
        "NX_DEVICER*KEYMASK → sided bit",
        arguments: [
        (UInt(NX_DEVICERSHIFTKEYMASK), NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT_RIGHT),
        (UInt(NX_DEVICERCTLKEYMASK), NSEvent.ModifierFlags.control, GHOSTTY_MODS_CTRL_RIGHT),
        (UInt(NX_DEVICERALTKEYMASK), NSEvent.ModifierFlags.option, GHOSTTY_MODS_ALT_RIGHT),
        (UInt(NX_DEVICERCMDKEYMASK), NSEvent.ModifierFlags.command, GHOSTTY_MODS_SUPER_RIGHT)
        ]
        )
    func sidedRawBitMapsToSidedGhosttyBit(
        rightMask: UInt,
        baseFlag: NSEvent.ModifierFlags,
        expectedSided: ghostty_input_mods_e
    ) {
        // Fabricate a raw flags value with the right-side bit set
        // AND the base flag set (the IOKit signal accompanies the
        // Cocoa bit, never replaces it).
        let raw = baseFlag.rawValue | rightMask
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        let mods = GhosttySurfaceView.mods(from: flags)
        #expect(mods.rawValue & expectedSided.rawValue != 0)
    }

    @Test
    func leftSideAloneDoesNotSetSidedBits() {
        // Plain Cocoa flag without NX_DEVICER*KEYMASK must NOT
        // claim a right-side press. Default to left.
        let mods = GhosttySurfaceView.mods(from: [.shift])
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue == 0)
    }

    @Test
    func bothSidesHeldSetsRightSidedBit() {
        // When both physical Shifts are held, AppKit sets the
        // NX_DEVICER*KEYMASK bit (right is detected); upstream notes
        // the structure can't distinguish "both held" from "right
        // only" and that's fine. Our helper passes the right-side
        // bit through.
        let raw = NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        let mods = GhosttySurfaceView.mods(from: flags)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue != 0)
    }

    // MARK: - consumedMods (Ctrl-letter / Cmd-letter contract)

    @Test
    func consumedModsStripsControl() {
        // Control is never consumed by text translation. Stripping
        // it from consumed_mods is what lets libghostty's KeyEncoder
        // re-apply CTRL on encode, which is the load-bearing piece
        // for raw-mode TUIs reading Ctrl-letter.
        let consumed = GhosttySurfaceView.consumedMods(from: [.control])
        #expect(consumed.rawValue & GHOSTTY_MODS_CTRL.rawValue == 0)
    }

    @Test
    func consumedModsStripsCommand() {
        // Command is also never consumed by text translation, which
        // matches stock Ghostty's "heuristic that has worked for
        // years" (NSEvent+Extension.swift line 27).
        let consumed = GhosttySurfaceView.consumedMods(from: [.command])
        #expect(consumed.rawValue & GHOSTTY_MODS_SUPER.rawValue == 0)
    }

    @Test
    func consumedModsPreservesShiftOptionCaps() {
        // Shift / option / caps DO contribute to the typed
        // character (shift capitalizes, option dead-keys, caps
        // lockmaps) so they belong in consumed_mods.
        let consumed = GhosttySurfaceView.consumedMods(
            from: [.shift, .option, .capsLock]
        )
        #expect(consumed.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(consumed.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(consumed.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0)
    }

    @Test
    func consumedModsForShiftPlusControlKeepsShiftOnly() {
        // Shift+Ctrl+letter (e.g. Ctrl+Shift+C in vim): consumed is
        // SHIFT only; libghostty re-applies CTRL. Matches the
        // Ctrl-letter contract that lets TUIs see the correct byte.
        let consumed = GhosttySurfaceView.consumedMods(
            from: [.shift, .control]
        )
        #expect(consumed.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(consumed.rawValue & GHOSTTY_MODS_CTRL.rawValue == 0)
    }
}
