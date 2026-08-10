# Private CoreSimulator Headers — Provenance

These headers are vendored from Meta's idb project and are MIT-licensed.
Upstream copyright notices are preserved in each header file.

The MIT text itself sits next to them in `LICENSE` in this directory. Each
header points at "the LICENSE file in the root directory of this source tree,"
meaning idb's tree; deviceterm's repository root is GPL v3 or later, so the
local copy is what keeps that pointer resolvable.

- **Upstream:** https://github.com/facebook/idb
- **Commit:** afd6e22d7d4a73f6d82af2f52ec97b1fbcf8b8df
- **Source paths within idb:**
  - `PrivateHeaders/CoreSimulator/*` (Sim* core CoreSimulator types)
  - `PrivateHeaders/SimulatorKit/*` (display protocols)
  - `PrivateHeaders/SimulatorApp/{Indigo.h,GSEvent.h}` (HID structs)
- **Snapshot date:** 2026-05-07

When private API drift forces an update, re-snapshot the headers wholesale
from a current idb commit and bump this file. Do not hand-patch individual
headers — the next refresh will silently overwrite the changes.
