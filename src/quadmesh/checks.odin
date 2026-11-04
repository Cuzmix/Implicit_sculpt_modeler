package quadmesh

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"

// What each stage gave, measured where the driver hands it on (driver.odin): the numbers
// the tests assert on and the log line carries (checks_line), so a change to a stage
// shows in numbers before anyone looks at a picture. Summed over the islands, but for the
// smallest angle and the largest spread, which are the worst island's. Only the Odin
// driver fills them; qm_remesh's are zero.
Checks :: struct {
	islands:             int,
	thin_triangles:      int, // the islands' triangles after the thinning
	thin_decimated:      int, // islands the thinning decimated
	thin_unpinched:      int, // vertices it split off pinches
	thin_open_edges:     int, // edges of one triangle in what the thinning gave
	thin_nonmanifold:    int, // and of three or more
	iso_triangles:       int,
	iso_open_edges:      int, // edges of one triangle
	iso_nonmanifold:     int, // edges of three or more
	iso_euler:           int, // vertices less edges plus triangles: what the quads should keep
	iso_split_fans:      int, // the Odin remesh's: vertices added where a vertex joined fans of triangles (a pinch)
	iso_torn_edges:      int, // and edges of three or more triangles, or of two running the same way, cut into borders
	iso_dropped:         int, // and triangles that repeated a vertex, dropped
	iso_capped:          int, // islands whose splits stopped at the cap
	iso_min_angle:       f64, // degrees: the smallest corner of any triangle
	iso_edge_spread:     f64, // the edges' standard deviation over their mean
	covers:              int, // covers solved
	cover_singular:      int, // the frame field's singular vertices, in the covers kept
	cover_flipped:       int, // triangles the kept covers turn over: folds
	cover_cells:         f64, // the kept covers' area in cells, signed, so folds take away
	cover_cells_abs:     f64, // and unsigned
	cover_cells_wanted:  f64, // what the count asks of the triangles off the caps
	quad_faces:          int,
	quad_quads:          int,
	quad_triangles:      int,
	quad_ngons:          int,
	quad_open_edges:     int, // edges of one polygon
	quad_nonmanifold:    int, // edges of three or more
	quad_valence:        [7]int, // vertices by the polygons meeting there, six or more in the last
	quad_euler:          int, // vertices less edges plus faces: the input's, 2 for a closed sphere, when nothing was lost
	// The Odin extraction's own (extract.odin); zero from the C++'s.
	extract_points:      int, // the cover's grid points, each a quad vertex
	extract_holes:       int, // triangles it went round: turned over, flat, or beside a seam that does not close
	extract_open_seams:  int, // edges whose triangles' charts do not meet
	extract_unmatched:   int, // quad edges whose trace found no partner
	extract_filled:      int, // faces of more than four sides filled with quads
	extract_patched:     int, // of those, the ones filled with their own grid cells (the rest cut in a ladder or a fan)
	extract_dropped:     int, // cycles of no area (an edge walked there and back) dropped
	extract_bad_cuts:    int, // faces no cut could fill without joining a corner to itself twice
	extract_largest_cut: int, // the most sides a face cut into quads had (the largest over the islands)
}

// The sums of two islands' checks.
checks_add :: proc(to: ^Checks, c: Checks) {
	angle := c.iso_min_angle if to.islands == 0 else min(to.iso_min_angle, c.iso_min_angle)
	spread := max(to.iso_edge_spread, c.iso_edge_spread)
	to.islands += c.islands
	to.thin_triangles += c.thin_triangles
	to.thin_decimated += c.thin_decimated
	to.thin_unpinched += c.thin_unpinched
	to.thin_open_edges += c.thin_open_edges
	to.thin_nonmanifold += c.thin_nonmanifold
	to.iso_triangles += c.iso_triangles
	to.iso_open_edges += c.iso_open_edges
	to.iso_nonmanifold += c.iso_nonmanifold
	to.iso_euler += c.iso_euler
	to.iso_split_fans += c.iso_split_fans
	to.iso_torn_edges += c.iso_torn_edges
	to.iso_dropped += c.iso_dropped
	to.iso_capped += c.iso_capped
	to.iso_min_angle, to.iso_edge_spread = angle, spread
	to.covers += c.covers
	to.cover_singular += c.cover_singular
	to.cover_flipped += c.cover_flipped
	to.cover_cells += c.cover_cells
	to.cover_cells_abs += c.cover_cells_abs
	to.cover_cells_wanted += c.cover_cells_wanted
	to.quad_faces += c.quad_faces
	to.quad_quads += c.quad_quads
	to.quad_triangles += c.quad_triangles
	to.quad_ngons += c.quad_ngons
	to.quad_open_edges += c.quad_open_edges
	to.quad_nonmanifold += c.quad_nonmanifold
	for n, i in c.quad_valence do to.quad_valence[i] += n
	to.quad_euler += c.quad_euler
	to.extract_points += c.extract_points
	to.extract_holes += c.extract_holes
	to.extract_open_seams += c.extract_open_seams
	to.extract_unmatched += c.extract_unmatched
	to.extract_filled += c.extract_filled
	to.extract_patched += c.extract_patched
	to.extract_dropped += c.extract_dropped
	to.extract_bad_cuts += c.extract_bad_cuts
	to.extract_largest_cut = max(to.extract_largest_cut, c.extract_largest_cut)
}

