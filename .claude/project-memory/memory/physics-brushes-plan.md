---
name: physics-brushes-plan
description: 2026-11-03 plan for cloth and physics brushes (Uniform study item 5): doc URL, plan file, the design in one paragraph, 8 PRs, defaults; Bolt said build all 8 (2026-11-03); PR1 #557, PR2 #560 merged
metadata:
  type: project
  modified: 2026-11-03T11:05:01.933Z
---

Thread "Plan cloth and physics brushes" (2026-11-03, Fable). Bolt picked item 5 of the Uniform study's own-ideas list ([[uniform-study]]) and asked for planning first with Blender's cloth source and ZBrush as references; he asked to review before any build (11:03Z).

Plan doc: https://claude.ai/artifact/CPv7XBVvWcZ13GxbvpEfUy (Claude Doc). Build copy: /mnt/project-files/notes/physics/plan.md.

Design in short: grow `src/sculpt/cloth.odin` (PBD, Jacobi, deterministic) into the one solver; three ways in: a Physics switch any moving tool drives (Grab/Elastic/Snake hook targets, gizmo/Pose/Deformers/Lattice as targets over the whole free part = ZBrush TransposeCloth, dab brushes at a strength = ZBrush Elasticity), the Cloth brush as force modes (Drag, Push, Pinch, Pinch line, Inflate, Expand, Twist, Wind) plus a preset family (ZBrush's 13), and a Physics card (Settle = Run Simulation, gravity with Set direction, floor, object collision via `voxel.clay_from_mesh` SDF keyed like the floor grid, self collision by counting sort, On masked, Strength/Firmness/Damping, Keep area = morph target base with Allow shrink/expand, filters Inflate/Expand/Scale with axes). Dense meshes: budget 300k/120k; over it simulate the finest level under budget and `levels_sync` at release, or a cloth proxy (simplify + bind + write back) for meshes without levels. GPU kernels after GPU sculpt P4 ([[gpu-sculpt-plan]]). Rope on curves last.

Research facts (not in the repo): Blender's `sculpt_cloth.cc` (now under `editors/sculpt_paint/mesh/`, fetch from projects.blender.org raw, GitHub mirror 404s) solves 5 Gauss-Seidel rounds serially over one constraint list built all-pairs per vertex; deformation constraint strengths 0.1 Grab, 0.35 Snake hook, 0.01 other tools; collisions by raycast against Collision-modifier objects, 0.005 offset, 35 % friction; cloth filter Gravity/Inflate/Expand/Pinch/Scale. ZBrush Dynamics: iterations 50, Strength, Firmness, On Masked, On Brushed + Fade Border, Self Collision 0-4, Floor, Allow Shrink/Expand, Gravity + Set Direction, Liquify, Inflate/Deflate/Expand/Contract with XYZ, CollisionVolume + Recalc + Resolution + Inflate, Max Simulation Points 250k; ZBrush for iPad has no Dynamics. Nomad, Forger, Marmoset have none; 3D-Coat a basic drape tool.

PRs: 1 solver (~900), 2 Physics switch (~700), 3 collisions (~650), 4 Physics card (~800, SCENE_VERSION 37, .strokes v31), 5 brush family (~300), 6 dense meshes (~600), 7 GPU kernels (~500), 8 rope (~450). Questions with defaults in the doc (switch placement, retire Deformation's Gravity slider, Follow strengths, Allow shrink/expand off, budgets, rope in, no Liquify).

**How to apply:** a build thread starts from the plan file and the doc after Bolt's OK, PRs 1-4 in order, design notes under notes/physics/, self-merge into odin-sculpt; Bolt runs the full gate ([[gate-on-bolts-pc]]).

Build status: 2026-11-03 Bolt: "OK let's do all of it" (defaults as written). PR1 solver #557 merged (notes/physics/pr1-solver.md). PR2 Physics switch #560 merged (Grab/Elastic/Hook/dabs; targets = vertices the tool wrote; gizmo/Pose/Deformers left for a follow-up PR 2b). PR3 collisions #565 merged (floor, SDF volumes per object cached in app, self grid; .strokes v33). PR2b pose drivers #567 merged (cloth hold mode, Whole region skips masked verts, PHYSICS_POSE_MAX 300k). PR4 Physics card paused by Bolt 2026-11-03 mid-build: WIP committed and pushed on branch claude/project-thread-6xripq (no PR; also notes/physics/pr4-physics-card-wip.patch) (on top of #567; app tests still failing: kit_more five-control limit (Options has 6 since PR2 Physics switch), show_where Skin_Squeeze, Retopo count, scene_tree view_flags round trip); PR5-8 not started. Branch claude/project-thread-6xripq.
