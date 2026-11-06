package main

import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"
import "../png_write"
import "../render"
import "../sculpt"
import "../ui"

// Polypaint and polygroups on the app side: the Polypaint and Polygroups commands as
// undo steps, the Ctrl + Shift click that isolates a group, and their GPU upload.

// The Paint brush's colour as the sculptor takes it: sRGB bytes.
brush_color_bytes :: proc(app: ^App) -> [3]u8 {
	c := app.brush.color
	return {u8(clamp(c.r, 0, 1) * 255 + 0.5), u8(clamp(c.g, 0, 1) * 255 + 0.5), u8(clamp(c.b, 0, 1) * 255 + 0.5)}
}

// Whether the brush `kind` takes the paint channel (Brush_Settings.channel): the
// sculpting brushes do; Paint, Mask, Grab, Elastic and Cloth keep to what they change.
channel_brush :: proc(kind: sculpt.Brush_Kind) -> bool {
	return kind not_in bit_set[sculpt.Brush_Kind]{.Paint, .Mask, .Grab, .Elastic, .Cloth}
}

// The channel the held brush's dabs take on `obj`. Paint needs a level's own vertices,
// so in an HD window, under dynamic topology and on voxel clay, Both only sculpts (a
// Colour stroke there is refused before it starts, stroke_start).
brush_channel :: proc(app: ^App, obj: ^Object) -> sculpt.Channel {
	c := app.brush.channel
	if c == .Both && (obj == nil || obj.voxel != nil || object_in_hd(obj) || object_dynamic(obj)) do return .Sculpt
	return c
}

// Trades the brush's main and secondary colours.
swap_colors :: proc(app: ^App) {
	b := &app.brush
	b.color, b.color2 = b.color2, b.color
}

// Fills the selected object with the brush colour, or with a gradient from it to the
// secondary colour, or clears its paint, as an undo step of its own
// (sculpt.sculptor_paint_command). The gradient runs down the screen: the main colour at
// the object's top as seen, the secondary at its bottom, as ZBrush's FillObject Grad.
paint_command :: proc(app: ^App, command: sculpt.Paint_Command) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil || !paint_allowed(obj) do return
	start := time.tick_now()
	gradient: sculpt.Paint_Gradient
	if command == .Gradient {
		// From the main colour at the top of the screen to the secondary at its bottom: the
		// view's down in the object's own space.
		_, up, _ := camera.orbit_basis(app.camera)
		gradient = {to = color_bytes(app.brush.color2), axis = -to_local_dir(obj.transform, up)}
	}
	material := [2]u8{u8(clamp(app.brush.roughness, 0, 1) * 255 + 0.5), u8(clamp(app.brush.metal, 0, 1) * 255 + 0.5)}
	if sculpt.sculptor_paint_on_texture(object_sculptor(obj)) {
		// The picked layer lives in a texture: its tiles change, kept by an undo step of
		// the object's own.
		step := new(sculpt.Texel_Step)
		changed := sculpt.levels_texel_command(&obj.levels, command, brush_color_bytes(app), material, step)
		log.infof("%s on a texture layer: %.0f ms%s", PAINT_COMMAND_NAMES[command], time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
		if changed do history_record_texels(app, obj, step, PAINT_COMMAND_NAMES[command])
		else {
			sculpt.texel_step_free(step)
			free(step)
		}
		return
	}
	changed := sculpt.sculptor_paint_command(object_sculptor(obj), command, brush_color_bytes(app), gradient, material)
	log.infof("%s: %.0f ms%s", PAINT_COMMAND_NAMES[command], time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
	if changed do history_record(app, obj, .Paint, PAINT_COMMAND_NAMES[command])
}

@(rodata)
PAINT_COMMAND_NAMES := [sculpt.Paint_Command]string {
	.Fill     = "Fill with colour",
	.Clear    = "Clear paint",
	.Gradient = "Fill gradient",
}

// Changes the selected object's polygroups as an undo step of its own
// (sculpt.sculptor_group_command).
group_command :: proc(app: ^App, command: sculpt.Group_Command) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil || !paint_allowed(obj) do return
	start := time.tick_now()
	s := object_sculptor(obj)
	// The groups as they were, for the group materials to follow.
	before: []u16
	if len(obj.group_materials) > 0 {
		if g := sculpt.sculptor_groups(s); g != nil do before = slice.clone(g, context.temp_allocator)
	}
	changed := sculpt.levels_group_uv_charts(&obj.levels) if command == .Uv_Charts else sculpt.sculptor_group_command(s, command, app.ui.crease_degrees)
	groups := 0
	if g := sculpt.sculptor_groups(s); g != nil {
		// A flag per group number: a map over 20M triangles takes a second.
		seen := make([]bool, int(max(u16)) + 1, context.temp_allocator)
		for x in g {
			if !seen[x] do groups += 1
			seen[x] = true
		}
	}
	log.infof("polygroups %v: %d groups, %.0f ms%s", command, groups, time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
	if !changed do return
	// Grouping is easiest to follow seen.
	app.show_groups = true
	history_record(app, obj, .Paint, GROUP_COMMAND_NAMES[command])
	if len(obj.group_materials) > 0 {
		after := group_materials_follow(obj.group_materials[:], before, sculpt.sculptor_groups(s))
		if slice.equal(after[:], obj.group_materials[:]) {
			delete(after)
			return
		}
		step := new(Group_Table_Step)
		step.before = slice.clone_to_dynamic(obj.group_materials[:])
		step.after = after
		app.history.done[len(app.history.done) - 1].group_table = step
		group_materials_replace(app, obj, after[:])
	}
}

@(rodata)
GROUP_COMMAND_NAMES := [sculpt.Group_Command]string {
	.Visible       = "Group visible",
	.Masked        = "Group masked",
	.Creases       = "Group by creases",
	.Clear         = "Clear groups",
	.Pieces        = "Group by pieces",
	.Normals       = "Group by normals",
	.Merge_Similar = "Merge similar groups",
	.Uv_Charts     = "Group by UVs",
}

// What Ctrl+W does, as ZBrush's: with something masked, the masked part becomes a group
// and the mask is cleared; otherwise what is shown becomes one.
group_shortcut :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	if object_sculptor(obj).mask != nil && !object_dynamic(obj) && !object_in_hd(obj) {
		before := len(app.history.done)
		group_command(app, .Masked)
		if len(app.history.done) > before do mask_command(app, .Clear)
		return
	}
	group_command(app, .Visible)
}

