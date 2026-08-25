// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// LocationsFileParserTests: the line grammar of the locations file.
//
// Two rules carry the most weight. A line this version can't read is
// *not* an entry and *not* an error, which is what lets an unrecognized
// line survive a write. And parsing is POSIX-only: the file means the
// same thing to everyone who opens it, unlike the sheet's typed input.

/// A base directory only route lines use; coordinate lines ignore it.
private let base = "/config"

private func parse(_ line: String) -> LocationEntry? {
    LocationsFileParser.entry(from: line, relativeTo: base)
}

// MARK: - Reading

@Test("a bare coordinate pair parses")
func parsesBarePair() {
    #expect(
        parse("37.7749,-122.4194")
            == .coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)
    )
}

@Test("a label runs to the end of the line and may contain spaces")
func parsesMultiWordLabel() {
    #expect(
        parse("51.5072,-0.1276 London  Bridge")
            == .coordinate(latitude: 51.5072, longitude: -0.1276, label: "London  Bridge")
    )
}

@Test("surrounding whitespace is ignored")
func toleratesWhitespace() {
    #expect(
        parse("   64.1466 , -21.9426    Reykjavík   ")
            == .coordinate(latitude: 64.1466, longitude: -21.9426, label: "Reykjavík")
    )
}

/// A CRLF file leaves `\r` on the end of every line once `LocationsFile`
/// splits on `\n`. Without trimming newlines too, the label of every
/// entry would carry an invisible character, and a bare pair would come
/// back labeled with one.
@Test("a CRLF line ending is not part of the entry")
func handlesCRLF() {
    #expect(
        parse("37.7749,-122.4194\r")
            == .coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)
    )
    #expect(
        parse("37.7749,-122.4194 Home\r")
            == .coordinate(latitude: 37.7749, longitude: -122.4194, label: "Home")
    )
}

@Test("blank lines and comments are not entries", arguments: [
    "", "   ", "# a comment", "   # indented comment", "#37.7749,-122.4194"
])
func skipsBlanksAndComments(line: String) {
    #expect(parse(line) == nil)
}

/// The forward-compatibility case, and the reason a route line must
/// carry the `.gpx` suffix to count. A line this version can't read is
/// not an entry and not an error; `LocationsFile` keeps it verbatim
/// either way. Treating *every* unreadable line as a path would render a
/// line written by a newer deviceterm as a broken route.
@Test("an unrecognized line is simply not an entry", arguments: [
    "~/routes/commute.kml",
    "~/routes/commute.gpx.bak",
    "polygon 37.7749,-122.4194 51.5072,-0.1276",
    ".gpx",
    "37.7749",
    "37.7749,",
    ",-122.4194",
    "37.7749,-122.4194,0",
    "north,west",
    "91.0,-122.4194",
    "37.7749,181.0",
    "nan,-122.4194",
    "inf,inf"
])
func unrecognizedLinesYieldNoEntry(line: String) {
    #expect(parse(line) == nil)
}

/// Parsing is locale-independent on purpose: a config file has one
/// meaning no matter who opens it. `37,75` is the *pair* (37, 75) here,
/// never the decimal `37.75` that a German-locale sheet would accept
/// from the same keystrokes.
@Test("the file format is POSIX, not locale-aware")
func fileFormatIsPOSIX() {
    #expect(parse("37,75") == .coordinate(latitude: 37, longitude: 75, label: nil))
}

/// The menu renders coordinates with a space after the comma, so that
/// spelling has to survive being pasted back into the file.
@Test("the displayed spelling can be pasted back")
func acceptsTheDisplayedSpelling() {
    let displayed = LocationMenuModel.formatCoordinate(latitude: 37.7749, longitude: -122.4194)
    #expect(parse(displayed) == .coordinate(latitude: 37.7749, longitude: -122.4194, label: nil))
}

// MARK: - Writing

