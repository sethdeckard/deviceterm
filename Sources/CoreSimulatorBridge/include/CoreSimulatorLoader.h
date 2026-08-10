// SPDX-License-Identifier: GPL-3.0-or-later
//
// CoreSimulatorLoader: dynamic loader for Apple's private CoreSimulator
// framework, plus a structured compatibility probe.
//
// The framework is dlopen'd at runtime (not link-time) so deviceterm can fail
// gracefully on machines without Xcode, and so we can support multiple
// install layouts (Xcode-bundled, system-installed via /Library/Developer,
// historical /Applications/Xcode.app path).
//
// The probe enumerates required classes/selectors/protocols against the
// loaded framework and produces a `CSBProbeReport`. Each subsequent
// CoreSimulatorBridge module's PR extends the probe inventory to cover
// every private selector that module depends on. See AGENTS.md's
// "Architecture-checks review gates."

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Structured outcome of `CoreSimulatorLoader.probe()`.
/// Immutable after construction; properties point at copies. Safe to pass
/// across actor boundaries.
@interface CSBProbeReport : NSObject

@property (nonatomic, copy, readonly) NSString *macOSVersion;
@property (nonatomic, copy, readonly) NSString *xcodeVersion;
@property (nonatomic, copy, readonly) NSString *developerDir;

/// Path of the framework binary that successfully dlopen'd, or `""` if the
/// framework could not be loaded. When empty, `okSymbols` is `[]` and
/// `missingSymbols` contains a `framework: …` entry.
@property (nonatomic, copy, readonly) NSString *frameworkPath;

@property (nonatomic, copy, readonly) NSArray<NSString *> *okSymbols;
@property (nonatomic, copy, readonly) NSArray<NSString *> *missingSymbols;

/// `YES` iff the framework loaded and every required symbol was found.
@property (nonatomic, readonly) BOOL ok;

@end


/// Dynamic loader + compatibility probe for CoreSimulator.framework.
///
/// `load()` and `probe()` are class methods; both are thread-safe and
/// idempotent. After a successful `load()`, the framework binary remains
/// in the process for the lifetime of the host.
@interface CoreSimulatorLoader : NSObject

/// Locate and `dlopen` CoreSimulator.framework. Idempotent and
/// thread-safe (`dispatch_once`-guarded). The resolved path is available
/// via `resolvedFrameworkPath` after this returns `YES`.
///
/// Tries paths in the order returned by `candidateFrameworkPaths(forDeveloperDir:)`
/// against the developer dir from `$DEVELOPER_DIR` or `xcode-select -p`.
/// Returns `NO` and populates `error` if every candidate is absent or
/// fails to load.
+ (BOOL)loadWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(loadFramework());

/// Locate and `dlopen` SimulatorKit.framework. Idempotent and
/// thread-safe (`dispatch_once`-guarded). Required for any bridge
/// module that drives input. SimulatorKit hosts the
/// `SimDeviceLegacyHIDClient` class and the Indigo wire-format helper
/// C functions that `SimHIDClient` uses.
+ (BOOL)loadSimulatorKitWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(loadSimulatorKit());

/// Locate and `dlopen` AccessibilityPlatformTranslation.framework.
/// Idempotent and thread-safe (`dispatch_once`-guarded). Required by
/// `SimAccessibility`, which needs `AXPTranslator` and the
/// `AXPTranslationTokenDelegateHelper` protocol, which is how iOS-side
/// accessibility trees reach the host process. The framework lives at
/// a fixed system path on macOS and doesn't depend on
/// `DEVELOPER_DIR`.
+ (BOOL)loadAccessibilityPlatformTranslationWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(loadAccessibilityPlatformTranslation());

/// Run the compatibility probe. Returns a fresh report each call.
/// Safe to call before or after `loadFramework()`. If a framework
/// hasn't been loaded, the report records a `framework: …` entry per
/// failure in `missingSymbols` and an empty `frameworkPath`.
+ (CSBProbeReport *)probe
    NS_SWIFT_NAME(probe());

/// Path of the CoreSimulator framework binary that successfully
/// `dlopen`'d, or `nil` if `loadFramework()` has not succeeded.
@property (class, nullable, readonly) NSString *resolvedFrameworkPath;

/// Active developer directory. Reads `DEVELOPER_DIR` from the process
/// env if set; otherwise shells out to `xcode-select -p`. Returns an
/// empty string if neither resolves. Synchronous; safe to call from
/// any thread (env reads + process spawn are concurrency-clean).
///
/// Bridge modules that need to locate SDK-relative resources call
/// this so the resolution policy stays in one place.
+ (NSString *)resolveDeveloperDir
    NS_SWIFT_NAME(resolveDeveloperDir());

/// Candidate framework paths the loader would try, given a developer-dir
/// hint. Pure function: does not touch process env or shell out. Exposed
/// for diagnostics ("which paths would deviceterm try on this machine?") and
/// for unit tests. The order matters: callers should try paths in the
/// returned order.
///
/// Pass `""` to get only the developer-dir-independent fallbacks (system-
/// level paths). Useful for testing the degraded-host scenario.
+ (NSArray<NSString *> *)candidateFrameworkPathsForDeveloperDir:(NSString *)developerDir
    NS_SWIFT_NAME(candidateFrameworkPaths(forDeveloperDir:));

@end

NS_ASSUME_NONNULL_END
