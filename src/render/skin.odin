package render

import "../gpu"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "../geom"

// The detail skin (sculpt/skin.odin) on the GPU: per sample its normal, per triangle its
// edges and lead corner, read by the skinned pipeline's fragment shader to light each
// pixel by the skin's normal there instead of the mesh's (skin.frag.slang). The vertex
// shader pulls its vertex from the mesh's own buffers, since a pixel needs its triangle's
// number, which an indexed draw cannot give it.

// The skinned vertex shader's storage buffers: paint, indices, positions, normals.
SKIN_VERTEX_STORAGE :: 4
// The skinned fragment shader's: the samples' normals and the triangles' records.
SKIN_FRAGMENT_STORAGE :: 2
// The grid's vertex shader's (skin_tess.vert.slang): paint, indices, positions, normals,
// and the samples' normals, the triangles' records and the samples' heights.
SKIN_TESS_STORAGE :: 7

// Whether `item` draws with the skinned pipeline: its mesh has a skin uploaded and its
// buffers can be read as storage.
@(private)
draws_skinned :: proc(pipes: ^Mesh_Pipelines, item: Draw_Item) -> bool {
	mb := item.mesh
	return pipes.skinned != 0 && mb != nil && mb.skin_normals != 0 && mb.skin_tris != 0 && mb.storage
}

// A chunk is drawn as the skin's grid when the skin can move its outline there by at least
// this many pixels: below it, the flat triangles and the skin's normals look the same.
SKIN_TESS_PX :: 0.5
// The most small triangles an item draws as the grid in a frame; past it, the nearest
// chunks have it and the farther ones stay flat.
SKIN_TESS_BUDGET :: 4_000_000

// How many pixels the skin of `item` can move its outline by at a chunk whose bounds are
// `bounds`, seen from `eye` (the mesh's space) through `proj` onto a target `height`
// pixels tall.
@(private = "file")
skin_tess_px :: proc(item: Draw_Item, proj: Mat4, height: u32, eye: geom.Vec3, bounds: geom.Aabb) -> f32 {
	reach := item.mesh.skin_reach
	px_per_unit := proj[1, 1] * f32(height) / 2
	if proj[3, 3] == 1 do return reach * linalg.length(item.model[0].xyz) * px_per_unit
	d := linalg.length(eye - linalg.clamp(eye, bounds.lo, bounds.hi))
	return reach * px_per_unit / max(d, 1e-6)
}

// Whether any of `item`'s chunks is near enough to be drawn as its skin's grid, and the
// device can draw it so.
@(private)
skin_tess_near :: proc(r: ^Renderer, item: Draw_Item, proj: Mat4, height: u32, eye: geom.Vec3) -> bool {
	mb := item.mesh
	if mb == nil || mb.skin_heights == 0 || mb.skin_reach <= 0 || mb.skin_meta[0] < 2 || !mb.storage do return false
	if r.single.skin_tess == 0 || r.single.skinned == 0 || (r.multi.mesh != 0 && r.multi.skin_tess == 0) do return false
	for c in item.chunks do if c.index_count > 0 && skin_tess_px(item, proj, height, eye, c.bounds) >= SKIN_TESS_PX do return true
	return false
}

