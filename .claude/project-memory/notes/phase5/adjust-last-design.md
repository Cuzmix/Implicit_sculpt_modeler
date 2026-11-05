# Phase 5 item 3: Adjust last operation

Roadmap row: "Adjust last operation (remesh, decimate, retopo, smooth all, extract, mirror)", done when "Re-run from
swap snapshot" (P12, Z123). Blender's Adjust Last Operation: after an operation, its settings stay editable, and a
change re-runs it from the state before it instead of stacking a second operation on the first (a remesh of a remesh
loses detail; Decimate to 200k after Decimate to 500k is not Decimate to 200k).

## What exists
- Remesh, Decimate, Mirror and weld (`Symmetrize`) are Scene_Commands that record a swap entry
  (`history_snapshot` + `history_record_swap`, scene.odin:502-551). Retopo and Extract add an object
  (`history_record_added`). Smooth all is a direct command (`smooth_command`, history.odin:219) recording a `.Deform`
  stroke-like entry over every node.
- `scene_run` reports destructive commands with Undo (results.odin:124); `undo_mark` / `undo_mark_on_top` tell
  whether a step is still the newest.
- The action bar (kit_action_bar.odin) shows next steps over the dock, folds groups into popovers on narrow windows.

## Design
- `App.last_op: Last_Op {op: Adjust_Op, object: int (id the op ran on), cmd: Scene_Command (its parameters),
  steps: i32, mark: Undo_Mark}` with `Adjust_Op :: enum {None, Remesh, Decimate, Mirror, Retopo, Smooth_All,
  Extract}`. Set after the op made its undo step: in `scene_run` for the five scene commands (when `swap_since`), and
  in `smooth_command` when it changed something. Live while `undo_mark_on_top(done, mark)` and the object exists; any
  newer step, an undo, a new scene or an open ends it (checked, not tracked).
- Adjusting is a new Scene_Command kind `.Adjust_Last` carrying the new parameters in the existing fields
  (`vertices`: remesh/decimate vertices, retopo quads; `axis`/`on`: mirror; `level`: smooth steps). Smooth all's
  strength and Extract's thickness are the same `app.ui` values their sections use, edited in place by the panel.
  Applied at the frame start like any scene command: if `last_op` is no longer live, a warning note and nothing else.
  Otherwise: undo one step (the same path as Ctrl+Z, `history_step`), select `last_op.object` again (Retopo and
  Extract selected the new object), then run the op with the new parameters through `scene_run` (or
  `smooth_command`), which records a new step and a new `last_op`. The undone entry sits in `undone` until the new
  record drops redo, so after an adjust the History has one entry for the operation, never two.
- Interface: the action bar gains a group `.Adjust`, shown while `last_op` is live, captioned by the op ("Remesh",
  "Mirror", ...), with one button "Adjust..." that opens `kit_adjust_popover` above the bar (as a folded group does).
  The popover holds the op's own controls, laid out like its section's:
  - Remesh, Decimate: the vertex count select (SPHERE_PRESETS), current one chosen.
  - Mirror and weld: X/Y/Z tabs and Keep + side / - side tabs.
  - Retopologize: the quad count select the Retopology section uses.
  - Smooth all: Steps and Strength sliders.
  - Extract: Thickness slider.
  A select or a tab change posts `.Adjust_Last` at once; a slider posts it when let go (not every frame of the drag,
  since each re-run can take seconds at 10M). The popover stays open, so values can be tried one after another, and
  shows the last result line ("Remeshed Sphere 1: 1,002,113 vertices (312 ms)"). Escape, a press outside or a
  stroke close it. The palette gets "Adjust last operation" (opens it; enabled while live).
- Cost: an adjust is an undo (an object restore from its snapshot, about an Open of that object) plus the op. At 10M
  that is seconds, as the op itself is; the "Saving..." style busy toast (Report_Flag.Busy) shows first when the
  object is above 1M vertices, using the same one-frame deferral as saving (`save_pending`'s pattern, generalised as
  `busy_pending` if it fits, else its own copy).
- Exit stats: `last_op` already exists; add `adjust_op` (live op or none) and `adjusts` (re-runs).

## Tests
- app unit tests where a scene can be built headless: remesh at A then adjust to B gives the same vertices, bit for
  bit, as remesh from the original at B, and `len(history.done)` is the same as after one remesh; an adjust after a
  stroke (last_op not live) changes nothing and warns.
- touch_check: Remesh (Ctrl+R at a preset), the bar shows "Remesh / Adjust...", open it, pick another size: export
  equals a run that remeshed straight to that size; Mirror: adjust the axis; Smooth all: adjust the steps; a stroke
  after the op hides the group.
- README: Interface (action bar), the sections' text, palette.

## After the sm-architect review (go with changes)
- No new Scene_Command kind: the command keeps its own kind and gains `adjust: bool`. `scene_run` finishes the
  stroke, checks that the adjust is live and of that kind, `history_undo`es, reselects the source by id and runs on as
  usual. Smooth all is adjusted by a direct `smooth_adjust` (steps and strength are the Deformation section's own).
- A re-run that records no step (nothing changed, Decimate above the count) is `history_redo`ne and warned about.
- Live means: the op's step is on top, nothing undone, `history.serial` and `scene_edits` as at the op, the result
  object (the one the op left selected) still selected with the transform and boolean mode it had, no stroke and no
  timeline playback. The state is `App.adjust`; stats `adjust_op` and `adjusts` (`last_op` is taken).
- The bar's Adjust group has a caption proc (the op's name); "Adjust..." is the registry command `.Adjust_Last`,
  which also opens from the palette with an anchor above the dock when the bar is hidden.
- No busy-toast deferral in this item.
- Memory: during an adjust at 10M the undone post-op snapshot and the new before-snapshot both exist (about
  370 MB each), within SWAP_LIMIT_BYTES.
- Tests: Smooth all adjust unit tests (equal to a direct run, one entry, not live after a move, a stroke, an undo or
  leaving HD, no-change re-run redoes); remesh/decimate/mirror/retopo/extract end to end in touch_check, with a
  dynamic-topology and a lower-level case.
