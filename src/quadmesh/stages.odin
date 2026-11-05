package quadmesh

import "base:runtime"

import "../jobs"

// What the stages hand each other (driver.odin): an island of the input, the isotropic
// mesh, a quad cover and the quads. Positions are f64, as AutoRemesher keeps them, so a
// stage's output goes into the next unchanged. Everything here is made and freed with
// runtime.heap_allocator(), since islands run on threads of their own.

// An island of the input: one connected piece, its vertices numbered from 0.
Island :: struct {
	positions: [][3]f64,
	triangles: [][3]u32,
	features:  [][2]u32, // feature edges, two vertex indices each (Params.features)
	density:   []f64, // quads per area relative to the mean, one a vertex, or nil (Params.density)
	refine:    []f64, // the isotropic edge's share, one a vertex, or nil (Params.refine)
}

// The isotropic remesh of an island: the triangles the cover is solved on.
Isotropic :: struct {
	positions:      [][3]f64,
	triangles:      [][3]u32,
	vertex_scale:   []f64, // the quad size the density asks, one a vertex, or nil
	corner_feature: []u8, // three a triangle: 1 where the edge from that corner to the next is a feature edge; nil for none
	mean_edge:      f64, // the mean edge length, which the cover's scaling multiplies
}

// One quad cover: a UV per triangle corner, three a triangle, and the frame field's
// singular vertices.
Cover :: struct {
	uvs:      [][3][2]f64,
	singular: []u32,
}

// The quads extracted from a cover: polygon p's corners are corners[first[p]:first[p + 1]].
Quads :: struct {
	positions: [][3]f64,
	first:     []u32,
	corners:   []u32,
}

island_destroy :: proc(m: ^Island) {
	a := runtime.heap_allocator()
	delete(m.positions, a)
	delete(m.triangles, a)
	delete(m.features, a)
	delete(m.density, a)
	delete(m.refine, a)
	m^ = {}
}

isotropic_destroy :: proc(m: ^Isotropic) {
	a := runtime.heap_allocator()
	delete(m.positions, a)
	delete(m.triangles, a)
	delete(m.vertex_scale, a)
	delete(m.corner_feature, a)
	m^ = {}
}

cover_destroy :: proc(c: ^Cover) {
	a := runtime.heap_allocator()
	delete(c.uvs, a)
	delete(c.singular, a)
	c^ = {}
}

quads_destroy :: proc(q: ^Quads) {
	a := runtime.heap_allocator()
	delete(q.positions, a)
	delete(q.first, a)
	delete(q.corners, a)
	q^ = {}
}

// How a stage ended.
Stage_Error :: enum u8 {
	None,
	Cancelled,
	Out_Of_Memory,
	Failed, // `Reason` says why
}

// A stage's reason for failing, kept in place so a thread of its own needs no allocator
// for it.
Reason :: struct {
	text: [REASON_MAX]u8,
}

reason_string :: proc(r: ^Reason) -> string {
	return string(cstring(raw_data(r.text[:])))
}

reason_set :: proc(r: ^Reason, text: string) {
	n := min(len(text), REASON_MAX - 1)
	copy(r.text[:n], text[:n])
	r.text[n] = 0
}

// How a stage runs: the threads its own loops may use, whether it stays on this thread
// (one island of several, whose threads are the parallelism), where its own 0..1 goes,
// and the pool the Odin stages' loops run on (nil: this thread alone).
Stage_Run :: struct {
	threads:  int,
	serial:   bool,
	progress: proc(tag: rawptr, fraction: f32) -> bool, // false cancels; nil for none
	tag:      rawptr,
	pool:     ^jobs.Pool,
}
