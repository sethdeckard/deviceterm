// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabAccessibilityIdentity: the accessibility identifiers the tab strip's
// controls carry.
//
// A pill's title is a resolved display title, taken from a precedence chain
// (manual rename, then OSC title, session name, cwd basename, finally
// "shell"), so several tabs routinely resolve to the same string and a title
// names no particular tab. The identifier is what names one: without it a
// consumer reading an accessibility dump can count pills but cannot say which
// pill it selected, and cannot address one to drive it.
//
// Keyed on the daemon-minted `shortId` because that is what `tabs list --json`
// reports and what `--tab <ref>` resolves first, so a single identifier joins
// an accessibility view of the strip to the CLI's. The field is optional only
// for compatibility with a pre-identifier-model daemon response; when it is
// absent the control carries no identifier rather than a second identifier
// format, since one shape is what lets a consumer compare whole strings.
//
// This names a tab's CURRENT primary session, not the tab itself: closing the
// first terminal of a split tab promotes the second, and the identifier
// follows. That is what keeps it agreeing with `tabs list --json`, and it is
// why it is a join key rather than a durable handle.
//
// The strings are an observability contract with those consumers, not
// user-visible text, so their shape stays machine-readable and fixed even as
// the session a control names changes underneath it. Human-facing
// labels are separate and deliberately so: the "+" reads "New Tab" to
// assistive technology, which is also the exact title of the New Tab menu
// item, so an element search by label matches two real things. The identifier
// is what distinguishes them.

enum TabAccessibilityIdentity {
    /// Shared prefix for the named tab-strip controls, so a consumer can
    /// collect them from a dump without matching on roles.
    static let prefix = "deviceterm.tab"

    /// The "+" affordance. Not keyed on a tab, because it belongs to the
    /// strip rather than to any one tab.
    static let newTabButton = "\(prefix).new"

    /// The identifier for one tab's pill.
    static func identifier(forTab shortId: String) -> String {
        "\(prefix).\(shortId)"
    }

    /// The identifier for one tab's close button. Suffixed rather than given
    /// its own prefix so a consumer filtering the tab prefix finds the pill
    /// and its closer together.
    ///
    /// The suffix cannot be read as some other tab's pill because a short id
    /// is a fixed six characters, so no id equals `<id>.close`.
    static func closeIdentifier(forTab shortId: String) -> String {
        "\(prefix).\(shortId).close"
    }
}
