// Package render owns every GPU object the app creates. It draws the sculpt viewport into
// an offscreen texture that the interface then shows (ui_pass.odin); it never reads or
// writes interface state.
package render

import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import sdl "vendor:sdl3"

import "../geom"

Mat4 :: matrix[4, 4]f32
IDENTITY :: Mat4(1)

VIEWPORT_COLOR_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

Renderer :: struct {
	device:        ^sdl.GPUDevice,
	window:        ^sdl.Window,
	depth_format:  sdl.GPUTextureFormat,
	depth_sampled: bool, // shaders can read depth_format textures (the studio render needs to)
	// The mesh pipelines at one sample, for thumbnails, the navigation head and a
	// viewport without anti-aliasing, and at `samples` for an anti-aliased viewport
	// (empty while samples is 1). A pipeline draws only into targets of its count.
	single:         Mesh_Pipelines,
	multi:          Mesh_Pipelines,
	samples:        sdl.GPUSampleCount, // the viewport's multisampling; see renderer_set_msaa
	// Bound in place of a mesh's paint buffer when it has none: the mesh shader reads
	// the binding only for items that show paint or groups, but it must be bound.
	no_paint:       ^sdl.GPUBuffer,
	// Bound in place of a matcap for items that have none, as no_paint is; and the
	// filtering, mipmapped sampler every matcap is read through.
	no_matcap:      ^sdl.GPUTexture,
	matcap_sampler: ^sdl.GPUSampler,
	// Bound in place of a textured mesh's normal map when it has none (a flat normal);
	// its base colour and ORM stand-in is no_matcap, white. The textured maps' sampler:
	// filtering, mipmapped, repeating, and anisotropic where the device allows it.
	no_normal_map:   ^sdl.GPUTexture,
	texture_sampler: ^sdl.GPUSampler,
	anisotropy:      bool, // the device was made with anisotropic filtering
	last_version:   u64,  // source of Mesh_Buffers.version
	cull:           bool, // skip off-screen and back-facing chunks of items that have them
	partial:        bool, // while the camera and objects stay put, redraw only what changed
	present_mode:   sdl.GPUPresentMode, // how frames reach the screen; see renderer_set_vsync
	// How far, in pixels, a full redraw may draw a group of chunks from its simplified
	// copy instead (see Draw_Item.lod); 0 draws everything at full detail. The app
	// sets it while the view moves.
	lod_px:         f32,
	// The floor grid the viewport draws behind and among its items; set by the app each
	// frame, as lod_px is.
	floor:          Floor_Grid,
	// What the viewport shows behind everything; set by the app each frame, as floor is.
	background:     Background,
	// The image environment the physically based materials light with (environment.odin),
	// nil for the built-in studio, and how it shows; set by the app each frame. The app
	// owns the environment. Bound in its place while there is none: a black texture; and
	// the sampler both are read through: filtering, mipmapped, repeating round the
	// panorama and clamped at its poles.
	environment:      ^Environment,
	environment_look: Environment_Look,
	no_environment:   ^sdl.GPUTexture,
	env_sampler:      ^sdl.GPUSampler,
}

// The viewport's background in display values, written as-is: `top` along the top edge
// shading to `bottom` along the bottom one, and one flat colour when the two are equal.
Background :: struct {
	top, bottom: [4]f32,
}

// Matches Clear_Uniforms in clear.frag.
Clear_Uniforms :: struct {
	using background: Background,
	extent:           [4]f32, // x: the target's height in pixels, y: its width
	env:              [4]f32, // x: 1 to show the environment, y: its strength, z: the level shown, w: the exposure
	clip_to_env:      Mat4,   // the inverse projection, then the view's turn into the panorama's axes
}
#assert(size_of(Clear_Uniforms) == 128)

// The grid drawn on up to three planes square to the world's axes, round the scene: per
// axis, whether the plane across it shows (`shown`, as 1 or 0, so the struct hashes with no
// padding) and where along the axis it sits (`at`); the side of a cell; how far from
// `center` its lines fade out; and whether the axes' own lines show in their colours.
Floor_Grid :: struct {
	shown:  [3]b32,
	at:     [3]f32,
	center: [3]f32,
	cell:   f32,
	radius: f32,
	axes:   b32,
}
#assert(size_of(Floor_Grid) == 48)

// Matches Floor_Uniforms in floor.frag.
Floor_Uniforms :: struct {
	inv_view_proj: Mat4,
	view_proj:     Mat4,
	plane:         [4]f32, // x: the axis across the plane, y: where along it the plane sits
	grid:          [4]f32, // x: a cell's side, y: the fade radius, z: 1 to draw the axes
	center:        [4]f32,
}

// The pipelines that draw meshes into targets of one sample count.
Mesh_Pipelines :: struct {
	mesh:  ^sdl.GPUGraphicsPipeline,
	// The same shaders drawing triangle edges as lines, pulled toward the eye so they
	// show over the surface they outline; nil where the device cannot draw lines.
	wire:  ^sdl.GPUGraphicsPipeline,
	// Fills the target, or a scissored rectangle of it, with the background at the far plane.
	clear: ^sdl.GPUGraphicsPipeline,
	// The mesh shaders blending over what is behind and leaving the depth be, for items
	// drawn see-through (Draw_Item.look.w); nil where the device refused it, and those items
	// are then drawn solid.
	see:   ^sdl.GPUGraphicsPipeline,
	// The floor grid (Floor_Grid), one full-screen triangle a plane; nil where the device
	// refused it, and the grid is then not drawn.
	floor: ^sdl.GPUGraphicsPipeline,
	// Textured meshes (textured.odin), opaque and see-through; nil where the device refused
	// them, and those items then draw through their sculpt buffers as clay.
	textured:     ^sdl.GPUGraphicsPipeline,
	textured_see: ^sdl.GPUGraphicsPipeline,
}

// How a mesh pipeline draws its triangles: filled and opaque, as lines, or filled and
// blended (see-through).
@(private)
Mesh_Mode :: enum u8 {
	Solid,
	Wire,
	See_Through,
}

// The flat grey the viewport shows until the app sets Renderer.background, in display
// values written as-is (like the mesh shader's output).
BACKGROUND :: [4]f32{0.17, 0.17, 0.17, 1}

// A partial redraw is skipped in favour of a full one when the changed rectangle
// covers more than this share of the viewport.
PARTIAL_MAX_AREA :: 0.6

// Offscreen colour + depth pair the 3D viewport renders into. Recreated on resize.
Viewport_Target :: struct {
	color:  ^sdl.GPUTexture, // one sample, sampled: what the interface shows and screenshots read
	depth:  ^sdl.GPUTexture, // at `samples`; shaders can read it only at one sample
	// With multisampling, what passes draw into, kept between frames so a partial redraw
	// can load it, and resolved into `color` at the end of every pass; nil at one sample.
	multi_color: ^sdl.GPUTexture,
	samples: sdl.GPUSampleCount,
	width:  u32,
	height: u32,
	cache:  Static_Cache, // at `samples`
	// Identifies what color and depth hold: camera, size, and every item's identity,
	// transform and colour (not its contents, which Draw_Item.damage accounts for).
	// 0 when they hold nothing reusable.
	frame_key: u64,
}

// Colour and depth of everything that is not `live`, as last drawn. While the camera
// and those objects stay put (all through a brush stroke), each frame copies this in
// and draws only the live objects on top, so idle meshes cost a screen-sized copy
// instead of all their triangles.
Static_Cache :: struct {
	color: ^sdl.GPUTexture,
	depth: ^sdl.GPUTexture,
	key:   u64, // hash of what the textures hold; 0 when they hold nothing
}

// GPU copy of a geom.Mesh. Positions (3 floats) and normals (octahedral, 2 snorm16)
// live in separate vertex buffers: 16 bytes a vertex. The transfer buffer is sized for
// typical per-frame sculpt updates, not the whole mesh; bigger uploads go through it
// in chunks.
Mesh_Buffers :: struct {
	positions:       ^sdl.GPUBuffer,
	normals:         ^sdl.GPUBuffer,
	indices:         ^sdl.GPUBuffer,
	transfer:        ^sdl.GPUTransferBuffer,
	transfer_size:   u32,
	vertex_capacity: u32,
	index_count:     u32,
	version:         u64, // changes whenever the buffers' contents do
	drawn_version:   u64, // version when last drawn into the viewport
	// The caller's stamp for index data that is not the mesh's own (the sculptor's
	// hidden triangles, mesh_buffers_upload_packed_indices); 0 for the mesh's own.
	hidden_stamp:    u32,

	// Culled drawing: one indirect draw command per visible run of chunks, rebuilt
	// each frame the mesh is drawn. Created on first use, sized for every chunk.
	indirect:          ^sdl.GPUBuffer,
	indirect_transfer: ^sdl.GPUTransferBuffer,
	indirect_capacity: u32, // commands
	draw_count:        u32, // commands recorded this frame
	visible:           [dynamic]geom.Index_Range, // scratch

	// Per vertex, a Paint_Packed: its polypaint and the polygroup it carries, read by the
	// mesh shader as a storage buffer (8 bytes a vertex). Nil until a mesh has paint or
	// groups (mesh_buffers_upload_paint).
	paint:       ^sdl.GPUBuffer,
	// The caller's stamp for what `paint` holds (the sculptor's paint stamp); 0 when it
	// holds nothing.
	paint_stamp: u32,

	// Simplified copies of groups of chunks (see Draw_Item.lod), drawn with indirect
	// commands that follow the draw_count full-detail ones. Created on first upload.
	lod_indices:    ^sdl.GPUBuffer,
	lod_capacity:   u32, // indices
	lod_draw_count: u32, // commands recorded this frame
	lod_visible:    [dynamic]geom.Index_Range, // scratch
}

Normal_Packed :: [2]i16
// Matches `paint` in mesh.vert: the colour's bytes red first, then the group.
Paint_Packed :: [2]u32
VERTEX_BYTES :: size_of(geom.Vec3) + size_of(Normal_Packed)

// Normals go up with the vertex's mask folded in: see geom.oct_encode_masked.
pack_normal :: geom.oct_encode_masked

// 16 MB holds positions and normals for 1M vertices: far more than a frame of
// sculpting changes, even with a large brush on a 10M vertex mesh.
TRANSFER_BUFFER_SIZE :: 16 << 20

// Matches Frame_Uniforms in mesh.vert (std140: column-major mat4s). Pushed per draw.
Frame_Uniforms :: struct {
	view_proj: Mat4,
	view:      Mat4,
	model:     Mat4,
	options:   [4]f32, // x: show the paint, y: show the polygroups, z: look up material slots
	slot_group: [GROUP_SLOTS]u32, // Material_Slots.groups, as mesh.vert's uvec4 slot_group[4]
}

// How many material slots an item has: slot 0 is its own material, the rest polygroups'.
GROUP_SLOTS :: 16

