// SPDX-License-Identifier: GPL-3.0-or-later
//
// CaptureService: composited screenshots via ScreenCaptureKit.
//
// Captures the *real* window-server output, so Metal-rendered content
// (the simulator / device panes, the terminal surface) appears exactly as
// a human sees it. An in-app self-render (`NSView.cacheDisplay`) would
// miss those layers, which is why the harness captures from outside.
//
// TCC: `SCShareableContent` requires the Screen Recording grant, and the
// grant attributes to the process that calls it (this resident harness),
// which is the whole reason it exists as a separate binary. When the grant
// is missing, ScreenCaptureKit throws and `captureFailed` carries a hint.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CaptureOutcome: Sendable {
    let path: String
    let width: Int
    let height: Int
    let scale: Double
}

/// A status-item capture: the badge window, or a report that it's absent
/// (hidden because the daemon owns zero booted sims).
enum StatusItemCapture: Sendable {
    case present(CaptureOutcome)
    case absent
}

enum CaptureError: Error {
    case noMatchingWindow(bundleID: String)
    /// More than one running application or eligible window owner can be
    /// the target, so capture selection is ambiguous: front-most (or
    /// smallest, for the status item) would pick between instances rather
    /// than between windows. A PNG of the wrong instance is worse than no
    /// PNG, because nothing about it looks wrong.
    case ambiguousTarget(bundleID: String, pids: [pid_t])
    /// `--out` names an existing path that isn't a regular file (a
    /// directory, socket, FIFO, symlink, device). Refused rather than
    /// treated as a PNG path: the hidden-badge path clears a stale file
    /// there, and we must never remove (or write over) a special file
    /// the caller pointed `--out` at (unlinking a live socket would break
    /// its listener; removing a directory would recurse).
    case outputNotAFile(path: String)
    /// `--out` exists but couldn't be inspected (permission, I/O). Distinct
    /// from "absent", so an inaccessible stale capture is never mistaken for
    /// a clear path.
    case outputUnreadable(path: String, underlying: String)
    /// Removing a stale capture at `--out` failed.
    case cleanupFailed(path: String, underlying: String)
    /// ScreenCaptureKit refused. Most often a missing Screen Recording
    /// grant for whichever process is attributed (the resident harness
    /// once bundled; the terminal app when run as a bare binary).
    case captureFailed(underlying: String)
}

enum CaptureService {
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

        let scale = backingScale(containing: window.frame, displays: content.displays)
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

    /// Screenshot just the daemon's menu-bar status-item window (the one
    /// showing the iPhone glyph and count), or report it absent.
    ///
    /// The status item is the daemon's own on-screen window (menu-bar
    /// extras are windows, at the overlay layer), so it is captured
    /// per-window like any other. The harness never captures a whole
    /// display, so this is the only way it can see the status item. "No
    /// such window" is a first-class result: it *is* the hidden-at-zero
    /// state, not an error.
    static func captureStatusItem(out path: String) async throws -> StatusItemCapture {
        try requireWritablePath(path)
        let content = try await shareableContent(onScreenWindowsOnly: true)
        let candidates = content.windows.map(candidate(from:))
        // Only once a badge is on screen does ambiguity change the answer.
        // Two daemons with no badge between them still means absent, and
        // that holds whichever one the caller meant; refusing there would
        // turn the ordinary hidden-at-zero-sims state into an error.
        let badgeOwners = WindowChooser.statusItemOwners(
            from: candidates,
            bundleID: DeviceTermBundleID.daemon
        )
        if !badgeOwners.isEmpty {
            try requireOneTarget(bundleID: DeviceTermBundleID.daemon, windowOwners: badgeOwners)
        }
        guard
            let chosen = WindowChooser.chooseStatusItem(
                from: candidates,
                bundleID: DeviceTermBundleID.daemon,
                frontToBack: frontToBackWindowIDs()
            ),
            let window = content.windows.first(where: { $0.windowID == chosen.windowID })
        else {
            // Hidden: leave no PNG at `out`, so a caller reusing a path that
            // held an earlier badge capture doesn't read the stale image as
            // if the item were still present. `requireWritablePath` already
            // rejected a directory, so this only unlinks a regular file.
            try removeStaleFile(at: path)
            return .absent
        }

        let scale = backingScale(containing: window.frame, displays: content.displays)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await capture(filter: filter, pointSize: window.frame.size, scale: scale)
        try PNGWriter.write(image, to: path)
        return .present(
            CaptureOutcome(path: path, width: image.width, height: image.height, scale: Double(scale))
        )
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
        let owners = TargetOwners.combined(
            processes: TargetOwners.live(bundleID: bundleID),
            windowOwners: windowOwners
        )
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
            area: Double(window.frame.width * window.frame.height),
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
