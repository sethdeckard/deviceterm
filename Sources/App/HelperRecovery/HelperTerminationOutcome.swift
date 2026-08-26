// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Darwin)
import Darwin
#endif

/// What came of the GUI asking the running helper
/// to stop.
///
/// Deliberately not a Bool. Three of these five leave recovery free to carry
/// on, but only one of them means this call sent anything, and the two that
/// stop it are different problems with different remedies. Reporting them apart
/// is what lets the GUI say something true when it couldn't do what the user
/// asked.
enum HelperTerminationOutcome: Sendable, Equatable {
    /// The signal reached `pid`. `kill(2)` returning 0 says it was accepted,
    /// and SIGKILL cannot be blocked or ignored, so that process is going
    /// away; it may not have finished doing so yet.
    case terminated(pid: pid_t)
    /// No signal was sent, because there was no connected peer or the pid
    /// read from one had already exited. Neither proves no helper process
    /// exists, only that this call found nothing to signal, so the caller is
    /// free to go on and reconnect.
    case alreadyGone
    /// A connection is open but XPC reported no pid for the far end, so
    /// there is no process to name. Nothing was signalled.
    case unknownPeer
    /// The connection this was fenced to had already been replaced by a newer
    /// one. That says the connection was superseded, not what became of the
    /// process behind it. Nothing was signalled, which is the point: a prompt
    /// raised against one connection can't reach whatever is answering now.
    case alreadyRestarted
    /// `kill(2)` refused, carrying the system's reason. Nothing was signalled.
    case failed(String)
}
