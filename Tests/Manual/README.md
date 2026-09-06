# Manual test coverage

> **Manual tests are an exception. Do not add one as a routine part of a
> change.**

`Tests/Manual` covers behavior that cannot yet be automated. A new checklist or
row belongs here only when one of these is true:

- There is no known way to observe the same outcome automatically.
- The automation path is known, but there is not enough time to build it in the
  current change.

A user-facing change does not require a corresponding manual test. Start with
the automated layers below, including the E2E scenario libraries for visible
behavior. If neither exception applies, do not add manual coverage.

## Before adding a manual test

Name the exact outcome that remains unverified. Check every applicable
automated layer before deciding it needs a person.

The checklist's coverage note must say:

- what the existing automation proves;
- what outcome it cannot observe;
- why the remaining check is manual;
- which automated layer should replace it, if a path is known.

When automation is deferred for time, write the manual procedure as its
executable specification. Keep the actions and expected results precise enough
to move into a test or E2E scenario later.

When no automation path is known, say so and record the observable behavior.

Keep the manual portion as small as possible. Do not repeat parsing, request
formation, state transitions, or other assertions that an automated test
already proves.

## What replaces a manual test

Automation replaces a manual row only when it observes the same outcome.

A receipt proving that input was dispatched does not prove that the guest UI
changed. A reducer test does not prove that AppKit rendered the intended
surface. Those manual assertions remain until an automated test can observe
the result.

The reverse also applies. Once automation observes the result, remove the
manual row. Do not keep it as a second release gate.

## Coverage layers

**Default automation** runs under `make verify`. It covers lint, unit and
integration tests, the compatibility probe, GUI smoke, shim and CLI tests, and
the release-build dry run.

**Deliberate automation** runs separately:

- `make test-live` uses a real Simulator and shuts down the Simulator fleet.
- `make test-device-live` uses a connected physical device but does not reboot
  or shut it down.
- `make test-uitest` drives DeviceTerm through the UI-test harness. It needs
  Screen Recording, Accessibility, and an unlocked display.

**Agent-driven E2E** uses two scenario libraries:

- `deviceterm-e2e` drives DeviceTerm's AppKit UI and checks CLI state,
  accessibility, and pixels.
- `deviceterm-device-e2e` drives the simulator or physical device inside a pane
  and checks the result through device accessibility.

These libraries provide repeatable E2E coverage, but they are not unattended
suites and do not run under `make verify`. A checklist that depends on one must
name the required scenario numbers. “Run the skill to completion” is not a
defined prerequisite.

**Manual fallback** covers the outcome left after those layers. It may need
physical judgment, another application, a signed build, real hardware, or a
measurement setup. Those conditions do not make the check permanently manual;
retire it when an automated layer can observe the same result.

## Retiring manual coverage

When automation covers part of a manual row, narrow the row to the remaining
observable gap and update its coverage note.

Delete the row when nothing remains. Delete the checklist when every outcome it
covered has moved into automation or a named E2E scenario.

## Automation candidates

Each checklist carries its exact coverage gap. These are broader automation
gaps:

- Add a Help Viewer scenario using the UI-test harness's bundle-targeted
  capture and accessibility support.
- Add process-level coverage for `deviceterm events` and
  `deviceterm with-pane`.
- Teach the UI-test harness to open DeviceTerm's menus and prove that
  chordless menu actions dispatch.
- Find a reliable automated readback for watchOS Crown movement and
  side-button results.
