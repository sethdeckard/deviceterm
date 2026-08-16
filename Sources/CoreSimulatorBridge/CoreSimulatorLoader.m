// SPDX-License-Identifier: GPL-3.0-or-later

#import "CoreSimulatorLoader.h"

#import <dlfcn.h>
#import <objc/runtime.h>

#pragma mark - Module state

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.Loader";

// Set once by `+loadWithError:` under dispatch_once. Reads from any thread
// thereafter are safe because the values are immutable after the once-block
// runs (the dispatch_once memory barrier synchronizes the publication).
static dispatch_once_t gLoadOnce;
static void *gFrameworkHandle = NULL;
static NSString *gResolvedFrameworkPath = nil;
static NSError *gLoadError = nil;

// SimulatorKit load state, same dispatch_once shape as CoreSimulator.
static dispatch_once_t gSimulatorKitLoadOnce;
static void *gSimulatorKitHandle = NULL;
static NSString *gResolvedSimulatorKitPath = nil;
static NSError *gSimulatorKitLoadError = nil;

// AccessibilityPlatformTranslation load state.
static dispatch_once_t gAXPLoadOnce;
static void *gAXPHandle = NULL;
static NSError *gAXPLoadError = nil;
static NSString *const kAXPFrameworkPath =
    @"/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation";

#pragma mark - CSBProbeReport

// Private mutator declarations so the .m can populate readonly properties
// from the public header.
@interface CSBProbeReport ()
@property (nonatomic, copy, readwrite) NSString *macOSVersion;
@property (nonatomic, copy, readwrite) NSString *xcodeVersion;
@property (nonatomic, copy, readwrite) NSString *developerDir;
@property (nonatomic, copy, readwrite) NSString *frameworkPath;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *okSymbols;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *missingSymbols;
@end

@implementation CSBProbeReport

- (BOOL)ok {
    return self.missingSymbols.count == 0 && self.frameworkPath.length > 0;
}

@end

#pragma mark - CoreSimulatorLoader

@implementation CoreSimulatorLoader

#pragma mark Helpers

/// Run an external command and return its trimmed stdout. Returns `""` on
/// any failure (including launch errors and non-zero exits). Used for
/// `xcode-select -p` and `xcodebuild -version`: no input piped in, no
/// large output expected, no concurrency. Synchronous on purpose.
+ (NSString *)_runCommand:(NSString *)command arguments:(NSArray<NSString *> *)args {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = command;
    task.arguments = args;
    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
        NSData *data = [outPipe.fileHandleForReading readDataToEndOfFile];
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        return [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } @catch (NSException *e) {
        return @"";
    }
}

#pragma mark Public API

+ (NSString *)resolveDeveloperDir {
    NSString *envDir = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (envDir.length > 0) return envDir;
    return [self _runCommand:@"/usr/bin/xcode-select" arguments:@[@"-p"]];
}

