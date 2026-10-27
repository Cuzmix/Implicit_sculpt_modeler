package sculpt

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Masks made from the surface itself, as the reference app's Mask by list: each shown
// vertex gets a measure from 0 to 1 (how much of a peak it is, how far from the viewer,
// how red its paint), shaped by a profile curve, then the mask may be blurred, all as one
// undo step. Mask adjust reshapes the mask as it is through a curve; Mask region
// (Mask_Command.Region) fills the parts a closed outline of mask cuts off. Hidden
// vertices keep their mask throughout.

Mask_By :: enum u8 {
	Peaks,            // crests: how far a vertex stands above its neighbours
	Curvature,        // how sharply the surface bends, either way
	Smoothness,       // how flat it is: the opposite of Curvature
	Depth,            // nearness to the viewer: the nearest vertex fully, the farthest not at all
	Facing_Away,      // how far a vertex's normal turns from the viewer: away fully, edge-on half
	Color_Intensity,  // how light the polypaint is, as far as it covers the clay
	Color_Hue,        // how near the polypaint's hue is to Mask_By_Options.hue
	Color_Saturation, // how vivid the polypaint is
	Open_Borders,     // the edges of holes and of the shown part
	Group_Borders,    // where polygroups meet
	Creases,          // edges sharper than Mask_By_Options.angle
}

Mask_By_Options :: struct {
	// Peaks, Curvature, Smoothness: how strongly the shape counts, 0 to 1, a quarter to
	// four times the gain Mask cavities uses, which 0.5 is.
	strength: f32,
	curve:    geom.Curve, // the profile: the mask is the curve at the measure
	blur:     int, // Blur steps after, in the same undo step
	view:     Front_Only, // Depth, Facing_Away: where the viewer is (`on` is not read)
	hue:      [3]u8, // Color_Hue: the colour whose hue masks fully, sRGB
	width:    f32, // Color_Hue: how far round the hue circle the mask falls to nothing, 0 to 0.5
	angle:    f32, // Creases: degrees between two triangles' normals that make a crease
}

// The default curve and options: a straight profile, no blur, cavities' gain.
MASK_BY_DEFAULT :: Mask_By_Options {
	strength = 0.5,
	curve    = geom.CURVE_LINEAR,
	width    = 0.1,
	angle    = 35,
}

// Masks the shown surface by `by` as one undo step. Returns true when it changed the
// mask; false too with nothing to go on: no polypaint for the colour kinds, no groups for
// Group_Borders, a grey colour for Color_Hue. Ends any stroke in progress first.
sculptor_mask_by :: proc(s: ^Sculptor, by: Mask_By, o: Mask_By_Options) -> bool {
	_ = sculptor_stroke_end(s)
	switch by {
	case .Color_Intensity, .Color_Hue, .Color_Saturation:
		if s.color == nil do return false
		if by == .Color_Hue {
			_, saturation := color_hue_saturation(o.hue)
			if saturation < GREY_SATURATION do return false
		}
	case .Group_Borders:
		if s.groups.tris == nil do return false
	case .Peaks, .Curvature, .Smoothness, .Depth, .Facing_Away, .Open_Borders, .Creases:
	}
	mask_ensure(s)
	job := By_Job {
		s       = s,
		by      = by,
		o       = o,
		table   = curve_table(o.curve),
		after   = slice.clone(s.mask, context.temp_allocator),
		changes = make([]bool, len(s.nodes), context.temp_allocator),
		gain    = CAVITY_GAIN * math.pow(f32(4), 2 * clamp(o.strength, 0, 1) - 1),
		cos     = math.cos(math.to_radians(clamp(o.angle, 1, 179))),
	}
	job.hue, _ = color_hue_saturation(o.hue)
	if by == .Depth {
		// The nearest and farthest shown vertex along the view, node by node, then all.
		near := make([][2]f32, len(s.nodes), context.temp_allocator)
		job.range = near
		jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
			job := cast(^By_Job)data
			for id in lo ..< hi {
				r := [2]f32{max(f32), -max(f32)}
				n := job.s.nodes[id]
				for v in n.vert_first ..< n.vert_first + n.vert_count {
					if vertex_hidden(job.s, v) do continue
					d := view_depth(job, v)
					r = {min(r[0], d), max(r[1], d)}
				}
				job.range[id] = r
			}
		}, NODE_GRAIN)
		job.lo, job.hi = max(f32), -max(f32)
		for r in near do job.lo, job.hi = min(job.lo, r[0]), max(job.hi, r[1])
		if job.lo > job.hi do return false
	}
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^By_Job)data
		for id in lo ..< hi {
			n := job.s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				if vertex_hidden(job.s, v) do continue
				x := clamp(mask_measure(job, v), 0, 1)
				job.after[v] = u8(job.table[int(x * 255 + 0.5)] * 255 + 0.5)
			}
			job.changes[id] = true
		}
	}, NODE_GRAIN)
	return mask_commit_blurred(s, job.after, job.changes, o.blur)
}

