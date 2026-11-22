# Changes

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
