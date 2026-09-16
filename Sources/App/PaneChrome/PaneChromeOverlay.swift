// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import SwiftUI

/// The simulator pane's SwiftUI chrome. A single
/// row of three regions framing a resizable ribbon:
///
///   - Leading (pinned): the drag grip, a vertical capsule marking
///     where to grab the pane. It opens the row to keep the marker
///     clear of the right-anchored ribbon whenever the row has width to
///     spare. The grip is a marker only: `PaneChromeDragHostView` owns
///     dragging from the strip's non-interactive regions.
///   - Left (pinned): status badge + truncating title.
///   - Right (anchored): the ribbon control proper, holding the chevron
///     resize handle (tap to jump between the end stops, drag to move between
///     reveal stops), the ribbon contents (at the narrowest stop the hot
///     action when there is one, otherwise as much of the family-aware row as
///     the current stop reveals), and the ⋯ overflow on the trailing side. The
///     whole ribbon is anchored to the right edge of the chrome with a
///     left-rounded / right-flat capsule.
///
/// The contents are a fixed-size row windowed by a trailing-aligned width
/// frame, so a partly revealed button is clipped by the leading edge rather
/// than removed from the row. Keeping the row's membership constant is what
/// lets the width animate: SwiftUI interpolates a `.frame(width:)` on a
/// stable view tree, where a `ForEach` gaining and losing members pops. The
/// narrowest stop is the one exception: it trades the row for the hot action,
/// fading between the two, or fades the row out alone when there is no hot
/// action to trade for.
///
/// At most one ribbon action is "hot" at a time, and it is the one the
/// narrowest stop shows. Stateful toggles (AX inspector, recording) become hot
/// while active and stay hot until turned off, whatever the pane's
/// capabilities admit, so their off-switch stays reachable. Otherwise the
/// last-used action takes over when the pane still supports it, and the
/// highest-priority action it does support when it does not. With neither
/// toggle active and no supported action, there is no hot action at all.
///
/// Hotness is not a tint. Only an active toggle is theme-tinted with the
/// ghostty `selection-background` color (fallback `controlAccentColor`); every
/// other hot button renders like the rest of the row. The ⋯ overflow is never
/// hot.
///
/// Per AGENTS.md SwiftUI/AppKit boundary: this surface is pure render
/// state + action callbacks, so SwiftUI is correct here. The action
/// closures route to `SimulatorPaneViewController` intent methods,
/// which delegate to `SimulatorPaneViewModel`'s pre-existing input
/// surface, so there is no duplication of business logic in the chrome.
struct PaneChromeOverlay: View {
    /// Which cursor the ribbon has pushed. Held as a case rather than the
    /// `NSCursor` itself so nothing non-`Sendable` sits in `@State`.
    private enum RibbonCursor {
        case arrow
        case resize
    }

    /// The ghostty selection-background color (fallback to system accent) for
    /// the on-state tint an active toggle carries. Shared across every ribbon
    /// control that needs the theme color.
    private static var themeTint: Color {
        let fallback = NSColor.controlAccentColor
        return Color(nsColor: GhosttyThemeColors.cachedSelectionBackground() ?? fallback)
    }

    /// Grip opacity with the pointer elsewhere. Faint rather than
    /// absent: a pane that hides its drag affordance until hovered
    /// gives no one a reason to hover there in the first place.
    private static let handleRestOpacity: Double = 0.18
    /// Grip opacity with the pointer over the chrome row.
    private static let handleHoverOpacity: Double = 0.55

    /// Spring the ribbon moves between rungs with.
    ///
    /// Critically damped, so it arrives and stops. An under-damped spring
    /// overshoots the rung and comes back, which at either end of the ladder
    /// has nowhere to go and reads as the control wobbling rather than
    /// landing.
    private static let ribbonSettle: Animation = .spring(
        response: 0.25,
        dampingFraction: 1.0
    )

