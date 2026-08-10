// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimLocation: simulated GPS position for one simulator.
//
// Wraps the private `SimDevice (SimLocation)` category, the same
// surface `simctl location <device> list/set/run/start/clear` drives.
// These are ordinary Obj-C methods that hand a coordinate, a named
// scenario, or a list of waypoints to the sim's location daemon. Only
// the waypoint list needed reverse-engineering, and its shape is
// documented on `startRouteWithDistance:…` below.
//
// **There is no getter.** CoreSimulator exports `setLocation…`,
// `setLocationScenario…`, `startLocationSimulationWith…`,
// `availableLocationScenarios` and `clearSimulatedLocation…`; nothing
// reads the current simulated position back. Callers that need to show
// which location is active must track what they set. A change made
// out-of-band (from
// Simulator.app, raw `simctl location`, or an Xcode debug session) is
// invisible to this wrapper.
//
// One selector on the category is left unwrapped:
// `setLocationScenarioWithPath:`. It remains declared in the vendored
// header but is not a bridge dependency; the probe covers only the
// selectors this wrapper calls.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Location-simulation client for one simulator.
///
/// **Not `Sendable` by design.** Holds a `SimDevice *` and calls
/// straight through to it. Keep each instance within one isolation
/// domain, or wrap it in a type that documents and enforces its
/// isolation invariant.
@interface SimLocation : NSObject

/// Acquire a location client for the device with this UDID.
+ (nullable instancetype)clientForUDID:(NSString *)udid
                                 error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(client(forUDID:));

@property (nonatomic, copy, readonly) NSString *udid;

/// The built-in scenario names this runtime offers: the "trips" that
/// `simctl location <device> list` prints (City Run, City Bicycle Ride,
/// Freeway Drive, Apple, …). Each is a *route* the sim plays over time,
/// not a fixed point.
///
/// **Requires a booted device.** A shut-down one returns an empty array
/// rather than an error, matching `simctl`, which prints only its table
/// header. An empty result is therefore a normal cold-device state, not
/// a failure: a caller showing this list must repopulate it once the
/// device boots.
///
/// The underlying selector is declared as returning bare `id`. The
/// live-verified shape (Xcode 26.5 / iOS 26) is an `NSArray` of
/// `NSDictionary`, each carrying `name` and `localizedName`; this vends
/// `name`, which is what `setScenario:` consumes. A plain string array,
/// and a dictionary keyed by name, are both still accepted as fallbacks
/// because the declared type guarantees none of that. Anything else
/// yields an empty array rather than trapping.
- (nullable NSArray<NSString *> *)availableScenariosWithError:
        (NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(availableScenarios());

/// Pin the device to a fixed coordinate. The simulated position
/// persists until `clear` or another set.
- (BOOL)setLatitude:(double)latitude
          longitude:(double)longitude
              error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(setCoordinate(latitude:longitude:));

/// Start one of the built-in scenarios from `availableScenarios`.
/// Playback runs sim-side; this returns as soon as the scenario is
/// accepted, not when the route finishes.
///
/// **The caller must validate `scenario` against `availableScenarios`
/// first.** An unknown name returns `YES` with no error or effect, so a
/// typo looks successful but changes nothing. `simctl` only appears to
/// reject bad names ("Could not find scenario 'x'") because it checks
/// its own list client-side before reaching this selector; there is no
/// validation behind it to inherit. Live-verified.
- (BOOL)setScenario:(NSString *)scenario
              error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(setScenario(_:));

/// Stop any running scenario or route and drop the simulated position,
/// returning the device to whatever location it would report on its own.
- (BOOL)clearWithError:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(clear());

/// Walk the device along `waypoints`, publishing a position every
/// `meters` travelled.
///
/// **`waypoints` is a flat array of alternating latitude and longitude
/// `NSNumber`s**, not points or dictionaries: `@[@37.77, @-122.41,
/// @40.71, @-74.00]` is two waypoints. The underlying selector declares
/// a bare `NSArray` and validates nothing, so this shape was recovered
/// from `simctl`'s own machine code rather than guessed. It builds one
/// `NSMutableArray`, appends `+[NSNumber numberWithDouble:]` for each
/// half of every `lat,lon` pair, then reports `count / 2` as the
/// waypoint total. Neither `simctl` nor CoreSimulator links
/// CoreLocation, so `CLLocation` was never a candidate.
///
/// Playback runs sim-side; this returns once the route is accepted, not
/// when it finishes. The route persists until `clear` or another set.
///
/// Callers must pass at least two waypoints (an even count of at least
/// four numbers); shorter input is rejected here rather than handed to
/// a private selector with no validation behind it.
- (BOOL)startRouteWithDistance:(double)meters
                         speed:(double)speed
                     waypoints:(NSArray<NSNumber *> *)waypoints
                         error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(startRoute(distance:speed:waypoints:));

/// Walk the device along `waypoints`, publishing a position every
/// `seconds`. Identical to the distance form in every other respect,
/// including the flat latitude/longitude `waypoints` shape.
- (BOOL)startRouteWithInterval:(double)seconds
                         speed:(double)speed
                     waypoints:(NSArray<NSNumber *> *)waypoints
                         error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(startRoute(interval:speed:waypoints:));

@end

NS_ASSUME_NONNULL_END
