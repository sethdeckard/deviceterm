// SPDX-License-Identifier: GPL-3.0-or-later
//
// LocationAlert: what a Location-menu failure tells the user.
//
// Shared by the two kinds of action whose failures the menu cannot
// report on its own, for two different reasons. Most rows need no alert
// at all: picking a trip or a saved point leaves the checkmark visibly
// where it was, and that is the report.
//
// **The Use My Location row never carries a checkmark.** A success
// checks a matching saved row, or appends a coordinate row elsewhere in
// the menu, so a failure leaves that row looking exactly as it would
// have if nothing had happened.
//
// **A `.gpx` row does carry one**, and it behaves like any other: it
// moves on success and stays put on failure. What it cannot express is
// *why* a route did not play, and a route's failures are mostly about
// the file rather than the device (missing, unreadable, several
// journeys in one). No checkmark can say which, so those are told
// directly.
//
// The wording lives in pure decision namespaces beside this
// (`UseMyLocationDecision`, `RouteFileDecision`) and the view controller
// does the presenting, so nothing about the phrasing needs AppKit to be
// tested.

import Foundation

/// The content of an alert raised from the Location menu.
struct LocationAlert: Equatable, Sendable {
    let title: String
    let body: String
    /// The System Settings pane that would let the user fix this, or nil
    /// when there is nothing there for them to change. Offering the link
    /// on an outcome they cannot act on (`restricted`, a missing file, a
    /// transient failure) would send them somewhere that shows no answer.
    let settingsURL: URL?
}
