# Round 3, PR 12: long jobs off the frame thread, with a progress ring (design, 30 Oct)

The overhaul's list asked for "progress rings on long jobs, then a fade to the new mesh".
The architect's review (design.md §6) found that no operation reports progress: Remesh,
Decimate, Retopo, Subdivide and the conversions run on the frame thread inside
`scene_apply`, so the app freezes for their whole run (seconds at 2M+ vertices) and nothing
can draw a ring. This PR moves them to a thread of their own, keeps the frame alive (the
camera, panels and motion all work), shows how far along they are, and lets them be
cancelled. The fade to the new mesh needs the kept picture PR 13 builds for the pass
cross-fade, so it lands there, one mechanism for both.

Best of the apps: ZBrush and Nomad freeze on DynaMesh/remesh; Blender shows a progress bar
in the status bar with Escape to cancel for its long operators (bake, remesh via modifiers
on apply, quadriflow) and keeps drawing; 3D-Coat shows a modal progress with Cancel. We take
Blender's: keep drawing, a ring with the percentage, Escape or a tap on Cancel.

## What exists after this PR
- Remesh, Decimate and Retopo (12a), then Subdivide, Voxel_To_Mesh, Mesh_To_Voxels and
  Voxel_Resample (12b), run on a job thread when the run is interactive and the object is
  big enough to take a noticeable time (`LONG_JOB_MIN_VERTICES`, 200k source vertices).
