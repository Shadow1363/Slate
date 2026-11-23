# Changes

## Developer ID signing, ready to switch on (2026-11-23)

- **The release workflow signs and notarizes when it can.** With the signing secrets set, it imports the Developer ID certificate into a temporary keychain. It then signs with the hardened runtime, notarizes with an App Store Connect API key, staples the ticket and deletes the keychain. Without the secrets, releases stay ad-hoc signed, and the release notes say which kind each build is.
- **`Scripts/release.sh`** notarizes with either a keychain profile or an API key (`NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`).
- **`Scripts/setup-signing.sh`:** the one-time setup. It finds your Developer ID identity, saves a `slate-notary` profile and checks it with Apple, then stores six GitHub secrets.
- **Updater:** a Developer ID-signed Slate refuses an update signed by any other team.
- **Waiting on you:**
  1. Make the Developer ID Application certificate and an App Store Connect API key (steps in README › Distribution).
  2. Run the setup script.

  Your keychain has Apple Development and Apple Distribution certificates, but not Developer ID yet. The files in `~/Keys` are for Android and iOS and aren't needed.

## 0.9.0 beta: releases, updates and screenshots (2026-11-23)

**Tests:** 440 pass: 306 in SlateCore, 107 in SlateUI and 27 in SlateExport (3 new). No compiler warnings.

### What works
- **Version 0.9.0 (beta).** The marketing version is in `VERSION`, and `project.yml` reads it through `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`. `Scripts/release.sh` takes `SLATE_VERSION` and `SLATE_BUILD`.
- **GitHub Actions:** `.github/workflows/release.yml`.
  - Every push to `main` installs XcodeGen, runs every test, packages Slate (ad-hoc signed) and publishes a prerelease named `v0.9.0-beta.<run number>`, with install notes.
  - The `dev` branch never releases.
- **Auto-update:**
  - Slate checks GitHub Releases at launch and downloads a newer version in the background. It unpacks it and checks its bundle ID and signature, then shows **Restart to Update**.
  - Restarting saves open projects and quits. A small script replaces the app (putting the old one back if the copy fails) and opens the new version.
  - **Slate › Check for Updates…** checks on demand.
  - **Settings › General › Updates:** check at launch, download automatically and include betas (all on), plus Check Now.
  - It refuses to update a copy macOS is running from a temporary location, or one in a folder you can't write to, and says why.
- **README screenshots** of the showcase (script, page view, storyboard, a note, canvas, map, timeline, search), taken by the new `Scripts/screenshots.sh`. It drives a Debug-only screenshot tour under its own bundle ID.

### Fixed
- **A canvas or map could open at 5–10%,** squeezed into a corner, when its view was first laid out tiny. It now fits once the view has its real size.

### Stubbed or not yet
- **There's no GitHub repository yet:**
  1. Create one (`gh repo create Shadow1363/Slate --public --source . --push`, or change `SlateUpdateRepository`).
  2. Push `main`.

  The first push makes the first release. Updates need the releases to be public.
- **Runner Xcode:** the workflow uses the `macos-26` runner and its newest Xcode. Slate is built here with Xcode 27.2; if the runner's Xcode is too old for something, the Test step will say so.
- **Builds are ad-hoc signed,** so the first launch still needs Privacy & Security › Open Anyway. Later updates replace the app in place and open without asking.
- **Not checked by hand:** the update banner and a real update. That needs two releases.

## Universe heading index (2026-11-23)

**Tests:** 437 pass: 303 in SlateCore, 107 in SlateUI and 27 in SlateExport (8 new). No compiler warnings.

### What works
- **Headings in the sidebar.** Every Universe note with headings gets a disclosure triangle, and its headings open as a nested tree under it. The rough draft uses the same tree instead of the old flat list.
  - Headings nest under the nearest heading above with a lower level, even across skipped levels.
  - A note's H1 that only repeats its name is left out.
- **Clicking a heading** opens the note at that heading.
- **Triangles:** a click opens or closes one level; ⌥-click does every level below; right-click › Expand All / Collapse All.
- **Remembered** per project, between launches. Notes start closed and the draft starts open. Renaming a note keeps its state, and so does editing elsewhere in it, because each heading is identified by its title path rather than its line.
- Draft headings keep Turn into Scene. Any heading can be dragged onto a canvas.

### Showcase
- Juno's Ghost section now has `### 1987` › `#### The bell` and `### Now`. The draft's act two has `### The clock` and `### The price of a turn`. SHOWCASE.md has a checklist.

### Stubbed or not yet
- Headings come from the link index, so a new heading appears in the sidebar about a quarter of a second after you stop typing.
- Not checked by hand: the indentation and triangles in the sidebar.

## Search, tags and an optional draft (2026-11-23)

**Build:** Debug builds with no compiler warnings.
**Tests:** 429 pass: 298 in SlateCore, 104 in SlateUI and 27 in SlateExport (13 new).

