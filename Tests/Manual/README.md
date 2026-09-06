# Manual test coverage

These checklists cover behavior that the automated suites and E2E playbooks do not prove. Read a checklist's coverage
note before running it. A lower-level test replaces a manual row only when it observes the same outcome.

## Coverage labels

**Default automation** runs under `make verify`. It covers lint, unit and integration tests, the compatibility probe, GUI
smoke, shim and CLI tests, and the release-build dry run.

**Deliberate automation** runs separately:

- `make test-live` uses a real Simulator and shuts down the Simulator fleet.
- `make test-device-live` uses a connected physical device but does not reboot or shut it down.
- `make test-uitest` drives DeviceTerm through the UI-test harness. It needs Screen Recording, Accessibility, and an
  unlocked display.

**Agent-driven E2E** uses one of two skills:

- `deviceterm-e2e` drives DeviceTerm's AppKit UI and checks CLI state, accessibility, and pixels.
- `deviceterm-device-e2e` drives the simulator or physical device inside a pane and checks the result through device
  accessibility.

A skill run is repeatable E2E coverage, but it is not part of `make verify` and does not run unattended.

**Manual only** covers behavior that still needs a person, external application, signed build, physical judgment, or
measurement setup. Examples include terminal feel, Apple-app coexistence, notarization behavior, and performance traces.

## Automation candidates

These manual checks are candidates for automated coverage:

- Add safe, simulator-free tab rename, tab select, and pane-navigation cases to `make test-uitest`.
- Add a Help Viewer scenario using the UI-test harness's bundle-targeted capture and accessibility support.
- Investigate process-level coverage for `deviceterm events` and `deviceterm with-pane`.