    let viewModel: PaneChromeViewModel
    @State private var isHovering = false
    /// Latched once a press on the chevron clears the drag threshold. What
    /// separates a click from a drag: `onEnded` with this still down is a
    /// click, because a drag that returned to its origin would otherwise
    /// read as one.
    @State private var handleDragArmed = false
    /// Rung the live drag counts its detents from, captured when the drag arms
    /// and held until it ends. Counting from the rendered stop instead would
    /// re-base after every crossing, so each detent would advance the ribbon
    /// further than the last.
    @State private var handleDragOrigin: Int?
    /// Weighted travel accumulated over the live drag, in the same sign as raw
    /// pointer translation. Speed gearing makes each delta worth its raw length
    /// or more, so the total cannot be recovered from the gesture's own
    /// translation and has to be summed as the deltas arrive.
    @State private var handleDragTravel: CGFloat = 0
    /// Raw translation at the previous gesture update, which is what turns
    /// SwiftUI's cumulative translation into the per-event delta the gearing
    /// needs.
    @State private var handleDragLastTranslation: CGFloat = 0
    /// Which cursor this view currently has pushed, nil when none. Exactly
    /// one push stays outstanding at a time; see `applyCursor`.
    @State private var pushedCursor: RibbonCursor?

    var body: some View {
        // Spacing here comes from `PaneChromeRibbonFit`, which also
        // predicts which reveal stops fit alongside an untruncated title.
        // Shared constants so a tweak here can't leave that prediction
        // stale.
        HStack(spacing: 0) {
            dragGrip
            badgeAndTitle
                .allowsHitTesting(false)
                .padding(.leading, PaneChromeRibbonFit.handleTrailingGap)
            Spacer(minLength: PaneChromeRibbonFit.minimumTitleGap)
            ribbonControl
        }
        .frame(height: PaneChromeRibbonFit.chromeRowHeight)
        .background(GhosttyThemeColors.backgroundSwiftUI(opacity: 1.0))
        .onHover { isHovering = $0 }
    }

    /// The drag affordance: a vertical capsule opening the row, ahead
    /// of the status badge. Purely a marker, so it declines hits and
    /// lets them reach `PaneChromeDragHostView`, which handles dragging
    /// from the strip's non-interactive regions and supplies the
    /// openHand cursor.
    ///
    /// `layoutPriority` keeps the grip from being the thing that gives when the
    /// row runs out of width: the title truncates instead, which is what it is
    /// already built to do. The fit cap keeps a chosen stop from causing that,
    /// so what is left is a pane too narrow for even stop 0 and any drift in
    /// the measured widths.
    private var dragGrip: some View {
        Capsule()
            .fill(Color.secondary)
            .frame(
                width: PaneChromeRibbonFit.handleWidth,
                height: PaneChromeRibbonFit.handleHeight
            )
            .opacity(isHovering ? Self.handleHoverOpacity : Self.handleRestOpacity)
            // Keep this animation on the grip: applying it to the row also
            // animates the ribbon's width, so a hover change landing mid-drag
            // animates the reveal a second time on top of its own spring.
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .padding(.leading, PaneChromeRibbonFit.leadingPadding)
            .layoutPriority(1)
            .help("Drag to rearrange pane")
            .allowsHitTesting(false)
    }

    /// The ribbon control proper, anchored to the trailing edge of the chrome
    /// with a left-rounded / right-flat capsule. Always lays out three regions:
    /// the chevron resize handle, the content viewport, and the ⋯ overflow. At
    /// stop 0 the viewport shows `hotAction` when there is one.
    private var ribbonControl: some View {
        HStack(spacing: PaneChromeRibbonFit.ribbonItemSpacing) {
            chevronHandle
            ribbonViewport
            chromeControlButton(
                systemImage: "ellipsis.circle",
                help: "Pane Actions",
                action: viewModel.onOpenContextMenu
            )
        }
        .padding(.horizontal, PaneChromeRibbonFit.ribbonHorizontalPadding)
        .padding(.vertical, 2)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 14,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(.regularMaterial)
        )
        // One cursor owner for the whole ribbon. The AppKit drag host paints
        // openHand across the entire chrome, so the ribbon pushes over it:
        // the resize cursor in the handle zone, the arrow everywhere else.
        // Tracking the zone here rather than with a second `onHover` on the
        // handle is deliberate, since SwiftUI does not order two exits and
        // an unbalanced pop would reach past the host's own cursor.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let overHandle = PaneChromeRibbonFit.chevronHandleZone.contains(point.x)
                applyCursor(handleDragArmed || overHandle ? .resize : .arrow)

