// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import SwiftUI

/// The SwiftUI surface for "Mirror Physical Device…".
/// Renders the connected-device roster from `DevicePickerViewModel`:
/// a progress indicator while loading, an error line if the list RPC
/// failed, an empty-state hint when nothing is connected, or a list of
/// devices. Each row reads as a selectable list entry: device icon,
/// name, a `model · iOS x.y` subtitle (so two devices that share a name
/// are distinguishable), a hover highlight, and a trailing chevron.
/// A single click mirrors the device; unavailable rows are disabled and
/// show their reason. Pure render-state product UI, so SwiftUI per the
/// boundary rule.
struct DevicePickerView: View {
    /// Above this many devices the list scrolls; at or below it sizes to
    /// its content so the window stays compact for the typical 1–3
    /// devices. ~46pt per row (icon + two text lines + padding/spacing).
    private static let visibleRowCap = 6
    private static let rowHeight: CGFloat = 46

    let viewModel: DevicePickerViewModel
    /// Reports the laid-out content height so the host window can resize
    /// to fit. The list grows with the device count (the loading/empty/
    /// error states differ in height too), and assigning the
    /// `NSHostingController` doesn't track those changes after the async
    /// load, so the window measures here and resizes explicitly.
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mirror Physical Device")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)
                .help("Refresh")
            }

            content

            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    onContentHeightChange(height)
                }
            }
        )
    }

    @ViewBuilder private var content: some View {
        if viewModel.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for connected devices…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        } else if let loadError = viewModel.loadError {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't list devices")
                    .font(.system(size: 12, weight: .medium))
                Text(loadError)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        } else if viewModel.devices.isEmpty {
            Text(
                "No connected devices. Plug in an iPhone or iPad, unlock "
                + "it, and trust this Mac, then reopen this menu."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        } else {
            deviceList
        }
    }

    @ViewBuilder private var deviceList: some View {
        let rows = VStack(spacing: 2) {
            ForEach(viewModel.devices, id: \.deviceId) { entry in
                DeviceRow(entry: entry) { viewModel.select(entry) }
            }
        }
        if viewModel.devices.count > Self.visibleRowCap {
            ScrollView { rows }
                .frame(height: CGFloat(Self.visibleRowCap) * Self.rowHeight)
        } else {
            rows
        }
    }

    /// Pure subtitle composer for a device row. Returns the
    /// `unavailableReason` for an unavailable device; otherwise joins the
    /// known `model` and `iOS <version>` with `" · "`. nil when there's
    /// nothing to show. Kept out of the view body so it's unit-tested.
    ///
    /// `model` is omitted when it would duplicate the row title. The
    /// title falls back to `model` when `name` is nil (the common case,
    /// since the handshake rarely exposes a name), so repeating it here
    /// would render "iPhone 15 Pro" over "iPhone 15 Pro · iOS 17.5".
    static func subtitle(for entry: PhysicalDeviceListEntry) -> String? {
        if !entry.available {
            return entry.unavailableReason
        }
        var parts: [String] = []
        if let model = entry.model, entry.name != nil {
            parts.append(model)
        }
        if let osVersion = entry.osVersion {
            parts.append("iOS \(osVersion)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension DevicePickerView {
    /// One selectable device row. Owns its hover state for the highlight.
    /// Tightly coupled to `DevicePickerView`, so it shares the file.
    struct DeviceRow: View {
        let entry: PhysicalDeviceListEntry
        let select: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: select) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.system(size: 18))
                        .foregroundStyle(entry.available ? .primary : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name ?? entry.model ?? entry.deviceId)
                            .font(.system(size: 13))
                        if let subtitle = DevicePickerView.subtitle(for: entry) {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if entry.available {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering && entry.available
                            ? Color.primary.opacity(0.08)
                            : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .disabled(!entry.available)
            .onHover { isHovering = $0 }
        }
    }
}
