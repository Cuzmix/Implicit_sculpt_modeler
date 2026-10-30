package render

import "core:hash"
import "core:log"
import "core:slice"
import sdl "vendor:sdl3"

import "../geom"

// The navigation head in the top-right corner: a small head that turns with the camera,
// drawn with the mesh pipeline into a texture of its own that the interface shows over
// the viewport. It is drawn NAV_HEAD_SUPERSAMPLE times larger each way and shown with
// a filtering sampler (Ui_Draw.smooth), which averages each pixel's samples evenly, so
// its outline is smooth on any device. It is redrawn only when the camera turns, its
// size changes or its colour does.
Nav_Head :: struct {
	mesh:   Mesh_Buffers,
	target: Viewport_Target,
	key:    u64, // what the target holds; 0 when nothing
	failed: bool, // the device refused it; nothing is drawn
}

NAV_HEAD_SUPERSAMPLE :: 2

// The head's mesh space is about a unit sphere; the view is this many units above and
// below the middle, enough for the nose and ears to fit from any side.
NAV_HEAD_HALF_HEIGHT :: 1.32

// Uploads the head's mesh once; the app builds it (nav_head_mesh in the app).
nav_head_init :: proc(r: ^Renderer, nh: ^Nav_Head, mesh: geom.Mesh) -> bool {
	mb, ok := mesh_buffers_create(r, mesh)
	if !ok {
		nh.failed = true
		return false
	}
	// The head never changes after this, so the large transfer buffer goes now.
	gpu_release_transfer_buffer(r.device, mb.transfer)
	mb.transfer, mb.transfer_size = nil, 0
	nh.mesh = mb
	return true
}

nav_head_destroy :: proc(r: ^Renderer, nh: ^Nav_Head) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	mesh_buffers_destroy(r, &nh.mesh)
	viewport_target_destroy(r, &nh.target)
	nh^ = {}
}

// Draws the head into its texture, `size` pixels as shown, turned as `rotation` says
// (the camera's right, up and back in world space, as its columns) and shaded `color`
// with the clay material, unless the texture holds that already. Returns the texture,
// or nil when there is none to show.
nav_head_draw :: proc(r: ^Renderer, nh: ^Nav_Head, cmd: ^sdl.GPUCommandBuffer, size: [2]u32, rotation: matrix[3, 3]f32, color: [4]f32) -> ^sdl.GPUTexture {
	if nh.failed || nh.mesh.positions == nil || size.x == 0 || size.y == 0 do return nil
	w, h := size.x * NAV_HEAD_SUPERSAMPLE, size.y * NAV_HEAD_SUPERSAMPLE
	if !viewport_target_resize(r, &nh.target, w, h, transient_depth = true) {
		nh.failed = true
		log.errorf("navigation head target: %s", sdl.GetError())
		return nil
	}
	// The camera's view without its place: the head sits three units in front of the eye.
	m := rotation
	view := Mat4{
		m[0, 0], m[1, 0], m[2, 0], 0,
		m[0, 1], m[1, 1], m[2, 1], 0,
		m[0, 2], m[1, 2], m[2, 2], -3,
		0, 0, 0, 1,
	}
	aspect := f32(w) / f32(h)
	hh := f32(NAV_HEAD_HALF_HEIGHT)
	proj := Mat4{
		1 / (hh * aspect), 0, 0, 0,
		0, 1 / hh, 0, 0,
		0, 0, 1 / (1 - 5), 1 / (1 - 5), // view depths -1 to -5 mapped to 0 to 1
		0, 0, 0, 1,
	}
	Keyed :: struct { // no padding: every byte is hashed
		view:  Mat4,
		color: [4]f32,
		size:  [2]u32,
	}
	keyed := Keyed{view, color, {w, h}}
	key := max(hash.fnv64a(slice.bytes_from_ptr(&keyed, size_of(keyed))), 1)
	if key == nh.key do return nh.target.color

	item := Draw_Item{mesh = &nh.mesh, model = IDENTITY, color = color, damage = geom.AABB_EMPTY}
	pass := begin_mesh_pass(r, cmd, &r.single, nh.target.color, nh.target.depth, load = false, keep_depth = false, background = {0, 0, 0, 0})
	draw_items(r, cmd, pass, &r.single, view, proj, {item}, nil, nil)
	gpu_end_render_pass(pass)
	nh.key = key
	return nh.target.color
}
