// SPDX-License-Identifier: GPL-3.0-or-later

/// Help topics for the device roster and attachment verbs.
///
/// This is a behavior-grouping extension, not a conformance split.
extension HelpCatalog {
    static let deviceTopics: [HelpTopic] = [
        HelpTopic(
            "devices",
            .command(.devices),
            summary: "The live roster of owned booted sims and connected devices",
            detail: """
              devices list
                  The aggregate live roster: owned booted sims + connected
                  physical devices, each annotated with its attach/ownership
                  state.
                  Columns: <id>  <kind>  <name>  <model>  <os>  <state>
                           <attachment>  (model/os are physical-device only)
                  Example: deviceterm devices list
            """
        ),
        HelpTopic(
            "device",
            .command(.devices),
            summary: "Claim a sim or mirror a connected device into this tab",
            detail: """
              device attach <ref>
                  The unified explicit-attach verb. <ref> resolves against
                  `devices list` (sim UDID, physical deviceId, or name) to
                  claim a booted/orphan sim or mirror a connected physical
                  device into the caller's tab. A bare UDID not in the roster
                  is claimed as an externally-booted sim. This is the only
                  explicit-attach verb; there is no `pane attach`.
                  Example: deviceterm device attach iPhone-17-Pro
            """
        ),
        HelpTopic(
            "panes",
            .command(.devices),
            summary: "List the device panes in your tab",
            detail: """
              panes list
                  List the calling tab's device panes.
                  Columns: <paneId>  <udid>  <state>  <family>  <type>
            """
        )
    ]
}