// Material_Slots.groups of a slot no polygroup uses.
SLOT_NONE :: max(u32)

// Polygroups shaded with materials of their own: slot k (from 1) shades the triangles of
// polygroup groups[k] with uniforms' entry k in place of the item's colour, shading and
// metal and roughness. groups[0] is unused (SLOT_NONE). The triangle's group is the one
// its first corner carries (Mesh_Buffers.paint), so the mesh needs its paint buffer.
Material_Slots :: struct {
	groups:   [GROUP_SLOTS]u32,
	uniforms: Slot_Uniforms,
}

// Matches Slot_Uniforms in mesh.frag (std140: arrays of vec4).
Slot_Uniforms :: struct {
	color:   [GROUP_SLOTS][4]f32, // as Draw_Item.color
	params:  [GROUP_SLOTS][4]f32, // as Draw_Item.material
	surface: [GROUP_SLOTS][4]f32, // x, y as Draw_Item.surface
}

// One mesh to draw this frame: where it sits in the world and its clay colour.
// `live` marks the object being worked on; everything else may come from the cache.
// With `chunks` (in index-buffer order, covering the mesh) and Renderer.cull, only the
// chunks that can be seen are drawn; `model` must then be a similarity (rotation,
// translation, uniform scale), as the culling transforms the eye into the mesh's space
// with its inverse and takes distances there.
Draw_Item :: struct {
	mesh:   ^Mesh_Buffers,
	model:  Mat4,
	color:  [4]f32,
	// Ambient, specular strength, specular power, and wrap (how far light reaches past
	// the side facing it, for a soft, waxy look); zero for the default clay.
	material:  [4]f32,
	// Metallic and roughness for physically based shading; a roughness of 0 keeps the
	// classic shading `material` describes.
	surface:   [2]f32,
	flat:      bool, // shade each triangle with its own normal instead of the smoothed ones
	wireframe: bool, // draw its triangles' edges over it
	paint:     bool, // draw its polypaint over the clay (needs Mesh_Buffers.paint)
	groups:    bool, // draw each triangle in its polygroup's colour instead (likewise)
	// The density preview's checker: xyz the first lattice point in mesh space, w the
	// cell size; zero for none.
	checker:   [4]f32,
	// How the shading is shown: x the exposure in stops, y how much creases darken
	// (cavity) and z how much crests lighten (ridge), 0 to 1; zero shows it plainly.
	look:      [4]f32,
	// A matcap (matcap_create) that shades the item instead of the lights, tinted by
	// `color`; nil for none.
	matcap:    ^sdl.GPUTexture,
	// The light rig: the columns of the rotation that takes the shader's key and fill
	// lights and its studio into view space, with the key light's strength in [0].w and
	// the fill's in [1].w; zero for DEFAULT_LIGHTS, fixed to the camera.
	lights:    [3][4]f32,
	// Polygroups with materials of their own; nil for none. Read during the frame only.
	slots:     ^Material_Slots,
	// A textured mesh drawn in place of `mesh`'s triangles while `texture_view` is not
	// .Off (textured.odin); `mesh` still draws the wireframe and stands for the item in
	// the frame keys and damage boxes. Nil for none.
	textured:     ^Textured_Mesh,
	texture_view: Texture_View,
	live:   bool,
	chunks: []geom.Chunk,
	chunk_groups: []geom.Chunk, // geom.chunk_group of each geom.CHUNK_GROUP chunks, to cull a group at a time; nil to test every chunk
	// Mesh-space box around everything that changed since the previous frame, before
	// and after the change; empty (lo > hi) when nothing did. A mesh whose buffers
	// changed without a damage box makes the next frame a full redraw.
	damage: geom.Aabb,
	// The mesh's simplification tree over `chunks`, whose copies are in the mesh's LOD
	// buffer (mesh_buffers_upload_lod). While Renderer.lod_px is above 0, full redraws
	// draw a group's copy instead of its chunks wherever that strays less than lod_px.
	lod:    geom.Lod,
	// Per chunk, then per group of `lod`: left out, whether culling is on or not (another
	// item draws that part, as an HD window does); nil to draw everything.
	hidden: []bool,
}

// What render_viewport did this frame, for the stats panel.
Viewport_Stats :: struct {
	triangles:     u64,  // triangles submitted
	draws:         u64,  // draw commands (indirect ones counted one by one)
	chunks:        u64,  // chunks considered for culling
	culled_view:   u64,  // ...outside the view
	culled_back:   u64,  // ...facing away
	simplified:    u64,  // groups of chunks drawn from their simplified copies
	cull_ms:       f64,  // CPU time spent culling and writing draw commands
	partial:       bool, // kept the previous frame and redrew only `redrawn_px` pixels
	redrawn_px:    u64,
	cache_used:    bool, // idle objects came from the cache
	cache_redrawn: bool, // ...which had to be redrawn first
}

// Matches Material_Uniforms in mesh.frag.
Material_Uniforms :: struct {
	base_color: [4]f32,
	params:     [4]f32, // x: ambient, y: specular strength, z: specular power, w: wrap
	surface:    [4]f32, // x: metallic, y: roughness (0: classic), z: 1 for flat shading, w: 1 for the matcap
	checker:    [4]f32, // the density preview: first lattice point, cell size (0: none)
	look:       [4]f32, // exposure in stops, cavity, ridge (Draw_Item.look)
	lights:     [3][4]f32, // the light rig's turn and strengths (Draw_Item.lights)
	maps:       [4]f32, // textured items: x, y, z which maps are bound (base colour, ORM, normal), w the Texture_View; zero otherwise
	// The image environment (environment.odin's material_environment); zero for the studio.
	env:        [4]f32, // x: 1 when bound, y: its strength, z: its prefiltered levels less one
	env_axes:   [3][4]f32, // the panorama's axes in view space (Environment_Look.rotation)
	env_sh:     [9][4]f32, // its diffuse light's harmonics, rgb
}
#assert(size_of(Material_Uniforms) == 352)

MESH_VERT_SPV :: #load("shaders/mesh.vert.spv")
MESH_FRAG_SPV :: #load("shaders/mesh.frag.spv")
TEXTURED_VERT_SPV :: #load("shaders/textured.vert.spv")
TEXTURED_FRAG_SPV :: #load("shaders/textured.frag.spv")
CLEAR_VERT_SPV :: #load("shaders/clear.vert.spv")
CLEAR_FRAG_SPV :: #load("shaders/clear.frag.spv")
FLOOR_VERT_SPV :: #load("shaders/floor.vert.spv")
FLOOR_FRAG_SPV :: #load("shaders/floor.frag.spv")

renderer_init :: proc(r: ^Renderer, window: ^sdl.Window, debug: bool) -> bool {
	r.window = window
	r.background = {BACKGROUND, BACKGROUND}
	when ODIN_PLATFORM_SUBTARGET == .Android {
		// Tablet GPUs may lack Vulkan features SDL asks for by default; nothing here clips
		// with gl_ClipDistance, samples anisotropically or starts an indirect draw past
		// instance 0, so those three are not required.
		props := sdl.CreateProperties()
		defer sdl.DestroyProperties(props)
		_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true)
		_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, debug)
		_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_FEATURE_CLIP_DISTANCE_BOOLEAN, false)
		_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_FEATURE_ANISOTROPY_BOOLEAN, false)
		_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_FEATURE_INDIRECT_DRAW_FIRST_INSTANCE_BOOLEAN, false)
		r.device = sdl.CreateGPUDeviceWithProperties(props)
	} else {
		r.device = sdl.CreateGPUDevice({.SPIRV}, debug, nil)
		r.anisotropy = true
	}
	if r.device == nil {
		log.errorf("CreateGPUDevice failed: %s", sdl.GetError())
		return false
	}
	log.infof("GPU: %s", gpu_description(r))
	if !sdl.ClaimWindowForGPUDevice(r.device, window) {
		log.errorf("ClaimWindowForGPUDevice failed: %s", sdl.GetError())
		return false
	}

	// A depth format shaders can also read, for the studio render, where there is one.
	r.depth_format = .D32_FLOAT
	for format in ([2]sdl.GPUTextureFormat{.D32_FLOAT, .D24_UNORM}) {
		if sdl.GPUTextureSupportsFormat(r.device, format, .D2, {.DEPTH_STENCIL_TARGET, .SAMPLER}) {
			r.depth_format, r.depth_sampled = format, true
			break
		}
	}
	if !r.depth_sampled && !sdl.GPUTextureSupportsFormat(r.device, r.depth_format, .D2, {.DEPTH_STENCIL_TARGET}) {
		r.depth_format = .D24_UNORM
	}

	r.single = mesh_pipelines_create(r, ._1)
	if r.single.wire == nil do log.warn("wireframe: this device cannot draw lines; the wireframe stays off")
	r.no_paint = sdl.CreateGPUBuffer(r.device, {usage = {.GRAPHICS_STORAGE_READ}, size = size_of(Paint_Packed)})
	if r.no_paint == nil do log.errorf("paint buffer creation failed: %s", sdl.GetError())
	white := [4]u8{255, 255, 255, 255}
	r.no_matcap = matcap_create(r, white[:], 1, 1)
	r.matcap_sampler = sdl.CreateGPUSampler(r.device, {
		min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		max_lod = 1000,
	})
	if r.matcap_sampler == nil do log.errorf("matcap sampler: %s", sdl.GetError())
	flat_normal := [4]u8{128, 128, 255, 255}
	r.no_normal_map = texture_create(r, TEXTURE_FORMATS[.Normal], flat_normal[:], 1, 1)
	r.texture_sampler = sdl.CreateGPUSampler(r.device, {
		min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .LINEAR,
		address_mode_u = .REPEAT, address_mode_v = .REPEAT, address_mode_w = .REPEAT,
		max_lod = 1000, max_anisotropy = 8, enable_anisotropy = r.anisotropy,
	})
	if r.texture_sampler == nil do log.errorf("texture sampler: %s", sdl.GetError())
	black := [4]u8{0, 0, 0, 255}
	r.no_environment = texture_create(r, .R8G8B8A8_UNORM, black[:], 1, 1)
	r.env_sampler = sdl.CreateGPUSampler(r.device, {
		min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .LINEAR,
		address_mode_u = .REPEAT, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		max_lod = 1000,
	})
	if r.env_sampler == nil do log.errorf("environment sampler: %s", sdl.GetError())
	if r.single.textured == nil do log.warn("textures: the textured pipeline could not be made; textured objects draw as clay")
	return r.single.mesh != nil && r.single.clear != nil && r.no_paint != nil && r.no_matcap != nil && r.matcap_sampler != nil && r.no_normal_map != nil && r.texture_sampler != nil && r.no_environment != nil && r.env_sampler != nil
}

