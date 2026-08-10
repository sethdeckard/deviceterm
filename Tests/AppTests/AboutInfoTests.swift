// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

@Suite
struct AboutInfoTests {
    @Test
    func resolvesAllFieldsFromPlist() {
        let info = AboutInfo.resolve(info: [
            "CFBundleName": "DeviceTerm",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "0.1.0",
            "DTSourceCommit": "abc1234",
            "NSHumanReadableCopyright": "© 2026 Seth Deckard"
        ])
        #expect(info.name == "DeviceTerm")
        #expect(info.version == "0.1.0")
        #expect(info.build == "0.1.0")
        #expect(info.commit == "abc1234")
        #expect(info.tagline == AboutInfo.defaultTagline)
        #expect(info.copyright == "© 2026 Seth Deckard")
    }

    @Test
    func missingKeysFallBackAndHideCommit() {
        // Raw `swift run`: no Info.plist keys at all.
        let info = AboutInfo.resolve(info: [:])
        #expect(info.name == "DeviceTerm")
        #expect(info.version == "—")
        #expect(info.build == "—")
        #expect(info.commit == nil)
        // No bundle means no NSHumanReadableCopyright, so the fallback is
        // what the About window's GPL notice has to display.
        #expect(info.copyright == AboutInfo.defaultCopyright)
    }

    @Test
    func unknownCommitFallbackIsTreatedAsAbsent() {
        // The bundle script writes "unknown" when git isn't available.
        let info = AboutInfo.resolve(info: ["DTSourceCommit": "unknown"])
        #expect(info.commit == nil)
    }

    @Test
    func emptyStringsAreTreatedAsAbsent() {
        let info = AboutInfo.resolve(info: [
            "CFBundleName": "",
            "CFBundleShortVersionString": "",
            "DTSourceCommit": "",
            "NSHumanReadableCopyright": ""
        ])
        #expect(info.name == "DeviceTerm")
        #expect(info.version == "—")
        #expect(info.commit == nil)
        #expect(info.copyright == AboutInfo.defaultCopyright)
    }
}