// Reshapes the mask as it is through `curve` (0 to 1 in, 0 to 1 out), then blurs it `blur`
// steps, as one undo step: a steeper curve hardens a soft edge and one above the diagonal
// strengthens a partial mask (an unmasked vertex stays unmasked, as every curve starts at
// 0). Returns true when it changed the mask.
sculptor_mask_adjust :: proc(s: ^Sculptor, curve: geom.Curve, blur: int) -> bool {
	_ = sculptor_stroke_end(s)
	// The curve may lift 0, so there need not be a mask yet.
	mask_ensure(s)
	table := curve_table(curve)
	Job :: struct {
		s:       ^Sculptor,
		table:   [256]u8,
		after:   []u8,
		changes: []bool,
	}
	job := Job{s = s, after = slice.clone(s.mask, context.temp_allocator), changes = make([]bool, len(s.nodes), context.temp_allocator)}
	for y, i in table do job.table[i] = u8(y * 255 + 0.5)
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for id in lo ..< hi {
			n := job.s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				if vertex_hidden(job.s, v) do continue
				job.after[v] = job.table[job.after[v]]
			}
			job.changes[id] = true
		}
	}, NODE_GRAIN)
	return mask_commit_blurred(s, job.after, job.changes, blur)
}

// A colour whose saturation is under this has no hue to speak of.
@(private = "file")
GREY_SATURATION :: 0.1

@(private = "file")
By_Job :: struct {
	s:       ^Sculptor,
	by:      Mask_By,
	o:       Mask_By_Options,
	table:   [256]f32,
	after:   []u8,
	changes: []bool,
	gain:    f32, // Peaks, Curvature, Smoothness
	cos:     f32, // Creases: the cosine of the crease angle
	hue:     f32, // Color_Hue: the hue sought, 0 to 1
	range:   [][2]f32, // Depth: per node, its nearest and farthest shown vertex
	lo, hi:  f32, // Depth: the nearest and farthest of all
}

// The curve at 0, 1/255, ... 1: masks are bytes, so 256 places cover every value, and the
// curve is bisected once a place rather than once a vertex.
@(private = "file")
curve_table :: proc(curve: geom.Curve) -> (t: [256]f32) {
	for &y, i in t do y = geom.curve_at(curve, f32(i) / 255)
	return
}

// Vertex v's measure for the job's kind, about 0 to 1.
@(private = "file")
mask_measure :: proc(job: ^By_Job, v: u32) -> f32 {
	s := job.s
	switch job.by {
	case .Peaks, .Curvature, .Smoothness:
		depth, ok := cavity_depth(s, v)
		if !ok do return 0
		bend := clamp(abs(depth) * job.gain, 0, 1)
		if job.by == .Peaks do return -depth * job.gain
		return 1 - bend if job.by == .Smoothness else bend
	case .Depth:
		if job.hi <= job.lo do return 1
		return 1 - (view_depth(job, v) - job.lo) / (job.hi - job.lo)
	case .Facing_Away:
		return (1 - linalg.dot(s.mesh.normals[v], toward_viewer(job, v))) * 0.5
	case .Color_Intensity, .Color_Hue, .Color_Saturation:
		c := s.color[v]
		cover := f32(c.a) / 255
		hue, saturation := color_hue_saturation(c.rgb)
		#partial switch job.by {
		case .Color_Intensity:
			return (0.2126 * f32(c.r) + 0.7152 * f32(c.g) + 0.0722 * f32(c.b)) / 255 * cover
		case .Color_Saturation:
			return saturation * cover
		}
		// Hue matters only as far as the paint has one: full from a quarter saturation.
		apart := abs(hue - job.hue)
		apart = min(apart, 1 - apart)
		return clamp(1 - apart / max(job.o.width, 1e-3), 0, 1) * min(saturation * 4, 1) * cover
	case .Open_Borders, .Group_Borders, .Creases:
		return 1 if vertex_on_feature(job, v) else 0
	}
	return 0
}

