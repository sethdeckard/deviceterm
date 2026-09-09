// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Composited screenshots via ScreenCaptureKit.
///
/// Captures composited per-window output, including the Metal-rendered
/// layers (the simulator / device panes, the terminal surface) that an
/// in-app self-render (`NSView.cacheDisplay`) misses, which is why the
/// harness captures from outside.
///
/// TCC: `SCShareableContent` requires the Screen Recording grant, and the
/// grant attributes to the process that calls it (this resident harness),
/// which is the whole reason it exists as a separate binary. When the grant
/// is missing, ScreenCaptureKit throws and `captureFailed` carries a hint.
enum CaptureService {
    /// How many times to locate the status item before giving up. Two
    /// attempts allow one transient: a badge frame that would not read, or
    /// one that moved between the reads bracketing the snapshot.
    private static let statusItemLocateAttempts = 2

    /// Screenshot the frontmost content window owned by `bundleID`: the
    /// main window, or an app-modal alert on top of it.
    static func captureWindow(bundleID: String, out path: String) async throws -> CaptureOutcome {
        try requireWritablePath(path)
        let content = try await shareableContent(onScreenWindowsOnly: true)

        let candidates = content.windows.map(candidate(from:))
        try requireOneTarget(
            bundleID: bundleID,
            windowOwners: WindowChooser.contentOwners(from: candidates, bundleID: bundleID)
        )
        guard
            let chosen = WindowChooser.choose(
                from: candidates,
                bundleID: bundleID,
                frontToBack: frontToBackWindowIDs()
            ),
            let window = content.windows.first(where: { $0.windowID == chosen.windowID })
        else {
            throw CaptureError.noMatchingWindow(bundleID: bundleID)
        }
        return try await writeCapture(of: window, displays: content.displays, to: path)
    }

    /// Screenshot one window at its native pixel size and write the PNG.
    private static func writeCapture(
        of window: SCWindow,
        displays: [SCDisplay],
        to path: String
    ) async throws -> CaptureOutcome {
        let scale = backingScale(containing: window.frame, displays: displays)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await capture(
            filter: filter,
            pointSize: window.frame.size,
            scale: scale
        )
        try PNGWriter.write(image, to: path)
        return CaptureOutcome(
            path: path,
            width: image.width,
            height: image.height,
            scale: Double(scale)
        )
    }

    /// Screenshot just the window hosting the daemon's menu-bar status item
    /// (the one showing the iPhone glyph and count), or report it absent.
    ///
    /// The harness never captures a whole display, so a per-window capture
    /// is the only way it can see the status item. The window is Control
    /// Center's rather than the daemon's, so accessibility supplies the
    /// frame and the window is matched against it.
    ///
    /// Absent is a first-class result, reached three ways: no daemon is
    /// running, no running daemon publishes a menu-bar item (the
    /// hidden-at-zero-sims state), or one does and no on-screen window
    /// contains its frame. All three mean "not on screen to capture".
    static func captureStatusItem(out path: String) async throws -> StatusItemCapture {
        try requireWritablePath(path)
        let daemon = DeviceTermBundleID.daemon
        for attempt in 0 ..< statusItemLocateAttempts {
            let isLast = attempt + 1 == statusItemLocateAttempts
            do {
                if let capture = try await locateAndCapture(daemon: daemon, out: path) {
                    return capture
                }
            } catch CaptureError.statusItemUnreadable where !isLast {
                // An unreadable element can be transient, a menu bar mid-reflow
                // among the possibilities, so retry once before surfacing it.
                continue
            }
        }
        throw CaptureError.statusItemUnstable(bundleID: daemon)
    }

    /// One attempt at the status-item capture. Nil means the badge frame
    /// differed across the reads bracketing the snapshot, so the caller
    /// should try again.
    private static func locateAndCapture(
        daemon: String,
        out path: String
    ) async throws -> StatusItemCapture? {
        // Accessibility locates the badge; the window server cannot, since
        // Control Center owns the window. `StatusItemLocator` also settles
        // instance ambiguity up front, before any window is considered.
        guard let axFrame = try StatusItemLocator.badgeFrame(bundleID: daemon) else {
            try removeStaleFile(at: path)
            return .absent
        }
        let content = try await shareableContent(onScreenWindowsOnly: true)
        // The menu bar reflows whenever an extra comes or goes, and the
        // snapshot above is awaited. Read the frame again on the far side: if
        // it moved, these coordinates now name whichever extra slid into them,
        // and capturing there would label another app's item as deviceterm's
        // badge. Matching reads bracket the snapshot, so the position it was
        // taken at is one the badge held.
        guard try StatusItemLocator.badgeFrame(bundleID: daemon) == axFrame else { return nil }
        guard
            let chosen = WindowChooser.chooseStatusItem(
                from: content.windows.map(candidate(from:)),
                axFrame: axFrame
            ),
            let window = content.windows.first(where: { $0.windowID == chosen.windowID })
        else {
            // Published, but no on-screen window contains its frame. Leave no
            // PNG at `out`, so a caller reusing a path that held an earlier
            // badge capture doesn't read the stale image as if the item were
            // still present. `requireWritablePath` already rejected a
            // directory, so this only unlinks a regular file.
            try removeStaleFile(at: path)
            return .absent
        }
        let outcome = try await writeCapture(of: window, displays: content.displays, to: path)
        return .present(outcome)
    }

