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
    static let pressAction = "AXPress"

    static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return error == .success ? value : nil
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

    /// Screen frame in top-left origin coordinates (AX's convention).
    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let rawPosition = copyAttribute(element, AXAttribute.position),
            let rawSize = copyAttribute(element, AXAttribute.size),
            let positionValue = axValue(rawPosition),
            let sizeValue = axValue(rawSize)
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
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