// The way toward the viewer from vertex v, unit length: the view's own when parallel.
@(private = "file")
toward_viewer :: #force_inline proc(job: ^By_Job, v: u32) -> Vec3 {
	if job.o.view.parallel do return linalg.normalize0(job.o.view.toward)
	return linalg.normalize0(job.o.view.eye - job.s.mesh.positions[v])
}

// How far vertex v lies from the viewer along the view.
@(private = "file")
view_depth :: #force_inline proc(job: ^By_Job, v: u32) -> f32 {
	return linalg.dot(job.o.view.eye - job.s.mesh.positions[v], linalg.normalize0(job.o.view.toward))
}

// Hue (0 to 1 round the circle) and saturation (0 to 1) of an sRGB colour, as HSV has them.
@(private = "file")
color_hue_saturation :: proc(c: [3]u8) -> (hue, saturation: f32) {
	r, g, b := f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255
	hi, lo := max(r, g, b), min(r, g, b)
	if hi <= 0 do return 0, 0
	spread := hi - lo
	saturation = spread / hi
	if spread <= 0 do return 0, saturation
	switch hi {
	case r: hue = (g - b) / spread
	case g: hue = 2 + (b - r) / spread
	case:   hue = 4 + (r - g) / spread
	}
	hue /= 6
	if hue < 0 do hue += 1
	return
}

// Whether vertex v is on one of the job's features: an edge of the shown triangles with
// only one of them (Open_Borders), triangles of more than one group (Group_Borders), or
// an edge between two shown triangles whose normals part by more than the angle (Creases).
@(private = "file")
vertex_on_feature :: proc(job: ^By_Job, v: u32) -> bool {
	s := job.s
	m := s.mesh
	hidden := sculptor_hidden_tris(s)
	faces := faces_of(s, v)
	shown :: #force_inline proc(hidden: []bool, f: u32) -> bool {return hidden == nil || !hidden[f]}
	if job.by == .Group_Borders {
		g := s.groups.tris
		first := -1
		for f in faces {
			if !shown(hidden, f) do continue
			if first < 0 do first = int(g[f])
			else if int(g[f]) != first do return true
		}
		return false
	}
	// Each other corner of v's shown triangles ends an edge from v; the triangles holding
	// that edge are those of v's that hold the corner too.
	for f in faces {
		if !shown(hidden, f) do continue
		for c in 0 ..< u32(3) {
			a := m.indices[3 * f + c]
			if a == v do continue
			count := 0
			other := f
			for e in faces {
				if !shown(hidden, e) do continue
				if m.indices[3 * e] == a || m.indices[3 * e + 1] == a || m.indices[3 * e + 2] == a {
					count += 1
					if e != f do other = e
				}
			}
			if job.by == .Open_Borders {
				if count == 1 do return true
				continue
			}
			if count == 2 && linalg.dot(face_normal(m, f), face_normal(m, other)) < job.cos do return true
		}
	}
	return false
}

@(private = "file")
face_normal :: #force_inline proc(m: ^geom.Mesh, f: u32) -> Vec3 {
	a, b, c := m.positions[m.indices[3 * f]], m.positions[m.indices[3 * f + 1]], m.positions[m.indices[3 * f + 2]]
	return linalg.normalize0(linalg.cross(b - a, c - a))
}

