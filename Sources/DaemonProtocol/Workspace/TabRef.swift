// SPDX-License-Identifier: GPL-3.0-or-later

/// Tagged `--tab <ref>` value.
///
/// The user-typed `<ref>` string is interpreted as the most specific
/// thing it can be: short_id first, then name, then UUID prefix, then
/// a reserved sentinel keyword. The resolver
/// (`TabRefResolver.resolve(_:in:)`) walks this order against a
/// `[TabsListEntry]` snapshot and returns the matching session.
///
/// Reserved sentinels (`current` and `all`) have the LOWEST priority,
/// not the highest, so a tab named `current` would match by name before
/// the sentinel fires. The trade-off is that a user can shadow a
/// sentinel with a literal name, which is rare and self-inflicted.
/// CLI commands that don't accept sentinels can ignore the
/// `.sentinel` case.
public enum TabRef: Equatable, Sendable {
    case shortId(String)
    case name(String)
    case uuidPrefix(String)
    case sentinel(Sentinel)

    /// Reserved keywords. `current` resolves to the caller's own tab
    /// (the tab whose `DEVICETERM_SESSION` is in the CLI's env); `all`
    /// resolves to every visible tab. Lowest-priority match.
    public enum Sentinel: String, Equatable, Sendable, CaseIterable {
        case current
        case all
    }
}
