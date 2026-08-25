// SPDX-License-Identifier: GPL-3.0-or-later

/// Public release version shared by bundled clients.
public enum DeviceTermVersion {
    /// The single source of truth for the release version.
    /// `scripts/lib/version.sh` parses this declaration textually, so
    /// keep the `public static let current = "X.Y.Z"` shape.
    public static let current = "0.4.0"
}
