---
name: uniform-study
description: 2026-11-01 study of Sparseal Uniform's 16 tutorials vs our app: ranked report artifact, tiers, recommendation; awaiting Bolt's picks, nothing built
metadata:
  type: project
  modified: 2026-11-01T22:24:17.606Z
---

Bolt asked 2026-11-01 22:18 what to learn, copy and improve from Uniform (sparseal.com/uniform/tutorials, all 16 fetched fine with curl).
Report: https://claude.ai/artifact/HrYcx5dkE9EKrRifEDWYsE (source /mnt/project-files/notes/uniform/uniform-study.html; live mocks: Look pad, brush modulator strip).

Ranking:
- Tier 1 (S, no new chunk): 1 Look pad (2D shading pad: x shape->colour->unlit, y lights; corners snap to MatCap/Flat/Material/Rendered; mask as outline in colour looks), 2 brush modulators (source pressure/tilt/distance wave/random -> size/strength/hue/spacing; square wave = stitches; seeded for replay), 3 light mixer details (Solo/Mute, size ring + power in stops on marker, drag a light out of the surface, turn environment by dragging the horizon) folded into lights PR3/4 of [[rail-groups-lights-plan]], 4 print bed overlay + Measure tool (length/angle/volume).
- Tier 2: 5 physics on Move/gizmo + Pin + floor (reuse cloth.odin), 6 rope curves with self-collision written back to Bézier, 7 stencils (all brushes, two-finger transform), 8 hair clumps (multi-strand curve objects, radius gestures, brushes on curves, custom profile), 9 linked instances (GPU instancing), 10 shared/linked swatches + Colourways, 11 live SDF shapes into voxel bricks (design first).
- Tier 3: colour layers -> Surface plan S3, pixel-art preset -> Surface plan ([[surface-uv-paint-shader-plan]]), Topo pen contour + snap to sculpt, tool mods row (Uniform's Global Overrides as visible switches + 3 saved sets).
- Recommended: tier 1 first, then physics-on-move and rope; SDF shapes biggest wow.

**Why:** Bolt wants best-of-all-worlds ([[best-of-all-worlds]]). **How to apply:** build only what Bolt picks; designs needed for new object kinds/chunks (instances, SDF shapes, hair strands).

Round 2 (2026-11-02 08:04, Bolt: "don't direct copy, be unique; how do brush modulators pan out in real use; rewrite/refactor/remove is fine"): same artifact v2.
- Findings: Uniform's novelty = one toolset on every data type + global switches + everything live; its UI is why artists bounce (Nomad forum: daunting, refund; App Store 3.4/25). Modulators in real use: painters keep pressure->size/opacity; variation lives in presets; Krita sensor editors hit a complexity ceiling; sculptors buy repeated detail as packs (ZBrush stitch packs). Verdict: engine under presets + one Variation slider, editor under More.
- Own ideas ranked: 1 Live strokes (re-tune a past stroke, replay later ones; needs History design), 2 surface-aware modulators (cavity/curvature/facing/height), 3 Look pad that follows the tool, 4 one Physics switch (replaces Cloth Drag/Gravity; rope on curves), 5 tool switches row, 6 live bake to low poly, 7 linked by default + Colourways, 8 live SDF list (replaces one-shot voxel booleans).
- Replace list: Colour spray/Spray scatter/Random turn/pressure curves -> modulators; shading list -> Look pad; Cloth modes -> Physics; per-tool snapping/Front faces -> switches row; Insert copies -> linked; voxel booleans -> live SDF.
- Suggested order A modulators + Look pad, B Physics/rope/switches row, C Live strokes (design), D linked/live bake/SDF. Awaiting Bolt.