// The checks as key=value pairs on one line, in temp memory. `cells_lost` is the share of
// the covers' cells that came out as no polygon.
checks_line :: proc(c: Checks) -> string {
	lost := 100 * (c.cover_cells_abs - f64(c.quad_faces)) / c.cover_cells_abs if c.cover_cells_abs > 0 else 0
	// A share that rounds to nothing reads as 0.0 rather than -0.0.
	if abs(lost) < 0.05 do lost = 0
	vertices := 0
	for n in c.quad_valence do vertices += n
	regular := 100 * f64(c.quad_valence[4]) / f64(vertices) if vertices > 0 else 0
	return fmt.tprintf("islands=%d thin_triangles=%d thin_decimated=%d thin_unpinched=%d thin_open=%d thin_nonmanifold=%d iso_triangles=%d iso_open=%d iso_nonmanifold=%d iso_euler=%d iso_split_fans=%d iso_torn_edges=%d iso_dropped=%d iso_capped=%d iso_min_angle=%.2f iso_edge_spread=%.3f covers=%d cover_singular=%d cover_flipped=%d cover_cells=%.1f cover_cells_abs=%.1f cover_cells_wanted=%.1f quad_faces=%d quad_quads=%d quad_triangles=%d quad_ngons=%d quad_open=%d quad_nonmanifold=%d quad_valence=%d,%d,%d,%d,%d,%d quad_regular=%.1f%% quad_euler=%d cells_lost=%.1f%% extract_points=%d extract_holes=%d extract_open_seams=%d extract_unmatched=%d extract_filled=%d extract_patched=%d extract_dropped=%d extract_bad_cuts=%d extract_largest_cut=%d",
		c.islands, c.thin_triangles, c.thin_decimated, c.thin_unpinched, c.thin_open_edges, c.thin_nonmanifold, c.iso_triangles, c.iso_open_edges, c.iso_nonmanifold, c.iso_euler, c.iso_split_fans, c.iso_torn_edges, c.iso_dropped, c.iso_capped, c.iso_min_angle, c.iso_edge_spread,
		c.covers, c.cover_singular, c.cover_flipped, c.cover_cells, c.cover_cells_abs, c.cover_cells_wanted,
		c.quad_faces, c.quad_quads, c.quad_triangles, c.quad_ngons, c.quad_open_edges, c.quad_nonmanifold,
		c.quad_valence[1], c.quad_valence[2], c.quad_valence[3], c.quad_valence[4], c.quad_valence[5], c.quad_valence[6], regular, c.quad_euler, lost,
		c.extract_points, c.extract_holes, c.extract_open_seams, c.extract_unmatched, c.extract_filled, c.extract_patched, c.extract_dropped, c.extract_bad_cuts, c.extract_largest_cut)
}

// What the thinning gave: its open and non-manifold edges.
checks_thin :: proc(c: ^Checks, thin: Island) {
	heap := runtime.heap_allocator()
	c.thin_triangles = len(thin.triangles)
	keys := make([]u64, 3 * len(thin.triangles), heap)
	defer delete(keys, heap)
	for t, f in thin.triangles do for k in 0 ..< 3 {
		a, b := t[k], t[(k + 1) % 3]
		keys[3 * f + k] = u64(min(a, b)) << 32 | u64(max(a, b))
	}
	c.thin_open_edges, c.thin_nonmanifold, _ = edge_counts(keys)
}

