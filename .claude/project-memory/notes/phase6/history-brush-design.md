# Phase 6 item 6: History brush and Adjust last stroke

Roadmap row: "History brush (local undo), adjust last stroke" (Z140 ZBrush HistoryRecall brush, Z123 ZBrush Adjust
Last; findings 78 and 28/29). Today: Undo/Redo per step (`src/sculpt/undo.odin`: a step saves the *before* positions,
masks, colours, layer deltas of the nodes it touched, and undo swaps them), the cross-object `History` with the
timeline (PR #35), the Morph brush toward a stored morph target (`morph.odin`), and Adjust last operation for
rebuilds (`adjust_last.odin`, Blender's pattern: re-run from before).

## What the user gets
1. **History brush** (ZBrush HistoryRecall): a new brush, "History", that paints the surface back toward how it was
   at a chosen point in the History, only where it is brushed: a local undo. It works like Morph (same rate, falloff,
   alpha, mask, symmetry, Front faces only, Connected), its target being the state at the recall point instead of a
   stored morph target.
   - The recall point: by default the oldest state of the selected object (its level) that the History still holds
     with the same topology, so a fresh session's History brush paints back toward what was opened. In the History
     panel, a long press or right-click on an entry offers **Recall to before this**; the entry then shows a small
     marker, as ZBrush's history marker. The Brush tab's section for the History brush says what it recalls ("Before:
     Clay stroke, 12 steps back") with **Use the oldest** (the default) and a stepper (one step earlier/later).
   - Strokes of the History brush are ordinary steps: undoable, recorded by the stroke recorder, timeline entries.
   - Refused, with a note, when there is nothing to recall (no earlier step) or the object changed topology since the
     point (remesh, dynamic topology, a level added or removed: the recall point drops with a note "History brush:
     the recall point was before a rebuild"). With dynamic topology on the brush is refused (vertices renumber), as Morph.
2. **Adjust last stroke** (ZBrush Adjust Last): after a sculpt, mask or paint stroke, the action bar's Adjust popover
   (the one Adjust last operation already shows over the dock) offers **Stroke amount**: 0 to 150%, 100% being the
   stroke as drawn. Dragging it sets every vertex the stroke changed to `before + k·(after − before)` (positions, a
   recording layer's delta, mask and colour values, the last two clamped), live, from the step's own saved *before* and
   an *after* kept at the first adjust. The step stays one step, so Undo takes the adjusted stroke back. Offered while
   the stroke is the newest step on the object and nothing has changed since (the `Adjustable.serial` and
   `edits` checks adjust_live already does); not for dynamic topology strokes (their steps save whole nodes and change
   triangles), Grab and Cloth are fine (they save positions too). Palette: "Adjust last stroke"; key: none by default.

## Data and code
- Sculpt (`src/sculpt/recall.odin`, new):
  - `sculptor_recall_build(s, steps_back: int) -> bool`: copies the positions into `s.recall` (history allocator,
    12 bytes a vertex, made on first use like `morph`) and writes each of the newest `steps_back` done steps' saved
    positions over it, newest first, so the oldest one's *before* wins. Refused (false, `s.recall` untouched) if a step
    in range is `full` (dyntopo), changes a layer (`layer_op`), or the vertex count differs. Layer deltas: the target
    is the shown positions (base + layers) at the point, which the before positions already are.
  - `Brush_Kind.History` (appended, so files keep their numbers), `job_history` = `displace` with the Morph path
    reading `s.recall`; `sculptor_recall_clear`; dropped with the sculptor and on dyntopo enable (as morph).
  - `sculptor_stroke_adjust(s, k: f32) -> bool`: on the newest done step (not `full`), keeps an `after` copy beside
    each `Saved_Node` the first time (positions, delta, masks, colours: the node's current values, history allocator,
    counted in `bytes`), then writes `before + k·(after − before)` for each saved node in parallel (`jobs.parallel_for`
    over the step's saved nodes), marks normals, bounds (refit) and paint stale as undo does. Deterministic: per node,
    no order dependence. Undo of an adjusted step swaps as now (it saves what is current). `after` is freed with the
    step.
- App:
  - `BRUSHES[.History]`: name "History", an icon (history clock), flags like Morph; key none (dock and browser).
  - Recall point per object and level: `Object.recall: Recall_Point{mark: Undo_Mark, steps: int, serial: u64}` kept
    by id; resolved to a step count back at stroke start (`history` entries of that object and level after the mark);
    the target rebuilt only when the point or the topology changed (`serial` check), never mid-stroke. Cost of a build:
    one copy of the positions plus the saved bytes in range (10M: about 40 ms once, shown as a Busy note "History
    brush: reading the History..." the first time).
  - History panel: entry long-press/right-click menu "Recall to before this" (`.Recall_Point` command with the entry's
    index), a marker on the entry; `scene_replace` and swap entries drop the point.
  - Adjust popover: `Adjust_Op.Stroke` with `amount` 0–1.5; `adjust_set` after `brush_stroke_finish` for a stroke
    with a step; adjusting runs `sculptor_stroke_adjust` directly (no re-run; it is cheap: one pass over the stroke's
    saved nodes); the History entry's label gains " (80%)".
  - Settings: none new (the recall point is not remembered). `.strokes` files: the History brush's kind is just a
    kind; a replay recalls toward the replaying object's own recall point.
  - README (History brush, Adjust last stroke), help glossary ("History brush": HistoryRecall (ZBrush), "Adjust last
    stroke": Adjust Last (ZBrush)), palette words ("local undo", "historyrecall", "adjust last").

## Tests
- Sculpt: recall_build after three strokes gives the positions before the first (bit-identical to a copy taken
  then); refused across a dyntopo step; History dabs move vertices toward the target (distance to it shrinks, never
  grows) and leave vertices outside the brush; serial = parallel.
- Sculpt: stroke_adjust(0) gives the before positions exactly, (1) the after exactly, (0.5) the midpoint; adjust then
  undo then redo round-trips; mask and paint steps clamp; a delta (layer) step adjusts the layer's delta with it.
- App: the default recall point is the oldest step; "Recall to before this" on an entry anchors there; a remesh drops it;
  the Adjust popover appears after a stroke and goes after another stroke or an undo; the timeline label shows the %.
- Scenarios: History brush stroke by pen after two Draw strokes reduces `mesh_sum` change toward the start
  (`undo_steps` 3); Adjust last stroke at 0% by mouse leaves `mesh_sum` as before the stroke.

## Split
- 6a: Adjust last stroke (sculpt `sculptor_stroke_adjust`, Adjust popover, tests).
- 6b: History brush with the default recall point (oldest) and the Brush tab section.
- 6c: History panel "Recall to before this" and marker.

## Open questions (defaults taken)
- Adjust range 0–150% (ZBrush caps at 100%; above it extrapolates, useful for "a bit more"). Default: 0–150%.
- Recall point default: oldest held step (ZBrush: the marker you set; with none, the first). Default: oldest.

## Architect review outcome (2026-10-26) — adopted
Required changes taken: (1) a recall build never reaches past a newer entry of the same object on another level or a
swap (levels sync only on level change); a built target stays valid. (2) Count only entries with a sculptor step (not
Transform, Arrange, swap); a count past `len(done)` means the point was dropped: fall back to the oldest with a note.
(3) Key the target by object, level and a concrete `Undo_Mark` (the oldest made concrete on first use), never by
`history.serial`. (4) Layer steps are not refused: positions always hold the shown sum; the build reads saved nodes with
`positions != nil && !full && !is_delta`. (5) `sculptor_stroke_adjust` writes then calls `sculptor_nodes_moved(s,
step.nodes)`; AGENTS.md §5 and sm-sculpt name it. (6) `after` copies allocated serially in one block (as record_hit),
copied in parallel; counted in step_bytes/reset/destroy; the limit trim shared and run after an adjust. (7) Each adjust
bumps `history.serial` (and `edits` outside HD) and refreshes `adjustable.serial/edits`. (8) Adjust requires the
object's current level (or HD window) to match the entry's. (9) A percent field on History_Entry, formatted in
entry_label.
Suggestions taken: a new icon (Morph has the history one); "Recall to before this" on a right-click or unmoved long
press of a timeline block; `after` freed in step_move; `.History` in the area-skip list with a length guard; serial
newest-to-oldest with parallel nodes per step; `s.recall` in memory stats. Refuse with dyntopo on, and refuse adjust
for steps with hidden, groups, layer_op or layer_set.
Split: 6a1 sculpt `sculptor_stroke_adjust` + tests; 6a2 app Adjust popover; 6b History brush (+ fixes 1-4); 6c timeline
recall point and marker.
