# Slate — macOS Screenwriting App: Build Spec & Prompt

Nov 22, 2026 · @Tomas Martinez

## How to use this doc

Export this doc as Markdown, save it as `SPEC.md` in an empty folder, open Claude Code there, and paste the prompt below. It builds one milestone at a time and stops after each so you can try it and steer. "Slate" is a placeholder name; rename it anywhere.

```text
You are building "Slate", a native macOS app for writing films. The full spec is in SPEC.md in this folder. Read all of it before writing any code and treat it as the source of truth.

Rules:
- Swift 6, SwiftUI app lifecycle, AppKit wherever SwiftUI falls short (text editing, spell check, printing/PDF). Target macOS 15+. No Electron, no web views for core editing.
- Generate the Xcode project with XcodeGen (project.yml) so it is reproducible. Build with xcodebuild and fix every error and warning before calling a step done.
- Everything the user writes lives as plain, human-readable files inside the project folder, exactly as described in "Project folder format". Never keep user content only in a database. Any cache or index lives in .slate/ and must be rebuildable from the files.
- The app must notice files changed outside it (Finder, VS Code, git, iCloud) and reload them without losing unsaved edits.
- Split the code into: SlateCore (models, file I/O, parsers, link index; no UI; fully unit-tested), SlateUI (views), SlateExport (PDF, Fountain, FDX, animatic).
- Build in the milestone order in SPEC.md. After each milestone: build, run the tests, add an entry to CHANGES.md listing what works and what is stubbed, then stop and wait for me.
- Where the spec is silent, pick the simplest option that keeps files readable and log it in DECISIONS.md.
- Ask me before adding any third-party dependency.

Start with Milestone 1.
```

## Product overview

Slate is a native Mac app where one film project holds everything: the world-building, the screenplay, the storyboard and a glossary, all as plain files in one folder you can open in Finder, move, back up or put in git.

A project has four areas, switched from the sidebar (Cmd-1 to Cmd-4):

| Area       | What it is for                                                                                                 | Stored as                                  |
| ---------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Universe   | Rough draft, characters, locations, rules of the world, idea canvases, timelines (including time travel), maps | `.md` with frontmatter, `.canvas`, `.json` |
| Script     | The official screenplay with live formatting, timings, a margin for to-dos and notes, and Publish              | `.md` (Fountain-flavoured)                 |
| Storyboard | Frames per scene, created automatically from the script's scene headings, with a player to watch them          | scene folders of images/clips + `.json`    |
| Dictionary | In-world terms and custom spellings that feed spell check                                                      | `.md` + `words.txt`                        |

Goals:

- Files first: deleting the app loses nothing; every file is readable in any text editor.
- Industry-correct output: Publish produces a script a production can use without reformatting.
- Everything links: a `[[Name]]` anywhere jumps to that note, and every note shows where it is used.
- Feels like a Mac app: native text system, Look Up, spell check, keyboard-first, light and dark.

Not in v1: real-time collaboration, iPad/iPhone apps, cloud sync of its own (iCloud Drive, Dropbox or git work because projects are plain folders).

## Tech stack and architecture

SwiftUI for the app shell and most views, AppKit for the parts that need the full Mac text system, and no database: the folder is the database, with a rebuildable index in `.slate/`.