// The isotropic mesh: its open and non-manifold edges, its smallest angle and how evenly
// its edges are sized.
checks_isotropic :: proc(c: ^Checks, iso: Isotropic) {
	heap := runtime.heap_allocator()
	c.iso_triangles = len(iso.triangles)
	keys := make([]u64, 3 * len(iso.triangles), heap)
	defer delete(keys, heap)
	smallest := f64(180)
	for t, f in iso.triangles {
		for k in 0 ..< 3 {
			a, b := t[k], t[(k + 1) % 3]
			keys[3 * f + k] = u64(min(a, b)) << 32 | u64(max(a, b))
			p, q, r := iso.positions[a], iso.positions[b], iso.positions[t[(k + 2) % 3]]
			// The angle at p between p to q and p to r.
			u, v := q - p, r - p
			lu, lv := math.sqrt(u.x * u.x + u.y * u.y + u.z * u.z), math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
			if lu > 0 && lv > 0 {
				cosine := clamp((u.x * v.x + u.y * v.y + u.z * v.z) / (lu * lv), -1, 1)
				smallest = min(smallest, math.acos(cosine) * 180 / math.PI)
			} else {
				smallest = 0
			}
		}
	}
	c.iso_min_angle = smallest
	edges: int
	c.iso_open_edges, c.iso_nonmanifold, edges = edge_counts(keys)
	c.iso_euler = len(iso.positions) - edges + len(iso.triangles)
	// Each edge once: its length's mean and spread.
	sum, squares, n := f64(0), f64(0), 0
	for i := 0; i < len(keys); i += 1 {
		if i > 0 && keys[i] == keys[i - 1] do continue
		a, b := iso.positions[keys[i] >> 32], iso.positions[keys[i] & 0xffffffff]
		e := b - a
		l := math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z)
		sum += l
		squares += l * l
		n += 1
	}
	if n > 0 && sum > 0 {
		mean := sum / f64(n)
		c.iso_edge_spread = math.sqrt(max(0, squares / f64(n) - mean * mean)) / mean
	}
}

// The cover kept: its singular vertices, its folds and its area in cells.
checks_cover :: proc(c: ^Checks, iso: Isotropic, cover: Cover, cells_wanted: f64) {
	c.cover_singular = len(cover.singular)
	c.cover_cells_wanted = cells_wanted
	for t in cover.uvs {
		signed := 0.5 * ((t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1]))
		if signed < 0 do c.cover_flipped += 1
		c.cover_cells += signed
		c.cover_cells_abs += abs(signed)
	}
}

// The quads: their sides, their open and non-manifold edges and their vertices' valence.
checks_quads :: proc(c: ^Checks, q: Quads) {
	if len(q.first) < 2 do return
	heap := runtime.heap_allocator()
	c.quad_faces = len(q.first) - 1
	keys := make([]u64, len(q.corners), heap)
	defer delete(keys, heap)
	valence := make([]int, len(q.positions), heap)
	defer delete(valence, heap)
	for f in 0 ..< len(q.first) - 1 {
		from, to := q.first[f], q.first[f + 1]
		switch to - from {
		case 4: c.quad_quads += 1
		case 3: c.quad_triangles += 1
		case: c.quad_ngons += 1
		}
		for k in from ..< to {
			a, b := q.corners[k], q.corners[k + 1 if k + 1 < to else from]
			keys[k] = u64(min(a, b)) << 32 | u64(max(a, b))
			valence[a] += 1
		}
	}
	edges: int
	c.quad_open_edges, c.quad_nonmanifold, edges = edge_counts(keys)
	used := 0
	for n in valence {
		c.quad_valence[min(n, len(c.quad_valence) - 1)] += 1
		if n > 0 do used += 1
	}
	c.quad_euler = used - edges + c.quad_faces
}

// How many of the edges (sorted here) one face has, how many three or more, and how many
// edges there are.
@(private = "file")
edge_counts :: proc(keys: []u64) -> (open, nonmanifold, edges: int) {
	slice.sort(keys)
	for i := 0; i < len(keys); {
		j := i + 1
		edges += 1
		for j < len(keys) && keys[j] == keys[i] do j += 1
		switch j - i {
		case 1: open += 1
		case 2:
		case: nonmanifold += 1
		}
		i = j
	}
	return
}
