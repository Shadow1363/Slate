# Slate

A native macOS app for writing films. One project holds the world-building, the screenplay, the storyboard and a glossary, all as plain files in one folder. See [SPEC.md](SPEC.md) for the full design, [CHANGES.md](CHANGES.md) for what's built so far, and [DECISIONS.md](DECISIONS.md) for choices made along the way.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

Swift Package Manager fetches two dependencies the first time you build. Both are used only by SlateCore and pinned to exact versions in `Packages/SlateCore/Package.swift`:
- [Yams](https://github.com/jpsim/Yams) 6.2.2 (MIT) reads note frontmatter.
- Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown) 0.9.0 (Apache 2.0, brings cmark-gfm) supplies note outlines and finds code blocks.

## Set up

The Xcode project isn't committed. Generate it from `project.yml`:

```sh
xcodegen generate
```

Run this again whenever you add or remove files, or change `project.yml`.

## Run

In Xcode:

```sh
open Slate.xcodeproj
```

Then pick the **Slate** scheme and press ⌘R.

From the terminal:

```sh
xcodebuild -project Slate.xcodeproj -scheme Slate -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Slate-*/Build/Products/Debug/Slate.app
```

New projects go in `~/Documents/Slate` by default. The project library is stored in `~/Library/Application Support/Slate/`.

## Test

The fastest way to run the tests:

```sh
swift test --package-path Packages/SlateCore   # models, files, parser, editing rules
swift test --package-path Packages/SlateUI     # the script editor, driven by keystrokes
swift test --package-path Packages/SlateExport # PDF, Fountain, FDX, page breaks vs reference PDFs
```

The same tests can also run through the Xcode scheme, with ⌘U in Xcode or:

```sh
xcodebuild -project Slate.xcodeproj -scheme Slate -destination 'platform=macOS' test
```

Tests use Swift Testing and work on temp copies of the sample project in `Fixtures/SampleProject/`. The SlateUI tests type into the real editor without a window, and include a speed check (under 16 ms per keystroke on a 10-page script). The SlateExport tests compare Slate's page breaks with the reference PDFs in `Fixtures/Fountain/` and the layout with a snapshot in `Fixtures/Snapshots/`. If you change the layout on purpose, regenerate the snapshot with `SLATE_UPDATE_SNAPSHOTS=1 swift test --package-path Packages/SlateExport`.

## Try it by hand

1. Run Slate, click **New Project**, enter a title and choose a template.
2. Right-click the project's card and choose **Show in Finder**.
3. In the project window, open a file such as `script/title-page.md`.
4. Edit that file in TextEdit or VS Code and save it. Slate reloads it within a second.
5. Type in Slate, then edit the same file outside before Slate autosaves (it waits 2 s). A **Changed on disk** banner offers Keep Mine or Load Theirs.

## Writing a script

