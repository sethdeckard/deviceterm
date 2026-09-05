# Help book manual checklist

`Tests/HelpBookGenTests` covers the conversion rules against synthetic
markdown: tables survive, fenced code survives, links rewrite. It never loads
the real guide, and it stops at the HTML. Whether the book registers, opens,
and renders is not checked anywhere automatically, so it is checked here.

The UI-test harness accepts arbitrary bundle ids for `capture window` and
`ax dump`, so it can address Help Viewer. The checks below don't use it.

Run before any release that touches `Sources/HelpBookGen/`,
`scripts/make-help-book.sh`, or the Help menu in `Sources/App/MainMenu.swift`.

## Preconditions

- A bundled build: **`make run`, not `swift run`.** The book lives at
  `Contents/Resources/DeviceTerm.help` and the app finds it through
  `CFBundleHelpBookFolder`, so an unbundled run has no book at all.

- `helpd` restarted, every time you rebuild:

  ```sh
  killall helpd
  ```

  It caches which bundle owns which book. After a rebuild it can hand Help
  Viewer an older copy, or nothing, and that looks identical to a broken book.

## 1. The book opens

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Help ▸ DeviceTerm Help. | Help Viewer opens on a page titled DeviceTerm Help, listing 14 topics. |
| 1.2 | Press ⌘? instead. | The same window. |
| 1.3 | Open a topic with a table, such as Configure DeviceTerm. | The table has visible columns and borders rather than running together as prose. |
| 1.4 | Find a fenced command block on that page. | Monospaced, on its own background, not reflowed into a paragraph. |

## 2. Links

| # | Action | Expected |
|---|--------|----------|
| 2.1 | From Boot Simulators From the Shell, follow the link to Mirror a Physical Device. | That topic opens inside Help Viewer. |
| 2.2 | Follow a link that pointed at a `###` heading, such as Coexist With Device Hub. | Lands on the page carrying that heading, scrolled to it. |
| 2.3 | Follow a link to another guide, such as one naming `INTEGRATION.md`. | Opens `https://deviceterm.com/docs/integration/` in your browser, not in Help Viewer. |

## 3. Search

This is what the book is for. Without one, the Help Topics section answers out
of macOS's own book, so a search for `split` returns Split View and window
tiling. Each step below compares DeviceTerm's matches against those generic
macOS topics.

| # | Action | Expected |
|---|--------|----------|
| 3.1 | In the Help search field, type `split`. | Menu Items still lists Split Right, Split Down, Toggle Split Direction. Record what Help Topics lists now. |
| 3.2 | Type `device hub`. | Record whether a DeviceTerm topic appears. |
| 3.3 | Type a phrase only the guide uses, such as `automation tab`. | Record whether the matching topic appears. |

**Section 3 is an open question, not pass/fail.** Whether registering a book
replaces macOS's topics or only adds a section above them is unestablished, and
so is whether menu-item search reaches the Help menu's own items. Record what
you see rather than judging it against an expectation this checklist doesn't
have.

## 4. A signed, notarized build

`helpd` may treat a debug bundle differently from a distributed one. Repeat
section 1 against every signed, notarized release candidate.