// The GPU's name, backend and driver version, for logs and benchmark reports.
// Temp-allocated.
gpu_description :: proc(r: ^Renderer) -> string {
	props := sdl.GetGPUDeviceProperties(r.device)
	name := sdl.GetStringProperty(props, sdl.PROP_GPU_DEVICE_NAME_STRING, "unknown GPU")
	version := sdl.GetStringProperty(props, sdl.PROP_GPU_DEVICE_DRIVER_VERSION_STRING, "unknown")
	return fmt.tprintf("%s (%s, driver %s)", name, sdl.GetGPUDeviceDriver(r.device), version)
}

// Picks how frames reach the screen. With vsync (the default), a frame waits for the
// display's refresh: no tearing, and the frame rate is capped at the refresh rate.
// Without, a frame is shown as soon as it is ready: mailbox where the window offers it
// (no tearing; a newer frame replaces one still waiting), else immediate (may tear).
// Returns false, keeping the current mode, when the window offers neither or the
// change fails. Recreates the swapchain, so it must not be called while a swapchain
// texture is acquired.
renderer_set_vsync :: proc(r: ^Renderer, vsync: bool) -> bool {
	mode := sdl.GPUPresentMode.VSYNC
	if !vsync {
		switch {
		case sdl.WindowSupportsGPUPresentMode(r.device, r.window, .MAILBOX):
			mode = .MAILBOX
		case sdl.WindowSupportsGPUPresentMode(r.device, r.window, .IMMEDIATE):
			mode = .IMMEDIATE
		case:
			log.warn("vsync stays on: the display offers no other present mode")
			return false
		}
	}
	if mode == r.present_mode do return true
	if !sdl.SetGPUSwapchainParameters(r.device, r.window, .SDR, mode) {
		log.errorf("SetGPUSwapchainParameters failed: %s", sdl.GetError())
		return false
	}
	r.present_mode = mode
	log.infof("present mode: %v", mode)
	return true
}

// Waits for the GPU, then releases everything the renderer created, in reverse order.
renderer_destroy :: proc(r: ^Renderer) {
	if r.device == nil do return
	_ = sdl.WaitForGPUIdle(r.device)
	mesh_pipelines_destroy(r, &r.single)
	mesh_pipelines_destroy(r, &r.multi)
	if r.no_paint != nil do sdl.ReleaseGPUBuffer(r.device, r.no_paint)
	if r.no_matcap != nil do sdl.ReleaseGPUTexture(r.device, r.no_matcap)
	if r.matcap_sampler != nil do sdl.ReleaseGPUSampler(r.device, r.matcap_sampler)
	if r.no_normal_map != nil do sdl.ReleaseGPUTexture(r.device, r.no_normal_map)
	if r.texture_sampler != nil do sdl.ReleaseGPUSampler(r.device, r.texture_sampler)
	if r.no_environment != nil do sdl.ReleaseGPUTexture(r.device, r.no_environment)
	if r.env_sampler != nil do sdl.ReleaseGPUSampler(r.device, r.env_sampler)
	sdl.ReleaseWindowFromGPUDevice(r.device, r.window)
	sdl.DestroyGPUDevice(r.device)
	r^ = {}
}

// Sets how many samples a viewport pixel takes: ._1 for none, or ._2, ._4 or ._8 to
// smooth the edges of silhouettes and wireframe lines (MSAA). Where the device cannot
// use the count asked for with both the colour and the depth format, it tries the other
// of 2 and 4 (Vulkan promises 4), then none. Returns what it set; the viewport target
// is remade at that count on its next viewport_target_resize. Waits for the GPU when
// it changes anything.
renderer_set_msaa :: proc(r: ^Renderer, want: sdl.GPUSampleCount) -> sdl.GPUSampleCount {
	supported :: proc(r: ^Renderer, count: sdl.GPUSampleCount) -> bool {
		return count == ._1 || sdl.GPUTextureSupportsSampleCount(r.device, VIEWPORT_COLOR_FORMAT, count) && sdl.GPUTextureSupportsSampleCount(r.device, r.depth_format, count)
	}
	got := sdl.GPUSampleCount._1
	other := sdl.GPUSampleCount._4 if want == ._2 else ._2
	switch {
	case supported(r, want):                  got = want
	case want != ._1 && supported(r, other): got = other
	}
	if got == r.samples do return got
	_ = sdl.WaitForGPUIdle(r.device)
	mesh_pipelines_destroy(r, &r.multi)
	if got != ._1 {
		r.multi = mesh_pipelines_create(r, got)
		if r.multi.mesh == nil || r.multi.clear == nil {
			log.warnf("anti-aliasing stays off: the %v pipelines could not be made", got)
			mesh_pipelines_destroy(r, &r.multi)
			got = ._1
		}
	}
	if got != want do log.infof("anti-aliasing: %v asked for, %v used", want, got)
	r.samples = got
	return got
}

// The pipelines that draw into targets of `samples`.
@(private)
mesh_pipelines :: proc(r: ^Renderer, samples: sdl.GPUSampleCount) -> ^Mesh_Pipelines {
	return &r.multi if samples != ._1 else &r.single
}

@(private)
mesh_pipelines_create :: proc(r: ^Renderer, samples: sdl.GPUSampleCount) -> Mesh_Pipelines {
	return {
		mesh = create_mesh_pipeline(r, .Solid, samples),
		wire = create_mesh_pipeline(r, .Wire, samples),
		clear = create_clear_pipeline(r, samples),
		see = create_mesh_pipeline(r, .See_Through, samples),
		floor = create_floor_pipeline(r, samples),
		textured = create_mesh_pipeline(r, .Solid, samples, textured = true),
		textured_see = create_mesh_pipeline(r, .See_Through, samples, textured = true),
	}
}

@(private)
mesh_pipelines_destroy :: proc(r: ^Renderer, p: ^Mesh_Pipelines) {
	for pipeline in ([7]^sdl.GPUGraphicsPipeline{p.mesh, p.wire, p.clear, p.see, p.floor, p.textured, p.textured_see}) do if pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, pipeline)
	p^ = {}
}

// With `textured`, the pipeline of textured meshes (textured.odin): their 32-byte
// interleaved vertex, no paint buffer, the MatCap, the environment and three maps, and no
// polygroup slots. Every mesh pipeline samples the MatCap and the environment.
@(private)
create_mesh_pipeline :: proc(r: ^Renderer, mode: Mesh_Mode, samples: sdl.GPUSampleCount, textured := false) -> ^sdl.GPUGraphicsPipeline {
	vert_spv, frag_spv := MESH_VERT_SPV, MESH_FRAG_SPV
	if textured do vert_spv, frag_spv = TEXTURED_VERT_SPV, TEXTURED_FRAG_SPV
	vert := sdl.CreateGPUShader(r.device, {
		code_size           = len(vert_spv),
		code                = raw_data(vert_spv),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .VERTEX,
		num_uniform_buffers = 1,
		num_storage_buffers = 0 if textured else 1,
	})
	frag := sdl.CreateGPUShader(r.device, {
		code_size           = len(frag_spv),
		code                = raw_data(frag_spv),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .FRAGMENT,
		num_samplers        = 5 if textured else 2,
		num_uniform_buffers = 1 if textured else 2,
	})
	// Shaders are only needed until the pipeline is built.
	defer if vert != nil do sdl.ReleaseGPUShader(r.device, vert)
	defer if frag != nil do sdl.ReleaseGPUShader(r.device, frag)
	if vert == nil || frag == nil {
		log.errorf("CreateGPUShader failed: %s", sdl.GetError())
		return nil
	}

	buffers := [2]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of(geom.Vec3), input_rate = .VERTEX},
		{slot = 1, pitch = size_of(Normal_Packed), input_rate = .VERTEX},
	}
	attributes := [4]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3},
		{location = 1, buffer_slot = 1, format = .SHORT2_NORM},
		{}, {},
	}
	num_buffers, num_attributes := 2, 2
	if textured {
		buffers[0] = {slot = 0, pitch = size_of(Textured_Vertex), input_rate = .VERTEX}
		attributes = {
			{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Textured_Vertex, position))},
			{location = 1, buffer_slot = 0, format = .SHORT2_NORM, offset = u32(offset_of(Textured_Vertex, normal))},
			{location = 2, buffer_slot = 0, format = .SHORT4_NORM, offset = u32(offset_of(Textured_Vertex, tangent))},
			{location = 3, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Textured_Vertex, uv))},
		}
		num_buffers, num_attributes = 1, 4
	}
	wire := mode == .Wire
	color_targets := [1]sdl.GPUColorTargetDescription{{format = VIEWPORT_COLOR_FORMAT, blend_state = BLEND_OVER if mode == .See_Through else {}}}

	pipeline := sdl.CreateGPUGraphicsPipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = u32(num_buffers),
			vertex_attributes = &attributes[0],
			num_vertex_attributes = u32(num_attributes),
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = wire ? sdl.GPURasterizerState{
			fill_mode = .LINE, cull_mode = .BACK, front_face = .COUNTER_CLOCKWISE,
			// Toward the eye, so a line wins against the triangle it borders.
			enable_depth_bias = true, depth_bias_constant_factor = -2, depth_bias_slope_factor = -1,
		} : sdl.GPURasterizerState{fill_mode = .FILL, cull_mode = .BACK, front_face = .COUNTER_CLOCKWISE},
		depth_stencil_state = {compare_op = .LESS_OR_EQUAL if wire else .LESS, enable_depth_test = true, enable_depth_write = mode == .Solid},
		multisample_state = {sample_count = samples},
		target_info = {
			color_target_descriptions = &color_targets[0],
			num_color_targets = len(color_targets),
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	switch {
	case pipeline != nil:
	case textured:
		log.warnf("textured %v pipeline: %s", mode, sdl.GetError())
	case mode == .Solid:
		log.errorf("CreateGPUGraphicsPipeline failed: %s", sdl.GetError())
	case mode == .See_Through:
		log.warnf("see-through objects are drawn solid: the blended pipeline could not be made: %s", sdl.GetError())
	}
	return pipeline
}

// Colour blended over what is there by the source's alpha; the target's alpha kept as it
// is, so the viewport image stays opaque wherever the interface shows it.
@(private)
BLEND_OVER :: sdl.GPUColorTargetBlendState {
	enable_blend          = true,
	src_color_blendfactor = .SRC_ALPHA,
	dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
	color_blend_op        = .ADD,
	src_alpha_blendfactor = .ZERO,
	dst_alpha_blendfactor = .ONE,
	alpha_blend_op        = .ADD,
}

