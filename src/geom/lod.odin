package geom

import "core:math/linalg"

// Error of a group that has no simplified triangles to draw.
LOD_NONE :: max(f32)

// One node of a mesh's simplification tree: neighbouring chunks, or smaller groups,
// with a simplified copy of their triangles. Vertices on the group's border never move
// in the copy, so it meets whatever is drawn next to it (chunks, or other groups'
// copies) exactly: any cut through the tree draws a closed surface.
Lod_Group :: struct {
	bounds:      Aabb, // of the full-detail triangles under the group
	cone_axis:   Vec3, // normal cone of the simplified triangles
	cone_cutoff: f32,
	// How far the simplified triangles may stray from the full-detail ones, in mesh
	// units; LOD_NONE when there are none to draw.
	error:       f32,
	first_index: u32, // the simplified triangles, in the simplified index buffer
	index_count: u32,
	child_first: u32, // children: Lod.units[child_first:][:child_count]
	child_count: u32,
	// Something under the group changed since it was built: its bounds, cone and
	// copy are out of date, so only its children may be drawn.
	stale:       bool,
}

// A mesh's simplification tree, as the renderer reads it. A unit is a chunk (below
// the number of chunks) or a group (the unit minus the number of chunks).
Lod :: struct {
	groups: []Lod_Group,
	units:  []u32,
	roots:  []u32,
}

Lod_Stats :: struct {
	units:    int, // chunks and groups considered
	frustum:  int, // ...culled because outside the view
	backface: int, // ...culled because facing away
	groups:   int, // groups drawn simplified
}

// Appends to `fine` the index ranges of the chunks to draw at full detail, and to
// `coarse` the simplified ranges of the groups that stray less than `max_error_px`
// pixels from the full mesh, skipping what lies outside the frustum of `clip` or faces
// away from `eye` (both in the mesh's space). `px_per_unit` is how many pixels one
// mesh unit covers seen from one unit away. Ranges adjacent in their buffer are merged.
// Units marked in `hidden` (one entry per unit, or nil) are left out: a hidden chunk is
// not drawn, and a hidden group never stands in for its children (whose hidden ones
// are left out in turn).
cull_lod :: proc(chunks: []Chunk, lod: Lod, clip: Mat4, eye: Vec3, px_per_unit, max_error_px: f32, fine, coarse: ^[dynamic]Index_Range, hidden: []bool = nil) -> (stats: Lod_Stats) {
	w := Lod_Walk {
		hidden    = hidden,
		chunks    = chunks,
		lod       = lod,
		planes    = frustum_planes(clip),
		eye       = eye,
		threshold = max_error_px / px_per_unit,
		fine      = fine,
		coarse    = coarse,
		stats     = &stats,
	}
	for root in lod.roots do lod_visit(&w, root)
	return
}

@(private = "file")
Lod_Walk :: struct {
	chunks:       []Chunk,
	lod:          Lod,
	planes:       [6][4]f32,
	eye:          Vec3,
	threshold:    f32, // largest error per unit of distance from the eye
	fine, coarse: ^[dynamic]Index_Range,
	stats:        ^Lod_Stats,
	hidden:       []bool,
}

@(private = "file")
lod_visit :: proc(w: ^Lod_Walk, unit: u32) {
	w.stats.units += 1
	hidden := w.hidden != nil && w.hidden[unit]
	if int(unit) < len(w.chunks) {
		if hidden do return
		c := w.chunks[unit]
		switch {
		case aabb_outside(&w.planes, c.bounds):
			w.stats.frustum += 1
		case chunk_backfacing(c, w.eye):
			w.stats.backface += 1
		case:
			append_range(w.fine, c.first_index, c.index_count)
		}
		return
	}
	g := w.lod.groups[int(unit) - len(w.chunks)]
	if !g.stale {
		if aabb_outside(&w.planes, g.bounds) {
			w.stats.frustum += 1
			return
		}
		if !hidden && g.error != LOD_NONE && g.error <= w.threshold * box_distance(g.bounds, w.eye) {
			if chunk_backfacing({bounds = g.bounds, cone_axis = g.cone_axis, cone_cutoff = g.cone_cutoff}, w.eye) {
				w.stats.backface += 1
			} else {
				append_range(w.coarse, g.first_index, g.index_count)
				w.stats.groups += 1
			}
			return
		}
	}
	for child in w.lod.units[g.child_first:][:g.child_count] do lod_visit(w, child)
}

// Distance from p to the nearest point of the box; 0 inside it.
box_distance :: #force_inline proc(b: Aabb, p: Vec3) -> f32 {
	return linalg.length(linalg.max(linalg.max(b.lo - p, p - b.hi), Vec3{}))
}
