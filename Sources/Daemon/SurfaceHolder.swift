// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import IOSurface

/// Who holds a slot. A slot returns to the free list when its holder set
/// empties. At most once per holder: a token never legitimately holds one
/// generation twice, so the set needs no counting.
enum SurfaceHolder: Hashable, Sendable {
    case daemonCurrent
    case subscription(UUID)
}
