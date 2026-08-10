// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Testing

// ConfigKeySpec drives the self-documenting config writer, and
// DeviceTermConfigDefaults.values is derived from the specs. Pin the
// rendering shape and the specs↔values consistency so a new key can't
// land with a default in one place and a doc in another.

@Test
func documentationLinesRenderSummaryAndAllowed() {
    let spec = ConfigKeySpec(
        key: "demo-key",
        defaultValue: "a",
        allowedValues: ["a", "b", "c"],
        summary: "Does a demo thing."
    )
    #expect(spec.documentationLines == [
        "# Does a demo thing.",
        "# Allowed: a, b, c. Default: a."
    ])
    #expect(spec.exampleLine == "# demo-key = a")
}

@Test
func documentationLinesDescribeAbsentBehaviorInsteadOfDefault() {
    // A key whose default is only the choice a present key selects
    // documents what absence does; a "Default:" line would wrongly
    // imply the value applies while the key is unset.
    let spec = ConfigKeySpec(
        key: "demo-key",
        defaultValue: "a",
        allowedValues: ["a", "b"],
        summary: "Does a demo thing.",
        absentBehavior: "the demo prompt is shown"
    )
    #expect(spec.documentationLines == [
        "# Does a demo thing.",
        "# Allowed: a, b. Unset: the demo prompt is shown."
    ])
}

@Test
func valuesAreDerivedFromSpecs() {
    let fromSpecs = Dictionary(
        uniqueKeysWithValues: DeviceTermConfigDefaults.specs.map { ($0.key, $0.defaultValue) }
    )
    #expect(DeviceTermConfigDefaults.values == fromSpecs)
}

@Test
func specLookupMatchesKnownKeys() {
    for spec in DeviceTermConfigDefaults.specs {
        #expect(DeviceTermConfigDefaults.isKnown(spec.key))
        #expect(DeviceTermConfigDefaults.spec(for: spec.key) == spec)
    }
    #expect(DeviceTermConfigDefaults.spec(for: "no-such-key") == nil)
}
