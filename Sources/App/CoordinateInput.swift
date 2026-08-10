// SPDX-License-Identifier: GPL-3.0-or-later
//
// CoordinateInput: parsing and validating what the user types into the
// Custom Coordinates sheet.
//
// The sheet delegates coordinate validation here, so tests can inspect
// every rejection and its optional message.
//
// **Locale-aware on purpose, and only here.** A person typing into a
// text field types in their own locale, so `37,7749` must be accepted
// where the decimal separator is a comma. The saved-locations *file* is
// the opposite: a fixed POSIX format whose meaning must not change with
// whoever opens it. `LocationsFileParser` therefore parses without a
// locale, and the two must not be made to share one code path.

import DaemonProtocol
import Foundation

enum CoordinateInput {
    /// Why a typed coordinate was rejected. Each carries the message the
    /// sheet shows beneath the offending field.
    enum Defect: Error, Equatable, Sendable {
        /// Nothing typed yet. The sheet shows no complaint for this,
        /// since an empty field is unfinished rather than wrong, but
        /// it still blocks submission.
        case empty
        /// Not a number at all, or a non-finite one (`nan`, `inf`).
        case notANumber
        /// A number outside the coordinate's valid range.
        case outOfRange(ClosedRange<Double>)

        /// Text to show beneath the field, or nil when the field is
        /// merely incomplete.
        var message: String? {
            switch self {
            case .empty:
                return nil

            case .notANumber:
                return "Enter a number."

            case let .outOfRange(range):
                return "Must be between \(Self.bound(range.lowerBound)) "
                    + "and \(Self.bound(range.upperBound))."
            }
        }

        /// Range bounds are whole degrees, so render them without the
        /// trailing `.0` that string interpolation would add.
        private static func bound(_ value: Double) -> String {
            String(format: "%g", value)
        }
    }

    /// Parse a typed latitude, rejecting anything outside `-90…90`.
    static func latitude(
        _ text: String,
        locale: Locale = .current
    ) -> Result<Double, Defect> {
        parse(text, in: SimulatedLocation.latitudeRange, locale: locale)
    }

    /// Parse a typed longitude, rejecting anything outside `-180…180`.
    static func longitude(
        _ text: String,
        locale: Locale = .current
    ) -> Result<Double, Defect> {
        parse(text, in: SimulatedLocation.longitudeRange, locale: locale)
    }

    /// Both fields at once, for the sheet's submit path. Succeeds only
    /// when each component does, so a `SimulatedLocation` built here is
    /// already within the ranges `pane.location.set` enforces daemon-side.
    ///
    /// The result is **canonicalized to the locations file's precision**,
    /// because applying a coordinate also saves it. Keeping the typed
    /// digits would set one number and store a rounded one, and the menu
    /// matches the daemon's claim by exact equality: the saved row would
    /// sit unchecked while a second row appeared for the claim. Every
    /// producer of a coordinate to apply, CoreLocation fixes and GPX
    /// points included, goes through here or
    /// `LocationsFileParser.canonical` for the same reason.
    static func location(
        latitude latitudeText: String,
        longitude longitudeText: String,
        locale: Locale = .current
    ) -> SimulatedLocation? {
        guard case let .success(lat) = latitude(latitudeText, locale: locale),
            case let .success(lon) = longitude(longitudeText, locale: locale) else {
            return nil
        }
        return .coordinate(
            latitude: LocationsFileParser.canonical(lat),
            longitude: LocationsFileParser.canonical(lon)
        )
    }

    private static func parse(
        _ text: String,
        in range: ClosedRange<Double>,
        locale: Locale
    ) -> Result<Double, Defect> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let value = number(from: trimmed, locale: locale) else {
            return .failure(.notANumber)
        }
        // Catches `nan` and `±inf`, which parse as `Double` but are not
        // positions and cannot be JSON-encoded onto the wire.
        guard value.isFinite else { return .failure(.notANumber) }
        guard range.contains(value) else { return .failure(.outOfRange(range)) }
        return .success(value)
    }

    /// POSIX first, then the user's locale.
    ///
    /// Order matters, and the collision is narrower than it looks.
    /// Wherever `.` is the *grouping* separator, `NumberFormatter`
    /// rejects `37.7749` outright (four digits behind a group is not a
    /// valid group). But it happily reads `37.774` as **37774**, three
    /// digits being exactly one group, so a locale-first parse turns
    /// that one coordinate into an out-of-range number while its
    /// four-decimal neighbour reads fine, which is the kind of bug
    /// nobody reproduces on demand.
    ///
    /// Trying the locale-independent form first means the unambiguous
    /// spelling always wins, and the locale pass only ever rescues input
    /// POSIX couldn't read at all, `37,7749` being the case that matters.
    private static func number(from text: String, locale: Locale) -> Double? {
        if let posix = Double(text) { return posix }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.number(from: text)?.doubleValue
    }
}
