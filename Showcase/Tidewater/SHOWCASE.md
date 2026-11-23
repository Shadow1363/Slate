# Tidewater: the Slate showcase

A made-up short film that uses every feature Slate has so far. Open this folder in Slate (⌘O). Everything here is filler.
Each milestone adds its features to this project; the checklist below grows with it.

**Story:** Juno Hale keeps the lighthouse in Saltmarrow. She finds a clock that winds the tide back one night per turn, goes back to the 1987 storm to save her brother Ellis, and pays with her own place in the family.

## Milestone 1: Foundation
- [ ] The project opens from the home screen; the four areas (⌘1–⌘4) show this folder's files.
- [ ] Edit a file here in another app and watch Slate reload it.

## Milestone 2: Script editor
- [ ] `script/` has three act files that join in name order: `# Act` sections, `=` synopses, a `## The storm night` sequence.
- [ ] Every element: scene headings with hidden IDs (`{#s001}`…`{#s010}`), action, characters with (V.O.), (O.S.) and (CONT'D), parentheticals, dialogue, dual dialogue (`^` in s006), a lyric (`~`), centered text (`> … <`), transitions, a boneyard (`/* */` in s004), a page break (`===` in act two), *italic* and _underline_.
- [ ] Spell check leaves Juno, Saltmarrow and Tidewind alone (they're in the dictionary).

## Milestone 3: Pagination and Publish
- [ ] Page view; Tobias's long speech in s007 should break with (MORE) / (CONT'D) depending on where it falls.
- [ ] s004 has a `dur=1:15` timing override. Publish a PDF with the title page; export Fountain and FDX.

## Milestone 4: Universe notes
- [ ] Notes of every built-in type: characters, locations, a rule, a faction, an item, an event, a freeform note (`notes/themes.md`).
- [ ] `templates/vessel.md` is a project-only template; *The Marigold* uses it (choice, yes/no, number, date, links, long text, picture, layout).
- [ ] Ellis Hale is in the wiki-infobox format (`title`, `subtitle`, `infobox`, `layout` with a header and columns, a `||spoiler||`).
- [ ] Links with aliases and headings (`[[The Tidewater Clock#What it is|the clock]]`), backlinks, the rough draft's outline, rename, quick open (⌘P) and Find in Project (⇧⌘F).

## Milestone 5: Margin
- [ ] To-dos anchored to scenes and quoted words, one overdue, one due later, one done, one with no scene.
- [ ] Margin notes for s003, s007 and s010, plus a whole-script note.

## Milestone 6: Dictionary
- [ ] `dictionary/words.md`: spellings only, meanings with parts of speech and forms (Tidewind), linked entries, a `#` entry ('87 storm).
- [ ] Defined words get a dotted underline in the script; hover them.

## Milestone 7: Canvas
- [ ] `story-web`: two frames, text cards (Markdown, a task list, a quote, a link), note cards, scene cards, an image, a web link, and connections with labels, colours, a two-way arrow and one with no arrow.

## Milestone 8: Timeline and map
- [ ] `main` timeline (dates): four lanes, a decades-long span, two jumps by Juno, an "Ellis lives" branch, causes (`after`), and one warning left in on purpose (Ida in two places).
- [ ] Personal view for Juno: present day → 1987 → earlier that night. Young Juno's 1987 event doesn't clash with adult Juno's.
- [ ] `storm-week` (days, with a span and a time of day) and `legends` (a custom calendar with three eras).
- [ ] `saltmarrow` map: an image, 1987 and 2024 layers, pins, regions and paths linked to location notes and scenes. `lighthouse-floors` is a blank-grid map.
- [ ] Right-click any scene in the Script sidebar › Show on Map.

## Milestone 9: Storyboard
- [ ] Storyboard (⌘3): eleven scene rows in script order. s008 has no frames, so it shows its first action line (as does s011, added in Milestone 11).
- [ ] Every shot size (EWS to INSERT) and seven camera moves; s002 and s007 set a lens.
- [ ] s003: frame 1 is a **sketch** (double-click to edit; 2.39:1 guide), frame 2 is a **clip** trimmed 0.5–2.5 s (drag the In/Out sliders), frame 3 an insert.
- [ ] Select a frame, then go to Script: its lines are tinted. Put the caret on an action line and come back: frames that cover it are outlined.
- [ ] Right-click in the script › Show Frames in Storyboard.
- [ ] Orphans: "s099 ext-ferry-deck-day" was cut from the script. Reattach it to s008.
- [ ] Delete a boarded scene in the script: its row turns "scene missing". Close and reopen the project and it's in `storyboard/orphans/`.
- [ ] Rename a heading, then press Tidy (or reopen): the folder name follows.
- [ ] Drag a frame to another scene and undo. Drop an image from Finder onto a row. New Sketch with ⇧⌘K.
- [ ] Home: the project card shows the first frame.

## Milestone 10: Animatic
- [ ] Storyboard › Watch Animatic (⌥⌘↩): the whole film plays in its own window, 2.39:1 letterboxed, with the temp score (`storyboard/score.m4a`, 60 s, at 50%) under it.
- [ ] s003 and s006 have **scratch audio** (a speaker badge on their rows). s006's is at 90%; click the badge to change it.
- [ ] **Push-in** is on in Storyboard Settings, so stills drift in slowly. s002's frame 2 and s005 push in by their own move; s010's photograph **pulls out**.
- [ ] **Subtitles:** in s006 frame 1 covers the exchange up to "You are. Tonight you are.", so those four lines share that frame by word count; Ellis's last line isn't covered and follows where it falls in the scene. In s003 Juno's whisper isn't covered by any frame either.
- [ ] s003's clip plays from 0.5 to 2.5 s (give it a longer duration and it holds its last frame). s008 plays its placeholder card.
- [ ] Press ▶ on a row to watch one scene; right-click a frame › Play From Here; use the range menu for scenes 4–6. Space, ←/→ and ⌥←/⌥→ in the player; ⌃⌘F for full screen.
- [ ] Turn overlays off and on (they're remembered). Click the frame name in the player to select it on the board.
- [ ] Add, replace and remove scratch audio on s008 (+ menu). Choose and remove a temp score in Storyboard Settings.
- [ ] Export › Animatic (.mov): it lands in `exports/` and opens in QuickTime with the overlays burned in. Export › Boards PDF at 2, 4 and 6 per page.
- [ ] Change a frame's duration while the player is open: it rebuilds and keeps its place.

## Milestone 11: Production
The script was locked (scene numbers and pages) and a Blue revision started; then a scene was added, one cut, and two lines changed. `script/production.json` holds the lock; `script/revisions/01 blue/` is the script as it was when the revision started.
- [ ] Script sidebar: the footer says "Scenes and pages locked · Blue Rev. 2026-11-23". Scenes are numbered 1–5, **4A**, 7–11 (6 was cut).
- [ ] **A-scene:** the ticket hut (s011, brought back from the boneyard note in act one) was added after scene 4, so it's **4A**. The storyboard, animatic and margin use the same numbers.
- [ ] **OMITTED:** the ferry deck (s099) was cut after locking; Page view shows `6  OMITTED` between scenes 5 and 7.
- [ ] **A-pages:** pages were locked; the new scene pushes page 2 onto **2A**, and pages 3 onward keep their numbers.
- [ ] **Revision marks:** the new scene, Ida's "The hard way." (scene 5) and Juno's "The bell goes…" (scene 10) have a `*` in the right margin; those pages say "Blue Rev. (11/23/26)" at the top. Unchanged pages don't.
- [ ] Production menu (Script toolbar, or Script › Production): Start Pink Revision, then change a line and see only that line marked. Clear Revisions puts the baselines in the Trash.
- [ ] Reports › Scene List as PDF and CSV (6 shows as OMITTED), Character Report, Location Report. All go to `exports/`.
- [ ] Sides…: pick 4A. The PDF has page 2 and 2A only, with scenes 3, 4 and 5 crossed out.
- [ ] Unlock Scene Numbers (it asks first): scenes renumber 1–11 and OMITTED goes away. Locking again locks the new numbers, so try this on a fresh Showcase copy.

## Milestone 12 onwards
Polish will be added here as it's built.
