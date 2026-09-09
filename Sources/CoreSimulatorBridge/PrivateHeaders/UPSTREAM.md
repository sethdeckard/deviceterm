# Private CoreSimulator Headers: Provenance

These headers are vendored from Meta's idb project and are MIT-licensed.
Upstream copyright notices are preserved in each header file.

The MIT text itself sits next to them in `LICENSE` in this directory. Each
header points at "the LICENSE file in the root directory of this source tree,"
meaning idb's tree; deviceterm's repository root is GPL v3 or later, so the
local copy is what keeps that pointer resolvable.

- **Upstream:** https://github.com/facebook/idb
- **Commit:** `4ad657b4ccead3f433f5d22d369eebd40358c1b3`
- **Snapshot date:** 2026-09-09

## What is vendored

One local directory for each vendored idb `PrivateHeaders/` subdirectory:

| Directory | Provides |
|---|---|
| `AccessibilityPlatformTranslation/` | AX translation types |
| `CoreSimulator/` | core `Sim*` types |
| `CoreSimDeviceIO/` | display and IO-port protocols |
| `CoreSimulatorUtilities/` | Foundation helper categories |
| `SimulatorKit/` | legacy HID client, boot info |
| `SimulatorApp/` | Indigo and GSEvent HID structs |
| `SimPasteboardPlus/` | pasteboard interfaces |

Xcode 27 split what had been `CoreSimulator` and `SimulatorKit` across
`CoreSimDeviceIO`, `CoreSimulatorUtilities` and `SimPasteboardPlus`. Those
three directories are that split, not new dependencies.

idb also ships `DTXConnectionServices/`, `XCTestPrivate/`, `AXRuntime/` and
`SimulatorBridge/`. None of them is vendored here, because nothing in the
bridge's include closure reaches them.

## Refreshing

When private API drift forces an update, re-snapshot the headers wholesale
from a current idb commit and bump this file.

Three rules hold whoever does it.

**Headers only.** Upstream's `module.modulemap` and `.tbd` files stay behind.
The bridge reaches these through `.headerSearchPath("PrivateHeaders")` in
`Package.swift`, not as modules.

**Verbatim.** Every `.h` is byte-identical to upstream at the pinned commit,
punctuation included. House style does not apply to them. Byte identity is
what lets the next refresh be a clean overwrite, and what makes a diff against
upstream mean something.

**No hand-patching.** Edit a header here and the next refresh overwrites it
without saying so. When you need a declaration upstream doesn't provide,
declare it in the first-party source that needs it. `SimDisplayHandle.m` does
that for `screenProperties`, which upstream's `SimScreen` omits.