// Splits the visible runs prepare_draws found (Mesh_Buffers.visible) into the chunks drawn
// flat and those drawn as the skin's grid (Mesh_Buffers.tess_visible, as the vertices of a
// non-indexed draw: 3 S^2 for each triangle): the near ones, nearest first, within
// SKIN_TESS_BUDGET small triangles. Both lists stay in the chunks' order.
@(private)
skin_tess_split :: proc(r: ^Renderer, item: Draw_Item, proj: Mat4, height: u32, eye: geom.Vec3) {
	mb := item.mesh
	clear(&mb.tess_visible)
	S2 := mb.skin_meta[0] * mb.skin_meta[0]
	Near :: struct {
		chunk: int,
		d:     f32,
	}
	near := make([dynamic]Near, 0, 64, context.temp_allocator)
	run := 0
	for c, i in item.chunks {
		if c.index_count == 0 do continue
		for run < len(mb.visible) && mb.visible[run].first_index + mb.visible[run].index_count <= c.first_index do run += 1
		if run == len(mb.visible) do break
		v := mb.visible[run]
		if c.first_index < v.first_index do continue
		if u64(c.first_index + c.index_count) * u64(S2) > u64(max(u32)) do continue
		if skin_tess_px(item, proj, height, eye, c.bounds) < SKIN_TESS_PX do continue
		append(&near, Near{i, linalg.length(eye - linalg.clamp(eye, c.bounds.lo, c.bounds.hi))})
	}
	if len(near) == 0 do return
	slice.stable_sort_by(near[:], proc(a, b: Near) -> bool {return a.d < b.d})
	taken := make([]bool, len(item.chunks), context.temp_allocator)
	budget := u64(SKIN_TESS_BUDGET)
	for n in near {
		small := u64(item.chunks[n.chunk].index_count / 3) * u64(S2)
		if small > budget do break
		budget -= small
		taken[n.chunk] = true
	}
	// The flat runs again without the taken chunks.
	flat := make([dynamic]geom.Index_Range, 0, len(mb.visible), context.temp_allocator)
	run = 0
	for v in mb.visible {
		at := v.first_index
		end := v.first_index + v.index_count
		for at < end {
			// The chunk starting here, found by walking forward: chunks and runs share order.
			for run < len(item.chunks) && item.chunks[run].first_index + item.chunks[run].index_count <= at do run += 1
			if run == len(item.chunks) || item.chunks[run].first_index > at {
				append_run(&flat, at, end - at)
				break
			}
			c := item.chunks[run]
			stop := min(c.first_index + c.index_count, end)
			if taken[run] {
				append_run(&mb.tess_visible, at * S2, (stop - at) * S2)
			} else {
				append_run(&flat, at, stop - at)
			}
			at = stop
		}
	}
	clear(&mb.visible)
	append(&mb.visible, ..flat[:])

	append_run :: proc(out: ^[dynamic]geom.Index_Range, first, count: u32) {
		if count == 0 do return
		if n := len(out); n > 0 && out[n - 1].first_index + out[n - 1].index_count == first {
			out[n - 1].index_count += count
			return
		}
		append(out, geom.Index_Range{first, count})
	}
}

