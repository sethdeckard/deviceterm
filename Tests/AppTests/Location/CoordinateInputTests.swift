// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// CoordinateInputTests: everything the Custom Coordinates sheet is
// allowed to accept.
//
// The boundaries are pinned exactly (±90, ±180 in; a ten-thousandth
// past them out) because the daemon enforces the same ranges, and a
// sheet that let something through would defer a simple typo to the
// RPC's `invalidParams` response instead of rejecting it in the sheet.

private func value(_ result: Result<Double, CoordinateInput.Defect>) -> Double? {
    guard case let .success(value) = result else { return nil }
    return value
}

private func defect(_ result: Result<Double, CoordinateInput.Defect>) -> CoordinateInput.Defect? {
    guard case let .failure(defect) = result else { return nil }
    return defect
}

// MARK: - Ranges

@Test("latitude accepts its whole range", arguments: [-90.0, -89.9999, 0, 37.7749, 89.9999, 90])
func latitudeAcceptsInRange(input: Double) {
    #expect(value(CoordinateInput.latitude("\(input)", locale: .posix)) == input)
}

@Test("longitude accepts its whole range", arguments: [-180.0, -122.4194, 0, 151.2093, 180])
func longitudeAcceptsInRange(input: Double) {
    #expect(value(CoordinateInput.longitude("\(input)", locale: .posix)) == input)
}

@Test("latitude rejects just outside its range", arguments: ["90.0001", "-90.0001", "180", "-180"])
func latitudeRejectsOutOfRange(input: String) {
    #expect(
        defect(CoordinateInput.latitude(input, locale: .posix))
            == .outOfRange(SimulatedLocation.latitudeRange)
    )
}

@Test("longitude rejects just outside its range", arguments: ["180.0001", "-180.0001", "360"])
func longitudeRejectsOutOfRange(input: String) {
    #expect(
        defect(CoordinateInput.longitude(input, locale: .posix))
            == .outOfRange(SimulatedLocation.longitudeRange)
    )
}

/// A longitude is valid at ±180 where a latitude is not, so the two
/// fields cannot share one range check.
@Test("the two fields do not share a range")
func rangesAreDistinct() {
    #expect(value(CoordinateInput.longitude("150", locale: .posix)) == 150)
    #expect(defect(CoordinateInput.latitude("150", locale: .posix)) != nil)
}

// MARK: - Non-numbers

/// `nan` and `inf` parse as `Double` but are not positions, and JSON
/// can't encode them, so a set carrying one would fail at the encoder
/// rather than in the sheet where the user could fix it.
@Test("non-finite input is not a number", arguments: ["nan", "NaN", "inf", "-inf", "infinity"])
func rejectsNonFinite(input: String) {
    #expect(defect(CoordinateInput.latitude(input, locale: .posix)) == .notANumber)
}

@Test("unparseable input is not a number", arguments: ["north", "37.7x", "37,7749,0", "--3", ""])
func rejectsGarbage(input: String) {
    let result = CoordinateInput.latitude(input, locale: .posix)
    #expect(defect(result) != nil)
    // Only the empty string is "unfinished" rather than wrong.
    #expect(defect(result) == (input.isEmpty ? .empty : .notANumber))
}

@Test("whitespace around a number is ignored")
func trimsWhitespace() {
    #expect(value(CoordinateInput.latitude("  37.7749  ", locale: .posix)) == 37.7749)
    #expect(defect(CoordinateInput.latitude("   ", locale: .posix)) == .empty)
}

// MARK: - Locale

/// A person types in their own locale, so a decimal comma has to work.
@Test("a locale decimal separator is accepted")
func acceptsLocaleDecimalSeparator() {
    let german = Locale(identifier: "de_DE")
    #expect(value(CoordinateInput.latitude("37,7749", locale: german)) == 37.7749)
}

/// The ordering rule the parse depends on, pinned on the input that
/// collides. Where `.` is the *grouping* separator, `NumberFormatter`
/// rejects `37.7749` (four digits is not a valid group) but reads
/// `37.774` as **37774**. Only the three-decimal spelling exposes a
/// locale-first parse, and it exposes it as an out-of-range complaint
/// about a perfectly good coordinate.
@Test("a POSIX decimal point survives a comma-decimal locale", arguments: [
    "37.774", "-122.419", "51.507", "37.7749"
])
func posixSpellingWinsInAnyLocale(input: String) {
    let german = Locale(identifier: "de_DE")
    let field = input.hasPrefix("-")
        ? CoordinateInput.longitude(input, locale: german)
        : CoordinateInput.latitude(input, locale: german)
    #expect(value(field) == Double(input))
}

