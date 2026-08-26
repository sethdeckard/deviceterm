// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The long-lived harness process's socket loop.
///
/// `start()` binds the listener synchronously (so the socket is ready the
/// moment it returns) and drives the blocking accept loop from a
/// dedicated background thread. The resident hands its main thread to an
/// AppKit run loop (see `UITestMain.runResident`), so a blocking accept
/// loop there would wedge it.
///
/// Protocol: one request per connection. Read one framed request,
/// dispatch through `Responder`, write one framed reply, close.
///
/// `Sendable` because every stored property is a `let` over `Sendable`
/// state (`socketPath`, a value-type `Responder`, a `DispatchQueue`), so
/// the background accept closure may capture `self` safely.
final class ResidentServer: Sendable {
    private let socketPath: String
    private let responder = Responder()
    /// Accepted connections are serviced here, off the accept loop, so a
    /// peer that connects and stalls mid-frame can't stop the resident
    /// from answering everyone else.
    private let workQueue = DispatchQueue(
        label: "com.deviceterm.uitest.work",
        attributes: .concurrent
    )

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Bind the listener and spawn the accept loop. Throws if the socket
    /// path is already owned by a live resident (or is an unrelated file).
    func start() throws {
        let listenerFd = try UDSListenerSocket.bindListener(at: socketPath)
        let queue = DispatchQueue(label: "com.deviceterm.uitest.accept")
        queue.async { [self] in
            acceptLoop(listenerFd: listenerFd)
        }
    }

    private func acceptLoop(listenerFd: Int32) {
        while true {
            guard let clientFd = try? UDSListenerSocket.acceptOne(listenerFd: listenerFd) else {
                // A non-transient accept error (e.g. a closed listener)
                // would otherwise spin this thread at 100% CPU.
                usleep(10_000)
                continue
            }
            workQueue.async { [self] in
                handle(clientFd: clientFd)
            }
        }
    }

    private func handle(clientFd: Int32) {
        defer { UDSListenerSocket.close(clientFd) }
        // `try?` flattens `Data?` → a single optional, so this covers
        // both a read error and a clean EOF-before-a-full-frame.
        guard let payload = try? UDSListenerSocket.readFrame(fd: clientFd) else { return }

        let reply: Data
        if let request = try? JSONDecoder().decode(UITestRequest.self, from: payload) {
            let responder = self.responder
            reply = blockingAwait { await responder.respond(to: request) }
        } else {
            reply = UITestReply.failure("malformed request frame")
        }
        try? UDSListenerSocket.writeFrame(fd: clientFd, payload: reply)
    }

    /// Run one `async` responder call to completion from this blocking
    /// worker thread.
    ///
    /// The socket I/O above is blocking, so it must not run on the
    /// cooperative pool; the responder is `async` because capture is.
    /// This is the single bridge between the two. Blocking here is safe:
    /// the worker is a plain GCD thread on a concurrent queue, distinct
    /// from the pool the `Task` runs on, so it cannot deadlock. The
    /// semaphore also supplies the happens-before edge that makes the
    /// `nonisolated(unsafe)` handoff sound: the Task writes `output`
    /// strictly before `signal()`, and we read it strictly after `wait()`.
    private func blockingAwait(
        _ operation: @escaping @Sendable () async -> Data
    ) -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output = Data()
        Task {
            output = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return output
    }
}
