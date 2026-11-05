# 2b Move topological: design note (2026-10-29)

Goal: Grab's falloff measured along the surface (geodesic distance) instead of straight-line distance, as ZBrush's
Move Topological and Blender's Elastic/Grab "Geodesic" falloff do, so a grab on one finger never drags the next one
and a grab on a lip leaves the other lip, and the falloff follows the surface round a fold rather than cutting
across it. Off by default; a switch in Grab's Options and a built-in preset "Move topological".

## What exists
- `sculpt.Brush.connected` + `grab_reach` (filters.odin's union-find flood over the hit leaves' triangles): picks only
  the part joined to the press, but weights by straight-line distance. Today's "Move topological" in README terms.
- `Grab_Job` evaluates `grab_follow(j, v)` per vertex in parallel per leaf, with per-image arrays (`reach`, `dirs`,
  `sides`), binary-searching sorted vertex lists made on the temp allocator.

## Design
- `sculpt.Brush.topological: bool`. In `sculptor_grab_begin`, with `topological` and no `through` (All depth wins,
  as it does over Connected), each symmetry image gets `geodesic_reach(s, center, radius) -> (verts: []u32,
  dist: []f32)` on the temp allocator, sorted by vertex. `grab_follow` then looks the vertex up (binary search, as
  `reach`) and uses `dist^2 * inv_r2` in place of the straight distance; a vertex not reached is skipped. It
  supersedes Connected (geodesic reach is joined by construction).
- `geodesic_reach`:
  1. Ball query (`bvh_query_leaves`, radius r): a geodesic distance under r implies a straight one under r, so the
     ball holds every vertex it can reach. Mark the inside vertices with a local index (reuse `s.connected.mark`
     stamps and `label` as the local index, so no new per-mesh array).
  2. Edges: each hit leaf's shown triangles with both corners inside give (a, b, |pa - pb|); collected per leaf on
     worker threads (heap allocator, as `job_connected_links` does), then one CSR adjacency in leaf order (order
     only changes relaxation order, never the distances).
  3. Seeds: the corners of the triangle the centre lies on (the same choice as `connected_flood`, nearest-vertex
     fallback), each at its straight distance from the centre.
  4. Dijkstra with a binary heap keyed by (distance, vertex index), stopping past r. Serial; the minimum over paths
     is the same float whatever order edges relax in, so serial and parallel callers agree bit for bit.
  Hidden triangles carry nothing (as Connected); masked vertices still carry the distance (the mask only weights).
- Same side, Silhouette and the press past the outline (2a) apply on top unchanged.
- Cost: once per grab press. Expect ~100k inside vertices for a large brush at 10M: a few ms to ~15 ms on the
  4-thread VM, measured with a bench row "Grab, topological" (begin time) at 1M and 10M next to plain Grab.

## App, files, UI
- `Brush_Settings.grab_topological`, setting `grab_topological`; switch "Topological" in Grab's Options section
  (beside All depth; greys out while All depth is on, as Connected only does); glossary entry.
- Built-in preset "Move topological" (Grab + topological), next to "Move all depth".
- Presets: one more field after the Grab group (line length 31). `.strokes` version 17: one more byte.
- README: Grab modes paragraph, settings list, .strokes versions.

## Tests
- sculpt: a U-shaped strip (two prongs joined at the base, prong tips 0.3 r apart): plain Grab moves both tips,
  topological moves only the pressed one, and the weight at a vertex equals falloff(geodesic/r) computed by hand on
  a straight strip; serial == parallel positions bit for bit.
- app: preset and `.strokes` round trip; touch scenario: Move topological preset on two spheres... (or the U strip
  via a script) with a screenshot.

## Left out
Heat-method geodesics (smoother than edge Dijkstra on coarse meshes); edge Dijkstra overestimates on diagonals by up
to ~8% on regular meshes, which only softens the falloff slightly. Topological for Snake hook and Elastic (2c, 2d
may reuse `geodesic_reach`).