            case .ended:
                applyCursor(nil)
            }
        }
    }

    /// The chevron, doubling as the ribbon's resize handle.
    ///
    /// The glyph draws at its own 10pt width so `PaneChromeRibbonFit`'s
    /// measurement stays true, and an `.overlay` widens only the grabbable
    /// region. `.overlay` cannot change the parent's size, which is the
    /// property being relied on; framing the glyph wider would make the fit
    /// math lie about the row.
    ///
    /// Not a `Button`: a `Button` and a `DragGesture` fight over the same
    /// press, and one gesture handling both is unambiguous. The
    /// accessibility traits below put back what dropping `Button` removes,
    /// and the adjustable action reaches intermediate stops that a two-state
    /// button never could.
    private var chevronHandle: some View {
        Image(systemName: viewModel.ribbonExpanded ? "chevron.right" : "chevron.left")
            .font(.system(size: PaneChromeRibbonFit.chevronFontSize, weight: .medium))
            .foregroundStyle(.secondary)
            .overlay {
                // Spans the row's full height on purpose. The AppKit hit-test
                // override withholds this whole column from the pane-drag host
                // on x alone, so a target only as tall as the glyph would
                // leave a band near the row's edges where the drag is refused
                // and the gesture never offered it either.
                Color.clear
                    .frame(
                        width: PaneChromeRibbonFit.chevronHandleWidth,
                        height: PaneChromeRibbonFit.chromeRowHeight
                    )
                    .contentShape(Rectangle())
                    .gesture(handleDrag)
            }
            .help(viewModel.ribbonExpanded
                ? "Drag to resize, click to collapse"
                : "Drag to resize, click to expand")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Ribbon Width")
            .accessibilityValue("\(viewModel.ribbonRenderedStop) of \(viewModel.ribbonWidestStop)")
            // `.isButton` announces the role but supplies no activation
            // behavior, so a gesture-backed element needs an explicit default
            // action or activating it does nothing.
            .accessibilityAction {
                withAnimation(Self.ribbonSettle) {
                    viewModel.toggleRibbonExtremes()
                }
            }
            .accessibilityAdjustableAction { direction in
                // Steps from the *rendered* stop, not the chosen one: on a pane
                // clamped narrow those differ, and stepping from a choice the
                // pane cannot honor would land back where it started.
                switch direction {
                case .increment:
                    adjust(to: viewModel.ribbonRenderedStop + 1)

                case .decrement:
                    adjust(to: viewModel.ribbonRenderedStop - 1)

                @unknown default:
                    break
                }
            }
    }

    /// The ribbon's content window: the full row, held at its ideal size and
    /// revealed from the trailing edge by a width frame.
    ///
    /// Order in the modifier stack carries weight. `fixedSize` comes first so
    /// the row takes its ideal width instead of compressing its spacing or
    /// squeezing the size-preset menu when handed a narrower proposal.
    /// `.frame(width:)` then reports exactly that width upward whatever the
    /// child overflows, which is also what makes the capsule background track
    /// the live width with no separate plumbing. `.clipped()` has to sit
    /// outside the frame to crop what spills.
    ///
    /// Clipping hides the overflow without disarming it, so the buttons carry
    /// their own hit gating rather than trusting the clip.
    private var ribbonViewport: some View {
        let stop = viewModel.ribbonRenderedStop
        let atHotAction = stop == 0
        let dragging = viewModel.ribbonDragStop != nil
        return ZStack(alignment: .trailing) {
            fullActionRow
                .opacity(atHotAction ? 0 : 1)
                .allowsHitTesting(!atHotAction && !dragging)
            // With no hot action, the narrowest stop leaves its action slot
            // empty rather than drawing a control that cannot act. The
            // size-preset menu lives one stop wider.
            if let hot = viewModel.hotAction {
                ribbonActionButton(hot)
                    .opacity(atHotAction ? 1 : 0)
                    .allowsHitTesting(atHotAction && !dragging)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(
            width: PaneChromeRibbonFit.contentWidth(stop: stop),
            alignment: .trailing
        )
        .clipped()
    }

    /// Every action plus the size-preset menu, in fixed display order.
    ///
    /// Membership never changes with the reveal stop; only how much of the row
    /// the viewport uncovers does. Buttons the stop has not reached decline
    /// hits, because clipping a SwiftUI row hides the overflow without
    /// disarming it, and a button cropped away must not answer a click.
    private var fullActionRow: some View {
        let actions = viewModel.ribbonActions
        let revealed = PaneChromeRibbonFit.revealedActionCount(
            stop: viewModel.ribbonRenderedStop
        )
        return HStack(spacing: PaneChromeRibbonFit.contentItemSpacing) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                // The row reveals from the trailing end, so the last actions
                // are the ones on screen.
                ribbonActionButton(action)
                    .allowsHitTesting(actions.count - index <= revealed)
            }
            sizePresetMenu
        }
    }

    // MARK: - Subviews (computed)

    private var badgeAndTitle: some View {
        HStack(spacing: PaneChromeRibbonFit.badgeTitleSpacing) {
            StatusBadgeView(state: viewModel.simState)
                .frame(
                    width: PaneChromeRibbonFit.badgeSize,
                    height: PaneChromeRibbonFit.badgeSize
                )
            Text(viewModel.title)
                .font(.system(size: PaneChromeRibbonFit.titleFontSize, weight: .medium))
                .foregroundStyle(.primary)
                .opacity(viewModel.isFocused ? 1.0 : 0.65)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(viewModel.title)
        }
    }

    /// Widest rung this drag can reach: the widest the pane currently fits, or
    /// stop 0 as the fallback when it fits none. Dragging therefore cannot park
    /// the ribbon over the device name, except on a pane too narrow to keep the
    /// name whole at any stop, where stop 0 is the least bad answer.
    private var reachableStop: Int {
        let offered = viewModel.ribbonWidestStop
        let cap = viewModel.ribbonWidestFittingStop ?? offered
        return max(0, min(cap, offered))
    }

    /// Rung the drag counts detents from, which is what is on screen rather
    /// than what was chosen: a pane clamped narrow starts from the clamped
    /// rung.
    ///
    /// Held for the life of the gesture in `handleDragOrigin`, because the
    /// rendered stop moves as the drag steps and counting from a moving origin
    /// would compound every step.
    private var committedStop: Int {
        handleDragOrigin ?? viewModel.ribbonRenderedStop
    }

    /// One gesture serving both a click and a detented resize.
    ///
    /// `minimumDistance: 0` makes `onChanged` fire on the press itself, which
    /// is what lets the same gesture answer for both. Below the threshold
    /// `onChanged` leaves the model untouched; `onEnded` then treats the
    /// release as a click.
    private var handleDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Arms on total travel, the same measure
                // `PaneChromeDragHostView` uses, so a press dragged mostly
                // downward counts as a drag rather than falling through to the
                // click branch and toggling on release. Detents still come
                // from horizontal travel alone, so an arming drag that never
                // moved sideways simply holds its rung.
                let travelled = hypot(value.translation.width, value.translation.height)
                guard handleDragArmed
                    || travelled >= PaneChromeRibbonFit.dragActivationDistance
                else { return }
                if !handleDragArmed {
                    handleDragArmed = true
                    handleDragOrigin = viewModel.ribbonRenderedStop
                    handleDragTravel = 0
                    // Only the activation distance is spent, not the whole
                    // update that cleared it; see `armingTranslation`.
                    handleDragLastTranslation = PaneChromeRibbonDragMath
                        .armingTranslation(translation: value.translation)
                }
                handleDragTravel += PaneChromeRibbonDragMath.weightedDelta(
                    rawDelta: value.translation.width - handleDragLastTranslation,
                    pointerSpeed: abs(value.velocity.width)
                )
                handleDragLastTranslation = value.translation.width
                let stop = PaneChromeRibbonDragMath.detentStop(
                    originStop: committedStop,
                    currentStop: viewModel.ribbonRenderedStop,
                    weightedTranslation: handleDragTravel,
                    widestStop: reachableStop
                )
                guard stop != viewModel.ribbonRenderedStop else { return }
                // Animated per crossing: the width only moves at a detent, so
                // each step is one short spring rather than a continuous
                // re-layout.
                withAnimation(Self.ribbonSettle) {
                    viewModel.trackRibbonDrag(stop: stop)
                }
            }
            .onEnded { value in
                let wasDrag = handleDragArmed
                let origin = committedStop
                let accumulated = handleDragTravel
                let lastTranslation = handleDragLastTranslation
                handleDragArmed = false
                handleDragOrigin = nil
                handleDragTravel = 0
                handleDragLastTranslation = 0
                guard wasDrag else {
                    withAnimation(Self.ribbonSettle) {
                        viewModel.toggleRibbonExtremes()
                    }
                    return
                }
                // The release carries its own translation, and nothing promises
                // a change callback delivered every point of it, so the final
                // segment is folded in here. It is zero when the two agree.
                let travel = accumulated + PaneChromeRibbonDragMath.weightedDelta(
                    rawDelta: value.translation.width - lastTranslation,
                    pointerSpeed: abs(value.velocity.width)
                )
                let landed = PaneChromeRibbonDragMath.detentStop(
                    originStop: origin,
                    currentStop: viewModel.ribbonRenderedStop,
                    weightedTranslation: travel,
                    widestStop: reachableStop
                )
                settle(
                    at: PaneChromeRibbonDragMath.releaseStop(
                        detentStop: landed,
                        pointerVelocity: value.velocity.width,
                        widestStop: reachableStop
                    )
                )
            }
    }

    /// Size-preset dropdown. It occupies stop 1 and stays visible at every
    /// wider stop, since it is the row's trailing item. Checkmark next to
    /// the active selection.
    private var sizePresetMenu: some View {
        Menu {
            ForEach(SimSizePreset.allCases, id: \.self) { preset in
                Button {
                    viewModel.onSizePresetSelected(preset)
                } label: {
                    Label(
                        preset.displayName,
                        systemImage: viewModel.selectedPreset == preset
                            ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Image(systemName: "rectangle.compress.vertical")
                .help("Size Preset")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(
            width: PaneChromeRibbonFit.sizePresetWidth,
            height: PaneChromeRibbonFit.controlButtonWidth
        )
    }

    // MARK: - Methods

    /// Step the ribbon one rung for an accessibility adjustment, and do nothing
    /// at all when the pane cannot honor the step.
    ///
    /// A plain settle would clamp an outward step at the fit cap back onto the
    /// rung already showing, which moves nothing yet still overwrites a wider
    /// remembered choice. Refusing the step keeps that choice, so widening the
    /// pane still restores it.
    private func adjust(to stop: Int) {
        let clamped = min(max(stop, 0), reachableStop)
        guard clamped != viewModel.ribbonRenderedStop else { return }
        settle(at: clamped)
    }

    /// Land the ribbon on a rung with the settle animation, clamped to the
    /// rungs this pane currently offers.
    private func settle(at stop: Int) {
        withAnimation(Self.ribbonSettle) {
            viewModel.settleRibbon(at: min(max(stop, 0), reachableStop))
        }
    }

    /// Keep exactly one cursor push outstanding: pop before pushing a
    /// different one, pop on exit, do nothing when it has not changed.
    ///
    /// One owner for the whole ribbon, because SwiftUI does not order nested
    /// hover exits: with a second push/pop pair on the handle, a pointer leaving
    /// both in one move can unbalance the stack. An unbalanced pop does not stop
    /// at this view either, it reaches past the drag host's openHand cursor
    /// rect.
    private func applyCursor(_ cursor: RibbonCursor?) {
        guard cursor != pushedCursor else { return }
        if pushedCursor != nil {
            NSCursor.pop()
        }
        pushedCursor = cursor
        switch cursor {
        case .resize:
            NSCursor.resizeLeftRight.push()

        case .arrow:
            NSCursor.arrow.push()

        case nil:
            break
        }
    }

    private func ribbonActionButton(_ action: SimChromeAction) -> some View {
        // On-state toggles (AX inspector active, recording active)
        // get the theme tint so the user can see the active state at
        // a glance. Other actions render in primary foreground, so the
        // "hot" / last-used button looks the same as the rest.
        let tint: Color? = {
            switch action {
            case .axInspector where viewModel.axInspectorEnabled:
                return Self.themeTint

            case .record where viewModel.recordingActive:
                return Self.themeTint

            default:
                return nil
            }
        }()
        return chromeControlButton(
            systemImage: action.systemImage(
                recording: viewModel.recordingActive,
                axOn: viewModel.axInspectorEnabled
            ),
            help: action.helpText(
                recording: viewModel.recordingActive,
                axOn: viewModel.axInspectorEnabled
            ),
            tint: tint,
            action: { performAction(action) }
        )
    }

    /// Dispatch a ribbon action through the view model and stamp it
    /// as the new last-used so the narrowest reveal stop tracks the recent
    /// pattern. Toggles update `recordingActive` / `axInspectorEnabled`
    /// on the next render pass via the VC's `render()`, so the tint
    /// follows automatically.
    private func performAction(_ action: SimChromeAction) {
        viewModel.lastUsedAction = action
        switch action {
        case .home:
            viewModel.onHardwareButton(.home)

        case .lock:
            viewModel.onHardwareButton(.lock)

        case .side:
            viewModel.onHardwareButton(.side)

        case .siri:
            viewModel.onHardwareButton(.siri)

        case .applePay:
            viewModel.onHardwareButton(.applePay)

        case .rotateLeft:
            viewModel.onRotateLeft()

        case .rotateRight:
            viewModel.onRotateRight()

        case .screenshot:
            viewModel.onScreenshot()

        case .record:
            viewModel.onRecordToggle()

        case .axInspector:
            viewModel.onAxInspectorToggle()

        case .crownPress:
            viewModel.onHardwareButton(.digitalCrown)

        case .crownUp:
            viewModel.onCrownUp()

        case .crownDown:
            viewModel.onCrownDown()
        }
    }

    /// Shared shape for the ribbon's buttons and the ⋯ overflow.
    /// Tint optional so callers can mark hot or stateful buttons with
    /// the theme color. Custom ButtonStyle interfered with action
    /// firing; `.borderless` is the reliable choice, and press feedback
    /// is the borderless default (subtle highlight on click).
    /// `contentShape` covers the whole 22×22 frame so taps in the
    /// gaps of thin SF symbol strokes still register.
    private func chromeControlButton(
        systemImage: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint ?? Color.primary)
                .frame(
                    width: PaneChromeRibbonFit.controlButtonWidth,
                    height: PaneChromeRibbonFit.controlButtonWidth
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - SimChromeAction → SF Symbol mapping

private extension SimChromeAction {
    func systemImage(recording: Bool, axOn: Bool) -> String {
        switch self {
        case .home:
            return "house"

        case .lock:
            return "lock"

        case .side:
            return "powersleep"

        case .siri:
            return "waveform"

        case .applePay:
            return "creditcard"

        case .rotateLeft:
            return "rotate.left"

        case .rotateRight:
            return "rotate.right"

        case .screenshot:
            return "camera"

        case .record:
            return recording ? "stop.circle.fill" : "record.circle"

        case .axInspector:
            return axOn ? "rectangle.dashed.badge.record" : "rectangle.dashed"

        case .crownPress:
            return "circle.circle"

        case .crownUp:
            return "arrow.up"

        case .crownDown:
            return "arrow.down"
        }
    }

    func helpText(recording: Bool, axOn: Bool) -> String {
        switch self {
        case .home:
            return "Home"

        case .lock:
            return "Lock"

        case .side:
            return "Side Button"

        case .siri:
            return "Siri"

        case .applePay:
            return "Apple Pay"

        case .rotateLeft:
            return "Rotate Left"

        case .rotateRight:
            return "Rotate Right"

        case .screenshot:
            return "Screenshot"

        case .record:
            return recording ? "Stop Recording" : "Record Screen"

        case .axInspector:
            return axOn ? "Disable AX Inspector" : "Enable AX Inspector"

        case .crownPress:
            return "Crown Press"

        case .crownUp:
            return "Crown Rotate Up"

        case .crownDown:
            return "Crown Rotate Down"
        }
    }
}

private extension PaneChromeOverlay {
    /// Status badge: small colored indicator showing the sim's lifecycle
    /// state. Mirrors the four `SimulatorPaneState` cases:
    ///
    ///   .booting → spinning ProgressView (no fixed color; system-tint).
    ///   .rendering → solid green dot.
    ///   .shutdown → solid gray dot.
    ///   .failed → solid red dot.
    ///
    /// Sized 12x12 by the caller's `.frame()` modifier; we just paint the
    /// shape.
    struct StatusBadgeView: View {
        let state: SimulatorPaneState

        var body: some View {
            switch state {
            case .booting:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.6)

            case .rendering:
                Circle().fill(.green)

            case .shutdown:
                Circle().fill(.gray)

            case .failed:
                Circle().fill(.red)
            }
        }
    }
}
