// SPDX-License-Identifier: GPL-3.0-or-later

/// The long-form `deviceterm agents` documentation surface.
///
/// `deviceterm help` lists the commands and `deviceterm help <command>`
/// reads one in full; `deviceterm agents` is the deeper workflow + triage
/// guide. The two stay disjoint in scope: help is organized by verb;
/// agents is organized by task and carries per-command
/// "broken-or-operator-error" checklists, the "Getting a sim into your
/// tab" recovery workflow, integration tips, and the pointer at the
/// permission model.
///
/// Lives as a pure constant so `Tests/CLITests` can assert content
/// invariants without spawning a process. Wrapped to 78 cols for any
/// 80-col terminal.
public enum AgentsText {
    /// The shape printed for `deviceterm agents`. Dispatch returns it as
    /// stdout and `CLIMain` writes it, exiting 0: same pattern as --help.
    public static let documentation = """
    deviceterm agents: workflow + triage guide for CLI users

    `deviceterm help` lists the commands, one line each, and
    `deviceterm help <command>` reads one in full. This guide is the
    companion organized by task instead: how a sim pane actually
    attaches to a tab, the gotchas you'll hit driving the common
    commands, where the env vars live, and the permission model.

    GETTING A SIM INTO YOUR TAB
      Pane creation is shim-driven. A sim pane appears in a tab
      when `xcrun simctl boot <UDID>` runs inside that tab. The
      deviceterm shim intercepts the boot and asks the daemon to
      attach the resulting sim to the calling session. Bypassing
      the shim (custom `idb`-style helpers, `simctl` against the
      Apple-shipped binary outside a tab) creates a sim that
      deviceterm has no knowledge of; `deviceterm pane list` will stay
      empty even after the sim is fully booted.

      If `deviceterm tap` / `swipe` / `crown` returns
      `no device pane in this tab`, run the diagnostic recipe:

        env | grep DEVICETERM     # confirms the tab's env is wired
        which xcrun            # confirms the shim is on PATH
        deviceterm pane list     # confirms the pane attached

      Expected env values inside a healthy deviceterm tab:

        DEVICETERM_SESSION        — UUID string, daemon's sessionId
        DEVICETERM_SESSION_CAP    — base64 capability token
        DEVICETERM_DAEMON_SOCK    — path to the daemon's UDS socket
        DEVICETERM_SHIM_DIR       — dir of shimmed binaries on PATH

      `which xcrun` should resolve to a path inside the deviceterm
      shim dir (e.g. `~/Library/Caches/deviceterm/sessions/<sid>/
      bin/xcrun`), NOT `/usr/bin/xcrun`. If it resolves to the
      system path, the shim isn't first on PATH and boots will
      not be intercepted. Open a fresh deviceterm tab to re-run the
      session-environment provisioning.

      The in-tab self-attach via shim is the implicit path. The
      explicit `deviceterm device attach <ref>` verb lets a session
      claim an unlinked or externally-booted sim (or mirror a
      physical device) without the shim path; see PERMISSIONS
      AND LINKAGE below.

    TRIAGE: IF A COMMAND SEEMS BROKEN, CHECK THESE FIRST

      swipe
        - If `deviceterm swipe` returned
          `ok ... dispatched=tap steps=1 durationMs=…`, the
          requested gesture collapsed to a tap-shape wire payload
          because `--duration` was below the one-frame floor
          (32 ms). Re-run with `--duration 100` or higher for a
          real drag. The `dispatched=tap` echo is your detection
          point. Bare `ok` from an older daemon means the same
          thing but doesn't surface the field.

      crown
        - On tight SwiftUI Float bindings like
          `.digitalCrownRotation(in: 0...1, by: 0.005)`, the
          streaming `--duration` path silently no-ops when the
          per-event delta falls below the watchOS recognizer's
          coalescing floor. The recorded transition was between
          0.97 and 1.08 IndigoWheel units per event at ~60 Hz
          cadence. Use single-shot
          `deviceterm crown N` (omit `--duration`) for fine
          placement: N = 1..8 maps roughly 0.18..0.95 of the
          binding range on sensitivity .medium.
        - On coarse scrollable lists, `--duration` works fine;
          the gap is specific to tight Float bindings.
        - `--duration` is in milliseconds, not seconds. A common
          misread is `--duration 1.5` thinking 1.5 s; that's
          1.5 ms and silently below the recognizer floor.
        - `--velocity` is decoded but silently ignored at the daemon
          (the SimulatorKit crown builder takes only a delta).
          Tuning it changes nothing; don't chase it as a knob.
        - Verify the watch pane is focused. `deviceterm ax tree`
          or `deviceterm ax sweep` should resolve a watch-shaped
          screen frame. If not, the pane lost focus and crown
          events go nowhere.

      ax tree / ax point / ax sweep
        - On watchOS, `deviceterm ax tree` often returns
          `{children: [], note: "..."}` by design. The bridge's
          `accessibilityChildren` walk is empty on this family.
          The `note` field points at the workaround:
          `deviceterm ax sweep` grid-walks `objectAtPoint:` to
          discover the elements directly. Use `--step <0..1>` to
          control sweep density (default 0.05).
        - A tree can come back short where the walk did run. The
          daemon hit-tests the screen centre when no descendant
          covers it; an element there that the tree never listed
          means the walk didn't reach everything, and the response
          carries `noteCode: "ax.treeIncomplete"` pointing at the
          same `deviceterm ax sweep` remedy. Absence from a tree
          carrying that note isn't evidence the element is off
          screen. One sample can prove an omission and can't rule
          one out, so an unnoted tree can still be short. Sweep
          before concluding an element isn't there.
        - A sweep carries a `note` of its own when it stopped at
          its time budget with grid left, alongside
          `truncated: true`. Read one before concluding an
          element isn't on screen: part of the grid went
          unqueried. The 0.02 floor plans 2500 cells;
          whether they fit the 10000ms default depends on
          the host and the device, so raise `--budget <ms>`
          (up to 60000) when a sweep comes back
          truncated. At the
          ceiling the note changes, because there is no larger
          budget to ask for: coarsen `--step` or retry when the
          pane is serving fewer accessibility reads.
        - `deviceterm ax point <x> <y>` resolves a single element
          at a normalized point, in the same displayed space the
          coordinate-bearing input verbs take. Faster than a
          sweep when you already know roughly where to look.
        - Node frames stay in displayed points so you can judge
          hit-target size. A node whose geometry produces an on-screen
          centre also carries `normalizedCenter: {x, y}` in the same
          normalized displayed space the coordinate-bearing input verbs
          take. Pass those values directly to `tap`, `ax point`, or
          another coordinate input.
        - `normalizedCenter` is optional. It is absent when the root
          scale or node frame is unusable, the centre is off-screen, or
          an older daemon produced the response. `ax sweep` children use
          the real preflight tree for their scale. The synthetic
          `AXSweepRoot` remains a 0,0,1,1 placeholder and has no
          `normalizedCenter`.
        - When their preflight yields a usable screen frame,
          `ax point` and `ax sweep` report it as `rootFrame`, in
          displayed points. Multiply a `normalizedCenter` by its
          `w` and `h` for point coordinates without a second
          `ax tree` call. It's absent when that frame was
          unusable, and on a sweep whose budget went before the
          preflight ran. `ax tree` publishes no `rootFrame`,
          because its own root frame is the scale.

      all input commands (tap, swipe, long-press, pinch, button,
      key, text, rotate, crown)
        - Pane attachment is a precondition. If the command
          returns `no device pane in this tab` (or
          `error.notFound` on the daemon side), see "Getting a
          sim into your tab" above; the most common cause is a
          boot that bypassed the shim.

    WORKFLOW RECIPES

      Boot a fresh sim and verify the pane attached:
        xcrun simctl list devices iPhone   # find UDID
        xcrun simctl boot <UDID>           # shim intercepts
        deviceterm pane list                 # pane row appears

      Tap a UI element you've located:
        deviceterm ax tree | jq \\
          '.tree.children[] | {label, frame, normalizedCenter}'
        deviceterm tap 0.2 0.1275
        # Copy normalizedCenter.x and normalizedCenter.y directly.
        # Keep frame.w and frame.h for point-size checks.

      Swipe a scrollable list down:
        deviceterm swipe 0.5 0.8 0.5 0.2 --duration 250

      Crown a tight SwiftUI Float binding to a value:
        deviceterm crown 5                    # ~half the range
        deviceterm crown -3                   # nudge back

      Type into a focused field:
        deviceterm text "hello world"

      Drive multiple panes with --pane disambiguation:
        deviceterm pane list                 # see all panes
        deviceterm tap 0.5 0.5 --pane <WATCH-UDID>

      Lock subsequent commands onto one pane with `with-pane`:
        deviceterm with-pane <WATCH-UDID> bash -c '
          deviceterm tap 0.5 0.5
          deviceterm crown 5
          deviceterm ax tree | jq
        '
        # DEVICETERM_TARGET_PANE is exported into the child shell; every
        # nested `deviceterm` call auto-targets the resolved pane without
        # --pane. <ref> can be a UDID, shortId, name, or paneId prefix.

      Spawn a fresh agent tab in the current window (needs a grant):
        deviceterm tab open
        deviceterm tab open --cwd ~/projects/app --command 'claude'
        # Requires a live automation grant; an ordinary tab is
        # refused with intent.automationRequired. Run it from a tab
        # opened via Shell > "Open Automation Tab". New tab appears
        # in the same window. The verb waits for the GUI to commit the
        # tab and mint its first terminal session, then returns the
        # window, tab, and terminal pane in one receipt. It does not
        # wait for shell readiness. --cwd sets the startup directory
        # (the CLI resolves relative / ~-prefixed paths against its
        # own CWD); --command is typed into the new shell after attach so
        # it runs once and the user lands at an interactive prompt.
        # `pane split --direction right` adds a terminal to this tab,
        # needs no grant, and returns the new terminal pane.

      Rename / focus / inspect existing tabs by shortId:
        deviceterm tab list                    # see open tabs
        deviceterm tab focus abc123             # focus it (grant)
        deviceterm tab move abc123 --window 22aa44 --index 0
        deviceterm tab rename "billing"         # rename current
        deviceterm tab show                     # panes + split layout
        deviceterm tab close abc123             # close that tab
        # "(grant)" marks a verb needing a live automation grant.
        # Both need it even when the target is your own tab:
        # selecting one can replace the visible tab and move terminal
        # focus, and moving one can shift other tabs' positions.

      Manage windows:
        deviceterm window open                  # new window (grant)
        deviceterm window list --all             # see all visible windows
        deviceterm window focus 22aa44           # stable ref (grant)
        deviceterm window close 22aa44           # index is metadata only

      Drive a terminal pane (run from an automation tab):
        deviceterm pane send-input term123 'echo hi\\n'
        # Writes the text into the resolved terminal pane as
        # though the user had typed it. control sequences flow
        # through libghostty's input pipeline. Authorization is a
        # live automation grant, not a role. Works from a tab
        # opened via Shell > "Open Automation Tab" (the GUI grants
        # that tab's session); from an ordinary agent tab it is
        # refused (intent.automationRequired).
        deviceterm pane send-input term123 --type-delay 45 -- 'ls\\n'
        # --type-delay <ms> animates the injection one character at a
        # time (for recording screencasts). Omit it for the instant
        # one-shot. The verb returns as soon as the typing is enqueued
        # (non-blocking); concurrent paced calls to one pane type out in
        # order. Delay is capped at 1000ms. See docs/DEMO.md for the
        # presenter-style recording workflow.

      Read a terminal pane (run from an automation tab):
        deviceterm pane capture-text term123 | grep error
        deviceterm pane capture-text term123 --json | jq -r .text
        deviceterm pane capture-text term123 --ansi --json | jq -r .text
        # Returns the resolved terminal's currently-visible viewport as
        # plain text. Viewport only; no scrollback or line-count
        # flags. --ansi keeps SGR color and style escapes, for display
        # rather than for reading: classify on the plain capture. Same
        # grant-gated authority as send-input: works from
        # an automation tab, refused from an agent tab. The intended
        # pairing is: pane send-input '<cmd>\\n' then wait for the prompt and
        # pane capture-text to read the output.

      Detach mode vs shutdown mode on close:
        deviceterm tab close --mode detach      # default; sim stays
                                             # booted as an orphan
        deviceterm tab close --mode shutdown    # shuts sim down

      Pipe JSON through jq for scripted decisions:
        deviceterm pane list --json |
          jq '.[] | select(.kind=="simulator")'
        deviceterm tab list --json | jq '.[] | select(.current).shortId'
        deviceterm tab show --json | jq '.layout'
        deviceterm window list --json | jq 'length'

      Boot and wait for the pane to render:
        xcrun simctl boot "$UDID"
        deviceterm wait pane rendering --pane "$UDID"
        # The wait probes current pane state immediately and blocks until
        # rendering or its 30000ms default deadline. Use --timeout <ms>
        # to choose another bound. wait.timeout exits 124; transport,
        # authentication, pane resolution, and decode failures retain
        # their own codes.

      Wait for an app element after a launch or tap:
        xcrun simctl launch "$UDID" com.example.App
        deviceterm wait ax --identifier login-button --role Button
        # --match contains reaches a label carrying a count or an
        # ellipsis. To act on a match, tap it directly:
        deviceterm tap --label Continue --match contains
        # Finds the element and taps it in one command, with no
        # coordinate crossing the shell. To see the coordinate
        # instead of tapping it:
        deviceterm wait ax --label Continue --match contains --print center
        # Writes a bare "x y" for the same element, to pass as tap's
        # two positional arguments. Both refuse with
        # wait.unreachable or wait.ambiguous rather than guess, and
        # a refusal sends no tap either way. What it writes differs:
        # --print center writes nothing at all, while tap --json
        # writes the usual error envelope to stdout, so test the
        # exit code rather than stdout emptiness. Read the full
        # match list with --json; matches[0] is not guaranteed to
        # carry a coordinate.
        # A wait that ends on an observation which couldn't see
        # the whole pane reports that rather than wait.timeout.
        # wait.inconclusive means coverage fell short, and
        # carries the daemon's note and noteCode.
        # wait.unsupported means full coverage was unavailable:
        # either the pane has no accessibility capability and
        # nothing was observed, or the family's tree walk didn't
        # enumerate and the root it returned carries a noteCode.
        # That root is observable, so a query it matches succeeds.

      Observe a long-running event stream:
        deviceterm events | jq --unbuffered \\
          'select(.type=="pane.stateChanged")'
        # Events have no replay or subscription-ready record. Use wait
        # for one-shot convergence; use events as a latency signal or
        # long-running observation stream.

    INTEGRATION TIPS

      Output modes
        Data commands (lists, receipts) support `--json` for
        machine-readable output. Lists become JSON arrays;
        receipts become JSON objects. The keys are not always the
        echo line's: `pane` splits into `paneId` and `shortId`, and
        a tap's `matches` is `matchCount`. JSON also carries fields
        the space-separated echo line has no way to quote, such as
        a selector-driven tap's `label` and `identifier`.
        Synthesized with `encodeIfPresent`, so nil fields are
        omitted rather than encoded as `null`.

        In JSON mode, typed failures emit a newline-terminated
        `{"error": ...}` object on stdout. They preserve the human
        diagnostic on stderr and the nonzero exit status. Branch
        on `.error.code`; do not parse `.error.message` or stderr
        prose. Command-specific failures not yet using the typed
        contract may still produce empty stdout.

        Documentation commands (`deviceterm --help` and `deviceterm
        agents`) stay text-only; the `--json` flag is accepted
        for consistency but the output is the same prose. AX commands
        always emit JSON. Successes use their usual `tree` or
        `element` wrapper; typed failures use the `error` envelope
        even without `--json`, including malformed AX invocations.
        `events` keeps its JSON Lines stream and human-readable
        stream errors.

      Identifiers
        Workspace lists come from the GUI's live projection, so a
        `tab list` row is one real tab and a `pane list` row is one
        real layout leaf, including terminal panes.

        Every workspace object carries:
        - `id`: the canonical UUID. A terminal pane's id is its
          daemon `sessionId`.
        - `shortId`: six lowercase hex characters derived from a
          window or tab UUID, or a six-character lowercase Crockford
          base32 handle minted for a pane.
        - `name`: an optional user-assigned stable name.

        Refs are raw, case-insensitive strings. Window and tab refs
        accept an exact short ID, exact full UUID, exact unique name,
        or unique full-UUID prefix. Pane refs also accept an exact
        device key or unique full-ID prefix. Names never match by
        prefix. The one-based window index is display metadata, not
        a reference.

        `tab show --json` returns `{tab, panes, layout}`. The layout
        recursively identifies pane leaves and split axis/extents.
        A pane row reports `kind`, `capabilities`, and one of
        `terminal`, `simulator`, or `device`. Branch on those fields
        instead of grouping daemon session rows yourself.

      Daemon discovery
        The CLI talks to one socket, named by
        `DEVICETERM_DAEMON_SOCK` in your tab's env (falling back
        to ~/Library/Application Support/deviceterm/daemon.sock).
        Reaching that socket starts nothing. The LaunchAgent the
        GUI registers declares a mach service, not this socket,
        so only the GUI's XPC traffic demand-launches the daemon;
        CLI traffic against a stopped daemon just fails. That's
        why `deviceterm doctor` reports socket reachability as
        its own check.

      Session lifetime
        The daemon idle-exits once nothing needs it: no connected
        GUI or CLI peer, no live mirror pane, no deviceterm-owned
        booted sim. It keeps no session state on disk. After a
        daemon-only restart the GUI re-supplies its live sessions,
        and an in-tab call retries for about a second while that
        lands, so the same session id usually keeps working
        without reopening the tab. The retry is bounded, not a
        guarantee: if restoration hasn't finished, the call fails
        and you run it again. A cold start with no GUI (both
        processes gone) is the case that loses sessions: booted
        sims survive and come back through the orphan-recovery
        sheet on the next GUI launch.

    PERMISSIONS AND LINKAGE

      The trust boundary is the terminal session
        `DEVICETERM_SESSION_CAP` is injected into the terminal pane's
        shell. It proves you hold the session's credential, but the
        cap ALONE is not enough: it is inherited env, readable by any
        same-uid process. The daemon also checks your process's kernel
        provenance: your POSIX session, controlling tty, and
        session-leader start time have to match the terminal the
        session is bound to, or a live ancestor's have to. So a
        process elsewhere that scraped the cap is refused: it has no
        ancestor in the tab. Processes started normally in the tab
        inherit its controlling terminal and may drive the session's
        panes, which is why the cap is intentionally not a secret
        from those children. A detached process (`setsid`, a
        daemonized helper) stays authorized only while its parent
        chain reaches the tab, which is what lets an agent harness
        drive the session it runs inside; orphan it and the next call
        is refused. Sibling terminal panes are separate sessions with
        their own caps and anchors. A stale/foreign cap or a wrong
        terminal is a hard reject.

      Roles
        Two roles exist: `agent` (default) and `automation`. The
        role is fixed for the session's lifetime and readable from
        `$DEVICETERM_SESSION_ROLE`. The role is descriptive metadata,
        not an authorization gate. A live automation grant independently
        authorizes workspace creation and focus, tab movement, and
        terminal-pane input and capture: tab open, tab focus, tab move,
        window open, window focus, pane focus, pane send-input, and
        pane capture-text. `deviceterm help` names
        your role in its header but lists every verb regardless. A
        listed command may be refused because the connection lacks
        the required authorization.

        An automation role is minted only through the validated GUI
        path, exposed as Shell → Open Automation Tab. The daemon
        enforces that rather than trusting the caller: a mint request
        arriving over the CLI's
        socket is refused outright, and one arriving from the GUI is
        accepted only after the peer's code signature is checked
        against the daemon's own. There is no CLI verb for it and
        constructing the raw request by hand does not work.

      Authority boundaries
        These operations use different enforcement paths:
        - Linkage-mutation (moving a pane to a different tab) —
          not supported by any path. `deviceterm device attach
          <ref>` naming a device already attached elsewhere is
          rejected rather than relinked, and the GUI's pane drag
          refuses cross-tab drops. Note this is the verb and the
          view declining, not the daemon: the underlying
          `pane.attach` wire method carries a relink flag that the
          shim's auto-attach sets, and the daemon forwards it
          without checking who asked.
        - Role escalation (agent → automation) — Shell → Open
          Automation Tab. The daemon refuses an automation mint
          over the CLI socket outright.
        - Workspace-wide mutation (tab open / focus / move,
          pane focus, window open / focus) — a live automation grant, checked
          by the daemon on every request. The role string alone
          does not carry it.
        - Protection mutation for someone else — target-tab ownership
          or a live automation grant. A grant can protect a visible,
          unprotected foreign tab, but it never reveals a foreign
          protected tab and therefore cannot unprotect one. The atomic
          batch RPC behind the GUI gate is accepted only from the
          signature-validated GUI peer, never a raw CLI socket.

      Pane reach
        Device panes are scoped to the tab through a session
        cohort the GUI keeps in sync with the tab's terminals.
        Every terminal session in the tab reaches the tab's
        panes, whichever of them attached the device; a paneId
        in another tab is refused with the same error as an
        unknown one. Only the GUI spans tabs. Closing one
        terminal of a split hands its panes to the survivors,
        and a freshly split terminal can see a brief refusal
        before the GUI registers it with the daemon; retry.
        Workspace close and rename are narrower for terminal panes:
        without a grant, the target terminal session must equal the
        caller. Simulator and physical-device mutations retain tab
        ownership plus this daemon cohort check.
        That gets you per-tab pane authority between agents in
        separate tabs, and nothing more: they still share a
        uid, a filesystem, and every other process on the
        machine.

    KNOWN GOTCHAS

      A daemon restart pauses calls; a cold start loses sessions
        A fresh daemon starts with no sessions. If the GUI is
        still up it re-supplies them, so an in-tab call sees a
        brief retryable failure and then usually works again;
        retry it yourself if it doesn't. If both
        processes went away, the sessions are gone. Booted sims
        survive either way (they're owned by Apple's simctl, not
        by the daemon) and re-surface through the orphan-recovery
        sheet on next GUI launch.

      Sims booted outside deviceterm are invisible
        Booting via Simulator.app's GUI or via a stock terminal
        running `xcrun simctl boot` creates a sim that has no
        deviceterm pane. `deviceterm pane list` won't show it.
        `deviceterm device attach <udid>` lets an agent (or
        automation) claim such an externally-booted sim into
        the current tab; the in-tab self-attach via shim is the
        other path.

      What's NOT in the deviceterm CLI by design
        - No simctl wrappers (`install`, `launch`, `push`,
            `location`, `appearance`, `status_bar`,
            `content_size`, `log`, `io screenshot`, `io
          recordVideo`). Use `xcrun simctl` for those because Apple's
          tool is the source of truth.
        - No MCP / model-context layer. deviceterm is the
          terminal; the agent is the agent.
        - No recipe library. Workflow scripting is the shell's
          job; `deviceterm` provides primitives. Task-shaped
          recipes live outside the binary, in the agent skills:
          https://github.com/sethdeckard/deviceterm-skills

    SEE ALSO

      deviceterm help            the command list, one line per verb
      deviceterm help <command>  that command's reference page
      deviceterm doctor          diagnose env + state

    INTEGRATION

      For machine-parseable surfaces (--json shapes, event-stream
      delivery semantics, stability commitments), read the
      integration guide:

        https://github.com/sethdeckard/deviceterm/blob/main/docs/INTEGRATION.md

      For workspace control, waits, automation grants, and event
      workflows, read the automation guide:

        https://github.com/sethdeckard/deviceterm/blob/main/docs/AUTOMATION.md

      Audience: automation, agents, CI gates, tooling that needs
      to depend on deviceterm's wire shape across versions. Everything
      in this `deviceterm agents` guide is human-prose;
      docs/INTEGRATION.md is the contract.

    """
}
