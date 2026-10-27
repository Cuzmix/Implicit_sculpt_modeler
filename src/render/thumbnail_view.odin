package render

import "core:log"
import sdl "vendor:sdl3"

// The thumbnail view: the scene drawn again, small, into a texture of its own, as a
// sculptor steps back from the work. As a silhouette, every object is black on a light
// ground, so the outline reads without the shading; otherwise it is shaded as the
// viewport is. The interface shows the texture, mirrored when the app asks, since a form
// seen flipped shows its proportions afresh.
Thumbnail_View :: struct {
	target: Viewport_Target,
	failed: bool, // the device refused the texture; nothing is drawn
}

// Drawn at twice the size it is shown and smoothed down, so a silhouette's edge is not
// stepped.
THUMBNAIL_SUPERSAMPLE :: 2

// The ground behind a silhouette, and behind the shaded view.
THUMBNAIL_PAPER :: [4]f32{0.86, 0.86, 0.85, 1}
THUMBNAIL_DARK :: [4]f32{0.07, 0.07, 0.08, 1}

thumbnail_view_destroy :: proc(r: ^Renderer, tv: ^Thumbnail_View) {
	if r.device == nil do return
	viewport_target_destroy(r, &tv.target)
	tv^ = {}
}

// Draws `items` seen through `view` and `proj` into the texture, `size` pixels as shown,
// each whole (their chunks and simplified copies are the viewport's this frame), and
// returns it; nil when there is none. A silhouette draws every item black: its colour
// and every light let through are dropped far below what shows.
thumbnail_view_draw :: proc(r: ^Renderer, tv: ^Thumbnail_View, cmd: ^sdl.GPUCommandBuffer, size: [2]u32, view, proj: Mat4, items: []Draw_Item, silhouette: bool) -> ^sdl.GPUTexture {
	if tv.failed || size.x == 0 || size.y == 0 do return nil
	if !viewport_target_resize(r, &tv.target, size.x * THUMBNAIL_SUPERSAMPLE, size.y * THUMBNAIL_SUPERSAMPLE) {
		tv.failed = true
		log.errorf("thumbnail view target: %s", sdl.GetError())
		return nil
	}
	whole := make([]Draw_Item, len(items), context.temp_allocator)
	for it, i in items {
		w := it
		w.chunks, w.chunk_groups, w.hidden, w.lod = nil, nil, nil, {}
		if silhouette {
			w.color.rgb = 0
			w.matcap, w.textured, w.slots = nil, nil, nil
			w.wireframe, w.paint, w.groups = false, false, false
			w.checker = {}
			// Forty stops darker: black after the tone map, highlights and all.
			w.look = {-40, 0, 0, 0}
		}
		whole[i] = w
	}
	pass := begin_mesh_pass(r, cmd, &r.single, tv.target.color, tv.target.depth, load = false, keep_depth = false, background = THUMBNAIL_PAPER if silhouette else THUMBNAIL_DARK)
	draw_items(r, cmd, pass, &r.single, view, proj, whole, nil, nil)
	sdl.EndGPURenderPass(pass)
	return tv.target.color
}