@Test("an entry renders at the file's precision")
func rendersAtFilePrecision() {
    let line = LocationsFileParser.line(
        for: .coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)
    )
    #expect(line == "37.774900,-122.419400")
}

@Test("a label is appended after the pair")
func rendersLabel() {
    let line = LocationsFileParser.line(
        for: .coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco")
    )
    #expect(line == "37.774900,-122.419400 San Francisco")
}

/// The round trip that keeps the file honest: entries representable at
/// the file's six-decimal precision come back unchanged.
@Test("a written line reads back as the same entry", arguments: [
    (37.7749, -122.4194, "San Francisco"),
    (-33.8688, 151.2093, nil),
    (0.0, 0.0, "Null Island"),
    (90.0, 180.0, nil),
    (-90.0, -180.0, nil)
])
func writtenLinesRoundTrip(latitude: Double, longitude: Double, label: String?) {
    let entry = LocationEntry.coordinate(latitude: latitude, longitude: longitude, label: label)
    #expect(parse(LocationsFileParser.line(for: entry)) == entry)
}

// MARK: - Dedup

/// The dedup key is the rendered pair, so "already saved" means exactly
/// "coordinates render to the same pair token", with no second notion of
/// equality to drift from it.
@Test("coordinates that render alike share a key")
func dedupKeyFollowsRendering() {
    let typed = LocationEntry.coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)
    // Differs only below the file's precision.
    let finer = LocationEntry.coordinate(
        latitude: 37.77490001,
        longitude: -122.41940001,
        label: nil
    )
    #expect(LocationsFileParser.dedupKey(for: typed) == LocationsFileParser.dedupKey(for: finer))
}

/// Labels are excluded from the key: saving a place you already have
/// under a new name should not add a second row pointing at it.
@Test("a different label is the same location")
func labelDoesNotAffectDedup() {
    let unnamed = LocationEntry.coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)
    let named = LocationEntry.coordinate(
        latitude: 37.7749,
        longitude: -122.4194,
        label: "San Francisco"
    )
    #expect(LocationsFileParser.dedupKey(for: unnamed) == LocationsFileParser.dedupKey(for: named))
}

/// `-0.0 == 0.0` is true in IEEE, so the menu already treats them as one
/// place. `%f` renders them as different tokens, though, which would let
/// the same location occupy two rows that refuse to deduplicate. The
/// canonical form collapses the sign so both notions of equality agree.
/// Includes the values that only *become* negative zero by rounding,
/// which is the realistic way to get one: a position just south of the
/// equator is not `-0.0` on the way in, but formats to `-0.000000` and
/// reads back as one. Normalizing before rounding would catch only the
/// exact `-0.0` case and miss every one of these.
@Test("negative zero is the same saved location as zero", arguments: [
    -0.0, -0.0000001, -1e-9, -0.0000004
])
func negativeZeroCanonicalizes(input: Double) {
    let negative = LocationEntry.coordinate(latitude: input, longitude: input, label: nil)
    let positive = LocationEntry.coordinate(latitude: 0.0, longitude: 0.0, label: nil)
    #expect(LocationsFileParser.dedupKey(for: negative) == LocationsFileParser.dedupKey(for: positive))
    #expect(LocationsFileParser.line(for: negative) == LocationsFileParser.line(for: positive))
    // And the canonical value itself, not just its rendering, so a
    // coordinate applied to the device carries no negative zero either.
    #expect(LocationsFileParser.canonical(input).sign == .plus)
}

/// Canonicalizing is idempotent: the value is already what the file
/// would store, so storing it again changes nothing.
@Test("canonicalizing twice is the same as once", arguments: [
    37.77490001, -122.41940001, 0.0, -0.0, 89.9999999, -180.0, 1.0 / 3.0
])
func canonicalIsIdempotent(input: Double) {
    let once = LocationsFileParser.canonical(input)
    #expect(LocationsFileParser.canonical(once) == once)
}

