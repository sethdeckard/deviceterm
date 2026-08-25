// SPDX-License-Identifier: GPL-3.0-or-later
//
// CustomCoordinatesSheet: type a position by hand.
//
// SwiftUI per the project default for sheets: this renders state and
// dispatches one action, with no responder-chain or draw-timing needs
// that would call for AppKit.
//
// Coordinate validation lives in `CoordinateInput`. The view decides
// when to show messages, when to enable Set, and how to normalize the
// optional name. Setting a location also saves it to the locations file
// (see `PaneLocationViewModel.apply`), which is why the sheet offers a
// name: an entry saved without one shows up in the menu as bare
// coordinates.

import DaemonProtocol
import SwiftUI

struct CustomCoordinatesSheet: View {
    /// Applies the typed position, with the name the user gave it (nil
    /// when the field was left blank).
    let onSubmit: (SimulatedLocation, String?) -> Void
    let onCancel: () -> Void

    /// Injected so tests and previews can pin a locale rather than
    /// inheriting the host's. See `CoordinateInput` on why typed input
    /// is locale-aware where the file format is not.
    var locale: Locale = .current

    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var nameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Coordinates")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 8) {
                field("Latitude", text: $latitudeText, defect: latitudeDefect)
                field("Longitude", text: $longitudeText, defect: longitudeDefect)
                GridRow {
                    Text("Name")
                        .gridColumnAlignment(.trailing)
                    TextField("Optional", text: $nameText)
                        .frame(width: 220)
                }
            }
            Text("Saved to your locations file so it stays in this menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Set", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    /// The typed position, or nil while either field is empty or wrong.
    /// Doubles as the Set button's enablement.
    private var parsed: SimulatedLocation? {
        CoordinateInput.location(
            latitude: latitudeText,
            longitude: longitudeText,
            locale: locale
        )
    }

    private var latitudeDefect: CoordinateInput.Defect? {
        guard case let .failure(defect) = CoordinateInput.latitude(latitudeText, locale: locale) else {
            return nil
        }
        return defect
    }

    private var longitudeDefect: CoordinateInput.Defect? {
        guard case let .failure(defect) = CoordinateInput.longitude(longitudeText, locale: locale) else {
            return nil
        }
        return defect
    }

    static func normalizedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        defect: CoordinateInput.Defect?
    ) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: text)
                    .frame(width: 220)
                // `.empty` yields no message: a field the user hasn't
                // finished typing isn't wrong yet, and complaining at an
                // empty sheet on first open would be noise.
                if let message = defect?.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func submit() {
        guard let parsed else { return }
        onSubmit(parsed, Self.normalizedName(nameText))
    }
}