- While one runs, a pill under the top bar shows a ring filling with the job's progress,
  what runs ("Remeshing Sphere 1"), the percentage and a Cancel button; the button or tile
  that started it (the Remesh rail button and its hold menu, the Object palette's buttons)
  draws the same ring round its icon.
- The scene is frozen while it runs: strokes, scene commands, mask commands, undo and redo,
  gizmo and inspector edits and file actions are refused with one note ("Wait for the
  remesh, or cancel it (Esc)"), their controls dimmed with that reason (offers.odin's
  `command_reason` path). The camera, view settings, panels, Settings and Search work.
- Escape (or Cancel) stops it at its next check: the object stays exactly as it was (out of
  HD if it was in it, as today's first step leaves it), no undo step, a note "Remesh
  cancelled".
- When it finishes, the next frame's start applies it exactly as today's code does after
  the computation (object_rebuild, the swap undo entry, history_record_added for Retopo),
  so undo, the scene file and the History see no difference.

## Design
### jobs: `Progress`
`src/jobs/progress.odin`: `Progress :: struct {done: u32 (atomic, parts of PROGRESS_SCALE
= 1<<16), cancel: bool (atomic)}` with `progress_set(p, stage_from, stage_to, k)`,
`progress_get(p) -> f32`, `progress_cancel(p)`, `progress_cancelled(p) -> bool`; every proc
takes nil and does nothing. No rendering or UI: the jobs package stays pure.

### geom/sculpt/voxel: an optional `progress: ^jobs.Progress = nil`
The long procs take it as their last parameter (default nil, so every caller and test stays
as it is): `remesh_voxel(_measured)`, `mesh_decimate`, `mesh_retopo` (+ `bvh_build_morton`
is quick, not checked), and in 12b `levels_subdivide`, `voxel` conversion and resample. Each
reports at its stage boundaries with a fixed share per stage (measured once at 2M and
written as constants, so the ring moves evenly) and inside its longest loop every
chunk/batch, and returns `ok = false` at the next check after cancel, freeing what it made
(the tracking allocator proves it). A check is one atomic load: no measurable cost (bench
rows before/after in the PR). Results with or without a Progress are bit-identical
(determinism tests compare).

### app: `long_job.odin`
- `Long_Job {on, kind: Scene_Command_Kind, cmd: Scene_Command, id: int (object), name:
  string, thread, pool: jobs.Pool (its own workers: cores - 2, at least 1), progress:
  jobs.Progress, input: geom.Mesh (owned only when compacted from a dynamic layout or
  shaped for retopo), area, bounds, before: ^Object_Snapshot, result: geom.Mesh, extra
  (decimate error, retopo quads), ok, built, done (atomic), started: time.Tick, stats}` in
  App.
- `scene_apply` for an async-capable kind calls `long_job_start(app, cmd, obj)` when
  `long_job_async(app, obj)`: interactive run (or `--async-jobs`), no script, macro, replay,
  time-lapse or turntable running, no job on, and the object at least
  `LONG_JOB_MIN_VERTICES` (or `--async-jobs`). Otherwise it runs inline exactly as today
  (scripted runs, small objects), so parity and every existing test keep their path.
- The start does on the frame thread what today's procs do before computing: stroke_finish,
  the snapshot (`history_snapshot`, as scene_apply takes it today), object_hd_leave, the
  area and bounds, the compacted copy for a dynamic object (`object_shape` for retopo). The
  job thread then runs only the pure geom call on its own pool, with its own temp arena freed
  at the end (rule: only the frame loop, setup paths and own threads free temp).
- Each object proc is split in two at the line where it stops computing and starts
  rebuilding: `object_remesh` becomes `remesh_compute(input) -> (mesh, built)` plus
  `remesh_apply(app, obj, mesh)`; the inline path calls both, the job calls compute on its
  thread and apply from `long_job_frame`. One body, two callers, no copy of the logic.
- `long_job_frame(app)` runs at the frame's start beside the scene commands: when `done`,
  join the thread, destroy the pool, then apply (built: rebuild + record swap/added, as
  today; not built: drop the snapshot and report as today; cancelled: drop the snapshot and
  free the result). A GPU failure on apply deletes the object as today's path does.
- The freeze: `long_job_busy(app)` joins `history_busy` (undo/redo), the stroke start
  (`stroke_begin` refuses), `scene_command` queueing (every kind refused with the note in 12a, even
  those that touch no mesh, so nothing can reorder or delete the object under the job),
  `mask_command`, `file_take` (saves and opens wait), `move`/`transform` drag
  starts, the cage tool, and the autosave's take (it skips while a job runs). `command_
  enabled` returns false with the reason for every command whose flags say it edits the
  scene (commands.odin `.Edits` flag, added where missing).
- Escape: `new_ui.odin`'s Escape chain cancels a running job first. Quit (closing the
  window) cancels and joins before `scene_destroy`.
- Adjust last (adjust_last.odin) stays inline in 12a: its popover re-runs on each change
  and must land before the next; when a job of the same kind runs, the adjust waits (its
  control dims). 12c may make it cancel-and-restart.

### Interface
- `kit_job_pill(app)` in the overlay layer: centred under the top bar, a 36-point pill:
  ring (the hold ring's drawing, accent on track), label, "42%", a Cancel icon button; it
  rises in with the Toasts motion class and fades out on finish. The ring itself is not
  motion (it shows a quantity), so it draws under motion Off too.
- `job_ring(app, id, rect)`: icon buttons whose command is the job's draw the ring round
  their icon (the kit's `command_tile` / `icon_button` callers for Remesh, Decimate,
  Retopologize; one helper call each).
- Stats: `long_job_running= long_jobs= long_job_cancels= long_job_ms= long_job_progress=`.

### Verification
- Unit: Progress API; `remesh_voxel` and `mesh_decimate` with a Progress are bit-identical
  to without; cancel returns not-built with no leak; long_job start/apply on a test object
  equals the inline result (same vertex count and positions).
- Touch (desktop simulation, `--async-jobs`): remesh from Search shows the pill
  (`long_job_running=1` a few frames on) and lands (`undo_steps=1`, vertex count changed);
  Escape mid-job cancels (`long_job_cancels=1`, `undo_steps=0`, count unchanged); a drag on
  the model mid-job lays nothing (`dabs=0`); Ctrl+Z mid-job does nothing.
- Bench: release `remesh_ms`/`decimate_ms` at 1M and 5M with and without the job thread, so
  the own pool's cost is known.
- Parity 19/19 (scripted runs stay inline).
- sm-store: no new permission; a thread per job is fine on iOS and Android; the app's
  lifecycle pause (backgrounded) leaves the job running and applies it on return.

## Architect review (30 Oct): approved with changes. This section wins.
- No command flags exist: freeze with an allowlist `JOB_ALLOWED_COMMANDS` (camera, view,
  panels, settings) checked in `command_enabled` and `command_reason`, like
  VOXEL_REFUSED_COMMANDS, so a new command is refused by default.
- Freeze points: `command_enabled` (allowlist), the whole viewport tool dispatch (not only
  `stroke_start`: lines, curves, lassos, group clicks), `history_busy` (covers undo, redo,
  history cap, timeline and History scrubs, the Blender link's get), `script_can_start`
  (scripts, plugins, replays), the scene-command post and `file_take`.
- The job always gets a private copy of positions and indices (dynamic or not): ~20 ms at
  2M, and a missed gate then costs an edit, never a torn read.
- Apply runs `scene_run`'s tail (report line, layers and sets notes, undo mark,
  `adjust_set`) keyed by the job's object, not the selection; `scene_run` is split into a
  start and a finish for that. Stats are set after the rebuild (object_build_from clears
  app.stats). Call `autosave_settle` in apply.
- Inline always: `cmd.adjust` (it undoes first), macro recording (macro_settle compares
  before and after).
- Escape cancels last in the chain, when nothing floating took it.
- Retopo's `quad_uv_unwrap` and triangulation go in the compute half.
- Progress is set only from the thread that called the proc (stage boundaries, and the
  serial `simplify` loop in decimate), so it never jumps back.
- Cancel checks `progress_cancelled` before the not-built note. Leaving HD at start drops
  the HD strokes, as today's not-built path does; the note says the object is as it was
  apart from that.
- Join the job on every exit path of the frame loop (a defer after scene setup).
- 12b Subdivide needs a compute-then-commit split inside sculpt (levels_subdivide runs in
  place); it is not a swap undo.

## As built (30 Oct)
- 12a #346: Remesh, Decimate, Retopo; long_job.odin, jobs.Progress, JOB_ALLOWED_COMMANDS freeze, pill + button ring, Esc cancel, --async-jobs.
- 12b #347: Subdivide (sculpt.levels_subdivide_build beside the levels + levels_subdivide_add), Convert to voxels (voxels_compute/apply), Res+/Res- (voxel.clay_resampled beside the old clay), Convert to mesh (clay flushed at start, clay_to_mesh flush=false on the thread, regrow forced). New meshes (Remesh, Decimate, Convert to mesh) get levels_init + normals on the job thread (long_job_prepare), object_build_from(prepared) only uploads. Autosave waits while a job runs. Stage shares measured in a release build (4M remesh, 2.5M subdivide, 2M to voxels, 512<->1024 resample).
- Left: Adjust last still inline (no cancel-and-restart); the fade to the new mesh goes with PR 13's kept picture.
