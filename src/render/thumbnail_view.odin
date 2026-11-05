package render

import "../geom"
import "../gpu"
import "core:log"
import "core:math/linalg"

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
	if !r.has_device do return
	viewport_target_destroy(r, &tv.target)
	tv^ = {}
}

// Draws `items` seen through `view` and `proj` into the texture, `size` pixels as shown,
// drawn at `supersample` times that each way and smoothed down, each whole (their chunks
// and simplified copies are the viewport's this frame), on `background`, and returns it;
// with `cull`, each item's chunks are culled on the CPU for this view and only those in it
// drawn, one direct draw a run (Draw_Item.ranges), which a picture of a small part of a
// dense mesh needs: drawn whole, every triangle of it would go through the GPU;
// nil when there is none. The caller sets each item's pass and lights. `keep_depth` keeps
// the depth for what reads it after (live occlusion, the studio render); without it the
// depth is transient, so a tile GPU gives it no memory. With `scene` the picture stands
// on Renderer.background (its gradient, or the environment where that shows) and
// Renderer.floor, as the viewport does, rather than on `background` alone.
thumbnail_view_draw :: proc(r: ^Renderer, tv: ^Thumbnail_View, cmd: gpu.Cmd, size: [2]u32, view, proj: Mat4, items: []Draw_Item, background: [4]f32, supersample: u32 = THUMBNAIL_SUPERSAMPLE, keep_depth := false, scene := false, cull := false) -> gpu.Texture {
	if tv.failed || size.x == 0 || size.y == 0 do return 0
	scale := max(supersample, 1)
	if !viewport_target_resize(r, &tv.target, size.x * scale, size.y * scale, transient_depth = !keep_depth) {
		tv.failed = true
		log.errorf("thumbnail view target: %s", gpu.last_error())
		return 0
	}
	// With parallel projection every chunk is seen from the same direction: an eye far
	// back along it makes the back-facing test agree, as prepare_draws has it.
	eye_world := linalg.inverse(view) * [4]f32{0, 0, 1e4 if proj[3, 3] == 1 else 0, 1}
	whole := make([dynamic]Draw_Item, 0, len(items), context.temp_allocator)
	for it in items {
		w := it
		if cull && len(it.chunks) > 0 {
			// The viewport's own test on the same chunks, cones and groups, so the picture
			// leaves out exactly what the viewport would from this view.
			runs := make([dynamic]geom.Index_Range, 0, 64, context.temp_allocator)
			eye := linalg.inverse(it.model) * eye_world
			clip := proj * view * it.model
			hidden := it.hidden[:len(it.chunks)] if it.hidden != nil else nil
			if len(it.chunk_groups) > 0 {
				_ = geom.cull_chunks_grouped(it.chunks, it.chunk_groups, clip, eye.xyz, &runs, hidden)
			} else {
				_ = geom.cull_chunks(it.chunks, clip, eye.xyz, &runs, hidden = hidden)
			}
			// An item none of which is in view is left out (no runs would read as the whole).
			if len(runs) == 0 do continue
			w.ranges = runs[:]
		}
		w.chunks, w.chunk_groups, w.hidden, w.lod = nil, nil, nil, {}
		append(&whole, w)
	}
	pass := begin_mesh_pass(r, cmd, &r.single, tv.target.color, tv.target.depth, load = false, keep_depth = keep_depth, background = background)
	if scene do draw_background(r, cmd, pass, &r.single, tv.target, proj, flat_too = true)
	draw_items(r, cmd, pass, &r.single, view, proj, whole[:], nil, nil)
	if scene do draw_floor(r, cmd, pass, &r.single, view, proj)
	gpu.end_render_pass(pass)
	return tv.target.color
}