@(private)
create_floor_pipeline :: proc(r: ^Renderer, samples: sdl.GPUSampleCount) -> ^sdl.GPUGraphicsPipeline {
	vert := sdl.CreateGPUShader(r.device, {
		code_size = len(FLOOR_VERT_SPV), code = raw_data(FLOOR_VERT_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .VERTEX,
	})
	frag := sdl.CreateGPUShader(r.device, {
		code_size = len(FLOOR_FRAG_SPV), code = raw_data(FLOOR_FRAG_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .FRAGMENT, num_uniform_buffers = 1,
	})
	defer if vert != nil do sdl.ReleaseGPUShader(r.device, vert)
	defer if frag != nil do sdl.ReleaseGPUShader(r.device, frag)
	if vert == nil || frag == nil {
		log.warnf("the floor grid stays off: its shaders could not be made: %s", sdl.GetError())
		return nil
	}
	color_targets := [1]sdl.GPUColorTargetDescription{{format = VIEWPORT_COLOR_FORMAT, blend_state = BLEND_OVER}}
	pipeline := sdl.CreateGPUGraphicsPipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		// Tested against the meshes' depth, which it leaves as it is.
		depth_stencil_state = {compare_op = .LESS_OR_EQUAL, enable_depth_test = true, enable_depth_write = false},
		multisample_state = {sample_count = samples},
		target_info = {
			color_target_descriptions = &color_targets[0],
			num_color_targets = len(color_targets),
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	if pipeline == nil do log.warnf("the floor grid stays off: its pipeline could not be made: %s", sdl.GetError())
	return pipeline
}

@(private)
create_clear_pipeline :: proc(r: ^Renderer, samples: sdl.GPUSampleCount) -> ^sdl.GPUGraphicsPipeline {
	vert := sdl.CreateGPUShader(r.device, {
		code_size = len(CLEAR_VERT_SPV), code = raw_data(CLEAR_VERT_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .VERTEX,
	})
	frag := sdl.CreateGPUShader(r.device, {
		code_size = len(CLEAR_FRAG_SPV), code = raw_data(CLEAR_FRAG_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1, num_uniform_buffers = 1,
	})
	defer if vert != nil do sdl.ReleaseGPUShader(r.device, vert)
	defer if frag != nil do sdl.ReleaseGPUShader(r.device, frag)
	if vert == nil || frag == nil {
		log.errorf("CreateGPUShader failed: %s", sdl.GetError())
		return nil
	}
	color_targets := [1]sdl.GPUColorTargetDescription{{format = VIEWPORT_COLOR_FORMAT}}
	pipeline := sdl.CreateGPUGraphicsPipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		// Writes far-plane depth everywhere it lands, whatever was there.
		depth_stencil_state = {compare_op = .ALWAYS, enable_depth_test = true, enable_depth_write = true},
		multisample_state = {sample_count = samples},
		target_info = {
			color_target_descriptions = &color_targets[0],
			num_color_targets = len(color_targets),
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	if pipeline == nil {
		log.errorf("CreateGPUGraphicsPipeline (clear) failed: %s", sdl.GetError())
	}
	return pipeline
}

// Ensures the target matches the requested size and sample count (the main viewport
// passes Renderer.samples; thumbnails and the navigation head stay at one sample, as the
// interface samples them). Old textures are released; SDL_GPU defers the actual free
// until in-flight command buffers no longer reference them.
viewport_target_resize :: proc(r: ^Renderer, vt: ^Viewport_Target, requested_width, requested_height: u32, samples := sdl.GPUSampleCount._1) -> bool {
	width, height := max(requested_width, 1), max(requested_height, 1)
	if vt.color != nil && vt.width == width && vt.height == height && vt.samples == samples do return true
	viewport_target_destroy(r, vt)

	multi := samples != ._1
	vt.color = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
	})
	if multi {
		vt.multi_color = sdl.CreateGPUTexture(r.device, {
			type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET},
			width = width, height = height, layer_count_or_depth = 1, num_levels = 1, sample_count = samples,
		})
	}
	// A multisampled texture cannot be sampled: the studio render draws its own depth then.
	vt.depth = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET, .SAMPLER} if r.depth_sampled && !multi else {.DEPTH_STENCIL_TARGET},
		width = width, height = height, layer_count_or_depth = 1, num_levels = 1, sample_count = samples,
	})
	if vt.color == nil || vt.depth == nil || multi && vt.multi_color == nil {
		log.errorf("viewport target creation failed: %s", sdl.GetError())
		viewport_target_destroy(r, vt)
		return false
	}
	vt.width, vt.height, vt.samples = width, height, samples
	return true
}

viewport_target_destroy :: proc(r: ^Renderer, vt: ^Viewport_Target) {
	for t in ([5]^sdl.GPUTexture{vt.color, vt.depth, vt.multi_color, vt.cache.color, vt.cache.depth}) do if t != nil do sdl.ReleaseGPUTexture(r.device, t)
	vt^ = {}
}

// Creates the cache textures on first use, at the target's size. They are released
// with the target, so a resize recreates them.
@(private)
static_cache_ensure :: proc(r: ^Renderer, vt: ^Viewport_Target) -> bool {
	if vt.cache.color != nil do return true
	vt.cache.color = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1, sample_count = vt.samples,
	})
	vt.cache.depth = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1, sample_count = vt.samples,
	})
	vt.cache.key = 0
	if vt.cache.color == nil || vt.cache.depth == nil {
		log.errorf("viewport cache creation failed: %s", sdl.GetError())
		if vt.cache.color != nil do sdl.ReleaseGPUTexture(r.device, vt.cache.color)
		if vt.cache.depth != nil do sdl.ReleaseGPUTexture(r.device, vt.cache.depth)
		vt.cache = {}
		return false
	}
	return true
}

// Creates the GPU buffers for `mesh` and uploads all of it, in chunks through the
// transfer buffer, waiting for the GPU after each chunk. For loading, not per frame.
// `mask`, per vertex, is the sculptor's mask; nil when nothing is masked.
mesh_buffers_create :: proc(r: ^Renderer, mesh: geom.Mesh, mask: []u8 = nil) -> (mb: Mesh_Buffers, ok: bool) {
	vcount := u32(len(mesh.positions))
	icount := u32(len(mesh.indices))
	vbytes := vcount * size_of(geom.Vec3)
	nbytes := vcount * size_of(Normal_Packed)
	ibytes := icount * size_of(u32)

	mb.vertex_capacity = vcount
	mb.index_count = icount
	r.last_version += 1
	mb.version = r.last_version
	mb.transfer_size = TRANSFER_BUFFER_SIZE
	mb.positions = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = vbytes})
	mb.normals = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = nbytes})
	mb.indices = sdl.CreateGPUBuffer(r.device, {usage = {.INDEX}, size = ibytes})
	mb.transfer = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = mb.transfer_size})
	if mb.positions == nil || mb.normals == nil || mb.indices == nil || mb.transfer == nil {
		log.errorf("mesh buffer creation failed: %s", sdl.GetError())
		mesh_buffers_destroy(r, &mb)
		return {}, false
	}
	ok = upload_blocking(r, &mb, mb.indices, slice.to_bytes(mesh.indices[:])) &&
		upload_blocking(r, &mb, mb.positions, slice.to_bytes(mesh.positions[:])) &&
		upload_normals_blocking(r, &mb, mesh.normals[:], mask)
	if !ok {
		log.errorf("mesh upload failed: %s", sdl.GetError())
		mesh_buffers_destroy(r, &mb)
		return {}, false
	}
	return mb, true
}

// Copies `data` to the start of `buffer` one transfer buffer at a time.
@(private)
upload_blocking :: proc(r: ^Renderer, mb: ^Mesh_Buffers, buffer: ^sdl.GPUBuffer, data: []u8) -> bool {
	for offset := 0; offset < len(data); offset += int(mb.transfer_size) {
		chunk := data[offset:min(offset + int(mb.transfer_size), len(data))]
		dst := sdl.MapGPUTransferBuffer(r.device, mb.transfer, false)
		if dst == nil do return false
		copy(([^]u8)(dst)[:len(chunk)], chunk)
		sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
		cmd := sdl.AcquireGPUCommandBuffer(r.device)
		if cmd == nil do return false
		pass := sdl.BeginGPUCopyPass(cmd)
		sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer}, {buffer = buffer, offset = u32(offset), size = u32(len(chunk))}, false)
		sdl.EndGPUCopyPass(pass)
		if !sdl.SubmitGPUCommandBuffer(cmd) || !sdl.WaitForGPUIdle(r.device) do return false
	}
	return true
}

// Packs and copies every normal, one transfer buffer at a time.
@(private)
upload_normals_blocking :: proc(r: ^Renderer, mb: ^Mesh_Buffers, normals: []geom.Vec3, mask: []u8) -> bool {
	per_batch := int(mb.transfer_size / size_of(Normal_Packed))
	for first := 0; first < len(normals); first += per_batch {
		batch := normals[first:min(first + per_batch, len(normals))]
		dst := cast([^]Normal_Packed)sdl.MapGPUTransferBuffer(r.device, mb.transfer, false)
		if dst == nil do return false
		if mask != nil {
			for n, i in batch do dst[i] = pack_normal(n, mask[first + i])
		} else {
			for n, i in batch do dst[i] = pack_normal(n, 0)
		}
		sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
		cmd := sdl.AcquireGPUCommandBuffer(r.device)
		if cmd == nil do return false
		pass := sdl.BeginGPUCopyPass(cmd)
		size := u32(len(batch) * size_of(Normal_Packed))
		sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer}, {buffer = mb.normals, offset = u32(first * size_of(Normal_Packed)), size = size}, false)
		sdl.EndGPUCopyPass(pass)
		if !sdl.SubmitGPUCommandBuffer(cmd) || !sdl.WaitForGPUIdle(r.device) do return false
	}
	return true
}

mesh_buffers_destroy :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	if mb.positions != nil do sdl.ReleaseGPUBuffer(r.device, mb.positions)
	if mb.normals != nil do sdl.ReleaseGPUBuffer(r.device, mb.normals)
	if mb.indices != nil do sdl.ReleaseGPUBuffer(r.device, mb.indices)
	if mb.transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.transfer)
	if mb.indirect != nil do sdl.ReleaseGPUBuffer(r.device, mb.indirect)
	if mb.indirect_transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.indirect_transfer)
	if mb.lod_indices != nil do sdl.ReleaseGPUBuffer(r.device, mb.lod_indices)
	if mb.paint != nil do sdl.ReleaseGPUBuffer(r.device, mb.paint)
	delete(mb.visible)
	delete(mb.lod_visible)
	mb^ = {}
}

