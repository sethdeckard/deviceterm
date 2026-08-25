# Device ▸ Location manual checklist

The row model (`LocationMenuModel`), the file grammar
(`LocationsFileParser`), GPX reading (`GPXDocument`, `GPXRouteMapper`),
the wire types, and the daemon's claim tracking are all covered by unit
tests. The live track (`make test-live`) drives the private
CoreSimulator selectors directly.

Neither can see the two things this checklist exists for. **There is no
getter for a simulated location on either backend**, so nothing
in-process can confirm a device actually moved: the selectors return a
bare `BOOL` and `devicectl` reports only that it accepted the command.
And the permission prompt, the sheet, and the menu itself are AppKit
surfaces no automated test in this repo opens.

Run before any release that touches `Sources/App/Location/`,
`Sources/Daemon/DeviceCtl/`,
`Sources/CoreSimulatorBridge/SimLocation.m`, or
`Sources/CoreSimulatorBridge/include/SimLocation.h`.

## Preconditions

- A clean build, launched as a bundle: **`make run`, not `swift run`**.
  `NSLocationWhenInUseUsageDescription` lives in the app's Info.plist,
  and macOS will not prompt a loose binary.
- One tab, with a sim booted from inside it.
- Maps (or any app showing a position) installed on the sim.
- A `~/.config/deviceterm/locations` you are willing to have appended
  to. Move an existing one aside if you want a clean run.

---

## 1. Menu shape

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Open Device ▸ Location on a fresh install (no `locations` file). | `None`, `Use My Location`, a separator, `Trips` with the four built-ins, a separator, `Custom Coordinates…`. No `Locations` section. |
| 1.2 | Nothing has been set yet. | **No row is checked.** Not even `None`: DeviceTerm has no claim, which is not the same as having cleared. |
| 1.3 | Open the same submenu from the pane's right-click menu. | Identical rows and checkmarks. |
| 1.4 | Focus the *terminal* pane, then open Device ▸ Location. | Still populated, acting on the tab's device pane. |
| 1.5 | Open it on a **watch** pane. | Enabled, not greyed. Location is not family-gated. |

## 2. Trips

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Pick `Freeway Drive`. Open Maps on the sim. | The blue dot moves continuously. Reopen the menu: `Freeway Drive` is checked, nothing else. |
| 2.2 | Pick `None`. | Movement stops. `None` is now checked. |
| 2.3 | Pick a trip, then reboot the sim from Device ▸ Reboot. Reopen the menu. | **No row checked.** The claim is dropped on shutdown, and no clear was sent. |

## 3. Custom Coordinates

| # | Action | Expected |
|---|--------|----------|
| 3.1 | `Custom Coordinates…`, enter `48.8584`, `2.2945`, name `Eiffel Tower`, Set. | Sheet dismisses. Maps shows Paris. |
| 3.2 | Reopen the menu. | A `Locations` section holding `Eiffel Tower`, checked. |
| 3.3 | `cat ~/.config/deviceterm/locations`. | A seeded `#` header and `48.858400,2.294500 Eiffel Tower`. |
| 3.4 | Enter `91`, `0`. | Rejected inline with a message; Set stays disabled. The sheet stays open. |
| 3.5 | In a German locale, enter `48,8584`. | Accepted as 48.8584. The *sheet* is locale-aware; the file is not. |
| 3.6 | Add the same coordinate again under a different name. | No second row, and the original name is kept. |

## 4. Use My Location

**The first-run prompt cannot be replayed once macOS has recorded a
decision for this bundle**, and the record survives in
`/var/db/locationd/clients.plist`, which SIP protects from root. A fresh
machine or a fresh bundle id is the only honest way to see 4.1.

| # | Action | Expected |
|---|--------|----------|
| 4.1 | On a Mac that has never decided for DeviceTerm: pick `Use My Location`. | macOS shows the permission prompt. Allowing it applies this Mac's position within a few seconds. |
| 4.2 | Allow, then reopen the menu. | A coordinate row for your position, checked. |
| 4.3 | `cat ~/.config/deviceterm/locations`. | **The fix was not appended.** Use My Location saves nothing on its own. |
| 4.4 | Now pick that coordinate row from the menu. | *Now* it is saved to the file, and stays checked. |
| 4.5 | Turn DeviceTerm off in Privacy & Security ▸ Location Services, then pick `Use My Location`. | An alert naming the refusal, with an `Open Privacy & Security` button that opens that pane. |
| 4.6 | With the prompt on screen and unanswered, pick `Freeway Drive`, then answer the prompt. | The trip stays applied. The fix is discarded and raises no alert. |
| 4.7 | Click `Use My Location` five times quickly. | One prompt, one apply, at most one alert. |

## 5. GPX routes

Write `~/routes/manual.gpx`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
  <trk><trkseg>
    <trkpt lat="37.3349" lon="-122.0090"><time>2026-01-01T00:00:00Z</time></trkpt>
    <trkpt lat="37.3420" lon="-122.0100"><time>2026-01-01T00:01:00Z</time></trkpt>
    <trkpt lat="37.3500" lon="-122.0120"><time>2026-01-01T00:02:00Z</time></trkpt>
  </trkseg></trk>
</gpx>
```

Add to `~/.config/deviceterm/locations`:

```
~/routes/manual.gpx Manual Route
```

| # | Action | Expected |
|---|--------|----------|
| 5.1 | Open Device ▸ Location **twice** (the file is read after the rows are built, so an edit lands on the following open). | A `Manual Route` row under `Locations`. |
| 5.2 | Pick it. Watch Maps. | **The dot walks the path**: about 1.70 km over the 120 s the stamps span, so roughly 14 m/s. This is the assertion no automated test can make. |
| 5.3 | Reopen the menu. | `Manual Route` is checked. |
| 5.4 | Pick `None`, reopen. | `None` checked, `Manual Route` unchecked. |
| 5.5 | Drop the `<time>` elements, reopen twice, pick it again. | Faster: the default 20 m/s rather than the derived ~14 m/s. |
| 5.6 | Rename the file away and pick the row. | An alert naming the path and saying it could not be read. |
| 5.7 | Close `<trkseg>` after the first point and open a second one around the other two, so the file has **two segments each holding points**. Reopen twice and pick the row. | An alert: the track is broken into 2 separate stretches. An *empty* second segment would change nothing, since only runs that hold points count. |
| 5.8 | Remove the line's label, reopen twice. | The row reads `manual` (the file name without its extension). |
| 5.9 | Put the file at a path with spaces and quote it: `"~/my routes/manual.gpx" Spaced`. | Row appears and plays. Unquoted, it will not resolve. |

## 6. Physical device

Repeat 2.1, 3.1, and 5.2 on a mirrored physical device pane
(Shell ▸ Mirror Physical Device…). The device path shells out to
`devicectl` rather than the private selectors, so it is a genuinely
different code path with the same expected behaviour.

## 7. The philosophy gate

| # | Action | Expected |
|---|--------|----------|
| 7.1 | `deviceterm location` in a tab. | Unknown verb. There is deliberately no CLI location verb. |
| 7.2 | `deviceterm agents`. | Still prints the "no simctl wrappers" line naming `location`. |
| 7.3 | `deviceterm doctor --json`. | No `pane.location.*` in the advertised methods. |