+ (NSArray<NSString *> *)candidateFrameworkPathsForDeveloperDir:(NSString *)developerDir {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // 1. xcode-select-derived path. Honors user's active Xcode selection,
    //    including beta toolchains.
    if (developerDir.length > 0) {
        NSString *xcodePath = [developerDir
            stringByAppendingPathComponent:@"Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"];
        [candidates addObject:xcodePath];
    }

    // 2. System-level install (Xcode 15+ / macOS 14+, where the framework is
    //    promoted out of the Xcode bundle into a shared location so the
    //    same binary serves Xcode and standalone simulators).
    [candidates addObject:@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"];

    // 3. CoreSimulator profile bundle (some Xcode versions reach the
    //    framework through here instead of `/Library/Developer/Private…`).
    [candidates addObject:@"/Library/Developer/CoreSimulator/Profiles/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"];

    // 4. Historical hardcoded path. Last resort for hosts where
    //    `xcode-select -p` is wrong but the bundled Xcode is installed at
    //    the default location.
    NSString *historical = @"/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
    if (![candidates containsObject:historical]) {
        [candidates addObject:historical];
    }

    return candidates;
}

+ (BOOL)loadWithError:(NSError **)error {
    dispatch_once(&gLoadOnce, ^{
        NSString *developerDir = [self resolveDeveloperDir];
        NSArray<NSString *> *candidates = [self candidateFrameworkPathsForDeveloperDir:developerDir];
        NSMutableArray<NSString *> *attempted = [NSMutableArray arrayWithCapacity:candidates.count];

        for (NSString *path in candidates) {
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                [attempted addObject:[NSString stringWithFormat:@"missing: %@", path]];
                continue;
            }
            void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
            if (handle != NULL) {
                gFrameworkHandle = handle;
                gResolvedFrameworkPath = [path copy];
                return;  // exits the once-block; gLoadError stays nil.
            }
            const char *dlErr = dlerror();
            [attempted addObject:[NSString stringWithFormat:@"dlopen failed (%s): %@",
                                  dlErr ? dlErr : "(no error)", path]];
        }

        gLoadError = [NSError errorWithDomain:kCSBErrorDomain code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Could not locate CoreSimulator.framework on this machine.",
            @"developerDir": developerDir,
            @"attempted": [attempted copy],
        }];
    });

    if (gFrameworkHandle != NULL) return YES;
    if (error) *error = gLoadError;
    return NO;
}

+ (NSString *)resolvedFrameworkPath {
    return gResolvedFrameworkPath;
}

#pragma mark SimulatorKit loader

/// Candidate paths for SimulatorKit.framework. Same shape as
/// `candidateFrameworkPathsForDeveloperDir:`: try the active
/// developer dir first, then the system-level install, then the
/// historical hardcoded Xcode.app path as a last resort for hosts
/// where `xcode-select -p` points at CommandLineTools but a working
/// Xcode is installed at `/Applications/Xcode.app`.
+ (NSArray<NSString *> *)_candidateSimulatorKitPathsForDeveloperDir:(NSString *)developerDir {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (developerDir.length > 0) {
        [candidates addObject:[developerDir
            stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"]];
    }
    [candidates addObject:@"/Library/Developer/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"];
    NSString *historical = @"/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit";
    if (![candidates containsObject:historical]) {
        [candidates addObject:historical];
    }
    return candidates;
}

+ (BOOL)loadSimulatorKitWithError:(NSError **)error {
    dispatch_once(&gSimulatorKitLoadOnce, ^{
        NSString *developerDir = [self resolveDeveloperDir];
        NSArray<NSString *> *candidates = [self _candidateSimulatorKitPathsForDeveloperDir:developerDir];
        NSMutableArray<NSString *> *attempted = [NSMutableArray arrayWithCapacity:candidates.count];

        for (NSString *path in candidates) {
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                [attempted addObject:[NSString stringWithFormat:@"missing: %@", path]];
                continue;
            }
            void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
            if (handle != NULL) {
                gSimulatorKitHandle = handle;
                gResolvedSimulatorKitPath = [path copy];
                return;
            }
            const char *dlErr = dlerror();
            [attempted addObject:[NSString stringWithFormat:@"dlopen failed (%s): %@",
                                  dlErr ? dlErr : "(no error)", path]];
        }

        gSimulatorKitLoadError = [NSError errorWithDomain:kCSBErrorDomain code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"Could not locate SimulatorKit.framework on this machine.",
            @"developerDir": developerDir,
            @"attempted": [attempted copy],
        }];
    });

    if (gSimulatorKitHandle != NULL) return YES;
    if (error) *error = gSimulatorKitLoadError;
    return NO;
}

#pragma mark AccessibilityPlatformTranslation loader

