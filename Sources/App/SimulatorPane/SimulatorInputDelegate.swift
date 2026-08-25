// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import IOSurface
import Metal
import MetalKit
import SurfaceTrace

@MainActor
protocol SimulatorInputDelegate: AnyObject {
    var simulatorPaneSupportsLiveTouchInput: Bool { get }
    /// Whether the daemon advertises the live two-finger stream. Gates
    /// the Option-drag pinch/rotate path; when false, Option-drag falls
    /// through to the normal single-finger behavior.
    var simulatorPaneSupportsMultitouchInput: Bool { get }
    /// Whether this pane can receive edge-tagged system gestures (App
    /// Switcher / home indicator). Simulator-only: a physical-device pane
    /// returns false, so a bottom-edge drag there stays an ordinary touch.
    var simulatorPaneSupportsEdgeGesture: Bool { get }

    func simulatorPaneDidTap(at point: CGPoint)
    /// `edge` is the `IndigoHIDEdge` value when this contact belongs to a
    /// drag that began in the displayed bottom-edge band (so it drives the
    /// system gesture), else `nil` for an ordinary touch. Only meaningful
    /// on `.down`, where the receiver latches it for the drag's lifetime.
    func simulatorPaneDidTouch(at point: CGPoint, phase: TouchPhase, edge: Int?)
    /// Live two-finger contact frame (center-anchored Option-drag).
    /// `finger1` is the mouse finger, `finger2` its mirror about screen
    /// center. Phases mirror the single-finger stream.
    func simulatorPaneDidMultitouch(
        phase: TouchPhase,
        finger1: CGPoint,
        finger2: CGPoint
    )
    func simulatorPaneDidSwipe(
        from start: CGPoint,
        to end: CGPoint,
        durationMs: Int
    )
    func simulatorPaneDidPinch(
        fromF1: CGPoint,
        fromF2: CGPoint,
        toF1: CGPoint,
        toF2: CGPoint,
        durationMs: Int
    )
    func simulatorPaneKeyDown(keyCode: UInt16)
    func simulatorPaneKeyUp(keyCode: UInt16)
    /// Pane became the window's first responder, so input is now
    /// routed here. Drives the chrome's focus indication (title
    /// brightening, AppKit border on the wrapper).
    func simulatorPaneDidBecomeFirstResponder()
    /// Pane lost first-responder status. Symmetric to the
    /// becomeFirstResponder hook; chrome dims back.
    func simulatorPaneDidResignFirstResponder()
    /// Unmodified scroll gesture over the pane. The VC decides
    /// whether to dispatch (watch sims drive the crown; phone /
    /// pad / tv sims drop it). `delta` is already in crown units.
    func simulatorPaneDidCrown(delta: Double)
}
