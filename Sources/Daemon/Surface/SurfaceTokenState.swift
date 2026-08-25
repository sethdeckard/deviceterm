// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import IOSurface

/// Per-token lifecycle. Only `active` admits new grants; acks are honored
/// while `draining`/`orphaned` so outstanding leases can drain.
enum SurfaceTokenState: Sendable {
    case active
    case draining
    case orphaned
    case closed
}