| Concern               | Choice                                                                          | Why                                                                                                        |
| --------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Language / UI         | Swift 6, SwiftUI, macOS 15+                                                     | Native, modern concurrency, Observation framework                                                          |
| Text editing          | `NSTextView` on TextKit 2, wrapped in `NSViewRepresentable`                     | SwiftUI `TextEditor` can't do per-element screenplay styling, margins, inline chips or spell-check control |
| Spell check / Look Up | `NSSpellChecker`, built-in force-click Look Up, Dictionary Services             | Free with NSTextView; per-project learned words                                                            |
| File watching         | `NSFilePresenter` / `NSFileCoordinator` + FSEvents                              | Safe with iCloud Drive and external editors                                                                |
| Markdown              | swift-markdown (Apple) for parsing; custom Fountain-style parser for the script | Apple-maintained; the script grammar is small enough to own                                                |
| Frontmatter           | YAML via Yams                                                                   | Readable fields on notes                                                                                   |
| Canvas, timeline, map | SwiftUI `Canvas` + gestures, custom layout                                      | Smooth zoom/pan at hundreds of nodes                                                                       |
| PDF                   | Own pagination engine, drawn with Core Text into a PDF context                  | Exact control over screenplay page breaks                                                                  |
| Animatic              | AVFoundation (`AVMutableComposition`, `AVPlayer`, `AVAssetExportSession`)       | Plays images and clips as one timeline, exports .mov                                                       |
| Reminders             | `UserNotifications` + an on-launch sheet                                        | To-dos surface when you open the app                                                                       |
| Project file          | XcodeGen `project.yml`; Swift packages SlateCore, SlateUI, SlateExport          | Reproducible builds, testable core                                                                         |

Key services in SlateCore:

- **ProjectStore**: opens a folder, loads `project.json`, exposes typed models (notes, script, boards, terms), writes changes atomically.
- **FileWatcher**: reports outside changes; merges if the open document is clean, otherwise shows "Changed on disk: keep mine / load theirs".
- **ScriptParser**: turns `script.md` into elements (scene heading, action, character, dialogue, parenthetical, transition) and scenes with stable IDs.
- **LinkIndex**: tracks every `[[link]]`, alias and scene reference for backlinks, rename-refactoring and autocomplete.
- **SpellService**: merges system, global and project dictionaries into one ignore list per document.
- **ThemeEngine**: loads theme JSON and publishes resolved fonts and colours to every view.

&#91;embedded content: app architecture · 3 packages, 1 store\]

Views only observe SlateCore models and send edits back; SlateCore is the only code that reads or writes the folder, which is what keeps outside edits safe.

Distribution: start as a Developer ID app outside the Mac App Store (unsandboxed, notarized) so folders can live anywhere. Store security-scoped bookmarks for project folders from day one, so sandboxing for the App Store later is a small change.

## Project folder format

A project is an ordinary folder (not a macOS package, so Finder shows its contents), identified by a `project.json` at its root.

```text
My Film/
├── project.json                 name, id, schema version, page size, settings
├── universe/
│   ├── draft.md                 rough draft / main points
│   ├── characters/mara-voss.md
│   ├── locations/
│   ├── rules/                   how things work: time travel, tech, magic
│   ├── factions/  items/  events/  (one folder per template type)
│   ├── canvases/act-two.canvas  JSON Canvas format
│   ├── timelines/main.timeline.json
│   └── maps/city.map.json + city.png
├── script/
│   ├── title-page.md
│   ├── 01-act-one.md            optional split; files join in name order
│   ├── 02-act-two.md            (or a single script.md)
│   ├── margin/todos.md
│   └── margin/notes.md
├── storyboard/
│   ├── storyboard.json          scene order, settings
│   ├── scenes/s014 int-kitchen-night/
│   │   ├── frames.json          order, duration, shot type, caption
│   │   ├── 01.png
│   │   └── 02.mov
│   └── orphans/                 boards whose scene was removed from the script
├── dictionary/
│   ├── terms/chronoshift.md     one file per in-world term
│   └── words.txt                extra spellings, one per line
├── templates/                   project overrides for note templates
├── exports/                     Publish output (PDF, FDX, .mov)
└── .slate/                      index, caches, window state; safe to delete
```

Notes use YAML frontmatter for template fields and Markdown for the body:

```markdown
---
type: character
id: c-7f3a
name: Mara Voss
aliases: [Mara, The Courier]
age: 34
tags: [lead]
---

## Want

To undo the night at the station.

## Secret

She has already met her future self. See [[The Brass Key]].
```

Rules that keep the folder safe to touch by hand:

- IDs live in the files (frontmatter `id`, scene tags `{#s014}`), so renaming or moving a file in Finder never breaks links.
- Links use `[[Name]]` or `[[Name|shown text]]` and resolve by name, then alias, then file name.
- Writes are atomic (write to temp, then replace) and go through `NSFileCoordinator`.
- Nothing is ever deleted silently: removed scenes send their boards to `storyboard/orphans/`, deleted notes go to the Trash.
- `project.json` carries `schemaVersion`; the app migrates older projects and keeps a backup copy in `.slate/backups/`.

## Home screen, project library and import

The home screen is a library of project folders that can live anywhere on disk; Slate remembers them by bookmark, not by copying them.

**Layout**

- Sidebar: All Projects, Recent, Pinned, and Watched Folders (any folder Slate scans for projects; default `~/Documents/Slate`).
- Main grid of project cards: cover image (first storyboard frame or a chosen image), title, last edited, page count, estimated runtime, open to-dos count.
- Toolbar: New Project, Open Folder, Import, search, grid/list toggle.
- Right-click a card: Show in Finder, Rename, Duplicate, Export as .zip, Remove from Library (keeps files), Move to Trash.

**New Project** asks for a title and a starting template: Feature, Short, TV Pilot, or Blank. Templates only differ in starter files (act files, note folders, a sample title page).

**Moving projects**: bookmarks follow a folder moved in Finder. If one can't be resolved, the card shows "Missing — Locate…".

**Import**

| Source                                        | Becomes                                                             |
| --------------------------------------------- | ------------------------------------------------------------------- |
| An existing Slate folder                      | Added to the library in place (or copied, if chosen)                |
| `.zip` of a Slate project                     | Unzipped into the default folder, then added                        |
| Fountain (`.fountain`)                        | New project; script converted to Slate's format, scene IDs assigned |
| Final Draft (`.fdx`)                          | New project; elements, scene numbers and title page mapped          |
| A folder of Markdown (e.g. an Obsidian vault) | Copied into `universe/`; `[[links]]` kept, `.canvas` files kept     |
| Plain `.txt` / `.md` screenplay               | Parsed with the Fountain rules                                      |

Inside a project, the window has a sidebar (Universe, Script, Storyboard, Dictionary), the main editor, and an optional inspector on the right. Global shortcuts: Cmd-P quick open any file, Cmd-Shift-F search the whole project, Cmd-K insert a link, Cmd-Shift-O jump to scene.

## Universe (notes)

Universe is where the film is thought through before and while it is written: a rough draft, typed notes from templates, and three visual tools (canvas, timeline, map) that all point at the same notes.

**Rough draft** — `universe/draft.md`, a plain Markdown editor with a heading outline on the left. Any heading can be dragged onto the canvas or turned into a scene stub in the script.

**Templated notes**

- Built-in templates: Character, Location, Rule (how something works), Faction, Item, Event, Freeform.
- A template is itself a `.md` file: frontmatter defines fields (text, number, date, list, link, image) and the body holds starter headings. Built-ins ship in the app; copies in `templates/` override them per project, and in `~/Library/Application Support/Slate/Templates/` globally.
- Each note opens as a form of its fields on top and a Markdown body below. Editing either side rewrites the same file.
- Inspector shows backlinks (every note, scene and margin note that links here) and, for characters, scenes appeared in and line count, pulled from the script.
- Renaming a note offers to update every `[[link]]` to it across the project.

