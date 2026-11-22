# Slate

A native macOS app for writing films. One project holds the world-building, the screenplay, the storyboard and a glossary, all as plain files in one folder. See [SPEC.md](SPEC.md) for the full design, [CHANGES.md](CHANGES.md) for what's built so far, and [DECISIONS.md](DECISIONS.md) for choices made along the way.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

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

Scripts are plain Fountain text in `script/`. Act files (`01-act-one.md`, …) join in name order. A line starting with `#` is a scene heading.

| Key | In the script editor |
| --- | --- |
| Return | Next element: Heading → Action, Action → Action, Character → Dialogue, Parenthetical → Dialogue, Dialogue → Action, Transition → Heading |
| Tab / ⇧Tab | Cycle the line: Action → Character → Transition → Scene Heading. Inside a speech: Dialogue ↔ Parenthetical |
| Tab or → | Accept the highlighted autocomplete (character names, `INT.`/`EXT.`, locations, `DAY`/`NIGHT`) |
| Esc | Dismiss the autocomplete |
| ⌥Return | Plain line break |

Scene IDs such as `{#s014}` are added when you finish typing a heading. They show as a small grey tag.

## Publishing

- **Page view** (⇧⌘\\ or the Draft/Page switch) shows the script exactly as it will print. You edit in Draft view, and the pages catch up a moment after you stop typing.
- **Script › Publish** writes PDF (⇧⌘E), Final Draft (.fdx), Fountain or Markdown into the project's `exports/` folder.
- **Print Script…** (⌥⌘P) uses the same renderer. ⌘P is kept for Quick Open.
- **Publish settings** (the sliders button in the Script toolbar): page size, scene numbers, automatic (CONT'D), and bold/italic/underline. They're saved in `project.json`.
- **Import Screenplay…** (⇧⌘I, or Import on the home screen) makes a new project from a `.fountain`, `.fdx`, `.txt` or `.md` file. Fountain `# Sections` become act files.

Publish always uses Courier Prime 12 pt and the industry layout, whatever the editor theme. Courier Prime is bundled under the SIL Open Font License (`Packages/SlateExport/Sources/SlateExport/Resources/Fonts/OFL.txt`).

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
| ⌘N | New Project |
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
| ⌘, | Settings (appearance and themes) |
