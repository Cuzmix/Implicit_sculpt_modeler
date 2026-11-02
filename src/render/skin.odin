package render

import "core:log"
import "core:slice"
import "../geom"
import sdl "vendor:sdl3"

// The detail skin (sculpt/skin.odin) on the GPU: per sample its normal, per triangle its
// edges and lead corner, read by the skinned pipeline's fragment shader to light each
// pixel by the skin's normal there instead of the mesh's (skin.frag.slang). The vertex
// shader pulls its vertex from the mesh's own buffers, since a pixel needs its triangle's
// number, which an indexed draw cannot give it.

// The skinned vertex shader's storage buffers: paint, indices, positions, normals.
SKIN_VERTEX_STORAGE :: 4
// The skinned fragment shader's: the samples' normals and the triangles' records.
SKIN_FRAGMENT_STORAGE :: 2

// Whether `item` draws with the skinned pipeline: its mesh has a skin uploaded and its
// buffers can be read as storage.
@(private)
draws_skinned :: proc(pipes: ^Mesh_Pipelines, item: Draw_Item) -> bool {
	mb := item.mesh
	return pipes.skinned != nil && mb != nil && mb.skin_normals != nil && mb.skin_tris != nil && mb.storage
}

// Draws `item`'s triangles with the skinned pipeline (bound by the caller): the same
// visible runs draw_item_triangles draws, as non-indexed draws over the index positions,
// with the indexed commands read as non-indexed ones (their first four numbers are the
// count, one instance, the first position and a vertex offset of zero, which reads as the
// first instance). The mesh has no simplified copies (prepare_draws).
@(private)
draw_skinned_item :: proc(r: ^Renderer, pass: ^sdl.GPURenderPass, item: Draw_Item, stats: ^Viewport_Stats) {
	mb := item.mesh
	vertex := [SKIN_VERTEX_STORAGE]^sdl.GPUBuffer{mb.paint if mb.paint != nil else r.no_paint, mb.indices, mb.positions, mb.normals}
	gpu_bind_vertex_storage_buffers(pass, 0, &vertex[0], len(vertex))
	fragment := [SKIN_FRAGMENT_STORAGE]^sdl.GPUBuffer{mb.skin_normals, mb.skin_tris}
	gpu_bind_fragment_storage_buffers(pass, 0, &fragment[0], len(fragment))
	STRIDE :: size_of(sdl.GPUIndexedIndirectDrawCommand)
	if mb.cull.culled && r.cull && len(item.chunks) > 0 && mb.indirect != nil {
		gpu_draw_primitives_indirect_count(pass, mb.indirect, CULL_HEADER, mb.indirect, 0, mb.draw_count, STRIDE)
	} else if (r.cull || item.hidden != nil) && len(item.chunks) > 0 && mb.indirect != nil {
		if mb.draw_count > 0 do gpu_draw_primitives_indirect(pass, mb.indirect, 0, mb.draw_count, STRIDE)
		if stats == nil do return
		for v in mb.visible do stats.triangles += u64(v.index_count / 3)
		stats.draws += u64(mb.draw_count)
	} else {
		gpu_draw_primitives(pass, mb.index_count, 1, 0, 0)
		if stats == nil do return
		stats.triangles += u64(mb.index_count / 3)
		stats.draws += 1
	}
}

// Gives the mesh a skin: `tris` per triangle its three edge references and lead corner,
// `normals` every sample's (sculpt.Skin.normals), over `segments` with `verts` vertices
// and `edges` edges. Replaces a skin it had. False on a GPU failure, with the mesh left
// without a skin, drawn by its own normals.
mesh_buffers_set_skin :: proc(r: ^Renderer, mb: ^Mesh_Buffers, tris: [][4]u32, normals: [][2]i16, segments, verts, edges: u32) -> bool {
	mesh_buffers_drop_skin(r, mb)
	if !mb.storage || len(tris) == 0 || len(normals) == 0 do return false
	mb.skin_normals = gpu_create_buffer(r.device, {usage = {.GRAPHICS_STORAGE_READ}, size = u32(len(normals) * size_of([2]i16))})
	mb.skin_tris = gpu_create_buffer(r.device, {usage = {.GRAPHICS_STORAGE_READ}, size = u32(len(tris) * size_of([4]u32))})
	ok := mb.skin_normals != nil && mb.skin_tris != nil
	ok = ok && upload_blocking(r, mb, mb.skin_normals, slice.to_bytes(normals))
	ok = ok && upload_blocking(r, mb, mb.skin_tris, slice.to_bytes(tris))
	if !ok {
		log.errorf("detail skin upload failed: %s", sdl.GetError())
		mesh_buffers_drop_skin(r, mb)
		return false
	}
	gpu_set_buffer_name(r.device, mb.skin_normals, "skin normals")
	gpu_set_buffer_name(r.device, mb.skin_tris, "skin triangles")
	mb.skin_meta = {segments, verts, edges}
	mb.skin_samples = u32(len(normals))
	mb_touch(r, mb)
	return true
}

// Records the upload of the samples' normals in `ranges` (sculpt.sculptor_skin_ranges).
mesh_buffers_upload_skin :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, normals: [][2]i16, ranges: []geom.Vertex_Range) {
	debug_group(cmd, "Skin upload", .Uploads)
	if mb.skin_normals == nil || len(ranges) == 0 do return
	if u32(len(normals)) != mb.skin_samples {
		log.errorf("detail skin upload: %d samples for a buffer of %d", len(normals), mb.skin_samples)
		return
	}
	// A packed normal is one u32, and a range of samples one of indices.
	words := slice.reinterpret([]u32, normals)
	if !upload_index_ranges(r, cmd, mb, mb.skin_normals, words, transmute([]geom.Index_Range)ranges) {
		log.errorf("detail skin upload failed: %s", sdl.GetError())
	}
	mb_touch(r, mb)
}

// Records the upload of every triangle's record again (their lead corners change with
// the polygroups).
mesh_buffers_upload_skin_tris :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, tris: [][4]u32) {
	if mb.skin_tris == nil do return
	words := slice.reinterpret([]u32, tris)
	whole := [1]geom.Index_Range{{0, u32(len(words))}}
	if !upload_index_ranges(r, cmd, mb, mb.skin_tris, words, whole[:]) {
		log.errorf("detail skin upload failed: %s", sdl.GetError())
	}
	mb_touch(r, mb)
}

// Takes the skin off the mesh, which draws by its own normals again. The caller waits for
// the GPU first (render.wait_idle) when it may still be drawing it.
mesh_buffers_drop_skin :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	if mb.skin_normals != nil do gpu_release_buffer(r.device, mb.skin_normals)
	if mb.skin_tris != nil do gpu_release_buffer(r.device, mb.skin_tris)
	mb.skin_normals, mb.skin_tris, mb.skin_meta, mb.skin_samples, mb.skin_lead_stamp = nil, nil, {}, 0, 0
	mb_touch(r, mb)
}

// A new version for the mesh's buffers, so what was drawn from them is drawn again.
@(private = "file")
mb_touch :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	r.last_version += 1
	mb.version = r.last_version
}
