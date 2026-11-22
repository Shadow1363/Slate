# Changes

## Milestone 3 — Pagination and Publish (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 148 pass: 115 in SlateCore, 17 in SlateUI and 16 in the new SlateExport target. The scheme runs all three.
**Done when:** on both fountain.io reference scripts, the page count matches and every page starts within 2 lines of the reference.
- *Brick & Steel* (4 pages): all page breaks exact.
- *The Last Birthday Card* (20 pages, 19 breaks): 14 exact, 4 off by 2 lines and 1 off by 1.

### What works
- **Page engine** (`Paginator`, SlateCore) lays out the joined act files on Letter (54 lines) or A4 (58).
  - Element positions follow the Publish table, checked against the reference PDF: heading and action at 1.5" (61 characters), cue at 3.5", parenthetical at 2.9", dialogue at 2.5" (35 characters), transitions right-aligned at 7.1".
  - Spacing comes from the elements (two blank lines before headings, one before everything else), not from blank lines in the file.
  - Break rules:
    - A heading moves with at least 2 lines of what follows.
    - A speech splits only at a sentence end with 2+ lines each side, adding `(MORE)` and `NAME (CONT'D)`.
    - A cue or parenthetical is never left at the bottom of a page.
    - Action splits only at a sentence or line end.
    - `===` forces a new page.
  - Dual dialogue (`^`) prints side by side; centred text (`>…<`) and lyrics are supported.
  - Boneyard, synopses, scene tags and `[[link]]` brackets are left out of the printed page.
