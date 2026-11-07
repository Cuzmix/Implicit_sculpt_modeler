package render

import "core:log"
import "core:math"
import "core:math/linalg"

import "../gpu"

// Smooth blend's offset pages (the Live stack row; design in
// .claude/project-memory/notes/smooth-blend/design.md): the moves of a drawn instance's
// vertices near the objects it is joined with, read by every vertex stage that places a
// sculpt mesh (shaders/blend_pages.slang), so the sculpt itself never changes. Sparse: a
// table with one word per BLEND_PAGE_VERTICES vertices names the page holding their moves,
// or BLEND_PAGE_NONE; only pages with a moved vertex exist.

// Vertices a page holds: the shaders find a vertex's page as vertex >> 10.
BLEND_PAGE_VERTICES :: 1024
#assert(BLEND_PAGE_VERTICES == 1 << 10)
BLEND_PAGE_NONE :: max(u32)

// One vertex's move, as blend_pages.slang reads it: the offset in the mesh's own space,
// then the blended surface's normal (two 12-bit octahedral halves, low first), how much of
// the blend acts there (4 bits) and the seam side (4 bits).
Blend_Entry :: struct {
	offset: [3]f32,
	packed: u32,
}
#assert(size_of(Blend_Entry) == 16)

// An instance's pages on the GPU, made and filled by blend_pages_set and kept until
// blend_pages_destroy. `version` changes whenever what they hold does, for the keys.
Blend_Pages :: struct {
	table, pages:       gpu.Buffer,
	table_words:        u32, // the table's capacity, in words
	page_capacity:      u32, // the pages buffer's capacity, in pages
	version:            u64,
}

// The entry for a move: its offset, the blended surface's unit normal, how much of the
// blend acts there (0 to 1) and which side of the seam it is on (-1 to 1, > 0 its own).
blend_entry_pack :: proc(offset, normal: [3]f32, amount, own: f32) -> Blend_Entry {
	n := linalg.normalize0(normal)
	l := abs(n.x) + abs(n.y) + abs(n.z)
	e := [2]f32{0, 0}
	if l > 0 {
		e = n.xy / l
		if n.z < 0 {
			// The sides as oct_decode (mesh_io.slang) and geom.oct_encode take them: zero is +.
			sx: f32 = 1 if e.x >= 0 else -1
			sy: f32 = 1 if e.y >= 0 else -1
			e = {(1 - abs(e.y)) * sx, (1 - abs(e.x)) * sy}
		}
	}
	q := [2]u32{u32(math.round(clamp(e.x * 0.5 + 0.5, 0, 1) * 4095)), u32(math.round(clamp(e.y * 0.5 + 0.5, 0, 1) * 4095))}
	a := u32(math.round(clamp(amount, 0, 1) * 15))
	o := u32(math.round(clamp(own * 0.5 + 0.5, 0, 1) * 15))
	return {offset = offset, packed = q.x | q.y << 12 | a << 24 | o << 28}
}

// Puts `table` (one word per BLEND_PAGE_VERTICES vertices of the mesh) and `entries`
// (BLEND_PAGE_VERTICES a page, in page order) into the instance's buffers, made or grown
// (by powers of two) as needed, through the frame's uploads. False, with the pages
// released, when a buffer cannot be made: the instance then draws unblended.
blend_pages_set :: proc(r: ^Renderer, cmd: gpu.Cmd, bp: ^Blend_Pages, table: []u32, entries: []Blend_Entry) -> bool {
	assert(len(entries) % BLEND_PAGE_VERTICES == 0, "blend_pages_set: entries come in whole pages")
	if len(table) == 0 {
		blend_pages_destroy(bp)
		return true
	}
	pages := u32(len(entries) / BLEND_PAGE_VERTICES)
	if bp.table == 0 || bp.table_words < u32(len(table)) {
		if bp.table != 0 do gpu.release_buffer(bp.table)
		bp.table_words = grown(u32(len(table)))
		bp.table = gpu.create_buffer({usage = {.Graphics_Storage_Read, .Storage_Read, .Storage_Write}, size = bp.table_words * size_of(u32)})
		gpu.set_buffer_name(bp.table, "Blend page table")
	}
	if bp.pages == 0 || bp.page_capacity < max(pages, 1) {
		if bp.pages != 0 do gpu.release_buffer(bp.pages)
		bp.page_capacity = grown(max(pages, 1))
		bp.pages = gpu.create_buffer({usage = {.Graphics_Storage_Read, .Storage_Read, .Storage_Write}, size = bp.page_capacity * BLEND_PAGE_VERTICES * size_of(Blend_Entry)})
		gpu.set_buffer_name(bp.pages, "Blend pages")
	}
	if bp.table == 0 || bp.pages == 0 {
		log.errorf("blend pages: buffer creation failed: %s", gpu.last_error())
		blend_pages_destroy(bp)
		return false
	}
	ok := gpu.upload(cmd, bp.table, 0, transmute([]u8)table)
	if len(entries) > 0 do ok = ok && gpu.upload(cmd, bp.pages, 0, transmute([]u8)entries)
	if !ok {
		log.errorf("blend pages: upload failed: %s", gpu.last_error())
		blend_pages_destroy(bp)
		return false
	}
	r.last_version += 1
	bp.version = r.last_version
	return true
}

blend_pages_destroy :: proc(bp: ^Blend_Pages) {
	if bp.table != 0 do gpu.release_buffer(bp.table)
	if bp.pages != 0 do gpu.release_buffer(bp.pages)
	bp^ = {}
}

@(private = "file")
grown :: proc(n: u32) -> u32 {
	c := u32(64)
	for c < n do c *= 2
	return c
}

// What an item's pages add to the keys that decide whether its pictures (the idle cache,
// the studio's samples) still hold: zero without pages, so those keys stay as they were.
blend_version :: proc(item: Draw_Item) -> u64 {
	if item.blend == nil || item.blend.table == 0 do return 0
	return item.blend.version * 0x9e3779b97f4a7c15
}

// What an item's vertex stage binds for its pages: its own, or the one-word dummies and
// a zero flag (blend.x in the frame or shadow uniforms) when it has none.
blend_bindings :: proc(r: ^Renderer, item: Draw_Item) -> (table, pages: gpu.Buffer, on: u32) {
	if bp := item.blend; bp != nil && bp.table != 0 && bp.pages != 0 do return bp.table, bp.pages, 1
	return r.no_blend, r.no_blend, 0
}