// Draws `item`'s triangles with the skinned pipeline (bound by the caller): the same
// visible runs draw_item_triangles draws, as non-indexed draws over the index positions,
// with the indexed commands read as non-indexed ones (their first four numbers are the
// count, one instance, the first position and a vertex offset of zero, which reads as the
// first instance). The mesh has no simplified copies (prepare_draws). Then the chunks
// skin_tess_split picked, as the skin's grid with `pipes`' skin_tess pipeline, which it
// leaves bound; returns whether it did.
@(private)
draw_skinned_item :: proc(r: ^Renderer, pass: gpu.Render_Pass, pipes: ^Mesh_Pipelines, item: Draw_Item, stats: ^Viewport_Stats) -> (tessellated: bool) {
	mb := item.mesh
	vertex := [SKIN_VERTEX_STORAGE]gpu.Buffer{mb.paint if mb.paint != 0 else r.no_paint, mb.indices, mb.positions, mb.normals}
	gpu.bind_vertex_storage_buffers(pass, 0, &vertex[0], len(vertex))
	fragment := [SKIN_FRAGMENT_STORAGE]gpu.Buffer{mb.skin_normals, mb.skin_tris}
	gpu.bind_fragment_storage_buffers(pass, 0, &fragment[0], len(fragment))
	STRIDE :: size_of(gpu.Indexed_Indirect_Draw)
	if mb.cull.culled && r.cull && len(item.chunks) > 0 && mb.indirect != 0 {
		gpu.draw_primitives_indirect_count(pass, mb.indirect, CULL_HEADER, mb.indirect, 0, mb.draw_count, STRIDE)
	} else if (r.cull || item.hidden != nil) && len(item.chunks) > 0 && mb.indirect != 0 {
		if mb.draw_count > 0 do gpu.draw_primitives_indirect(pass, mb.indirect, 0, mb.draw_count, STRIDE)
		if stats != nil {
			for v in mb.visible do stats.triangles += u64(v.index_count / 3)
			stats.draws += u64(mb.draw_count)
		}
		if mb.tess_draw_count == 0 || pipes.skin_tess == 0 do return
		gpu.bind_graphics_pipeline(pass, pipes.skin_tess)
		grid := [SKIN_TESS_STORAGE]gpu.Buffer{vertex[0], mb.indices, mb.positions, mb.normals, mb.skin_normals, mb.skin_tris, mb.skin_heights}
		gpu.bind_vertex_storage_buffers(pass, 0, &grid[0], len(grid))
		gpu.draw_primitives_indirect(pass, mb.indirect, (mb.draw_count + mb.lod_draw_count) * STRIDE, mb.tess_draw_count, STRIDE)
		if stats != nil {
			for v in mb.tess_visible[:mb.tess_draw_count] {
				stats.triangles += u64(v.index_count / 3)
				stats.skin_grid += u64(v.index_count / 3)
			}
			stats.draws += u64(mb.tess_draw_count)
		}
		return true
	} else {
		gpu.draw_primitives(pass, mb.index_count, 1, 0, 0)
		if stats == nil do return
		stats.triangles += u64(mb.index_count / 3)
		stats.draws += 1
	}
	return
}

// Gives the mesh a skin: `tris` per triangle its three edge references and lead corner,
// `normals` every sample's (sculpt.Skin.normals), over `segments` with `verts` vertices
// and `edges` edges. Replaces a skin it had. False on a GPU failure, with the mesh left
// without a skin, drawn by its own normals.
mesh_buffers_set_skin :: proc(r: ^Renderer, mb: ^Mesh_Buffers, tris: [][4]u32, normals: [][2]i16, heights: []f16, reach: f32, segments, verts, edges: u32) -> bool {
	mesh_buffers_drop_skin(r, mb)
	if !mb.storage || len(tris) == 0 || len(normals) == 0 || len(heights) != len(normals) do return false
	words := heights_packed(heights, {{0, u32(len(heights) + 1) / 2}}, context.temp_allocator)
	mb.skin_normals = gpu.create_buffer({usage = {.Graphics_Storage_Read}, size = u32(len(normals) * size_of([2]i16))})
	mb.skin_tris = gpu.create_buffer({usage = {.Graphics_Storage_Read}, size = u32(len(tris) * size_of([4]u32))})
	mb.skin_heights = gpu.create_buffer({usage = {.Graphics_Storage_Read}, size = u32(len(words) * size_of(u32))})
	ok := mb.skin_normals != 0 && mb.skin_tris != 0 && mb.skin_heights != 0
	ok = ok && upload_now(r, mb.skin_normals, slice.to_bytes(normals))
	ok = ok && upload_now(r, mb.skin_tris, slice.to_bytes(tris))
	ok = ok && upload_now(r, mb.skin_heights, slice.to_bytes(words))
	if !ok {
		log.errorf("detail skin upload failed: %s", gpu.last_error())
		mesh_buffers_drop_skin(r, mb)
		return false
	}
	gpu.set_buffer_name(mb.skin_normals, "skin normals")
	gpu.set_buffer_name(mb.skin_tris, "skin triangles")
	gpu.set_buffer_name(mb.skin_heights, "skin heights")
	mb.skin_meta = {segments, verts, edges}
	mb.skin_reach = reach
	mb.skin_samples = u32(len(normals))
	mb_touch(r, mb)
	return true
}