// MARK: - Messages

/// `.empty` deliberately shows nothing: a field the user hasn't finished
/// typing isn't wrong, and a sheet that opens complaining is noise.
@Test("an empty field shows no complaint")
func emptyHasNoMessage() {
    #expect(CoordinateInput.Defect.empty.message == nil)
}

@Test("the range message names whole-degree bounds")
func rangeMessageReadsInWholeDegrees() {
    let message = CoordinateInput.Defect.outOfRange(SimulatedLocation.latitudeRange).message
    #expect(message == "Must be between -90 and 90.")
}

@Test("an unreadable field says so")
func notANumberHasAMessage() {
    #expect(CoordinateInput.Defect.notANumber.message == "Enter a number.")
}

// MARK: - Combined

@Test("both fields together build a coordinate")
func buildsALocation() {
    let location = CoordinateInput.location(
        latitude: "37.7749",
        longitude: "-122.4194",
        locale: .posix
    )
    #expect(location == .coordinate(latitude: 37.7749, longitude: -122.4194))
}

/// One bad field blocks the whole submission. This is what disables
/// the sheet's Set button.
@Test("one bad field yields nothing", arguments: [
    ("91", "-122.4194"),
    ("37.7749", "181"),
    ("", "-122.4194"),
    ("37.7749", "")
])
func aBadFieldBlocksSubmission(latitude: String, longitude: String) {
    #expect(
        CoordinateInput.location(latitude: latitude, longitude: longitude, locale: .posix) == nil
    )
}

/// A typed coordinate is rounded to what the file will store, because
/// applying one also saves it. Keeping the typed digits would set
/// `37.77490001` on the device and save `37.774900`, and the menu
/// matches the daemon's claim by exact equality: the saved row would sit
/// unchecked while a second, unlabeled row appeared for the claim.
@Test("a typed coordinate is canonicalized to the file's precision")
func typedCoordinatesAreCanonical() {
    let location = CoordinateInput.location(
        latitude: "37.77490001",
        longitude: "-122.41940001",
        locale: .posix
    )
    #expect(location == .coordinate(latitude: 37.7749, longitude: -122.4194))
}

/// What gets applied and what gets saved must be the same number.
/// Otherwise the saved row remains unchecked and the claim appears as a
/// second checked row.
@Test("what is applied round-trips through the file unchanged", arguments: [
    ("37.77490001", "-122.41940001"),
    ("0", "0"),
    ("-0.0000001", "-0.0000001"),
    ("89.9999999", "179.9999999")
])
func appliedCoordinateSurvivesTheFile(latitude: String, longitude: String) throws {
    let applied = try #require(
        CoordinateInput.location(latitude: latitude, longitude: longitude, locale: .posix)
    )
    guard case let .coordinate(lat, lon) = applied else {
        Issue.record("expected a coordinate")
        return
    }
    let line = LocationsFileParser.line(
        for: .coordinate(latitude: lat, longitude: lon, label: nil)
    )
    let entry = LocationsFileParser.entry(from: line, relativeTo: "/tmp")
    guard case let .coordinate(readLat, readLon, _) = entry else {
        Issue.record("expected a coordinate entry, got \(String(describing: entry))")
        return
    }
    #expect(SimulatedLocation.coordinate(latitude: readLat, longitude: readLon) == applied)
}

/// A location built here is already inside the ranges the wire type
/// validates, so the sheet can never produce a set the daemon rejects
/// as `invalidParams`.
@Test("what the sheet produces is always wire-valid", arguments: [
    ("90", "180"), ("-90", "-180"), ("0", "0")
])
func producesWireValidLocations(latitude: String, longitude: String) throws {
    let location = try #require(
        CoordinateInput.location(latitude: latitude, longitude: longitude, locale: .posix)
    )
    #expect(location.defect == nil)
}

private extension Locale {
    /// Fixed locale so these assertions don't depend on the host's.
    static let posix = Locale(identifier: "en_US_POSIX")
}
