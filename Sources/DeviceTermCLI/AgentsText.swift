// SPDX-License-Identifier: GPL-3.0-or-later
//
// AgentsText: the long-form `deviceterm agents` documentation surface.
//
// `deviceterm help` lists the commands and `deviceterm help <command>`
// reads one in full; `deviceterm agents` is the deeper workflow + triage
// guide. The two stay disjoint in scope: help is organized by verb;
// agents is organized by task and carries
// per-command "broken-or-operator-error" checklists, the load-bearing
// "Getting a sim into your tab" section, integration tips, and the
// pointer at the permission model.
//
// Lives as a pure constant so `Tests/CLITests` can assert content
// invariants without spawning a process. Wrapped to 78 cols for any
// 80-col terminal.

public enum AgentsText {
    /// The shape printed for `deviceterm agents`. main.swift writes
    /// this to stdout and exits 0: same pattern as --help.
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
      deviceterm has no knowledge of; `deviceterm panes list` will stay
      empty even after the sim is fully booted.

      If `deviceterm tap` / `swipe` / `crown` returns
      `no device pane in this session`, run the diagnostic recipe:

        env | grep DEVICETERM     # confirms the tab's env is wired
        which xcrun            # confirms the shim is on PATH
        deviceterm panes list     # confirms the pane attached

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
        - `deviceterm ax point <x> <y>` resolves a single element
          at a normalized point. Faster than a sweep when you
          already know roughly where to look.

      all input commands (tap, swipe, long-press, pinch, button,
      key, text, rotate, crown)
        - Pane attachment is a precondition. If the command
          returns `no device pane in this session` (or
          `error.notFound` on the daemon side), see "Getting a
          sim into your tab" above; the most common cause is a
          boot that bypassed the shim.

    WORKFLOW RECIPES

      Boot a fresh sim and verify the pane attached:
        xcrun simctl list devices iPhone   # find UDID
        xcrun simctl boot <UDID>           # shim intercepts
        deviceterm panes list                 # pane row appears

      Tap a UI element you've located:
        deviceterm ax tree | jq '.tree'       # locate element
        deviceterm tap 0.5 0.5                # tap normalized coords

      Swipe a scrollable list down:
        deviceterm swipe 0.5 0.8 0.5 0.2 --duration 250

      Crown a tight SwiftUI Float binding to a value:
        deviceterm crown 5                    # ~half the range
        deviceterm crown -3                   # nudge back

      Type into a focused field:
        deviceterm text "hello world"

      Drive multiple panes with --pane disambiguation:
        deviceterm panes list                 # see all panes
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

      Spawn a fresh agent tab in the current window:
        deviceterm tab open
        deviceterm tab open --cwd ~/projects/app --cmd 'claude'
        # New tab appears in the same window. The verb returns once
        # the GUI accepts the route; the new tab's session id isn't
        # reflected back (fire-and-forget). --cwd sets the shell's
        # startup directory (the CLI resolves relative / ~-prefixed
        # paths against its own CWD); --cmd is typed into the new
        # shell after attach so it runs once and the user lands at
        # an interactive prompt. Same flags on `pane open --terminal`.

      Rename / select / inspect existing tabs by shortId:
        deviceterm tabs list                    # see open tabs
        deviceterm tab select --tab abc123      # focus tab abc123
        deviceterm tab rename "billing"         # rename current
        deviceterm tab info                     # role + linked panes
        deviceterm tab close --tab abc123       # close that tab

      Manage windows:
        deviceterm window open                  # new window
        deviceterm windows list                 # see all windows
        deviceterm window focus --window 2      # bring window 2 forward
        deviceterm window close --window 2      # close window 2

