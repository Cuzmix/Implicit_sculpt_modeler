package render

import "core:log"
import sdl "vendor:sdl3"

// The thumbnail view: the scene drawn again, into a texture of its own, as the app's
// second view sees it (its camera, its pass). The interface shows the texture, mirrored
// when the app asks, since a form seen flipped shows its proportions afresh.
Thumbnail_View :: struct {
	target: Viewport_Target,
	failed: bool, // the device refused the texture; nothing is drawn
}

// Drawn at twice the size it is shown and smoothed down, so a silhouette's edge is not
// stepped.
THUMBNAIL_SUPERSAMPLE :: 2

// The ground behind a silhouette (the other passes sit on the scene's background).
THUMBNAIL_PAPER :: [4]f32{0.86, 0.86, 0.85, 1}

thumbnail_view_destroy :: proc(r: ^Renderer, tv: ^Thumbnail_View) {
	if r.device == nil do return
	viewport_target_destroy(r, &tv.target)
	tv^ = {}
}

// Draws `items` seen through `view` and `proj` into the texture, `size` pixels as shown,
// drawn at `supersample` times that each way and smoothed down, each whole (their chunks
// and simplified copies are the viewport's this frame), on `background`, and returns it;
// nil when there is none. The caller sets each item's pass and lights. `keep_depth` keeps
// the depth for what reads it after (live occlusion, the studio render); without it the
// depth is transient, so a tile GPU gives it no memory. With `scene` the picture stands
// on Renderer.background (its gradient, or the environment where that shows) and
// Renderer.floor, as the viewport does, rather than on `background` alone.
thumbnail_view_draw :: proc(r: ^Renderer, tv: ^Thumbnail_View, cmd: ^sdl.GPUCommandBuffer, size: [2]u32, view, proj: Mat4, items: []Draw_Item, background: [4]f32, supersample: u32 = THUMBNAIL_SUPERSAMPLE, keep_depth := false, scene := false) -> ^sdl.GPUTexture {
	if tv.failed || size.x == 0 || size.y == 0 do return nil
	scale := max(supersample, 1)
	if !viewport_target_resize(r, &tv.target, size.x * scale, size.y * scale, transient_depth = !keep_depth) {
		tv.failed = true
		log.errorf("thumbnail view target: %s", sdl.GetError())
		return nil
	}
	whole := make([]Draw_Item, len(items), context.temp_allocator)
	for it, i in items {
		w := it
		w.chunks, w.chunk_groups, w.hidden, w.lod = nil, nil, nil, {}
		whole[i] = w
	}
	pass := begin_mesh_pass(r, cmd, &r.single, tv.target.color, tv.target.depth, load = false, keep_depth = keep_depth, background = background)
	if scene do draw_background(r, cmd, pass, &r.single, tv.target, proj, flat_too = true)
	draw_items(r, cmd, pass, &r.single, view, proj, whole, nil, nil)
	if scene do draw_floor(r, cmd, pass, &r.single, view, proj)
	gpu_end_render_pass(pass)
	return tv.target.color
}
