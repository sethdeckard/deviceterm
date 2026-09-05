// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Turns heading text into the anchor slug a markdown renderer would give
/// it, so an in-document link written for GitHub keeps working once the
/// document is split across pages.
///
/// This has to match what `docs/USAGE.md` already links against, because
/// those links were written by hand against GitHub's rendering:
/// `[Coexist With Device Hub](#coexist-with-device-hub)`. The rule is
/// lowercase, drop everything that isn't a letter, digit, space, or
/// hyphen, then spaces to hyphens. It is why `Coexist With Simulator.app`
/// anchors as `coexist-with-simulatorapp`, the period vanishing rather
/// than becoming a hyphen.
enum Slug {
    static func make(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "-" {
                out.append(character)
            } else if character == " " {
                out.append("-")
            }
        }
        return out
    }
}