      Cross-tab shell control (run from an orchestrator tab):
        deviceterm tab send-input --tab abc123 'echo hi\\n'
        # Writes the text into the resolved tab's terminal as
        # though the user had typed it. control sequences flow
        # through libghostty's input pipeline. Authorization is a
        # live orchestration grant, not a role. Works from a tab
        # opened via Shell > "Open Orchestrator Tab" (the GUI grants
        # that tab's session); from an ordinary agent tab it is
        # refused (error.role_violation).
        deviceterm tab send-input --tab abc123 --type-delay 45 -- 'ls\\n'
        # --type-delay <ms> animates the injection one character at a
        # time (for recording screencasts). Omit it for the instant
        # one-shot. The verb returns as soon as the typing is enqueued
        # (non-blocking); concurrent paced calls to one tab type out in
        # order. Delay is capped at 1000ms. See docs/DEMO.md for the
        # presenter-style recording workflow.

      Cross-tab screen read (run from an orchestrator tab):
        deviceterm tab capture --tab abc123 | grep error
        deviceterm tab capture --tab abc123 --json | jq -r .text
        # Returns the resolved tab's currently-visible viewport as
        # plain text. Viewport only; no scrollback or line-count
        # flags. Same grant-gated authority as send-input: works from
        # an orchestrator tab, refused from an agent tab. The intended
        # pairing is: tab send-input '<cmd>\\n' then wait for the prompt and
        # tab capture to read the output.

      Detach mode vs shutdown mode on close:
        deviceterm tab close --mode detach      # default; sim stays
                                             # booted as an orphan
        deviceterm tab close --mode shutdown    # shuts sim down

      Pipe JSON through jq for scripted decisions:
        deviceterm panes list --json | jq '.[] | select(.family=="watch")'
        deviceterm tabs current --json | jq '.shortId'
        deviceterm tab info --json | jq '.role'
        deviceterm windows list --json | jq 'length'

      Boot-wait via the event stream (no polling):
        deviceterm events | jq --unbuffered \\
          'select(.type=="pane.stateChanged" and .state=="rendering")' \\
          | head -n 1
        # Blocks until the next pane reaches "rendering" state, then
        # exits. Use jq's `select` to filter on type/state/udid/pane;
        # `head -n 1` to one-shot, or omit to keep watching.

    INTEGRATION TIPS

      Output modes
        Data commands (lists, receipts) support `--json` for
        machine-readable output. Lists become JSON arrays;
        receipts become JSON objects with the same fields as the
        human-mode echo line (synthesized with `encodeIfPresent`;
        nil fields are omitted rather than encoded as `null`).
        Errors stay on stderr in human form regardless of mode,
        so `deviceterm ... --json | jq` works on the happy path.

        Documentation commands (`deviceterm --help` and `deviceterm
        agents`) stay text-only; the `--json` flag is accepted
        for consistency but the output is the same prose. AX
        commands already emit JSON natively; `--json` is a
        no-op there too.

      Identifiers
        Every tab + pane carries three identifiers:
        - `shortId` — 6-char Crockford base32 (lowercase, no
          i/l/o/u). Immutable, daemon-minted, per-container
          unique. The most-typeable handle; surfaced in `tabs
          list`, `panes list`, and the pane= column of every
          receipt.
        - `name` — optional, and it means a different thing on
          each container. A session's name is fixed at
          `session.create` and never rewritten. The GUI derives
          one from the git worktree branch, when it finds one, for
          a new tab's first terminal session; terminals added to
          an existing tab get their own sessions and start
          unnamed. `deviceterm tab rename [<name>]` retitles the
          tab in the GUI without touching the field, so `tabs
          list` keeps reporting the original. A pane's name is its
          own field and is nil today: `deviceterm pane rename` is
          scaffolded but deferred to the linkage refinement.
        - `sessionId` / `paneId` — canonical UUIDs. Always
          unambiguous; use when scripting against output from
          older daemons that may not emit `shortId`.