// Mask region: on each piece of the shown surface (joined through shown triangles) that
// holds a masked vertex, the unmasked parts (joined through triangles whose corners are
// all unmasked) are found, and every one but the largest by area is masked fully, so an
// outline drawn closed fills on its smaller side and a piece with no mask is left alone.
// Ties of area go to the part with the lowest vertex. One undo step; false when nothing
// was cut off. The parts are joined node by node in parallel and then across nodes with
// the lower root winning, so the result does not depend on the threads.
@(private)
mask_region :: proc(s: ^Sculptor) -> bool {
	n := len(s.mesh.positions)
	Job :: struct {
		s:      ^Sculptor,
		piece:  []u32, // per vertex: the union-find label of its piece of the surface
		part:   []u32, // ...and of its unmasked part
		links:  [][dynamic][2][2]u32, // per node: {piece, part} joins across nodes; part {max, max} for none
	}
	job := Job {
		s     = s,
		piece = make([]u32, n, context.temp_allocator),
		part  = make([]u32, n, context.temp_allocator),
		links = make([][dynamic][2][2]u32, len(s.nodes), context.temp_allocator),
	}
	for &l in job.links do l = make([dynamic][2][2]u32, runtime.heap_allocator())
	defer for l in job.links do delete(l)
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for id in lo ..< hi {
			n := job.s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count do job.piece[v], job.part[v] = v, v
		}
	}, NODE_GRAIN)
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		s := job.s
		m := s.mesh
		hidden := sculptor_hidden_tris(s)
		NONE :: [2]u32{max(u32), max(u32)}
		for id in lo ..< hi {
			nd := s.nodes[id]
			first, last := nd.vert_first, nd.vert_first + nd.vert_count
			for f in nd.tri_first ..< nd.tri_first + nd.tri_count {
				if hidden != nil && hidden[f] do continue
				corners := [3]u32{m.indices[3 * f], m.indices[3 * f + 1], m.indices[3 * f + 2]}
				// An unused slot under dynamic topology: three times the same corner.
				if corners[0] == corners[1] do continue
				open := s.mask[corners[0]] < MASK_HALF && s.mask[corners[1]] < MASK_HALF && s.mask[corners[2]] < MASK_HALF
				for k in 0 ..< 3 {
					a, b := corners[k], corners[(k + 1) % 3]
					if a < first || a >= last || b < first || b >= last {
						append(&job.links[id], [2][2]u32{{a, b}, {a, b} if open else NONE})
						continue
					}
					region_join(job.piece, a, b)
					if open do region_join(job.part, a, b)
				}
			}
		}
	}, NODE_GRAIN)
	for l in job.links {
		for e in l {
			region_join(job.piece, e[0][0], e[0][1])
			if e[1][0] != max(u32) do region_join(job.part, e[1][0], e[1][1])
		}
	}
	// The area of each unmasked part, a third of each triangle to each corner's part, in
	// the triangles' order, and whether each piece holds some mask.
	area := make([]f64, n, context.temp_allocator)
	masked := make([]bool, n, context.temp_allocator)
	m := s.mesh
	hidden := sculptor_hidden_tris(s)
	for nd in s.nodes {
		for v in nd.vert_first ..< nd.vert_first + nd.vert_count {
			if !vertex_hidden(s, v) && s.mask[v] >= MASK_HALF do masked[region_root(job.piece, v)] = true
		}
		for f in nd.tri_first ..< nd.tri_first + nd.tri_count {
			if hidden != nil && hidden[f] do continue
			a, b, c := m.indices[3 * f], m.indices[3 * f + 1], m.indices[3 * f + 2]
			if a == b do continue
			third := f64(linalg.length(linalg.cross(m.positions[b] - m.positions[a], m.positions[c] - m.positions[a]))) / 6
			for v in ([3]u32{a, b, c}) do if s.mask[v] < MASK_HALF do area[region_root(job.part, v)] += third
		}
	}
	// The largest part of each masked piece, by its root; vertices in order, so ties go to
	// the lowest root.
	largest := make([]u32, n, context.temp_allocator)
	slice.fill(largest, max(u32))
	for nd in s.nodes {
		for v in nd.vert_first ..< nd.vert_first + nd.vert_count {
			if vertex_hidden(s, v) || s.mask[v] >= MASK_HALF || region_root(job.part, v) != v do continue
			p := region_root(job.piece, v)
			if !masked[p] do continue
			if largest[p] == max(u32) || area[v] > area[largest[p]] do largest[p] = v
		}
	}
	after := slice.clone(s.mask, context.temp_allocator)
	changes := make([]bool, len(s.nodes), context.temp_allocator)
	for nd, id in s.nodes {
		for v in nd.vert_first ..< nd.vert_first + nd.vert_count {
			if vertex_hidden(s, v) || s.mask[v] >= MASK_HALF do continue
			p := region_root(job.piece, v)
			if !masked[p] || region_root(job.part, v) == largest[p] do continue
			after[v] = 255
			changes[id] = true
		}
	}
	return mask_commit_values(s, after, changes)
}

// Joins the union-find sets of a and b, the lower root winning: in the parallel pass only
// for two vertices the node at work owns, whose labels no other thread touches.
@(private = "file")
region_join :: #force_inline proc(label: []u32, a, b: u32) {
	ra, rb := region_root(label, a), region_root(label, b)
	if ra < rb do label[rb] = ra
	else if rb < ra do label[ra] = rb
}

// The root of v's set, halving the path on the way.
@(private = "file")
region_root :: #force_inline proc(label: []u32, v: u32) -> u32 {
	x := v
	for label[x] != x {
		label[x] = label[label[x]]
		x = label[x]
	}
	return x
}
