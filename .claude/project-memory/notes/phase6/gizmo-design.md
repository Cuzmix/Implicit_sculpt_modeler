# Phase 6 item 1: Full gizmo (rotate, scale, pivot by surface tap, snapping, numeric entry)

Roadmap row: "Full gizmo: rotate, scale, pivot by surface tap, snapping, numeric entry" (A-10, Z066, N004), done when
"Blockout flow W2 without typed values". W2's friction for us today: "No rotate/scale gizmo, no pivot placement, no
snapping, no parenting" (parenting is the scene tree item, not this one).

## What exists
- `src/gizmo` is pure math: `project`, `pick` (arms and a centre square, `PICK_PX` 8, `CENTER_PX` 9), `closest_on_axis`
  and `ray_plane`.
- `move_tool.odin` holds `Move_Tool{hover, drag}`. A press on an arm moves along it, and a press on the centre or on an
  object moves in the view plane. It writes `obj.transform.position` directly every frame.
- `Transform{position, scale (uniform), rotation (degrees about x, then y, then z)}`. `Draw_Item.model` must stay a
  similarity, so there is no non-uniform scale.
- The inspector's Transform section edits the values with `drag_value`.
- **No transform change is undoable.** History has no kind for it, and a swap snapshot only carries the transform
  along.

## Design (two PRs)

### PR 1: rotate, scale, plane handles, snapping, undo
- **Modes.** `Gizmo_Mode {Move, Turn, Scale}` in `App.move`, picked from a new action bar group, Gizmo, shown with
  the Move tool and an object selected: chips Move, Turn, Scale, then Snap (a latch), then Reset pivot (PR 2). W
  while already in the Move tool cycles the mode, as tapping W in ZBrush toggles its gizmo. The mode is remembered
  (`gizmo_mode`).
- **Handles** (gizmo package, pure; new procs and tests):
  - Move: the three arms; three plane squares between pairs of arms (XY, YZ, XZ), which move in that plane; the
    centre (view plane).
  - Turn: three rings (circles of the arm length in each axis plane, drawn as polylines with the back half dimmed),
    picked by distance to the projected ellipse, plus an outer view ring that turns about the view axis. The angle is
    the signed angle between the start and current vectors from the centre to the ray's hit on the ring plane (falling
    back to the screen-space angle when the plane is edge-on). Rotation composes as world-axis delta R:
    `R_new = R_delta * R_start`, decomposed back to the x-then-y-then-z degrees `Transform` stores
    (`transform_rotation` has the forward direction; add an exact inverse with a gimbal case, tested round-trip).
  - Scale: the centre disc. Dragging away from or toward the centre on screen scales uniformly:
    `factor = current_distance / start_distance` from the centre, clamped to 0.01..100 per drag.
  - Picking is by pointer kind: `PICK_PX` for the mouse; half the theme target (about 22 pt) for a finger or the pen,
    so handles are touch-sized; the centre's radius grows likewise.
- **Pivot.** The gizmo sits at `App.move.pivot` (world), which defaults to the object's position. Turn and scale go
  about it: `position = pivot + R_delta * (start_position - pivot)` (times the factor for scale). PR 1 only ever has
  pivot == position; the field exists so that PR 2 needs no change to the math.
- **Snapping** (Snap latch, or Ctrl held during the drag, as in Blender):
  - Move: to whole steps of a grid that follows the zoom, `10^floor(log10(world_per_px * ARM_PX / 2))`, along each
    moved axis, measured from the start (so it is relative, as in ZBrush and Nomad).
  - Turn: 15° steps.
  - Scale: factors in steps of 0.1.
  - The step shows in the drag readout.
- **Readout.** While dragging, a small label by the pointer shows the change: "X +0.250", "Turn Z 45°" or
  "Scale ×1.30", plus "(snap)".
- **Undo.** A new `History_Kind.Transform`. A History_Entry gains `before, after: Transform` (only for this kind).
  - Gizmo drags record one entry on release when the transform changed.
  - Inspector value drags record one entry each time the drag is let go, through a `transform_begin` /
    `transform_end` pair, the way `layer_dragging` makes one undo step.
  - Undo sets `before`, and redo sets `after`. Undo of a transform does not touch the object's strokes, since
    strokes are in the mesh's own space.
  - `edits` counts it, so autosave sees moves.
  - The History panel colours this kind.
  - The adjust-last rule "same transform" already ends an adjust when the object moves.
- **Commands:** Gizmo Move, Gizmo Turn, Gizmo Scale, Gizmo Snap, and Reset transform (position 0, rotation 0,
  scale 1, as one undo step).
