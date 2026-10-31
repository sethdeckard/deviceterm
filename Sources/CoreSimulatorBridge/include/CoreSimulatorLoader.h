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
/// `xcodebuild -version` from the cached developer-directory selection.
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
/// `load()` and `probe()` are class methods; both are thread-safe. After a
/// successful `load()`, the framework binary remains in the process for the
/// lifetime of the host; a failed one retries on the next call.
@interface CoreSimulatorLoader : NSObject

/// Locate and `dlopen` CoreSimulator.framework. Thread-safe; a success is
/// cached for the process lifetime, and a failure retries on the next call.
/// The resolved path is available via `resolvedFrameworkPath` after this
/// returns `YES`.
///
/// Tries paths in the order returned by `candidateFrameworkPaths(forDeveloperDir:)`
/// against the `resolveDeveloperDir()` snapshot. A retry tries the current
/// selection first, merged as `loadRetryDeveloperDirs(forResolved:current:)`
/// describes. The snapshot moves to that selection only when the framework
/// loaded from inside it (see `developerDir(_:suppliedFrameworkAtPath:)`).
/// Returns `NO` and populates `error` if every candidate is absent or fails
/// to load; the error's description lists each path tried.
+ (BOOL)loadWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(loadFramework());

/// Locate and `dlopen` SimulatorKit.framework. Thread-safe, with the same
/// success caching, retry, and error shape as `loadFramework()`, against
/// `candidateSimulatorKitPaths(forDeveloperDir:)`. Required for any bridge
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

/// Snapshot of the active developer directory. Reads `DEVELOPER_DIR` from the
/// process env if set, otherwise shells out to `xcode-select -p`, and keeps
/// the first non-empty result; an empty one is read again on the next call.
/// The snapshot then changes only when a framework load retry loads from
/// inside a newer selection, which it adopts. Later service contexts use the
/// adopted selection. Frameworks already loaded remain unchanged. Synchronous
/// and safe to call from any thread.
///
/// Bridge modules that need to locate SDK-relative resources call
/// this so the resolution policy and the Xcode selection shared by their
/// service contexts stay in one place.
+ (NSString *)resolveDeveloperDir
    NS_SWIFT_NAME(resolveDeveloperDir());

/// The `SimServiceContext` for the `resolveDeveloperDir()` snapshot, or `nil`
/// with `error` set. Refuses an empty snapshot with an error that says to
/// select an Xcode, because CoreSimulator throws on an empty developer dir.
/// Typed `id` so this header stays free of the private CoreSimulator headers.
+ (nullable id)sharedServiceContextWithError:(NSError * _Nullable * _Nullable)error;

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

/// Candidate SimulatorKit framework paths for a developer-dir hint. For an
/// Xcode `Contents/Developer` hint, tries that Xcode's `Contents/Developer`
/// and sibling `Contents/SharedFrameworks` layouts before
/// developer-dir-independent fallbacks. Pure function with the same
/// diagnostics/testing purpose as `candidateFrameworkPaths(forDeveloperDir:)`.
+ (NSArray<NSString *> *)candidateSimulatorKitPathsForDeveloperDir:(NSString *)developerDir
    NS_SWIFT_NAME(candidateSimulatorKitPaths(forDeveloperDir:));

/// Developer dirs a load retry walks: the current selection, then the
/// cached developer-directory selection, each once and skipping empties. Returns `[""]`
/// when both are empty, so the developer-dir-independent fallbacks still run.
/// Pure function.
+ (NSArray<NSString *> *)loadRetryDeveloperDirsForResolved:(NSString *)resolved
                                                   current:(NSString *)current
    NS_SWIFT_NAME(loadRetryDeveloperDirs(forResolved:current:));

/// Whether `frameworkPath` lies inside the Xcode `developerDir` names: under
/// its `Contents` directory for an Xcode `Contents/Developer` path, otherwise
/// under the dir itself. Decides whether a load retry adopts the selection.
/// Pure function.
+ (BOOL)developerDir:(NSString *)developerDir suppliedFrameworkAtPath:(NSString *)frameworkPath
    NS_SWIFT_NAME(developerDir(_:suppliedFrameworkAtPath:));

/// Description for a framework that no candidate loaded: names the
/// framework, says to select an Xcode and retry, then lists every
/// `attempted` entry in order. Pure function.
+ (NSString *)loadFailureDescriptionForFramework:(NSString *)frameworkName
                                       attempted:(NSArray<NSString *> *)attempted
    NS_SWIFT_NAME(loadFailureDescription(forFramework:attempted:));

@end

NS_ASSUME_NONNULL_END