// Records copies of the positions and normals (with `mask`, nil when nothing is
// masked) of every vertex in `ranges` into `cmd`. Ranges are packed into the transfer
// buffer, which is cycled so an upload never stalls on the previous frame's copy; if
// they do not fit, they go in several batches.
mesh_buffers_upload_ranges :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, mesh: geom.Mesh, ranges: []geom.Vertex_Range, mask: []u8 = nil) {
	if len(ranges) > 0 {
		r.last_version += 1
		mb.version = r.last_version
	}
	capacity := mb.transfer_size / VERTEX_BYTES // vertices per batch
	pending := ranges
	split: geom.Vertex_Range // remainder of a range cut at a batch boundary
	for len(pending) > 0 || split.count > 0 {
		// Plan a batch: whole ranges, then part of the next if it does not fit.
		Planned :: struct {
			r:   geom.Vertex_Range,
			dst: u32,
		}
		batch: [dynamic; 256]Planned
		used: u32
		for used < capacity && len(batch) < cap(batch) {
			next: geom.Vertex_Range
			if split.count > 0 {
				next, split = split, {}
			} else if len(pending) > 0 {
				next, pending = pending[0], pending[1:]
			} else {
				break
			}
			assert(next.first + next.count <= mb.vertex_capacity)
			if next.count > capacity - used {
				split = {next.first + (capacity - used), next.count - (capacity - used)}
				next.count = capacity - used
			}
			append(&batch, Planned{next, used})
			used += next.count
		}

		// Positions for the batch first, then packed normals, each laid out by range.
		mapped := cast([^]u8)sdl.MapGPUTransferBuffer(r.device, mb.transfer, true)
		dst_p := cast([^]geom.Vec3)mapped
		dst_n := cast([^]Normal_Packed)(mapped[used * size_of(geom.Vec3):])
		for p in batch {
			copy(dst_p[p.dst:][:p.r.count], mesh.positions[p.r.first:][:p.r.count])
			if mask != nil {
				for n, k in mesh.normals[p.r.first:][:p.r.count] do dst_n[p.dst + u32(k)] = pack_normal(n, mask[p.r.first + u32(k)])
			} else {
				for n, k in mesh.normals[p.r.first:][:p.r.count] do dst_n[p.dst + u32(k)] = pack_normal(n, 0)
			}
		}
		sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
		pass := sdl.BeginGPUCopyPass(cmd)
		for p in batch {
			src_p := p.dst * size_of(geom.Vec3)
			src_n := used * size_of(geom.Vec3) + p.dst * size_of(Normal_Packed)
			sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer, offset = src_p}, {buffer = mb.positions, offset = p.r.first * size_of(geom.Vec3), size = p.r.count * size_of(geom.Vec3)}, false)
			sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer, offset = src_n}, {buffer = mb.normals, offset = p.r.first * size_of(Normal_Packed), size = p.r.count * size_of(Normal_Packed)}, false)
		}
		sdl.EndGPUCopyPass(pass)
	}
}

// Records copies of the paint data (colours, nil for none, and the groups vertices
// carry, nil for none) of every vertex in `ranges` into the mesh's paint buffer, or of
// every vertex when `all` or when the buffer has to be made first. Packs ranges into the
// transfer buffer like mesh_buffers_upload_ranges. On failure the buffer is dropped, so
// the mesh is drawn without paint until a later upload succeeds.
mesh_buffers_upload_paint :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, colors: [][4]u8, groups: []u16, ranges: []geom.Vertex_Range, all: bool) {
	ranges, all := ranges, all
	if mb.paint == nil {
		mb.paint = sdl.CreateGPUBuffer(r.device, {usage = {.GRAPHICS_STORAGE_READ}, size = max(mb.vertex_capacity, 1) * size_of(Paint_Packed)})
		if mb.paint == nil {
			log.errorf("paint buffer creation failed: %s", sdl.GetError())
			return
		}
		all = true
	}
	whole := [1]geom.Vertex_Range{{0, mb.vertex_capacity}}
	if all do ranges = whole[:]
	r.last_version += 1
	mb.version = r.last_version
	capacity := mb.transfer_size / size_of(Paint_Packed) // vertices per batch
	pending := ranges
	split: geom.Vertex_Range
	for len(pending) > 0 || split.count > 0 {
		Planned :: struct {
			r:   geom.Vertex_Range,
			dst: u32,
		}
		batch: [dynamic; 256]Planned
		used: u32
		for used < capacity && len(batch) < cap(batch) {
			next: geom.Vertex_Range
			if split.count > 0 {
				next, split = split, {}
			} else if len(pending) > 0 {
				next, pending = pending[0], pending[1:]
			} else {
				break
			}
			if next.count > capacity - used {
				split = {next.first + (capacity - used), next.count - (capacity - used)}
				next.count = capacity - used
			}
			append(&batch, Planned{next, used})
			used += next.count
		}
		dst := cast([^]Paint_Packed)sdl.MapGPUTransferBuffer(r.device, mb.transfer, true)
		if dst == nil {
			log.errorf("paint upload failed: %s", sdl.GetError())
			sdl.ReleaseGPUBuffer(r.device, mb.paint)
			mb.paint = nil
			return
		}
		for p in batch {
			for k in 0 ..< p.r.count {
				v := p.r.first + k
				x: Paint_Packed
				if colors != nil && int(v) < len(colors) do x[0] = transmute(u32)colors[v]
				if groups != nil && int(v) < len(groups) do x[1] = u32(groups[v])
				dst[p.dst + k] = x
			}
		}
		sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
		pass := sdl.BeginGPUCopyPass(cmd)
		for p in batch {
			sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer, offset = p.dst * size_of(Paint_Packed)}, {buffer = mb.paint, offset = p.r.first * size_of(Paint_Packed), size = p.r.count * size_of(Paint_Packed)}, false)
		}
		sdl.EndGPUCopyPass(pass)
	}
}

// Records copies of the `ranges` of `indices`, the mesh's simplified copies, into its
// LOD buffer; all of `indices` when `all`, or when the buffer has to be created or
// grown to hold them (first to `expected` indices, then by half again). Packs ranges
// into the transfer buffer like mesh_buffers_upload_ranges. On failure the buffer is
// dropped, so the mesh is drawn at full detail until a later upload succeeds.
mesh_buffers_upload_lod :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, indices: []u32, ranges: []geom.Index_Range, all: bool, expected := 0) {
	ranges, all := ranges, all
	if mb.lod_indices == nil || u32(len(indices)) > mb.lod_capacity {
		if mb.lod_indices != nil do sdl.ReleaseGPUBuffer(r.device, mb.lod_indices)
		capacity := max(u32(len(indices)) + u32(len(indices)) / 2, u32(expected), 1024)
		mb.lod_indices = sdl.CreateGPUBuffer(r.device, {usage = {.INDEX}, size = capacity * size_of(u32)})
		mb.lod_capacity = capacity if mb.lod_indices != nil else 0
		if mb.lod_indices == nil {
			log.errorf("LOD index buffer creation failed: %s", sdl.GetError())
			return
		}
		all = true
	}
	whole := [1]geom.Index_Range{{0, u32(len(indices))}}
	if all do ranges = whole[:]
	if !upload_index_ranges(r, cmd, mb, mb.lod_indices, indices, ranges) {
		log.errorf("LOD upload failed: %s", sdl.GetError())
		sdl.ReleaseGPUBuffer(r.device, mb.lod_indices)
		mb.lod_indices, mb.lod_capacity = nil, 0
	}
}

// Records copies of the `ranges` of `indices`, the mesh's own triangles, into its index
// buffer: for a mesh whose triangles change (the sculptor's dynamic topology).
mesh_buffers_upload_indices :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, indices: []u32, ranges: []geom.Index_Range) {
	if len(ranges) == 0 do return
	r.last_version += 1
	mb.version = r.last_version
	for x in ranges do assert(x.first_index + x.index_count <= mb.index_count)
	if !upload_index_ranges(r, cmd, mb, mb.indices, indices, ranges) do log.errorf("index upload failed: %s", sdl.GetError())
}

// Records copies of `indices`, which hold the `ranges` one after another, into those
// ranges of the mesh's index buffer: for index data that is not the mesh's own, such as
// a sculptor's triangles with the hidden ones made degenerate.
mesh_buffers_upload_packed_indices :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, indices: []u32, ranges: []geom.Index_Range) {
	if len(ranges) == 0 do return
	r.last_version += 1
	mb.version = r.last_version
	for x in ranges do assert(x.first_index + x.index_count <= mb.index_count)
	if !upload_index_ranges(r, cmd, mb, mb.indices, indices, ranges, packed = true) do log.errorf("index upload failed: %s", sdl.GetError())
}

// Packs index ranges into the transfer buffer, cycled, and records their copies into
// `buffer`, in as many batches as they need. The data of each range is at the same
// place in `indices`, or with `packed`, `indices` holds the ranges one after another.
@(private)
upload_index_ranges :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, buffer: ^sdl.GPUBuffer, indices: []u32, ranges: []geom.Index_Range, packed := false) -> bool {
	ranges := ranges
	capacity := mb.transfer_size / size_of(u32) // indices per batch
	split: geom.Index_Range // remainder of a range cut at a batch boundary
	read: u32 // with `packed`: where in `indices` the next piece starts
	for len(ranges) > 0 || split.index_count > 0 {
		Planned :: struct {
			r:   geom.Index_Range,
			dst: u32,
			src: u32,
		}
		batch: [dynamic; 256]Planned
		used: u32
		for used < capacity && len(batch) < cap(batch) {
			next: geom.Index_Range
			if split.index_count > 0 {
				next, split = split, {}
			} else if len(ranges) > 0 {
				next, ranges = ranges[0], ranges[1:]
			} else {
				break
			}
			if next.index_count == 0 do continue
			if next.index_count > capacity - used {
				split = {next.first_index + (capacity - used), next.index_count - (capacity - used)}
				next.index_count = capacity - used
			}
			append(&batch, Planned{next, used, read if packed else next.first_index})
			read += next.index_count
			used += next.index_count
		}
		if len(batch) == 0 do break
		dst := cast([^]u32)sdl.MapGPUTransferBuffer(r.device, mb.transfer, true)
		if dst == nil do return false
		for p in batch do copy(dst[p.dst:][:p.r.index_count], indices[p.src:][:p.r.index_count])
		sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
		pass := sdl.BeginGPUCopyPass(cmd)
		for p in batch {
			sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer, offset = p.dst * size_of(u32)}, {buffer = buffer, offset = p.r.first_index * size_of(u32), size = p.r.index_count * size_of(u32)}, false)
		}
		sdl.EndGPUCopyPass(pass)
	}
	return true
}

// Records the viewport: the live items over everything else. With `use_cache`, the
// other items are drawn into the cache only when they, the camera or the target size
// changed since the cache was filled; otherwise every item is drawn every frame.
//
// With Renderer.partial, a frame whose camera, size and items match the previous one
// keeps the previous colour and depth and redraws only the screen rectangle the items'
// damage boxes cover, or nothing at all when nothing changed.
render_viewport :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, use_cache: bool) -> (stats: Viewport_Stats) {
	key := frame_key(vt^, view, proj, items, r.lod_px, r.floor, r.background, environment_keyed(r))
	defer {
		vt.frame_key = key
		for item in items do item.mesh.drawn_version = item.mesh.version
	}
	// With multisampling a rectangle's edge may keep samples of the frame before (see
	// render_rect), which a see-through item blended again would show as a seam.
	pipes := mesh_pipelines(r, vt.samples)
	see := false
	for item in items do see ||= blended(pipes, item)
	if r.partial && key == vt.frame_key && !(see && vt.samples != ._1) {
		if rect, ok := damage_rect(vt^, view, proj, items); ok {
			stats.partial = true
			if rect.w > 0 && rect.h > 0 do render_rect(r, cmd, vt, view, proj, items, rect, &stats)
			return
		}
	}
	render_full(r, cmd, vt, view, proj, items, use_cache, &stats)
	return
}