- **Automatic (CONT'D)**, **scene numbers** in both margins, and **emphasis** (`*italic*`, `**bold**`, `***both***`, `_underline_`, `\` escapes) are all on by default. Each can be switched off per project in `project.json` › `settings.publish`.
- **Exact timings:** eighths per scene (counted per page, at least 1/8) and the page count come from the same engine as the PDF.
  - The navigator and status bar show `~` estimates while you type.
  - They switch to exact numbers 300 ms after typing stops. Layout runs off the main thread and takes about 2.4 ms for 12 pages.
- **PDF** (Core Text, bundled Courier Prime):
  - Title page from `title-page.md`: title, credit, authors, source and draft date centred; contact bottom-left.
  - Page numbers top right, 0.5" from the top, with no number on page 1.
  - The PDF title comes from the title page.
- **Page view:** Draft/Page switch in the Script toolbar, or ⇧⌘\\. It shows the rendered PDF, read-only, follows the caret's page and keeps your place when it refreshes.
- **Publish menu:** PDF (⇧⌘E), Final Draft, Fountain and Markdown go to `exports/<Project> – <date>.<ext>`. An existing file is never overwritten, and the new file is shown in Finder.
- **Print Script…** (⌥⌘P) uses the same renderer.
- **Fountain import:**
  - The title page becomes `title-page.md`.
  - Top-level `# Sections` become numbered act files; deeper sections become `/* ## … */`.
  - `.HEADING` becomes `# HEADING`, and Fountain `[[notes]]` become `/* note: … */`.
  - Scene IDs are made unique across all act files.
- **Fountain export:** one file. Act files become `# Sections`, headings print as `INT. …` or `.FORCED`, and tags and link brackets are removed. A round trip keeps elements, acts and the title page.
- **FDX export and import** (Foundation XML, no dependency):
  - Element types, emphasis styles, dual dialogue, centred text, forced page breaks, scene numbers and the title page all map both ways.
  - Slate scene IDs travel in a `SlateSceneID` attribute, so an FDX round trip keeps them and paginates identically.
  - FDX scene numbers are kept as `{#s001 number=14}`.
- **Import Screenplay…** (⇧⌘I, and an Import button on the home screen) creates a new project in `~/Documents/Slate` from a `.fountain`, `.fdx`, `.txt` or `.md` file and opens it.
- **Publish settings** popover in the Script toolbar: page size, scene numbers, automatic (CONT'D), emphasis.
- Courier Prime is registered at launch, so the editor themes' "Courier Prime" now resolves too.

### Stubbed or not yet done
- **Page view is read-only.** Typing happens in Draft view.
- A transition that doesn't fit at the bottom of a page moves to the next page alone, rather than taking the line above with it.
- Production features are left for Milestone 11:
  - locked scene numbers, A-scenes and A-pages,
  - revision colours and marks,
  - reports and sides.

  The `number=` attribute from FDX is kept but not printed yet.
- Smart quotes aren't applied in Publish; quotes print as typed.
- Importing a Slate folder or `.zip`, or a Markdown folder (Obsidian vault), is Milestone 12.
- FDX boneyard and synopsis lines aren't exported (Final Draft has no plain equivalent).

### How to check the "done when"
1. Run `swift test --package-path Packages/SlateExport --filter Reference` to see the page-break offsets printed.
2. In the app, use **Import Screenplay…** on `Fixtures/Fountain/Brick-and-Steel.fountain`. Switch to Page view, then publish a PDF and compare it side by side with `Fixtures/Fountain/Brick-and-Steel.pdf`.
3. If you have Final Draft or Highland, open the exported `.fdx` and compare its page count.

## Milestone 2 — Script editor (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 103 pass: 89 in SlateCore and 14 in SlateUI. `swift test` for each package and `xcodebuild … test` both run them, and the scheme now includes SlateUI.

### What works
- **ScriptParser** (SlateCore): turns a script file into classified lines and scenes, following the Fountain rules.
  - Scene headings: `#` lines, plus auto-detected `INT.`/`EXT.`/`INT./EXT.`/`I/E`/`EST.` after a blank line.
  - Character cues with extensions and `^` dual dialogue, parentheticals, dialogue (including two-space blank lines), transitions ending `TO:`.
  - Forced `!` `@` `>` `.` `~` `=`, centred `>…<`, `===`, and `/* boneyard */` spanning several lines.
  - Scene tags `{#s014 dur=2:30}`. Handles CRLF, emoji and accents, with UTF-16 ranges for the editor.
- **ScriptBook**: joins the act files in `script/` in name order (skipping the title page and `margin/`). It numbers scenes and collects characters, locations and times of day, most-used first. It also estimates eighths, duration (1 page ≈ 1 min, or `dur=`), pages and word count.
- **Editor** (`NSTextView` on TextKit 2, Draft view): formatting updates live as you type. Each element gets its indents from the Publish table, in a centred 6-inch column, with theme fonts and colours. The text in the file stays plain.
  - `#` and forced markers are dimmed.
  - Scene tags show as a small chip-coloured tag.
  - `[[links]]` are coloured.
- **Tab / Return** work like Final Draft. See the table in the README.
  - On an empty line, Tab chooses what the line will be before you type. Typed headings get `# ` and transitions `>`, so the file reads back the same.
  - Cues, headings and transitions are typed in capitals.
  - Tab on an empty dialogue line makes `()` with the caret inside, and Return steps past the `)`.
  - Undo works across all of it.
- **Scene IDs:** a heading gets the next free `sNNN` (across all act files) when you press Return on it or move off it. A pasted duplicate ID gets a new one.
- **Autocomplete:** the rest of a match appears selected after the caret. It covers:
  - cue names from the script and from `universe/characters/*.md` (`name:` and `aliases:`),
  - `(V.O.)`, `(O.S.)`, `(O.C.)` and `(CONT'D)`,
  - `INT. `/`EXT. `/`INT./EXT. `/`EST. `, known locations, and times of day.

  Tab, → or Return accepts it, Esc removes it, and typing over it keeps what you type.
- **Spell check:** on as you type, with auto-correct and smart quotes off. Character names, aliases, `dictionary/words.txt` and screenplay terms (`INT`, `V.O.`, `CONT'D`, `ECU`, …) are ignored. Scene tags, markers and `[[links]]` are never flagged.
- **Scene navigator:** title page, then each act file with its scenes. Each scene row shows its number, heading, eighths and estimated time, and the scene under the caret is bold. Clicking a scene jumps to it, and dragging reorders scenes within a file. Totals are shown at the bottom.
- **Status bar:** current element, scene N of M with its length, words, estimated pages and runtime.
- **Menus:** Script › Jump to Scene… (⇧⌘O, type to filter, arrows, Return), Move Scene Up/Down (⌃⌘↑/↓). The Script area can create `script/script.md` when the folder has no script yet.
- **Speed:** 4.9 ms per keystroke on a 10-page script in release (7 ms in debug), including SwiftUI's update. A test enforces < 16 ms.

### Stubbed or not yet done
- **Page view**, real page breaks, and exact eighths and timings come in M3. Today's eighths and pages are estimates from line counts, labelled `~` in the UI.
- Fountain emphasis (`*italic*`, `**bold**`, `_underline_`) is not rendered yet, so the markers show as typed.
- Dual dialogue (`^`) is parsed but not laid out side by side.
- Scene colour labels, and dragging scenes **between** act files, are not built yet. Creating new act files has to be done in Finder for now.
- Focus mode, typewriter scrolling and snapshots (⇧⌘S) aren't built. The spec lists them under the editor but not in M2.
- Duplicate scene IDs are fixed only within one act file. A copy that collides with an ID in another act file isn't renumbered yet.
- The other areas still show the temporary file list from M1.

### How to check the "done when"
1. Open a project and press ⌘2. The first act file opens with the caret in it.
2. Without the mouse: press Tab three times and type `int. kitchen - night`, then Return. Type an action line and press Return, then Tab. Type `mara`, press Return and type dialogue. Press Return, then Tab twice for a transition. Use ⇧⌘O to jump between scenes.
3. Keep going for ~10 pages. The status bar shows the page estimate, and the layout should look like a screenplay in Draft view.

## Milestone 1 — Foundation (2026-11-22)

**Build:** `xcodegen generate && xcodebuild -project Slate.xcodeproj -scheme Slate build`. It succeeds with no compiler warnings. Xcode's App Intents metadata tool still prints "Metadata extraction skipped", which is a tool log line and not a code warning.
**Tests:** `swift test --package-path Packages/SlateCore`, or ⌘U / `xcodebuild … test`. 53 tests in 10 suites pass, three runs in a row.

### What works
- **Project setup**: `project.yml` (XcodeGen) builds the `Slate` app target for macOS 15 in Swift 6 language mode, with strict concurrency, hardened runtime, no sandbox and ad-hoc signing. The three local packages are `SlateCore`, `SlateUI` and `SlateExport`. The test scheme runs `SlateCoreTests`.
- **project.json** (`ProjectManifest`): reads and writes `name`, `id`, `schemaVersion`, `pageSize`, `theme` and `settings`. Unknown keys are kept, and a canonical file round-trips byte for byte. Errors are readable ("project.json is missing “name”").
- **Migration** (`ProjectMigrator`): a project with a newer schema is refused with a clear message. An older schema is backed up to `.slate/backups/` before it is upgraded.
- **New Project** (`ProjectCreator`): the Feature, Short, TV Pilot and Blank templates create the folder layout from SPEC.md with starter files (title page, act files or `script.md`, margin files, `storyboard.json`, `words.txt`). It refuses a folder that exists and isn't empty.
- **File I/O** (`CoordinatedFileIO`): every read and write goes through `NSFileCoordinator`, and every write is atomic. Non-UTF-8 files are refused rather than mangled.
- **FileWatcher**: FSEvents plus an `NSFilePresenter` on the project root. It reports relative paths, ignores `.slate/` and `.DS_Store`, and flags "rescan everything" when FSEvents asks for it.
- **ProjectStore**: lists the files in each area, opens documents, and saves on ⌘S and after 2 s idle. On an outside change it:
  - reloads a document with no unsaved edits,
  - shows **Changed on disk: Keep Mine / Load Theirs** if there are unsaved edits,
  - shows **Deleted on disk: Save Again / Close** if the file is gone,
  - re-reads the disk just before every save, so it never overwrites an edit the watcher hasn't reported yet,
  - picks up outside edits to `project.json`, keeping the old values and showing a banner if the new file is invalid.
- **ProjectLibrary**: `library.json` in `~/Library/Application Support/Slate/`. Projects are stored as security-scoped bookmarks (with a plain-bookmark fallback), so a folder moved in Finder is followed. Unresolvable projects show **Missing — Locate…**. Remove from Library keeps the files. `~/Documents/Slate` is scanned for projects.
- **ThemeEngine**: built-in Light and Dark themes that cover every token group in the spec. User `.slatetheme` files in `~/Library/Application Support/Slate/Themes/` fall back to their `base`, and bad values are reported with their path (`editor.background: “#12” is not a hex colour`). Appearance can be Light, Dark or Follow System, with a theme picked for each. A per-project `theme` in project.json overrides both.
- **Home screen**: sidebar with All Projects, Recent, Pinned and Watched Folders, plus search. Project cards show the title and last-edited time. Toolbar has New Project and Open Folder. Right-click offers Open, Show in Finder, Pin/Unpin, Locate… and Remove from Library.
- **Project window**: one window per project. The sidebar has Universe, Script, Storyboard and Dictionary (⌘1–⌘4), a file list for the chosen area, and a plain-text editor (`NSTextView`, TextKit 2) with spell check on and auto-correct and smart quotes off.
- **Menus**: New Project… ⌘N, Open Folder… ⌘O, Project Library ⇧⌘L, Save ⌘S, areas ⌘1–⌘4. Settings (⌘,) has Appearance, the theme pickers, Reload Themes and Show Themes Folder.

### Stubbed or not yet done
- The area views are placeholders. Each shows a **temporary file list and plain-text editor** so you can watch reloads now. Script (M2), Universe (M4), Dictionary (M6) and Storyboard (M9) replace them.
- Cards show "— pages · — min · — to-dos" and a placeholder cover. Page count and runtime come in M3, to-dos in M5, covers in M9.
- These card actions aren't built yet: Rename, Duplicate, Export as .zip, Move to Trash. The list/grid toggle and Import are also missing. Import is M3 for Fountain/FDX and M12 for folders/zip.
- Watched Folders: only the default `~/Documents/Slate`. There's no UI to add or remove folders yet.
- Global shortcuts ⌘P, ⇧⌘F, ⌘K and ⇧⌘O arrive with the features they open (M2/M4).
- `SlateExport` only declares `ExportFormat`. There are no exporters yet.
- Courier Prime isn't bundled, so Courier-family theme fonts fall back to Courier New. This needs deciding before M3; see DECISIONS.md.
- No app icon (M12).

### How to check the "done when"
1. Run Slate, click **New Project**, enter "Test Film" and choose Feature. A project window opens.
2. Right-click its card on the home screen, choose **Show in Finder**, and check the folder.
3. In the project window, pick `title-page.md` under Script. Edit that file in TextEdit or VS Code and save. The editor updates within a second.
4. Type something in Slate (don't wait 2 s), then edit the same file outside. The **Changed on disk** banner appears, and both buttons work.
5. Quit, move the project folder in Finder, and relaunch. The card still opens the project.
