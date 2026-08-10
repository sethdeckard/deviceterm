// SPDX-License-Identifier: GPL-3.0-or-later
//
// RetainedXPCObject: Sendable carrier for an `xpc_object_t`.
//
// XPC objects (in particular the `xpc_object_t` returned by
// `IOSurfaceCreateXPCObject` for a surface marshalled across the
// daemon→GUI boundary) are reference-counted libxpc handles. Swift's
// `XPC` module imports `xpc_object_t` without Sendable annotations,
// so passing one through an actor boundary requires an explicit
// opt-in wrapper. The wrapper holds the object for the carrier's
// lifetime; libxpc handles release on the wrapper's deinit.
//
// Use this when an xpc payload needs to ride from the surface
// callback through a registry slot to the actor that owns the send
// side of the XPC connection.

import Foundation
@preconcurrency import XPC

public final class RetainedXPCObject: @unchecked Sendable {
    public let object: xpc_object_t

    public init(_ object: xpc_object_t) {
        self.object = object
    }
}
