// SPDX-License-Identifier: GPL-3.0-or-later
//
// StatusItemController: the daemon's menu bar presence.
//
// One `NSStatusItem` in the system status bar. Badge format is
// the single source of truth referenced from `docs/ARCHITECTURE.md`,
// the `Tests/Manual/` checklists, and the e2e playbook's status-item
// capture:
//
//   - Hidden when 0 owned booted sims.
//   - Visible when N > 0, as a monochrome iPhone glyph followed by N.
//
// The glyph is an SF Symbol drawn as a template image, so AppKit owns
// its coloring and renders it for the status button's current
// appearance and state rather than burning in one color.
//
// Beyond the badge, the item carries an `NSMenu` that lists every
// owned booted sim with a "Shut Down …" action (plus a "Shut Down
// All"). A detached sim stays owned and counted, so this is how a user
// reclaims one that outlived its window once the main GUI is gone.
//
// The controller polls `DeviceCoordinator.listOwnedBooted()` on a
// slow timer and derives *both* the badge and the menu from that one
// snapshot per tick, so they can't disagree across two CoreSimulator
// reads.

import AppKit

/// Build the per-sim shutdown menu entries from a snapshot of owned
/// booted sims. Pure (no AppKit, no actor) so it's unit-testable;
/// the menu wiring below depends on it.
///
/// Titles disambiguate duplicate device names: a name unique within
/// the snapshot is shown bare; a name shared by two or more sims is
/// suffixed with a short UDID prefix (`name — 1A2B3C4D`) so the user
/// can tell them apart. The shutdown action is always keyed by the
/// full `udid`, never the title, so disambiguation never changes which
/// sim gets shut down. Order follows the input (CoreSimulator
/// enumeration order).
func statusMenuEntries(_ sims: [OwnedSim]) -> [(title: String, udid: String)] {
    var nameCounts: [String: Int] = [:]
    for sim in sims { nameCounts[sim.name, default: 0] += 1 }
    return sims.map { sim in
        let isDuplicate = (nameCounts[sim.name] ?? 0) > 1
        let title = isDuplicate
            ? "\(sim.name) — \(shortUDID(sim.udid))"
            : sim.name
        return (title: title, udid: sim.udid)
    }
}

/// One sim, formatted for menu display, plus the group header it
/// belongs to. Pure value type so the grouping helper below can be
/// unit-tested without instantiating SessionManager or AppKit menus.
public struct StatusMenuRow: Sendable, Equatable {
    /// The user-facing label for the device, already disambiguated
    /// against duplicate names per `statusMenuEntries`'s rules.
    public let title: String
    public let udid: String
    /// Group header for this row. The status item renders each
    /// distinct value as a disabled section header; rows that share
    /// the same value cluster underneath it. nil signals
    /// "ungrouped", used for orphan sims whose owning session has
    /// been closed.
    public let groupHeader: String?
}

/// Group owned sims by their owning session's display name. Sims
/// whose session has been closed (or never had one) collect under a
/// `nil`-header bucket that the menu renders as "Unlinked".
///
/// The function is parameterized by a `nameForSession` closure so the
/// menu layer doesn't depend on SessionManager directly: tests pass
/// a stub mapping, the daemon wires it to `sessionManager.session(id:)
/// ?.name`. Returns rows in CoreSimulator enumeration order (the
/// input order); section headers don't reorder anything.
public func groupedStatusMenuRows(
    _ sims: [OwnedSim],
    nameForSession: (UUID) -> String?
) -> [StatusMenuRow] {
    let titledEntries = statusMenuEntries(sims)
    return zip(sims, titledEntries).map { sim, entry in
        let header: String? = sim.sessionId.flatMap(nameForSession)
        return StatusMenuRow(
            title: entry.title,
            udid: entry.udid,
            groupHeader: header
        )
    }
}

/// First 8 hex of a UDID, uppercased, enough to disambiguate two
/// sims of the same device type at a glance without dumping the full
/// UUID into a menu title.
private func shortUDID(_ udid: String) -> String {
    String(udid.prefix(8)).uppercased()
}

@MainActor
public final class StatusItemController {
    /// SF Symbol drawn as a template image ahead of the count. Held as
    /// a constant so a typo is one edit away from the test that pins
    /// it, rather than buried in the button setup.
    nonisolated public static let symbolName = "iphone"

    /// Product name shown as the menu's title row. Hardcoded rather
    /// than read from the bundle: the daemon's own `CFBundleName` is
    /// `deviceterm-daemon` (a helper, not a product), and the host
    /// app is only reachable by walking up out of
    /// `Contents/Library/LoginItems`, which doesn't resolve at all in
    /// an unbundled dev run. A fork rebrands by editing this line.
    /// (The runtime bundle-id derivation in `PeerIdentity` is a
    /// security check, not branding; it has different constraints.)
    nonisolated public static let appDisplayName = "DeviceTerm"