// Records the upload of the samples' normals and heights in `ranges`
// (sculpt.sculptor_skin_ranges), and how far the skin now strays at most.
mesh_buffers_upload_skin :: proc(r: ^Renderer, cmd: gpu.Cmd, mb: ^Mesh_Buffers, normals: [][2]i16, heights: []f16, reach: f32, ranges: []geom.Vertex_Range) {
	debug_group(cmd, "Skin upload", .Uploads)
	mb.skin_reach = reach
	if mb.skin_normals == 0 || len(ranges) == 0 do return
	if u32(len(normals)) != mb.skin_samples || len(heights) != len(normals) {
		log.errorf("detail skin upload: %d samples for a buffer of %d", len(normals), mb.skin_samples)
		return
	}
	// A packed normal is one u32, and a range of samples one of indices.
	words := slice.reinterpret([]u32, normals)
	if !upload_index_ranges(r, cmd, mb, mb.skin_normals, words, transmute([]geom.Index_Range)ranges) {
		log.errorf("detail skin upload failed: %s", gpu.last_error())
	}
	// The heights go two a word: each range widened to whole words, packed one after another.
	word_ranges := make([]geom.Index_Range, len(ranges), context.temp_allocator)
	for g, i in ranges do word_ranges[i] = {g.first / 2, (g.first + g.count + 1) / 2 - g.first / 2}
	packed := heights_packed(heights, word_ranges, context.temp_allocator)
	if !upload_index_ranges(r, cmd, mb, mb.skin_heights, packed, word_ranges, packed = true) {
		log.errorf("detail skin upload failed: %s", gpu.last_error())
	}
	mb_touch(r, mb)
}

// The words of `heights` in `words` (ranges of words, sample 2k in word k's low half), one
// range after another, in `allocator`; a last odd sample's word has a zero high half.
@(private = "file")
heights_packed :: proc(heights: []f16, words: []geom.Index_Range, allocator := context.allocator) -> []u32 {
	n := 0
	for w in words do n += int(w.index_count)
	out := make([]u32, n, allocator)
	at := 0
	for w in words {
		for k in w.first_index ..< w.first_index + w.index_count {
			lo := transmute(u16)heights[2 * k]
			hi := transmute(u16)heights[2 * k + 1] if int(2 * k + 1) < len(heights) else 0
			out[at] = u32(lo) | u32(hi) << 16
			at += 1
		}
	}
	return out
}

// Records the upload of every triangle's record again (their lead corners change with
// the polygroups).
mesh_buffers_upload_skin_tris :: proc(r: ^Renderer, cmd: gpu.Cmd, mb: ^Mesh_Buffers, tris: [][4]u32) {
	if mb.skin_tris == 0 do return
	words := slice.reinterpret([]u32, tris)
	whole := [1]geom.Index_Range{{0, u32(len(words))}}
	if !upload_index_ranges(r, cmd, mb, mb.skin_tris, words, whole[:]) {
		log.errorf("detail skin upload failed: %s", gpu.last_error())
	}
	mb_touch(r, mb)
}

// Takes the skin off the mesh, which draws by its own normals again. A frame in flight
// still drawing the skin keeps its buffers until it is done.
mesh_buffers_drop_skin :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	if mb.skin_normals != 0 do gpu.release_buffer(mb.skin_normals)
	if mb.skin_tris != 0 do gpu.release_buffer(mb.skin_tris)
	if mb.skin_heights != 0 do gpu.release_buffer(mb.skin_heights)
	mb.skin_normals, mb.skin_tris, mb.skin_heights, mb.skin_meta, mb.skin_samples, mb.skin_lead_stamp, mb.skin_stamp = 0, 0, 0, {}, 0, 0, 0
	mb.skin_reach, mb.tess_draw_count = 0, 0
	mb_touch(r, mb)
}

// A new version for the mesh's buffers, so what was drawn from them is drawn again.
@(private = "file")
mb_touch :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	r.last_version += 1
	mb.version = r.last_version
}
