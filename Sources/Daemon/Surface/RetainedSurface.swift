// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOSurface

/// ARC-style wrapper around a borrowed `IOSurfaceRef`.
///
/// CoreSimulator hands the bridge an `IOSurfaceRef` whose lifetime ends
/// when the callback returns (autorelease semantics). The daemon needs
/// to outlive that scope: surfaces cross actor boundaries on their way
/// to subscribers and ride XPC marshalling into the GUI process. The
/// wrapper takes ownership at construction (`CFRetain` +
/// `IOSurfaceIncrementUseCount`) and releases the corresponding pair
/// in `deinit` so callers can stash the reference safely without
/// risking a dangling ref.
///
/// Two reasons for both CFRetain AND IOSurfaceIncrementUseCount:
///
///   - `CFRetain` keeps the CF object alive. Without it, the
///     autoreleased ref vanishes when its pool drains and any
///     downstream access dereferences freed memory.
///     `IOSurfaceIncrementUseCount` does NOT increment the CF retain
///     count; the two counters serve different purposes.
///   - `IOSurfaceIncrementUseCount` raises the in-use count, a
///     *cooperative recycling signal* pool owners consult before
///     handing a surface back out. It is **not** a write lock: it does
///     not block anyone, including this process's own producer, from
///     `memcpy`-ing new pixels into the buffer while a consumer reads
///     it. So the bump does not, by itself, protect a device-mirror
///     consumer from a coherent-but-wrong-generation frame. That
///     happens-before edge is supplied by the acknowledged leased
///     surface pool (generations + watermark acks + the GPU-completion
///     ownership edge), not by this counter. The bump is retained here
///     as the advisory it is, not as a correctness guarantee.
///
/// Marked `@unchecked Sendable` because `IOSurfaceRef`/`CFTypeRef`
/// don't carry Swift's Sendable annotation. The wrapper's lifecycle is
/// the only thing touching the ref outside of `withRef`; `withRef`
/// hands callers a temporary borrow that doesn't escape.
public final class RetainedSurface: @unchecked Sendable {
    private let ref: IOSurfaceRef

    public init(_ ref: IOSurfaceRef) {
        // CFRetain first so the ref stays alive across the use-count
        // bump (defensive ordering: the two are independent
        // counters, but acquiring memory ownership before signaling
        // "in use" keeps the lifecycle reads-easily).
        let retained = Unmanaged.passRetained(ref).takeUnretainedValue()
        self.ref = retained
        IOSurfaceIncrementUseCount(retained)
    }

    deinit {
        // Tear down in reverse order: signal "no longer in use" then
        // release the CF reference. The use-count decrement must
        // happen while we still hold a strong ref, otherwise an
        // intervening CFRelease could free the object before the
        // kernel sees the decrement.
        IOSurfaceDecrementUseCount(ref)
        Unmanaged.passUnretained(ref).release()
    }

    /// Borrow the underlying ref for the duration of `body`. The ref
    /// must not be stored anywhere that outlives the call: the
    /// retain/use-count pair is held by `self`, and storing a bare
    /// ref past `body`'s return puts the caller at risk of using the
    /// surface after `self` is deinit'd.
    public func withRef<T>(_ body: (IOSurfaceRef) throws -> T) rethrows -> T {
        try body(ref)
    }
}
