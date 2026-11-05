package render

import "../gpu"
import "core:hash"
import "core:log"
import "core:math"
import "core:slice"

// Reference pictures on planes in the scene (the References card's In scene), as Blender's
// view-aligned reference images and ZBrush's image planes: each one quad drawn unlit from
// the picture's own GPU copy (ref_plane.vert and .frag), in the viewport pass after the
// meshes and before the floor grid. A plane faces one axis view and shows only while the
// camera looks along that axis, within REF_PLANE_SHOWN_COS, unless it is shown from any
// side. Behind, it is drawn at the far plane's depth and tested against the meshes', so
// it shows only where no mesh is, as a backdrop, and the grid's lines cross it; Through,
// it is drawn over everything at its opacity after the see-through items, the silhouette
// check. Neither writes depth. With no planes, nothing is bound or drawn, and the pipelines are only
// made the first time one is.

// One plane as the app sets it each frame (Renderer.ref_planes): the picture's texture,
// the plane's middle, half its width along its view's right and half its height along
// its view's up, the way it faces (toward the eye of its view, unit length), the
// picture's texture coordinates at its top left, top right, bottom right and bottom left
// corners, its opacity, whether it is drawn through the model, and whether it shows from
// any side. Every field is hashed into the frame's key, so the struct has no padding.
Ref_Plane :: struct {
	texture: gpu.Texture,
	center:  [3]f32,
	right:   [3]f32,
	up:      [3]f32,
	facing:  [3]f32,
	uv:      [4][2]f32,
	opacity: f32,
	through: b32,
	always:  b32,
}
#assert(size_of(Ref_Plane) == 4 + 4 * 12 + 32 + 4 + 4 + 4)

// The cosine of 10°: how far from looking straight along a plane's axis the camera may
// turn and still show it, as Blender's "Only Axis Aligned".
REF_PLANE_SHOWN_COS :: 0.98480775

// Matches Ref_Plane_Uniforms in ref_plane.vert.slang.
@(private)
Ref_Plane_Uniforms :: struct {
	view_proj: Mat4,
	center:    [4]f32,
	right:     [4]f32,
	up:        [4]f32,
	uv_top:    [4]f32,
	uv_bottom: [4]f32,
}

// Whether plane `p` shows from a camera looking along `forward` (world space, unit length).
ref_plane_shown :: proc(p: Ref_Plane, forward: [3]f32) -> bool {
	if p.texture == 0 || p.opacity <= 0 do return false
	if p.always do return true
	return -(forward.x * p.facing.x + forward.y * p.facing.y + forward.z * p.facing.z) >= REF_PLANE_SHOWN_COS
}

// The way the camera of `view` looks, in world space: the view's third row turned back.
view_forward :: proc(view: Mat4) -> [3]f32 {
	f := [3]f32{-view[2, 0], -view[2, 1], -view[2, 2]}
	n := math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
	return f / n if n > 0 else {0, 0, -1}
}

// Folds the planes into a frame key: none leaves the key as it was.
@(private)
ref_planes_key :: proc(planes: []Ref_Plane, h: u64) -> u64 {
	if len(planes) == 0 do return h
	return hash.fnv64a(slice.to_bytes(planes), h)
}

// Draws the planes drawn `through` the model, or those behind it, that the camera of
// `view` shows.
@(private)
draw_ref_planes :: proc(r: ^Renderer, cmd: gpu.Cmd, pass: gpu.Render_Pass, pipes: ^Mesh_Pipelines, view, proj: Mat4, through: bool) {
	if len(r.ref_planes) == 0 do return
	forward := view_forward(view)
	bound := false
	for p in r.ref_planes {
		if bool(p.through) != through || !ref_plane_shown(p, forward) do continue
		if !bound {
			ref_plane_pipelines(r, pipes)
			pipeline := pipes.ref_through if through else pipes.ref_behind
			if pipeline == 0 || r.matcap_sampler == 0 do return
			gpu.bind_graphics_pipeline(pass, pipeline)
			bound = true
		}
		u := Ref_Plane_Uniforms {
			view_proj = proj * view,
			center    = {p.center.x, p.center.y, p.center.z, 1},
			right     = {p.right.x, p.right.y, p.right.z, 0},
			up        = {p.up.x, p.up.y, p.up.z, 0},
			uv_top    = {p.uv[0].x, p.uv[0].y, p.uv[1].x, p.uv[1].y},
			uv_bottom = {p.uv[2].x, p.uv[2].y, p.uv[3].x, p.uv[3].y},
		}
		push_vertex(cmd, Ref_Plane_Vert_Uniforms.Ref_Plane_Uniforms, &u)
		look := [4]f32{clamp(p.opacity, 0, 1), 0, 0, 0}
		push_fragment(cmd, Ref_Plane_Frag_Uniforms.Ref_Plane_Look, &look)
		// The picture's mips filtered linearly and clamped at its edges, as a matcap's are.
		samplers := [Ref_Plane_Frag_Samplers]gpu.Texture_Sampler_Binding{.picture = {texture = p.texture, sampler = r.matcap_sampler}}
		bind_fragment_samplers(pass, &samplers)
		gpu.draw_primitives(pass, 6, 1, 0, 0)
	}
}

// Makes the planes' two pipelines of `p`'s sample count the first time a plane is drawn,
// so a scene with none never builds them; each stays nil where the device refused it,
// and its planes are then not drawn.
@(private)
ref_plane_pipelines :: proc(r: ^Renderer, p: ^Mesh_Pipelines) {
	if p.ref_made do return
	p.ref_made = true
	p.ref_behind = create_ref_plane_pipeline(r, p.samples, through = false)
	p.ref_through = create_ref_plane_pipeline(r, p.samples, through = true)
}

@(private)
create_ref_plane_pipeline :: proc(r: ^Renderer, samples: gpu.Sample_Count, through: bool) -> gpu.Graphics_Pipeline {
	vert := gpu.create_shader(REF_PLANE_VERT)
	frag := gpu.create_shader(REF_PLANE_FRAG)
	defer if vert != 0 do gpu.release_shader(vert)
	defer if frag != 0 do gpu.release_shader(frag)
	if vert == 0 || frag == 0 {
		log.warnf("reference planes stay off: their shaders could not be made: %s", gpu.last_error())
		return 0
	}
	color_targets := [1]gpu.Color_Target_Desc{{format = VIEWPORT_COLOR_FORMAT, blend_state = BLEND_OVER}}
	pipeline := gpu.create_graphics_pipeline({
		vertex_shader = vert,
		fragment_shader = frag,
		primitive = .Triangle_List,
		// A plane is seen from its own side, but a turn of the view past it shows its back
		// mirrored rather than nothing.
		rasterizer_state = {fill_mode = .Fill, cull_mode = .None},
		// Behind: at the far plane (ref_plane.vert), tested against the meshes' depth and
		// leaving it be, so it shows only where no mesh is. Through: over everything.
		depth_stencil_state = {compare_op = .Less_Or_Equal, enable_depth_test = !through, enable_depth_write = false},
		multisample_state = {sample_count = samples},
		targets = {
			color_targets = color_targets[:],
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	if pipeline == 0 do log.warnf("reference planes stay off: their pipeline could not be made: %s", gpu.last_error())
	return pipeline
}