/// The canonical value is defined as "parse what we would have written",
/// so it survives the file by construction rather than by two roundings
/// happening to break ties the same way. Pairs are valid for their own
/// field: -180 is a longitude, never a latitude.
@Test("a canonical pair renders and re-reads as itself", arguments: [
    (37.77490001, -122.41940001),
    (0.0, 0.0),
    (-0.0, -0.0),
    (89.9999999, 179.9999999),
    (-90.0, -180.0),
    (1.0 / 3.0, 2.0 / 3.0)
])
func canonicalPairsSurviveTheFile(latitude: Double, longitude: Double) {
    let entry = LocationEntry.coordinate(
        latitude: LocationsFileParser.canonical(latitude),
        longitude: LocationsFileParser.canonical(longitude),
        label: nil
    )
    let line = LocationsFileParser.line(for: entry)
    #expect(LocationsFileParser.entry(from: line, relativeTo: base) == entry)
}

@Test("distinct positions have distinct keys")
func distinctPositionsDiffer() {
    let first = LocationEntry.coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)
    let second = LocationEntry.coordinate(latitude: 51.5072, longitude: -0.1276, label: nil)
    #expect(LocationsFileParser.dedupKey(for: first) != LocationsFileParser.dedupKey(for: second))
}

/// East and west of the meridian are different places, so the sign is
/// part of the key. The one exception is zero, where `-0.0` and `0.0`
/// name the same point and are deliberately collapsed
/// (`negativeZeroCanonicalizes`).
@Test("a flipped sign is a different location")
func signMatters() {
    let east = LocationEntry.coordinate(latitude: 37.7749, longitude: 122.4194, label: nil)
    let west = LocationEntry.coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)
    #expect(LocationsFileParser.dedupKey(for: east) != LocationsFileParser.dedupKey(for: west))
}

// MARK: - Route lines

@Test("a bare gpx path parses as a route")
func parsesBareRoutePath() {
    #expect(parse("/routes/commute.gpx") == .route(path: "/routes/commute.gpx", label: nil))
}

@Test("a route label runs to the end of the line")
func parsesRouteLabel() {
    #expect(
        parse("/routes/marathon.gpx Boston  Marathon")
            == .route(path: "/routes/marathon.gpx", label: "Boston  Marathon")
    )
}

/// A path is resolved at parse time, because this is the last point that
/// knows where the locations file lives. Everything downstream gets a
/// path it can open.
@Test("a relative path resolves against the locations file's directory")
func relativeRoutePathResolves() {
    #expect(parse("routes/commute.gpx") == .route(path: "/config/routes/commute.gpx", label: nil))
}

@Test("a tilde path expands to the home directory")
func tildeRoutePathExpands() {
    let expected = ("~/routes/commute.gpx" as NSString).expandingTildeInPath
    #expect(parse("~/routes/commute.gpx") == .route(path: expected, label: nil))
}

/// macOS paths have spaces in them constantly, so a quoted spelling
/// exists for them.
@Test("a quoted path may contain spaces")
func quotedRoutePathMayContainSpaces() {
    #expect(
        parse("\"/my routes/sunday run.gpx\" Sunday Long Run")
            == .route(path: "/my routes/sunday run.gpx", label: "Sunday Long Run")
    )
}

@Test("a quoted path needs no label")
func quotedRoutePathWithoutLabel() {
    #expect(parse("\"/my routes/run.gpx\"") == .route(path: "/my routes/run.gpx", label: nil))
}

/// The reason the quoted spelling exists rather than a rule that guesses
/// where an unquoted path stops. Any such rule reads this line one of
/// two defensible ways, and picking either silently contradicts half the
/// people who write it. Unquoted, the path is the first token, full
/// stop, and the rest is a label however much it looks like a path.
@Test("an unquoted path ends at the first space, whatever follows")
func unquotedRoutePathEndsAtTheFirstSpace() {
    #expect(
        parse("/routes/old.gpx exports/run.gpx Morning")
            == .route(path: "/routes/old.gpx", label: "exports/run.gpx Morning")
    )
}

