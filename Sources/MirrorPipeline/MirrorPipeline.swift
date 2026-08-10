// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import CoreVideo
import DeviceReachability
import Foundation

/// The live HEVC mirror of a physical device's display, delivered as decoded
/// pixel buffers.
///
/// It ties the negotiator, the UDP ingress, the RFC-7798 assembler, the loss
/// policy, and the hardware decoder into one restarting receive loop, and hands
/// the result out through a single-use `DecodedFrameFeed`. It ends at decoded
/// frames: it never allocates a surface pool, stamps a trace, or publishes,
/// since the daemon owns all of that.
///
/// Lifecycle is a single state machine, `idle → running → (stopped | failed)`,
/// both terminal states absorbing. One serial `stateQueue` is the sole owner of
/// every field touched from more than one execution context: the state, the
/// stream continuation, the current session's `ingress`, and the liveness
/// counters the decode callback writes and the watchdog reads. Session teardown
/// is fenced through that queue: a session installs its socket only while the
/// feed is still `running`, so a `stop` that wins the race prevents the socket
/// from ever being adopted, and a `stop` that arrives later closes the adopted
/// socket to end the receive loop.
///
/// `@unchecked Sendable`: the cross-context state above is confined to
/// `stateQueue`; the remaining decode/session fields are confined to the single
/// receive task (one session runs at a time, and the decode callback reaches
/// only the queue-owned counters).
package final class MirrorPipeline: DecodedFrameFeed, @unchecked Sendable {
    private enum State {
        case idle
        case running
        case stopped
        case failed
    }

    /// Handles grabbed under `stateQueue` during a stop, then acted on outside it
    /// (finishing the continuation re-enters `onTermination`, which must not
    /// re-enter a `stateQueue.sync`).
    private struct Teardown {
        static let none = Teardown(task: nil, ingress: nil, continuation: nil)

        let task: Task<Void, Never>?
        let ingress: DatagramIngress?
        let continuation: AsyncStream<DecodedFrame>.Continuation?
    }

    private let route: DeviceRoute
    private let channels: DeviceChannels
    private let displayID: Int
    private let diagnostics: (@Sendable (String) -> Void)?
    // Restart tuning (production defaults; a test can shorten them). The cap and
    // the backoff are behaviour, not policy the daemon sets.
    private let emptyRestartLimit: Int
    private let restartBackoff: Duration

    // stateQueue-owned: every field below is read/written only on this queue.
    private let stateQueue = DispatchQueue(label: "com.deviceterm.mirror.state")
    private var state: State = .idle
    private var continuation: AsyncStream<DecodedFrame>.Continuation?
    private var onFatal: (@Sendable (String) -> Void)?
    private var receiveTask: Task<Void, Never>?
    /// The running session's socket, so `stop` can close it to end the receive
    /// loop. A session only stores it while `state == .running`.
    private var ingress: DatagramIngress?
    /// Liveness for the stall watchdog and the empty-restart accounting. Written
    /// by the decode callback, read by the watchdog and the session loop.
    private var lastFrameNanos: UInt64 = 0
    private var framesThisSession = 0
    private var decodeErrors = 0
    /// Lifetime counters behind `observation()`. Unlike the fields above these
    /// survive a session restart, so a caller can difference two snapshots.
    private var framesDelivered = 0
    private var receiverReportAttempts = 0
    private var sessionRestarts = 0

    // Receive-task-confined: touched only during handle/ingest/flush/reset, which
    // run on the single receive task, one session at a time.
    private var assembler = AccessUnitAssembler()
    private var loss = LossPolicy()
    private var decoder: HardwareDecoder?
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var accessUnit: [[UInt8]] = []
    private var accessUnitIsKey = false
    private var feedback: FeedbackTarget?
    // The negotiated device video SSRC; media is gated on it because the device's
    // PT-101 control keepalives share this socket and fall outside the RTCP
    // range, so an ungated foreign packet would poison the sequence state.
    private var videoSSRC: UInt32?
    private var lastReceiverReportNanos: UInt64 = 0
    private var lastKeyframeRequestNanos: UInt64 = 0
    private let keyframeThrottleNanos: UInt64 = 250_000_000

    private var isRunning: Bool {
        stateQueue.sync { state == .running }
    }

    package init(
        route: DeviceRoute,
        channels: DeviceChannels,
        displayID: Int = 1,
        emptyRestartLimit: Int = 5,
        restartBackoff: Duration = .seconds(2),
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.route = route
        self.channels = channels
        self.displayID = displayID
        self.emptyRestartLimit = emptyRestartLimit
        self.restartBackoff = restartBackoff
        self.diagnostics = diagnostics
    }

    // MARK: DecodedFrameFeed

    package func frames(onFatal: @escaping @Sendable (String) -> Void) -> AsyncStream<DecodedFrame> {
        stateQueue.sync {
            // Single-use: a second start, or a start after a terminal state,
            // returns an already-finished stream and never re-arms the callback.
            guard state == .idle else {
                return AsyncStream { $0.finish() }
            }
            state = .running
            self.onFatal = onFatal
            // Keep only the newest frame: decode outpaces the consumer's
            // copy+publish, so an unbounded buffer would render ever-older frames.
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                self.continuation = continuation
                // Detached so packet I/O and the periodic RTCP keep-alive never
                // land on a caller's actor (e.g. the main thread), where an input
                // burst could starve the Receiver Reports past the encoder's
                // timeout and stall the stream.
                self.receiveTask = Task.detached { await self.drive() }
                // Consumer abandoned the stream: tear down. Scheduled async so it
                // never re-enters `stateQueue` when it fires from inside a
                // finish() call already on the queue.
                continuation.onTermination = { [weak self] _ in self?.tearDownFromConsumer() }
            }
        }
    }

    /// The stream's consumer stopped iterating: cancel the receive task and close
    /// the socket. Runs on `stateQueue` (async, so it never re-enters a sync).
    private func tearDownFromConsumer() {
        stateQueue.async {
            if self.state == .running { self.state = .stopped }
            let task = self.receiveTask
            self.receiveTask = nil
            self.continuation = nil
            self.onFatal = nil // release the callback so it can't retain its owner
            let ingress = self.ingress
            self.ingress = nil
            task?.cancel()
            ingress?.close()
        }
    }

    package func stop() {
        // Grab the teardown handles under the lock, then finish the continuation
        // and close the socket *outside* it: finishing invokes `onTermination`,
        // which must not re-enter `stateQueue.sync`.
        let teardown: Teardown = stateQueue.sync {
            switch state {
            case .idle:
                state = .stopped
                return .none

            case .running:
                state = .stopped
                let grabbed = Teardown(task: receiveTask, ingress: ingress, continuation: continuation)
                receiveTask = nil
                ingress = nil
                continuation = nil
                onFatal = nil // release the callback so it can't retain its owner
                return grabbed

            case .stopped, .failed:
                return .none
            }
        }
        teardown.task?.cancel()
        teardown.ingress?.close()
        teardown.continuation?.finish()
    }

    // MARK: Observation

    /// The lifetime counters, read as one consistent set. Instrumentation for the
    /// live-device track: the product never calls this, and the pipeline never
    /// branches on a counter.
    package func observation() -> MirrorObservation {
        stateQueue.sync {
            MirrorObservation(
                framesDelivered: framesDelivered,
                receiverReportAttempts: receiverReportAttempts,
                sessionRestarts: sessionRestarts
            )
        }
    }

    // MARK: Delivery (serialized on stateQueue)

    /// Yield a decoded frame unless the feed has already left `running`. The
    /// `DecodedFrame` (an `@unchecked Sendable`) is built before the hop so the
    /// raw `CVPixelBuffer` never crosses into the `@Sendable` queue closure.
    private func deliver(_ pixelBuffer: CVPixelBuffer) {
        let frame = DecodedFrame(pixelBuffer: pixelBuffer)
        stateQueue.async {
            guard self.state == .running else { return }
            self.continuation?.yield(frame)
        }
    }

    /// Terminal give-up: finish the stream and fire `onFatal` exactly once.
    /// `fail` is called off `stateQueue` (from the receive task), so it does the
    /// transition under the queue and invokes `onFatal` *outside* it, since a callback
    /// that synchronously calls `stop()` would otherwise deadlock on the queue.
    private func fail(_ reason: String) {
        let fatal: (@Sendable (String) -> Void)? = stateQueue.sync {
            guard state == .running else { return nil }
            state = .failed
            let grabbedContinuation = continuation
            continuation = nil
            let grabbedFatal = onFatal
            onFatal = nil
            grabbedContinuation?.finish() // onTermination re-enters via async, not sync
            return grabbedFatal
        }
        fatal?(reason)
    }

    /// Voluntary completion (the loop ended without a caller stop): finish the
    /// stream, no fatal.
    private func finish() {
        stateQueue.async {
            guard self.state == .running else { return }
            self.state = .stopped
            let continuation = self.continuation
            self.continuation = nil
            self.onFatal = nil // release the callback so it can't retain its owner
            continuation?.finish()
        }
    }

    // MARK: Receive loop

    /// Drive the stream with automatic stall recovery. A session that produced
    /// frames and then stalled is restarted (a fresh start forces a new encoder +
    /// IDR); give up after the configured number of consecutive empty sessions
    /// (a session that produced no frames, whether it failed to bind, open the
    /// channel, negotiate, or simply stalled).
    private func drive() async {
        var emptyRestarts = 0
        while isRunning, !Task.isCancelled {
            let produced = await runSession()
            if !isRunning || Task.isCancelled { break }
            emptyRestarts = produced > 0 ? 0 : emptyRestarts + 1
            guard emptyRestarts < emptyRestartLimit else {
                fail("mirror gave up after \(emptyRestartLimit) consecutive empty sessions")
                return
            }
            diagnostics?("stream ended; restarting (\(emptyRestarts) empty in a row)")
            stateQueue.sync { sessionRestarts += 1 }
            resetSessionState()
            try? await Task.sleep(for: restartBackoff)
        }
        finish()
    }

    /// One media-stream session: bind ingress, negotiate the stream, and pump
    /// datagrams until cancellation, a socket failure, or the watchdog closing the
    /// ingress ends the loop (the control channel isn't read after negotiation).
    /// Returns the number of frames it decoded.
    private func runSession() async -> Int {
        stateQueue.sync {
            framesThisSession = 0
            lastFrameNanos = 0
            decodeErrors = 0
        }
        var socket: DatagramIngress?
        do {
            let ingress = try DatagramIngress()
            socket = ingress
            // Adopt the socket only while the feed is still running. If `stop`
            // already won, don't install it (close it and bail) so the receive
            // loop never starts after a stop.
            let adopted = stateQueue.sync { () -> Bool in
                guard state == .running else { return false }
                self.ingress = ingress
                return true
            }
            guard adopted else {
                ingress.close()
                return 0
            }

            let channel = try await channels.open(.mirror)
            defer { channel.close() }
            let target = try await MirrorNegotiator(channel: channel).start(
                receiverIP: route.hostAddress,
                receiverPort: ingress.boundPort,
                senderIP: route.deviceAddress,
                displayID: displayID
            )
            feedback = target
            videoSSRC = target.remoteSSRC
            diagnostics?(
                "rtcp on · sourcePort=\(target.sourcePort) ourSSRC=\(target.localSSRC) deviceSSRC=\(target.remoteSSRC)"
            )

            let startNanos = DispatchTime.now().uptimeNanoseconds
            let watchdog = Task.detached { [weak self] in
                await self?.watchForStall(ingress: ingress, startNanos: startNanos)
            }
            defer { watchdog.cancel() }

            for await datagram in ingress.datagrams() {
                if Task.isCancelled { break }
                handle(datagram, ingress: ingress)
            }
        } catch {
            // Couldn't start (or the channel errored): an empty session.
        }
        if let socket {
            stateQueue.sync { if self.ingress === socket { self.ingress = nil } }
            socket.close()
        }
        return stateQueue.sync { framesThisSession }
    }

    /// End the packet loop (so `drive` restarts) when no frame has decoded within
    /// the stall window, or none ever arrived after a generous first-frame grace.
    private func watchForStall(ingress: DatagramIngress, startNanos: UInt64) async {
        let firstFrameGrace: UInt64 = 10_000_000_000
        let stallWindow: UInt64 = 5_000_000_000
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1_000))
            if Task.isCancelled { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let last = stateQueue.sync { lastFrameNanos }
            let stalled = last == 0 ? now &- startNanos > firstFrameGrace : now &- last > stallWindow
            if stalled {
                diagnostics?("watchdog: stalled (no frame); forcing stream restart")
                ingress.close()
                return
            }
        }
    }

    private func resetSessionState() {
        assembler.reset()
        loss.reset()
        decoder = nil
        vps = nil
        sps = nil
        pps = nil
        accessUnit.removeAll(keepingCapacity: true)
        accessUnitIsKey = false
        feedback = nil
        videoSSRC = nil
        lastReceiverReportNanos = 0
        lastKeyframeRequestNanos = 0
    }

    // MARK: Packet handling (receive task only)

    private func handle(_ packet: [UInt8], ingress: DatagramIngress) {
        guard packet.count >= 12 else { return }
        // RFC 5761 reserves payload types 64–95 for RTCP in an RTP/RTCP-muxed
        // stream (media uses 96+). A narrower filter would splice feedback frames
        // into the bitstream as bogus NALs with no organic keyframe to recover.
        let payloadType = packet[1] & 0x7F
        if (64...95).contains(payloadType) { return }

        // Accept only the negotiated video SSRC (bytes 8–11). PT-101 control
        // keepalives share this socket and fall outside the RTCP range, so a
        // foreign packet would poison the sequence/timestamp state and drive
        // spurious loss PLIs. Ungated when no SSRC was negotiated.
        if let videoSSRC {
            let packetSSRC = (UInt32(packet[8]) << 24) | (UInt32(packet[9]) << 16)
                | (UInt32(packet[10]) << 8) | UInt32(packet[11])
            guard packetSSRC == videoSSRC else { return }
        }

        let marker = (packet[1] & 0x80) != 0
        let sequence = (UInt16(packet[2]) << 8) | UInt16(packet[3])
        if loss.record(sequence: sequence) {
            assembler.reset()
            requestKeyframe(reason: "loss at seq \(sequence)", ingress: ingress)
        }
        sendReceiverReportIfDue(ingress: ingress)
        // While awaiting the IDR a PLI asked for, every delta is discarded; if
        // that one datagram (or its response) is lost, nothing re-asks and the
        // mirror stays frozen until the watchdog restarts. So keep asking while
        // waiting: the throttle bounds it to one per 250ms and a healthy stream
        // never enters here.
        if loss.awaitingKeyframe {
            requestKeyframe(reason: "awaiting keyframe", ingress: ingress)
        }

        let csrcCount = Int(packet[0] & 0x0F)
        var offset = 12 + 4 * csrcCount
        if (packet[0] & 0x10) != 0, offset + 4 <= packet.count { // extension header
            let extensionLength = (Int(packet[offset + 2]) << 8) | Int(packet[offset + 3])
            offset += 4 + 4 * extensionLength
        }
        guard offset < packet.count else { return }

        for nal in assembler.accept(Array(packet[offset...])) {
            ingest(nal)
        }
        if marker { flushAccessUnit() }
    }

    /// Send a Receiver Report at most once per second while packets flow.
    /// Without it the encoder stalls (~25s) and the mirror freezes.
    private func sendReceiverReportIfDue(ingress: DatagramIngress) {
        guard let feedback else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastReceiverReportNanos >= 1_000_000_000 else { return }
        lastReceiverReportNanos = now
        // Counted before the send: `send` reports nothing back, so an attempt is
        // the most this can honestly claim.
        stateQueue.sync { receiverReportAttempts += 1 }
        ingress.send(
            FeedbackReports.receiverReport(
                senderSSRC: feedback.localSSRC,
                mediaSSRC: feedback.remoteSSRC,
                highestSequence: loss.highestSequence
            ),
            toHost: route.deviceAddress,
            port: feedback.sourcePort
        )
    }

    /// Ask the encoder for a fresh IDR (PLI), throttled so a burst doesn't flood
    /// the device.
    private func requestKeyframe(reason: String, ingress: DatagramIngress) {
        guard let feedback else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastKeyframeRequestNanos >= keyframeThrottleNanos else { return }
        lastKeyframeRequestNanos = now
        ingress.send(
            FeedbackReports.pictureLossIndication(senderSSRC: feedback.localSSRC, mediaSSRC: feedback.remoteSSRC),
            toHost: route.deviceAddress,
            port: feedback.sourcePort
        )
        diagnostics?("PLI · \(reason)")
    }

    private func ingest(_ nal: [UInt8]) {
        guard !nal.isEmpty else { return }
        switch AccessUnitAssembler.nalType(nal) {
        case AccessUnitAssembler.vps:
            vps = nal

        case AccessUnitAssembler.sps:
            sps = nal

        case AccessUnitAssembler.pps:
            pps = nal

        default:
            if AccessUnitAssembler.isKeyframe(AccessUnitAssembler.nalType(nal)) {
                accessUnitIsKey = true
            }
            accessUnit.append(nal)
        }
    }

    private func flushAccessUnit() {
        defer {
            accessUnit.removeAll(keepingCapacity: true)
            accessUnitIsKey = false
        }
        // Never decode an access unit assembled across a gap: VideoToolbox decodes
        // partial slices as visible corruption rather than erroring, and every
        // later inter-frame predicts from that corrupt picture, so one gap would
        // persist indefinitely. Wait for a COMPLETE keyframe, even when the gappy
        // unit is itself a keyframe.
        switch loss.endAccessUnit(isKeyframe: accessUnitIsKey) {
        case .discardCorrupt, .discardUntilKeyframe:
            return

        case .decode:
            break
        }

        ensureDecoder()
        guard let decoder, !accessUnit.isEmpty else { return }
        try? decoder.decode(accessUnit: accessUnit, isKeyframe: accessUnitIsKey)
    }

    /// Build the decoder once VPS/SPS/PPS are all known. The decode callback runs
    /// synchronously on the receive task, but the counters it writes are read
    /// cross-context by the watchdog and the session loop, so its counter writes
    /// (and its frame delivery) hop to `stateQueue`.
    private func ensureDecoder() {
        guard decoder == nil, let vps, let sps, let pps else { return }
        guard let built = try? HardwareDecoder(vps: vps, sps: sps, pps: pps) else { return }
        switch built.usingHardwareDecoder {
        case .some(true):
            diagnostics?("decoder: hardware")

        case .some(false):
            diagnostics?("decoder: software")

        case .none:
            diagnostics?("decoder: unknown (property unavailable)")
        }
        built.onImage = { [weak self] pixelBuffer in
            guard let self else { return }
            self.stateQueue.sync {
                guard self.state == .running else { return }
                self.lastFrameNanos = DispatchTime.now().uptimeNanoseconds
                self.framesThisSession += 1
                self.framesDelivered += 1
            }
            self.deliver(pixelBuffer)
        }
        built.onDecodeError = { [weak self] status in
            guard let self else { return }
            self.stateQueue.sync {
                self.decodeErrors += 1
                let count = self.decodeErrors
                if count == 1 || count.isMultiple(of: 30) {
                    self.diagnostics?("decode error status=\(status) (count \(count))")
                }
            }
        }
        decoder = built
    }
}