Scripts are standard [Fountain](https://fountain.io/syntax) in `script/`. Act files (`01-act-one.md`, …) join in name order.

- A scene heading is a line starting with `INT.`, `EXT.`, `INT./EXT.`, `I/E` or `EST.` after a blank line. Any other heading is forced with a leading `.` (`.THE VAULT`). The editor adds or removes that `.` for you, and capitalises the heading, when you leave the line.
- `#`, `##`, … lines are Fountain sections (acts, sequences). They organise the script but never print.
- Each scene heading becomes a scene in the navigator and, from Milestone 9, a scene in the storyboard.

| Key | In the script editor |
| --- | --- |
| Return | Next element: Heading → Action, Action → Action, Character → Dialogue, Parenthetical → Dialogue, Dialogue → Action, Transition → Heading |
| Tab / ⇧Tab | Cycle the line: Action → Character → Transition → Scene Heading. Inside a speech: Dialogue ↔ Parenthetical |
| Tab or → | Accept the highlighted autocomplete (character names, `INT.`/`EXT.`, locations, `DAY`/`NIGHT`) |
| Esc | Dismiss the autocomplete |
| ⌥Return | Plain line break |

Scene IDs such as `{#s014}` are added when you finish typing a heading. They show as a small grey tag. They're Slate's one addition to Fountain: they keep each storyboard attached to its scene when you rename or move it. Fountain scene numbers (`#1A#`) are read too. Exports to Fountain, Final Draft and PDF leave the tags out.

## Publishing

- **Page view** (⇧⌘\\ or the Draft/Page switch) shows the script exactly as it will print. You edit in Draft view, and the pages catch up a moment after you stop typing.
- **Script › Publish** writes PDF (⇧⌘E), Final Draft (.fdx), Fountain or Markdown into the project's `exports/` folder.
- **Print Script…** (⌥⌘P) uses the same renderer. ⌘P is kept for Quick Open.
- **Publish settings** (the sliders button in the Script toolbar): page size, scene numbers, automatic (CONT'D), and bold/italic/underline. They're saved in `project.json`.
- **Import Screenplay…** (⇧⌘I, or Import on the home screen) makes a new project from a `.fountain`, `.fdx`, `.txt` or `.md` file. Fountain `# Sections` become act files.

Publish always uses Courier Prime 12 pt and the industry layout, whatever the editor theme. Courier Prime is bundled under the SIL Open Font License (`Packages/SlateExport/Sources/SlateExport/Resources/Fonts/OFL.txt`).

## Margin: to-dos and notes

- **The margin** is the column beside the script (⇧⌘M or the toolbar button). It has two tabs, To-dos and Notes, each showing **This Scene** (the caret's scene) or **All**.
- **⇧⌘T** adds a to-do at the caret and **⌥⌘T** adds a note. Each is anchored to the scene, and to the selected words if you selected some. Anchored words get a soft highlight in the script, and clicking the quote in the margin selects them.
- **Files:** to-dos are a Markdown task list in `script/margin/todos.md`, e.g. `- [ ] "I haven't opened it yet" — make it land @s014 due:2026-12-01`. Notes are list items under `## @s014` headings in `script/margin/notes.md`. Both read fine in any editor, and outside edits reload.
- **All to-dos:** set the To-dos tab to All, then filter (Open / Done / All) and order (By Scene / By Due Date) from its menu. Script › Show All To-dos jumps straight there.
- **Links:** hovering a `[[link]]` in the script or a note shows a preview. ⌘-click in the script, or a click in the margin, opens the note in the margin, so you never leave the scene.
- **At launch,** a sheet lists open to-dos (overdue first) with Go to Scene and Done. **Settings › Reminders** chooses Off / Last project / All projects and turns due-date notifications (at 9:00) on or off.

## Universe notes

- **Notes** live in `universe/<type>/<name>.md`: YAML frontmatter for fields, then a Markdown body. Use + or ⌘N to make a note from a template: Character, Location, Rule, Faction, Item, Event or Freeform.
- **Templates** are `.md` files too. Make and edit them in **Universe › + › Edit Templates…**. A copy in the project's `templates/` (or in `~/Library/Application Support/Slate/Templates/`) replaces the built-in template of the same type, and Revert to Built-in removes it. The sample project overrides Character.
- **The wiki page:** a note opens with its body on the left and an infobox on the right. **Edit** turns the infobox into a form with these field types: text, long text, number, date, choice, yes/no, list, link, links and image. Each change rewrites only that field's lines, so comments and key order in the file stay as you wrote them.
- **Obsidian infobox notes** work as they are: `infobox: Character` picks the template, `title:` is the name, `subtitle:` sits under it, and a `layout:` list adds section headers (`type: header`, `above: key`) and columns (`type: columns`, `keys: [...]`). `||text||` is a spoiler, hidden until clicked.
- **Links:** typing `[[` suggests notes by name or alias, and ⌘K inserts a link. ⌘-click a link to open it; clicking an unresolved link (red, dashed) offers to create the note. Links work in the script too.
- **Links inspector** (⌥⌘0) lists backlinks from notes, scenes, margin notes and the rough draft. For a character it also lists the scenes they speak in.
- **Renaming** a note (press Return in its name, or right-click › Rename…) offers to update every link to it, and renames the file. Its `id` stays the same.
- **Find in Project** is ⇧⌘F. **Quick Open** (⌘P) opens any note, scene or file.
- **Rough draft:** `universe/draft.md` shows its headings in the sidebar. Right-click a heading › Turn into Scene to append it to the script.

## Canvas

- **Boards** are `universe/canvases/*.canvas` files in the open [JSON Canvas](https://jsoncanvas.org) format, so they open in Obsidian too. Use **New Canvas** in the sidebar's Canvases section or the + menu.
- **Cards:** text (Markdown), notes (live infobox), scenes, images, web links and frames. Drag notes, draft headings and scenes in from the sidebars, or images from Finder.
- **Moving around:** scroll to pan; pinch or ⌘-scroll to zoom; ⌥-drag to pan with a mouse. ⌘0 fits everything, ⇧⌘0 is 100%, and the minimap moves the view.
- **Editing:** drag to move (frames carry their cards), resize from the corner, and double-click to edit or open a card. Drag a side dot onto another card to connect them, then click the connection to label or colour it. **Arrange** aligns and distributes; **Snap to Grid** uses a 20 pt grid. Everything undoes.

## Timelines

- **Timelines** are `universe/timelines/*.timeline.json`. Use **New Timeline** in the sidebar or the + menu; the sample project has `main`.
- **Lanes** are characters or story threads (Add › Add Lane for Character links one to its note). **Events** have a world time, an optional end (a span), a lane, a place, the scenes that show them, and the events that cause them. Double-click a row to add an event at that time.
- **Three views:** **World Order** (when things happen), **Story Order** (as the film shows them, from scene order) and **Personal** (one character's life, following their jumps).
- **Jumps:** right-click an event › Jump From Here…, then click where the traveller arrives. **Branches:** Branch From Here starts an alternate line; set where it rejoins in its inspector.
- **Warnings** (toolbar) flag a character in two places at once with no jump, an event before its cause, events that fall between a traveller's jumps, unreadable times and broken links.
- **Time units:** dates (`2031-03-14T22:10`), days (`Day 3 14:00`), or a custom calendar of eras (`Second Age 312`).

## Maps

- **Maps** are `universe/maps/*.map.json` next to their image. **New Map** starts as a blank grid; add an image with the toolbar or drop one from Finder.
- **Tools:** Select, Pin, Region (click corners, double-click or Return to finish) and Path. Drag items to move them and the corner dots to reshape. Drop a note from the sidebar to pin it.
- **Links:** each item can link to a note (usually a location) and to scenes. Double-click an item to open its note or scene.
- **Layers** (toolbar) can be shown and hidden, and new items go on the layer you choose. Coordinates are saved from 0 to 1 across the image, so a sharper copy of the same image keeps every pin in place.
- **Show on Map:** right-click a scene in the Script sidebar to jump to the pin linked to that scene, or to the location its heading names.

## Dictionary

- **One book:** `dictionary/words.md` is the film's own dictionary, filed A–Z under `## Letter` headings:
  ```markdown
  ## C

  - **Chronoshift** *noun* (chronoshifts, chronoshifted) — A jump between loops that keeps memory.
  - Calloway
  - **Copper Gate** — See [[The Copper Gate]].
  ```
  A word on its own is just a correct spelling. Anything after the dash is its meaning, and a `[[link]]` points to the Universe note with the full story.
- **The Dictionary area** reads it like a book. Search words, forms and meanings; jump with the A–Z strip; open a word to see its page and every place it's used in the script and notes. ⌘N or + adds a word. The toolbar's document button shows `words.md` as text.
- **Everywhere you write,** defined words get a faint dotted underline. Hovering one shows its meaning (or the linked note's preview), and ⌘-click opens it.
- **Spell check** accepts every word and form in the book, plus character names. Right-click a misspelling for **Add to Project Dictionary**, **Add to Every Project** (`~/Library/Application Support/Slate/words.md`) or **Define in Dictionary…**.
- **Define** (⌃⌥⌘D, or the inspector's Define tab) shows the selected word's project meaning, then the Mac's dictionary definition. Force-click still opens Look Up.
- **Settings › Spelling** sets the language, grammar checking for the script and for notes, and auto-correct (off by default).
- Projects from before Milestone 6 are converted once: `words.txt` becomes entries, and any `dictionary/terms/*.md` file moves to `universe/notes/` with an entry linking to it. The originals are backed up in `.slate/backups/`.

## Layout

```
project.yml             XcodeGen project definition
App/                    App entry point (SlateApp.swift)
Packages/
  SlateCore/            Models, file I/O, watcher, themes. No UI. Unit-tested.
  SlateUI/              SwiftUI and AppKit views
  SlateExport/          PDF renderer, Fountain/FDX/Markdown import and export, Courier Prime
Fixtures/SampleProject  Sample project used by tests
Fixtures/Fountain       Reference scripts and PDFs from fountain.io
Fixtures/Snapshots      Golden page layouts
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New Note (in a project window; Add Word in the Dictionary) / New Project (elsewhere) |
| ⌥⌘N | New Project (from a project window) |
| ⌘P | Quick Open |
| ⇧⌘F | Find in Project |
| ⌘K | Insert link |
| ⌥⌘0 | Inspector (Links and Define) |
| ⌃⌥⌘D | Define the selected word |
| ⌘0 / ⇧⌘0 | Canvas: fit everything / 100% |
| ⌘= / ⌘− | Canvas and map: zoom in / out. Timeline: wider / narrower |
| ⌘0 | Map: fit |
| ⇧⌘T | Add to-do at the caret |
| ⌥⌘T | Add margin note at the caret |
| ⇧⌘M | Show / hide the margin |
| ⌘O | Open a project folder |
| ⇧⌘L | Project Library |
| ⌘S | Save |
| ⌘1 – ⌘4 | Universe, Script, Storyboard, Dictionary |
| ⇧⌘O | Jump to scene |
| ⌃⌘↑ / ⌃⌘↓ | Move the current scene up / down |
| ⇧⌘\\ | Draft / Page view |
| ⇧⌘E | Publish PDF |
| ⌥⌘P | Print script |
| ⇧⌘I | Import a screenplay |
| ⌘, | Settings (appearance, spelling, reminders) |
