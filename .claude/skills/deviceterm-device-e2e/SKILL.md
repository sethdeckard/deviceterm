---
name: deviceterm-device-e2e
description: >-
  Drive the device inside a deviceterm pane through the `deviceterm` CLI: touch,
  hardware buttons, text, rotation, and accessibility reads against a simulator
  or connected device. Use when asked to exercise or verify device-control
  behaviour, coordinate mapping in any orientation, or `ax tree`/`point`/`sweep`
  output. Pairs an input verb with an accessibility read-back, since a receipt
  reports dispatch and never what the app did. For deviceterm's own AppKit
  chrome (windows, tabs, panes, status item, prompts), use `deviceterm-e2e`
  instead.
---

This skill's full instructions live in one neutral playbook shared by every
agent runtime, so there is a single source of truth and no copy to drift:

**Read and follow `.agents/skills/deviceterm-device-e2e/PLAYBOOK.md`** (relative
to the repo root). It carries the coordinate contract, the read-back doctrine,
the scenario library, and the known-broken list.

Do not act before reading it. The coordinate contract is the part that silently
produces false passes: portrait is the identity transform, so a portrait-only
run cannot tell a correct implementation from one that rotates nothing.

This skill needs no TCC grants, no `deviceterm-uitest` harness, and no
automation grant. Do not import the `deviceterm-e2e` preflight gate; it would
refuse a machine that can run all of this.