// Makes the next frame redraw everything, cache included: for changes the frame keys
// cannot see, such as which chunks of an item are hidden.
viewport_invalidate :: proc(vt: ^Viewport_Target) {
	vt.frame_key = 0
	vt.cache.key = 0
}

// Pixel rectangle, top-left origin.
@(private)
Rect :: struct {
	x, y, w, h: i32,
}

// The viewport rectangle covering every item's damage box, padded by a couple of
// pixels; zero-sized when nothing on screen changed. ok is false when a full redraw is
// needed instead: an item changed without saying where, a box reaches behind the
// eye, or the rectangle is too large to be worth it.
@(private)
damage_rect :: proc(vt: Viewport_Target, view, proj: Mat4, items: []Draw_Item) -> (rect: Rect, ok: bool) {
	W, H := f32(vt.width), f32(vt.height)
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for item in items {
		b := item.damage
		damaged := b.lo.x <= b.hi.x
		if !damaged {
			if item.mesh.version != item.mesh.drawn_version do return {}, false
			continue
		}
		clip := proj * view * item.model
		for corner in 0 ..< 8 {
			p := [4]f32 {
				b.hi.x if corner & 1 != 0 else b.lo.x,
				b.hi.y if corner & 2 != 0 else b.lo.y,
				b.hi.z if corner & 4 != 0 else b.lo.z,
				1,
			}
			c := clip * p
			if c.w <= 1e-4 do return {}, false
			px := [2]f32{(c.x / c.w * 0.5 + 0.5) * W, (0.5 - c.y / c.w * 0.5) * H}
			lo = linalg.min(lo, px)
			hi = linalg.max(hi, px)
		}
	}
	if lo.x > hi.x do return {}, true // nothing changed
	PAD :: 2
	x0 := i32(clamp(math.floor(lo.x) - PAD, 0, W))
	y0 := i32(clamp(math.floor(lo.y) - PAD, 0, H))
	x1 := i32(clamp(math.ceil(hi.x) + PAD, 0, W))
	y1 := i32(clamp(math.ceil(hi.y) + PAD, 0, H))
	if x1 <= x0 || y1 <= y0 do return {}, true // changed only off screen
	if f32((x1 - x0) * (y1 - y0)) > PARTIAL_MAX_AREA * W * H do return {}, false
	return {x0, y0, x1 - x0, y1 - y0}, true
}

// Redraws one rectangle of the previous frame: clears it, then draws the chunks of
// every item that fall inside it, scissored to it.
@(private)
render_rect :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, rect: Rect, stats: ^Viewport_Stats) {
	// With multisampling the meshes are drawn one pixel wider than the rectangle that is
	// cleared. A rasterizer may test the scissor at each sample's position for triangles
	// crossing its edge (llvmpipe does), which would leave samples of the rectangle's edge
	// pixels with only the clear: a seam the full redraw does not have. The extra pixel
	// all round is drawn again at the depth it already holds, which the depth test keeps.
	drawn := rect
	if vt.samples != ._1 {
		x0, y0 := max(rect.x - 1, 0), max(rect.y - 1, 0)
		x1, y1 := min(rect.x + rect.w + 1, i32(vt.width)), min(rect.y + rect.h + 1, i32(vt.height))
		drawn = {x0, y0, x1 - x0, y1 - y0}
	}
	// Maps the drawn rectangle to the whole of clip space, so culling against the
	// narrowed frustum keeps only the chunks that can touch it.
	W, H := f32(vt.width), f32(vt.height)
	nx0, nx1 := 2 * f32(drawn.x) / W - 1, 2 * f32(drawn.x + drawn.w) / W - 1
	ny0, ny1 := 1 - 2 * f32(drawn.y + drawn.h) / H, 1 - 2 * f32(drawn.y) / H
	cx, hx := (nx0 + nx1) / 2, (nx1 - nx0) / 2
	cy, hy := (ny0 + ny1) / 2, (ny1 - ny0) / 2
	narrow := Mat4{
		1 / hx, 0, 0, -cx / hx,
		0, 1 / hy, 0, -cy / hy,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
	prepare_draws(r, cmd, view, proj, items, nil, stats, narrow)
	pipes := mesh_pipelines(r, vt.samples)
	pass := target_pass(r, cmd, vt, load = true)
	sdl.SetGPUScissor(pass, {rect.x, rect.y, rect.w, rect.h})
	draw_background(r, cmd, pass, pipes, vt^, proj, flat_too = true)
	if drawn != rect do sdl.SetGPUScissor(pass, {drawn.x, drawn.y, drawn.w, drawn.h})
	draw_scene(r, cmd, pass, pipes, view, proj, items, nil, stats, rect if drawn != rect else nil)
	sdl.EndGPURenderPass(pass)
	stats.redrawn_px = u64(rect.w) * u64(rect.h)
}

// Hash of what frame_key in Viewport_Target describes.
@(private)
frame_key :: proc(vt: Viewport_Target, view, proj: Mat4, items: []Draw_Item, lod_px: f32, floor: Floor_Grid, background: Background, environment: Environment_Keyed) -> u64 {
	Keyed :: struct {
		mesh:     ^Mesh_Buffers,
		matcap:   ^sdl.GPUTexture,
		model:    Mat4,
		color:    [4]f32,
		material: [4]f32,
		checker:  [4]f32,
		look:     [4]f32,
		lights:   [3][4]f32,
		surface:  [2]f32,
		wire:     b32,
		flat:     b32,
		paint:    b32,
		groups:   b32,
		slotted:  b32, // with Material_Slots, hashed after it
		_:        b32, // no padding: every byte is hashed
	}
	#assert(size_of(Keyed) == 224)
	Header :: struct { // no padding: every byte is hashed
		view, proj:    Mat4,
		width, height: u32,
		items:         u32,
		lod_px:        f32,
		floor:         Floor_Grid,
		background:    Background,
		environment:   Environment_Keyed,
	}
	#assert(size_of(Header) == 2 * size_of(Mat4) + 16 + size_of(Floor_Grid) + size_of(Background) + size_of(Environment_Keyed))
	header := Header{view, proj, vt.width, vt.height, u32(len(items)), lod_px, floor, background, environment}
	h := hash.fnv64a(slice.bytes_from_ptr(&header, size_of(header)))
	for item in items {
		k := Keyed{item.mesh, item.matcap, item.model, item.color, item.material, item.checker, item.look, item.lights, item.surface, b32(item.wireframe), b32(item.flat), b32(item.paint), b32(item.groups), item.slots != nil, false}
		h = hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k)), h)
		if item.slots != nil do h = hash.fnv64a(slice.bytes_from_ptr(item.slots, size_of(Material_Slots)), h)
		h = textured_key(item, h)
	}
	return max(h, 1)
}

// Folds what a textured item shows into a frame key: the mesh, its vertices, its maps and
// the view. Its vertices change when its sculpt buffers do (damage boxes cover those)
// but also when only its UVs do, which no damage box sees, so both keys take them: a
// textured object is small, and a full redraw when it changes costs little.
@(private)
textured_key :: proc(item: Draw_Item, h: u64) -> u64 {
	if item.textured == nil || item.texture_view == .Off do return h
	Keyed :: struct { // no padding: every byte is hashed
		mesh:       ^Textured_Mesh,
		maps_stamp: u64,
		stamp:      u64,
		view:       u64,
	}
	k := Keyed{item.textured, item.textured.maps_stamp, item.textured.stamp, u64(item.texture_view)}
	return hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k)), h)
}

// Redraws the whole viewport: the live items over the idle ones, which come from the
// cache when `use_cache` and they, the camera and the size are unchanged.
@(private)
render_full :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, use_cache: bool, stats: ^Viewport_Stats) {
	// Pixels a mesh unit covers one unit in front of the eye (perspective only).
	lod := Lod_View{r.lod_px, proj[1, 1] * f32(vt.height) / 2} if r.lod_px > 0 && proj[3, 3] == 0 else {}
	pipes := mesh_pipelines(r, vt.samples)
	live, see := 0, 0
	for item in items {
		live += int(item.live)
		see += int(blended(pipes, item))
	}
	// With nothing live (or nothing idle) there is nothing to reuse; and see-through items
	// must blend over everything drawn before them, which a cache of the idle ones drawn
	// first would break (while the scene is see-through, the idle ones are all
	// see-through anyway).
	if !use_cache || see > 0 || live == 0 || live == len(items) || !static_cache_ensure(r, vt) {
		vt.cache.key = 0
		prepare_draws(r, cmd, view, proj, items, nil, stats, lod = lod)
		pass := target_pass(r, cmd, vt, load = false)
		draw_background(r, cmd, pass, pipes, vt^, proj)
		draw_scene(r, cmd, pass, pipes, view, proj, items, nil, stats)
		sdl.EndGPURenderPass(pass)
		return
	}
	stats.cache_used = true

	key := static_key(vt^, view, proj, items, r.lod_px, r.background, environment_keyed(r))
	redraw := key != vt.cache.key
	prepare_draws(r, cmd, view, proj, items, nil if redraw else true, stats, lod = lod)
	if redraw {
		pass := begin_mesh_pass(r, cmd, pipes, vt.cache.color, vt.cache.depth, load = false, keep_depth = true, background = r.background.top)
		draw_background(r, cmd, pass, pipes, vt^, proj)
		draw_items(r, cmd, pass, pipes, view, proj, items, false, stats)
		sdl.EndGPURenderPass(pass)
		vt.cache.key = key
		stats.cache_redrawn = true
	}

	copy_pass := sdl.BeginGPUCopyPass(cmd)
	// Multisampled textures copy as they are, sample for sample (Vulkan copies images of
	// equal sample counts).
	for pair in ([2][2]^sdl.GPUTexture{{vt.cache.color, target_color(vt)}, {vt.cache.depth, vt.depth}}) {
		sdl.CopyGPUTextureToTexture(copy_pass, {texture = pair[0]}, {texture = pair[1]}, vt.width, vt.height, 1, cycle = true)
	}
	sdl.EndGPUCopyPass(copy_pass)

	// The grid only here, after the live items, and never into the cache: a live item drawn
	// over the cache's depth, which has no grid, would cover grid in front of it.
	pass := target_pass(r, cmd, vt, load = true)
	draw_scene(r, cmd, pass, pipes, view, proj, items, true, stats)
	sdl.EndGPURenderPass(pass)
}

