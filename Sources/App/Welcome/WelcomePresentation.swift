// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// How a welcome came to be on screen.
///
/// The two are not interchangeable. A first-run presentation gates the
/// app's first window, so its button continues into the app and the
/// screen says where to find this again. An explicit presentation, from
/// the Help menu or the advisory's Learn More… button, does neither: it
/// carries no completion, so it must not hold the launch sequence even
/// when it happens with every window closed.
enum WelcomePresentation: Equatable {
    case firstRun
    case reopened
}
