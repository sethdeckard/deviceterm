// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import SwiftUI

/// The fold bar a foldable pane shows under its device picture: the three
/// named postures, then the hinge itself.
///
/// A row of its own rather than part of the chrome strip. The hinge is
/// continuous, so the control needs a slider, and a slider needs width the
/// ribbon does not have. Below the picture it also sits outside the strip the
/// pane is dragged by, so no press on it can start a rearrange.
///
/// Draws nothing when the pane shows no fold bar, and the pane view
/// controller collapses its host to zero height to match.
struct PaneFoldBarView: View {
    let viewModel: PaneChromeViewModel

    var body: some View {
        if viewModel.showsFoldBar {
            bar
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: PaneChromeRibbonFit.foldBarHeight)
                .background(GhosttyThemeColors.backgroundSwiftUI(opacity: 1.0))
        }
    }

    /// The postures and the slider.
    ///
    /// The slider sends on release, never while dragging. Each fold spawns a
    /// guest helper the daemon waits on, serialized behind the pane's input
    /// queue, so a drag that sent per tick would enqueue a few hundred of
    /// them and the hinge would still be catching up long after the pointer
    /// stopped.
    private var bar: some View {
        HStack(spacing: PaneChromeRibbonFit.contentItemSpacing) {
            ForEach(FoldPosture.allCases, id: \.self) { posture in
                PaneChromeOverlay.chromeControlButton(
                    systemImage: posture.chromeSymbol,
                    help: posture.chromeTitle,
                    tint: nil,
                    action: { viewModel.onFold(posture.degrees) }
                )
                .accessibilityIdentifier("fold.posture.\(posture.rawValue)")
            }
            Slider(
                value: Binding(
                    get: { viewModel.foldDegrees },
                    set: { viewModel.foldDegrees = $0 }
                ),
                in: FoldPosture.degreeRange,
                onEditingChanged: { editing in
                    viewModel.foldSliderIsTracking = editing
                    guard !editing else { return }
                    viewModel.onFold(viewModel.foldDegrees)
                }
            )
            .controlSize(.small)
            // SwiftUI tints a slider from the system accent unless told
            // otherwise. Keeps the filled track consistent with the pane's
            // focus border, which reads the same color.
            .tint(PaneChromeOverlay.themeTint)
            .accessibilityIdentifier("fold.angle")
            // The slider's current value. Fixed width and tabular digits so
            // the slider does not resize as the number changes.
            Text("\(Int(viewModel.foldDegrees.rounded()))°")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .accessibilityIdentifier("fold.angle.readout")
        }
        .padding(.horizontal, PaneChromeRibbonFit.leadingPadding)
    }
}
