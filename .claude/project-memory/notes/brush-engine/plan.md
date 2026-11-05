# Brush engine plan (research + phases), 2026-10-29

Thread "Plan a ZBrush-feel brush engine". Full findings, side-by-side tables, sources and the plan as an artifact:
https://claude.ai/artifact/FWUTVoVJ4chsRmnuNUDMAz. Status: approved by Bolt 2026-10-29 12:26 with the defaults as written; build thread requested from the coordinator.

## Three findings
1. Input: SDL 3.4 reads only the newest pen/touch sample per OS event on Windows (WM_POINTER history ignored),
   Android (MotionEvent historical samples ignored) and iOS (coalescedTouches ignored). Our "every sample" stroke
   path (App.samples, stroke_walk) therefore gets one sample a frame on tablets; fast curves are chorded. Blender
   reads GetPointerPenInfoHistory; 3D-Coat 2021 follows the whole trajectory. Biggest responsiveness win, app only.
2. Grab: absolute-from-start, follow matrices, symmetry, undo are right. Missing: press past the silhouette (Nomad
   background radius), along-normal mode (ZBrush Shift / Nomad Normal / 3D-Coat Ctrl / Blender Normal weight),
   topological falloff (geodesic), elastic (Kelvinlets), Grab under dyntopo with stretch repair (nobody has it).
3. Feel: one pressure curve shared by size and strength; Smooth is one Jacobi step; area normal re-sampled every
   dab (ZBrush Samples: Stabilize orientation, Sample radius, Buildup). Spacing 0.25 r vs 0.15-0.2 r elsewhere,
   strength not compensated for spacing (Blender does).

## Phases and PRs (20 PRs, order 1 -> 6)
Phase 1 Input and stabiliser (app only, ~1100 lines)
- 1a Every tablet sample: Windows SDL_SetWindowsMessageHook + GetPointerPenInfoHistory (older first, like Blender);
  Android: our SDLActivity subclass overrides onTouch to push getHistorical* via JNI; iOS: gesture recogniser on
  SDL's view reading coalescedTouches + Pencil force/azimuth/altitude per sample. Pen samples carry own pressure/tilt.
  Stats samples_frame, samples_coalesced. Drop SDL's own event for the same update (risk).
- 1b Stabiliser 2.0: Lazy radius (exists) + Smoothing (moving average N 1..16) + Pressure smoothing (own N); catch up
  on lift (default on); rope drawn by default. Presets/settings/.strokes version bump.
- 1c Spacing default 0.2 r with Blender's overlap compensation (strength / max overlap, normalised so a stroke at the
  new default builds today's height); scene-space spacing option; symmetry feathering (Blender: divide by the
  summed overlap of mirror images within 2 r of a plane); bench Draw 10M.
- 1d Predicted cursor ring (iOS predicted touches, Android MotionEventPredictor, else 1-frame velocity extrapolation,
  never committed); present mode check per platform; latency_ms in gpubench tables.
Phase 2 Move family (~1900 lines; design notes 2b, 2c, 2e)
- 2a Grab from past the silhouette (nearest surface point to the ray within the screen radius via
  bvh_query_leaves_line), Shift after press = along area normal with Normal weight slider + view scale, Alt after
  press = along the surface (Blender Nudge/Thumb (n x delta) x n = ZBrush Alt-move), Same side (Nomad), Silhouette
  (Blender), press pressure latched (Grab has it; add Snake hook).
- 2b Move topological: radius-limited Dijkstra per symmetry image, weight = falloff(geodesic/r); preset "Move
  topological"; chip on Grab's section. Ties by vertex index (serial == parallel).
- 2c Elastic brush kind: regularized Kelvinlets (Blender constants: scales r,2r,4r, force calibrated to the tip),
  Volume = Poisson 0..0.9 default 0.4, evaluated over leaves within 3 r with a blend to 0 at 3 r (bounded cost),
  restore-and-reapply reusing Grab's arrays. Scale/Twist later.
- 2d Snake hook: Pinch/Magnify (Blender term with near-centre damping), Rake, Elastic tip option.
- 2e Grab/Elastic allowed under dyntopo; stroke-end Rivara split pass over moved nodes + tangent smooth of new verts,
  same undo step.
Phase 3 Pressure (~700 lines): 3a separate Size and Strength curves, per brush with Use global (ZB/Nomad), pressure
  smoothing before both; 3b response presets (Clay = max(0.2r, r p^3) Blender; Firm strokes; Light touch).
Phase 4 Smooth (~900 lines; design note 4b): 4a strength -> up to 4 Jacobi passes (Blender), open-border vertices
  average only border neighbours, Stronger preset, Stable switch (passes x (radius/mean edge)^2, cap 8);
  4b modes Smooth / Relax (tangential) / Polish (HC Laplacian a=b=0.5, volume-keeping) with Alt+Smooth = Polish;
  4c Smooth under dyntopo: collapse-only tessimation behind the Collapse switch, bench rows.
Phase 5 Sampling (~1000 lines; design note 5a): 5a Samples section: Stabilize orientation (EMA of area normal/plane,
  Lock plane its end stop), Sample radius 0.25..1, Accumulate per brush (off = falloff distance + normal from the
  stroke's undo start positions, per-vertex height cap like Layer; Clay on, Draw off as Nomad); 5b Hardness (Blender)
  + Falloff shape Sphere/Projected for all brushes (Projected default for Flatten, Clay); 5c Size Constant in world
  units (ZB Dynamic / Nomad Constant 3D), No back and forth, Directional; 5d Clay strips (ZB ClayBuildup: Blender
  cube tip with Tip roundness/scale, z(1-z) build-up weight, Plane trim, p^1.5 + 0.3r floor) and Trim (Blender
  Multiplane scrape, dynamic angle), Flatten gains Plane height/depth. Phase 5 ~1700 lines.
Phase 6 Dyntopo (~500 lines): 6a per-brush toggle + Use global, Detail by Radius option, falloff- and mask-weighted
  split/collapse tests; 6b stretch repair pass for Snake hook and Cloth + Remove stretching command.

## Blender source (second read, 2026-10-29 12:xx)
Artifact section "Blender's engine, read from the source": StrokeCache invariants/variants, radius from px at the
hit depth, strength = strength^2 x pressure x overlap x per-brush constant (Clay 0.25 p^4, Draw 1, Inflate 0.25/0.125,
Pinch 1/0.25, grab-like raw), factor pipeline order (mask, front, distance, radius, hardness, falloff, automask,
texture), area normal over normal_radius_factor 0.5 with 3p^2-2p^3 weights and front/back bins, Plane brush rolling
stabiliser, leaves <= 2500 verts, lazy normals at draw, in-between events dropped only for grab-like brushes. Local
copies of the files read: scratchpad (not durable).

## Defaults chosen (questions in the artifact)
Q1 spacing 0.2 r + compensation: yes. Q2 topological falloff off by default (preset + chip). Q3 Elastic is its own
brush kind. Q4 Alt+Smooth = Polish. Q5 order 1..6; if tablet feel first: 1a, 1b, 3a, 2a.

## Verification per PR
gate.py; bench rows 1M/10M (Grab, Elastic, Smooth, Draw spacing); touch_check scenarios (fast stroke dab count,
catch-up, Shift mid-grab); PNGs; README. Pen/touch parts need Bolt's Windows/tablet try (VM has no pen).

## Left out
Gravity/Imbed/depth masks, Backtrack Plane/Spline/Path, 3D-Coat Powerful smoothing / Super Relax, ARAP grabs,
Android front-buffered rendering.
