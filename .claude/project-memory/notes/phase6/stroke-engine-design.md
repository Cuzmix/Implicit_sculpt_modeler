# Phase 6 item 5: Stroke engine

Roadmap row: "Stroke engine: roll, spray, straight line, snap-continue, plane locks, filter chips" (Z087 strokes,
Z085 Lazy Mouse 2.0 / LazySnap / Backtrack line, N013 Nomad stroke + filter sections). Today: `Stroke_Mode{Dots,
Drag_Rect}`, lazy mouse (`lazy_px`), front faces only (`front_only`, `Brush.facing`), all in `src/app/sculpt_tool.odin`.

## What the user gets
1. **Stroke modes** in the Brush tab's Stroke section (tabs become a select of four): Dots, Drag rectangle, **Spray**,
   **Roll**.
   - Spray (ZBrush Spray): at each spacing step, one dab scattered within `spray_spread` radii of the path
     (default 0.6), its size × [1 − 0.5·jitter, 1], its strength × [0.5, 1], and with an alpha a random turn. Spacing
     is 0.5 radii. Random numbers come from a per-stroke seed (the stroke's start position hashed, plus the dab
     index), so a replayed stroke (`.strokes`, R) lands the same dabs. One slider: Spread (0–1.5 radii).
   - Roll (ZBrush Roll): dabs one diameter apart along the path with the alpha's top along the stroke, so an alpha
     tiles like a tape rolled out (stitches, zips, chains). Without an alpha it is Dots at diameter spacing.
2. **Straight line** (ZBrush's Lazy Mouse line, 3DCoat's Shift line): **Shift pressed after a stroke has started**
   puts back what it did (`sculptor_stroke_restore`, as Drag rectangle does) and lays it again as a straight line from
   where the stroke began to the pointer, redone each frame while Shift is held; letting go of Shift goes on freehand
   from the line's end. Shift held at the press still means Smooth. Pen/finger: the rail's Smooth chip pressed
   mid-stroke does the same? No: touch gets a **Line** latch on the rail's long-press menu? Out of scope; touch uses
   the Stroke section's **Line** switch (every stroke a straight line, the redo always on).
   Redoing is bounded: at most MAX_DABS_PER_FRAME dabs a frame; a longer line catches up across frames (pending).
3. **Snap-continue** (LazySnap): a stroke pressed within `SNAP_PX` (24 px, Settings-free) of where the last stroke
   ended, on the same object, within 1.5 s and with the camera unchanged, starts from that end instead of the press,
   carrying its travel and direction, so a line drawn in pieces has no blob or gap at the joins. A switch "Join
   strokes" in the Stroke section, off by default (it changes where a press lands).
4. **Plane lock**: a switch "Lock plane" (Clay, Flatten, Layer, Draw, Inflate, Crease: every kind that works along the
   area normal) fixes the area normal and plane centre at the stroke's first dab, as Nomad's lock and ZBrush's
   Original plane options, so long Flatten strokes do not drift. Sculpt: `Brush.locked: Locked_Plane{set, normal,
   plane}`; `apply_dab` uses it instead of the area result when set (the first dab computes and returns its area, the
   app stores it on the stroke). Symmetric dabs mirror the locked plane with the dab.
5. **Filter chips**: the Brush tab's Options section gets a chip row: **Front only** (exists), **Connected** (new: only
   vertices joined to the dab's hit through the surface within the brush, ZBrush's topological auto masking: a flood
   over the hit leaves' triangles from the hit triangle, bounded by `reach`, per dab; a vertex not reached gets
   weight 0), **Unmasked only**? (the mask already protects) — so two chips, plus the same two in the brush pie's
   centre as toggles. Each chip shows on the action bar's Brush group? No: action bar groups are object-scoped.

## Data and files
- `Brush_Settings` gains `spray_spread f32`, `line bool`, `join bool`, `lock_plane bool`, `connected bool`; settings.txt
  keys (`stroke_spread`, `stroke_line`, `stroke_join`, `lock_plane`, `connected`), presets keep them (Preset_Values
  gains the same), `.strokes` files: a version bump of the brush block appending the five fields (older files read
  with defaults).
- `Stroke` gains `line_start, line_active`, `seed u64`, `dab_index`, `locked`.
- Sculpt: `Brush.locked`, `Brush.connected` (+ `sculptor` returns the area of the first dab), a `connected` flood
  scratch per sculptor (heap, reused, sized by hit vertices).

## Split
- 5a: Spray + Roll (app only) + Spread slider; settings, presets, strokes-file fields for spread.
- 5b: Straight line (Shift mid-stroke, Line switch) + Join strokes.
- 5c: Lock plane + Connected (sculpt) + filter chips (Options section, pie).

## Tests
- App: spray dabs within spread·radius of the path and identical for the same seed; roll spacing = diameter, alpha up
  along the stroke; line redo leaves exactly the straight-line result (compare with a stroke laid straight);
  join starts at the last end (st.pos) only within SNAP_PX/time/camera.
- Sculpt: locked plane Flatten over a slope keeps every dab's plane = first; connected leaves a separate shell under
  the brush untouched (two spheres overlapping in space, not in topology); serial = parallel for both.
- Scenarios: spray and roll strokes dab (`dabs` > 0) and are one undo step; Shift mid-stroke gives `stroke_line=1`
  stat; join continues (`stroke_joined=1`); chips toggle (`brush_connected=1`).

## Architect review outcome (2026-10-26) — adopted
Required changes taken: (1) latch the stroke's kind (Smooth/Mask) at stroke_start so Shift mid-stroke is free for
Line (new 5a0, its own PR; README notes old takes with a mid-stroke Shift replay as lines); (2) Line refused under
dyntopo and for Grab/Cloth/Hook/Rect strokes; (3) line redo kept as line_from/line_to/line_done, restarted only after
the previous redo finished, completed before freehand resumes, pivot_sum/travel/dir reset on restore; (4) spray seed
from an App counter, stored per stroke in Take (STROKES_VERSION bump), dab_index per spacing step, no app.alpha_seed;
(5) Join drops the time condition (same object, camera unchanged, SNAP_PX), cleared by replay_start/stop; (6) Lock plane
applies to Draw, Clay, Flatten, Pinch, Crease and alpha frames, locked before Clay's offset and tilt, from the first
dab with weight; stored in the Sculptor, reset by stroke_begin, mirrored per image; (7) Connected floods from the hit
vertex nearest the (mirrored) centre through vertices inside the reach sphere (reachability, order-free), local
scratch via the hit nodes' ranges, applied in job_area, Smooth, mask_dab and paint_dab; Grab skips it; (8) Stroke
section ≤5: mode select hidden for Grab/Hook/Cloth, Spread only for Spray, Line and Join under More; kit_more_test
loops Stroke_Mode; (9) preset lines accept old and new field counts.
Suggestions taken: presets keep spread/lock/connected (line/join global); STROKES_VERSION bumped per sub-PR; jitter a
named constant, spread in screen px; Roll holds its first dab until the pointer moved a radius; no pie-centre toggles,
Connected and Lock plane are commands instead; Connected bench row at 10M.
Split: 5a0 latch kind; 5a Spray (+seed) and Roll; 5b Line and Join; 5c Lock plane, Connected, chips.
