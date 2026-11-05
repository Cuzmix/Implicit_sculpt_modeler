# Phase 5 item 2: Save that finishes before saying so, Save a copy, Versions

Roadmap row: "Save that finishes before saying so; Save a copy; Versions list" (C059: 3DCoat says "saved" while the
write still runs and a reboot loses the scene; Z109: ZBrush users are told to save incrementally and keep 3+ versions;
N022: a second Save silently overwrites).

## What exists
- `scene_save` (src/app/files.odin) serializes on the frame loop, then `write_file_safely`: `os.write_entire_file` to
  `path.partial`, `os.rename` over `path`. No fsync, so "Saved" can show before the bytes are on the disk; a power cut
  after the rename can leave an empty or short file where the old good one was.
- The frame blocks for the whole save (4.6 s at 10M on the VM) with nothing on the screen saying so: the toast comes after.
- Ctrl+S saves over `app.scene_path` without a dialog; Save as asks for a path. No copy, no versions.

## 1. Saving finishes before it says so
- `write_file_safely` writes with `os.open` + chunked writes (share `write_chunked` from autosave.odin, moved to
  files.odin as `write_durably(path, data) -> string`), `os.sync(f)` before close and rename, and after the rename
  syncs the folder on POSIX (open the folder read-only, `os.sync`, close; skipped on Windows where `MoveFileEx` with
  write-through is what the OS offers and a folder handle cannot be synced the same way). Export, screenshots and
  .strokes keep using it, so they become durable too.
- The note "Saved ..." is only posted after that returns, and says how long the flush took when it was over 100 ms.
- A save that will block more than a frame shows first: `file_apply` for `.Save`/`.Save_Copy` on a scene above
  1M vertices does not save at once; it sets `app.saving = req` and returns, the interface draws one frame with a
  busy toast "Saving head.sculpt..." (no Undo), and the save runs at the start of the next frame. Input that arrives
  in that frame is ignored for sculpting (the toast frame is not interactive: `autosave_quiet`-style check, a stroke
  cannot start while `app.saving` is set). Below 1M the save is under ~300 ms and runs at once.
- Saving does not go to the autosave thread: a user save cannot be aborted by a stroke, and holding every scene
  change while a thread reads is a larger design (noted as the path if 30M+ saves need to stay interactive).

## 2. Save a copy
- Command `.Save_Scene_Copy` "Save a copy...", after Save as in Menu > FILE and the palette (words: copy, duplicate,
  backup, export scene). File_Kind `.Save_Copy`: the save dialog, then `scene_save(app, path, copy = true)` which
  writes the same bytes but does not change `scene_path`, does not call `autosave_scene_saved` (the scene is no
  more saved than before) and does not make a version of anything. Note: "Saved a copy as x.sculpt ...; this scene
  still saves to head.sculpt" (or "...is still unsaved").

## 3. Versions of a saved file
- Saving over an existing file (Ctrl+S or Save as onto it; not Save a copy) keeps the file it replaces: before the
  rename, `os.link(path, version)` (a hard link: no copy, no time) where `version` is
  `<dir>/<stem> versions/<stem> YYYY-MM-DD HH.MM.SS.sculpt` (local time; seconds and then `-2`, `-3` when two saves
  share a second). Then `rename(partial, path)` replaces `path` atomically, so at every moment `path` is a whole file
  and the old one survives as the version. Where linking fails (FAT/exFAT cards, some network drives, Android
  content later), fall back to `os.copy_file`; if that fails too, the save still goes ahead and the note says the
  earlier version could not be kept and why (warning colour).
- How many to keep: Settings > System > Saving, "Keep earlier saves": Off, 3, 5 (default), 10; remembered as
  `versions_kept`. After a save, the folder's versions of that stem beyond the count are deleted oldest first
  (only files matching `<stem> ####-##-## ##.##.##*.sculpt`, never anything else in the folder). Off keeps none and
  deletes nothing already there. Disk cost is shown in the System tab line: "Earlier saves of head.sculpt: 5, 1.7 GB".
- Versions list: Menu > FILE > "Versions..." (command `.Scene_Versions`, enabled when the scene has a path and its
  folder has at least one version). Closes the menu and opens a popover in the same place (`kit_versions`,
  kit_menu.odin's neighbour; no state kept between frames except `k.versions: bool` and the armed row like New
  scene's). Rows newest first: "Today 14:02", "Yesterday 18:40", "12 Oct 09:15", each with its size; the file's
  current save on top, not tappable, as "Saved now / 14:05". Listing is read when the popover opens and kept in a
  heap list freed when it closes (the folder is not read every frame).
- Tapping a row opens that version as the scene (`File_Kind.Open_Version`): `scene_open(version)` then
  `scene_remember_path(app, main_path)` so the next Ctrl+S saves it back as head.sculpt and keeps the replaced one
  as a version (restore, not a fork; nothing is lost). With work to lose (`scene_has_work`), the first tap arms the
  row ("Discard changes?", red, as New scene does) and the second within the arm time opens it. Note: "Opened the
  head.sculpt saved at 14:02; Save makes it the current one, keeping the other as a version".
- Escape closes the popover; a finger tap outside closes it (popover default).

## Tests
- app unit tests: version name from a time and collisions; `versions_found` lists only matching names and sorts by
  time; prune keeps N newest and leaves other files; save over a file twice in a temp folder makes 1 then 2
  versions with the old bytes; Save a copy leaves `scene_path` and the fingerprint's clean value alone.
- touch_check (desktop simulation): `--open=PATH` then Ctrl+S twice with strokes between (Ctrl+S needs no dialog)
  → 2 versions on disk; open Versions from the menu, tap the older row twice (armed then open) → the exported mesh
  equals the first save's; versions_kept=Off writes none.
- Kill test: SIGKILL during the save of a 5M scene at random points, then the file at `path` is always a whole
  scene (the old or the new) and the version folder holds whole files only.

## Flags and docs
- `--versions-kept=N` for runs (scripted runs read no settings). README Files section, Settings > System, flags;
  sm-store note: on Android/iPad the versions folder must sit inside the app's or the picked document's tree (later).
- No `.sculpt` format change; SCENE_VERSION stays 7.

## After the sm-architect review (go with changes)
Shipped in three steps: (1) durable write and the one-frame "Saving..." deferral; (2) Save a copy and versions on
disk with the setting; (3) the Versions popover. Changes taken:
- The deferred save runs first in the next frame, before the scene command branch, after `autosave_settle`;
  `autosave_quiet` is false while `app.saving` is set; a pending save runs before `autosave_close` at exit; a second
  Save while one is pending is dropped; no input rule for the toast frame (whatever it does is saved).
- The threshold is the sum of `object_put_estimate`, not shown vertices.
- Windows renames with `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)`; POSIX syncs the folder after the rename,
  and the versions folder (and its parent when first made) after linking.
- Copy fallback writes `version.partial`, syncs and renames; a missing `path` is no warning.
- Screenshots keep writing in place (not covered; README says so only for scenes, meshes and strokes).
- The version list lives in App, refreshed after save, open and prune; the kit keeps only the open flag and armed row.
- Opening a version names the main path in the session and leaves the scene not clean; "work to lose" uses a saved
  fingerprint kept whether or not autosave is on.
- Version names take the replaced file's modification time; the list sorts by that time.
- Crash safety is tested by unit tests with a failure at each step of link, rename, prune instead of a kill test.
