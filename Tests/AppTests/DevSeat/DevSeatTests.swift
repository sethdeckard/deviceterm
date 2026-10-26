// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import Foundation
import Testing

private func temporaryDirectory() throws -> String {
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("devseat-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func solidImage(width: Int, height: Int, alpha: CGFloat) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    )
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

/// Only the seat's own debug build is the seat.
struct DevSeatDecisionTests {
    @Test("which builds are the seat's", arguments: [
        ("/Users/me/repo/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm", "/Users/me/repo", true),
        // Another checkout, the release build, an installed app.
        ("/Users/me/other/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm", "/Users/me/repo", false),
        ("/Users/me/repo/.build/release/DeviceTerm.app/Contents/MacOS/deviceterm", "/Users/me/repo", false),
        ("/Applications/DeviceTerm.app/Contents/MacOS/deviceterm", "/Users/me/repo", false),
        // A checkout whose name starts with the seat's.
        ("/Users/me/repo2/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm", "/Users/me/repo", false)
    ])
    func onlyTheSeatsDebugBuildIsTheSeat(executable: String, root: String, isSeat: Bool) {
        #expect(DevSeatDecision.isSeat(executablePath: executable, holderRoot: root) == isSeat)
    }

    @Test
    func aRealDebugBuildIsTheSeatThroughItsLinks() throws {
        // SwiftPM's `.build/debug` is a link to the triple's directory, and
        // the running executable reports the resolved path.
        let root = (try temporaryDirectory() as NSString).resolvingSymlinksInPath
        let triple = root + "/.build/arm64-apple-macosx/debug"
        let macOS = triple + "/DeviceTerm.app/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: macOS + "/deviceterm", contents: Data())
        try FileManager.default.createSymbolicLink(atPath: root + "/.build/debug", withDestinationPath: triple)
        #expect(DevSeatDecision.isSeat(executablePath: macOS + "/deviceterm", holderRoot: root))
        #expect(DevSeatDecision.isSeat(
            executablePath: root + "/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm",
            holderRoot: root
        ))
    }

    @Test
    func noSeatMeansNoBuildIsTheSeat() {
        let executable = "/Users/me/repo/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm"
        #expect(!DevSeatDecision.isSeat(executablePath: executable, holderRoot: nil))
        #expect(!DevSeatDecision.isSeat(executablePath: nil, holderRoot: "/Users/me/repo"))
    }

    @Test
    func theHolderRootIsTheHolderFilesFirstLine() throws {
        let seat = try temporaryDirectory()
        #expect(DevSeatDecision.holderRoot(seatDirectory: seat) == nil)
        try "/Users/me/repo\nSat Oct 24 21:01:22 EDT 2026\n"
            .write(toFile: seat + "/holder", atomically: true, encoding: .utf8)
        #expect(DevSeatDecision.holderRoot(seatDirectory: seat) == "/Users/me/repo")
    }
}

struct DevSeatSnapshotRequestTests {
    @Test
    func aRequestDecodesFromWhatTheScriptWrites() throws {
        let json = #"{"udid":"ABC","seconds":2,"out":"/tmp/frames"}"#
        let request = try JSONDecoder().decode(PaneSnapshotRequest.self, from: Data(json.utf8))
        #expect(request == PaneSnapshotRequest(udid: "ABC", seconds: 2, out: "/tmp/frames"))
        #expect(request.problem == nil)
    }

    @Test
    func aRequestNamesItsSimulatorInEitherCase() {
        let request = PaneSnapshotRequest(udid: "5AF10B0F-628C-416D-9063-282E2F9D0C1C", seconds: 1, out: "/tmp/x")
        #expect(request.names(udid: "5af10b0f-628c-416d-9063-282e2f9d0c1c"))
        #expect(!request.names(udid: "1EE32B22-84AF-4496-AFCC-78A8E32F4340"))
    }

    @Test("a request that can't run says why", arguments: [
        PaneSnapshotRequest(udid: "", seconds: 2, out: "/tmp/frames"),
        PaneSnapshotRequest(udid: "ABC", seconds: 0, out: "/tmp/frames"),
        PaneSnapshotRequest(udid: "ABC", seconds: PaneSnapshotRequest.maximumSeconds + 1, out: "/tmp/frames"),
        PaneSnapshotRequest(udid: "ABC", seconds: 2, out: "frames")
    ])
    func anUnusableRequestHasAProblem(request: PaneSnapshotRequest) {
        #expect(request.problem != nil)
    }
}