+ (BOOL)loadAccessibilityPlatformTranslationWithError:(NSError **)error {
    dispatch_once(&gAXPLoadOnce, ^{
        // Don't gate on fileExistsAtPath: `/System` is SIP-protected
        // and may be invisible to non-system processes even when
        // `dlopen` succeeds. Let dlopen be the source of truth.
        void *handle = dlopen(kAXPFrameworkPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        if (handle != NULL) {
            gAXPHandle = handle;
            return;
        }
        const char *dlErr = dlerror();
        gAXPLoadError = [NSError errorWithDomain:kCSBErrorDomain code:3 userInfo:@{
            NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"dlopen AccessibilityPlatformTranslation failed: %s",
                 dlErr ? dlErr : "(no error)"],
            @"path": kAXPFrameworkPath,
        }];
    });

    if (gAXPHandle != NULL) return YES;
    if (error) *error = gAXPLoadError;
    return NO;
}

+ (CSBProbeReport *)probe {
    CSBProbeReport *report = [CSBProbeReport new];

    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    report.macOSVersion = [NSString stringWithFormat:@"%ld.%ld.%ld",
                           (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    report.xcodeVersion = [self _runCommand:@"/usr/bin/xcodebuild" arguments:@[@"-version"]];
    report.developerDir = [self resolveDeveloperDir];

    NSError *loadError = nil;
    if (![self loadWithError:&loadError]) {
        report.frameworkPath = @"";
        report.okSymbols = @[];
        report.missingSymbols = @[[NSString stringWithFormat:@"framework: %@",
                                   loadError.localizedDescription ?: @"unknown error"]];
        return report;
    }
    report.frameworkPath = gResolvedFrameworkPath ?: @"";

    // SimulatorKit doesn't gate the probe the way CoreSimulator does: a
    // failure to load it surfaces as a `framework SimulatorKit: …` entry
    // in missing symbols, plus the downstream class/selector entries
    // that depend on it, and the probe carries on rather than
    // early-returning. Those entries still fail the gate; only the
    // optional C symbols below are exempt from that.
    NSError *simKitLoadError = nil;
    BOOL simKitLoaded = [self loadSimulatorKitWithError:&simKitLoadError];

    // AccessibilityPlatformTranslation is handled the same way. It lives
    // under /System (no Xcode dependency), so failure usually means a
    // very old macOS without the framework.
    NSError *axpLoadError = nil;
    BOOL axpLoaded = [self loadAccessibilityPlatformTranslationWithError:&axpLoadError];

    // Required-symbol inventory. Grows as each subsequent CoreSimulatorBridge
    // module lands. See AGENTS.md "Architecture-checks review gates."
    // Every entry below must have a matching row in as-tested.md's
    // Required-symbols table.
    NSArray<NSString *> *requiredClasses = @[
        // CoreSimulatorLoader
        @"SimServiceContext",
        // SimDeviceHandle
        @"SimDeviceSet",
        @"SimDevice",
        @"SimRuntime",
        @"SimDeviceType",
        // SimDisplayHandle
        @"SimDeviceIOClient",
        // SimHIDClient: Swift-bridged subclass we instantiate. The
        // parent `SimDeviceLegacyClient` exists in the vendored headers
        // for static typing but isn't a runtime-registered class, so its
        // instance selectors resolve via inheritance on the subclass.
        @"SimulatorKit.SimDeviceLegacyHIDClient",
        // SimAccessibility: AXPTranslator is the entry point; the
        // other AXP types appear via its method returns and don't need
        // direct class probes (they're resolved through translations).
        @"AXPTranslator",
        @"AXPTranslatorResponse",
        @"AXPMacPlatformElement",
    ];
    NSDictionary<NSString *, NSArray<NSString *> *> *requiredClassSelectors = @{
        // CoreSimulatorLoader
        @"SimServiceContext": @[
            @"sharedServiceContextForDeveloperDir:error:",
        ],
        // SimAccessibility: singleton accessor + empty-response fallback.
        @"AXPTranslator": @[
            @"sharedInstance",
        ],
        @"AXPTranslatorResponse": @[
            @"emptyResponse",
        ],
    };
    NSDictionary<NSString *, NSArray<NSString *> *> *requiredInstanceSelectors = @{
        // SimDeviceHandle: context + device-set access
        @"SimServiceContext": @[
            @"defaultDeviceSetWithError:",
        ],
        @"SimDeviceSet": @[
            @"devices",
            // SimDeviceNotifier: set-level subscription so we
            // catch boot/shutdown transitions the shim's argv
            // detector can't see (xcodebuild, Simulator.app,
            // absolute-path `xcrun`, FFI callers).
            @"registerNotificationHandlerOnQueue:handler:",
            @"unregisterNotificationHandler:error:",
        ],
        // SimDeviceHandle: identity + lifecycle on a single device
        @"SimDevice": @[
            @"UDID",
            @"name",
            @"state",
            @"runtime",
            @"runtimeIdentifier",
            @"deviceType",
            @"deviceTypeIdentifier",
            @"bootWithOptions:error:",
            @"shutdownWithError:",
            // SimDisplayHandle: io accessor (returns the io client).
            @"io",
            // SimPurpleHID: Mach service lookup in the sim's bootstrap
            // namespace (used to resolve PurpleWorkspacePort).
            @"lookup:error:",
            // SimAccessibility: request round-trip to the iOS-side
            // AXP server.
            @"sendAccessibilityRequestAsync:completionQueue:completionHandler:",
            // SimLocation: simulated GPS position. Probe only the
            // selectors the bridge calls; `setLocationScenarioWithPath:`
            // remains outside the dependency set.
            @"availableLocationScenarios",
            @"setLocationWithLatitude:andLongitude:error:",
            @"setLocationScenario:error:",
            @"clearSimulatedLocationWithError:",
            @"startLocationSimulationWithDistance:speed:waypoints:error:",
            @"startLocationSimulationWithInterval:speed:waypoints:error:",
        ],
        // SimDeviceHandle: runtime + deviceType identity (via SimDevice.runtime / .deviceType)
        @"SimRuntime": @[
            @"identifier",
        ],
        @"SimDeviceType": @[
            @"identifier",
            @"name",
        ],
        // SimDisplayHandle: port enumeration off the IO client.
        @"SimDeviceIOClient": @[
            @"ioPorts",
        ],
        // SimHIDClient: instantiation + send path. Selectors live on
        // the parent SimDeviceLegacyClient but are inherited by the
        // Swift-bridged subclass we actually instantiate.
        @"SimulatorKit.SimDeviceLegacyHIDClient": @[
            @"initWithDevice:error:",
            @"sendWithMessage:freeWhenDone:completionQueue:completion:",
        ],
        // SimAccessibility: entry points + tree walking.
        @"AXPTranslator": @[
            @"frontmostApplicationWithDisplayId:bridgeDelegateToken:",
            @"objectAtPoint:displayId:bridgeDelegateToken:",
            @"macPlatformElementFromTranslation:",
            @"setBridgeTokenDelegate:",
        ],
        @"AXPMacPlatformElement": @[
            @"accessibilityRole",
            @"accessibilityLabel",
            @"accessibilityIdentifier",
            @"accessibilitySubrole",
            @"accessibilityValue",
            @"accessibilityFrame",
            @"accessibilityChildren",
            @"translation",
        ],
    };
    NSArray<NSString *> *requiredProtocols = @[
        // SimDisplayHandle: the picker tests for SimDisplayIOSurfaceRenderable
        // conformance and calls methods inherited from its parent protocol
        // SimDisplayRenderable.
        @"SimDisplayRenderable",
        @"SimDisplayIOSurfaceRenderable",
        // SimDisplayHandle's orientation observation. The same display
        // descriptor also conforms to SimScreen, which is where the
        // presented orientation and its change callback live.
        @"SimScreen",
        @"SimScreenProperties",
        // SimAccessibility: three-method delegate protocol that AXP
        // calls back into. Missing any of these methods crashes the
        // first translation request.
        @"AXPTranslationTokenDelegateHelper",
    ];
    // Selectors that must exist as method descriptions on a private
    // protocol. Renderable proxies are dynamically-classed (their
    // class names vary across Xcode versions and platforms) so we can't
    // probe via NSClassFromString, but the protocol contract is stable
    // and reachable via the runtime. Each method below is looked up as
    // either required or optional on the protocol.
    NSDictionary<NSString *, NSArray<NSString *> *> *requiredProtocolInstanceSelectors = @{
        // The base SimDisplayRenderable carries display dimensions and
        // the damage-rectangles callback shape (register + unregister).
        @"SimDisplayRenderable": @[
            @"displaySize",
            @"registerCallbackWithUUID:damageRectanglesCallback:",
            @"unregisterDamageRectanglesCallbackWithUUID:",
        ],
        // SimDisplayIOSurfaceRenderable adds the IOSurface accessors and
        // both shapes of the surface-change callback.
        @"SimDisplayIOSurfaceRenderable": @[
            @"framebufferSurface",
            @"ioSurface",
            @"registerCallbackWithUUID:ioSurfaceChangeCallback:",
            @"registerCallbackWithUUID:ioSurfacesChangeCallback:",
            @"unregisterIOSurfaceChangeCallbackWithUUID:",
            @"unregisterIOSurfacesChangeCallbackWithUUID:",
        ],
        // SimScreen carries the presented orientation: `screenProperties`
        // reads it, and the screen-callback registration is how a change
        // is pushed. Losing these costs the pane every rotation it didn't
        // command itself, silently, so they are probed rather than left to
        // a runtime `respondsToSelector:` that just answers NO.
        @"SimScreen": @[
            @"screenProperties",
            @"registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:",
            @"unregisterScreenCallbacksWithUUID:",
        ],
        // The property the orientation is actually read from.
        @"SimScreenProperties": @[
            @"uiOrientation",
        ],
        // SimAccessibility: AXP calls back through these on every
        // translation request. Skip any and the first call crashes.
        @"AXPTranslationTokenDelegateHelper": @[
            @"accessibilityTranslationDelegateBridgeCallbackWithToken:",
            @"accessibilityTranslationConvertPlatformFrameToSystem:withToken:",
            @"accessibilityTranslationRootParentWithToken:",
        ],
    };
    // C-function symbols probed via `dlsym(RTLD_DEFAULT, …)`. The
    // SimulatorKit Indigo helpers aren't exposed as Obj-C methods; the
    // bridge calls them via dlsym at runtime. Probing here ensures the
    // compat gate catches it if Apple renames or removes them.
    NSArray<NSString *> *requiredCSymbols = @[
        // SimHIDClient: Indigo wire-format helpers
        @"IndigoHIDMessageForButton",
        @"IndigoHIDMessageForKeyboardArbitrary",
        @"IndigoHIDMessageForMouseNSEvent",
        @"IndigoHIDMessageForHIDArbitrary",  // Siri (Voice Command consumer usage)
    ];
    // Optional C symbols: present on modern SimulatorKit but may be absent on
    // older Xcode installs. Their absence degrades only the matching feature
    // (not the whole bridge), so they are reported but NEVER counted as a
    // probe failure. `SimHIDClient` treats them the same way.
    NSArray<NSString *> *optionalCSymbols = @[
        @"IndigoHIDMessageForDigitalCrownEvent",  // watchOS Digital Crown rotation
    ];

    NSMutableArray<NSString *> *ok = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];

    // Surface SimulatorKit's load outcome first so downstream missing
    // entries don't read as mysterious. The CoreSimulator load already
    // succeeded by this point (we'd have early-returned otherwise).
    if (simKitLoaded) {
        [ok addObject:[NSString stringWithFormat:@"framework SimulatorKit (%@)",
                       gResolvedSimulatorKitPath ?: @"?"]];
    } else {
        [missing addObject:[NSString stringWithFormat:@"framework SimulatorKit: %@",
                            simKitLoadError.localizedDescription ?: @"unknown error"]];
    }
    if (axpLoaded) {
        [ok addObject:@"framework AccessibilityPlatformTranslation"];
    } else {
        [missing addObject:[NSString stringWithFormat:@"framework AccessibilityPlatformTranslation: %@",
                            axpLoadError.localizedDescription ?: @"unknown error"]];
    }

    for (NSString *clsName in requiredClasses) {
        if (NSClassFromString(clsName)) {
            [ok addObject:[NSString stringWithFormat:@"class %@", clsName]];
        } else {
            [missing addObject:[NSString stringWithFormat:@"class %@", clsName]];
        }
    }
    [requiredClassSelectors enumerateKeysAndObjectsUsingBlock:^(NSString *clsName, NSArray<NSString *> *sels, BOOL *_) {
        Class cls = NSClassFromString(clsName);
        if (!cls) return;  // already recorded as missing class
        for (NSString *selName in sels) {
            SEL sel = NSSelectorFromString(selName);
            BOOL responds = [cls respondsToSelector:sel];
            NSString *label = [NSString stringWithFormat:@"+[%@ %@]", clsName, selName];
            [(responds ? ok : missing) addObject:label];
        }
    }];
    [requiredInstanceSelectors enumerateKeysAndObjectsUsingBlock:^(NSString *clsName, NSArray<NSString *> *sels, BOOL *_) {
        Class cls = NSClassFromString(clsName);
        if (!cls) return;
        for (NSString *selName in sels) {
            SEL sel = NSSelectorFromString(selName);
            BOOL responds = [cls instancesRespondToSelector:sel];
            NSString *label = [NSString stringWithFormat:@"-[%@ %@]", clsName, selName];
            [(responds ? ok : missing) addObject:label];
        }
    }];
    for (NSString *protoName in requiredProtocols) {
        Protocol *p = NSProtocolFromString(protoName);
        NSString *label = [NSString stringWithFormat:@"protocol %@", protoName];
        [(p ? ok : missing) addObject:label];
    }
    [requiredProtocolInstanceSelectors enumerateKeysAndObjectsUsingBlock:
     ^(NSString *protoName, NSArray<NSString *> *sels, BOOL *_) {
        Protocol *p = NSProtocolFromString(protoName);
        if (!p) return;  // already recorded as missing protocol
        for (NSString *selName in sels) {
            SEL sel = NSSelectorFromString(selName);
            // Try required+instance first, then optional+instance; either
            // counts as present. Renderable selectors are sometimes
            // declared @optional on the protocol but the proxy
            // implements them anyway.
            struct objc_method_description req =
                protocol_getMethodDescription(p, sel, YES, YES);
            struct objc_method_description opt =
                protocol_getMethodDescription(p, sel, NO, YES);
            BOOL present = (req.name != NULL) || (opt.name != NULL);
            NSString *label = [NSString stringWithFormat:@"-<%@> %@", protoName, selName];
            [(present ? ok : missing) addObject:label];
        }
    }];
    for (NSString *sym in requiredCSymbols) {
        void *fn = dlsym(RTLD_DEFAULT, sym.UTF8String);
        NSString *label = [NSString stringWithFormat:@"C %@", sym];
        [(fn ? ok : missing) addObject:label];
    }
    // Optional symbols always land in `ok` (present or absent) so they never
    // fail the gate, but the label records their status for release review.
    for (NSString *sym in optionalCSymbols) {
        void *fn = dlsym(RTLD_DEFAULT, sym.UTF8String);
        [ok addObject:(fn
            ? [NSString stringWithFormat:@"C %@ (optional)", sym]
            : [NSString stringWithFormat:@"C %@ (optional: absent; feature disabled)", sym])];
    }

    report.okSymbols = [ok copy];
    report.missingSymbols = [missing copy];
    return report;
}

@end