// How much a full redraw may simplify: Renderer.lod_px, and how many pixels a mesh
// unit covers one unit in front of the eye. All zero for full detail.
@(private)
Lod_View :: struct {
	max_px, px_per_unit: f32,
}

// For every item that will be drawn this frame (those whose `live` matches, all of
// them when `live` is nil) and can be culled, culls its chunks against the camera and
// uploads one indirect draw command per visible run. With `lod`, groups of chunks
// that may be simplified get one command per run of their copies, after the others.
// Must run before the render passes, since uploads need a copy pass.
// `narrow` maps clip space to a smaller frustum to cull against (see render_rect).
@(private)
prepare_draws :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, view, proj: Mat4, items: []Draw_Item, live: Maybe(bool), stats: ^Viewport_Stats, narrow := IDENTITY, lod := Lod_View{}) {
	if !r.cull {
		// Only items with hidden parts need runs of chunks then.
		any_hidden := false
		for item in items do any_hidden ||= item.hidden != nil
		if !any_hidden do return
	}
	t0 := sdl.GetTicksNS()
	defer stats.cull_ms += f64(sdl.GetTicksNS() - t0) / 1e6
	// With parallel projection every chunk is seen from the same direction: an eye far
	// back along it makes the back-facing test agree.
	eye_world := linalg.inverse(view) * [4]f32{0, 0, 1e4 if proj[3, 3] == 1 else 0, 1}
	copy_pass: ^sdl.GPUCopyPass
	for item in items {
		if want, filtered := live.?; filtered && item.live != want do continue
		if !r.cull && item.hidden == nil do continue
		mb := item.mesh
		mb.lod_draw_count = 0
		simplify := r.cull && lod.max_px > 0 && len(item.lod.groups) > 0 && mb.lod_indices != nil
		commands := len(item.chunks) + (len(item.lod.groups) if simplify else 0)
		if len(item.chunks) == 0 || !indirect_ensure(r, mb, u32(commands)) do continue
		eye := linalg.inverse(item.model) * eye_world
		clip := narrow * proj * view * item.model
		clear(&mb.visible)
		clear(&mb.lod_visible)
		switch {
		case !r.cull:
			geom.chunks_shown(item.chunks, item.hidden, &mb.visible)
		case simplify:
			ls := geom.cull_lod(item.chunks, item.lod, clip, eye.xyz, lod.px_per_unit, lod.max_px, &mb.visible, &mb.lod_visible, item.hidden)
			stats.chunks += u64(ls.units)
			stats.culled_view += u64(ls.frustum)
			stats.culled_back += u64(ls.backface)
			stats.simplified += u64(ls.groups)
		case:
			cs: geom.Cull_Stats
			if len(item.chunk_groups) > 0 {
				cs = geom.cull_chunks_grouped(item.chunks, item.chunk_groups, clip, eye.xyz, &mb.visible, item.hidden)
			} else {
				cs = geom.cull_chunks(item.chunks, clip, eye.xyz, &mb.visible, hidden = item.hidden)
			}
			stats.chunks += u64(cs.chunks)
			stats.culled_view += u64(cs.frustum)
			stats.culled_back += u64(cs.backface)
		}
		mb.draw_count = u32(len(mb.visible))
		mb.lod_draw_count = u32(len(mb.lod_visible))
		if mb.draw_count + mb.lod_draw_count == 0 do continue
		dst := cast([^]sdl.GPUIndexedIndirectDrawCommand)sdl.MapGPUTransferBuffer(r.device, mb.indirect_transfer, true)
		for v, i in mb.visible {
			dst[i] = {num_indices = v.index_count, num_instances = 1, first_index = v.first_index}
		}
		for v, i in mb.lod_visible {
			dst[int(mb.draw_count) + i] = {num_indices = v.index_count, num_instances = 1, first_index = v.first_index}
		}
		sdl.UnmapGPUTransferBuffer(r.device, mb.indirect_transfer)
		if copy_pass == nil do copy_pass = sdl.BeginGPUCopyPass(cmd)
		size := (mb.draw_count + mb.lod_draw_count) * size_of(sdl.GPUIndexedIndirectDrawCommand)
		sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = mb.indirect_transfer}, {buffer = mb.indirect, size = size}, true)
	}
	if copy_pass != nil do sdl.EndGPUCopyPass(copy_pass)
}

// Creates the mesh's indirect command buffer for up to `commands` draws. On failure
// the mesh is drawn whole.
@(private)
indirect_ensure :: proc(r: ^Renderer, mb: ^Mesh_Buffers, commands: u32) -> bool {
	if mb.indirect != nil && mb.indirect_capacity >= commands do return true
	if mb.indirect != nil do sdl.ReleaseGPUBuffer(r.device, mb.indirect)
	if mb.indirect_transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.indirect_transfer)
	size := commands * size_of(sdl.GPUIndexedIndirectDrawCommand)
	mb.indirect = sdl.CreateGPUBuffer(r.device, {usage = {.INDIRECT}, size = size})
	mb.indirect_transfer = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = size})
	mb.indirect_capacity = commands
	if mb.indirect == nil || mb.indirect_transfer == nil {
		log.errorf("indirect buffer creation failed: %s", sdl.GetError())
		if mb.indirect != nil do sdl.ReleaseGPUBuffer(r.device, mb.indirect)
		if mb.indirect_transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.indirect_transfer)
		mb.indirect, mb.indirect_transfer, mb.indirect_capacity = nil, nil, 0
		return false
	}
	return true
}

// Identifies the cache contents: the target size, camera, simplification, and every
// idle item's buffers (by identity and version), transform and colour.
@(private)
static_key :: proc(vt: Viewport_Target, view, proj: Mat4, items: []Draw_Item, lod_px: f32, background: Background, environment: Environment_Keyed) -> u64 {
	Keyed :: struct {
		mesh:     ^Mesh_Buffers,
		matcap:   ^sdl.GPUTexture,
		version:  u64,
		model:    Mat4,
		color:    [4]f32,
		material: [4]f32,
		checker:  [4]f32,
		look:     [4]f32,
		lights:   [3][4]f32,
		surface:  [2]f32,
		wire:     b32,
		flat:     b32,
		paint:    b32,
		groups:   b32,
		slotted:  b32, // with Material_Slots, hashed after it
		_:        b32, // no padding: every byte is hashed
	}
	#assert(size_of(Keyed) == 232)
	Header :: struct { // no padding: every byte is hashed
		view, proj:    Mat4,
		width, height: u32,
		lod_px:        f32,
		background:    Background,
		_:             u32,
		environment:   Environment_Keyed,
	}
	#assert(size_of(Header) == 2 * size_of(Mat4) + 16 + size_of(Background) + size_of(Environment_Keyed))
	header := Header{view, proj, vt.width, vt.height, lod_px, background, 0, environment}
	h := hash.fnv64a(slice.bytes_from_ptr(&header, size_of(header)))
	for item in items {
		if item.live do continue
		k := Keyed{item.mesh, item.matcap, item.mesh.version, item.model, item.color, item.material, item.checker, item.look, item.lights, item.surface, b32(item.wireframe), b32(item.flat), b32(item.paint), b32(item.groups), item.slots != nil, false}
		h = hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k)), h)
		if item.slots != nil do h = hash.fnv64a(slice.bytes_from_ptr(item.slots, size_of(Material_Slots)), h)
		h = textured_key(item, h)
	}
	return max(h, 1) // 0 means empty
}

// The colour texture passes draw the viewport into: the multisampled one, or `color`.
@(private)
target_color :: proc(vt: ^Viewport_Target) -> ^sdl.GPUTexture {
	return vt.multi_color if vt.multi_color != nil else vt.color
}

// Opens a pass drawing into the viewport, keeping its depth; with multisampling it keeps
// the samples too, for the next partial redraw to load, and resolves them into `color`.
@(private)
target_pass :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, load: bool) -> ^sdl.GPURenderPass {
	return begin_mesh_pass(r, cmd, mesh_pipelines(r, vt.samples), target_color(vt), vt.depth, load, keep_depth = true, background = r.background.top, resolve = vt.color if vt.multi_color != nil else nil)
}

// Paints Renderer.background over the pass (its scissor, if set) at the far plane, or the
// environment seen through `proj` when the background shows it. A flat one is the colour
// the pass was cleared to, so it is drawn only with `flat_too`, where part of an earlier
// frame is being cleared.
@(private)
draw_background :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, pipes: ^Mesh_Pipelines, vt: Viewport_Target, proj: Mat4, flat_too := false) {
	b := r.background
	shown := environment_background(r)
	if b.top == b.bottom && !flat_too && !shown do return
	uniforms := Clear_Uniforms{background = b, extent = {f32(vt.height), f32(vt.width), 0, 0}}
	if shown {
		look := r.environment_look
		// The panorama's axes are the columns of its turn into view space, so its
		// transpose turns view space into the panorama's.
		to_env := IDENTITY
		for c in 0 ..< 3 do for k in 0 ..< 3 do to_env[c, k] = look.rotation[c][k]
		uniforms.env = {1, look.strength, look.blur * f32(r.environment.levels - 1), look.exposure}
		uniforms.clip_to_env = to_env * linalg.inverse(proj)
	}
	sdl.BindGPUGraphicsPipeline(pass, pipes.clear)
	binding := environment_binding(r)
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	sdl.PushGPUFragmentUniformData(cmd, 0, &uniforms, size_of(uniforms))
	sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
}

// Opens a pass into `color_tex` and `depth_tex`, cleared to `background` or loaded, with
// `pipes.mesh` bound. With `resolve`, `color_tex` is multisampled and the pass ends by
// resolving it into `resolve`, keeping its samples.
@(private)
begin_mesh_pass :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pipes: ^Mesh_Pipelines, color_tex, depth_tex: ^sdl.GPUTexture, load, keep_depth: bool, background := BACKGROUND, resolve: ^sdl.GPUTexture = nil) -> ^sdl.GPURenderPass {
	color := sdl.GPUColorTargetInfo {
		texture     = color_tex,
		clear_color = sdl.FColor(background),
		load_op     = .LOAD if load else .CLEAR,
		store_op    = .RESOLVE_AND_STORE if resolve != nil else .STORE,
		cycle       = !load,
		// The resolve writes all of it, so a frame still showing the last one need not wait.
		resolve_texture = resolve,
		cycle_resolve_texture = resolve != nil,
	}
	depth := sdl.GPUDepthStencilTargetInfo {
		texture          = depth_tex,
		clear_depth      = 1,
		load_op          = .LOAD if load else .CLEAR,
		store_op         = .STORE if keep_depth else .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
		cycle            = !load,
	}
	pass := sdl.BeginGPURenderPass(cmd, &color, 1, &depth)
	sdl.BindGPUGraphicsPipeline(pass, pipes.mesh)
	return pass
}

