# Cloth and physics brushes plan (2026-11-03)

Full plan with the Blender, ZBrush and Uniform findings and the side-by-side table:
https://claude.ai/artifact/CPv7XBVvWcZ13GxbvpEfUy (Claude Doc). This file is the build thread's copy of the
design and PR list. Status: awaiting Bolt's review; nothing built.

## Recommendation
Grow `src/sculpt/cloth.odin` (PBD, Jacobi, bit-identical serial/parallel) into the app's one physics
solver, reached three ways: a **Physics** switch any moving tool drives (Grab, Elastic, Snake hook, Move
gizmo, Pose, Deformers, Lattice, Deformation sliders, and the displacement brushes at a strength), the
**Cloth brush** as force modes plus a preset family (ZBrush's 13 cloth brushes), and a **Physics card** in
the Object palette (Settle = ZBrush Run Simulation, gravity, floor, object and self collision, the Blender
filter set). No new package, no new scene chunk, no History change.

Take: Blender's deformation-target constraints (0.1 Grab, 0.35 Snake hook, 0.01 others), its 8 force modes,
Dynamic area, Persistent base, filters with orientation and axes. ZBrush: Strength, Firmness, On masked,
Allow shrink/expand with the morph target as base, Set direction, floor, self collision, collision volume,
brush family, any brush at a simulation %. Uniform: one switch on every deformer, Pin = Grab + Physics +
gravity. Avoid: Blender's serial Gauss-Seidel list and all-pairs constraint build; ZBrush's 250k cap, separate
palette, Recalc by hand, Liquify; Uniform's hidden overrides. Better: parallel Jacobi (GPU-portable), SDF
collision volume (`voxel.clay_from_mesh`) rebuilt by itself (keyed like the floor grid), dense meshes by
simulating a coarse level (`levels_sync` carries detail) or a cloth proxy.

## Design
1. Solver (`cloth.odin`, `cloth_links.odin`, `cloth_collide.odin` in sculpt): Strength (edge correction
   scale, default 1), Firmness (one cross-edge link per triangle edge, default 0.5, replaces the
   displacement-smoothing bend term), Damping 0.08, 5 rounds a substep, substeps by largest drive move in
   link lengths (cap 4); deformation targets (position + weight × Follow); Keep area (rest lengths from the
   morph target if stored, else the stroke start) with Allow shrink / Allow expand (one-sided links);
   regions Local (1.6 r, outer 30 % pinned), Follows (re-gathered every half radius, nothing pinned), Whole
   (all shown free vertices; mask = pin); symmetry = union of brush images, mirrored drive, one simulation;
   gravity Screen down / World down / Set direction (stored per object); Cloth brush modes Drag, Push,
   Pinch, Pinch line, Inflate, Expand, Twist, Wind (Gravity, Grab, Hook modes retired).
2. Collisions after the rounds, each a parallel pass: floor grid plane with 35 % friction; per other shown
   mesh object an SDF volume at ~1/256 of its size, keyed by id/transform/level, Gap default 1 % of size;
   self collision by a counting-sort grid of cells 2 × Thickness (default half the median link), pairs in
   index order (deterministic); self collision off under brushes, on for Settle.
3. Physics switch (`Brush_Settings.physics`, `physics_strength` %, default 35): Brush card Options row,
   Move card row, a dock chip beside Symmetry; settings, presets (tail word), `.strokes` v31. Grab/Elastic
   (Local 2.5 r) and Snake hook (Follows) drive targets; gizmo/Pose/Deformers/Lattice/Deformation sliders
   set the pose as now (`pose_set`) and the pose's result becomes targets of the free vertices over Whole
   with collisions (TransposeCloth); dab brushes run one step at the frame's flush over the union of dab
   regions with dabbed vertices as targets at Physics strength. Refused: HD windows, voxel objects, the
   cage, GPU take (Gpu_Take None until PR 7).
4. Physics card (Object palette, between Deformation and Deformers): Settle (hold-to-run; tap = run until
   tap/Space; auto-stop below a thousandth of a link per frame; one undo step), Gravity + Strength +
   Direction + Set direction, Floor, Collide with objects + Gap, Self collision + Thickness, On masked,
   Strength, Firmness, Damping, Keep area (+ Allow shrink/expand under More), filters Inflate (signed),
   Expand (signed), Scale with XYZ and Orientation Object/World/Screen as live drag sliders (one undo step
   each). Settle runs as a stroke with a step a frame (not a Scene_Command). Per-object fields in the OBJ
   chunk, SCENE_VERSION 37. Deformation card's Gravity slider retired (Bolt's call).