    // MARK: - ScreenCaptureKit plumbing

    private static func shareableContent(
        onScreenWindowsOnly: Bool
    ) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: onScreenWindowsOnly
            )
        } catch {
            throw CaptureError.captureFailed(underlying: String(describing: error))
        }
    }

    /// Capture at native pixel resolution: point size × the display's
    /// backing scale, so a Retina window yields a 2x PNG rather than a
    /// downsampled one.
    private static func capture(
        filter: SCContentFilter,
        pointSize: CGSize,
        scale: CGFloat
    ) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((pointSize.width * scale).rounded())
        configuration.height = Int((pointSize.height * scale).rounded())
        configuration.showsCursor = false
        configuration.scalesToFit = false
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw CaptureError.captureFailed(underlying: String(describing: error))
        }
    }

    // MARK: - Output path safety

    /// A capture `--out` must be either nonexistent or a plain regular
    /// file. Reject anything else up front (a directory, socket, FIFO,
    /// symlink, or device) so neither the PNG write nor (for a hidden
    /// badge) the stale-file cleanup can ever target a special file.
    private static func requireWritablePath(_ path: String) throws {
        guard let type = try fileType(atPath: path) else { return }  // nonexistent → fine
        guard type == .typeRegular else {
            throw CaptureError.outputNotAFile(path: path)
        }
    }

    /// Remove a prior capture at `path`, a regular file only. A directory
    /// or special file is left untouched; a removal failure is surfaced,
    /// not swallowed.
    private static func removeStaleFile(at path: String) throws {
        guard try fileType(atPath: path) == .typeRegular else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw CaptureError.cleanupFailed(path: path, underlying: String(describing: error))
        }
    }

    /// The item's own type (does not follow a symlink; a symlink reports
    /// `.typeSymbolicLink`), or nil when nothing exists at `path`.
    ///
    /// Only a genuine "no such file" reads as nil. A permission or I/O
    /// failure is *not* absence, so it is surfaced as `outputUnreadable`.
    /// Swallowing it would let an inaccessible stale capture linger while
    /// the caller is told the path is clear.
    private static func fileType(atPath path: String) throws -> FileAttributeType? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return attributes[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw CaptureError.outputUnreadable(path: path, underlying: String(describing: error))
        }
    }

    /// Refuse when more than one process can be the target.
    ///
    /// Window owners alone would miss an instance showing nothing, and a
    /// hidden instance can be the one the caller meant, so the process
    /// list is consulted too. Point-in-time by nature: this describes the
    /// moment the request ran, not the whole track.
    private static func requireOneTarget(bundleID: String, windowOwners: Set<pid_t>) throws {
        try requireOneTarget(
            bundleID: bundleID,
            processes: TargetOwners.live(bundleID: bundleID),
            windowOwners: windowOwners
        )
    }

    private static func requireOneTarget(
        bundleID: String,
        processes: [pid_t],
        windowOwners: Set<pid_t>
    ) throws {
        let owners = TargetOwners.combined(processes: processes, windowOwners: windowOwners)
        guard owners.count <= 1 else {
            throw CaptureError.ambiguousTarget(bundleID: bundleID, pids: owners.sorted())
        }
    }

    // MARK: - Ordering + scale

    /// Project an `SCWindow` onto the pure `CandidateWindow` the chooser
    /// reasons about, so window selection stays testable without SCKit.
    private static func candidate(from window: SCWindow) -> CandidateWindow {
        CandidateWindow(
            windowID: window.windowID,
            layer: window.windowLayer,
            frame: window.frame,
            bundleID: window.owningApplication?.bundleIdentifier,
            isOnScreen: window.isOnScreen,
            pid: window.owningApplication?.processID
        )
    }

    /// Window IDs in window-server order, front first. ScreenCaptureKit's
    /// content list has no ordering guarantee, so this supplies it.
    private static func frontToBackWindowIDs() -> [UInt32] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
    }

    private static func backingScale(containing frame: CGRect, displays: [SCDisplay]) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let display = displays.first { $0.frame.contains(center) } ?? displays.first
        guard let display else { return NSScreen.main?.backingScaleFactor ?? 2 }
        return screenScale(displayID: display.displayID)
    }

    private static func screenScale(displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            if CGDirectDisplayID(number.uint32Value) == displayID {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }
}
