---
name: deviceterm-e2e
description: >-
  End-to-end test deviceterm's own GUI from inside a deviceterm tab. Use when
  asked to verify that deviceterm's window/tab/pane chrome, status item, modal
  prompts, or device picker actually render and respond — i.e. anything the
  `deviceterm` CLI's `--json` can't observe about the app's own AppKit UI. Pairs
  CLI state mutation with pixel + accessibility verification via the
  out-of-process `deviceterm-uitest` harness.
---

This skill's full instructions live in one neutral playbook shared by every
agent runtime, so there is a single source of truth and no copy to drift:

**Read and follow `.agents/skills/deviceterm-e2e/PLAYBOOK.md`** (relative to the
repo root). It carries the test loop, the preflight gate, and the scenario
library. The helper scripts it references are in
`.agents/skills/deviceterm-e2e/helpers/`.

Do not act before reading it — the preflight gate there is what keeps a
misconfigured machine (no harness resident, missing TCC grants, no deviceterm
window) from producing false passes.
