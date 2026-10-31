package geom

import "core:slice"

import "../jobs"

// Keep symmetry for the tools that rebuild a mesh rather than move its vertices (Decimate,
// Quad Remesh): the part on the + side of each symmetry plane is cut off (mirror_cut),
// rebuilt alone with its cut as a seam that stays on the planes (mirror_seam, and
// Simplify_Guide.seam for a decimation), and mirrored back (mirror_polygons), so the
// result is its own mirror image whatever the rebuild did, as ZBrush's ZRemesher keeps
// symmetry. Remesh keeps it its own way, on a lattice even about the planes. The planes
// are a Remesh_Mirror: each axis set is the plane through `center` square to it.

// The part of `m` on the + side of each plane `mirror` names, cut along each in turn
// (mesh_slice) and with `close` capped flat on each, with where each of its vertices and
// triangles came from in `from` when asked (SLICE_NONE for a cap's). ok false, with
// nothing made, when no plane is named or one leaves the mesh wholly on one side: there
// is nothing to mirror across it.
mirror_cut :: proc(m: Mesh, mirror: Remesh_Mirror, close: bool, pool: ^jobs.Pool, allocator := context.allocator, from: ^Slice_From = nil) -> (half: Mesh, ok: bool) {
	half = m
	owned := false
	sources: Slice_From
	for a in 0 ..< 3 {
		if !mirror.axes[a] do continue
		normal: Vec3
		normal[a] = 1
		step: Slice_From
		front, back, cut := mesh_slice(half, mirror.center, normal, close, pool, allocator, &step if from != nil else nil)
		mesh_destroy(&back)
		if !cut {
			if owned do mesh_destroy(&half)
			slice_from_destroy(&sources)
			return {}, false
		}
		if from != nil {
			// Each step's sources are the step before's vertices and triangles.
			if owned {
				for &v in step.vertex do if v != SLICE_NONE do v = sources.vertex[v]
				for &t in step.triangle do if t != SLICE_NONE do t = sources.triangle[t]
			}
			slice_from_destroy(&sources)
			sources = step
		}
		if owned do mesh_destroy(&half)
		half, owned = front, true
	}
	if !owned do return {}, false
	if from != nil do from^ = sources
	return half, true
}

// Which planes of `mirror` each vertex of a cut half (mirror_cut without `close`) lies
// on as its seam: bit a for the plane across axis a when the vertex ends an open edge
// whose two ends both lie within `snap` of that plane. A vertex that only touches a plane
// (a surface meeting it at a point) or ends an open edge of a hole elsewhere gets none.
mirror_seam :: proc(half: Mesh, mirror: Remesh_Mirror, snap: f32, allocator := context.allocator) -> []u8 {
	n := len(half.positions)
	near := make([]u8, n, context.temp_allocator)
	defer delete(near, context.temp_allocator)
	for p, v in half.positions {
		for a in 0 ..< 3 do if mirror.axes[a] && abs(p[a] - mirror.center[a]) <= snap do near[v] |= 1 << u8(a)
	}
	// The edges with both ends near one plane, sorted by their ends: one met once is open.
	Edge :: struct {
		key:  u64,
		bits: u8,
	}
	edges := make([dynamic]Edge, 0, 1024, context.temp_allocator)
	defer delete(edges)
	ix := half.indices[:]
	for t := 0; t + 2 < len(ix); t += 3 {
		for c in 0 ..< 3 {
			a, b := ix[t + c], ix[t + (c + 1) % 3]
			if common := near[a] & near[b]; common != 0 do append(&edges, Edge{u64(min(a, b)) << 32 | u64(max(a, b)), common})
		}
	}
	slice.sort_by(edges[:], proc(x, y: Edge) -> bool {return x.key < y.key})
	planes := make([]u8, n, allocator)
	for i := 0; i < len(edges); {
		j := i + 1
		for j < len(edges) && edges[j].key == edges[i].key do j += 1
		if j - i == 1 {
			e := edges[i]
			planes[e.key >> 32] |= e.bits
			planes[e.key & 0xffff_ffff] |= e.bits
		}
		i = j
	}
	return planes
}