5. Dense meshes: budget B (300k desktop, 120k tablets, `--physics-budget=`). Under B: direct. Over B with
   levels: simulate the finest level under B (mask carried down), show that level during the drag, sync up
   at release in the same undo step. Over B without levels: cloth proxy (simplify to B, bind each fine
   vertex to its closest proxy triangle + normal offset, ~0.5 s at 25M on the VM), proxy drawn during the
   drag, fine mesh written back at release (~60 ms at 25M on the VM), proxy kept until topology changes.
6. GPU (PR 7 after GPU sculpt P4): integrate/round/collision/write-back kernels under the GPU sculpt
   switch, `Physics_Gpu` callbacks beside `Stroke_Gpu`, kernels in `render/sculpt_gpu.odin`, on P1's CSR,
   `--gpu-sculpt-sync` A/B.
7. Undo/replay/files: existing stroke and pose recording; replay records the switch, strength and card
   settings; Keep area base = morph target; README Cloth brush section becomes Physics.
8. Tablets: Settle = hold, chip = tap, budget 120k; touch scenarios Pin drag, Settle hold, gizmo + Physics.

## PRs (sizes in lines, each gated as usual; design notes under notes/physics/)
1. Solver (~900, note): stiffness, substeps, targets, Keep area, regions, symmetry, gravity direction, new
   Cloth modes; old Gravity/Pinch/Expand strokes in `.strokes` refused. Tests: determinism, area within 1 %,
   one-sided links, symmetric to the bit; `bench --physics` at 500k and 10M.
2. Physics switch (~700, note): settings/presets/.strokes v31/dock chip; drivers; refusals. Touch: Pin
   drag, gizmo with Physics; PNG Grab with/without Physics.
3. Collisions (~650, note): floor, volumes, self collision, friction. Tests: sheet on sphere ≥ Gap, folded
   sheet keeps Thickness; PNG drape over a head.
4. Physics card (~800, note): card, Settle, gravity controls, On masked, filters, OBJ fields v37, scripts,
   README; Deformation Gravity retired. Touch: Settle hold; PNGs before/after.
5. Brush family (~300): presets Nudge, Pull, Hook, Inflate, Ball, Fold, Pinch, Pinch trails, Slide, Twister,
   Wind, Dimple, Pin, Cloth smooth; previews; a PNG each.
6. Dense meshes (~600, note): budget, level path, cloth proxy. Tests: identity write-back to the bit; 25M
   drag under 16 ms a frame on the VM; mesh_check.
7. GPU kernels (~500, note with the GPU sculpt thread): bit-exact A/B; 25M on the 3060 Ti.
8. Rope on curves (~450, note): chain + capsule self collision + gravity/floor, written back to Bézier
   points; Physics on the Curve tool; PNG of a knot.
Order: 1-4 in order; 5 after 2; 6 after 1; 7 after GPU sculpt P4 and PR 6; 8 after 1.

## Questions with defaults
1. Where the switch shows: Options row + Move card + dock chip (or the Uniform study's switches row).
2. Deformation Gravity slider: retired.
3. Follow strengths 0.1 / 0.35 / 35 %; gravity off under brushes, on for Settle; Pin preset turns it on.
4. Allow shrink/expand both off; Pull preset turns Allow expand on.
5. Budgets 300k / 120k; measured on the tablets after PR 6.
6. Rope (PR 8) in, last.
7. Liquify not planned.
