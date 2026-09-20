// SPDX-License-Identifier: GPL-3.0-or-later

/// Which shortcut, if any, a tab's position advertises.
///
/// The strip badges a tab only where the chord genuinely selects it, so the
/// rule has to match `KeybindingCatalog` exactly rather than approximately.
/// ⌘1 through ⌘8 address a position; ⌘9 addresses the end of the strip, which
/// is why it is `selectLastTab` and not "tab 9". Positions after the eighth
/// show no badge unless they are the last tab, which shows ⌘9.
///
/// Badging the last tab is deliberate rather than an off-by-one: ⌘9 genuinely
/// selects it, so leaving it bare would hide a chord that works.
///
/// Pure, so the rule is testable without a window, the way `TabMarkerDecision`
/// and `TabSelectionMath` already are. Positional badges correspond to
/// `TabSelectionMath.index(forMenuTag:tabCount:)` and the last-tab badge to
/// its `lastIndex(tabCount:)`; those and this agree, or a badge names one tab
/// and selects another.
enum TabShortcutDecision {
    /// Positions 1 through 8, in order. The last-tab arm is separate because
    /// it addresses the end rather than a position.
    private static let positional: [KeybindingAction] = [
        .selectTab1, .selectTab2, .selectTab3, .selectTab4,
        .selectTab5, .selectTab6, .selectTab7, .selectTab8
    ]

    /// The action that selects the tab at `index` of `tabCount`, or nil when
    /// no chord reaches it.
    ///
    /// A strip of eight or fewer never reaches the last-tab arm, so its final
    /// tab keeps its own number instead of being relabelled ⌘9.
    static func action(atIndex index: Int, tabCount: Int) -> KeybindingAction? {
        guard index >= 0, index < tabCount else { return nil }
        if index < positional.count {
            return positional[index]
        }
        return index == tabCount - 1 ? .selectLastTab : nil
    }
}
