// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimAccessibility: iOS-side accessibility tree via AXPTranslator.
//
// Apple's `AccessibilityPlatformTranslation` framework brokers
// accessibility-tree requests between a macOS process and the iOS-side
// AX server running inside a booted simulator. The bridge plumbs:
//
//   1. `dlopen` of `AccessibilityPlatformTranslation.framework`
//      (lazy-loaded once per process via
//      `CoreSimulatorLoader.loadAccessibilityPlatformTranslation()`).
//   2. A shared `AXPTranslationTokenDelegateHelper` that AXP calls
//      back into for every translation request. **The delegate is
//      a process-wide singleton that multiplexes by token**, as the
//      multi-tenant note below explains.
//   3. Per-client tokens that AXP stamps onto every returned
//      translation so the singleton delegate can resolve back to the
//      right `SimDevice` for the sync-over-async request round-trip.
//   4. Recursive walks via `AXPMacPlatformElement.accessibilityChildren`
//      (with the token re-stamped onto each child) to serialize whole
//      trees into Foundation dictionaries.
//
// **Multi-tenant delegate.** Assigning
// `translator.bridgeTokenDelegate = client.delegate` per client is the
// obvious shape, and it silently breaks with more than one
// client. `AXPTranslator
// .sharedInstance` is a singleton, so setting its
// `bridgeTokenDelegate` ivar replaces the global slot: a second
// `SimAccessibility` client clobbers the first client's delegate and
// AXP calls back into the second client's `SimDevice` regardless of
// which token was passed. Instead one shared
// `CSBAccessibilityDelegate` holds a `(token → SimDevice)` dictionary
// and resolves the right device per callback, and the translator's
// `bridgeTokenDelegate` is set once (idempotently) to that shared
// instance.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// NSError domain for every error thrown by `SimAccessibility`. Daemon
/// consumers compare against `(error as NSError).domain` to confirm
/// the error originated in this bridge before reading a specific
/// `code`.
extern NSString * const SimAccessibilityErrorDomain;

/// Subset of `SimAccessibility`'s error codes that the daemon
/// distinguishes by behavior. The full enum lives in
/// `SimAccessibility.m`; only the codes pinned here are part of the
/// daemon-facing contract.
typedef NS_ENUM(NSInteger, SimAccessibilityErrorCode) {
    /// `elementAtPoint:` returned no element. This is a routine
    /// per-cell outcome inside a `pane.ax.sweep` (blank regions on
    /// most screens) and the daemon must NOT treat it as a bridge
    /// failure. Distinct from every other code in this enum so the
    /// sweep can dispatch on it cleanly.
    SimAccessibilityErrorCodeObjectAtPointNil = 78,
};

/// Accessibility client for one simulator. Acquire transiently inside
/// a serializing actor; the underlying `SimDevice` reference is held
/// strongly, so dropping the client also drops the token registration
/// from the shared delegate.
///
/// **Not `Sendable` by design.** The serialized tree dictionaries
/// returned by `frontmostTree()` / `elementAtPoint(...)` are pure
/// Foundation values and are safe to pass across actor boundaries
/// (treat them as immutable after the call returns).
@interface SimAccessibility : NSObject

+ (nullable instancetype)clientForUDID:(NSString *)udid
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(client(forUDID:));

@property (nonatomic, copy, readonly) NSString *udid;

/// The frontmost iOS app's accessibility tree, serialized recursively
/// into a Foundation dictionary. Keys: `role`, `label`, `identifier`,
/// `subrole`, `value`, `frame` (`{x,y,w,h}` dict), `children` (array
/// of element dicts). Optional keys are omitted when empty.
- (nullable NSDictionary<NSString *, id> *)frontmostTreeWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(frontmostTree());

/// The single accessibility element at a pixel-space point. Same
/// dict shape as `frontmostTree()` minus the `children` key. Only
/// the element struck by the point is returned, not its descendants.
/// `point` is in the iOS-side display coordinate space (origin top-
/// left, units = pixels), the space AXPTranslator's
/// `objectAtPoint:displayId:bridgeDelegateToken:` expects. Daemon
/// callers convert from their normalized RPC surface using the
/// frontmost app's root frame; the bridge itself does not normalize.
- (nullable NSDictionary<NSString *, id> *)elementAtPoint:(CGPoint)point
                                                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(elementAtPoint(_:));

@end

NS_ASSUME_NONNULL_END