// Draws the items whose `live` flag matches (all of them when `live` is nil) with the
// clay material: the visible runs prepare_draws found, or the whole mesh.
@(private)
draw_items :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, pipes: ^Mesh_Pipelines, view, proj: Mat4, items: []Draw_Item, live: Maybe(bool), stats: ^Viewport_Stats, see := false) {
	bound: ^sdl.GPUGraphicsPipeline
	for item in items {
		if want, filtered := live.?; filtered && item.live != want do continue
		if blended(pipes, item) != see do continue
		textured := draws_textured(pipes, item)
		main := pipes.see if see else pipes.mesh
		if textured do main = pipes.textured_see if see else pipes.textured
		if main != bound {
			sdl.BindGPUGraphicsPipeline(pass, main)
			bound = main
		}
		mb := item.mesh
		show_paint, show_groups := item.paint && mb.paint != nil, item.groups && mb.paint != nil
		slotted := item.slots != nil && mb.paint != nil && !textured
		frame := Frame_Uniforms{view_proj = proj * view, view = view, model = item.model, options = {f32(int(show_paint)), f32(int(show_groups)), f32(int(slotted)), 0}}
		frame.slot_group = SLOT_NONE
		if slotted {
			frame.slot_group = item.slots.groups
			sdl.PushGPUFragmentUniformData(cmd, 1, &item.slots.uniforms, size_of(Slot_Uniforms))
		}
		params := item.material if item.material != {} else DEFAULT_MATERIAL
		surface := [4]f32{item.surface.x, item.surface.y, 1 if item.flat else 0, 1 if item.matcap != nil else 0}
		lights := item.lights if item.lights != {} else DEFAULT_LIGHTS
		material := Material_Uniforms{base_color = item.color, params = params, surface = surface, checker = item.checker, look = item.look, lights = lights}
		material_environment(r, &material)
		// Drawn solid after all where the blended pipeline is missing, and opaque then.
		if !see do material.look.w = 0
		if textured {
			frame.options = {}
			draw_textured_item(r, cmd, pass, item, &frame, &material, stats)
			if item.wireframe && pipes.wire != nil {
				// The wire pass draws the sculpt buffers, which hold the same surface.
				sdl.PushGPUVertexUniformData(cmd, 0, &frame, size_of(frame))
				paint := [1]^sdl.GPUBuffer{r.no_paint}
				sdl.BindGPUVertexStorageBuffers(pass, 0, &paint[0], 1)
				samplers := [2]sdl.GPUTextureSamplerBinding{{texture = r.no_matcap, sampler = r.matcap_sampler}, environment_binding(r)}
				sdl.BindGPUFragmentSamplers(pass, 0, &samplers[0], len(samplers))
				vbufs := [2]sdl.GPUBufferBinding{{buffer = mb.positions}, {buffer = mb.normals}}
				sdl.BindGPUVertexBuffers(pass, 0, &vbufs[0], len(vbufs))
				wire_pass(r, cmd, pass, pipes, item)
				bound = pipes.wire
			}
			continue
		}
		sdl.PushGPUVertexUniformData(cmd, 0, &frame, size_of(frame))
		sdl.PushGPUFragmentUniformData(cmd, 0, &material, size_of(material))
		paint := [1]^sdl.GPUBuffer{mb.paint if mb.paint != nil else r.no_paint}
		sdl.BindGPUVertexStorageBuffers(pass, 0, &paint[0], 1)
		samplers := [2]sdl.GPUTextureSamplerBinding{{texture = item.matcap if item.matcap != nil else r.no_matcap, sampler = r.matcap_sampler}, environment_binding(r)}
		sdl.BindGPUFragmentSamplers(pass, 0, &samplers[0], len(samplers))
		vbufs := [2]sdl.GPUBufferBinding{{buffer = mb.positions}, {buffer = mb.normals}}
		sdl.BindGPUVertexBuffers(pass, 0, &vbufs[0], len(vbufs))
		draw_item_triangles(r, pass, item, stats)
		if item.wireframe && pipes.wire != nil {
			wire_pass(r, cmd, pass, pipes, item)
			bound = pipes.wire
		}
	}
}

// The item's triangles again as lines in one flat colour (a negative specular strength
// tells the shader so), with the sculpt buffers bound by the caller.
@(private)
wire_pass :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, pipes: ^Mesh_Pipelines, item: Draw_Item) {
	wire := Material_Uniforms{base_color = WIRE_COLOR, params = {0, -1, 0, 0}}
	sdl.PushGPUFragmentUniformData(cmd, 0, &wire, size_of(wire))
	sdl.BindGPUGraphicsPipeline(pass, pipes.wire)
	draw_item_triangles(r, pass, item, nil)
}

// Whether `item` is drawn see-through, blended over what is behind it: it asks to be
// (Draw_Item.look.w) and the device made the blended pipeline.
@(private)
blended :: proc(pipes: ^Mesh_Pipelines, item: Draw_Item) -> bool {
	if draws_textured(pipes, item) do return item.look.w > 0 && pipes.textured_see != nil
	return item.look.w > 0 && pipes.see != nil
}

// Draws the viewport's items whose `live` matches in the order blending needs: the opaque
// ones, then the floor grid, then the see-through ones over both. In render_rect the opaque
// ones are drawn a pixel past the rectangle (see there); everything blended stays inside
// `inside`, as drawing it twice at the edge would blend it twice.
@(private)
draw_scene :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, pipes: ^Mesh_Pipelines, view, proj: Mat4, items: []Draw_Item, live: Maybe(bool), stats: ^Viewport_Stats, inside: Maybe(Rect) = nil) {
	draw_items(r, cmd, pass, pipes, view, proj, items, live, stats)
	if rect, ok := inside.?; ok do sdl.SetGPUScissor(pass, {rect.x, rect.y, rect.w, rect.h})
	draw_floor(r, cmd, pass, pipes, view, proj)
	if pipes.see == nil && pipes.textured_see == nil do return
	for item in items do if blended(pipes, item) {
		draw_items(r, cmd, pass, pipes, view, proj, items, live, stats, see = true)
		break
	}
}

// Draws Renderer.floor's planes, each as a full-screen triangle whose pixels find where
// their ray meets the plane (floor.frag).
@(private)
draw_floor :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, pipes: ^Mesh_Pipelines, view, proj: Mat4) {
	f := r.floor
	if pipes.floor == nil || f.shown == {} || f.cell <= 0 do return
	view_proj := proj * view
	u := Floor_Uniforms {
		inv_view_proj = linalg.inverse(view_proj),
		view_proj     = view_proj,
		grid          = {f.cell, f.radius, f32(int(f.axes)), 0},
		center        = {f.center.x, f.center.y, f.center.z, 0},
	}
	sdl.BindGPUGraphicsPipeline(pass, pipes.floor)
	for axis in 0 ..< 3 {
		if !f.shown[axis] do continue
		u.plane = {f32(axis), f.at[axis], 0, 0}
		sdl.PushGPUFragmentUniformData(cmd, 0, &u, size_of(u))
		sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
	}
}

DEFAULT_MATERIAL :: [4]f32{0.08, 0.2, 40, 0}
// The light rig unturned, at full strength: the lights fixed to the camera.
DEFAULT_LIGHTS :: [3][4]f32{{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 0}}

// Where the rig `lights` (Draw_Item.lights) puts the view-space direction `dir` given in
// the rig's own space.
lights_turn :: proc(lights: [3][4]f32, dir: [3]f32) -> [3]f32 {
	l := lights if lights != {} else DEFAULT_LIGHTS
	return l[0].xyz * dir.x + l[1].xyz * dir.y + l[2].xyz * dir.z
}
WIRE_COLOR :: [4]f32{0.05, 0.05, 0.06, 1}

// The item's triangles: the visible runs prepare_draws found, or the whole mesh. Counts
// them in `stats` when given.
@(private)
draw_item_triangles :: proc(r: ^Renderer, pass: ^sdl.GPURenderPass, item: Draw_Item, stats: ^Viewport_Stats) {
	mb := item.mesh
	sdl.BindGPUIndexBuffer(pass, {buffer = mb.indices}, ._32BIT)
	if (r.cull || item.hidden != nil) && len(item.chunks) > 0 && mb.indirect != nil {
		if mb.draw_count > 0 do sdl.DrawGPUIndexedPrimitivesIndirect(pass, mb.indirect, 0, mb.draw_count)
		if mb.lod_draw_count > 0 {
			sdl.BindGPUIndexBuffer(pass, {buffer = mb.lod_indices}, ._32BIT)
			sdl.DrawGPUIndexedPrimitivesIndirect(pass, mb.indirect, mb.draw_count * size_of(sdl.GPUIndexedIndirectDrawCommand), mb.lod_draw_count)
		}
		if stats == nil do return
		for v in mb.visible do stats.triangles += u64(v.index_count / 3)
		for v in mb.lod_visible do stats.triangles += u64(v.index_count / 3)
		stats.draws += u64(mb.draw_count + mb.lod_draw_count)
	} else {
		sdl.DrawGPUIndexedPrimitives(pass, mb.index_count, 1, 0, 0, 0)
		if stats == nil do return
		stats.triangles += u64(mb.index_count / 3)
		stats.draws += 1
	}
}

// Reads the viewport colour back to the CPU (RGBA8, rows top to bottom), waiting for
// the GPU: `texture` (a viewport-sized RGBA8 one, such as the studio render's) or the
// target's own. For tests and debugging, not per frame. Returns nil on failure.
viewport_download :: proc(r: ^Renderer, vt: ^Viewport_Target, allocator := context.allocator, texture: ^sdl.GPUTexture = nil) -> []u8 {
	return texture_download(r, texture if texture != nil else vt.color, vt.width, vt.height, allocator)
}

// Reads a `width` by `height` RGBA8 texture back as rows top to bottom, after waiting
// for the GPU; nil on failure.
texture_download :: proc(r: ^Renderer, texture: ^sdl.GPUTexture, width, height: u32, allocator := context.allocator) -> []u8 {
	size := width * height * 4
	transfer := sdl.CreateGPUTransferBuffer(r.device, {usage = .DOWNLOAD, size = size})
	if transfer == nil do return nil
	defer sdl.ReleaseGPUTransferBuffer(r.device, transfer)
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil do return nil
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(pass, {texture = texture, w = width, h = height, d = 1}, {transfer_buffer = transfer})
	sdl.EndGPUCopyPass(pass)
	if !sdl.SubmitGPUCommandBuffer(cmd) || !sdl.WaitForGPUIdle(r.device) do return nil
	src := sdl.MapGPUTransferBuffer(r.device, transfer, false)
	if src == nil do return nil
	pixels := make([]u8, size, allocator)
	copy(pixels, ([^]u8)(src)[:size])
	sdl.UnmapGPUTransferBuffer(r.device, transfer)
	return pixels
}
