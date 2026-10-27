// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Keeps the saved layout current while the app runs, and takes the last
/// snapshot at quit.
///
/// Writes about a second after the workspace's windows, tabs, or panes change,
/// and on a slower tick for what the navigation model doesn't hold (window
/// frames, divider drags, working directories), so a crash still leaves a
/// recent layout behind. A write is skipped when the encoded layout hasn't
/// changed.
///
/// `saveFinal` runs at quit before any window closes, then freezes the writer:
/// quitting tears every window down, and a snapshot taken during that teardown
/// would record an empty workspace and lose the layout the user quit with.
@MainActor
final class WorkspaceSnapshotWriter {
    private let build: @MainActor () -> WorkspaceSnapshot
    private let write: (Data) -> Void
    private let debounce: Duration
    private let interval: Duration
    private var lastWritten: Data?
    private var isFrozen = false
    private var observation: ObservationToken?
    private var pendingSave: Task<Void, Never>?
    private var tick: Task<Void, Never>?

    init(
        debounce: Duration = .seconds(1),
        interval: Duration = .seconds(10),
        write: @escaping (Data) -> Void,
        build: @escaping @MainActor () -> WorkspaceSnapshot
    ) {
        self.debounce = debounce
        self.interval = interval
        self.write = write
        self.build = build
    }

    /// Begin recording. Call once the launch's windows are open, so nothing
    /// is written while the saved layout is still being restored.
    func start() {
        guard !isFrozen, observation == nil else { return }
        observation = App.observe { [weak self] in self?.workspaceChanged() }
        tick = Task { @MainActor [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
        }
    }

    /// Write the current layout if it differs from the last one written.
    func saveNow() {
        guard !isFrozen else { return }
        guard let data = try? WorkspaceSnapshotStore.encode(build()), data != lastWritten else {
            return
        }
        write(data)
        lastWritten = data
    }

    /// Write the layout one last time and stop recording for good.
    func saveFinal() {
        saveNow()
        isFrozen = true
        observation?.cancel()
        observation = nil
        pendingSave?.cancel()
        pendingSave = nil
        tick?.cancel()
        tick = nil
    }

    /// Re-run on every observed change. Building reads every window, tab, and
    /// pane, which is what registers them for observation; the write itself
    /// waits out the debounce so a burst of changes lands once.
    private func workspaceChanged() {
        _ = build()
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}