        `tabs list --json` also carries `displayTitle`: the GUI's
        live tab label (the shell's OSC title, a manual rename), in
        the normalized, bounded form the daemon holds. It is NOT an
        identifier and resolves no `--tab <ref>`, since it changes
        as often as the shell redraws its prompt, and it is null
        whenever it would say nothing `name` doesn't already. Read
        it to see what a tab is doing; key on `shortId` or
        `sessionId` to act on one.

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
        session is bound to. So a process elsewhere that scraped the
        cap is refused. What earns trust is sitting in that terminal,
        not descending from the shell. Anything you run there shares
        the controlling terminal and may drive the session's pane(s),
        which is why the cap is intentionally not a secret from those
        children; but something that detaches from the terminal
        (`setsid`, a daemonized helper) stops matching even though the
        shell is its ancestor. Sibling terminal panes are separate
        sessions with their own caps and anchors. A stale/foreign cap
        or a wrong terminal is a hard reject.

      Roles
        Two roles exist: `agent` (default) and `orchestrator`. The
        role is fixed for the session's lifetime and readable from
        `$DEVICETERM_SESSION_ROLE`. The role is descriptive metadata,
        not an authorization gate; cross-tab verbs are authorized by a
        live orchestration grant, independently of role. `deviceterm
        help` names your role in its header but lists every verb
        regardless. A listed command may be refused because the
        connection lacks the required authorization.

        An orchestrator role is minted only through the validated GUI
        path, exposed as Shell → Open Orchestrator Tab. The daemon
        enforces that rather than trusting the caller: a mint request
        arriving over the CLI's
        socket is refused outright, and one arriving from the GUI is
        accepted only after the peer's code signature is checked
        against the daemon's own. There is no CLI verb for it and
        constructing the raw request by hand does not work.

      Human-only actions
        Three things route through the GUI rather than a CLI verb.
        The first is a convention the CLI follows; the other two the
        daemon enforces:
        - Linkage-mutation (moving a pane to a different tab) —
          not supported by any path. `deviceterm device attach
          <ref>` naming a device already attached elsewhere is
          rejected rather than relinked, and the GUI's pane drag
          refuses cross-tab drops. Note this is the verb and the
          view declining, not the daemon: the underlying
          `pane.attach` wire method carries a relink flag that the
          shim's auto-attach sets, and the daemon forwards it
          without checking who asked.
        - Role escalation (agent → orchestrator) — Shell → Open
          Orchestrator Tab. The daemon refuses an orchestrator mint
          over the CLI socket outright.
        - Privacy-mutation for someone else — a `tab set-private`
          only touches a tab the caller owns a terminal in. The GUI
          enforces that owner gate, and the atomic batch RPC behind
          it is accepted only from the signature-validated GUI peer,
          never a raw CLI socket. Orchestrator is not special-cased.

      Pane reach
        Panes are linked to an owning session, and the daemon
        authorizes every pane-targeted call against the current
        ownership. Your session reaches only its own panes; a paneId
        owned by another session is refused with the same error as
        an unknown one, so a sibling terminal pane's sim is not
        yours to drive even inside your own tab. Only the GUI spans
        sessions. That gets you separated pane authority between two
        agents in separate terminal panes, and nothing more: they
        still share a uid, a filesystem, and every other process on
        the machine.

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
        deviceterm pane. `deviceterm panes list` won't show it.
        `deviceterm device attach <udid>` lets an agent (or
        orchestrator) claim such an externally-booted sim into
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
          job; `deviceterm` provides primitives.

    SEE ALSO

      deviceterm help            the command list, one line per verb
      deviceterm help <command>  that command's reference page
      deviceterm doctor          diagnose env + state

    INTEGRATION

      For machine-parseable surfaces (--json shapes, event-stream
      delivery semantics, stability commitments), read the
      integration guide:

        https://github.com/sethdeckard/deviceterm/blob/main/docs/INTEGRATION.md

      For workspace control, orchestration grants, and event-wait
      workflows, read the automation guide:

        https://github.com/sethdeckard/deviceterm/blob/main/docs/AUTOMATION.md

      Audience: automation, agents, CI gates, tooling that needs
      to depend on deviceterm's wire shape across versions. Everything
      in this `deviceterm agents` guide is human-prose;
      docs/INTEGRATION.md is the contract.

    """
}