// A Ctrl + Shift click at viewport point `at`: on a group of the object there, shows
// only that group (or, when it is all that shows, everything but it), or with `alt`
// masks it; anywhere else, or on an object without groups, shows everything. Returns
// whether a group was clicked.
group_click :: proc(app: ^App, at, size: [2]f32, alt: bool) -> bool {
	origin, dir := mouse_ray(app.camera, at, size)
	index, _, ok := scene_raycast(app, origin, dir)
	if !ok do return false
	obj := app.scene.objects[index]
	s := object_sculptor(obj)
	if !sculpt.sculptor_has_groups(s) || object_in_hd(obj) do return false
	t := obj.transform
	group, hit := sculpt.sculptor_group_at(s, to_local(t, origin), to_local_dir(t, dir))
	if !hit do return false
	stroke_finish(app)
	app.scene.selected = index
	start := time.tick_now()
	if alt {
		changed := sculpt.sculptor_mask_group(s, group)
		report(app, Section.Mask, {.Quiet}, "Mask group %d in %.0f ms%s", group, time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
		if changed do history_record(app, obj, .Mask, "Mask group")
		return true
	}
	changed := sculpt.sculptor_hide_group(s, group)
	report(app, Section.Visibility, {.Quiet}, "Isolate group %d: %s of %s triangles hidden, %.0f ms", group, thousands(sculpt.sculptor_hidden_count(s)), thousands(object_triangle_count(obj)), time.duration_milliseconds(time.tick_since(start)))
	if changed {
		history_record(app, obj, .Hide, "Isolate group")
		render.viewport_invalidate(&app.target)
	}
	return true
}

// Whether paint and group commands can run on the selected object now: paint_allowed
// without its log line, so their buttons grey out rather than do nothing.
paint_ready :: proc(app: ^App, _: int) -> bool {
	obj := selected_object(app)
	return obj != nil && !object_in_hd(obj) && !object_dynamic(obj)
}

// Paint and groups work on a level's own vertices and triangles: not in an HD window,
// whose detail leaves when it closes, nor under dynamic topology, whose edits would have
// to carry them along.
paint_allowed :: proc(obj: ^Object) -> bool {
	switch {
	case object_in_hd(obj):
		log.warn("polypaint and polygroups: leave the HD window first (A)")
		return false
	case object_dynamic(obj):
		log.warn("polypaint and polygroups: not with dynamic topology on")
		return false
	}
	return true
}

// Brings the level's paint buffer up to date (colours, groups, and roughness and metal in
// the group word's high bits): everything when its colours or groups
// changed as a whole (or the buffer is new), else the vertex `ranges` the flush reported.
// Returns the bytes sent.
paint_upload :: proc(app: ^App, cmd: render.Cmd, gpu: ^render.Mesh_Buffers, lv: ^sculpt.Level, ranges: []sculpt.Vertex_Range) -> int {
	s := &lv.sculptor
	colors, groups := sculpt.sculptor_paint_shown(s), sculpt.sculptor_vertex_groups(s)
	if colors == nil && groups == nil do return 0
	stamp := sculpt.sculptor_paint_stamp(s)
	all := gpu.paint == 0 || gpu.paint_stamp != stamp
	if !all && len(ranges) == 0 do return 0
	materials := sculpt.sculptor_paint_shown_material(s)
	render.mesh_buffers_upload_paint(&app.renderer, cmd, gpu, colors, groups, ranges, all, materials)
	gpu.paint_stamp = stamp
	if all do return int(gpu.vertex_capacity) * size_of(render.Paint_Packed)
	bytes := 0
	for r in ranges do bytes += int(r.count) * size_of(render.Paint_Packed)
	return bytes
}

// What the Paint tab's foot does to the picked paint layer.
Paint_Layer_Action :: enum u8 {
	Move_Up,
	Move_Down,
	Merge_Down,
	Delete,
}

// Adds a paint layer above the picked one and picks it, as one History step.
paint_layer_add :: proc(app: ^App, obj: ^Object) {
	stroke_finish(app)
	if obj == nil || !paint_allowed(obj) do return
	if sculpt.sculptor_paint_add(object_sculptor(obj)) >= 0 do history_record(app, obj, .Paint, "New paint layer")
}

// Adds a texture paint layer at the object's texture size (its texture layers' own, else
// the Bake size) above the picked one and every vertex layer, and picks it, as one History
// step. Says why when it cannot: no UVs, or a size its texture layers do not have.
texture_layer_add :: proc(app: ^App, obj: ^Object) {
	stroke_finish(app)
	if obj == nil || !paint_allowed(obj) do return
	if !sculpt.levels_has_uvs(&obj.levels) {
		file_note(app, true, "%s has no UVs: Unwrap it first (Mesh > UVs)", object_label(obj))
		return
	}
	side := texture_layer_side(app, obj)
	if sculpt.levels_texel_layer_add(&obj.levels, side) >= 0 do history_record(app, obj, .Paint, "New texture layer")
}

// The size a new texture layer of `obj` takes: its texture layers' own when it has any,
// else the Bake size, at most 2048 on a tablet, where a 4096 layer's tiles and map cost
// too much memory for what the screen shows.
texture_layer_side :: proc(app: ^App, obj: ^Object) -> int {
	if len(obj.levels.texels.layers) > 0 do return obj.levels.texels.side
	side := int(app.ui.bake.size)
	if !sculpt.texel_side_ok(side) do side = 2048
	return min(side, 2048) if MOBILE else side
}

// Whether the picked paint layer can take `action` now.
paint_layer_ready :: proc(app: ^App, action: Paint_Layer_Action) -> bool {
	if !paint_ready(app, 0) do return false
	s := object_sculptor(selected_object(app))
	i, n := sculpt.sculptor_paint_picked(s), len(sculpt.sculptor_paint_layers(s))
	switch action {
	case .Move_Up:    return i >= 0 && i + 1 < n
	case .Move_Down, .Merge_Down: return i > 0
	case .Delete:     return i >= 0
	}
	return false
}

// Moves, merges or deletes the picked paint layer, as one History step.
paint_layer_edit :: proc(app: ^App, obj: ^Object, action: Paint_Layer_Action) {
	stroke_finish(app)
	if obj == nil || !paint_allowed(obj) do return
	s := object_sculptor(obj)
	i := sculpt.sculptor_paint_picked(s)
	if i < 0 do return
	done := false
	switch action {
	case .Move_Up:    done = sculpt.sculptor_paint_move(s, i)
	case .Move_Down:  done = i > 0 && sculpt.sculptor_paint_move(s, i - 1)
	case .Merge_Down: done = sculpt.sculptor_paint_merge_down(s, i)
	case .Delete:     done = sculpt.sculptor_paint_remove(s, i)
	}
	if done do history_record(app, obj, .Paint, PAINT_LAYER_ACTION_NAMES[action])
	// A new step drops what could have been redone, which may have held the last row of a
	// texture layer.
	sculpt.levels_texels_sweep(&obj.levels)
}

@(rodata)
PAINT_LAYER_ACTION_NAMES := [Paint_Layer_Action]string {
	.Move_Up    = "Move paint layer up",
	.Move_Down  = "Move paint layer down",
	.Merge_Down = "Merge paint down",
	.Delete     = "Delete paint layer",
}

// The vertices a paint layer's swatch looks at, spread over the mesh: enough for its colour,
// few enough to look at every frame at any size.
PAINT_SWATCH_SAMPLES :: 4096

// A paint layer's swatch for the Paint tab: the mean of its colours over where it covers,
// weighted by coverage, from vertices spread over the mesh; false when it covers none of them.
paint_layer_swatch :: proc(app: ^App, obj: ^Object, index: int) -> (ui.Color, bool) {
	colors := sculpt.sculptor_paint_layer_colors(object_sculptor(obj), index)
	if len(colors) == 0 do return {}, false
	step := max(len(colors) / PAINT_SWATCH_SAMPLES, 1)
	rgb: [3]f32
	cover: f32
	for v := 0; v < len(colors); v += step {
		c := colors[v]
		a := f32(c.a)
		rgb += {f32(c.r), f32(c.g), f32(c.b)} * a
		cover += a
	}
	if cover <= 0 do return {}, false
	rgb /= cover
	return {u8(rgb.r + 0.5), u8(rgb.g + 0.5), u8(rgb.b + 0.5), 255}, true
}

// `obj`'s colours per vertex on level `s` with its texture layers laid over
// (sculpt.levels_paint_flat), for the rebuilds and exports that keep colours per vertex
// only: valid until the frame ends.
object_paint_flat :: proc(obj: ^Object, s: ^sculpt.Sculptor) -> []sculpt.Color {
	return sculpt.levels_paint_flat(&obj.levels, s)
}

// `obj`'s paint as base colour and ORM maps (sculpt.levels_texels_maps), PNG coded in
// temporary memory, over its material's colour, roughness and metal: nil unless it has
// texture layers to show and can show them (no voxels, HD window or dynamic topology).
object_paint_map_pngs :: proc(app: ^App, obj: ^Object) -> (base, orm: []u8, side: int) {
	if obj.voxel != nil || obj.curve != nil || obj.cage != nil || object_dynamic(obj) || object_in_hd(obj) do return
	l := &obj.levels
	sculpt.levels_texels_flush(l)
	if !sculpt.levels_texels_show(l) do return
	// The material as an export gives it (a classic or MatCap one as its nearest
	// physically based look), so the maps say what the file would without them.
	m := export_material(object_material(app, obj))
	under: [3]u8
	for k in 0 ..< 3 do under[k] = u8(clamp(geom.srgb_encode(m.base[k]) * 255 + 0.5, 0, 255))
	rm := [2]u8{u8(clamp(m.roughness * 255 + 0.5, 0, 255)), u8(clamp(m.metallic * 255 + 0.5, 0, 255))}
	b, o := sculpt.levels_texels_maps(l, under, rm, context.temp_allocator)
	if b == nil do return
	side = l.texels.side
	return png_write.encode(b, side, side, false, context.temp_allocator), png_write.encode(o, side, side, false, context.temp_allocator), side
}

// Writes the selected object's paint (vertex and texture layers, over its material) into
// `folder` as NAME_base_color.png and NAME_orm.png at its texture layers' size, NAME being
// the object's, as Bake names its maps. False, with a note saying why, when it cannot.
paint_maps_export :: proc(app: ^App, folder: string) -> bool {
	obj := selected_object(app)
	if obj == nil {
		file_note(app, true, "Export paint maps: select an object with texture layers first")
		return false
	}
	stroke_finish(app)
	start := time.tick_now()
	base, orm, side := object_paint_map_pngs(app, obj)
	if base == nil {
		file_note(app, true, "Export paint maps: %s has no texture layer showing (Layers > Paint > New layer > In a texture)", object_label(obj))
		return false
	}
	name, _ := strings.replace_all(object_label(obj), " ", "_", context.temp_allocator)
	for m in ([2]struct {
			data:   []u8,
			suffix: string,
		}{{base, "_base_color.png"}, {orm, "_orm.png"}}) {
		path, _ := filepath.join({folder, strings.concatenate({name, m.suffix}, context.temp_allocator)}, context.temp_allocator)
		if !write_file_safely(app, path, m.data, "export") do return false
	}
	file_note(app, false, "%s", fmt.tprintf("Exported %s's paint as %s_base_color.png and %s_orm.png (%d x %d) in %.0f ms", object_label(obj), name, name, side, side, time.duration_milliseconds(time.tick_since(start))))
	return true
}
