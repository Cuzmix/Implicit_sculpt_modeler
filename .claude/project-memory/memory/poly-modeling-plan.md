---
name: poly-modeling-plan
description: 2026-10-28 Bolt's asks for a ZModeler-equivalent poly modeling mode: pen/tablet-first rule, findings doc, open questions with defaults
metadata:
  type: project
---

Thread "Plan poly modeling like ZModeler", started 2026-10-28 17:48 by Bolt: plan (not build yet) a ZModeler-equivalent poly modeling mode.

Bolt's rules for it:
- Read every Maxon doc/tutorial on ZModeler, poly modeling and retopology first and "understand this totally"; show Bolt the list of what was found; ask about unclear areas (Bolt will send links); then plan. Take inspiration from Blender and other modelers too ([[best-of-all-worlds]]).
- **Pen/tablet-friendly first** (Bolt 17:56): Bolt uses an XP-Pen tablet. ZModeler is the reference because nearly every operation is one pen press-drag on the hovered element; Blender/Maya/Plasticity often are not pen-friendly. Lean on pen-friendly operations; touch is a helper.
- Approval needed before building; then the usual self-merge into odin-sculpt.

Findings doc (Claude Doc, 2026-10-28): https://claude.ai/artifact/HyMakwsdpk7zC9MhoUAPob — 155 desktop + 57 iPad doc pages, 28 Cineversity tutorials; 73 ZClassroom YouTube videos listed but unwatched (blocked).
Questions sent to Bolt 2026-10-28 with defaults used for planning: hover on XP-Pen + pen/express keys bindable (default: hover on desktop, press-hold preview otherwise); n-gons allowed in cage (default yes, quads at subdivide); separate selection layer not temp polygroups; tap-to-repeat kept with tolerance+toggle; editing meshes with levels later (first versions require dropping levels); box modeling before retopo.

Plan artifact (2026-10-28): https://claude.ai/artifact/FbiAiDoT6wX8dyrMjJYUjx (copy in /mnt/project-files/notes/poly/model-mode-plan.html). 10 phases, ~28 PRs (final version 2026-10-28 19:10, all apps folded in): 1 src/poly half-edge cage + target queries; 2 Model shelf page, primitives, cage edges, scene v26, cage undo; 3 pen grammar (hover colours point blue/edge amber/face teal, label, press-hold preview, wheel relabel Smooth->Snap Mask->Select Invert->Alt, pie on pen side button, presets as shelf tiles) + face actions; 4 edge/point actions; 5 selection layer, floating value tap-to-type, Adjust Last, tap repeat, mirror; 6 Catmull-Clark + semi-sharp creases + bevel; 7 CC levels in sculptor, Apply to sculpt, edit under levels with reprojection; 8 bevel creases/thickness/knife; 9 Topo pen (Maya Quad Draw + Modo Topology Pen grammar on the pen); 10 strips/patches incl. 3D-Coat ring strokes to tubes and outline fill. Architect design note required before phase 1. **2026-10-28 19:15 Bolt approved: "do all of the phases, I will be away"** — build all 10 phases autonomously, self-merge each PR into odin-sculpt, thread renamed "Build pen-first poly modeling".

Research notes on Shapr3D, Blender, Plasticity, 3D-Coat, Maya, Modo: [[poly-modeling-research]].

Code facts found (odin-sculpt @ bf70bd1): geom.Mesh is triangles only (SoA, u32 indices); OBJ import fans polygons; retopo keeps quads in sculpt.Levels.faces (Quad_Faces) and draws them as triangle pairs; levels are Loop subdivision only (no Catmull-Clark, no creases); polygroups are per triangle (u16); wireframe draws triangle edges; scene file v25.

How to read the sources: [[maxon-docs-access]].

Build progress: ALL 10 PHASES MERGED by 2026-10-29 01:55: #248 p1, #253 p2, #255 p3, #257 p4, #261 p5, #263 p6 (CC + creases + bevel, v28), #264 p8a (knife, loop shaping), #265 p7a (CC levels, v29), #266 p7b (Edit cage, v30), #267 p8b (live stack thickness/bevel, v31), #268 p8c (Align, Spine), #269 p9 (Topo pen, model_topo.odin), #270 p10 (Topo strokes: strip/closed fill/Ctrl grid patch; live mirror Live.mirror + Apply mirror via tidy_cage apply_mirror, v32). Left out: 3D-Coat rings-to-tubes, patch handles. Nothing tried on Windows/tablet yet.

Gotcha (cost a debug round): `history_snapshot` calls `object_put`, which does `free_all(context.temp_allocator)`, so anything temp made before a snapshot is garbage after it; take the snapshot first.
