# 4b Smooth, Relax and Polish: design note (2026-10-29)

Goal: Smooth gets three modes, as ZBrush's smooth modifiers, Nomad's Relax and Blender's Surface Smooth do: Smooth
(as 4a left it), Relax (evens out the spacing of the vertices along the surface and keeps the shape) and Polish
(takes off roughness but keeps the volume, the HC Laplacian). Alt held while smoothing (the Smooth brush or Shift
with any brush) switches the dabs to Polish, as ZBrush's alternate smooth on Alt.

## Maths, per pass (4a's passes and strength stay)
- q = the middle of the vertex's triangles' corners (4a's target; the border rule stays for all three modes).
- Smooth: p' = q.
- Relax: p' = p + (q - p) - n ((q - p) . n), n the vertex normal: only the part across the surface.
- Polish (HC Laplacian, Vollmer, Mencl and Muller 1999, as Blender's Surface Smooth with alpha = beta = 0.5):
  b_i = q_i - (alpha o_i + (1 - alpha) p_i), o the positions when the dab began;
  p'_i = q_i - (beta b_i + (1 - beta) mean of b_j over its neighbours j).
  A vertex outside the brush has b = 0 (it does not move, so it does not push back).
  Two Jacobi sub-steps a pass: the q and b of every vertex inside first (job_smooth_targets writes q and b),
  then p' (a new job reading the neighbours' b), then the blend p = lerp(p, p', rate x falloff x shield).
- The dab-start positions are the leaves' positions copied before the first pass (o), so each dab keeps its own
  volume; storing a stroke-start copy (Blender's original positions) costs 12 bytes a vertex for little gain.

## Data
- `sculpt.Smooth_Mode :: enum u8 {Smooth, Relax, Polish}`, `Brush.smooth_mode`. Scratch: `s.smooth_b` (b per slot,
  as smooth_to) and `s.smooth_from` (o per slot).
- App: `Brush_Settings.smooth_mode`; brush_at gives it to a Smooth dab, Polish while Alt is held.

## App
- Smooth's Options: tabs Smooth / Relax / Polish at the top; Valleys/Peaks and Stable move under More (the section's
  five controls).
- Settings `smooth_mode`; presets as the named value `smooth_mode=relax|polish`; `.strokes` version 24 (the byte
  after Stable). README Smooth row; glossary Relax and Polish.

## Tests
- Relax on a sphere moves vertices only across the surface: the distance from the centre changes by under 1e-4
  of what Smooth's does, and the spacing evens out (the spread of edge lengths falls).
- Polish keeps the volume: on a noisy sphere a full-strength dab over the whole of it loses under a third of what
  Smooth loses (Blender's own claim is volume-aware, not exact).
- serial == parallel for Polish; Alt in brush_at gives Polish.

## Cost
Polish does two passes over the vertices per pass and copies the positions once a dab: about twice Smooth's time.
Bench row "Smooth, polish" at 1M and 10M.
