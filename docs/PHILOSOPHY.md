# DeviceTerm Driving Philosophy

Seven principles guide DeviceTerm's design. Every feature and review is weighed
against them. When two principles pull in different directions, the earlier one
takes priority.

1. **The tab is the workspace.** A tab is the unit of current work: its terminal
   panes, working directories, attached devices, and Simulator panes. A
   Simulator does not float free of a tab. Each terminal pane backs its own
   session, and that session is the CLI's identity: commands default to it,
   with broader views behind an explicit scope. Another tab's contents are
   reachable only through a grant a human issues in the GUI; the CLI can
   never mint one. See
   [Tab semantics](ARCHITECTURE.md#tab-semantics-and-cli-scoping) and
   [the automation model](AUTOMATION.md#understand-tabs-sessions-and-authority).

2. **DeviceTerm owns what it boots; everything else is borrowed.** A Simulator
   booted through `xcrun simctl` inside a DeviceTerm tab is attached to that tab.
   A Simulator booted from Xcode, Simulator.app, or another terminal stays alone
   until the user explicitly attaches it. Physical devices are always borrowed,
   however the mirror was mounted: the GUI picker, `deviceterm device attach`,
   or a `devicectl` deploy the shim observed. This boundary lets Apple's tools
   and DeviceTerm coexist without competing for ownership.

3. **Do not reimplement Apple's tools or established Unix tools.** Most users
   continue to run `xcrun simctl` and `xcrun devicectl`; DeviceTerm observes the
   supported operations it needs and otherwise preserves their arguments,
   standard I/O, signals, and exit status. The `deviceterm` CLI fills gaps such
   as input, accessibility, pane management, and advanced integrations. Shell
   persistence and detach/reattach remain the domain of tmux, zellij, and screen.
   A wrapper is justified only when its workflow value exceeds its maintenance
   cost.

4. **Configuration is minimal and optional.** DeviceTerm works without a config
   file. Terminal presentation and terminal-local key bindings come from the
   user's Ghostty configuration. DeviceTerm-specific behavior comes from
   `~/.config/deviceterm/config`, honoring `$XDG_CONFIG_HOME`. These are separate
   configuration domains, not layers in one precedence chain. The app ignores
   unknown keys, while `deviceterm dump-config` reports them as warnings.

5. **Agents speak CLI.** The public `deviceterm` commands, JSON output, and exit
   codes form the advanced integration contract for both humans and agents.
   There is no parallel MCP surface to maintain. See
   [AUTOMATION.md](AUTOMATION.md) for the workflows and
   [INTEGRATION.md](INTEGRATION.md) for the contract.

6. **The private surface is the product.** Live Simulator panes ride private
   CoreSimulator APIs and physical-device mirrors ride unpublished CoreDevice
   contracts; capability is never traded away for App Store eligibility or a
   sandbox. Each surface is pinned rather than assumed: the compatibility
   probe checks the CoreSimulator symbols the bridge requires, recorded in
   `Sources/CoreSimulatorBridge/as-tested.md`, and the device client
   validates required CoreDevice shapes before use rather than sending
   guessed requests. DeviceTerm ships under a Developer ID, notarized,
   updating through Sparkle; mechanics live in
   [Distribution](ARCHITECTURE.md#distribution).

7. **Background daemon, foreground discipline.** The daemon is demand-launched,
   appears in the status item only while it owns booted Simulators, and exits
   after nothing needs it. Users do not manage it with `launchctl`. The app and
   CLI are clients of the same service. See
   [Daemon lifecycle](ARCHITECTURE.md#daemon-lifecycle).

A pull request that moves against one of these principles should name the
trade-off so reviewers can decide whether it is justified.
