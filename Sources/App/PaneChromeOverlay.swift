// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneChromeOverlay: the simulator pane's SwiftUI chrome. A single
// 28pt row with two pinned regions framing a collapsible ribbon:
//
//   - Left (pinned): status badge + truncating title.
//   - Right (anchored): the ribbon control proper, holding a chevron toggle
//     button (tap to expand/collapse), the ribbon contents
//     (last-used action when collapsed, full family-aware set when
//     expanded), and the ⋯ overflow on the trailing side. The whole
//     ribbon is anchored to the right edge of the chrome with a
//     left-rounded / right-flat capsule.
//
// At any moment exactly one ribbon action is the "hot" button,
// theme-tinted with the ghostty `selection-background` color
// (fallback `controlAccentColor`) so the user sees the active focus
// at a glance. Stateful toggles (AX inspector, recording) become
// hot when active and remain hot until turned off, after which the
// last-used action takes over. The ⋯ overflow is never hot.
//
// Per AGENTS.md SwiftUI/AppKit boundary: this surface is pure render
// state + action callbacks, so SwiftUI is correct here. The action
// closures route to `SimulatorPaneViewController` intent methods,
// which delegate to `SimulatorPaneViewModel`'s pre-existing input
// surface, so there is no duplication of business logic in the chrome.

import AppKit
import DaemonProtocol
import SwiftUI

struct PaneChromeOverlay: View {
    /// The ghostty selection-background color (fallback to system
    /// accent) for the hot-button and on-state tint. Shared across
    /// every ribbon control that needs the theme color.
    private static var themeTint: Color {
        let fallback = NSColor.controlAccentColor
        return Color(nsColor: GhosttyThemeColors.cachedSelectionBackground() ?? fallback)
    }

    let viewModel: PaneChromeViewModel
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            // Hover-revealed drag handle, painted FIRST so the ribbon
            // (added second) overlays it whenever the expanded ribbon
            // reaches the middle of the chrome. Aligned to the top of
            // the chrome, just under the focus border, matching the
            // terminal pane handle's position.
            Capsule()
                .fill(Color.secondary)
                .frame(width: 28, height: 3)
                .opacity(isHovering ? 0.55 : 0.0)
                .padding(.top, 3)
                .help("Drag to rearrange pane")
                .allowsHitTesting(false)
            // Spacing here comes from `PaneChromeRibbonFit`, which also
            // predicts whether the expanded ribbon fits alongside an
            // untruncated title. Shared constants so a tweak here can't
            // leave that prediction stale.
            HStack(spacing: 0) {
                badgeAndTitle
                    .allowsHitTesting(false)
                    .padding(.leading, PaneChromeRibbonFit.leadingPadding)
                Spacer(minLength: PaneChromeRibbonFit.minimumTitleGap)
                ribbonControl
            }
        }
        .frame(height: 28)
        .background(GhosttyThemeColors.backgroundSwiftUI(opacity: 1.0))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    /// The ribbon control proper, anchored to the trailing edge of
    /// the chrome with a left-rounded / right-flat capsule. Always
    /// shows three elements: a chevron toggle button (tap to expand
    /// or collapse), the last-used action (when collapsed) or the
    /// full action set (when expanded), and the ⋯ overflow on the
    /// trailing side.
    private var ribbonControl: some View {
        HStack(spacing: PaneChromeRibbonFit.ribbonItemSpacing) {
            Button {
                // Mark the launch-time fit decided before toggling so
                // later layout passes preserve the user's choice.
                viewModel.ribbonExpansionDecided = true
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    viewModel.ribbonExpanded.toggle()
                }
            } label: {
                Image(systemName: viewModel.ribbonExpanded
                    ? "chevron.right" : "chevron.left")
                    .font(.system(size: PaneChromeRibbonFit.chevronFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(viewModel.ribbonExpanded ? "Collapse" : "Expand")
            ribbonContent
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
        // Push the arrow cursor over the ribbon so the openHand cursor
        // from the AppKit drag host (which paints over the whole
        // chrome) doesn't show while the user is reading / clicking
        // the ribbon controls. Pop on exit returns to the openHand.
        .onHover { hovering in
            if hovering {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
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

    /// Ribbon middle: collapsed shows only the last-used action;
    /// expanded shows the full family-specific set + size-preset.
    /// The chevron toggle and ⋯ overflow live in `ribbonControl`,
    /// outside this builder, so they're always visible.
    @ViewBuilder private var ribbonContent: some View {
        if viewModel.ribbonExpanded {
            HStack(spacing: PaneChromeRibbonFit.contentItemSpacing) {
                ForEach(ribbonActions, id: \.self) { action in
                    ribbonActionButton(action)
                }
                sizePresetMenu
            }
        } else {
            // Collapsed ribbon shows `hotAction`, not raw `lastUsedAction`,
            // so an AX-inspector or recording toggle started via the ⋯
            // menu surfaces a one-click off-switch in the collapsed view.
            // The VM cascade ends at `lastUsedAction`, so behavior matches
            // the previous shape when no on-state toggle is active.
            ribbonActionButton(viewModel.hotAction)
        }
    }

    /// Ribbon actions in left-to-right display order, computed on the
    /// view model (filtered to the pane's supported controls there) so
    /// the gating is unit-testable and the SwiftUI view stays a thin
    /// renderer.
    private var ribbonActions: [SimChromeAction] {
        viewModel.ribbonActions
    }

    /// Size-preset dropdown. Lives in the expanded ribbon only, so the
    /// collapsed view stays minimal at one button. Checkmark next to
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
    /// as the new last-used so the collapsed view tracks the recent
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
private struct StatusBadgeView: View {
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