**Canvas** — an infinite board for connecting ideas, saved in the open [JSON Canvas](https://jsoncanvas.org) format so it also opens in Obsidian.

- Card types: note card (live embed of a universe note), text card, image, scene card (links to a scene in the script), group frame.
- Connections: arrows with optional labels and colours; drag from a card edge to connect.
- Zoom, pan, multi-select, align/distribute, snap to grid, minimap. Dropping a note from the sidebar creates its card.

**Timeline** — built for stories where the order things happen and the order the audience sees them differ.

- Every event has a world time (when it happens in the universe) and can link to the scene(s) that show it.
- Lanes per character or story thread; events can be points or spans.
- Branches: an alternate timeline forks from an event and can rejoin.
- Jumps: a time-travel link from a departure event to an arrival event, drawn as an arc. The traveller's own lived sequence follows jumps.
- Three views of the same data: **World order** (chronological), **Story order** (as the film plays, from scene order), **Personal** (one character's lived experience, following their jumps).
- Light continuity checks: warn when a character is in two places at the same world time without a jump, or when a scene shows an event before its cause on their personal line.
- Time units are configurable: real dates, relative days ("Day 3"), or a custom calendar with named eras.

```json
{
  "units": "datetime",
  "lanes": [{ "id": "mara", "name": "Mara", "note": "c-7f3a" }],
  "branches": [{ "id": "prime" }, { "id": "b2", "forksFrom": "e-07" }],
  "events": [
    {
      "id": "e-07",
      "title": "Station fire",
      "world": "2031-03-14T22:10",
      "lane": "mara",
      "branch": "prime",
      "scenes": ["s014"]
    },
    {
      "id": "e-12",
      "title": "Mara arrives in 1998",
      "world": "1998-06-02T09:00",
      "lane": "mara",
      "branch": "prime",
      "scenes": ["s003"]
    }
  ],
  "jumps": [{ "from": "e-07", "to": "e-12", "traveller": "mara" }]
}
```

**Map** — any image (or a blank grid) as a base layer.

- Pins, regions (polygons) and paths, each linkable to a location note or a scene.
- Layers you can toggle (e.g. "1998" vs "2031" if the city changes across time).
- Coordinates stored normalised 0–1 against the image, so swapping in a higher-resolution map keeps every pin in place.
- Clicking a location in the script's scene heading can reveal it on the map.

## Script

The script is plain text that follows the [Fountain](https://fountain.io/syntax) screenplay rules and with a scene converted that creates the scene in the storyboard.

**Syntax**

```markdown
INT. KITCHEN - NIGHT {#s014}

Rain hammers the window. MARA (34) stares at a brass key on the table.

MARA
(quietly)
I haven't opened it yet.

OLDER MARA (O.S.)
You already have.

CUT TO:
```

- `# ...` = scene heading. Lines starting with `INT.`, `EXT.`, `INT./EXT.` or `EST.` are also detected without the `#`.
- `{#s014}` = the scene's stable ID, inserted automatically when a heading is typed and hidden in the editor (shown as a small scene-number chip). It ties the scene to its storyboard, margin notes, timeline events and to-dos, so reordering or renaming scenes never breaks anything.
- Character cue = an ALL-CAPS line followed by dialogue; `(...)` lines under it are parentheticals; lines ending in `TO:` are transitions; `>THE END<` is centred; `/* ... */` is a boneyard comment left out of Publish. All per Fountain.
- `[[Name]]` links to a universe note (instead of Fountain's `[[note]]` syntax, which Slate replaces with the margin).
- Acts: either one `script.md`, or several files in `script/` that join in file-name order (`01-act-one.md`, `02-act-two.md`).

**Editor**

- Live screenplay formatting while typing: each element is indented and styled as on the page; the raw text stays plain.
- Tab / Return cycle elements like Final Draft (Action → Character → Dialogue → Parenthetical …).
- Autocomplete for character names (from the script and character notes), locations, and `INT./EXT.` / `DAY/NIGHT`.
- Two view modes: Page view (true page breaks and page numbers as they will print) and Draft view (continuous, theme fonts).
- Scene navigator on the left: scene number, heading, length in eighths, estimated time, a colour label; drag to reorder scenes.
- Focus mode, typewriter scrolling, word/page count in the status bar.
- Snapshots: Cmd-Shift-S saves a named copy to `script/.snapshots/`, with a compare view.

**Estimated timings**

- Default rule of thumb: one page ≈ one minute. Length is measured in eighths of a page, from the same pagination engine Publish uses, so estimates match the printed script.
- Per scene: length in eighths and estimated duration; totals per act and for the film in the status bar.
- Optional override per scene, e.g. `{#s014 dur=2:30}`, for montages or action sequences that run long on few pages.
- The storyboard uses these durations as the default length of each scene in the player.

**Margin** — a collapsible column to the right of the page with two tabs.

_To-dos_

- Add with Cmd-Shift-T at the cursor; the to-do is anchored to that scene (and optionally the selected words).
- Stored as a Markdown task list, readable anywhere:

```markdown
- [ ] Fix Mara's motivation before the reveal @s014 due:2026-12-01
- [ ] Check that the key is set up in act one @s003
- [x] Rename the courier @s021
```

- On launch: a sheet lists open to-dos (overdue first) for the last project, or all projects, with "Go to scene" and "Done". Setting: Off / Last project / All projects.
- Optional macOS notification for to-dos with a due date.
- A project-wide to-do list view with filters (open, done, by scene, by due date).

_Notes_

- Margin notes anchored to a scene or a selection, shown beside the line they belong to.
- Notes can hold `[[links]]` back to the universe; hovering a link shows a preview of the note, clicking opens it in a side panel without leaving the script.
- Stored in `margin/notes.md`, grouped by scene ID:

```markdown
## @s014

- "I haven't opened it yet" — she has, in the 1998 loop. See [[The Brass Key]] and [[Time Loop Rules]].
```

**Publish** — output a production can use as is. The editor theme never affects Publish; it always uses the industry layout.

| Element       | Layout (US Letter, Courier Prime 12 pt, 6 lines per inch)                 |
| ------------- | ------------------------------------------------------------------------- |
| Page          | Margins: left 1.5", right 1", top 1", bottom 1"; about 55 lines per page  |
| Page number   | Top right, 0.5" from top, followed by a period; none on page 1            |
| Scene heading | Left 1.5", ALL CAPS; scene numbers left and right in production drafts    |
| Action        | 1.5" to 7.5"                                                              |
| Character cue | Starts 3.7" from the left edge, ALL CAPS, with (V.O.) / (O.S.) / (CONT'D) |
| Parenthetical | Starts 3.1", about 2" wide                                                |
| Dialogue      | 2.5" to about 6"                                                          |
| Transition    | Right-aligned to 7.5"                                                     |

- Page-break rules: no scene heading alone at a page foot; dialogue split across pages gets (MORE) at the bottom and CHARACTER (CONT'D) at the top; never break inside a parenthetical.
- Title page from `title-page.md`: title, "written by", authors, draft date centred; contact bottom-left.
- A4 option with the same rules. Measurements above are the common industry defaults; verify against Final Draft's output during Milestone 3.
- Production mode: lock scene numbers; new scenes get letters (14A, 14B); removed scenes print as OMITTED; locked pages with A-pages (23A); revision marks (\*) in the right margin; revision colours in the standard order (White, Blue, Pink, Yellow, Green, Goldenrod, Buff, Salmon, Cherry) with the colour name and date in the page header.
- Exports: PDF (main), Final Draft `.fdx`, `.fountain`, plain `.md`, and reports: scene list (number, INT/EXT, location, DAY/NIGHT, eighths, cast), character and location reports as PDF/CSV, and sides (selected scenes only) for a shoot day.
- Print directly via the macOS print dialog using the same renderer.

## Storyboard

The storyboard mirrors the script: every `#` scene heading becomes a scene row automatically, and you fill it with frames (images, clips or sketches) that the player turns into a watchable animatic.

**Storage (recommended)** — one folder per scene, named by its ID plus a readable slug: `storyboard/scenes/s014 int-kitchen-night/`. Media files sit in it as normal files; `frames.json` holds order and metadata. The ID prefix is the real key, so the slug is renamed when the heading changes and Finder stays readable.

```json
{
  "scene": "s014",
  "frames": [
    {
      "file": "01.png",
      "duration": 3.0,
      "shot": "WS",
      "move": "static",
      "caption": "Rain on the window",
      "scriptRange": "action-1"
    },
    {
      "file": "02.mov",
      "in": 1.2,
      "out": 4.8,
      "shot": "CU",
      "caption": "The key",
      "audio": true
    }
  ]
}
```

**Board view**

- Rows of scenes in script order, each with scene number, heading, estimated time and a strip of frame thumbnails.
- Drag images or clips from Finder onto a scene to add them (copied into its folder); paste from the clipboard; drag to reorder, including between scenes.
- Per frame: shot size (EWS, WS, MS, MCU, CU, ECU, insert), camera move, lens, duration, caption, and which script lines it covers. Selecting a frame highlights those lines in the script, and vice versa.
- Built-in sketch pad for rough boards: pen, eraser, a few greys, frame guides in 16:9, 2.39:1 or 1.85:1; saved as PNG with its strokes kept beside it for re-editing.
- Empty scenes show a placeholder card with the scene's first action line, so the animatic plays even before every scene is boarded.
- When a scene is deleted from the script, its folder moves to `storyboard/orphans/` and can be reattached.

**Watch (animatic player)**

- Play one scene, a range, or the whole film, full screen or in a window.
- Built with `AVMutableComposition`: images hold for their duration (optional slow push-in), clips play with their own trim and audio.
- If frames don't set durations, the scene's estimated script time is split evenly across its frames.
- Overlays (toggle): scene number and heading, caption, and the dialogue being spoken from the script as subtitles.
- Optional scratch audio track per scene (temp music, recorded voice) and a project-wide temp score.
- Export the animatic as H.264 `.mov` to `exports/`; export boards as a PDF (2, 4 or 6 frames per page with captions).

## Dictionary and spell check

The Dictionary area is the film's own glossary, and every word in it (plus every character name and alias) is automatically treated as correctly spelled in that project.

**Project dictionary**

- One file per term in `dictionary/terms/`, with frontmatter: word, pronunciation, part of speech, plural/forms, definition, and links to related notes.
- `dictionary/words.txt` for quick custom spellings with no definition (one per line).
- List view with search, A–Z index and tags; selecting a term shows where it is used across script and notes.
- Hovering a defined term anywhere shows its definition; Cmd-click opens it.

**Built-in dictionary**

- System Look Up (force-click or Ctrl-Cmd-D) on any word, provided free by NSTextView.
- A Define panel in the inspector using Dictionary Services for the selected word.

**Spell check**

- `NSSpellChecker` with one document tag per editor; check-as-you-type and grammar toggles per area (e.g. on in Script, off in canvas cards).
- Ignore list for each document = system dictionary + global words (`~/Library/Application Support/Slate/words.txt`) + project `words.txt` + project terms + character names and aliases.
- Screenplay-aware: never flags scene IDs, `INT./EXT.`, `V.O.`, `O.S.`, `CONT'D`, `[[links]]` or shot abbreviations.
- Right-click a misspelling: suggestions, Learn for this project, Learn everywhere, Add as term (opens a new dictionary entry).
- Settings: languages (multiple at once), auto-correct on/off (off by default for screenwriting).

## Theme system

Themes are JSON files of named tokens; Light and Dark ship built in, and every colour, font and spacing value can be overridden in a theme editor with live preview.

- Location: `~/Library/Application Support/Slate/Themes/*.slatetheme` (JSON). Built-ins are read-only; "Duplicate" makes an editable copy.
- Appearance setting: Light, Dark, or Follow System, with a chosen theme for each.
- Optional per-project theme override saved in `project.json`.
- Import / export `.slatetheme` files to share themes.
- Themes change the editor and app only. Publish and print always use the industry layout.

| Token group             | What it controls                                                                                                                                                     |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App chrome              | Window and sidebar background, accent, selection, separators, toolbar                                                                                                |
| Editor                  | Background, page colour, text, caret, selection, current-line highlight, line spacing, page width, spell-error underline                                             |
| Screenplay elements     | Font, size, weight, colour, case and spacing for each of scene heading, action, character, parenthetical, dialogue, transition, centred, boneyard, scene-number chip |
| Markdown                | Body font, H1–H3, bold/italic, links, `[[wiki links]]`, broken links, code, quotes, task checkboxes                                                                  |
| Margin                  | To-do, done, overdue, note background, anchor highlight                                                                                                              |
| Canvas / timeline / map | Card fills by type, connector colours, lane colours, jump-arc colour, branch colours, pin styles                                                                     |
| Storyboard              | Board background, frame border, selected frame, player overlay text                                                                                                  |

```json
{
  "name": "Night Draft",
  "base": "dark",
  "editor": { "background": "#14161A", "text": "#E6E2D8", "lineSpacing": 1.4 },
  "script": {
    "sceneHeading": {
      "font": "Courier Prime",
      "size": 13,
      "weight": "bold",
      "color": "#F2C46D"
    },
    "character": { "color": "#9CC3FF" },
    "dialogue": { "font": "Courier Prime", "size": 13 }
  }
}
```

Any token a theme leaves out falls back to its `base`, so a custom theme can be a few lines.

## Build milestones

Twelve milestones, ordered so the script is writable and printable early and the visual tools come after the file foundations are solid. Each ends with a "done when" you can check yourself.

1. **Foundation** — XcodeGen project, three packages, ProjectStore, FileWatcher, ThemeEngine with Light/Dark, home screen with New/Open/Remove, project window with the four-area sidebar (empty views).
   - Done when: you can create a project, see its folder in Finder, edit a file there and watch the app reload it.
2. **Script editor** — ScriptParser with unit tests, TextKit 2 editor with live element formatting, Tab/Return element cycling, scene IDs, scene navigator, character autocomplete, spell check.
   - Done when: a 10-page script can be typed without touching the mouse and looks right in Draft view.
3. **Pagination and Publish** — page engine, Page view, PDF export with title page, (MORE)/(CONT'D), timings in eighths, Fountain and FDX import/export.
   - Done when: a Fountain sample script exports to a PDF whose page breaks match Final Draft or Highland within a line or two.
4. **Universe notes** — Markdown editor, templates with frontmatter forms, `[[links]]` with autocomplete, LinkIndex, backlinks, rename-refactor, project search, quick open.
5. **Margin** — anchored to-dos and notes, link previews, launch-reminder sheet, due-date notifications, project to-do list.
6. **Dictionary** — terms area, `words.txt`, merged spell-check ignore lists, hover definitions, Look Up / Define panel.
7. **Canvas** — JSON Canvas read/write, cards, connections, groups, zoom/pan, minimap.
8. **Timeline and map** — lanes, branches, jumps, the three views, continuity warnings; map layers, pins, regions, links.
9. **Storyboard** — scenes synced from the script, frame import by drag-drop, frame metadata, sketch pad, orphans, script↔frame highlighting.
10. **Animatic** — player built on AVFoundation, overlays and subtitles, scratch audio, `.mov` and board PDF export.
11. **Production features** — locked scene numbers, A-scenes and A-pages, revision colours and marks, reports, sides.
12. **Polish and ship** — theme editor UI, settings, import of Markdown folders/zip, accessibility (VoiceOver, Dynamic Type where possible), app icon, onboarding sample project, Developer ID signing and notarization.

Testing throughout: SlateCore has unit tests for every parser and file format (round-trip: read → write → byte-identical where unchanged); Publish has snapshot tests comparing rendered pages of sample scripts; a sample project in `Fixtures/` exercises every feature.

## Open decisions

The spec picks a default for each of these; change them here before Milestone 1 if you want something different.

| Decision             | Default in this spec                            | Alternative                                                 |
| -------------------- | ----------------------------------------------- | ----------------------------------------------------------- |
| App name             | Slate (placeholder)                             | Your choice                                                 |
| Scene heading marker | `#` line, plus auto-detected `INT./EXT.`        | Pure Fountain                                               |
| Acts                 | Optional split into numbered files in `script/` | `## Act` headings inside one file                           |
| Minimum macOS        | 15 (Sequoia)                                    | 26 (Tahoe) for the newest SwiftUI and Liquid Glass styling  |
| Distribution         | Developer ID, unsandboxed                       | Mac App Store (sandboxed; needs bookmarks, already planned) |
| Default page size    | US Letter                                       | A4                                                          |
| Storyboard storage   | Scene folders + `frames.json`                   | One `.slateboard` package per scene                         |
| Sketch pad           | Simple built-in (pen, eraser, greys)            | Import-only; draw in another app                            |

- [ ] Confirm the defaults above, or note changes
- [ ] Pick the app name
