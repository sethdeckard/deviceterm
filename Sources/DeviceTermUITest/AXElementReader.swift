// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import CoreGraphics
import Foundation

/// The CoreFoundation plumbing for reading one
/// AXUIElement, shared by the tree dump and the input driver.
///
/// Two Swift-level hazards live here, in one place rather than at every
/// call site:
///   * The SDK's `kAX*Attribute` constants are C globals (`var`), which
///     Swift 6 rejects as shared mutable state, so names are literals.
///   * `CFTypeRef as? AXValue` is rejected as an always-succeeding cast,
///     so every downcast is gated on the CoreFoundation type id first.
enum AXElementReader {
    /// What one attribute read found.
    ///
    /// The distinction that matters is the middle case against the last:
    /// an element that does not carry an attribute and an element whose
    /// attribute could not be read both yield "no value" from
    /// `copyAttribute`, and only one of them is an observation.
    enum AttributeRead {
        case value(CFTypeRef)
        /// The element answers and carries no such attribute. Most elements
        /// publish only a handful, so this is the common case.
        case absent
        /// The read itself failed: a timeout, a stale reference, a target
        /// that stopped answering.
        case failed
    }

    /// What a frame read found. Same three states as `AttributeRead`, with
    /// the rectangle already decoded.
    enum FrameRead {
        case value(CGRect)
        case absent
        case failed
    }

    static let pressAction = "AXPress"

    static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard case let .value(raw) = read(element, name) else { return nil }
        return raw
    }

    /// Read one attribute, keeping "not there" apart from "could not read".
    static func read(_ element: AXUIElement, _ name: String) -> AttributeRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch error {
        case .success:
            guard let value else { return .absent }
            return .value(value)

        // The element answered, and has nothing under this name.
        //
        // `.notImplemented` is deliberately not here: it stays a failure
        // because it does not establish that the attribute is absent.
        case .noValue, .attributeUnsupported:
            return .absent

        default:
            return .failed
        }
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let raw = copyAttribute(element, name) else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return raw as? String
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = copyAttribute(element, name) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyAttribute(element, AXAttribute.children) else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    /// Children, or nil when the *read* failed rather than the element
    /// legitimately having none.
    ///
    /// `children(of:)` folds both into an empty array, which is right for a
    /// tree walk that should degrade rather than abort. A caller deciding
    /// whether something is absent needs them apart: a timed-out read that
    /// reads as "no children" reports absence that was never observed.
    static func childrenIfReadable(of element: AXUIElement) -> [AXUIElement]? {
        // `.failed` covers a stale reference as well as a timeout, and both
        // belong here rather than in the empty case: a menu bar invalidated
        // mid-reflow would otherwise report an empty bar, which is the
        // false-absence this function exists to rule out.
        switch read(element, AXAttribute.children) {
        case let .value(raw):
            // Something came back and it is not a list of elements. That is
            // not an observed childless element, so it fails like an
            // undecodable frame rather than reading as an empty bar.
            guard let children = raw as? [AXUIElement] else { return nil }
            return children

        case .absent:
            return []

        case .failed:
            return nil
        }
    }

    /// Screen frame in top-left origin coordinates (AX's convention), or nil
    /// when the element has no geometry *or* it could not be read. Callers
    /// that must tell those apart use `frameRead(of:)`.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard case let .value(frame) = frameRead(of: element) else { return nil }
        return frame
    }

    /// A frame read, keeping "no geometry" apart from "could not read it".
    ///
    /// Position and size are two reads, so either can fail on its own. A
    /// value that arrives but will not decode counts as failed too: something
    /// came back and it is not a frame, which is not the same as an element
    /// that publishes none.
    static func frameRead(of element: AXUIElement) -> FrameRead {
        let position = read(element, AXAttribute.position)
        let size = read(element, AXAttribute.size)
        if case .failed = position { return .failed }
        if case .failed = size { return .failed }
        guard
            case let .value(rawPosition) = position,
            case let .value(rawSize) = size
        else { return .absent }
        guard
            let positionValue = axValue(rawPosition),
            let sizeValue = axValue(rawSize)
        else { return .failed }

        var origin = CGPoint.zero
        var frameSize = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue, .cgSize, &frameSize)
        else { return .failed }
        return .value(CGRect(origin: origin, size: frameSize))
    }

    static func supportsPress(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success else { return false }
        let names = (actions as? [String]) ?? []
        return names.contains(pressAction)
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, pressAction as CFString) == .success
    }

    /// Coerce an AX attribute into something `JSONSerialization` accepts.
    /// Anything exotic is described rather than dropped, so the shape of a
    /// dumped tree stays legible.
    static func jsonSafe(_ raw: CFTypeRef) -> Any? {
        let typeID = CFGetTypeID(raw)
        if typeID == CFStringGetTypeID() { return raw as? String }
        if typeID == CFNumberGetTypeID() || typeID == CFBooleanGetTypeID() {
            return raw as? NSNumber
        }
        // An element reference says nothing useful in a flat dump.
        if typeID == AXUIElementGetTypeID() { return nil }
        let described = String(describing: raw)
        return described.isEmpty ? nil : described
    }

    private static func axValue(_ raw: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(raw as AnyObject, to: AXValue.self)
    }
}
