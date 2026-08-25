// SPDX-License-Identifier: GPL-3.0-or-later

/// Current linkage-policy version. Increment alongside any change
/// to the on-the-wire linkage semantics so older CLIs can detect
/// they may not understand new pane states or recovery flows.
public enum LinkagePolicy {
    public static let currentVersion = 1
}
