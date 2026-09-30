// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A real `devicectl` reader: a running `Process` plus the pipe its lines
/// arrive on.
///
/// `@unchecked Sendable`: the serial queue protects the two handlers and
/// `terminated`, and `Process` and `Pipe` are only touched from it or from
/// Foundation's own callbacks.
final class SpawnedHingeProcess: HingeMonitorProcess, @unchecked Sendable {
    private let process: Process
    private let output: Pipe
    private let queue = DispatchQueue(label: "com.deviceterm.daemon.hinge-process")
    private var terminated = false

    init(process: Process, output: Pipe) {
        self.process = process
        self.output = output
    }

    /// Backstop for a reader dropped without `terminate()`. A `Process` keeps
    /// running when its last reference goes, so without this a monitor
    /// released on some path that forgot to stop it would leave `devicectl`
    /// alive until the daemon exits.
    deinit {
        terminate()
    }

    func onOutput(_ handler: @escaping @Sendable (Data) -> Void) {
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // An empty read is end of file. Clearing the handler here stops
            // Foundation spinning on a closed descriptor, which it otherwise
            // does for as long as the handler is installed.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            handler(data)
        }
    }

    func onExit(_ handler: @escaping @Sendable () -> Void) {
        process.terminationHandler = { _ in handler() }
    }

    func terminate() {
        queue.sync {
            guard !terminated else { return }
            terminated = true
            // Drop the handler before terminating: a read arriving against a
            // descriptor this is about to close has nowhere useful to go.
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
        }
    }
}