// Mirrors polygons (face f is corners[first[f]:first[f + 1]], counter-clockwise from
// outside) across each plane of `mirror` in turn, X then Y then Z. A vertex with the
// plane's bit in `planes` is on the seam: it is put exactly on the plane and both sides
// share it. Every other vertex gets a mirrored copy, which keeps its bits for the planes
// still to come, and every polygon a reversed copy over the copies, so a half whose open
// border is the seam comes out closed. A polygon whose corners all lie on one of the
// planes (flat in it, which its image would double) goes first, and vertices no polygon
// uses go last. `from` (each vertex's source, a copy its original's) and `face_from`
// (each polygon's), when given, follow: given empty they start as the vertices' and
// polygons' own numbers, given one per vertex or polygon they are carried as they are.
// Returns how many polygons went.
mirror_polygons :: proc(positions: ^[dynamic]Vec3, first, corners: ^[dynamic]u32, planes: ^[dynamic]u8, mirror: Remesh_Mirror, from: ^[dynamic]u32 = nil, face_from: ^[dynamic]u32 = nil) -> (dropped: int) {
	active: u8
	for a in 0 ..< 3 do if mirror.axes[a] do active |= 1 << u8(a)
	if from != nil && len(from) != len(positions) {
		resize(from, len(positions))
		for &f, v in from do f = u32(v)
	}
	// The flat polygons out, in place.
	faces := len(first) - 1
	given: []u32
	if face_from != nil {
		if len(face_from) == faces do given = slice.clone(face_from[:], context.temp_allocator)
		resize(face_from, 0)
	}
	defer delete(given, context.temp_allocator)
	kept_corners, kept := 0, 0
	for f in 0 ..< faces {
		lo, hi := int(first[f]), int(first[f + 1])
		common := active
		for k in lo ..< hi do common &= planes[corners[k]]
		if common != 0 {
			dropped += 1
			continue
		}
		for k in lo ..< hi {
			corners[kept_corners] = corners[k]
			kept_corners += 1
		}
		kept += 1
		first[kept] = u32(kept_corners)
		if face_from != nil do append(face_from, given[f] if given != nil else u32(f))
	}
	resize(corners, kept_corners)
	resize(first, kept + 1)

	for a in 0 ..< 3 {
		if !mirror.axes[a] do continue
		bit := u8(1) << u8(a)
		n := len(positions)
		twin := make([]u32, n, context.temp_allocator)
		defer delete(twin, context.temp_allocator)
		for v in 0 ..< n {
			if planes[v] & bit != 0 {
				positions[v][a] = mirror.center[a]
				twin[v] = u32(v)
				continue
			}
			q := positions[v]
			q[a] = 2 * mirror.center[a] - q[a]
			twin[v] = u32(len(positions))
			append(positions, q)
			append(planes, planes[v])
			if from != nil do append(from, from[v])
		}
		count := len(first) - 1
		for f in 0 ..< count {
			// Indexed, not sliced: the arrays grow under the loop.
			lo, hi := int(first[f]), int(first[f + 1])
			for k := hi - 1; k >= lo; k -= 1 do append(corners, twin[corners[k]])
			append(first, u32(len(corners)))
			if face_from != nil do append(face_from, face_from[f])
		}
	}

	// Only the vertices still used, in order.
	n := len(positions)
	remap := make([]u32, n, context.temp_allocator)
	defer delete(remap, context.temp_allocator)
	for c in corners do remap[c] = 1
	at: u32
	for v in 0 ..< n {
		if remap[v] == 0 do continue
		remap[v] = at
		positions[at] = positions[v]
		planes[at] = planes[v]
		if from != nil do from[at] = from[v]
		at += 1
	}
	resize(positions, int(at))
	resize(planes, int(at))
	if from != nil do resize(from, int(at))
	for &c in corners do c = remap[c]
	return
}

// mirror_polygons for a triangle mesh: its normals left zero for the sculptor to
// compute, and `tri_from` each triangle's number before.
mesh_mirror :: proc(m: ^Mesh, planes: ^[dynamic]u8, mirror: Remesh_Mirror, from: ^[dynamic]u32 = nil, tri_from: ^[dynamic]u32 = nil) -> (dropped: int) {
	first := make([dynamic]u32, len(m.indices) / 3 + 1)
	defer delete(first)
	for &f, i in first do f = u32(3 * i)
	dropped = mirror_polygons(&m.positions, &first, &m.indices, planes, mirror, from, tri_from)
	resize(&m.normals, len(m.positions))
	slice.zero(m.normals[:])
	return
}