struct DevSeatSnapshotWriterTests {
    private let state = PaneSnapshotFrame.State(
        hingeDegrees: 90,
        spansHinge: true,
        creased: true,
        drawnOrientation: "landscapeRight",
        presentedOrientation: "landscapeRight",
        surfaceWidth: 8,
        surfaceHeight: 12
    )

    private func outcome(of writer: PaneSnapshotWriter) async -> PaneSnapshotOutcome {
        await withCheckedContinuation { continuation in
            writer.finish { continuation.resume(returning: $0) }
        }
    }

    @Test
    func aBurstWaitsForEveryPromisedFrame() async throws {
        let directory = try temporaryDirectory()
        let writer = try PaneSnapshotWriter(directory: directory)
        writer.expectFrame()
        writer.expectFrame()
        // The second frame lands after the burst was told to finish, as a
        // late GPU completion would.
        writer.deliver(
            index: 0,
            seconds: 0,
            state: state,
            picture: PaneSnapshotWriter.Image(image: try solidImage(width: 4, height: 4, alpha: 1)),
            bezel: nil
        )
        async let finished = outcome(of: writer)
        try await Task.sleep(nanoseconds: 50_000_000)
        writer.deliver(index: 1, seconds: 0.016, state: state, picture: nil, bezel: nil)
        let result = await finished
        // The unreadable frame keeps its promise without a file.
        #expect(result == PaneSnapshotOutcome(ok: true, frames: 1, error: nil))
        #expect(FileManager.default.fileExists(atPath: directory + "/0000.png"))
        #expect(!FileManager.default.fileExists(atPath: directory + "/0001.png"))
        let frames = try JSONDecoder().decode(
            [PaneSnapshotFrame].self,
            from: try Data(contentsOf: URL(fileURLWithPath: directory + "/frames.json"))
        )
        #expect(frames == [PaneSnapshotFrame(index: 0, file: "0000.png", seconds: 0, state: state)])
    }

    @Test
    func thePictureIsDrawnOverTheBezel() throws {
        // A transparent picture lets the bezel show through, as the Metal
        // view's clear colour does around the screen.
        let picture = try solidImage(width: 2, height: 2, alpha: 0)
        let bezel = try solidImage(width: 2, height: 2, alpha: 1)
        let composited = try #require(PaneSnapshotWriter.composite(picture: picture, over: bezel))
        let data = try #require(composited.dataProvider?.data as Data?)
        // BGRA, little-endian premultiplied-first: red is byte 2, alpha byte 3.
        #expect(data[2] == 255)
        #expect(data[3] == 255)
    }
}

@MainActor
struct DevSeatSnapshotWatcherTests {
    private func waitForAnswer(_ path: String) async throws -> PaneSnapshotOutcome {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(PaneSnapshotOutcome.self, from: data)
    }

