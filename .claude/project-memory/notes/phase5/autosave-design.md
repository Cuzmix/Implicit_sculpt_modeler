# Autosave and crash recovery (UX roadmap phase 5, item 1): design

Base: odin-sculpt 80a38d1 (PR #75). Roadmap row: "Autosave snapshots on a worker, rotate N, crash recovery prompt. Done when a kill test loses ≤ 2 min and the stroke frame is unchanged at 10M (bench)". Evidence: N005 (Nomad has no background save, only a reminder), C059 (3DCoat's background save finishes 10–30 s after it says it is done; a reboot then destroys the scene), Z109 (ZBrush's QuickSave runs after a rest). Redesign 10 §75: "Restored from 1 minute ago (autosave). Open the last saved version instead?"

## What I measured first
A 10M-vertex sphere saved in a release build on this VM: **2.5 s to build the file in memory** (360 MB, almost all of it `append` into fresh pages: 120 MB of positions take 0.25 s, 240 MB of triangles take 1.7 s), then 2.1 s to write it. On a desktop the copy should be around 0.1–0.3 s, but that is still a visible freeze, and today it happens on the frame loop. So the autosave can neither copy the scene on the main thread nor write it there.

## What exists when done
- **Autosave, on by default every minute.** Settings > System > AUTOSAVE has a select: Off, Every minute, Every 2 minutes, Every 5 minutes or Every 10 minutes.
  - Under it, one line says what happened last, such as "Autosaved 40 s ago: 360 MB in 2.3 s", "Nothing changed since the last save" or "Autosave failed: <reason>".
  - A button there, "Open the last autosave", does the same as the command below.
- **When it runs.** An autosave runs when all of these hold:
  1. the scene changed since the last autosave, save or open (see the fingerprint below);
  2. the interval has passed since the last autosave;
  3. the app has been at rest for 1.5 s: no button, key, wheel, finger, pen contact, stroke, drag, waiting tap, replay, timeline playback, time-lapse or pending request. Hovering is rest.

  The roadmap's "kill test loses ≤ 2 min" holds with the 1-minute default: at worst, the work since the last autosave is lost, which is the interval plus however long the user went without a 1.5 s pause.
- **Nothing visible while it runs.** No toast and no frame drop. A failure shows one warning toast, "Autosave failed: <reason>. Your work is not being saved automatically", and the toast is not repeated until an autosave succeeds again.
- **Where the files go.** `<SDL pref path>/autosave/`. That is the app's own folder on every platform (sm-store: no permission needed). Each run is a *session* named by its start time and a random suffix, for example `20261026-143005-7f3a`.
  - `<session>-1.sculpt` … `<session>-3.sculpt`: the three newest autosaves, rotating. They are ordinary scene files (SCENE_VERSION 7, no format change), each written to `.partial` and then renamed, so a kill mid-write leaves the older ones intact.
  - `<session>.session`: a small text file with:
    - `sculpt-session 1`
    - `alive <unix time>`, refreshed every 30 s
    - `scene <path or empty>`, `saved <unix time>` (the last manual save), and `newest <slot> <unix time> <objects> <vertices>`
    - `closed <unix time>` once the run ends cleanly
- **Crash recovery prompt.** At start, the app looks for sessions that are not closed, are not alive (heartbeat older than 90 s, so a second running copy of the app is never taken for a crash), and have an autosave newer than their last manual save. For the newest such session, a card shows under the tool bar, where the first-run tips go. The tips wait while it shows. It reads:
  > **Recover your work?** Sculpt closed before your last changes were saved. The autosave from 3 minutes ago has 2 objects and 1.2M vertices (dragon.sculpt).
  > [Recover] [Not now] [Discard]
  - **Recover** opens that autosave as Open does. Ctrl+S then saves to the scene's own file again. The toast reads "Recovered your work from 3 minutes ago. Save to keep it", with no Undo, since Open has none either. The recovered file is moved into this session as its slot 1, so a second crash before the next autosave still finds it. The old session's other files go.
  - **Not now** closes the card and keeps the files, so the next start asks again.
  - **Discard** deletes that session's files.
  - **Escape** is Not now. On touch, the buttons are 48-point targets.
  - If several crashed sessions are waiting, the next one is asked about after the first is answered.
- **A clean exit** (closing the window, or the end of a scripted run) does the following:
  1. stops any autosave in progress, which takes under a few ms;
  2. hides the window;
  3. if the scene changed since the last autosave or save, writes one last autosave;
  4. marks the session `closed` and keeps only its newest autosave.

  This leaves "Open the last autosave" useful after a quit without saving. Closed sessions beyond the newest three, and any session older than 14 days, are pruned at start. Leftover `.partial` files are deleted at start.
- **Going to the background** (Android or iPad: `DID_ENTER_BACKGROUND`) starts an autosave at once if the scene changed, without the interval or the rest. SDL blocks the frame loop while the app is paused, so the worker carries on alone, and the OS may end the app there (sm-store: "Going to the background saves recoverable state").
- **New command** "Open the last autosave" (Files group, in the palette and Menu). It opens the newest autosave of any earlier session, crashed or closed, through the same Recover path. With none, it shows the toast "No autosave from an earlier session".

## How it stays off the stroke frame
1. **The start (frame loop, at rest).**
   - For each object not in HD, call `levels_sync`. That mutates, and its cost is the edits not yet synced, the same as a level change.
   - Write the scene header into the job (magic, version, the object count, the selected object, next_id and the camera), plus a copy of the object pointer list.
   - Post the job to the worker thread. That is all the main thread does.
2. **The worker** is one persistent thread (`core:thread`, `.Low` priority) waiting on a semaphore. It serializes each object with `object_put` (new `sculpt.Write_Options`; see below) into its own heap buffer. It uses no jobs pool: the pool belongs to the frame loop, and `nil` runs `parallel_ranges` serially. The worker reads the live meshes while the frame loop goes on drawing them; both only read.
3. **The guard (frame loop, every frame, two points):** at the top, before the frame's Scene_Command and file request, and after the events are read, before anything acts on them.
   - If the worker is still serializing and the frame is not at rest (by the predicate above, plus "a Scene_Command or file request is waiting"), the frame loop sets the worker's abort flag and waits for it to stop.
   - The serializer checks the flag between pieces of at most 4 MB of copying or one `RANGE_GRAIN` range of a loop. On a desktop that is about 1–3 ms, so the first frame of a stroke after a rest is at most a few ms late. That is measured as `autosave_wait_ms` (max).
   - The aborted job is dropped, and the next rest starts it again.
   - Nothing in the frame may change the scene before the guard, so the worker never reads data that is changing. The only things that change the scene without input are the ones the rest predicate lists, and a unit test pins that list.
4. **The write** comes once the buffer is complete. The worker writes it in 8 MB chunks to `.partial`, syncs it to the disk (`os.sync`), and renames it over the oldest slot. Then it rewrites the session file. By then the worker reads nothing of the scene, so strokes may run during the write. That is the case the bench checks: "stroke frame unchanged at 10M".
5. **The result** is published to the frame loop under the job's mutex: done or failed, bytes, serialize ms and write ms. The frame loop reports it, never the worker.

The buffer is about one scene file in size (360 MB at 10M), only while an autosave is being made, as a manual save needs today. It is freed after the write.

## The fingerprint (has the scene changed?)
`scene_fingerprint(app) -> u64` hashes:
- `History.serial`, which changes on every stroke, mask, hide, deform, rebuild, paint, layer, undo, redo, forget and clear;
- the object count, and per object: id, name, transform (position, rotation and scale), boolean mode, `levels.current`, the number of levels and the HD steps;
- `scene.selected`.

It costs microseconds for 50 objects. The camera is left out: a view change alone is not worth an autosave. The fingerprint is compared once per frame, only while an autosave is due. `autosave.clean` holds the value at the last autosave start, save, open or new scene. A unit test runs each scene change kind (each Scene_Command kind, a move, a rename, a level change, a mask command and undo) and checks that the fingerprint changes. The same value is what item 2's "unsaved changes" will use.

## Code
- **New `src/app/autosave.odin`** (about 450 lines):
  - `Autosave` state in App: settings, session, slot, the clean fingerprint, timings, and the worker (thread, sema, mutex, cond, job, abort and result).
  - `autosave_init`: the folder, pruning, the session file, and the list of crashed sessions to ask about.
  - `autosave_guard(app, top: bool)`, `autosave_frame(app)`, `autosave_quiet(app) -> bool` (pure, tested), `autosave_start`, `autosave_shutdown` (the exit steps above), `autosave_background`.
  - Session files: `session_write` and `session_read` (a damaged one is ignored, never asserted on), `autosave_recover(app, session)`, `autosave_discard`.
  - `scene_fingerprint`.
- **New `src/app/kit_recover.odin`** (about 80 lines): the card, and `kit_floating` counts it while it shows.
- **files.odin:**
  - `scene_header_put(app, out)`, shared by scene_save and the autosave.
  - `object_put(app, out, obj, opts := {})` gets an options variant that skips `object_hd_leave` and `free_all` for the worker.
  - scene_save, scene_open and scene_new set `autosave.clean` and the session's `scene` and `saved`.
- **sculpt/levels_file.odin:**
  - `levels_write(l, out, opts := Write_Options{}) -> bool` with `Write_Options{serial, abort: ^bool, synced, hd_open}`.
  - The big copies go through `put_checked` (4 MB pieces), and the loops through a `ranges` helper that runs serially and checks the flag when `serial` is set.
  - `level_canon` and `write_layers` take the pool from the options.
  - `hd_open` writes the levels as they are with a window open. Their HD detail is never stored, so that is the same file `object_hd_leave` would lead to, without leaving HD.
  - It returns false only on abort.
- **main.odin:**
  - Flags:
    - `--autosave=SECONDS` turns autosave on for a scripted run at that interval;
    - `--autosave-folder=PATH`;
    - `--autosave-rest=SECONDS` (default 1.5);
    - `--crash-after-autosave` calls `os.exit(3)` after the first autosave is written, skipping every clean-exit step: the automated kill test.
  - The guard's two calls, the exit steps, and `DID_ENTER_BACKGROUND`.
  - Exit stats: `autosaves`, `autosave_aborts`, `autosave_wait_ms` (max), `autosave_serialize_ms`, `autosave_write_ms`, `autosave_mb` and `recovered`.
- **Settings and commands:**
  - `autosave_minutes` row (0, 1, 2, 5 or 10);
  - Settings > System: the select, the status line and the button;
  - the command `.Open_Last_Autosave`.
- **Scripted runs never autosave or ask** unless `--autosave` or `--autosave-folder` is given, so tests and benches never write to the pref folder, as the first-run tips work.

## Tests
- **Unit (src/app):**
  - `autosave_quiet` over each busy state;
  - the fingerprint for every change kind, and unchanged by a camera move;
  - the session file round trip, and damaged lines ignored;
  - the choice of the session to ask about (alive, closed, older than its save, the newest of several);
  - pruning.
- **Unit (src/sculpt):** `levels_write` serial with no abort is byte-identical to the pooled one, for 1 level, 3 levels, a mask, paint, groups and layers, and dyntopo. With the abort flag set, it returns false and stops early.
- **Scenarios (touch_check, a desktop simulation; new `autosave_*` group):**
  - after a stroke and a rest, an autosave file exists and opens with the stroke in it (`--open` of it, then `mesh_check` against the dumped one);
  - a stroke during an autosave aborts it (`autosave_aborts=1`), and a later rest completes it;
  - kill test: a stroke, a rest, `--crash-after-autosave`, then a new run with the same folder shows the card; Recover brings the stroke back (vertex stats match) and Discard leaves no files;
  - Not now keeps the files, and the next run asks again;
  - a clean exit keeps one autosave and asks nothing next time;
  - the Settings select set to Off makes no files.
- **Real kill:** a run killed by its PID (`kill -9`) after an autosave, then recovered, as the scenario does.
- **Bench (release, A/B, ranges, as sm-perf asks):**
  - `--vertices=10000000 --bench-stroke=240 --no-vsync` with autosave off, against a run whose autosave write overlaps the stroke (`--autosave=1 --bench-after-autosave`: the stroke starts once the serialization is done). Compare brush_ms, the frame p50 and p99 and the frame max.
  - Also `autosave_wait_ms` when a stroke starts mid-serialization at 10M with 3 levels.

## Not in this step
- **Item 2 work:**
  - the "unsaved changes" mark and the quit prompt (they will use the fingerprint);
  - Save a copy;
  - the Versions list, which will list these autosaves too.
- **Incremental autosave** (only the objects that changed): the first version writes the whole scene each time.
- **Autosaving HD detail**, which no save stores yet.

## After the sm-architect review (what changed)
- **Write_Options gets one `pool` for every loop.** That includes `sculptor_compact_mesh` (a `pool` and a `normals := true` parameter; the file needs no normals, and the frame loop writes them). Every loop gets an abort check: the mask, colour and group scatters, `tri_canon` and the compact copy, all in 1 MB pieces. `autosave_wait_ms` is reported as measured; the "1–3 ms" figure is dropped.
- **Guards.** One unconditional settle sits inside the `scene_run` and `file_apply` branches, after the command or request is taken, so a dialog's request posted from SDL's thread cannot slip past. One predicate guard runs after the events.
- **The rest predicate** also checks:
  - the Space pie;
  - `bench_input` and `gpubench`;
  - a waiting tap (`dab_wait.active`);
  - `stroke.pending`.
- **The background autosave starts at the end of the frame,** after the waiting tap and the touch cancel ran.
- **The worker's context.** It gets the frame loop's allocator through `init_context`: the tracking allocator has its own mutex, so a debug build still catches a leak in it. It calls `free_all` on its own thread-local temp allocator after each object. AGENTS.md §5 says so: "the frame loop, the setup paths and the autosave thread, on its own temp allocator".
- **The fingerprint** uses a new `History.scene_serial`, which skips HD-level entries and forgets: they change no saved byte. A new `app.scene_edits` counter is bumped where saved state changes outside the History: the move tool, renames, layer renames and "Lay out UVs again". The status line says "Work inside an HD window is not autosaved" while one is open.
- **Debug check `--check-autosave`.** The worker hashes the positions, indices and node layout of every object it read, at the start and at the end of the serialization, and the run fails if they differ. The scenarios run with it.
- **Sessions.**
  - The session file is written through `.partial` and a rename.
  - The newest slot is found from the files' modification times.
  - If the newest slot will not open, the older ones are tried.
  - The heartbeat is checked again right before Recover or Discard.
  - Crashed sessions are never pruned without an answer; only closed ones are, beyond the newest three.
- **Mobile.** There is no exit autosave on Android or iPad: the background autosave already ran, and onDestroy must not wait. iPad background time and iCloud backup exclusion are noted in sm-store for the first iPad build (UNVERIFIED; no iPad build exists). Android already sets `allowBackup="false"`.
- **Determinism note.** Syncing at an autosave makes the lower levels depend on when the user rested, just as they already depend on when the user saved or changed level (sync is not linear). This is accepted and stated in sm-sculpt.
- **Cost rows.** Add `autosave_sync_ms` (the main thread's levels_sync at the start).
- **Disk wear.** Constant sculpting at 10M writes about 21 GB an hour; the README states it next to the interval setting.