### What works
- **Search (⌘K)** is one Spotlight-style panel over the project window. It replaces Quick Open (⌘P) and Find in Project (⇧⌘F now opens Search as `!text `).
  - **Plain words** find notes by name and alias, scenes, films, dictionary words, timeline events, map places, canvases and files, then matching lines of text.
  - **Bangs** search one part. Template bangs: `!c` `!l` `!r` `!f` `!i` `!e` `!n`. Area bangs: `!u` `!s` `!film` `!act` `!cue` `!x` `!b` `!todo` `!mn` `!tl` `!m` `!cv` `!d` `!w` `!t` `!file` `!text` (or `/`). They can go anywhere in the query and combine.
  - **Filters:**
    - `#tag`;
    - any note field (`role:lead`);
    - scene fields (`time:`, `place:`, `int:`, `ext:`, `color:`, `film:2`, `long:`);
    - frame fields (`shot:`, `move:`, `empty:`);
    - to-do fields (`due:`, `done:`);
    - `"exact words"`.
  - **Suggestions:** typing `!` shows the bangs and `#` shows tags with counts; Tab completes them. An empty field shows recent searches.
  - **Opening a result** goes to the right area and film:
    - a scene or speech, at its line;
    - a word in the Dictionary;
    - a timeline event or map place, selected on its timeline or map;
    - a frame, selected in the Storyboard;
    - a to-do, in the margin.
  - **Settings › Search:**
    - record a different shortcut (clashes with Slate's own are refused);
    - rename area bangs;
    - Reset.

    Templates get a **Search bang** field, checked for duplicates.
  - **Insert Link** moved to ⌥⌘K (`[[` still works).
- **Tags:**
  - a tag field under every note's name;
  - **Tags…** for a scene in the Script navigator, with tags shown under the scene heading;
  - a **Tags** section in the Universe sidebar (click to search, right-click to Rename… or Remove from All…).

  Tags are normalised ("Good Guy" → `good-guy`). Scene tags live in the hidden scene tag and never print.
- **The rough draft is optional.** Right-click Draft › Move to Trash; the section disappears, and the Universe + menu offers **New Rough Draft**.

### Showcase
- Tidewater's characters are tagged: Juno `protagonist, good`; Ellis `good`; Ida `antagonist`; Tobias `mentor, good`.
- The 1987 scenes are tagged `1987` (`storm` for the two storm scenes), and Slack Water's market scene is `mystery`.
- SHOWCASE.md has a Search checklist. ShowcaseTests cover tags, bangs and filters across both films.

### Stubbed or not yet
- **Not checked by hand:** the panel's look, keyboard handling (↑/↓ inside the field), the shortcut recorder and the tag field need trying in the app.
- **The shortcut works in project windows only;** it isn't a system-wide hotkey.
- **Matching:**
  - whole words find results as written; letters in order (`mrv`) only when nothing matches exactly;
  - full text uses the same scan as before, which is fast for normal projects.
- **No tags yet** on storyboard frames or dictionary words.

### Please try
1. ⌘K, type `!`: the list of bangs. Try `!c #good`, `!t good protagonist`, `!cue juno`, `!s time:night`, `!film slack !s`, `!b empty:`, `/always empty`.
2. Open a character, add a tag under the name; right-click a scene › Tags….
3. Universe sidebar › Tags › right-click › Rename….
4. Settings › Search: record ⌃Space, then use it.
5. On a copy: right-click Draft › Move to Trash, then + › New Rough Draft.

## Templates: nothing fixed (2026-11-23)

**Build:** Debug builds with no compiler warnings.
**Tests:** 416 pass: 290 in SlateCore, 99 in SlateUI and 27 in SlateExport (4 new).

### What works
- **Delete any template**, including Slate's Character, Location, Rule, Faction, Item, Event and Freeform. Deleting a built-in writes a short `removed: true` file in `templates/` (this project) or in the global templates folder (every project, chosen with "Saved in"). Your own templates just go to the Trash.
- **Restore:** deleted templates are listed under **Deleted** in the Templates window, each with a Restore button. Deleting the `removed: true` file in Finder does the same.
- **Built-ins edit like any template.** "Save a Copy" is now plain **Save**. Your version replaces Slate's, and **Revert to Built-in** brings Slate's back.
- **Fields are all editable:**
  - the name field's key and type can change, and it can be removed (the next text field becomes the name);
  - any text field can be the **Name field**, not just `name` or `title`.
- **Renaming a template's type** works even when notes use it, and rewrites `type:` in each of those notes.
- **Notes outlive their template.** Notes of a deleted type keep every field and stay in the Universe sidebar under their folder.
- **With every template deleted,** New Note offers what's left. The Templates window explains how to make or restore one.

### Still fixed, on purpose
- Field keys `type`, `id`, `layout` and `infobox` are reserved, because Slate writes them in every note.
- Script autocomplete and spell check still read character names from `universe/characters/`. If you move Character notes to another folder, the script won't know those names.

### Please try
1. Universe › + › Edit Templates…: select Faction › Delete Template. It moves to Deleted; Restore it.
2. Rename Location's type to `place`, save, and open a location note: it says `type: place`.
3. In Character, add a text field `callsign`, pick it as the Name field, then remove `name`.

## Sagas: several films in one project (2026-11-23)

**Build:** Debug builds with no compiler warnings.
**Tests:** 412 pass: 288 in SlateCore, 97 in SlateUI and 27 in SlateExport (14 new).
**Dependencies:** none added.

### What works
- **One project, many films.** Each film is a folder in `script/`: `script/01 Tidewater/`, `script/02 Slack Water/`… Each has its own act files, title page, `production.json` (locked numbers, pages, revisions), `revisions/` and `.snapshots/`. The folder's number sets the saga's order and the rest is the film's title.
- **Shared by every film:** the universe, the dictionary, the margin's to-dos and notes, the storyboard folder, timelines, maps and canvases.
- **New Film…** comes from Script › Film, the navigator's film button, or the film bar's ⋯ menu. In a one-film project, the first New Film moves the existing script (act files, title page, production lock, revisions, snapshots) into `script/01 <project name>/`. It asks first, and canvas cards pointing at the old act files are updated. Projects you never split stay exactly as they were.
- **Switching films:** in a saga, a film bar above the Script and Storyboard navigators picks the film; both areas follow it. Script › Film lists them, and ⌃⌘] / ⌃⌘[ step through. Following a link, a scene card, a to-do or a timeline event to another film's scene switches to that film.
- **Scene IDs are unique across the saga.** A new heading in film 2 continues after film 1's highest ID. A scene pasted or copied from another film gets a fresh ID, and the earlier film keeps the original. So each storyboard folder, to-do and timeline event points at exactly one scene.
- **Storyboard:** each film's scenes become that film's rows. Boards of the other films aren't treated as "Scene Missing" and are never tidied into `orphans/`. Watch and Export Animatic and Boards PDF cover the open film.
- **Per film:** scene numbers and page counts start at 1 in each film. Publish, Print, reports and sides use the film's title page, and files in `exports/` are named after the film.
- **Saga-wide:** the timeline's Story order runs through every film in order, and its scene picker shows "Film · HEADING". Margin to-dos sort film by film. Home cards read "2 films · 132 pp · 2:12:00".
- **Rename Film…** keeps the number. **Move Film to Trash…** asks first; that film's boards move to `orphans/` when the project closes.

### Showcase
- Tidewater is now a two-film saga. The original script moved to `script/01 Tidewater/` with its production lock, Blue revision and snapshot. `script/02 Slack Water/` is a three-scene sequel (s012–s014) with one board (s012), a to-do (@s013) and a link to The Drowned Market. The story-web canvas cards point at the new paths.
- `SHOWCASE.md` has a Sagas checklist. ShowcaseTests check both films, that IDs don't overlap, the shared boards and to-dos, and the Home summary.

### Stubbed or not yet
- **Reordering films** means renumbering their folders in Finder. Slate picks the new order up straight away.
- **Quick Open** lists the open film's scenes; other films' act files are listed as files and open in their film.
- **Publish covers one film at a time.** There's no saga-wide PDF or report yet.
- **The first film can't be renamed** in a project that hasn't been split; it uses the project's name.
- **Not checked by hand:** the film bar, the menus and the New Film prompt need a look in the running app.

### Please try
1. Open a fresh Sample Film: the Script navigator shows the film bar with "1. Tidewater" and "2. Slack Water". Switch films, then open the Storyboard: s012 has its frame and Tidewater's boards are untouched.
2. In Slack Water, type a new scene heading: its ID is s015.
3. On a copy of one of your one-film projects, Script › Film › New Film…, then check the folders in Finder.
4. Timeline: Story order now runs through both films.

## Milestone 12 — Polish and ship (2026-11-23)

**Build:** Debug and Release build with no compiler warnings.
**Tests:** 398 pass: 278 in SlateCore, 93 in SlateUI and 27 in SlateExport (the backlog pass and this milestone together added 21).
**Dependencies:** none added (`ditto`, `notarytool` and `stapler` ship with macOS and Xcode).

### What works
- **Welcome window** at launch, and from Help › Welcome to Slate:
  - Open the Sample Film (a fresh Tidewater copy), New Project, or Open a Folder;
  - a short tour of the four areas;
  - a "show at launch" switch.

  Help › Open Sample Film makes a copy directly.
- **Theme editor**, from Settings › Appearance › Edit Themes…:
  - the theme list, with Duplicate, Delete, Import and Export;
  - every token grouped as in SPEC's table, edited with colour wells, font and weight menus, numbers and switches, each with a Reset;
  - a live preview.

  User themes store only what differs from their base. A change that would break a theme is refused.
- **Per-project theme:** View › Theme for This Project (saved in `project.json`).
- **Settings:**
  - **General:** the welcome window.
  - **Appearance:** adds Text size, from 85% to 150%.
  - **Spelling:** per-area switches.
  - **Reminders.**
  - **Library:** watched folders.
- **Import…** (⇧⌘I) takes:
  - a Slate folder, added in place or copied;
  - a project `.zip`;
  - a screenplay;
  - a folder of Markdown such as an Obsidian vault. It becomes a project with the notes in `universe/`; links, canvases and attachments are kept and `.obsidian` is skipped.
- **Accessibility:**
  - VoiceOver can reach canvas connections, timeline jumps, and map regions and paths (selectable);
  - the player's icon-only buttons have labels;
  - Reduce Motion stops push-ins in the player.
- **App icon:** a film slate, drawn by `Scripts/make-icon.swift` into the asset catalog.
- **Distribution:** `Scripts/release.sh` builds, signs with Developer ID, notarizes, staples, checks and zips. `--adhoc` runs the same pipeline without notarization, and works here: valid ad-hoc signature, hardened runtime on, zip written. README › Distribution has the two commands to run once you have the certificate.

### Showcase and fixtures
- `SHOWCASE.md` has a Milestone 12 checklist: welcome, theme editor, text size, vault import, VoiceOver, icon.
- New `Fixtures/MarkdownVault`: notes in a subfolder, an image, a canvas, a clashing `draft.md` and an `.obsidian` folder, used by the import tests.
- A new test checks that sample copies get free names (`Tidewater`, `Tidewater 2`) and bring the snapshot and revision copies.

### Stubbed or not yet
- **Not checked by hand:** I could launch the app, but not look at windows. The welcome window, theme editor, Import panel and VoiceOver passes need trying.
- **Notarization** hasn't run, since there's no Developer ID certificate on this Mac. The script stops with a clear message if `TEAM_ID` or `NOTARY_PROFILE` is missing.
- **The theme preview** is drawn from the theme's tokens, not with the real editors.
- **Text size** scales the editors' fonts; sidebars and other system text follow macOS's own size settings.
- **Default projects folder:** `~/Documents/Slate` can't be changed yet; watched folders can.
- **Imports:** a Markdown folder's Obsidian embeds (`![[key.png]]`) are kept as text, but Slate doesn't show the image inline.

### Please try
1. Quit Slate and open it: the welcome window. Open the Sample Film.
2. Settings › Appearance › Edit Themes…: duplicate Dark, recolour the scene heading, then pick it in View › Theme for This Project.
3. Import… `Fixtures/MarkdownVault` and click through the notes and the canvas.
4. Set Text size to 130% and look at the script.
5. Run `Scripts/release.sh --adhoc` and open `build/release/export/Slate.app`.

## Backlog pass (2026-11-23)

The SPEC features still missing from earlier milestones, and the most noticeable gaps from their "Stubbed or not yet" lists.

### What's new
- **Home:**
  - Rename…, Duplicate, Export as .zip… and Move to Trash… on every project, as SPEC lists;
  - a grid/list switch;
  - cards show page count and runtime;
  - watched folders can be added (the + in the sidebar) and removed.
- **Scene colour labels:** right-click a scene › Colour. They're saved in its tag (`{#s014 color=blue}`) and shown in the navigator, Jump to Scene and storyboard rows.
- **Act files:**
  - New Act File, from the navigator button or the Script menu;
  - drag a scene onto another act file, or right-click › Move to.
  - A scene ID repeated across act files (a file copied in Finder) is renumbered when the script loads.
- **Focus mode** (⇧⌘↩): the side columns close and other paragraphs dim. **Typewriter scrolling** is in the View menu.
- **Snapshots:** ⇧⌘S saves one to `script/.snapshots/`. Script › Snapshots… compares any snapshot with the script now, side by side, and restores it after saving "Before restore".
- **Spell check per area:** spelling and grammar switches for the script, notes, canvas cards and margin sheets. Cards and margin notes now use the project's word list too.
- **Subtitles** too short to read spread into free time around them.
- **Storyboard:**
  - adding and deleting frames can be undone (files go to the Trash and come back);
  - ⌘A selects a row, ⌘-click adds a frame;
  - Delete, shot, move and duration work on all selected frames.

### Showcase
- **Tidewater:**
  - colour labels: blue for the present, red for 1987, green for the ending;
  - a snapshot, "Before the ticket hut".
- **`ShowcaseTests`** check the labels, that the snapshot is read but isn't an act file, and that it differs from today's script where expected.

### Stubbed or not yet
- **Not checked by hand:** drag between act files, focus dimming, typewriter scrolling and the Snapshots sheet.
- **Dragging to reorder** frames still moves one frame at a time, even with several selected.

## Milestone 11 — Production features (2026-11-23)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 377 pass: 267 in SlateCore, 86 in SlateUI and 24 in SlateExport.
**Dependencies:** none added.

### What works
- **The Production menu**, in the Script toolbar and at Script › Production, holds every production command below. The Script sidebar's footer shows the state, e.g. "Scenes and pages locked · Blue Rev. 2026-11-23".
- **Lock Scene Numbers:**
  - New scenes get letters: 14A, 14B, or A1 before scene 1.
  - Cut scenes print as `6  OMITTED` in their old place.
  - Locked numbers show everywhere: the navigator, storyboard, animatic, margin, canvas, and Fountain and Final Draft exports. Fountain numbers on headings (`#14A#`) are now honoured even when not locked.
- **Lock Pages:**
  - Each page keeps starting where it did. Overflow goes onto A-pages (12A, 12B…), and a page whose start was cut prints as OMITTED.
  - Locking with nothing changed gives exactly the same pages, even where a page breaks mid-paragraph or mid-speech.
- **Revisions:**
  - Start Blue Revision copies the script to `script/revisions/01 blue/`. From then on, changed lines get a `*` in the right margin and their pages read "Blue Rev. (11/23/26)".
  - The next revision is Pink, then Yellow, and so on in the standard order.
  - Clear Revisions puts the copies in the Trash. Unlock and Clear ask first.
- **Reports**, as PDF or CSV:
  - **Scene list:** number, INT/EXT, location, time, eighths, first page and cast, with OMITTED rows.
  - **Character report:** scenes, speeches, words and first page.
  - **Location report.**
- **Sides…:** pick scenes and get just their pages, with everything else crossed out.
- **Files:** `script/production.json` (readable, order kept, unknown keys kept) and `script/revisions/`. Editing either outside Slate updates the pages. Find in Project ignores the revision copies.

### Showcase and fixtures
- **Tidewater** is now a locked Blue-revision script:
  - the ticket-hut scene from act one's boneyard note was brought back as **4A**;
  - the ferry-deck scene (whose board is the orphan) is **6 OMITTED**;
  - page 2 overflows to **2A**;
  - three changes are marked.

  `SHOWCASE.md` has a Milestone 11 checklist. Scenes are now eleven: s011 sits between s004 and s005, and has no board yet.
- **`ShowcaseTests`** check:
  - the labels, the omitted scene and that every page anchor still resolves;
  - the 2A page and the marked lines (on Blue pages, with unmarked pages left plain);
  - the scene list with its OMITTED row.
- **Checked by eye:** I rendered the showcase's page 2, its sides for 4A and the scene list.

### Stubbed or not yet
- **Not checked by hand:** the Production menu, the confirmation alerts and the Sides sheet need clicking through.
- **Only the current revision is marked.** Earlier colours' marks aren't kept, and pages aren't tinted.
- **Dual dialogue:** a mark on the right column's lines is placed on the whole row.
- **Location names** keep everything before the last " - " (`THE LIGHTHOUSE - LAMP ROOM`); there's no grouping of sub-locations.
- **No undo** for lock, unlock or revision commands; `production.json` is a plain file, so git or Time Machine can roll it back.
- **A flaky test:** `autosaveWritesAfterIdle` failed once under load and passed on every rerun. It's an existing timing test.

### Please try
1. Make a fresh Showcase project. Look at the Script sidebar numbers (4A), then Page view: 6 OMITTED, page 2A, `*` marks and the Blue header.
2. Production › Start Pink Revision, change any line, and watch only that line get a `*`.
3. Add a scene after scene 1: it becomes 1A. Production › Reports › Scene List (CSV) and open it in Numbers.
4. Production › Sides…, pick 4A, and export.
5. Unlock Pages, then Lock Pages again: the A-pages renumber.

## Milestone 10 — Animatic (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 359 pass: 256 in SlateCore, 82 in SlateUI and 21 in SlateExport.
**Dependencies:** none added (AVFoundation, AVKit, Core Image and Core Graphics are Apple's).

### What works
- **Watch** (⌥⌘↩, the Storyboard toolbar, or the new Storyboard menu) opens the animatic in its own window. It can go full screen.
  - **Ranges:** the whole film; one scene (a row's ▶ or + menu › Watch Scene); scenes from–to (the range menu); or from a frame to the end (right-click › Play From Here).
  - **Transport:** play/pause (Space), frame steps (←/→), scene steps (⌥←/⌥→) and a scrubber. Clicking the frame name selects that frame on the board.
  - **Live updates:** editing the board or the script while it's open rebuilds it within half a second, at the same place.
- **Timing:**
  - Frames without a duration share their scene's estimated time.
  - Clips play from In to Out. A clip given a longer duration holds its last frame.
  - Empty scenes play their placeholder card.
  - Frames fill the storyboard's guide (2.39:1 is letterboxed).
- **Push-in:** "Slow push-in on stills" in Storyboard Settings, or a frame's own "push in" / "pull out" move.
- **Overlays:** scene number and heading, caption, and subtitles. Each can be turned off, and the choice is remembered.
  - **Subtitles:** a line shows during the frame whose Covers includes it, and lines sharing a frame split its time by word count.
  - Lines no frame covers are placed where they fall in the scene.
- **Scratch audio:** a row's + menu › Add Scratch Audio… copies a recording into the scene's folder.
  - `frames.json` gets `"audio": "scratch.m4a"`.
  - A speaker badge on the row sets the volume.
- **Temp score:** Storyboard Settings › Temp Score copies a file into `storyboard/` and names it in `storyboard.json`, with a volume. It stays in step with film time in every range.
- **Export:**
  - **Animatic (.mov):** H.264, 1080p, overlays burned in.
  - **Boards PDF:** 2, 4 or 6 frames per page, with scene, shot, move, duration and caption.

  Both go to `exports/`, with a progress bar and Cancel at the foot of the window, then show in Finder. They're also in Script › Publish.
- **Storyboard Settings** (toolbar sliders): the temp score, push-in, and the sketch guide (now also the shape frames are shown in).

### Showcase and fixtures
- **Tidewater:**
  - spoken scratch reads on s003 and s006 (s006 at 90%);
  - a 60-second drone as the temp score (50%);
  - push-in on;
  - s010's photograph set to pull out.

  The existing Covers ranges show both subtitle cases: s006 covered, s003 placed. `SHOWCASE.md` has a Milestone 10 checklist.
- **`ShowcaseTests`** also build the whole-film animatic and check:
  - every image, clip and sound exists;
  - there are two scratch tracks and a score;
  - each scene runs its estimated time (s010 runs its frames' own 9 s);
  - s008 is a placeholder, and both moves appear;
  - every scene with dialogue has subtitles inside its own time.
- **Exported for real:** the full showcase (5½ minutes) exports in under 2 minutes with nothing missing. I checked frames from the `.mov` and a page of the boards PDF by eye.
- **The sample fixture** is unchanged. Export tests make their own image, clip and tone.

### Also changed
- New Sketch (⇧⌘K) moved from the Script menu to the Storyboard menu.
- **Fixed:** with the Links/Define inspector open, switching to Storyboard could widen the window past the screen. The board now needs 240 pt (was 420) and the frame inspector 220 pt (was 260), and the Links/Define inspector has a set width range (200–400 pt, 260 by default).
- The `ExportFormat.isAvailable` flag is gone. `isScript` tells script formats from storyboard exports.

### Stubbed or not yet
- **Not checked by hand:** I can build, test, export and launch the app, but I can't watch playback or press keys in the player here. Smooth playback, full screen, keyboard transport and live rebuilds especially need trying.
- **Short subtitles:** when a scene's frames set their own short durations (s010 runs 9 s of a 30 s estimate), lines placed by position can flash by. Giving those frames a Covers range fixes it.
- **Score length:** the temp score plays once from the start; it doesn't loop.
- **Mixing:** no fades between scenes, and a scratch track that runs longer than its scene is cut at the scene's end.
- **Export speed:** about 3× real time on this Mac. Cancel works, but the progress bar only moves during encoding, not while the composition is built.

### Please try
1. Make a fresh Showcase project. Press ⌥⌘↩ and watch from the start: the score, the scenes, the push-ins and the subtitles.
2. In the player, use Space, ←/→ and ⌥←/⌥→, then ⌃⌘F for full screen. Choose scenes 3–6 in the range menu.
3. Leave it open, change a frame's duration on the board, and see it rebuild at the same place.
4. Click s006's speaker badge and change the volume. Add scratch audio to s008 from its + menu.
5. Right-click a frame › Play From Here.
6. Export › Animatic (.mov) and open it in QuickTime. Export › Boards PDF at 2, 4 and 6 per page.

## Showcase in New Project (2026-11-22, after Milestone 9)

- **New Project › Template › Showcase (sample film)** makes a fresh copy of *Tidewater* under your title (it suggests "Tidewater"), with its own project ID. It isn't linked to the repo's copy.
- **The app now bundles** `Showcase/Tidewater` as a resource (372 KB), so this works from any build of Slate.
- **Tests:** 334 pass, one more than before: creating from the showcase copies every file except the cache, renames the project, and the result opens.

## Milestone 9 — Storyboard (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 333 pass: 242 in SlateCore, 75 in SlateUI and 16 in SlateExport.
**Dependencies:** none added (AVFoundation and ImageIO are Apple's).

### What works
- **Rows follow the script.** The Storyboard area (⌘3) has a row for every scene with an ID, in script order: number, heading, estimated time, and a strip of frames. The left column lists scenes with frame counts, then "Scene Missing" and "Orphans".
- **Empty scenes** show a placeholder card with their first action line.
- **Files:** `storyboard/scenes/s014 int-kitchen-night/` holds the media and `frames.json`, in SPEC's format. A folder is created with a scene's first frame. Images or clips dropped into the folder in Finder show up at the end of the row.
- **Adding frames:**
  - drop images or clips from Finder onto a row (or before a frame);
  - a row's + menu: Add Images or Clips…, New Sketch, Paste;
  - ⌘V pastes.

  Files are copied in and named `01.png`, `02.mov`….
- **Arranging:** drag frames to reorder, or onto another scene (the file moves, with its strokes). Delete sends a frame's files to the Trash. Undo covers details, reordering and moves.
- **Inspector:**
  - a large preview;
  - shot size (EWS to INSERT) and camera move;
  - lens, and duration (empty shows the "auto" share of the scene's time);
  - caption;
  - **Covers**, the first and last script lines the frame shows (written as `scriptRange`, e.g. `action-1..dialogue-2`);
  - for clips, In/Out sliders that update the poster, plus a sound toggle.
- **Script ↔ frames:**
  - Selecting a frame tints its lines in the script.
  - Frames that cover the line at the script's caret get a dashed outline on the board.
  - **Show Frames in Storyboard** is on the script's right-click menu, and **Show in Storyboard** on a scene's menu in the Script sidebar.
  - A frame's **Show in Script** goes the other way.
- **Sketch pad** (⇧⌘K, or a row's + menu):
  - a pen that responds to pressure (Force Touch trackpad or tablet), an eraser, four greys and three sizes;
  - 16:9, 2.39:1 and 1.85:1 guides, with the area outside darkened;
  - undo and redo per stroke, and Clear.
  - It saves a PNG cropped to the guide, with `NN.strokes.json` beside it. Double-click the frame (or Edit Sketch) to change it.
- **Clips:** a poster frame and length are read in the background. A clip with no duration plays from in to out.
- **Missing scenes:** when a scene is deleted, its row turns "scene missing" right away, with **Reattach** (to any scene without a board) and **Move to Orphans**.
  - When the project opens or closes, leftovers move to `storyboard/orphans/`, and folder names are renamed to match changed headings (or press **Tidy**).
  - Nothing moves while you type, and nothing is orphaned if the script has no scenes.
  - Orphans can be reattached.
- **Home:** each project card shows its first storyboard image.
- **Outside edits:** editing `frames.json` in another app reloads the board. The project store now notices changed contents, not only added or removed files.

### Showcase and fixtures
- **Tidewater:**
  - boards for nine of ten scenes, using every shot size, seven camera moves and two lenses;
  - a sketch with strokes and a 3-second clip, trimmed 0.5–2.5 s;
  - an empty s008 to show the placeholder;
  - a cut "ferry deck" board in `orphans/` to reattach.

  `SHOWCASE.md` has a Milestone 9 checklist.
- **`ShowcaseTests`** now also check that every frame file exists, every `scriptRange` resolves, folder names match headings, `frames.json` is in Slate's layout, and only the orphan is unattached.
- **The sample fixture** has a three-frame board for s014, one of them a sketch.

### Stubbed or not yet
- **Not checked by hand:** I can build, test and launch the app, but I can't draw or drag here. The sketch pad with a real tablet or trackpad, dragging between rows, and paste especially need trying.
- **Playback:** the animatic player, overlays, scratch audio, `.mov` export and the boards PDF are Milestone 10. Clips can be trimmed but not played yet.
- **Undo limits:** adding frames isn't undone with ⌘Z (delete them instead), and a deleted frame comes back from the Trash, not with undo.
- **Selecting:** ⌘A on a row isn't in yet; frames are selected one at a time.
- **Thumbnails** are cached in memory only, so a big project rereads them each launch.

### Please try
1. Open Tidewater and press ⌘3. Scroll the rows; s008 shows its placeholder.
2. Select frame 2 of s003, the clip, and drag the In and Out sliders.
3. Select a frame, then press ⌘2: its lines are tinted. Right-click an action line › Show Frames in Storyboard.
4. Press ⇧⌘K and draw, using pressure if you can. Erase, switch guides, then Add Sketch. Double-click it to edit.
5. Drag a frame to another scene, undo, then drop an image from Finder onto a row.
6. Reattach the ferry orphan to s008.
7. Delete a boarded scene's heading in the script, look at the board, then close and reopen the project.

## Showcase project (2026-11-22, after Milestone 8)

- **New:** `Showcase/Tidewater`, a made-up short film about a lighthouse keeper, a clock that winds back the tide, and a brother saved at a price. It uses every feature from Milestones 1–8:
  - three act files using every Fountain element;
  - notes of every type, a wiki-infobox note and a project-only Vessel template;
  - margin to-dos and notes;
  - a dictionary;
  - a canvas;
  - timelines in dates, days and a custom calendar;
  - an image map with layers and a blank-grid map.
- **`SHOWCASE.md`** inside it is a checklist of what to try, by milestone.
- **`ShowcaseTests`** (4 tests) check that every file reads, links and scene IDs resolve, every script element appears, all three time units are used, and only the warning left in on purpose shows.
- **From now on,** each milestone adds its features to the showcase and its checklist.

## Milestone 8 — Timeline and map (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 310 pass: 230 in SlateCore, 64 in SlateUI and 16 in SlateExport.
**Dependencies:** none added.

### Timeline: what works
- **Files:** `universe/timelines/*.timeline.json`, in SPEC's format plus `end`, `location`, `after`, `summary`, `color`, branch `name`/`rejoins` and custom-calendar eras. They're written as indented, readable JSON. An unchanged file is never rewritten, and keys from elsewhere are kept.
- **The sample project** has `main.timeline.json`, with Mara and Thomas, a span, a jump from the 2031 fire back to 1998, a "No fire" branch, and two warnings left in on purpose.
- **Sidebar:** a **Timelines** section with New Timeline (also in the + menu).
- **World Order:** a column for each distinct time and a row for each lane, with branch rows under their lane.
  - Spans stretch across columns, and overlapping events stack.
  - Jumps are orange arcs; forks and rejoins are dashed lines.
  - Double-click a row to add an event at that time.
- **Story Order:** a column for each scene that shows an event, in script order, plus "Not in the script". Double-click a column header to go to the scene.
- **Personal:** pick a character to see their life in the order they live it, following their jumps. Events after each jump are marked.
- **Inspector:**
  - **Events:** title, when, end, lane, branch, place (a location note or any name), scenes (checkboxes), "happens after" causes, jumps, summary, colour and that event's warnings.
  - **Lanes:** name, linked note and colour.
  - **Branches:** name, where it forks and where it rejoins.
- **Right-click an event:** open its scenes or place; Jump From Here… (then click the arrival); Branch From Here; Duplicate; Delete.
- **Right-click a lane:** add an event; follow the character's life; move up or down; delete.
- **Warnings** (toolbar button with a count):
  - a character in two places at once with no jump;
  - an event before its cause;
  - events that fall between a traveller's jumps;
  - unreadable or backwards times;
  - links to missing lanes, branches, events or scenes.

  Click a warning to select its event; warned events show a triangle.
- **Time units:** dates, days, or a custom calendar whose eras you set.
- **Zoom:** ⌘= / ⌘− make columns wider or narrower. **Undo** works for every change.
- **Links:** lanes and places are backlinks, so a note's inspector shows "“Mara” on this timeline". They're stored by note `id`, which survives renames. Paths and names are updated when a note is renamed.

### Map: what works
- **Files:** `universe/maps/*.map.json` beside their image, with layers, pins, regions and paths. Coordinates are saved from 0 to 1 across the image.
- **The sample project** has `city.map.json` and a generated `city.png`, with a station pin, an Old Town region on the 1998 layer and a chase path on the 2031 layer.
- **Sidebar:** a **Maps** section with New Map, which starts as a blank grid. Map images are kept out of Other Files.
- **Base layer:**
  - the image, or a grid;
  - Add or Change Image copies the image beside the map, and so does dropping one from Finder;
  - if the image goes missing, a banner says so and the pins stay put.
- **Moving around:** scroll to pan and pinch or ⌘-scroll to zoom, as on the canvas. ⌘0 fits.
- **Tools:**
  - **Select:** click an item, drag it to move it, drag a corner dot to reshape it, or drag empty space to pan;
  - **Pin:** click to place a pin;
  - **Region** and **Path:** click corners, then double-click or press Return to finish (Escape stops).
  - Delete removes the selected item, and every change can be undone.
- **Inspector:** title, layer, colour, linked note (locations listed first) and scenes. Double-click an item to open its note or scene.
- **Dropping a note** from the Universe sidebar makes a pin linked to it.
- **Layers:** show or hide each one (for this window only; the file isn't changed), choose the layer new items go on, add, rename and delete.
- **Show on Map:** right-click a scene in the Script sidebar. The map opens on the pin linked to that scene, or else the one linked to the location its heading names, and briefly highlights it.
- **Links:** map items linked to notes are backlinks ("“The Station” on this map").

### Also changed
- The canvas's pan and zoom handling is now shared with maps, and its edit, undo and save logic has a shared version (`FileBackedModel`) that timelines and maps use.
- Note `id:` values are now link targets.
- The link index cache version went to 5, so it rebuilds once.

### Stubbed or not yet
- **Not checked by hand:** I can build, test and launch the app, but I can't click through these screens from here. Map dragging, drawing regions, and the timeline's double-click and context menus especially need trying.
- **Scene links:** "Show on Map" is only on the Script sidebar's scene menu, not on a click in the script editor's heading. A scene doesn't yet list its timeline events.
- **Timeline columns aren't to scale:** one per distinct time.
- **Personal view** shows every branch together.
- **Events** can't be dragged between lanes or times on the grid; use the inspector.
- **Map editing:** you can't add or remove a corner of an existing region or path. Hidden layers are forgotten when the map is closed.
- **Time formats:** custom-calendar times are only `<era> <number>` (no months).

### Please try
1. Open **main** under Timelines. Check World Order: the arc from Station fire back to "Mara arrives in 1998", and the dashed fork to the "No fire" row.
2. Click **2 Warnings**, then each warning: it selects the clashing event. Change "Mara at the archive" to happen at the Station and the two-places warning goes away.
3. Switch to **Personal** and pick Mara: her life runs to the fire, then continues from 1998.
4. Right-click an event, choose **Jump From Here…**, click another event, then undo.
5. Open **city** under Maps. Hide the 1998 layer and drag the station pin. Draw a region with the Region tool, then reshape it by its corner dots.
6. Right-click the kitchen scene in the Script sidebar and choose **Show on Map**.
7. Edit `main.timeline.json` in VS Code while it's open: the timeline reloads.

## Templates rework and Milestone 7 — Canvas (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 276 pass: 203 in SlateCore, 57 in SlateUI and 16 in SlateExport.
**Dependencies:** none added.

### Templates and notes: what works
- **Your infobox notes open as they are.** The sample project now includes the note you pasted, as `universe/characters/thomas-wiley-cade.md`, plus a Powers note so its links resolve. Opening it shows:
  - the title, and "The Broken" under it;
  - the Character template;
  - your fields;
  - a **Powers** header above two columns of links, showing their alias text;
  - the status hidden as a spoiler until you click it.
- **Notes look like a wiki page:** the body is on the left and the infobox card on the right (the sidebar button hides it). Empty fields are left out of the card. **Edit** turns the card into a form with a control for each field type, plus a box to add a field to just this note. Each change rewrites only that field's lines, keeping comments, line endings and your `layout:` block.
- **New field types:**
  - **Long text**, written as a YAML block;
  - **Choice**, a dropdown of options you define;
  - **Yes/No**, a checkbox;
  - **Links**, several `[[links]]`.
- **Universe › Templates…** opens from the + menu, or Edit Templates… in the New Note sheet.
  - **Every template** is listed, marked Built-in, This project or Every project.
  - **The form:** name, icon, type, folder, name field (`name` or `title`), and where to save it.
  - **Fields:** key, label, type, choice options, a section header, and "beside previous" for columns. Drag to reorder, add and remove.
  - **Starter headings**, and a live infobox preview.
  - **New Template** starts blank or from a copy of another template.
  - **Built-ins** can't be changed in place: saving one makes your own copy, and **Revert to Built-in** puts the original back. Your own templates can be deleted.
  - **Saving** goes to the project's `templates/` by default, or to every project.
- **Spoilers:** `||text||` is hidden in the infobox, link previews and canvas cards until clicked.
- Custom templates appear in the New Note menu and the sidebar with their icons. Their folder is created when you make the first note.

### Canvas: what works
- **Boards** are `universe/canvases/*.canvas` files in JSON Canvas format.
  - The sidebar has a **Canvases** section with New Canvas.
  - The sample project has `act-two.canvas`, with one card of each type.
- **Cards:**
  - **text card:** rendered Markdown with clickable links; double-click to edit the raw text;
  - **note card:** the note's infobox and the start of its body; double-click opens the note;
  - **scene card:** number, heading and length; double-click goes to the scene;
  - **image card**;
  - **web link card:** shows the address; double-click opens it in the browser;
  - **frame:** a coloured, labelled group.
  - Cards can be coloured with the six JSON Canvas colours.
- **Navigating:** scroll to pan; pinch or ⌘-scroll to zoom; ⌥-drag to pan with a mouse. ⌘0 fits everything, ⇧⌘0 is 100%, and ⌘= / ⌘− zoom. The minimap in the corner can be clicked or dragged, and the zoom level shows bottom-left.
- **Selecting:** click, ⇧-click, drag a marquee on empty space, or ⌘A.
- **Editing:**
  - drag cards to move them (a frame takes its cards with it); resize from the corner handle; Delete removes the selection;
  - double-click empty space to add a text card;
  - the toolbar adds a text card, frame, note, scene, image or web link;
  - **Arrange** aligns and distributes; **Snap to Grid** (on by default) uses a 20 pt grid.
- **Connections:** drag a dot on a card's side onto another card. Select a connection to give it a label, a colour, and arrows at either end.
- **Drag and drop:** notes and rough-draft headings from the Universe sidebar, scenes from the Script sidebar, and images from Finder, which are copied into `universe/canvases/images/`.
- **Undo** works for every change; a whole drag is one step.
- **Files:** changes are saved through the usual autosave. Editing the file elsewhere reloads the board. A board you haven't changed is never rewritten, and keys from other apps are kept.
- **Links:** a note's inspector shows the boards it's on. Renaming or moving a note updates its cards.

### Stubbed or not yet
- Not checked by hand: I can build, test and launch the app, but I can't drag on the board or click through these screens from here. Trackpad gestures, drag and drop and the inline editors especially need trying.
- Canvas text cards have no spell-check setting yet, and their Markdown rendering is simple: headings, lists, tasks, quotes, emphasis and links, but no tables or code blocks.
- Web link cards show the address, not a preview of the page, because SPEC rules out web views.
- A connection can't be re-attached to a different card; delete it and draw a new one.
- Multi-select alignment uses the toolbar's Arrange menu. There are no alignment guides while dragging.
- In a long-text field, each change is written as you type, like the other fields.

### Please try
1. Open **Thomas Wiley Cade**. Check the infobox, the Powers columns, and click the hidden status.
2. Click **Edit**, change the height, then check in VS Code that only that line changed.
3. Go to **Universe › + › Edit Templates…**. Make a new template from a copy of Character, add a Choice field and a Long text field, set one field "Beside previous", then save it to This project. Make a note from it.
4. Edit the built-in Location template and save it, then **Revert to Built-in**.
5. Open **act-two**. Pan, pinch, press ⌘0 and use the minimap. Drag Mara Voss in from the sidebar, connect two cards and label the connection, group cards and move the group, align three cards, then undo.
6. Open `act-two.canvas` in Obsidian, or read the JSON: it loads, and `styleAttributes` is still there.
7. Edit the canvas in VS Code while Slate has it open, and watch the board reload.

## Milestone 6 — Dictionary (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 244 pass: 181 in SlateCore, 47 in SlateUI and 16 in SlateExport.
**Dependencies:** none added. Spell check uses `NSSpellChecker` and definitions use Dictionary Services, both part of macOS.

### What works
- **`dictionary/words.md`** is the project's dictionary, as you asked: one readable book, filed A–Z.
  - `- Riley` is a spelling.
  - `- **Chronoshift** *noun* (chronoshifts, chronoshifted) — meaning` is a word with its part of speech, other forms and meaning. Meanings can run onto indented lines.
  - A `[[link]]` in the meaning points to a Universe note, so a made-up element can have a one-line meaning here and its full story in Universe.
- **Dictionary area:**
  - The sidebar has a search field (words, forms and meanings) and an A–Z strip for jumping. Words from the global book are listed under "Every Project".
  - With no word selected, the main view shows every defined word as a reading page, with the spelling-only words listed underneath.
  - A word's page shows its card, an Open-note button when it links somewhere, Look Up, and **Used In**: every place it appears in the script and notes. Click a row to go there.
  - **Add Word** is ⌘N or +. It opens a sheet with fields for word, part of speech, forms and meaning, a **Link to Note** menu, and a choice of this project or every project. Edit and Delete are on the same sheet and in the right-click menu.
  - The document toolbar button shows `words.md` as text in the Markdown editor.
- **In every editor** (script, notes, the draft, the word book):
  - Words in the dictionary aren't flagged as misspelled. Neither are their forms or character names.
  - Defined words get a faint dotted underline. Hovering one shows its meaning, or its note's preview if the entry is only a link.
  - ⌘-click opens a defined word: a link-only entry opens its note (in the margin, from the script); any other entry opens its page.
- **Right-click a misspelling:**
  - **Add to Project Dictionary** adds the word to `words.md`, under its letter.
  - **Add to Every Project** adds it to the global `~/Library/Application Support/Slate/words.md`.
  - **Define in Dictionary…** opens the Add Word sheet.

  These replace the system's "Learn Spelling", which would teach every app on the Mac.
- **Define panel:** the inspector now has Links and Define tabs (⌃⌥⌘D opens Define). It shows the project's meaning for the selected words first, then the definition from the Mac's dictionaries. Force-click Look Up works as before.
- **Settings › Spelling:**
  - language: Automatic, or one fixed language;
  - grammar checking for the script (off) and for notes (on);
  - auto-correct (off);
  - a button that shows the global word book in Finder.
- **Links and rename:** `[[links]]` in `words.md` show up as backlinks on Universe notes, and renaming a note updates them.
- **Outside edits:** edits to `words.md` reload the book, the underlines and spell check. Edits to the global book are picked up when you switch back to Slate.
- **Older projects** are converted once, and `project.json` moves to schema 3:
  - the words in `words.txt` become spelling entries;
  - any `dictionary/terms/*.md` file moves to `universe/notes/`, and its entry keeps the definition and links to the note;
  - the originals are copied to `.slate/backups/dictionary-v2-<date>/` first.
- **Sample project:** it now has a `words.md` with spellings, a word with forms (Chronoshift), and a link-only word (Brass Key). The script uses "chronoshifted".

### Stubbed or not yet
- Spell check in the margin's to-do and note sheets uses the system list only, because they're SwiftUI text fields. The script and Markdown editors use the full list.
- The meaning field in the Add Word sheet has no `[[` autocomplete. Use the Link to Note menu, or type the link.
- Multiple languages at once work only through Automatic, which uses the languages set in System Settings. macOS has no per-app language list.
- Typing speed: the keystroke test passes in the full test run, but this Mac is busy right now (load average around 12). Debug builds measure about 24–34 ms per keystroke, against the 33 ms limit, and release about 17–20 ms, against 16 ms, so the test can fail on a loaded machine. A clean copy of the Milestone 5 code measures the same on this machine today, so this milestone didn't slow typing. Matching 200 dictionary words across ten pages takes about 8 ms, and it runs only after you pause typing.
- Not checked by hand yet. Please try these:
  1. Open the sample project's Dictionary. Search "chrono", click C on the A–Z strip, and open Chronoshift to see its meaning and Used In.
  2. Click the `[[Time Travel]]` link on Chronoshift's page, and the Universe note opens.
  3. In the script, type a made-up word, right-click it, choose Add to Project Dictionary, and check that `words.md` has it under its letter.
  4. Hover "chronoshifted" in the script to see the meaning card. Hover "brass key" in a note for the note preview, and ⌘-click it.
  5. Edit `words.md` in VS Code while Slate is open: the book, the underlines and spell check update.
  6. Select an ordinary word and press ⌃⌥⌘D to see the Mac's definition.
  7. Open a copy of an older project with a `words.txt`: it converts, and the original is in `.slate/backups/`.

## Milestone 5 — Margin (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 224 pass: 169 in SlateCore, 39 in SlateUI and 16 in SlateExport.
**Dependencies:** none added; notifications use Apple's UserNotifications.

### What works
- **Margin column** beside the script (⇧⌘M or the toolbar button), with To-dos and Notes tabs. Each tab shows This Scene (the caret's scene) or All.
- **To-dos** (`script/margin/todos.md`, a Markdown task list):
  - ⇧⌘T adds one at the caret, anchored to the scene and the selected words, with an optional due date.
  - Tick, edit or delete from the list. Ticking changes only the `[ ]` box in the file.
  - Filters: Open / Done / All. Order: By Scene / By Due Date. Overdue dates are red.
  - Scene chips jump to the scene; a quote selects those words. Script › Show All To-dos opens the project-wide list.
- **Notes** (`script/margin/notes.md`, grouped by `## @sceneID`):
  - ⌥⌘T adds one at the caret (anchored to the scene and the selection), or type it at the bottom of the tab.
  - `[[links]]` are clickable. Notes can be edited and deleted.
- **Anchors:** the words a note or open to-do points at get a soft highlight in the script. The file isn't touched.
- **Link previews:** hovering a `[[link]]` for half a second in the script, a note or the draft shows a preview (name, type, fields, start of the body).
- **Peek:** ⌘-click on a link in the script, or a click in the margin, opens the note in the margin. You stay in the scene, and Open in Universe goes to the full note.
- **Launch sheet:** open to-dos, overdue first, with Go to Scene and Done. **Settings › Reminders** chooses Off / Last project (the default) / All projects.
- **Due-date notifications** at 9:00 on the due date. Clicking one opens the project at the scene. They're rescheduled whenever to-dos change, and can be turned off in Settings › Reminders.
- **Project cards** show how many to-dos are open.
- **Outside edits** to either margin file reload the lists. An edit to an item that changed underneath is refused with a message, and never overwrites.

### Stubbed or not yet
- Notes are listed per scene in the margin, not placed level with their exact line as the script scrolls.
- If the anchored words are rewritten in the script, the item keeps its scene but loses its highlight; there's no fuzzy re-anchoring.
- Notifications only cover to-dos as of Slate's last launch or edit. A due date added in another editor while Slate is closed is scheduled at the next launch.
- If no Slate window is open when you click a notification, the project opens the next time the library window appears.
- Not checked by hand yet. Please try these:
  1. Open the sample project. The margin shows its to-dos; the Notes tab shows the "I haven't opened it yet" note, and those words are highlighted.
  2. Select some words, press ⇧⌘T, set a due date for tomorrow and add it. Check `todos.md` in another editor.
  3. Hover `[[The Brass Key|a brass key]]` in the script, then ⌘-click it.
  4. Quit and reopen Slate: the launch sheet should list the open to-dos. Try Done and Go to Scene.
  5. Set a to-do due today, allow notifications, and wait for it (or set it in the past to see it only on the sheet).

## Standard Fountain scripts (2026-11-22, after Milestone 4)

You asked to drop `#` scene headings and use standard Fountain.
- **Scene headings:** `INT.`, `EXT.`, `INT./EXT.`, `I/E` and `EST.` lines after a blank line are headings. Anything else is forced with a leading `.` (`.THE VAULT`). These headings are what create scenes in the navigator and, from Milestone 9, in the storyboard.
- **Sections:** `#`, `##`, … lines are Fountain sections. They're styled bold and grey in the editor, and left out of PDF, Final Draft and Markdown exports.
- **Typing a heading:** when you leave the line, the editor capitalises it and adds the `.` if Fountain would need it, or removes it if not.
- **Scene numbers:** Fountain's `#1A#` scene numbers are read.
- **Scene tags:** `{#s014}` stays as Slate's only addition to Fountain, because it keeps storyboards attached to scenes.
- **Older projects:** opening a project from before this change rewrites its `# HEADING` lines once, after backing the files up to `.slate/backups/script-v1-<date>/`. `project.json` goes to schema 2.
- **New projects:** act files start with `# ACT ONE`-style sections.
- **Fountain import and export:** import keeps sections and forced headings as written. Export no longer adds a duplicate section.
- **Tests:** 206 pass: 158 in SlateCore, 32 in SlateUI and 16 in SlateExport. The editor's speed test now allows 33 ms per keystroke in debug builds and keeps 16 ms for release builds (measured at about 9 ms).

## Milestone 4 — Universe notes (2026-11-22)

**Build:** `xcodebuild … build` succeeds with no compiler warnings.
**Tests:** 199 pass: 153 in SlateCore, 30 in SlateUI and 16 in SlateExport.
**Dependencies:** Yams 6.2.2 and swift-markdown 0.9.0, both used only by SlateCore and pinned exactly.

### What works
- **Universe area:**
  - The navigator shows the rough draft with its heading outline, then notes grouped by type with backlink counts, then any other files.
  - + (or ⌘N) makes a note from a template, with the name field ready to type.
  - Right-click a note for Rename…, Show in Finder or Move to Trash.
- **Templates:**
  - Seven built-ins: Character, Location, Rule, Faction, Item, Event, Freeform.
  - A template is a plain `.md` file with a `fields:` map and starter headings.
  - Copies in project `templates/` or `~/Library/Application Support/Slate/Templates/` override built-ins of the same type.
- **Note form:**
  - The name, plus each template field: text, number, date (with a calendar), list (as chips), link (with suggestions and an open button) and image (copied next to the note, with a thumbnail).
  - Keys that aren't in the template still show, in italics.
  - Each edit rewrites only that key's lines, keeping comments, key order and quoting. Unchanged files stay byte-identical.
  - If the YAML is broken, the file opens as plain text with a warning, and nothing is hidden.
- **Markdown editor** (styled source, TextKit 2):
  - Headings at theme sizes; bold, italic, strikethrough and code styled; markers dimmed; quotes, lists, task lists and code blocks styled.
  - Return continues a list.
  - Spell check skips links and code.
  - Only changed lines are restyled while typing.
  - For notes it edits only the body, below the form.
- **Links:**
  - `[[Name]]`, `[[Name|shown]]` and `[[Name#Heading]]` are tinted chips. Unresolved links are red with a dashed underline.
  - Typing `[[` suggests names and aliases: ↑/↓ choose, Return or Tab insert, Esc dismisses. ⌘K inserts a link.
  - ⌘-click opens the target. An unresolved link offers to create the note, with its name already filled in.
  - The same works in the script editor.
- **LinkIndex:**
  - Resolves by name, then alias, then file name, ignoring case and accents.
  - Indexes notes, dictionary terms, act files (each link tied to its scene), margin notes and the draft.
  - Unsaved edits count after a short pause.
  - Its cache in `.slate/index/links.json` can be deleted at any time.
- **Links inspector** (⌥⌘0):
  - Backlinks with context; clicking one jumps to that line or scene.
  - For a character, the scenes they speak in, with speech counts.
  - Unresolved links in the note, each with a Create… button.
- **Rename:**
  - Shows a sheet: "Update N links in M files?", with a preview of each edit.
  - Update Links / Rename Only / Cancel.
  - The file follows the new name, and the `id` stays the same.
  - Alias links and links in code are left alone. Open documents change in memory; closed files are rewritten atomically.
- **Find in Project (⇧⌘F):**
  - Ignores case and accents; `"quotes"` give an exact phrase.
  - Results are grouped by file, with the match highlighted. Return opens the note or act file at the match.
  - Searches unsaved edits too.
- **Quick Open (⌘P):** fuzzy matching over note names, aliases, scenes and files.
- **Rough draft:**
  - Its outline is in the sidebar; click a heading to jump to it.
  - Right-click › Turn into Scene appends `# HEADING {#sNNN}` to the last act file.
- **Files:**
  - Notes are moved with NSFileCoordinator when renamed, and Move to Trash never deletes outright.
  - Outside edits reload the form and the body like any other file.
- **Sample project:** now has The Brass Key (item), The Station (location), Loop Rules (rule, with a hand-written YAML comment), alias and unresolved links, a script link, and a project Character template.

### Stubbed or not yet
- Dragging draft headings onto a canvas waits for the canvas (Milestone 7). Canvas, timeline and map files appear under "Other Files".
- Dictionary terms are indexed as link targets, but the Dictionary area is still a file list (Milestone 6).
- The list field edits chips; you can't drag them to reorder yet.
- Link suggestions rank by prefix, then name order, not by recent use.
- Rename doesn't merge two notes, and renaming to an existing name is allowed (links then resolve to the first by path).
- Search is plain text; there's no regex or replace.
- Not checked by hand yet, since I can't drive the UI here. Please try these:
  1. Open the sample project and press ⌘1. Mara Voss opens as a form with the body below.
  2. Change Age, then check the file in another editor: only that line changed.
  3. In the draft, type `[[Br`, accept "The Brass Key", then ⌘-click it.
  4. Open the inspector (⌥⌘0) on The Brass Key. You should see Mara's note, the kitchen scene, the margin note and the draft.
  5. Rename The Station and accept Update Links.
  6. Search with ⇧⌘F for "rain", and open a scene with ⌘P.
  7. Edit a note in VS Code while it's open, and watch the form reload.

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