/// Only the path's own suffix is tested, so a directory named for the
/// extension can't swallow the file inside it.
@Test("a .gpx in a directory name is not the path's end")
func extensionInsideADirectoryNameIsNotSpecial() {
    #expect(
        parse("/gpx.gpx-backups/run.gpx old")
            == .route(path: "/gpx.gpx-backups/run.gpx", label: "old")
    )
}

/// Left unrecognized rather than guessed at, so `LocationsFile`
/// preserves the line instead of rewriting it somewhere the author
/// didn't mean.
///
/// The second case is the one that matters: its remainder *is* a
/// well-formed path, so a lenient reading would happily accept it and
/// only the missing quote says the author meant something else.
@Test("an unterminated quote is not an entry", arguments: [
    "\"/my routes/run.gpx Sunday",
    "\"/my routes/run.gpx"
])
func unterminatedQuoteIsNotAnEntry(line: String) {
    #expect(parse(line) == nil)
}

/// The suffix rule holds under quoting too, so the forward-compat
/// guarantee doesn't have a hole in it.
@Test("a quoted path still needs the .gpx suffix")
func quotedPathStillNeedsTheExtension() {
    #expect(parse("\"/my routes/run.kml\" Sunday") == nil)
}

@Test("the extension match is case-insensitive")
func routeExtensionIsCaseInsensitive() {
    #expect(parse("/routes/RUN.GPX") == .route(path: "/routes/RUN.GPX", label: nil))
}

/// A coordinate wins outright, so a file that happens to be named like
/// a coordinate pair can't shadow one.
@Test("a coordinate line is never read as a path")
func coordinatesWinOverPaths() {
    #expect(
        parse("37.7749,-122.4194 San Francisco.gpx")
            == .coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco.gpx")
    )
}

@Test("a commented route line is not an entry")
func commentedRouteIsNotAnEntry() {
    #expect(parse("# /routes/commute.gpx") == nil)
}

/// Keyed separately from a coordinate token, so a file named like one
/// can never dedup against a saved point. deviceterm never appends a
/// route, so this only appears on the existing-entry side.
@Test("a route's dedup key can't collide with a coordinate's")
func routeKeysAreDistinct() {
    let route = LocationEntry.route(path: "37.774900,-122.419400", label: nil)
    let point = LocationEntry.coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)
    #expect(LocationsFileParser.dedupKey(for: route) != LocationsFileParser.dedupKey(for: point))
}

@Test("two routes at the same path share a key")
func sameRouteSharesAKey() {
    let first = LocationEntry.route(path: "/routes/run.gpx", label: "Run")
    let second = LocationEntry.route(path: "/routes/run.gpx", label: nil)
    #expect(LocationsFileParser.dedupKey(for: first) == LocationsFileParser.dedupKey(for: second))
}

/// `line(for:)` has to be total, and a route renders with the resolved
/// path it carries. Only ever reached in a test: deviceterm appends
/// coordinates and leaves existing route lines verbatim.
@Test("a route entry renders back to a line", arguments: [
    (LocationEntry.route(path: "/routes/run.gpx", label: nil), "/routes/run.gpx"),
    (.route(path: "/routes/run.gpx", label: "Sunday"), "/routes/run.gpx Sunday"),
    // Quoted on the way out too, or what deviceterm writes would not be
    // what it reads back.
    (.route(path: "/my routes/run.gpx", label: nil), "\"/my routes/run.gpx\""),
    (.route(path: "/my routes/run.gpx", label: "Sunday"), "\"/my routes/run.gpx\" Sunday")
])
func routeEntryRenders(entry: LocationEntry, expected: String) {
    #expect(LocationsFileParser.line(for: entry) == expected)
    #expect(LocationsFileParser.entry(from: expected, relativeTo: base) == entry)
}
