// SPDX-License-Identifier: GPL-3.0-or-later

/// Tagged `--pane <ref>` value. Consumed by `pane info` /
/// `pane close` / `pane rename` CLI surfaces.
///
/// Mirrors `TabRef` for symmetry; same priority order
/// (short_id → name → UUID prefix → sentinel) so an agent that
/// learned the tab grammar doesn't have to re-learn for panes.
public enum PaneRef: Equatable, Sendable {
    case shortId(String)
    case name(String)
    case uuidPrefix(String)
    case sentinel(Sentinel)

    /// Reserved keywords matched after ordinary reference tiers. CLI target
    /// resolution treats `default` and `all` as unsupported sentinels;
    /// omitting `--pane` selects the tab's sole device pane.
    public enum Sentinel: String, Equatable, Sendable, CaseIterable {
        case `default`
        case all
    }
}