- **Stats:** `gizmo_mode`, `gizmo_hover`, `gizmo_drag`, `gizmo_snap`, `transform=x,y,z,rx,ry,rz,s`,
  `transform_undo` (entries of this kind).

### PR 2: pivot by surface tap, numeric entry
- **Pivot by surface tap.**
  - With the Move tool, Alt+click on a surface, or a tap on any surface while the Pivot chip is latched, puts the
    pivot at the hit point (Z066). The gizmo moves there; turns and scales go about it.
  - Reset pivot puts it back on the object's origin.
  - The pivot is per selection, cleared when the selected object changes. It is not saved in scene files, so the
    scene version does not change.
  - Moving the object carries the pivot with it.
- **Numeric entry.**
  - A tap (press and release within the slop, no drag) on a handle opens a small popover at the handle, holding the
    value for that handle in a text field: position along the axis for an arm, the turn in degrees for a ring, the
    factor for scale.
  - It shows the current value, and Enter applies it as one undo step (relative values such as "+0.5" are allowed).
  - Escape or a tap outside closes it.
  - On a tablet the field takes the on-screen keyboard (`text_field` already does).

## Tests
- gizmo package: ring pick, the angle on a ring including the edge-on fallback, the scale factor, plane-square
  pick, snapping steps, and the Euler inverse round-trip over a grid of angles including ±90° pitch.
- app:
  - A transform entry undoes and redoes the exact Transform.
  - Interleaving it with strokes and swaps keeps both right.
  - Inspector drags make one entry per drag.
  - W cycles the mode.
  - Snap gives multiples.
- Touch scenarios (desktop simulation):
  - Drag a ring with the mouse and with a finger: rotation changes about that axis only, then undo restores it.
  - Scale by finger.
  - A plane square moves in two axes.
  - Ctrl snaps the move to the grid step.
  - The action bar chips switch the mode.
  - Numeric entry and surface pivot in PR 2.
- PNG: the Turn gizmo and the Scale gizmo on a sphere, mouse and finger sizes.

## Not in this item
- Multi-object transform (scene tree item).
- Non-uniform scale: it would need the renderer's similarity rule lifted, and the mesh baking a scale instead.
- Gizmo orientation to the surface normal (the pivot moves; axes stay world axes).

## Review (sm-architect): approve with changes. All required changes taken into the build
1. history_step gets a `.Transform` branch before entry_sculptor: undo sets `before`, redo sets `after`; a missing object is
   skipped; it clears the move drag, never calls object_set_level, and counts `edits` itself.
2. `history_record_transform` in history.odin, with level 0 (not HD_LEVEL). history_drop_redo leaves transform entries alone.
3. history_forget_strokes and history_forget_level(HD) keep transform entries; only the all-levels forget drops them.
4. No undo or redo while a gizmo or inspector transform drag is open.
5. drag_decide tests the gizmo pick with the pointer's radius right after the palm check, so handles off the silhouette
   can be grabbed by every pointer.
6. A second finger, or a cancel, restores the start transform without recording.
7. Scale uses the change in distance: `exp((d - d0) / ARM_PX)`; the absolute scale is clamped to 0.01..100.
8. The inspector copies the transform before its drag_value calls and records once per drag (as layer_drag_end does).
9. Only Turn writes `rotation`. The round trip is tested on matrices. Angles are normalised to [-180, 180). Euler
   storage stays.
10. The gizmo package takes the pick radius and world-per-pixel as parameters; it imports no app types.
11. W cycles the mode only from its key binding (a key-only argument of Tool_Move), so the toolbar button never cycles.
12. Timeline colour, history_next_label returns `what`, README/help/tool text, `gizmo_mode` remembered and tested.
13. PR 2: the pivot is stored in the object's local space with its id. A pivot tap with the latch on never selects.
    Alt is taken (orbit), so the pivot uses the latch and a long-press. Finger and pen drags start past the slop.
Optional, taken: no stored pivot in PR 1 (`gizmo_center`); nearest handle wins; the edge-on fallback is decided at the
press; a drag on the body moves in every mode; the pen keeps the mouse radius.

## Review of the PR 1 diff (sm-reviewer) and what changed
- Blocker fixed: Reset transform in the inspector recorded two steps (the section's drag snapshot saw the reset); the
  snapshot now follows the button. Scenario `transform_values_undo_per_drag` fails without the fix.
- scene_apply ends an open gizmo or inspector drag first, so a swap snapshot never holds a half-done drag.
- The centre square and scale disc pick at the interface's scale, as drawn.
- A new press ends a drag left open; the readout waits for a change; Escape during a drag only puts the object back.
