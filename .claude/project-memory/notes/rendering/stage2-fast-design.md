# Stage 2: Fast that survives moving (design)

Stage 2 of "One Render" (https://claude.ai/artifact/PPSMxjSsYTUZfkVnufnTdL), approved by Bolt 2026-10-28.
Today Preview (render/studio.odin) starts over on any change: while the view turns it shows live occlusion or the
plain viewport, and its occlusion and soft shadows come back only after the view rests. Fast keeps them while the
camera moves, as EEVEE's and Toolbag's raster modes do, by carrying last frame's samples to where they now are.

## What exists when done
- Turning, panning or zooming the view keeps Preview's occlusion and shadows on screen: each frame reprojects the
  samples it has, drops the ones the move uncovered, and adds one new sample, so the picture stays shaded and
  sharpens again within a few frames of rest. Preview is renamed Fast in the Render section.
- A stroke, a moved object, a light or any other scene change still starts over as today (live occlusion covers
  strokes): per-object motion needs motion vectors from the mesh pass, which means a second colour target on the
  mesh pipelines, and the Vulkan thread owns pipeline creation now. That part moves to stage 4 (Balanced), on the
  Vulkan backend.

## Sources: take, avoid, better
| From | Take | Avoid | Better |
|---|---|---|---|
| Unreal TAA / Karis 2014, EEVEE Next | reprojection from depth and the previous view-projection; a history cap so old samples fade | colour clamping to the neighbourhood (made for shading, it eats occlusion) | reject by depth and normal agreement instead: occlusion is a property of the surface point |
| Toolbag 5 Raster | shading never drops out while the camera moves | blur while moving | keep the sample count honest: a reprojected pixel carries a capped weight, a new one starts at zero |
| SVGF (Schied 2017) | moments-style counts per pixel, disocclusion test with depth and normal | | the counts already live in accum (ao sum, ao count, lit sum, light count) |

## How
- `studio_frame` gets the previous view-projection and a `moved_only` flag from the app: true when the view or the
  viewport size is all that changed (`view_changed` without any object, light, look or redraw cause). The app
  knows this from the frame key parts it already hashes; the renderer gets one bool.
- New pass `studio_reproject.frag.slang` (full-screen, into the other of two `accum` targets, RGBA16F as now):
  for each pixel, world position from the new depth (`inv_view_proj`), into last frame's clip space
  (`prev_view_proj`), last frame's accum and depth fetched there (nearest; bilinear would mix the sums across an
  edge). Kept when last frame's depth there puts the point within 1% of the eye distance and the depth-derived
  normals agree (dot > 0.9); then the counts are capped (ao 24, light 8: about a third of a second of samples at
  60 Hz, so a turn's ghosting fades as fast as it shows) and the sums scaled by the same factor. Rejected: zeros,
  and the pixel shows the viewport's own shading until samples come.
- `accum` becomes a pair (ping-pong) and the studio keeps last frame's one-sample depth (`prev_depth`, R32F, a
  copy of the depth the gather read). Cost while moving: the depth pass that the gather needs with MSAA (as now at
  a still view's first sample), one shadow-map draw, the gather, the reproject and the composite. Tablets: the
  sample is skipped on frames slower than 20 ms (the composite of what there is still runs), as render mode's
  bands adapt.
- Display: `studio_texture` shows the composite whenever the accum holds reprojected samples, without waiting for
  STUDIO_SHOW_MIN (which still applies to a fresh start).
- Traced studio: trace_prepare's trees hold for a camera-only move (no geometry changed), so traced samples go on
  reprojecting too.
- Rename: Render quality tabs "Fast | Full"; command and help text; README; `render_quality` keeps its stored value
  names (`preview` reads as fast) so settings files keep working.

## Checks
- At rest nothing changes: 0 px against base in four scenes, before and after a turn that comes back to the same
  view (`moved_only` with the same matrices reprojects exactly).
- A scripted orbit: images at frames 1, 4, 16 of a turn, described; counts stay capped (exit stat `studio_kept`
  share of pixels kept, `studio_reprojected` frames).
- Unit test of the cap and rejection maths on the CPU mirror; touch scenario: a two-finger turn with Render on
  keeps `studio_samples` above zero.
- Full gate; gpubench row with Fast on while orbiting.

## Architect review (approve with changes), folded in
1. Camera-only detection lives in render: `studio_key` inside `studio_frame` over each item's mesh, version,
   index_version, model, hidden, look, pass, matcap; the world-space lights, softness, environment; and an epoch
   `viewport_invalidate` bumps. Reproject only when that key holds and only view/proj moved. Never call
   `view_changed` twice (it writes `app.view_key`).
2. A `lod_px` change (the LOD settle 250 ms after rest) is a reprojection with the same matrices, not a restart.
3. Camera-fixed lights (the default rig) turn with the view: keep occlusion (r, g) always, keep shadows (b, a) only
   when every light on is fixed to the scene; otherwise zero them and let key samples rebuild them. Say so in README.
4. Caps in sample counts: g <= 0.25 * N_ao (g is a sum of cosines, about 0.25 a sample), a <= N_key (one key sample
   in four). Start with N_ao 16, N_key 4.
5. `samples` keeps counting for the R2 sequence; stopping, idle and STUDIO_SHOW_MIN use `fresh` (since the last
   restart). Neither the gather nor the traced add clears after a reprojection; under MSAA the view depth is drawn
   every moving frame.
6. No time-based skip: a triangle budget decides (above it, reproject and composite only); 0 px only for runs
   without motion.
7. `prev_depth` written by a full-screen pass as linear view depth (no depth-to-colour copies).
8. Depth is standard [0,1], far 1; test the plane distance |n . (p_prev - p)| scaled by view depth (perspective) or
   the scene radius (ortho).
9. 2x2 bilinear with the depth/normal test per tap and renormalised weights (sums are linear, so exact).
10. While moving: shadow map from the coarsest simplified copy, one shared 1x depth with live AO, normal offset and
    TRACE_EPSILON grown by the LOD error.
12. Where counts are zero and live AO is on, the composite's base is live AO's image.
13. A resize restarts. 14. finish_version adds the reprojection and fresh counts. 15. `studio_kept` only in dumps.