    /// `NSStatusBar.system.statusItem` is created with variable
    /// length so the title sizes itself. We hide by setting
    /// `isVisible = false` rather than removing the item; either
    /// works but `isVisible` keeps the slot reserved for when the
    /// count next ticks above zero.
    private let statusItem: NSStatusItem
    private let coordinator: DeviceCoordinator
    private let paneCoordinator: PaneCoordinator
    private let sessionManager: SessionManager?
    private let pollIntervalSeconds: TimeInterval
    private var pollTask: Task<Void, Never>?

    public init(
        coordinator: DeviceCoordinator,
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager? = nil,
        pollIntervalSeconds: TimeInterval = 1.0
    ) {
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        self.coordinator = coordinator
        self.paneCoordinator = paneCoordinator
        self.sessionManager = sessionManager
        self.pollIntervalSeconds = pollIntervalSeconds
        self.statusItem.isVisible = false
        configureButton()
    }

    /// Count text shown trailing the glyph; nil hides the item
    /// entirely. Pinned by tests so the shape can't silently drift.
    /// `nonisolated` because it's pure: no AppKit, no state.
    nonisolated public static func titleForCount(_ count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }

    /// Install the glyph once, at construction: every refresh changes
    /// only the count, so rebuilding an `NSImage` per refresh would be
    /// pure waste.
    ///
    /// `isTemplate` is the load-bearing line: it hands the glyph's
    /// coloring to AppKit instead of burning in one color.
    /// `accessibilityDescription` labels the glyph for VoiceOver,
    /// which otherwise has only a bare digit to read.
    ///
    /// If the symbol can't be created, the badge falls back to the
    /// count alone.
    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: Self.symbolName,
            accessibilityDescription: "Booted Simulators"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        )
        // Set on the *derived* image: `withSymbolConfiguration` vends a
        // new instance, so flagging the original wouldn't carry over.
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
    }

    public func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        statusItem.isVisible = false
    }

    /// Force one refresh now. Tests + the daemon's startup code
    /// call this to sync state without waiting for the next poll.
    public func refresh() async {
        let sims = await coordinator.listOwnedBooted()
        // Resolve owning-session names up front (one actor message
        // per distinct sessionId) so `apply` can stay synchronous
        // and the menu state never spans multiple await points
        // where the snapshot could drift.
        // Pick the best human-readable handle the session offers: a
        // user-set `name` (worktree branch / `deviceterm tab rename`)
        // first, then the internal `label`, then `shortId` (the
        // Crockford base32 handle the CLI's `tabs.list` exposes).
        // Falling back to `shortId` keeps a live, owned session out
        // of the menu's "Unlinked" bucket. That bucket is for sims
        // whose owning session is actually gone, NOT for a tab whose
        // user didn't name it. Missing only when the session itself
        // has been closed between the device snapshot and this
        // resolution.
        var names: [UUID: String] = [:]
        if let sessionManager {
            for sessionId in Set(sims.compactMap(\.sessionId)) {
                if let state = await sessionManager.session(id: sessionId) {
                    names[sessionId] = state.name
                        ?? state.label
                        ?? state.shortId
                }
            }
        }
        apply(sims, sessionNames: names)
    }

    /// Drive both the badge and the menu from one owned-booted
    /// snapshot, so the visible count and the menu's entry list are
    /// always consistent. `sessionNames` is the pre-resolved
    /// sessionId → display name map; missing keys land in the
    /// "Unlinked" group.
    private func apply(_ sims: [OwnedSim], sessionNames: [UUID: String]) {
        if let title = Self.titleForCount(sims.count) {
            statusItem.button?.title = title
            statusItem.isVisible = true
        } else {
            statusItem.isVisible = false
        }
        rebuildMenu(sims, sessionNames: sessionNames)
    }

    /// Non-actionable title row naming the app this menu belongs to.
    /// Nothing else in the menu says so: the badge is a generic phone
    /// glyph and every row below names a *simulator*, so without this
    /// the menu reads as Simulator.app's or Xcode's. That matters most
    /// in exactly the case the status item exists for, where the GUI
    /// has exited and this menu is the only DeviceTerm surface left.
    ///
    /// Semibold, so it reads as a title rather than as another session
    /// group header (those are plain disabled rows). Setting
    /// `attributedTitle` overrides AppKit's automatic dimming of a
    /// disabled item, so the secondary color is applied explicitly.
    private func appTitleItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.appDisplayName, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: Self.appDisplayName,
            attributes: [
                // Take the size from the menu font so the title shares
                // a baseline size with the rows below it, whatever
                // that size turns out to be.
                .font: NSFont.systemFont(
                    ofSize: NSFont.menuFont(ofSize: 0).pointSize,
                    weight: .semibold
                ),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        return item
    }

    private func rebuildMenu(_ sims: [OwnedSim], sessionNames: [UUID: String]) {
        let menu = NSMenu()
        menu.addItem(appTitleItem())
        menu.addItem(.separator())
        let rows = groupedStatusMenuRows(sims) { sessionNames[$0] }
        var lastHeader: String?? = .none
        for row in rows {
            // Insert a disabled section header whenever the group
            // header changes. `nil` headers (orphan sims whose owning
            // session is gone) read as "Unlinked".
            let display = row.groupHeader ?? "Unlinked"
            if lastHeader != .some(row.groupHeader) {
                if lastHeader != .none { menu.addItem(.separator()) }
                let header = NSMenuItem(title: display, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                lastHeader = .some(row.groupHeader)
            }
            menu.addItem(simSubmenuItem(row: row))
        }
        if sims.count > 1 {
            menu.addItem(.separator())
            let all = NSMenuItem(
                title: "Shut Down All",
                action: #selector(shutDownAll(_:)),
                keyEquivalent: ""
            )
            all.target = self
            menu.addItem(all)
        }
        statusItem.menu = menu
    }

    /// One row in the status menu: the device name as the top-level
    /// item, with a submenu carrying the per-sim actions (Shut Down,
    /// Open in Simulator.app, Reveal in Finder). The submenu items
    /// carry the UDID on `representedObject` so the @objc handlers
    /// can dispatch without round-tripping a title.
    private func simSubmenuItem(row: StatusMenuRow) -> NSMenuItem {
        let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: row.title)
        let shutDown = NSMenuItem(
            title: "Shut Down",
            action: #selector(shutDownSim(_:)),
            keyEquivalent: ""
        )
        shutDown.target = self
        shutDown.representedObject = row.udid
        submenu.addItem(shutDown)
        let openInSim = NSMenuItem(
            title: "Open in Simulator.app",
            action: #selector(openSimInSimulatorApp(_:)),
            keyEquivalent: ""
        )
        openInSim.target = self
        openInSim.representedObject = row.udid
        submenu.addItem(openInSim)
        let reveal = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(revealSimInFinder(_:)),
            keyEquivalent: ""
        )
        reveal.target = self
        reveal.representedObject = row.udid
        submenu.addItem(reveal)
        item.submenu = submenu
        return item
    }

    /// Bridge the synchronous AppKit menu action to the actor-isolated,
    /// throwing `DeviceCoordinator.shutdown(udid:)`. The udid rides on
    /// the item's `representedObject` (set in `rebuildMenu`), never the
    /// title, so a disambiguated title can't misroute the action. After
    /// shutdown, which also releases ownership, refresh so the badge
    /// and menu reconcile immediately rather than on the next tick.
    @objc
    private func shutDownSim(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.shutDown(udid: udid)
            await self.refresh()
        }
    }

    @objc
    private func shutDownAll(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-read the live set rather than trusting a snapshot
            // captured when the menu was built. A sim may have shut
            // down externally between the build and the click.
            let sims = await self.coordinator.listOwnedBooted()
            for sim in sims {
                await self.shutDown(udid: sim.udid)
            }
            await self.refresh()
        }
    }

    /// Foreground the sim's window in Apple's `Simulator.app`.
    /// Resolves Simulator.app through Launch Services so the active
    /// `xcode-select` / Xcode-beta install wins, same path as the
    /// Device > Open in Simulator.app menu item in the GUI. No
    /// daemon state changes.
    @objc
    private func openSimInSimulatorApp(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iphonesimulator"
        )
        guard let url else {
            FileHandle.standardError.write(
                Data(
                    ("deviceterm-daemon: Simulator.app not found in Launch Services "
                        + "(open Xcode once to register it)\n").utf8
                )
            )
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["-CurrentDeviceUDID", udid]
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared
                    .openApplication(at: url, configuration: config)
            } catch {
                FileHandle.standardError.write(
                    Data(
                        "deviceterm-daemon: openApplication failed: \(error)\n".utf8
                    )
                )
            }
        }
    }

    /// Reveal the sim's data directory in Finder. CoreSimulator stores
    /// each device under `~/Library/Developer/CoreSimulator/Devices/
    /// <udid>/`; this is the canonical "what's on disk for this sim"
    /// entry point.
    @objc
    private func revealSimInFinder(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            .appendingPathComponent(udid)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Converge on the shared shutdown path so a sim killed from the
    /// menu also drives its pane into `.shutdown` (the overlay), not a
    /// frozen frame, the same transition the shim event and the
    /// `device.shutdown` RPC use.
    private func shutDown(udid: String) async {
        do {
            try await DeviceMethods.shutdownConverged(
                udid: udid,
                coordinator: coordinator,
                paneCoordinator: paneCoordinator
            )
        } catch {
            FileHandle.standardError.write(
                Data(
                "deviceterm-daemon: shutdown failed for \(udid): \(error)\n".utf8
            )
                )
        }
    }

    private func runPollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(
                nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000)
            )
        }
    }
}