    private func drop(_ json: String, id: String, in seat: String) throws {
        let requests = seat + "/snapshots/requests"
        try json.write(toFile: requests + "/\(id).tmp", atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(atPath: requests + "/\(id).tmp", toPath: requests + "/\(id).json")
    }

    @Test
    func aRequestRunsOnceAndIsAnswered() async throws {
        let seat = try temporaryDirectory()
        var handled: [PaneSnapshotRequest] = []
        let watcher = PaneSnapshotWatcher(seatDirectory: seat, stillSeat: { true }, handler: { request, answer in
            handled.append(request)
            answer(PaneSnapshotOutcome(ok: true, frames: 3, error: nil))
        })
        try watcher.start()
        try drop(#"{"udid":"ABC","seconds":1,"out":"/tmp/x"}"#, id: "one", in: seat)
        let answer = try await waitForAnswer(seat + "/snapshots/requests/one.done.json")
        #expect(answer == PaneSnapshotOutcome(ok: true, frames: 3, error: nil))
        #expect(handled == [PaneSnapshotRequest(udid: "ABC", seconds: 1, out: "/tmp/x")])
        #expect(!FileManager.default.fileExists(atPath: seat + "/snapshots/requests/one.json"))
    }

    @Test
    func aBadRequestIsRefusedWithoutReachingAPane() async throws {
        let seat = try temporaryDirectory()
        var handled = 0
        let watcher = PaneSnapshotWatcher(seatDirectory: seat, stillSeat: { true }, handler: { _, _ in handled += 1 })
        try watcher.start()
        try drop(#"{"udid":"ABC"}"#, id: "malformed", in: seat)
        try drop(#"{"udid":"ABC","seconds":60,"out":"/tmp/x"}"#, id: "long", in: seat)
        #expect(try await !waitForAnswer(seat + "/snapshots/requests/malformed.done.json").ok)
        #expect(try await !waitForAnswer(seat + "/snapshots/requests/long.done.json").ok)
        #expect(handled == 0)
    }

    @Test
    func anAppThatLostTheSeatRefuses() async throws {
        let seat = try temporaryDirectory()
        var handled = 0
        let watcher = PaneSnapshotWatcher(seatDirectory: seat, stillSeat: { false }, handler: { _, _ in handled += 1 })
        try watcher.start()
        try drop(#"{"udid":"ABC","seconds":1,"out":"/tmp/x"}"#, id: "late", in: seat)
        let answer = try await waitForAnswer(seat + "/snapshots/requests/late.done.json")
        #expect(!answer.ok)
        #expect(handled == 0)
    }
}

@MainActor
struct DevSeatContentViewSnapshotTests {
    @Test
    func aBurstOffScreenEndsAndPutsTheDrawableBack() async throws {
        let view = SimulatorContentView()
        let writer = try PaneSnapshotWriter(directory: try temporaryDirectory())
        let outcome: PaneSnapshotOutcome = await withCheckedContinuation { continuation in
            // Off screen, as for a pane in a background tab: the display
            // link never ticks, and the deadline has to end the burst.
            view.beginSnapshot(
                SimulatorContentView.SnapshotBurst(
                    writer: writer,
                    seconds: 0.1,
                    bezel: { _ in nil },
                    state: { .unknown },
                    completion: { continuation.resume(returning: $0) }
                )
            )
            #expect(view.isTakingSnapshot)
            #expect(!view.framebufferOnly)
        }
        #expect(outcome == PaneSnapshotOutcome(ok: true, frames: 0, error: nil))
        #expect(!view.isTakingSnapshot)
        #expect(view.framebufferOnly)
    }

    @Test
    func aDrawThatCantRenderStillSettlesItsFrame() async throws {
        let view = SimulatorContentView()
        let writer = try PaneSnapshotWriter(directory: try temporaryDirectory())
        let outcome: PaneSnapshotOutcome = await withCheckedContinuation { continuation in
            view.beginSnapshot(
                SimulatorContentView.SnapshotBurst(
                    writer: writer,
                    seconds: 0.1,
                    bezel: { _ in nil },
                    state: { .unknown },
                    completion: { continuation.resume(returning: $0) }
                )
            )
            // No window, so no drawable: the render returns before it reaches
            // the readback, and the frame it was promised must still settle
            // or the burst never reports.
            view.draw(in: view)
        }
        #expect(outcome == PaneSnapshotOutcome(ok: true, frames: 0, error: nil))
    }

    @Test
    func aPosedDrawSettlesItsFrameToo() async throws {
        let view = SimulatorContentView()
        // Shown closed while the inner panel is still lit: drawn posed.
        view.setPosedFold(
            SimulatorContentView.PosedFold(
                closed: true,
                openTurn: 1,
                showsInnerFrame: true,
                innerOrientation: .landscapeRight,
                coverOrientation: .portrait,
                innerSize: CGSize(width: 8, height: 12),
                coverSize: CGSize(width: 6, height: 9),
                family: .phone
            )
        )
        #expect(view.drawsPosedFold)
        let writer = try PaneSnapshotWriter(directory: try temporaryDirectory())
        let outcome: PaneSnapshotOutcome = await withCheckedContinuation { continuation in
            view.beginSnapshot(
                SimulatorContentView.SnapshotBurst(
                    writer: writer,
                    seconds: 0.1,
                    bezel: { _ in nil },
                    state: { .unknown },
                    completion: { continuation.resume(returning: $0) }
                )
            )
            view.draw(in: view)
        }
        #expect(outcome == PaneSnapshotOutcome(ok: true, frames: 0, error: nil))
    }

    @Test
    func aReadbackSettlesOnce() {
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let readback = SimulatorFrameReadback { _ in count.value += 1 }
        readback.settleUnread()
        readback.settleUnread()
        #expect(count.value == 1)
    }
}

@MainActor
struct DevSeatPaneSnapshotTests {
    @Test
    func aPaneOffScreenRefusesASnapshot() async throws {
        let (viewController, _) = SimulatorPaneFoldIntentTests().makeViewController()
        viewController.loadViewIfNeeded()
        let directory = try temporaryDirectory()
        let outcome: PaneSnapshotOutcome = await withCheckedContinuation { continuation in
            viewController.captureSnapshot(seconds: 1, into: directory) { continuation.resume(returning: $0) }
        }
        #expect(!outcome.ok)
        #expect(outcome.error?.contains("isn't on screen") == true)
    }
}
