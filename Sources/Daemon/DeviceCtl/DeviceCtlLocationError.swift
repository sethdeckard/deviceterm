// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

enum DeviceCtlLocationError: Error, Equatable {
    /// A non-zero exit not classified as `unknownScenario`. Carries
    /// devicectl's own stderr when it wrote any. A spawn failure arrives
    /// here too, as status `-1` with the launch error as the message, so
    /// there is no separate launch case.
    case commandFailed(status: Int32, message: String)
    /// devicectl rejected the scenario name. Split out from
    /// `commandFailed` because it is the one location failure the *caller*
    /// can fix, so it reaches the wire as `invalidParams` rather than a
    /// generic server error, matching how the simulator backend answers
    /// the same mistake.
    case unknownScenario(name: String)
    /// Exit 0 but no readable `--json-output` payload.
    case missingOutput
    /// Exit 0 with a payload that isn't the expected shape.
    case malformedOutput
    /// The route file couldn't be written, so `devicectl` was never run.
    /// A full or unwritable temp directory is the realistic cause.
    case routeFileUnwritable(message: String)
}
