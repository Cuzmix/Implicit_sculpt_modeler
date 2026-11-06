// Package render owns every GPU object the app creates. It draws the sculpt viewport into
// an offscreen texture that the interface then shows (ui_pass.odin); it never reads or
// writes interface state.
package render

import "../gpu"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import sdl "vendor:sdl3"

import "../geom"
import "../jobs"

Mat4 :: matrix[4, 4]f32
IDENTITY :: Mat4(1)

VIEWPORT_COLOR_FORMAT :: gpu.Format.RGBA8_Unorm

// A tablet build, Android's or the iPad's: less memory and a slower GPU, so the render
// mode's budgets are smaller there. What only Android's Vulkan needs tests `.Android`.
@(private)
MOBILE :: ODIN_PLATFORM_SUBTARGET != .Default

Renderer :: struct {
	has_device:    bool, // the GPU device is made; gpu holds it (gpu.create_device)
	caps:          Gpu_Caps, // what the device and backend can do (caps.odin)
	// The ray query check's outcome (ray_query.odin), run under --gpu-debug only.
	ray_query_check: Ray_Query_Check,
	window:        ^sdl.Window,
	depth_format:  gpu.Format,
	depth_sampled: bool, // shaders can read depth_format textures (the studio render needs to)
	// The mesh pipelines at one sample, for thumbnails, the navigation head and a
	// viewport without anti-aliasing, and at `samples` for an anti-aliased viewport
	// (empty while samples is 1). A pipeline draws only into targets of its count.
	single:         Mesh_Pipelines,
	multi:          Mesh_Pipelines,
	samples:        gpu.Sample_Count, // the viewport's multisampling; see renderer_set_msaa
	// Bound in place of a mesh's paint buffer when it has none: the mesh shader reads
	// the binding only for items that show paint or groups, but it must be bound.
	no_paint:       gpu.Buffer,
	// Bound in place of a matcap for items that have none, as no_paint is; and the
	// filtering, mipmapped sampler every matcap is read through.
	no_matcap:      gpu.Texture,
	matcap_sampler: gpu.Sampler,
	// Bound in place of a textured mesh's normal map when it has none (a flat normal);
	// its base colour and ORM stand-in is no_matcap, white. The textured maps' sampler:
	// filtering, mipmapped, repeating, and anisotropic where the device allows it.
	no_normal_map:   gpu.Texture,
	texture_sampler: gpu.Sampler,
	anisotropy:      bool, // the device was made with anisotropic filtering
	last_version:   u64,  // source of Mesh_Buffers.version
	cull:           bool, // skip off-screen and back-facing chunks of items that have them
	// ...on the GPU where Gpu_Caps.gpu_cull (gpu_cull.odin): Stats > Drawing's Cull on the
	// GPU, --cpu-cull off.
	gpu_cull:       bool,
	gpu_culling:    Gpu_Cull,
	// Sculpting on the GPU (sculpt_gpu.odin): the normals kernel, the readback ring and
	// the run's counts. The app's switch is its own (App.gpu_sculpt).
	sculpt_gpu:     Sculpt_Gpu,
	// Makes a multisampled viewport keep its samples in tile memory (Viewport_Target.tile)
	// on a GPU without transient targets too (--tile-msaa), so a desktop can test that mode.
	tile_msaa:      bool,
	// The app's worker pool, which culling by groups spreads a big mesh's chunks over; nil
	// culls on the calling thread. Only the frame thread draws, so it is never busy here.
	pool:           ^jobs.Pool,
	partial:        bool, // while the camera and objects stay put, redraw only what changed
	trace:          bool, // the studio render casts rays at the triangles where it can (trace.odin)
	// Those rays use ray queries against the driver's acceleration structures where
	// Gpu_Caps.ray_query is true (Settings > System > Graphics: Ray tracing hardware).
	ray_query:      bool,
	// Render mode builds kernels specialised to each scene's features off the frame and
	// switches to them between samples (path.odin, Render_Features); off, it keeps the
	// general kernel (--no-render-variants, for comparison). With kernel_builds_wait, as
	// scripted runs set it, a build is waited for, so a run's images never depend on how
	// long a compile took.
	render_variants: bool,
	kernel_builds_wait: bool,
	present_mode:   gpu.Present_Mode, // how frames reach the screen; see renderer_set_vsync
	// How far, in pixels, a full redraw may draw a group of chunks from its simplified
	// copy instead (see Draw_Item.lod); 0 draws everything at full detail. The app
	// sets it while the view moves.
	lod_px:         f32,
	// The floor grid the viewport draws behind and among its items; set by the app each
	// frame, as lod_px is.
	floor:          Floor_Grid,
	// What the viewport shows behind everything; set by the app each frame, as floor is.
	background:     Background,
	// The reference pictures on planes in the scene (ref_planes.odin); set by the app each
	// frame, as floor is, from memory that lasts the frame.
	ref_planes:     []Ref_Plane,
	// The wireframe's colour, linear; zero for WIRE_COLOR. Set by the app each frame from
	// the theme, and folded into the redraw keys only when set, so their values stay.
	wire_color:     [4]f32,
	// Draw the wireframe as the triangles again in lines even where the device could draw
	// it in the shading pass (Gpu_Caps.barycentric): --gpubench's comparison of the two.
	// Whoever changes it calls viewport_invalidate.
	wire_as_lines:  bool,
	// The image environment the physically based materials light with (environment.odin),
	// nil for the built-in studio, and how it shows; set by the app each frame. The app
	// owns the environment. Bound in its place while there is none: a black texture; and
	// the sampler both are read through: filtering, mipmapped, repeating round the
	// panorama and clamped at its poles.
	environment:      ^Environment,
	environment_look: Environment_Look,
	no_environment:   gpu.Texture,
	env_sampler:      gpu.Sampler,
}

// The viewport's background in display values, written as-is: `top` along the top edge
// shading to `bottom` along the bottom one, and one flat colour when the two are equal.
Background :: struct {
	top, bottom: [4]f32,
}

// Matches Clear_Uniforms in clear.frag.slang.
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

// Matches Floor_Uniforms in floor.frag.slang.
Floor_Uniforms :: struct {
	inv_view_proj: Mat4,
	view_proj:     Mat4,
	plane:         [4]f32, // x: the axis across the plane, y: where along it the plane sits
	grid:          [4]f32, // x: a cell's side, y: the fade radius, z: 1 to draw the axes
	center:        [4]f32,
}

// The mesh shaders bind as one family: the drawing loop binds mesh.vert's and mesh.frag's
// slots whichever of these pipelines is bound, so each shader's matching slots sit where theirs do.
#assert(int(Mesh_Wire_Vert_Buffers.paint) == int(Mesh_Vert_Buffers.paint) && int(Skin_Vert_Buffers.paint) == int(Mesh_Vert_Buffers.paint))
#assert(int(Mesh_Wire_Vert_Buffers.paint_material_words) == int(Mesh_Vert_Buffers.paint_material_words))
#assert(int(Mesh_Wire_Vert_Uniforms.Frame_Uniforms) == int(Mesh_Vert_Uniforms.Frame_Uniforms) && int(Skin_Vert_Uniforms.Frame_Uniforms) == int(Mesh_Vert_Uniforms.Frame_Uniforms))
#assert(int(Skin_Tess_Vert_Uniforms.Frame_Uniforms) == int(Mesh_Vert_Uniforms.Frame_Uniforms) && int(Textured_Vert_Uniforms.Frame_Uniforms) == int(Mesh_Vert_Uniforms.Frame_Uniforms))
#assert(len(Mesh_Area_Frag_Samplers) == len(Mesh_Frag_Samplers) && len(Mesh_Wire_Frag_Samplers) == len(Mesh_Frag_Samplers) && len(Skin_Frag_Samplers) == len(Mesh_Frag_Samplers))
#assert(int(Mesh_Area_Frag_Samplers.environment_map) == int(Mesh_Frag_Samplers.environment_map) && int(Mesh_Wire_Frag_Samplers.environment_map) == int(Mesh_Frag_Samplers.environment_map) && int(Skin_Frag_Samplers.environment_map) == int(Mesh_Frag_Samplers.environment_map))
#assert(int(Mesh_Area_Frag_Uniforms.Slot_Uniforms) == int(Mesh_Frag_Uniforms.Slot_Uniforms) && int(Mesh_Wire_Frag_Uniforms.Slot_Uniforms) == int(Mesh_Frag_Uniforms.Slot_Uniforms) && int(Skin_Frag_Uniforms.Slot_Uniforms) == int(Mesh_Frag_Uniforms.Slot_Uniforms))
#assert(int(Textured_Frag_Uniforms.Material_Uniforms) == int(Mesh_Frag_Uniforms.Material_Uniforms))

// The pipelines that draw meshes into targets of one sample count.
Mesh_Pipelines :: struct {
	mesh:  gpu.Graphics_Pipeline,
	// The same shaders drawing triangle edges as lines, pulled toward the eye so they
	// show over the surface they outline; nil where the device cannot draw lines.
	wire:  gpu.Graphics_Pipeline,
	// The same shaders drawing a line list (Mesh_Buffers.edges): a Model mode cage's
	// edges, which every device can draw, unlike the wireframe's line fill.
	lines: gpu.Graphics_Pipeline,
	// Fills the target, or a scissored rectangle of it, with the background at the far plane.
	clear: gpu.Graphics_Pipeline,
	// The mesh shaders blending over what is behind and leaving the depth be, for items
	// drawn see-through (Draw_Item.look.w); nil where the device refused it, and those items
	// are then drawn solid.
	see:   gpu.Graphics_Pipeline,
	// The floor grid (Floor_Grid), one full-screen triangle a plane; nil where the device
	// refused it, and the grid is then not drawn.
	floor: gpu.Graphics_Pipeline,
	// Textured meshes (textured.odin), opaque and see-through; nil where the device refused
	// them, and those items then draw through their sculpt buffers as clay.
	textured:     gpu.Graphics_Pipeline,
	textured_see: gpu.Graphics_Pipeline,
	// Meshes with a detail skin (skin.odin), opaque; nil where the device refused it, and
	// those items then draw with the mesh's own normals.
	skinned:      gpu.Graphics_Pipeline,
	// The triangles of a skinned mesh near the camera, drawn as the skin's grid of small
	// ones at its points (skin_tess.vert, skin.odin); nil where the device refused it, and
	// they then draw as the far ones do.
	skin_tess:    gpu.Graphics_Pipeline,
	// mesh, see, textured and textured_see with the area lights' code (mesh_area and
	// textured_area.frag), drawn for an item lit by an area light so the others carry
	// none of it; made the first time one is drawn (area_pipelines), each nil until then
	// or where the device refused it, when the plain one draws and leaves the area light
	// out.
	area:         [Area_Pipeline]gpu.Graphics_Pipeline,
	area_made:    bool,
	// mesh with the wireframe drawn over the triangles' edges in the same pass
	// (mesh_wire.frag.slang), made the first time a wireframe is drawn where the device
	// offers barycentrics (wire_pipeline); nil until then, elsewhere, or where the device
	// refused it, when the wireframe is drawn as lines through `wire`.
	mesh_wire:      gpu.Graphics_Pipeline,
	mesh_wire_made: bool,
	// The reference planes' pipelines, behind the model and through it (ref_planes.odin),
	// made the first time a plane is drawn; each nil until then or where the device
	// refused it, when those planes are not drawn.
	ref_behind:  gpu.Graphics_Pipeline,
	ref_through: gpu.Graphics_Pipeline,
	ref_made:    bool,
	// The plain, see-through, textured and skinned pipelines clipped at Draw_Item.clip
	// (*_clip.frag.slang), made the first time a clipped item is drawn (clip_pipelines),
	// each nil until then or where the device refused it, when the item draws whole. A
	// clipped item leaves out area lights and the wireframe drawn in its shading, which
	// it draws as lines instead.
	clip:           [Clip_Pipeline]gpu.Graphics_Pipeline,
	clip_made:      bool,
	samples:      gpu.Sample_Count, // the targets' sample count they were made for
}

// Which of the area lights' pipelines (Mesh_Pipelines.area).
@(private)
Area_Pipeline :: enum u8 {
	Mesh,
	See,
	Textured,
	Textured_See,
}

// How a mesh pipeline draws its triangles: filled and opaque, as lines, or filled and
// blended (see-through); or, for Lines, a list of line segments (Mesh_Buffers.edges).
@(private)
Mesh_Mode :: enum u8 {
	Solid,
	Wire,
	See_Through,
	Lines,
}

// The flat grey the viewport shows until the app sets Renderer.background, in display
// values written as-is (like the mesh shader's output).
BACKGROUND :: [4]f32{0.17, 0.17, 0.17, 1}

// A partial redraw is skipped in favour of a full one when the changed rectangle
// covers more than this share of the viewport.
PARTIAL_MAX_AREA :: 0.6

// Offscreen colour + depth pair the 3D viewport renders into. Recreated on resize.
Viewport_Target :: struct {
	color:  gpu.Texture, // one sample, sampled: what the interface shows and screenshots read
	depth:  gpu.Texture, // at `samples`; shaders can read it only at one sample
	// With multisampling, what passes draw into, kept between frames so a partial redraw
	// can load it, and resolved into `color` at the end of every pass; nil at one sample.
	multi_color: gpu.Texture,
	samples: gpu.Sample_Count,
	width:  u32,
	height: u32,
	// `depth` lives only inside the one pass that clears it (gpu.create_texture_transient),
	// for targets whose depth nothing reads after their pass.
	transient_depth: bool,
	// With multisampling where Gpu_Caps.transient_targets and partial redraw is off: the
	// samples and their depth live only inside the pass that draws them (in tile memory on
	// a tile GPU, which then never gives them memory) and only the resolved `color` is
	// stored. Every frame then draws everything in one pass: no partial redraw loads the
	// samples back, and no idle cache is copied into them.
	tile: bool,
	cache:  Static_Cache, // at `samples`
	// Identifies what color and depth hold: camera, size, and every item's identity,
	// transform and colour (not its contents, which Draw_Item.damage accounts for).
	// 0 when they hold nothing reusable.
	frame_key: u64,
	// Counts viewport_invalidate's calls: whatever made the picture start over also starts
	// over what was built from it across frames (the studio render's carried samples).
	epoch: u64,
}

// Colour and depth of everything that is not `live`, as last drawn. While the camera
// and those objects stay put (all through a brush stroke), each frame copies this in
// and draws only the live objects on top, so idle meshes cost a screen-sized copy
// instead of all their triangles.
Static_Cache :: struct {
	color: gpu.Texture,
	depth: gpu.Texture,
	key:   u64, // hash of what the textures hold; 0 when they hold nothing
}

// GPU copy of a geom.Mesh. Positions (3 floats) and normals (octahedral, 2 snorm16)
// live in separate vertex buffers: 16 bytes a vertex. The transfer buffer is sized for
// typical per-frame sculpt updates, not the whole mesh; bigger uploads go through it
// in chunks.
Mesh_Buffers :: struct {
	positions:       gpu.Buffer,
	normals:         gpu.Buffer,
	indices:         gpu.Buffer,
	vertex_capacity: u32,
	index_count:     u32,
	version:         u64, // changes whenever the buffers' contents do
	drawn_version:   u64, // version when last drawn into the viewport
	// The caller's stamp for index data that is not the mesh's own (the sculptor's
	// hidden triangles, mesh_buffers_upload_packed_indices); 0 for the mesh's own.
	hidden_stamp:    u32,
	// Positions and indices can be read by compute shaders too (the traced studio
	// render's rays, trace.odin); false where the device refused that, and the mesh is
	// only drawn.
	storage:         bool,
	// The version as of the last upload of the mesh's own indices (creation,
	// mesh_buffers_upload_indices): what the traced studio's trees were built from.
	// Uploads of hidden triangles leave it, since the trees skip degenerate triangles.
	index_version:   u64,
	// The traced studio render's trees over the triangles; nil until it first runs.
	trace:           ^Trace_Mesh,
	// Pairs of vertices drawn as lines over the surface (Draw_Item.cage_lines): a Model
	// mode cage's edges, or the polygon edges a wireframe shows; nil for none
	// (mesh_buffers_set_edges).
	edges:           gpu.Buffer,
	edge_indices:    u32,
	// The polygon edges again per triangle, for the wireframe drawn in the shading pass
	// (mesh_wire.frag.slang): four bits a triangle, eight a word, bit k set where the edge
	// across from corner k is a polygon's and clear where it only cuts a polygon into
	// triangles; nil for none (mesh_buffers_set_edges).
	tri_edges:       gpu.Buffer,

	// Culled drawing: one indirect draw command per visible run of chunks, rebuilt
	// each frame the mesh is drawn. Created on first use, sized for every chunk.
	indirect:          gpu.Buffer,
	indirect_capacity: u32, // commands
	draw_count:        u32, // commands recorded this frame (with cull.culled, the most the kernels may write)
	visible:           [dynamic]geom.Index_Range, // scratch
	cull:              Mesh_Cull, // GPU culling's copy of the chunks (gpu_cull.odin)

	// Per vertex, a Paint_Packed: its polypaint and the polygroup it carries, read by the
	// mesh shader as a storage buffer (8 bytes a vertex). Nil until a mesh has paint or
	// groups (mesh_buffers_upload_paint).
	paint:       gpu.Buffer,
	// Per vertex, its painted roughness and metal (sculpt.Material_Paint: roughness, its
	// coverage, metal, its coverage, a byte each), read by the mesh shaders beside `paint`.
	// Nil until a paint layer holds either (mesh_buffers_upload_paint's `materials`), so
	// paint of colour alone and groups pay nothing for it.
	paint_material: gpu.Buffer,
	// The caller's stamp for what `paint` holds (the sculptor's paint stamp); 0 when it
	// holds nothing.
	paint_stamp: u32,

	// Simplified copies of groups of chunks (see Draw_Item.lod), drawn with indirect
	// commands that follow the draw_count full-detail ones. Created on first upload.
	lod_indices:    gpu.Buffer,
	lod_capacity:   u32, // indices
	lod_draw_count: u32, // commands recorded this frame
	lod_visible:    [dynamic]geom.Index_Range, // scratch

	// The detail skin over the mesh (skin.odin): each sample's normal, packed as the mesh's
	// are, and per triangle its edges and lead corner; nil without one.
	skin_normals: gpu.Buffer,
	skin_tris:    gpu.Buffer,
	// Each sample's height, two halves a word, for the triangles drawn as the grid.
	skin_heights: gpu.Buffer,
	skin_meta:    [3]u32, // segments, vertex count, edge count (Frame_Uniforms.skin)
	skin_samples: u32,
	// How far the skin strays from its base at most (sculpt.Skin.height_max), in the
	// mesh's units: what decides which chunks are near enough to draw as the grid.
	skin_reach:   f32,
	// The commands, after the draw_count flat ones, that draw chunks as the skin's grid
	// this frame (skin_tess_split).
	tess_draw_count: u32,
	tess_visible:    [dynamic]geom.Index_Range, // scratch
	// The caller's stamp for the lead corners `skin_tris` holds (the sculptor's paint
	// stamp, which moves with the polygroups); 0 for none.
	skin_lead_stamp: u32,
	// The caller's stamp for which skin the buffers hold (the sculptor's skin stamp).
	skin_stamp:      u32,

	// Sculpting on the GPU (sculpt_gpu.odin): the mesh's vertex -> triangle lookup and the
	// frame's queued normals.
	sculpt: Mesh_Sculpt,

	// The culled commands of the items drawing this mesh as a copy (Draw_Item.copy): copy k's
	// at k - 1, grown as copies are first drawn and released with the buffers.
	copy_draws: [dynamic]Copy_Draws,
}

// What one copy of a mesh (Draw_Item.copy) draws this frame, culled under its own model:
// the commands of its visible chunks, then of its groups' simplified copies.
Copy_Draws :: struct {
	indirect:       gpu.Buffer,
	capacity:       u32, // commands
	draw_count:     u32,
	lod_draw_count: u32,
	visible:        [dynamic]geom.Index_Range, // scratch
	lod_visible:    [dynamic]geom.Index_Range, // scratch
}

Normal_Packed :: [2]i16
// Matches `paint` in mesh.vert.slang: the colour's bytes red first, then the group.
Paint_Packed :: [2]u32
VERTEX_BYTES :: size_of(geom.Vec3) + size_of(Normal_Packed)

// Normals go up with the vertex's mask folded in: see geom.oct_encode_masked.
pack_normal :: geom.oct_encode_masked

// Matches Frame_Uniforms in mesh_io.slang (std140: column-major mat4s). Pushed per draw.
Frame_Uniforms :: struct {
	view_proj: Mat4,
	view:      Mat4,
	model:     Mat4,
	options:   [4]f32, // x: show the paint, y: show the polygroups, z: look up material slots
	slot_group: [GROUP_SLOTS]u32, // Material_Slots.groups, as mesh_io.slang's uint4 slot_group[4]
	skin:       [4]u32, // the detail skin's segments, vertex and edge counts (Mesh_Buffers.skin_meta)
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

// Matches Slot_Uniforms in mesh.frag.slang (std140: arrays of vec4).
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
	cage_lines: bool, // draw Mesh_Buffers.edges over it as lines (a cage's edges, or a wireframe's polygon edges)
	paint:     bool, // draw its polypaint over the clay (needs Mesh_Buffers.paint)
	groups:    bool, // draw each triangle in its polygroup's colour instead (likewise)
	// The density preview's checker: xyz the first lattice point in mesh space, w the
	// cell size; zero for none.
	checker:   [4]f32,
	// How the shading is shown: x the exposure in stops, y how much creases darken
	// (cavity) and z how much crests lighten (ridge), 0 to 1; zero shows it plainly.
	look:      [4]f32,
	// The shading's style, for the classic and physically based materials: x how bright
	// the rim at the silhouette is, y how much of the ambient light reaches a surface
	// facing straight down (1 as much as one facing up), w 1 to use them. Zero keeps the
	// classic rim and an even ambient light, as thumbnails and the navigation head draw.
	// z 1 draws masked parts as the rest, whatever w is (the view's Show the mask off).
	style:     [4]f32,
	// The pass the viewport shows it in (View_Pass): x the pass, y and z where Depth
	// starts and ends, in view-space distance from the eye, w a wipe compare (0 for none,
	// else 1 + the pass right of its line + 16 x the line's pixel column; app/passes.odin's
	// pass_items). Zero shades it as usual.
	pass:      [4]f32,
	// How far the view takes the colours toward clay, so the form reads under the paint:
	// rgb the clay, a how far (0 to 1). Zero shows the colours whole.
	fade:      [4]f32,
	// A matcap (matcap_create) that shades the item instead of the lights, tinted by
	// `color`; nil for none.
	matcap:    gpu.Texture,
	// The lights and the turn of the studio the physically based materials reflect, in
	// view space; zero for lights_default(), the lights fixed to the camera.
	lights:    Lights,
	// Polygroups with materials of their own; nil for none. Read during the frame only.
	slots:     ^Material_Slots,
	// A textured mesh drawn in place of `mesh`'s triangles while `texture_view` is not
	// .Off (textured.odin); `mesh` still draws the wireframe and stands for the item in
	// the frame keys and damage boxes. Nil for none.
	textured:     ^Textured_Mesh,
	texture_view: Texture_View,
	live:   bool,
	// The mesh `mesh` was made from, on the CPU and as uploaded (its own indices, not the
	// hidden ones' stand-ins): the traced studio render builds its trees from it. Nil
	// where there is none, which keeps the studio render on shadow maps.
	source: ^geom.Mesh,
	chunks: []geom.Chunk,
	chunk_groups: []geom.Chunk, // geom.chunk_group of each geom.CHUNK_GROUP chunks, to cull a group at a time; nil to test every chunk
	// When each group was last made and the chunks' layout (sculpt.sculptor_chunk_stamps),
	// for GPU culling's copy of them; nil and 0 to cull on the CPU.
	group_stamps: []u64,
	chunk_layout: u64,
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
	// Runs of the index buffer drawn one direct draw each instead of the whole mesh, when
	// not nil: a picture that culled `chunks` for its own narrower view (thumbnail_view_draw
	// with cull), which must not touch the indirect commands the viewport drew from.
	ranges: []geom.Index_Range,
	// A copy of an item drawing the same `mesh` under another `model` (the app's live stack:
	// a mirror image, an array's or a radial copy), numbered from 1; 0 for the item itself.
	// A copy culls its chunks on the CPU under its own model into Mesh_Buffers.copy_draws,
	// never on the GPU, and draws the mesh's triangles: no skin grid or skin lighting, and
	// untextured when reflected (a normal map's tangent frame would turn over). The path
	// render leaves copies out. `model` may be reflected (a negative determinant): the
	// front face then turns over (gpu.set_front_face).
	copy: u32,
	// Planes through the mesh's origin that clip what is drawn, in the mesh's own space: a
	// point is kept where clip[a] * p[a] >= 0 for each axis a, so +1 keeps the positive
	// side, -1 the negative one and 0 clips nothing (the live stack's mirror, whose image
	// draws the kept side again across the plane), drawn with the clipped variants of the
	// mesh pipelines (Mesh_Pipelines.clip). The depth-only passes (Live AO's, the studio's)
	// draw it whole.
	clip: [3]f32,
}

// Whether `model` turns space over (a reflection): its triangles then wind the other way.
model_reflected :: proc(model: Mat4) -> bool {
	return linalg.determinant(matrix[3, 3]f32{
		model[0, 0], model[0, 1], model[0, 2],
		model[1, 0], model[1, 1], model[1, 2],
		model[2, 0], model[2, 1], model[2, 2],
	}) < 0
}

// How the viewport shows the meshes (Draw_Item.pass): shaded as the materials say, or
// one of the diagnostic passes that check form, as Blender's and ZBrush's do. Normals
// shows the view-space normal as a colour; Depth near as white and far as black;
// Curvature creases toward blue and crests toward orange; AO a plain grey that the live
// occlusion darkens; Silhouette every object flat near-black; Skin detail what a detail
// skin holds over its mesh, as a normal map's colours (flat lavender where it holds
// nothing, and on objects with no skin). One more is the viewport shading's own rather
// than a pass that checks form: Unlit, the Flat look, the colour (with paint, the mask,
// cavity and ridge) shown as it is, with no light.
View_Pass :: enum u8 {
	Shaded,
	Normals,
	Depth,
	Curvature,
	AO,
	Silhouette,
	Skin_Detail,
	Unlit,
}

// What render_viewport did this frame, for the stats panel.
Viewport_Stats :: struct {
	triangles:     u64,  // triangles submitted
	draws:         u64,  // draw commands (indirect ones counted one by one)
	skin_grid:     u64,  // small triangles of detail skins drawn as their grid (skin_tess_split)
	chunks:        u64,  // chunks considered for culling
	culled_view:   u64,  // ...outside the view
	culled_back:   u64,  // ...facing away
	simplified:    u64,  // groups of chunks drawn from their simplified copies
	// Items drawn with their wireframe: in the shading pass (wire_pipeline), or as their
	// triangles again in lines.
	wire_shaded:   u64,
	wire_lines:    u64,
	cull_ms:       f64,  // CPU time spent culling and writing draw commands
	partial:       bool, // kept the previous frame and redrew only `redrawn_px` pixels
	redrawn_px:    u64,
	redrawn:       [4]i32, // ...in this rectangle: x, y, width, height (top-left origin)
	cache_used:    bool, // idle objects came from the cache
	cache_redrawn: bool, // ...which had to be redrawn first
}

// Matches Material_Uniforms in mesh.frag.slang.
Material_Uniforms :: struct {
	base_color: [4]f32,
	params:     [4]f32, // x: ambient, y: specular strength, z: specular power, w: wrap
	surface:    [4]f32, // x: metallic, y: roughness (0: classic), z: 1 for flat shading, w: 1 for the matcap
	checker:    [4]f32, // the density preview: first lattice point, cell size (0: none)
	look:       [4]f32, // exposure in stops, cavity, ridge (Draw_Item.look)
	lights:     Lights, // Draw_Item.lights
	maps:       [4]f32, // textured items: x, y, z which maps are bound (base colour, ORM, normal), w the Texture_View; zero otherwise
	// The image environment (environment.odin's material_environment); zero for the studio.
	env:        [4]f32, // x: 1 when bound, y: its strength, z: its prefiltered levels less one; w: 1 under a parallel projection, bound or not
	env_axes:   [3][4]f32, // the panorama's axes in view space (Environment_Look.rotation)
	env_sh:     [9][4]f32, // its diffuse light's harmonics, rgb
	style:      [4]f32, // Draw_Item.style
	pass:       [4]f32, // Draw_Item.pass
	fade:       [4]f32, // Draw_Item.fade
	// The wireframe's colour, linear, read only by mesh_wire.frag.slang, whose block alone
	// declares it: the other mesh shaders read the 1168 bytes before it.
	wire:       [4]f32,
	// Draw_Item.clip, read only by the clipped variants (*_clip.frag.slang).
	clip:       [4]f32,
}
#assert(size_of(Material_Uniforms) == 1200)
#assert(offset_of(Material_Uniforms, pass) == 1136)
#assert(offset_of(Material_Uniforms, fade) == 1152)
#assert(offset_of(Material_Uniforms, maps) == 896)

renderer_init :: proc(r: ^Renderer, window: ^sdl.Window, debug: bool) -> bool {
	r.window = window
	r.background = {BACKGROUND, BACKGROUND}
	// A device that falls short of the backend's needs ends the start, with the reason in
	// backend_error for the app's message.
	ok: bool
	r.anisotropy, ok = gpu.create_device(debug)
	r.has_device = ok
	if !ok {
		if gpu.backend_error() == "" do gpu.backend_fail(gpu.backend_title(), "no GPU device")
		return false
	}
	log.infof("GPU: %s", gpu_description(r))
	caps_fill(r)
	if !gpu.claim_window(window) {
		gpu.backend_fail(gpu.backend_title(), "the window cannot be drawn into (%s)", gpu.last_error())
		return false
	}
	if debug do r.ray_query_check = ray_query_check(r)

	// A depth format shaders can also read, for the studio render, where there is one.
	r.depth_format = .D32_Float
	for format in ([2]gpu.Format{.D32_Float, .D24_Unorm}) {
		if gpu.texture_supports_format(format, .D2, {.Depth_Target, .Sampled}) {
			r.depth_format, r.depth_sampled = format, true
			break
		}
	}
	if !r.depth_sampled && !gpu.texture_supports_format(r.depth_format, .D2, {.Depth_Target}) {
		r.depth_format = .D24_Unorm
	}

	r.single = mesh_pipelines_create(r, ._1)
	if r.single.wire == 0 do log.warn("wireframe: this device cannot draw lines; the wireframe stays off")
	r.no_paint = gpu.create_buffer({usage = {.Graphics_Storage_Read}, size = size_of(Paint_Packed)})
	if r.no_paint == 0 do log.errorf("paint buffer creation failed: %s", gpu.last_error())
	white := [4]u8{255, 255, 255, 255}
	r.no_matcap = matcap_create(r, white[:], 1, 1)
	r.matcap_sampler = gpu.create_sampler({
		min_filter = .Linear, mag_filter = .Linear, mipmap_mode = .Linear,
		address_mode_u = .Clamp_To_Edge, address_mode_v = .Clamp_To_Edge, address_mode_w = .Clamp_To_Edge,
		max_lod = 1000,
	})
	if r.matcap_sampler == 0 do log.errorf("matcap sampler: %s", gpu.last_error())
	flat_normal := [4]u8{128, 128, 255, 255}
	r.no_normal_map = texture_create(r, TEXTURE_FORMATS[.Normal], flat_normal[:], 1, 1)
	r.texture_sampler = gpu.create_sampler({
		min_filter = .Linear, mag_filter = .Linear, mipmap_mode = .Linear,
		address_mode_u = .Repeat, address_mode_v = .Repeat, address_mode_w = .Repeat,
		max_lod = 1000, max_anisotropy = 8, enable_anisotropy = r.anisotropy,
	})
	if r.texture_sampler == 0 do log.errorf("texture sampler: %s", gpu.last_error())
	black := [4]u8{0, 0, 0, 255}
	r.no_environment = texture_create(r, .RGBA8_Unorm, black[:], 1, 1)
	r.env_sampler = gpu.create_sampler({
		min_filter = .Linear, mag_filter = .Linear, mipmap_mode = .Linear,
		address_mode_u = .Repeat, address_mode_v = .Clamp_To_Edge, address_mode_w = .Clamp_To_Edge,
		max_lod = 1000,
	})
	if r.env_sampler == 0 do log.errorf("environment sampler: %s", gpu.last_error())
	if r.single.textured == 0 do log.warn("textures: the textured pipeline could not be made; textured objects draw as clay")
	return r.single.mesh != 0 && r.single.clear != 0 && r.no_paint != 0 && r.no_matcap != 0 && r.matcap_sampler != 0 && r.no_normal_map != 0 && r.texture_sampler != 0 && r.no_environment != 0 && r.env_sampler != 0
}

// The GPU's name alone, for people (Settings > System > Graphics). Temp-allocated.
gpu_name :: proc(r: ^Renderer) -> string {
	name := gpu.device_name()
	return fmt.tprint(name if name != "" else "an unknown GPU")
}

// The GPU's name, backend and driver version, for logs and benchmark reports.
// Temp-allocated.
gpu_description :: proc(r: ^Renderer) -> string {
	name, version := gpu.device_name(), gpu.driver_version()
	return fmt.tprintf("%s (%s, driver %s)", name if name != "" else "unknown GPU", gpu.backend_name(), version if version != "" else "unknown")
}

// Lets the device draw into another window (a view window): mailbox where the window offers
// it, since such a window is presented only when what it shows changed and must never hold
// the main window's frame; else the vsync claiming gives.
window_claim :: proc(r: ^Renderer, window: ^sdl.Window) -> bool {
	if !gpu.claim_window(window) do return false
	if gpu.window_supports_present_mode(window, .Mailbox) && !gpu.set_swapchain_parameters(window, .Sdr, .Mailbox) {
		log.warnf("a view window keeps vsync: %s", gpu.last_error())
	}
	return true
}

// Gives a window claimed with window_claim back; the GPU layer waits for its frames.
window_release :: proc(r: ^Renderer, window: ^sdl.Window) {
	gpu.release_window(window)
}

// Picks how frames reach the screen. With vsync (the default), a frame waits for the
// display's refresh: no tearing, and the frame rate is capped at the refresh rate.
// Without, a frame is shown as soon as it is ready: mailbox where the window offers it
// (no tearing; a newer frame replaces one still waiting), else immediate (may tear).
// Returns false, keeping the current mode, when the window offers neither or the
// change fails. Recreates the swapchain, so it must not be called while a swapchain
// texture is acquired.
renderer_set_vsync :: proc(r: ^Renderer, vsync: bool) -> bool {
	mode := gpu.Present_Mode.Vsync
	if !vsync {
		switch {
		case gpu.window_supports_present_mode(r.window, .Mailbox):
			mode = .Mailbox
		case gpu.window_supports_present_mode(r.window, .Immediate):
			mode = .Immediate
		case:
			log.warn("vsync stays on: the display offers no other present mode")
			return false
		}
	}
	if mode == r.present_mode do return true
	if !gpu.set_swapchain_parameters(r.window, .Sdr, mode) {
		log.errorf("SetGPUSwapchainParameters failed: %s", gpu.last_error())
		return false
	}
	r.present_mode = mode
	log.infof("present mode: %v", mode)
	return true
}

// Which present modes besides vsync the main window offers: what Unlimited and Limit can
// use there, which the exit stats report so a run on a tablet shows its driver's.
renderer_present_offers :: proc(r: ^Renderer) -> (mailbox, immediate: bool) {
	return gpu.window_supports_present_mode(r.window, .Mailbox), gpu.window_supports_present_mode(r.window, .Immediate)
}

// The present mode in use, as the exit stats and the Stats panel name it.
renderer_present_name :: proc(r: ^Renderer) -> string {
	switch r.present_mode {
	case .Vsync:     return "vsync"
	case .Mailbox:   return "mailbox"
	case .Immediate: return "immediate"
	}
	return "unknown"
}

// Waits for the GPU, then releases everything the renderer created, in reverse order.
renderer_destroy :: proc(r: ^Renderer) {
	if !r.has_device do return
	_ = gpu.wait_for_idle()
	gpu_cull_destroy(r)
	sculpt_gpu_destroy(r)
	mesh_pipelines_destroy(r, &r.single)
	mesh_pipelines_destroy(r, &r.multi)
	if r.no_paint != 0 do gpu.release_buffer(r.no_paint)
	if r.no_matcap != 0 do gpu.release_texture(r.no_matcap)
	if r.matcap_sampler != 0 do gpu.release_sampler(r.matcap_sampler)
	if r.no_normal_map != 0 do gpu.release_texture(r.no_normal_map)
	if r.texture_sampler != 0 do gpu.release_sampler(r.texture_sampler)
	if r.no_environment != 0 do gpu.release_texture(r.no_environment)
	if r.env_sampler != 0 do gpu.release_sampler(r.env_sampler)
	gpu.release_window(r.window)
	gpu.destroy_device()
	r^ = {}
}

// Sets how many samples a viewport pixel takes: ._1 for none, or ._2, ._4 or ._8 to
// smooth the edges of silhouettes and wireframe lines (MSAA). Where the device cannot
// use the count asked for with both the colour and the depth format, it tries the other
// of 2 and 4 (Vulkan promises 4), then none. Returns what it set; the viewport target
// is remade at that count on its next viewport_target_resize. The old pipelines go once
// the frames that drew with them are done.
renderer_set_msaa :: proc(r: ^Renderer, want: gpu.Sample_Count) -> gpu.Sample_Count {
	supported :: proc(r: ^Renderer, count: gpu.Sample_Count) -> bool {
		return count == ._1 || gpu.texture_supports_sample_count(VIEWPORT_COLOR_FORMAT, count) && gpu.texture_supports_sample_count(r.depth_format, count)
	}
	got := gpu.Sample_Count._1
	other := gpu.Sample_Count._4 if want == ._2 else ._2
	switch {
	case supported(r, want):                  got = want
	case want != ._1 && supported(r, other): got = other
	}
	if got == r.samples do return got
	mesh_pipelines_destroy(r, &r.multi)
	if got != ._1 {
		r.multi = mesh_pipelines_create(r, got)
		if r.multi.mesh == 0 || r.multi.clear == 0 {
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
mesh_pipelines :: proc(r: ^Renderer, samples: gpu.Sample_Count) -> ^Mesh_Pipelines {
	return &r.multi if samples != ._1 else &r.single
}

@(private)
mesh_pipelines_create :: proc(r: ^Renderer, samples: gpu.Sample_Count) -> Mesh_Pipelines {
	return {
		mesh = create_mesh_pipeline(r, .Solid, samples),
		wire = create_mesh_pipeline(r, .Wire, samples),
		lines = create_mesh_pipeline(r, .Lines, samples),
		clear = create_clear_pipeline(r, samples),
		see = create_mesh_pipeline(r, .See_Through, samples),
		floor = create_floor_pipeline(r, samples),
		textured = create_mesh_pipeline(r, .Solid, samples, textured = true),
		textured_see = create_mesh_pipeline(r, .See_Through, samples, textured = true),
		skinned = create_mesh_pipeline(r, .Solid, samples, skinned = true),
		skin_tess = create_mesh_pipeline(r, .Solid, samples, skin_tess = true),
		samples = samples,
	}
}

@(private)
mesh_pipelines_destroy :: proc(r: ^Renderer, p: ^Mesh_Pipelines) {
	for pipeline in ([10]gpu.Graphics_Pipeline{p.mesh, p.wire, p.lines, p.clear, p.see, p.floor, p.textured, p.textured_see, p.skinned, p.skin_tess}) do if pipeline != 0 do gpu.release_graphics_pipeline(pipeline)
	for pipeline in p.area do if pipeline != 0 do gpu.release_graphics_pipeline(pipeline)
	for pipeline in p.clip do if pipeline != 0 do gpu.release_graphics_pipeline(pipeline)
	if p.mesh_wire != 0 do gpu.release_graphics_pipeline(p.mesh_wire)
	if p.ref_behind != 0 do gpu.release_graphics_pipeline(p.ref_behind)
	if p.ref_through != 0 do gpu.release_graphics_pipeline(p.ref_through)
	p^ = {}
}

// The area lights' pipelines of `p`'s sample count, made once, the first time an item lit
// by an area light is drawn: a scene that never has one never builds them.
@(private)
area_pipelines :: proc(r: ^Renderer, p: ^Mesh_Pipelines) {
	if p.area_made do return
	p.area_made = true
	samples := p.samples
	p.area[.Mesh] = create_mesh_pipeline(r, .Solid, samples, area = true)
	p.area[.See] = create_mesh_pipeline(r, .See_Through, samples, area = true)
	p.area[.Textured] = create_mesh_pipeline(r, .Solid, samples, textured = true, area = true)
	p.area[.Textured_See] = create_mesh_pipeline(r, .See_Through, samples, textured = true, area = true)
}

Clip_Pipeline :: enum u8 {
	Mesh,
	See,
	Textured,
	Textured_See,
	Skinned,
}

@(private)
clip_pipelines :: proc(r: ^Renderer, p: ^Mesh_Pipelines) {
	if p.clip_made do return
	p.clip_made = true
	samples := p.samples
	p.clip[.Mesh] = create_mesh_pipeline(r, .Solid, samples, clip = true)
	p.clip[.See] = create_mesh_pipeline(r, .See_Through, samples, clip = true)
	p.clip[.Textured] = create_mesh_pipeline(r, .Solid, samples, textured = true, clip = true)
	p.clip[.Textured_See] = create_mesh_pipeline(r, .See_Through, samples, textured = true, clip = true)
	if p.skinned != 0 do p.clip[.Skinned] = create_mesh_pipeline(r, .Solid, samples, skinned = true, clip = true)
}

// The pipeline drawing `p`'s sample count's meshes with their wireframe in the shading
// pass, made the first time it is asked for where the device offers barycentrics; nil
// where it does not, when Renderer.wire_as_lines asks for lines, or where the device
// refused it (logged once), and the wireframe is then drawn as lines.
@(private)
wire_pipeline :: proc(r: ^Renderer, p: ^Mesh_Pipelines) -> gpu.Graphics_Pipeline {
	if !r.caps.barycentric || r.wire_as_lines do return 0
	if !p.mesh_wire_made {
		p.mesh_wire_made = true
		p.mesh_wire = create_mesh_pipeline(r, .Solid, p.samples, wire_bary = true)
	}
	return p.mesh_wire
}

// Whether any light that is on in `l` is an area light.
lights_have_area :: proc(l: Lights) -> bool {
	for p, i in l.pos do if p.w == LIGHT_AREA && l.color[i].w > 0 do return true
	return false
}

// With `textured`, the pipeline of textured meshes (textured.odin): their 32-byte
// interleaved vertex, no paint buffer, the MatCap, the environment and three maps, and no
// polygroup slots. Every mesh pipeline samples the MatCap and the environment. With
// `skinned`, the pipeline of meshes with a detail skin (skin.odin): no vertex buffers, the
// vertex pulled from the paint, index, position and normal buffers, and the skin's two
// buffers in the fragment stage. With `skin_tess`, the pipeline drawing a skinned mesh's
// near triangles as the skin's grid: no vertex buffers, the paint, mesh and three skin
// buffers in the vertex stage, and the clay's own fragment stage.
@(private)
create_mesh_pipeline :: proc(r: ^Renderer, mode: Mesh_Mode, samples: gpu.Sample_Count, textured := false, skinned := false, area := false, wire_bary := false, skin_tess := false, clip := false) -> gpu.Graphics_Pipeline {
	vert_desc, frag_desc := MESH_VERT, MESH_CLIP_FRAG if clip else MESH_AREA_FRAG if area else MESH_FRAG
	if wire_bary do vert_desc, frag_desc = MESH_WIRE_VERT, MESH_WIRE_FRAG
	if textured do vert_desc, frag_desc = TEXTURED_VERT, TEXTURED_CLIP_FRAG if clip else TEXTURED_AREA_FRAG if area else TEXTURED_FRAG
	if skinned do vert_desc, frag_desc = SKIN_VERT, SKIN_CLIP_FRAG if clip else SKIN_FRAG
	if skin_tess do vert_desc = SKIN_TESS_VERT
	vert := gpu.create_shader(vert_desc)
	frag := gpu.create_shader(frag_desc)
	// Shaders are only needed until the pipeline is built.
	defer if vert != 0 do gpu.release_shader(vert)
	defer if frag != 0 do gpu.release_shader(frag)
	if vert == 0 || frag == 0 {
		log.errorf("CreateGPUShader failed: %s", gpu.last_error())
		return 0
	}

	buffers := [2]gpu.Vertex_Buffer {
		{slot = 0, pitch = size_of(geom.Vec3), input_rate = .Vertex},
		{slot = 1, pitch = size_of(Normal_Packed), input_rate = .Vertex},
	}
	attributes := [4]gpu.Vertex_Attribute {
		{location = 0, buffer_slot = 0, format = .Float3},
		{location = 1, buffer_slot = 1, format = .Short2_Norm},
		{}, {},
	}
	num_buffers, num_attributes := 2, 2
	if textured {
		buffers[0] = {slot = 0, pitch = size_of(Textured_Vertex), input_rate = .Vertex}
		attributes = {
			{location = 0, buffer_slot = 0, format = .Float3, offset = u32(offset_of(Textured_Vertex, position))},
			{location = 1, buffer_slot = 0, format = .Short2_Norm, offset = u32(offset_of(Textured_Vertex, normal))},
			{location = 2, buffer_slot = 0, format = .Short4_Norm, offset = u32(offset_of(Textured_Vertex, tangent))},
			{location = 3, buffer_slot = 0, format = .Float2, offset = u32(offset_of(Textured_Vertex, uv))},
		}
		num_buffers, num_attributes = 1, 4
	}
	if skinned || skin_tess do num_buffers, num_attributes = 0, 0
	wire := mode == .Wire
	lines := mode == .Lines
	color_targets := [1]gpu.Color_Target_Desc{{format = VIEWPORT_COLOR_FORMAT, blend_state = BLEND_OVER if mode == .See_Through else {}}}

	pipeline := gpu.create_graphics_pipeline({
		vertex_shader = vert,
		fragment_shader = frag,
		vertex_input = {
			buffers = buffers[:num_buffers],
			attributes = attributes[:num_attributes],
		},
		primitive = .Line_List if lines else .Triangle_List,
		// Lines have no side to cull, and depth bias does not reach them: lines_pass pulls
		// them toward the eye through the view instead.
		rasterizer_state = lines ? gpu.Rasterizer_State{fill_mode = .Fill, cull_mode = .None} : wire ? gpu.Rasterizer_State{
			fill_mode = .Line, cull_mode = .Back, front_face = .Counter_Clockwise,
			// Toward the eye, so a line wins against the triangle it borders.
			enable_depth_bias = true, depth_bias_constant_factor = -2, depth_bias_slope_factor = -1,
		} : gpu.Rasterizer_State{fill_mode = .Fill, cull_mode = .Back, front_face = .Counter_Clockwise},
		depth_stencil_state = {compare_op = .Less_Or_Equal if wire || lines else .Less, enable_depth_test = true, enable_depth_write = mode == .Solid},
		multisample_state = {sample_count = samples},
		targets = {
			color_targets = color_targets[:],
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	switch {
	case pipeline != 0:
	case area:
		log.warnf("area lights left out: the %v area pipeline could not be made: %s", mode, gpu.last_error())
	case textured:
		log.warnf("textured %v pipeline: %s", mode, gpu.last_error())
	case wire_bary:
		log.warnf("the wireframe is drawn as lines: the pipeline drawing it in the shading could not be made: %s", gpu.last_error())
	case skinned:
		log.warnf("detail skins show the mesh's own normals: the skinned pipeline could not be made: %s", gpu.last_error())
	case skin_tess:
		log.warnf("detail skins keep the mesh's outline: the pipeline drawing them as their grid could not be made: %s", gpu.last_error())
	case mode == .Solid:
		log.errorf("CreateGPUGraphicsPipeline failed: %s", gpu.last_error())
	case mode == .See_Through:
		log.warnf("see-through objects are drawn solid: the blended pipeline could not be made: %s", gpu.last_error())
	case mode == .Lines:
		log.warnf("cage edges stay hidden: the line pipeline could not be made: %s", gpu.last_error())
	}
	return pipeline
}

// Colour blended over what is there by the source's alpha; the target's alpha kept as it
// is, so the viewport image stays opaque wherever the interface shows it.
@(private)
BLEND_OVER :: gpu.Blend_State {
	enable_blend          = true,
	src_color_blendfactor = .Src_Alpha,
	dst_color_blendfactor = .One_Minus_Src_Alpha,
	color_blend_op        = .Add,
	src_alpha_blendfactor = .Zero,
	dst_alpha_blendfactor = .One,
	alpha_blend_op        = .Add,
}

@(private)
create_floor_pipeline :: proc(r: ^Renderer, samples: gpu.Sample_Count) -> gpu.Graphics_Pipeline {
	vert := gpu.create_shader(FLOOR_VERT)
	frag := gpu.create_shader(FLOOR_FRAG)
	defer if vert != 0 do gpu.release_shader(vert)
	defer if frag != 0 do gpu.release_shader(frag)
	if vert == 0 || frag == 0 {
		log.warnf("the floor grid stays off: its shaders could not be made: %s", gpu.last_error())
		return 0
	}
	color_targets := [1]gpu.Color_Target_Desc{{format = VIEWPORT_COLOR_FORMAT, blend_state = BLEND_OVER}}
	pipeline := gpu.create_graphics_pipeline({
		vertex_shader = vert,
		fragment_shader = frag,
		primitive = .Triangle_List,
		rasterizer_state = {fill_mode = .Fill, cull_mode = .None},
		// Tested against the meshes' depth, which it leaves as it is.
		depth_stencil_state = {compare_op = .Less_Or_Equal, enable_depth_test = true, enable_depth_write = false},
		multisample_state = {sample_count = samples},
		targets = {
			color_targets = color_targets[:],
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	if pipeline == 0 do log.warnf("the floor grid stays off: its pipeline could not be made: %s", gpu.last_error())
	return pipeline
}

@(private)
create_clear_pipeline :: proc(r: ^Renderer, samples: gpu.Sample_Count) -> gpu.Graphics_Pipeline {
	vert := gpu.create_shader(CLEAR_VERT)
	frag := gpu.create_shader(CLEAR_FRAG)
	defer if vert != 0 do gpu.release_shader(vert)
	defer if frag != 0 do gpu.release_shader(frag)
	if vert == 0 || frag == 0 {
		log.errorf("CreateGPUShader failed: %s", gpu.last_error())
		return 0
	}
	color_targets := [1]gpu.Color_Target_Desc{{format = VIEWPORT_COLOR_FORMAT}}
	pipeline := gpu.create_graphics_pipeline({
		vertex_shader = vert,
		fragment_shader = frag,
		primitive = .Triangle_List,
		rasterizer_state = {fill_mode = .Fill, cull_mode = .None},
		// Writes far-plane depth everywhere it lands, whatever was there.
		depth_stencil_state = {compare_op = .Always, enable_depth_test = true, enable_depth_write = true},
		multisample_state = {sample_count = samples},
		targets = {
			color_targets = color_targets[:],
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	if pipeline == 0 {
		log.errorf("CreateGPUGraphicsPipeline (clear) failed: %s", gpu.last_error())
	}
	return pipeline
}

// Ensures the target matches the requested size and sample count (the main viewport
// passes Renderer.samples; thumbnails and the navigation head stay at one sample, as the
// interface samples them), and whether its depth is transient (`transient_depth`: one-shot
// targets drawn in one pass with keep_depth false). Old textures are released; the backend
// defers the actual free until in-flight command buffers no longer reference them.
viewport_target_resize :: proc(r: ^Renderer, vt: ^Viewport_Target, requested_width, requested_height: u32, samples := gpu.Sample_Count._1, transient_depth := false) -> bool {
	width, height := max(requested_width, 1), max(requested_height, 1)
	multi := samples != ._1
	tile := multi && !transient_depth && (r.caps.transient_targets || r.tile_msaa) && !r.partial
	if vt.color != 0 && vt.width == width && vt.height == height && vt.samples == samples && vt.transient_depth == transient_depth && vt.tile == tile do return true
	viewport_target_destroy(r, vt)

	vt.color = gpu.create_texture({
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.Color_Target, .Sampled},
		width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
	})
	if multi {
		info := gpu.Texture_Desc{
			type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.Color_Target},
			width = width, height = height, layer_count_or_depth = 1, num_levels = 1, sample_count = samples,
		}
		vt.multi_color = gpu.create_texture_transient(info) if tile else gpu.create_texture(info)
	}
	// A multisampled texture cannot be sampled: the studio render draws its own depth then.
	if transient_depth || tile {
		vt.depth = gpu.create_texture_transient({
			type = .D2, format = r.depth_format, usage = {.Depth_Target},
			width = width, height = height, layer_count_or_depth = 1, num_levels = 1, sample_count = samples,
		})
	} else {
		vt.depth = gpu.create_texture({
			type = .D2, format = r.depth_format, usage = {.Depth_Target, .Sampled} if r.depth_sampled && !multi else {.Depth_Target},
			width = width, height = height, layer_count_or_depth = 1, num_levels = 1, sample_count = samples,
		})
	}
	if vt.color == 0 || vt.depth == 0 || multi && vt.multi_color == 0 {
		log.errorf("viewport target creation failed: %s", gpu.last_error())
		viewport_target_destroy(r, vt)
		return false
	}
	vt.width, vt.height, vt.samples, vt.transient_depth, vt.tile = width, height, samples, transient_depth, tile
	gpu.set_texture_name(vt.color, "viewport colour")
	gpu.set_texture_name(vt.depth, "viewport depth")
	if multi do gpu.set_texture_name(vt.multi_color, "viewport colour (multisampled)")
	return true
}

viewport_target_destroy :: proc(r: ^Renderer, vt: ^Viewport_Target) {
	for t in ([5]gpu.Texture{vt.color, vt.depth, vt.multi_color, vt.cache.color, vt.cache.depth}) do if t != 0 do gpu.release_texture(t)
	vt^ = {}
}

// Copies `src`, `width` by `height` in the viewport's colour format (the target's colour,
// or the studio's, render mode's or live occlusion's picture), into `dst`'s colour, made
// or remade at that size first, on a command buffer of its own submitted at once: the copy
// is queued before anything later this frame draws over `src` or releases it.
viewport_copy :: proc(r: ^Renderer, dst: ^Viewport_Target, src: gpu.Texture, width, height: u32) -> bool {
	if !r.has_device || src == 0 || width == 0 || height == 0 do return false
	if !viewport_target_resize(r, dst, width, height) do return false
	cmd := gpu.acquire_command_buffer()
	if cmd == nil do return false
	pass := gpu.begin_copy_pass(cmd)
	gpu.copy_texture_to_texture(pass, {texture = src}, {texture = dst.color}, width, height, 1, cycle = false)
	gpu.end_copy_pass(pass)
	_, ok := gpu.submit(cmd)
	return ok
}

// Creates the cache textures on first use, at the target's size. They are released
// with the target, so a resize recreates them.
@(private)
static_cache_ensure :: proc(r: ^Renderer, vt: ^Viewport_Target) -> bool {
	if vt.cache.color != 0 do return true
	vt.cache.color = gpu.create_texture({
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.Color_Target},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1, sample_count = vt.samples,
	})
	vt.cache.depth = gpu.create_texture({
		type = .D2, format = r.depth_format, usage = {.Depth_Target},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1, sample_count = vt.samples,
	})
	vt.cache.key = 0
	if vt.cache.color == 0 || vt.cache.depth == 0 {
		log.errorf("viewport cache creation failed: %s", gpu.last_error())
		if vt.cache.color != 0 do gpu.release_texture(vt.cache.color)
		if vt.cache.depth != 0 do gpu.release_texture(vt.cache.depth)
		vt.cache = {}
		return false
	}
	return true
}

// Creates the GPU buffers for `mesh` and fills them. Where the device offers shared
// buffers (Gpu_Caps.shared_buffers) the CPU writes them in place, spread over r.pool, with
// no GPU work; otherwise, and for any buffer the shared memory could not hold, it uploads
// in chunks through the transfer buffer, waiting for the GPU after each chunk. For
// loading, not per frame. `mask`, per vertex, is the sculptor's mask; nil when nothing is
// masked.
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
	mb.index_version = mb.version
	// Readable by compute as well, so the traced studio casts rays at the triangles the
	// viewport draws without copying them; a device that refuses gets plain buffers.
	positions_info := gpu.Buffer_Desc{usage = {.Vertex, .Storage_Read, .Storage_Write, .Graphics_Storage_Read}, size = vbytes}
	indices_info := gpu.Buffer_Desc{usage = {.Index, .Storage_Read, .Graphics_Storage_Read}, size = ibytes}
	// Normals, positions and indices are read as storage too by the skinned pipeline, which
	// pulls its vertices itself (skin.odin), and the normals are written by the normals
	// kernel of sculpting on the GPU (sculpt_gpu.odin).
	normals_info := gpu.Buffer_Desc{usage = {.Vertex, .Graphics_Storage_Read, .Storage_Write}, size = nbytes}
	positions_map, indices_map, normals_map: rawptr
	// Where ray queries are offered the driver also builds acceleration structures from
	// them (trace.odin).
	rq := r.caps.ray_query
	if r.caps.shared_buffers {
		mb.positions, positions_map = gpu.create_buffer_mapped(positions_info, rq)
		mb.indices, indices_map = gpu.create_buffer_mapped(indices_info, rq)
		mb.normals, normals_map = gpu.create_buffer_mapped(normals_info)
	}
	if mb.positions == 0 do mb.positions = gpu.create_buffer(positions_info, rq)
	if mb.indices == 0 do mb.indices = gpu.create_buffer(indices_info, rq)
	mb.storage = mb.positions != 0 && mb.indices != 0
	if !mb.storage {
		if mb.positions != 0 do gpu.release_buffer(mb.positions)
		if mb.indices != 0 do gpu.release_buffer(mb.indices)
		positions_map, indices_map = nil, nil
		mb.positions = gpu.create_buffer({usage = {.Vertex}, size = vbytes})
		mb.indices = gpu.create_buffer({usage = {.Index}, size = ibytes})
	}
	if mb.normals == 0 do mb.normals = gpu.create_buffer(normals_info)
	if mb.positions == 0 || mb.normals == 0 || mb.indices == 0 {
		log.errorf("mesh buffer creation failed: %s", gpu.last_error())
		mesh_buffers_destroy(r, &mb)
		return {}, false
	}
	gpu.set_buffer_name(mb.positions, "mesh positions")
	gpu.set_buffer_name(mb.indices, "mesh indices")
	gpu.set_buffer_name(mb.normals, "mesh normals")
	ok = true
	if indices_map != nil {
		fill_copy(r.pool, indices_map, slice.to_bytes(mesh.indices[:]))
		gpu.buffer_filled(mb.indices)
	} else {
		ok = upload_now(r, mb.indices, slice.to_bytes(mesh.indices[:]))
	}
	if positions_map != nil {
		fill_copy(r.pool, positions_map, slice.to_bytes(mesh.positions[:]))
		gpu.buffer_filled(mb.positions)
	} else {
		ok = ok && upload_now(r, mb.positions, slice.to_bytes(mesh.positions[:]))
	}
	if normals_map != nil {
		fill_normals(r.pool, normals_map, mesh.normals[:], mask)
		gpu.buffer_filled(mb.normals)
	} else {
		ok = ok && upload_normals_now(r, &mb, mesh.normals[:], mask)
	}
	if !ok {
		log.errorf("mesh upload failed: %s", gpu.last_error())
		mesh_buffers_destroy(r, &mb)
		return {}, false
	}
	return mb, true
}

// Elements a job of fill_copy and fill_normals writes: a multiple of 64, so no two jobs
// write the same cache line of the mapped (often write-combined) memory whatever the
// element size.
@(private = "file")
FILL_ELEMENTS :: 1 << 18

// Copies `src` to `dst`, a buffer's mapping, in ranges spread over `pool` (all on the
// calling thread when nil). The mapping is only written, never read.
@(private = "file")
fill_copy :: proc(pool: ^jobs.Pool, dst: rawptr, src: []u8) {
	Job :: struct {
		dst: [^]u8,
		src: []u8,
	}
	job := Job{([^]u8)(dst), src}
	BYTES :: FILL_ELEMENTS * 16
	jobs.parallel_for(pool, (len(src) + BYTES - 1) / BYTES, &job, proc(data: rawptr, k: int) {
		job := cast(^Job)data
		lo := k * BYTES
		hi := min(lo + BYTES, len(job.src))
		copy(job.dst[lo:hi], job.src[lo:hi])
	})
}

// Packs every normal (with its mask value) into `dst`, a buffer's mapping, as
// upload_normals_now packs them into upload memory.
@(private = "file")
fill_normals :: proc(pool: ^jobs.Pool, dst: rawptr, normals: []geom.Vec3, mask: []u8) {
	Job :: struct {
		dst:     [^]Normal_Packed,
		normals: []geom.Vec3,
		mask:    []u8,
	}
	job := Job{([^]Normal_Packed)(dst), normals, mask}
	jobs.parallel_for(pool, (len(normals) + FILL_ELEMENTS - 1) / FILL_ELEMENTS, &job, proc(data: rawptr, k: int) {
		job := cast(^Job)data
		lo := k * FILL_ELEMENTS
		hi := min(lo + FILL_ELEMENTS, len(job.normals))
		if job.mask != nil {
			for i in lo ..< hi do job.dst[i] = pack_normal(job.normals[i], job.mask[i])
		} else {
			for i in lo ..< hi do job.dst[i] = pack_normal(job.normals[i], 0)
		}
	})
}

// Copies `data` to the start of `buffer` on command buffers of their own, submitted at
// once, UPLOAD_CHUNK bytes each, so a large mesh never needs all its bytes in upload
// memory: a chunk waits only for the one two before it. Work submitted later sees the
// buffer filled. For loading and rebuilding, not per frame.
@(private)
upload_now :: proc(r: ^Renderer, buffer: gpu.Buffer, data: []u8) -> bool {
	Fill :: struct {
		data: []u8,
	}
	fill := Fill{data}
	return upload_now_by(r, buffer, len(data), &fill, proc(dst: []u8, offset: int, user: rawptr) {
		copy(dst, (^Fill)(user).data[offset:][:len(dst)])
	})
}

// Packs every normal (with its mask value) into the normals buffer as upload_now copies.
@(private)
upload_normals_now :: proc(r: ^Renderer, mb: ^Mesh_Buffers, normals: []geom.Vec3, mask: []u8) -> bool {
	Fill :: struct {
		normals: []geom.Vec3,
		mask:    []u8,
	}
	fill := Fill{normals, mask}
	return upload_now_by(r, mb.normals, len(normals) * size_of(Normal_Packed), &fill, proc(dst: []u8, offset: int, user: rawptr) {
		f := (^Fill)(user)
		first := offset / size_of(Normal_Packed)
		out := slice.reinterpret([]Normal_Packed, dst)
		if f.mask != nil {
			for &n, i in out do n = pack_normal(f.normals[first + i], f.mask[first + i])
		} else {
			for &n, i in out do n = pack_normal(f.normals[first + i], 0)
		}
	})
}

// Bytes a command buffer of upload_now carries: 16 MB holds positions and normals for 1M
// vertices.
UPLOAD_CHUNK :: 16 << 20

// Uploads `size` bytes into `buffer`, `fill` writing each chunk's bytes from `offset`.
@(private = "file")
upload_now_by :: proc(r: ^Renderer, buffer: gpu.Buffer, size: int, user: rawptr, fill: proc(dst: []u8, offset: int, user: rawptr)) -> bool {
	tickets: [2]gpu.Ticket
	chunk_index := 0
	for offset := 0; offset < size; offset += UPLOAD_CHUNK {
		n := min(UPLOAD_CHUNK, size - offset)
		slot := &tickets[chunk_index % len(tickets)]
		chunk_index += 1
		if !gpu.wait(slot^) do return false
		cmd := gpu.acquire_command_buffer()
		if cmd == nil do return false
		dst := gpu.stage_buffer(cmd, buffer, u32(offset), u32(n))
		if dst == nil {
			_ = gpu.cancel_command_buffer(cmd)
			return false
		}
		fill(dst, offset, user)
		ok: bool
		slot^, ok = gpu.submit(cmd)
		if !ok do return false
	}
	return true
}

mesh_buffers_destroy :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	if mb.positions != 0 do gpu.release_buffer(mb.positions)
	if mb.normals != 0 do gpu.release_buffer(mb.normals)
	if mb.indices != 0 do gpu.release_buffer(mb.indices)
	if mb.indirect != 0 do gpu.release_buffer(mb.indirect)
	if mb.lod_indices != 0 do gpu.release_buffer(mb.lod_indices)
	for &cd in mb.copy_draws {
		if cd.indirect != 0 do gpu.release_buffer(cd.indirect)
		delete(cd.visible)
		delete(cd.lod_visible)
	}
	delete(mb.copy_draws)
	gpu_cull_release(r, mb)
	sculpt_gpu_forget(r, mb)
	gpu.release_readback(mb.cull.download)
	delete(mb.cull.expect)
	if k, found := slice.linear_search(r.gpu_culling.checked[:], mb); found do unordered_remove(&r.gpu_culling.checked, k)
	if mb.paint != 0 do gpu.release_buffer(mb.paint)
	if mb.paint_material != 0 do gpu.release_buffer(mb.paint_material)
	if mb.edges != 0 do gpu.release_buffer(mb.edges)
	if mb.tri_edges != 0 do gpu.release_buffer(mb.tri_edges)
	if mb.skin_normals != 0 do gpu.release_buffer(mb.skin_normals)
	if mb.skin_tris != 0 do gpu.release_buffer(mb.skin_tris)
	if mb.skin_heights != 0 do gpu.release_buffer(mb.skin_heights)
	if mb.trace != nil {
		trace_mesh_destroy(r, mb.trace)
		free(mb.trace)
	}
	delete(mb.visible)
	delete(mb.lod_visible)
	delete(mb.tess_visible)
	mb^ = {}
}

// Records copies of the positions and normals (with `mask`, nil when nothing is
// masked) of every vertex in `ranges` into `cmd`, through the GPU layer's upload memory
// (which takes a backing no earlier frame still reads, so an upload never stalls on the
// previous frame's copy). With `positions_only` the normals stay as the GPU has them: the
// normals kernel of sculpting on the GPU writes them this frame.
mesh_buffers_upload_ranges :: proc(r: ^Renderer, cmd: gpu.Cmd, mb: ^Mesh_Buffers, mesh: geom.Mesh, ranges: []geom.Vertex_Range, mask: []u8 = nil, positions_only := false) {
	debug_group(cmd, "Brush upload", .Uploads)
	// Recorded inside the group, so the Stats panel times them as uploads.
	defer gpu.flush_uploads(cmd)
	if len(ranges) > 0 {
		r.last_version += 1
		mb.version = r.last_version
	}
	// The staging memory is taken range by range here (gpu.stage_buffer holds a lock), then
	// filled in pieces across the pool: a large brush on a dense mesh uploads millions of
	// vertices a frame, which one thread packed in milliseconds.
	Piece :: struct {
		first, count: u32,
		positions:    []geom.Vec3,
		normals:      []Normal_Packed, // nil when positions_only
	}
	Fill :: struct {
		positions, normals: []geom.Vec3, // the mesh's
		mask:   []u8,
		pieces: []Piece,
	}
	pieces := make([dynamic]Piece, 0, 64, context.temp_allocator)
	vertices: u32
	// A refused range ends the staging, and what was staged before it is still filled:
	// staged memory is uploaded whatever it holds.
	staging: for x in ranges {
		if x.count == 0 do continue
		assert(x.first + x.count <= mb.vertex_capacity)
		dst_p := gpu.stage_buffer(cmd, mb.positions, x.first * size_of(geom.Vec3), x.count * size_of(geom.Vec3))
		if dst_p == nil {
			log.errorf("brush upload failed: %s", gpu.last_error())
			break staging
		}
		positions := slice.reinterpret([]geom.Vec3, dst_p)
		normals: []Normal_Packed
		if !positions_only {
			dst_n := gpu.stage_buffer(cmd, mb.normals, x.first * size_of(Normal_Packed), x.count * size_of(Normal_Packed))
			if dst_n == nil {
				log.errorf("brush upload failed: %s", gpu.last_error())
				// The positions just staged go up with the rest.
				for at: u32 = 0; at < x.count; at += UPLOAD_PIECE {
					count := min(UPLOAD_PIECE, x.count - at)
					append(&pieces, Piece{x.first + at, count, positions[at:][:count], nil})
				}
				break staging
			}
			normals = slice.reinterpret([]Normal_Packed, dst_n)
		}
		for at: u32 = 0; at < x.count; at += UPLOAD_PIECE {
			count := min(UPLOAD_PIECE, x.count - at)
			append(&pieces, Piece{x.first + at, count, positions[at:][:count], normals[at:][:count] if normals != nil else nil})
		}
		vertices += x.count
	}
	fill := Fill{mesh.positions[:], mesh.normals[:], mask, pieces[:]}
	jobs.parallel_for(r.pool if vertices >= UPLOAD_PARALLEL_VERTS else nil, len(pieces), &fill, proc(data: rawptr, i: int) {
		f := cast(^Fill)data
		p := f.pieces[i]
		copy(p.positions, f.positions[p.first:][:p.count])
		if p.normals == nil do return
		if f.mask != nil {
			for n, k in f.normals[p.first:][:p.count] do p.normals[k] = pack_normal(n, f.mask[p.first + u32(k)])
		} else {
			for n, k in f.normals[p.first:][:p.count] do p.normals[k] = pack_normal(n, 0)
		}
	})
}

// The vertices a worker packs at a time for a brush upload, and the fewest a frame uploads
// before the packing is spread over the pool (below it, waking the workers costs more).
@(private)
UPLOAD_PIECE :: 1 << 14
@(private)
UPLOAD_PARALLEL_VERTS :: 1 << 15

// Records copies of the paint data (colours, nil for none, the groups vertices carry, nil
// for none, and the painted roughness and metal, sculpt.Material_Paint, nil for none, into
// their own buffer, paint_material) of every vertex in `ranges` into the mesh's paint buffer, or of
// every vertex when `all` or when the buffer has to be made first, through upload memory
// like mesh_buffers_upload_ranges. On failure the buffer is dropped, so
// the mesh is drawn without paint until a later upload succeeds.
mesh_buffers_upload_paint :: proc(r: ^Renderer, cmd: gpu.Cmd, mb: ^Mesh_Buffers, colors: [][4]u8, groups: []u16, ranges: []geom.Vertex_Range, all: bool, materials: [][4]u8 = nil) {
	debug_group(cmd, "Paint upload", .Uploads)
	// Recorded inside the group, so the Stats panel times them as uploads.
	defer gpu.flush_uploads(cmd)
	ranges, all := ranges, all
	if mb.paint == 0 {
		mb.paint = gpu.create_buffer({usage = {.Graphics_Storage_Read}, size = max(mb.vertex_capacity, 1) * size_of(Paint_Packed)})
		if mb.paint == 0 {
			log.errorf("paint buffer creation failed: %s", gpu.last_error())
			return
		}
		all = true
	}
	// The roughness and metal come and go with the layers that hold them: the buffer is
	// made, filled whole, the first time they do, and dropped when none does.
	materials_all := all
	if materials == nil && mb.paint_material != 0 {
		gpu.release_buffer(mb.paint_material)
		mb.paint_material = 0
	}
	if materials != nil && mb.paint_material == 0 {
		mb.paint_material = gpu.create_buffer({usage = {.Graphics_Storage_Read}, size = max(mb.vertex_capacity, 1) * size_of(u32)})
		if mb.paint_material == 0 do log.errorf("paint material buffer creation failed: %s", gpu.last_error())
		materials_all = true
	}
	whole := [1]geom.Vertex_Range{{0, mb.vertex_capacity}}
	if all do ranges = whole[:]
	r.last_version += 1
	mb.version = r.last_version
	if mb.paint_material != 0 {
		for x in (whole[:] if materials_all else ranges) {
			if x.count == 0 do continue
			bytes := gpu.stage_buffer(cmd, mb.paint_material, x.first * size_of(u32), x.count * size_of(u32))
			if bytes == nil {
				log.errorf("paint material upload failed: %s", gpu.last_error())
				gpu.release_buffer(mb.paint_material)
				mb.paint_material = 0
				break
			}
			dst := slice.reinterpret([][4]u8, bytes)
			for k in 0 ..< x.count {
				v := x.first + k
				dst[k] = materials[v] if int(v) < len(materials) else {}
			}
		}
	}
	for x in ranges {
		if x.count == 0 do continue
		bytes := gpu.stage_buffer(cmd, mb.paint, x.first * size_of(Paint_Packed), x.count * size_of(Paint_Packed))
		if bytes == nil {
			log.errorf("paint upload failed: %s", gpu.last_error())
			gpu.release_buffer(mb.paint)
			mb.paint = 0
			return
		}
		dst := slice.reinterpret([]Paint_Packed, bytes)
		for k in 0 ..< x.count {
			v := x.first + k
			p: Paint_Packed
			if colors != nil && int(v) < len(colors) do p[0] = transmute(u32)colors[v]
			if groups != nil && int(v) < len(groups) do p[1] = u32(groups[v])
			dst[k] = p
		}
	}
}

// Records copies of the `ranges` of `indices`, the mesh's simplified copies, into its
// LOD buffer; all of `indices` when `all`, or when the buffer has to be created or
// grown to hold them (first to `expected` indices, then by half again), through upload
// memory like mesh_buffers_upload_ranges. On failure the buffer is
// dropped, so the mesh is drawn at full detail until a later upload succeeds.
mesh_buffers_upload_lod :: proc(r: ^Renderer, cmd: gpu.Cmd, mb: ^Mesh_Buffers, indices: []u32, ranges: []geom.Index_Range, all: bool, expected := 0) {
	ranges, all := ranges, all
	if mb.lod_indices == 0 || u32(len(indices)) > mb.lod_capacity {
		if mb.lod_indices != 0 do gpu.release_buffer(mb.lod_indices)
		capacity := max(u32(len(indices)) + u32(len(indices)) / 2, u32(expected), 1024)
		mb.lod_indices = gpu.create_buffer({usage = {.Index}, size = capacity * size_of(u32)})
		mb.lod_capacity = capacity if mb.lod_indices != 0 else 0
		if mb.lod_indices == 0 {
			log.errorf("LOD index buffer creation failed: %s", gpu.last_error())
			return
		}
		all = true
	}
	whole := [1]geom.Index_Range{{0, u32(len(indices))}}
	if all do ranges = whole[:]
	if !upload_index_ranges(r, cmd, mb, mb.lod_indices, indices, ranges) {
		log.errorf("LOD upload failed: %s", gpu.last_error())
		gpu.release_buffer(mb.lod_indices)
		mb.lod_indices, mb.lod_capacity = 0, 0
	}
}

// Records copies of the `ranges` of `indices`, the mesh's own triangles, into its index
// buffer: for a mesh whose triangles change (the sculptor's dynamic topology).
mesh_buffers_upload_indices :: proc(r: ^Renderer, cmd: gpu.Cmd, mb: ^Mesh_Buffers, indices: []u32, ranges: []geom.Index_Range) {
	if len(ranges) == 0 do return
	r.last_version += 1
	mb.version = r.last_version
	mb.index_version = mb.version
	for x in ranges do assert(x.first_index + x.index_count <= mb.index_count)
	if !upload_index_ranges(r, cmd, mb, mb.indices, indices, ranges) do log.errorf("index upload failed: %s", gpu.last_error())
}

// Records copies of `indices`, which hold the `ranges` one after another, into those
// ranges of the mesh's index buffer: for index data that is not the mesh's own, such as
// a sculptor's triangles with the hidden ones made degenerate.
mesh_buffers_upload_packed_indices :: proc(r: ^Renderer, cmd: gpu.Cmd, mb: ^Mesh_Buffers, indices: []u32, ranges: []geom.Index_Range) {
	if len(ranges) == 0 do return
	r.last_version += 1
	mb.version = r.last_version
	for x in ranges do assert(x.first_index + x.index_count <= mb.index_count)
	if !upload_index_ranges(r, cmd, mb, mb.indices, indices, ranges, packed = true) do log.errorf("index upload failed: %s", gpu.last_error())
}

// Records copies of index ranges into `buffer` through the GPU layer's upload memory. The
// data of each range is at the same place in `indices`, or with `packed`, `indices` holds
// the ranges one after another.
@(private)
upload_index_ranges :: proc(r: ^Renderer, cmd: gpu.Cmd, mb: ^Mesh_Buffers, buffer: gpu.Buffer, indices: []u32, ranges: []geom.Index_Range, packed := false) -> bool {
	read: u32 // with `packed`: where in `indices` the next range starts
	for x in ranges {
		if x.index_count == 0 do continue
		src := read if packed else x.first_index
		read += x.index_count
		if !gpu.upload(cmd, buffer, x.first_index * size_of(u32), slice.to_bytes(indices[src:][:x.index_count])) do return false
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
render_viewport :: proc(r: ^Renderer, cmd: gpu.Cmd, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, use_cache: bool) -> (stats: Viewport_Stats) {
	debug_group(cmd, "Viewport", .Viewport)
	key := ref_planes_key(r.ref_planes, frame_key(vt^, view, proj, items, r.lod_px, r.floor, r.background, environment_keyed(r), r.wire_color))
	defer {
		vt.frame_key = key
		for item in items do item.mesh.drawn_version = item.mesh.version
	}
	// With multisampling a rectangle's edge may keep samples of the frame before (see
	// render_rect), which a see-through item blended again would show as a seam.
	pipes := mesh_pipelines(r, vt.samples)
	see := false
	for item in items do see ||= blended(pipes, item)
	if r.partial && !vt.tile && key == vt.frame_key && !(see && vt.samples != ._1) {
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
	vt.epoch += 1
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
render_rect :: proc(r: ^Renderer, cmd: gpu.Cmd, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, rect: Rect, stats: ^Viewport_Stats) {
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
	prepare_draws(r, cmd, view, proj, items, nil, stats, rect_narrow(drawn, vt.width, vt.height), height = vt.height)
	pipes := mesh_pipelines(r, vt.samples)
	pass := target_pass(r, cmd, vt, load = true)
	gpu.set_scissor(pass, {rect.x, rect.y, rect.w, rect.h})
	draw_background(r, cmd, pass, pipes, vt^, proj, flat_too = true)
	if drawn != rect do gpu.set_scissor(pass, {drawn.x, drawn.y, drawn.w, drawn.h})
	draw_scene(r, cmd, pass, pipes, view, proj, items, nil, stats, rect if drawn != rect else nil)
	gpu.end_render_pass(pass)
	stats.redrawn_px = u64(rect.w) * u64(rect.h)
	stats.redrawn = {rect.x, rect.y, rect.w, rect.h}
}

// Hash of what frame_key in Viewport_Target describes.
@(private)
frame_key :: proc(vt: Viewport_Target, view, proj: Mat4, items: []Draw_Item, lod_px: f32, floor: Floor_Grid, background: Background, environment: Environment_Keyed, wire_color: [4]f32 = {}) -> u64 {
	Keyed :: struct {
		// Pointers by address widened to 64 bits, so the struct has one layout and no
		// padding where pointers are 32-bit (the web build).
		mesh:     u64,
		matcap:   u64,
		model:    Mat4,
		color:    [4]f32,
		material: [4]f32,
		checker:  [4]f32,
		look:     [4]f32,
		style:    [4]f32,
		pass:     [4]f32,
		fade:     [4]f32,
		lights:   Lights,
		surface:  [2]f32,
		wire:     b32,
		flat:     b32,
		paint:    b32,
		groups:   b32,
		slotted:  b32, // with Material_Slots, hashed after it
		lines:    b32, // Draw_Item.cage_lines; the field also keeps the struct free of padding
	}
	#assert(size_of(Keyed) == 1040)
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
	// A wireframe colour set by the theme redraws what it lines; none leaves the key as it was.
	if wire_color != {} {
		wire := wire_color
		h = hash.fnv64a(slice.bytes_from_ptr(&wire, size_of(wire)), h)
	}
	for item in items {
		k := Keyed{u64(uintptr(item.mesh)), u64(uintptr(item.matcap)), item.model, item.color, item.material, item.checker, item.look, item.style, item.pass, item.fade, item.lights, item.surface, b32(item.wireframe), b32(item.flat), b32(item.paint), b32(item.groups), item.slots != nil, b32(item.cage_lines)}
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
		mesh:       u64, // the address, widened as frame_key's
		maps_stamp: u64,
		stamp:      u64,
		view:       u64,
	}
	k := Keyed{u64(uintptr(item.textured)), item.textured.maps_stamp, item.textured.stamp, u64(item.texture_view)}
	return hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k)), h)
}

// Redraws the whole viewport: the live items over the idle ones, which come from the
// cache when `use_cache` and they, the camera and the size are unchanged.
@(private)
render_full :: proc(r: ^Renderer, cmd: gpu.Cmd, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, use_cache: bool, stats: ^Viewport_Stats) {
	// Pixels a mesh unit covers one unit in front of the eye (perspective only).
	lod := lod_view(r, vt.height, proj)
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
	if !use_cache || vt.tile || see > 0 || live == 0 || live == len(items) || !static_cache_ensure(r, vt) {
		vt.cache.key = 0
		prepare_draws(r, cmd, view, proj, items, nil, stats, lod = lod, height = vt.height)
		pass := target_pass(r, cmd, vt, load = false)
		draw_background(r, cmd, pass, pipes, vt^, proj)
		draw_scene(r, cmd, pass, pipes, view, proj, items, nil, stats)
		gpu.end_render_pass(pass)
		return
	}
	stats.cache_used = true

	key := static_key(vt^, view, proj, items, r.lod_px, r.background, environment_keyed(r), r.wire_color)
	redraw := key != vt.cache.key
	prepare_draws(r, cmd, view, proj, items, nil if redraw else true, stats, lod = lod, height = vt.height)
	if redraw {
		pass := begin_mesh_pass(r, cmd, pipes, vt.cache.color, vt.cache.depth, load = false, keep_depth = true, background = r.background.top)
		draw_background(r, cmd, pass, pipes, vt^, proj)
		draw_items(r, cmd, pass, pipes, view, proj, items, false, stats)
		gpu.end_render_pass(pass)
		vt.cache.key = key
		stats.cache_redrawn = true
	}

	copy_pass := gpu.begin_copy_pass(cmd)
	// Multisampled textures copy as they are, sample for sample (Vulkan copies images of
	// equal sample counts).
	for pair in ([2][2]gpu.Texture{{vt.cache.color, target_color(vt)}, {vt.cache.depth, vt.depth}}) {
		gpu.copy_texture_to_texture(copy_pass, {texture = pair[0]}, {texture = pair[1]}, vt.width, vt.height, 1, cycle = true)
	}
	gpu.end_copy_pass(copy_pass)

	// The grid only here, after the live items, and never into the cache: a live item drawn
	// over the cache's depth, which has no grid, would cover grid in front of it.
	pass := target_pass(r, cmd, vt, load = true)
	draw_scene(r, cmd, pass, pipes, view, proj, items, true, stats)
	gpu.end_render_pass(pass)
}

// How much a full redraw may simplify: Renderer.lod_px, and how many pixels a mesh
// unit covers one unit in front of the eye. All zero for full detail.
@(private)
Lod_View :: struct {
	max_px, px_per_unit: f32,
}

// The Lod_View a full redraw of a target `height` pixels tall through `proj` uses:
// Renderer.lod_px under perspective, nothing otherwise.
@(private)
lod_view :: proc(r: ^Renderer, height: u32, proj: Mat4) -> Lod_View {
	return Lod_View{r.lod_px, proj[1, 1] * f32(height) / 2} if r.lod_px > 0 && proj[3, 3] == 0 else {}
}

// For every item that will be drawn this frame (those whose `live` matches, all of
// them when `live` is nil) and can be culled, culls its chunks against the camera and
// uploads one indirect draw command per visible run. With `lod`, groups of chunks
// that may be simplified get one command per run of their copies, after the others.
// Must run before the render passes, since uploads need a copy pass.
// `narrow` maps clip space to a smaller frustum to cull against (see render_rect).
// With the target's `height`, a skinned item's chunks near enough for its skin to change
// its outline by half a pixel are drawn as the skin's grid (skin_tess_split).
@(private)
prepare_draws :: proc(r: ^Renderer, cmd: gpu.Cmd, view, proj: Mat4, items: []Draw_Item, live: Maybe(bool), stats: ^Viewport_Stats, narrow := IDENTITY, lod := Lod_View{}, height: u32 = 0) {
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
	gpu_culled := false
	for item in items {
		if want, filtered := live.?; filtered && item.live != want do continue
		if !r.cull && item.hidden == nil do continue
		if item.copy > 0 {
			copy_prepare(r, cmd, item, narrow * proj * view * item.model, linalg.inverse(item.model) * eye_world, lod, stats)
			continue
		}
		mb := item.mesh
		mb.lod_draw_count = 0
		mb.tess_draw_count = 0
		mb.cull.culled = false
		// A skinned mesh's simplified copies would lose its triangles' numbers.
		simplify := r.cull && lod.max_px > 0 && len(item.lod.groups) > 0 && mb.lod_indices != 0 && mb.skin_normals == 0
		eye := linalg.inverse(item.model) * eye_world
		clip := narrow * proj * view * item.model
		tess := r.cull && height > 0 && item.clip == {} && skin_tess_near(r, item, proj, height, eye.xyz)
		// The GPU writes the commands itself, after the commands staged for the meshes
		// before it. Chunks drawn as a skin's grid are picked on the CPU.
		if r.cull && !tess && len(item.chunks) > 0 && gpu_cull_wanted(r, item, simplify) {
			if gpu_cull_item(r, cmd, item, clip, eye.xyz) {
				mb.draw_count = u32(len(item.chunks))
				stats.chunks += u64(len(item.chunks))
				gpu_culled = true
				continue
			}
		}
		commands := len(item.chunks) * (2 if tess else 1) + (len(item.lod.groups) if simplify else 0)
		if len(item.chunks) == 0 || !indirect_ensure(r, mb, u32(commands)) do continue
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
				cs = geom.cull_chunks_grouped_parallel(r.pool, item.chunks, item.chunk_groups, clip, eye.xyz, &mb.visible, item.hidden)
			} else {
				cs = geom.cull_chunks(item.chunks, clip, eye.xyz, &mb.visible, hidden = item.hidden)
			}
			stats.chunks += u64(cs.chunks)
			stats.culled_view += u64(cs.frustum)
			stats.culled_back += u64(cs.backface)
		}
		if tess do skin_tess_split(r, item, proj, height, eye.xyz)
		mb.draw_count = u32(len(mb.visible))
		mb.lod_draw_count = u32(len(mb.lod_visible))
		mb.tess_draw_count = u32(len(mb.tess_visible)) if tess else 0
		if mb.draw_count + mb.lod_draw_count + mb.tess_draw_count == 0 do continue
		size := (mb.draw_count + mb.lod_draw_count + mb.tess_draw_count) * size_of(gpu.Indexed_Indirect_Draw)
		staged := gpu.stage_buffer(cmd, mb.indirect, 0, size)
		if staged == nil {
			log.errorf("indirect draws: upload memory was refused (%s); the mesh is left out of this frame", gpu.last_error())
			mb.draw_count, mb.lod_draw_count, mb.tess_draw_count = 0, 0, 0
			continue
		}
		dst := cast([^]gpu.Indexed_Indirect_Draw)raw_data(staged)
		// Where the wireframe can be drawn in the shading pass, each command's first instance
		// is its first triangle's number, which the shader adds the primitive id to; a
		// simplified copy's triangles have no polygons behind them (WIRE_ALL_EDGES).
		numbered := r.caps.barycentric
		for v, i in mb.visible {
			dst[i] = {num_indices = v.index_count, num_instances = 1, first_index = v.first_index, first_instance = v.first_index / 3 if numbered else 0}
		}
		for v, i in mb.lod_visible {
			dst[int(mb.draw_count) + i] = {num_indices = v.index_count, num_instances = 1, first_index = v.first_index, first_instance = WIRE_ALL_EDGES if numbered else 0}
		}
		// The grid's commands, read as non-indexed ones: vertices, not indices.
		for v, i in mb.tess_visible[:mb.tess_draw_count] {
			dst[int(mb.draw_count + mb.lod_draw_count) + i] = {num_indices = v.index_count, num_instances = 1, first_index = v.first_index}
		}
	}
	// This pass's numbers from the GPU, as the same pass of a few frames back found them.
	if gpu_culled {
		g := &r.gpu_culling
		if g.call < CULL_CALLS {
			late := g.late[g.call]
			stats.draws += late[0]
			stats.triangles += late[1]
			stats.culled_view += late[2]
			stats.culled_back += late[3]
		}
		g.call += 1
	}
}

// prepare_draws for a copy (Draw_Item.copy): its chunks culled on the CPU under its own
// `clip` and `eye`, into its own commands, which draw_item_triangles draws.
@(private)
copy_prepare :: proc(r: ^Renderer, cmd: gpu.Cmd, item: Draw_Item, clip: Mat4, eye: [4]f32, lod: Lod_View, stats: ^Viewport_Stats) {
	mb := item.mesh
	for len(mb.copy_draws) < int(item.copy) do append(&mb.copy_draws, Copy_Draws{})
	cd := &mb.copy_draws[item.copy - 1]
	cd.draw_count, cd.lod_draw_count = 0, 0
	if len(item.chunks) == 0 do return
	simplify := r.cull && lod.max_px > 0 && len(item.lod.groups) > 0 && mb.lod_indices != 0
	commands := u32(len(item.chunks) + (len(item.lod.groups) if simplify else 0))
	if cd.indirect == 0 || cd.capacity < commands {
		if cd.indirect != 0 do gpu.release_buffer(cd.indirect)
		cd.indirect = gpu.create_buffer({usage = {.Indirect}, size = commands * size_of(gpu.Indexed_Indirect_Draw)})
		cd.capacity = commands if cd.indirect != 0 else 0
		if cd.indirect == 0 {
			log.errorf("copy draws: indirect buffer creation failed: %s", gpu.last_error())
			return
		}
	}
	clear(&cd.visible)
	clear(&cd.lod_visible)
	switch {
	case !r.cull:
		geom.chunks_shown(item.chunks, item.hidden, &cd.visible)
	case simplify:
		ls := geom.cull_lod(item.chunks, item.lod, clip, eye.xyz, lod.px_per_unit, lod.max_px, &cd.visible, &cd.lod_visible, item.hidden)
		stats.chunks += u64(ls.units)
		stats.culled_view += u64(ls.frustum)
		stats.culled_back += u64(ls.backface)
		stats.simplified += u64(ls.groups)
	case:
		cs: geom.Cull_Stats
		if len(item.chunk_groups) > 0 {
			cs = geom.cull_chunks_grouped_parallel(r.pool, item.chunks, item.chunk_groups, clip, eye.xyz, &cd.visible, item.hidden)
		} else {
			cs = geom.cull_chunks(item.chunks, clip, eye.xyz, &cd.visible, hidden = item.hidden)
		}
		stats.chunks += u64(cs.chunks)
		stats.culled_view += u64(cs.frustum)
		stats.culled_back += u64(cs.backface)
	}
	cd.draw_count, cd.lod_draw_count = u32(len(cd.visible)), u32(len(cd.lod_visible))
	total := cd.draw_count + cd.lod_draw_count
	if total == 0 do return
	staged := gpu.stage_buffer(cmd, cd.indirect, 0, total * size_of(gpu.Indexed_Indirect_Draw))
	if staged == nil {
		log.errorf("copy draws: upload memory was refused (%s); the copy is left out of this frame", gpu.last_error())
		cd.draw_count, cd.lod_draw_count = 0, 0
		return
	}
	dst := cast([^]gpu.Indexed_Indirect_Draw)raw_data(staged)
	numbered := r.caps.barycentric
	for v, i in cd.visible {
		dst[i] = {num_indices = v.index_count, num_instances = 1, first_index = v.first_index, first_instance = v.first_index / 3 if numbered else 0}
	}
	for v, i in cd.lod_visible {
		dst[int(cd.draw_count) + i] = {num_indices = v.index_count, num_instances = 1, first_index = v.first_index, first_instance = WIRE_ALL_EDGES if numbered else 0}
	}
}

// Creates the mesh's indirect command buffer for up to `commands` draws. On failure
// the mesh is drawn whole.
@(private)
indirect_ensure :: proc(r: ^Renderer, mb: ^Mesh_Buffers, commands: u32) -> bool {
	if mb.indirect != 0 && mb.indirect_capacity >= commands do return true
	if mb.indirect != 0 do gpu.release_buffer(mb.indirect)
	size := commands * size_of(gpu.Indexed_Indirect_Draw)
	// Kernels write the commands where the GPU culls.
	usage: gpu.Buffer_Usages = {.Indirect, .Storage_Write} if r.caps.gpu_cull else {.Indirect}
	mb.indirect = gpu.create_buffer({usage = usage, size = size})
	mb.indirect_capacity = commands
	if mb.indirect == 0 {
		log.errorf("indirect buffer creation failed: %s", gpu.last_error())
		mb.indirect_capacity = 0
		return false
	}
	return true
}

// Identifies the cache contents: the target size, camera, simplification, and every
// idle item's buffers (by identity and version), transform and colour.
@(private)
static_key :: proc(vt: Viewport_Target, view, proj: Mat4, items: []Draw_Item, lod_px: f32, background: Background, environment: Environment_Keyed, wire_color: [4]f32 = {}) -> u64 {
	Keyed :: struct {
		// Pointers by address widened to 64 bits, so the struct has one layout and no
		// padding where pointers are 32-bit (the web build).
		mesh:     u64,
		matcap:   u64,
		version:  u64,
		model:    Mat4,
		color:    [4]f32,
		material: [4]f32,
		checker:  [4]f32,
		look:     [4]f32,
		style:    [4]f32,
		pass:     [4]f32,
		fade:     [4]f32,
		lights:   Lights,
		surface:  [2]f32,
		wire:     b32,
		flat:     b32,
		paint:    b32,
		groups:   b32,
		slotted:  b32, // with Material_Slots, hashed after it
		lines:    b32, // Draw_Item.cage_lines; the field also keeps the struct free of padding
	}
	#assert(size_of(Keyed) == 1048)
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
	// A wireframe colour set by the theme redraws what it lines; none leaves the key as it was.
	if wire_color != {} {
		wire := wire_color
		h = hash.fnv64a(slice.bytes_from_ptr(&wire, size_of(wire)), h)
	}
	for item in items {
		if item.live do continue
		k := Keyed{u64(uintptr(item.mesh)), u64(uintptr(item.matcap)), item.mesh.version, item.model, item.color, item.material, item.checker, item.look, item.style, item.pass, item.fade, item.lights, item.surface, b32(item.wireframe), b32(item.flat), b32(item.paint), b32(item.groups), item.slots != nil, b32(item.cage_lines)}
		h = hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k)), h)
		if item.slots != nil do h = hash.fnv64a(slice.bytes_from_ptr(item.slots, size_of(Material_Slots)), h)
		h = textured_key(item, h)
	}
	return max(h, 1) // 0 means empty
}

// The colour texture passes draw the viewport into: the multisampled one, or `color`.
@(private)
target_color :: proc(vt: ^Viewport_Target) -> gpu.Texture {
	return vt.multi_color if vt.multi_color != 0 else vt.color
}

// Opens a pass drawing into the viewport, keeping its depth; with multisampling it keeps
// the samples too, for the next partial redraw to load, and resolves them into `color`.
// A `tile` target keeps neither: only the resolve leaves the pass.
@(private)
target_pass :: proc(r: ^Renderer, cmd: gpu.Cmd, vt: ^Viewport_Target, load: bool) -> gpu.Render_Pass {
	assert(!(vt.tile && load), "a tile target's samples cannot be loaded")
	return begin_mesh_pass(r, cmd, mesh_pipelines(r, vt.samples), target_color(vt), vt.depth, load, keep_depth = !vt.tile, background = r.background.top, resolve = vt.color if vt.multi_color != 0 else 0, resolve_only = vt.tile)
}

// The bytes of memory the target's textures take, leaving out the transient ones a tile
// GPU never gives memory (for the exit stats; the cache is counted when it exists).
viewport_target_bytes :: proc(vt: Viewport_Target) -> u64 {
	px := u64(vt.width) * u64(vt.height)
	samples := u64(1) << u32(vt.samples)
	depth := u64(4)
	total := px * 4
	if vt.multi_color != 0 && !vt.tile do total += px * 4 * samples
	if !vt.tile && !vt.transient_depth do total += px * depth * samples
	if vt.cache.color != 0 do total += px * 4 * samples
	if vt.cache.depth != 0 do total += px * depth * samples
	return total
}

// Paints Renderer.background over the pass (its scissor, if set) at the far plane, or the
// environment seen through `proj` when the background shows it. A flat one is the colour
// the pass was cleared to, so it is drawn only with `flat_too`, where part of an earlier
// frame is being cleared.
@(private)
draw_background :: proc(r: ^Renderer, cmd: gpu.Cmd, pass: gpu.Render_Pass, pipes: ^Mesh_Pipelines, vt: Viewport_Target, proj: Mat4, flat_too := false) {
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
	gpu.bind_graphics_pipeline(pass, pipes.clear)
	samplers := [Clear_Frag_Samplers]gpu.Texture_Sampler_Binding{.environment_map = environment_binding(r)}
	bind_fragment_samplers(pass, &samplers)
	push_fragment(cmd, Clear_Frag_Uniforms.Clear_Uniforms, &uniforms)
	gpu.draw_primitives(pass, 3, 1, 0, 0)
}

// Opens a pass into `color_tex` and `depth_tex`, cleared to `background` or loaded, with
// `pipes.mesh` bound. With `resolve`, `color_tex` is multisampled and the pass ends by
// resolving it into `resolve`, keeping its samples.
@(private)
begin_mesh_pass :: proc(r: ^Renderer, cmd: gpu.Cmd, pipes: ^Mesh_Pipelines, color_tex, depth_tex: gpu.Texture, load, keep_depth: bool, background := BACKGROUND, resolve: gpu.Texture = 0, resolve_only := false) -> gpu.Render_Pass {
	store: gpu.Store_Op = .Store
	if resolve != 0 do store = .Resolve if resolve_only else .Resolve_And_Store
	color := gpu.Color_Target {
		texture     = color_tex,
		clear_color = background,
		load_op     = .Load if load else .Clear,
		store_op    = store,
		cycle       = !load,
		// The resolve writes all of it, so a frame still showing the last one need not wait.
		resolve_texture = resolve,
		cycle_resolve_texture = resolve != 0,
	}
	depth := gpu.Depth_Target {
		texture          = depth_tex,
		clear_depth      = 1,
		load_op          = .Load if load else .Clear,
		store_op         = .Store if keep_depth else .Dont_Care,
		stencil_load_op  = .Dont_Care,
		stencil_store_op = .Dont_Care,
		cycle            = !load,
	}
	pass := gpu.begin_render_pass(cmd, &color, 1, &depth)
	gpu.bind_graphics_pipeline(pass, pipes.mesh)
	return pass
}

// Draws the items whose `live` flag matches (all of them when `live` is nil) with the
// clay material: the visible runs prepare_draws found, or the whole mesh.
@(private)
draw_items :: proc(r: ^Renderer, cmd: gpu.Cmd, pass: gpu.Render_Pass, pipes: ^Mesh_Pipelines, view, proj: Mat4, items: []Draw_Item, live: Maybe(bool), stats: ^Viewport_Stats, see := false) {
	bound: gpu.Graphics_Pipeline
	for item in items {
		if want, filtered := live.?; filtered && item.live != want do continue
		if blended(pipes, item) != see do continue
		reflected := model_reflected(item.model)
		textured := draws_textured(pipes, item) && !(item.copy > 0 && reflected)
		skinned := !textured && !see && item.copy == 0 && draws_skinned(pipes, item)
		main := pipes.see if see else pipes.mesh
		if textured do main = pipes.textured_see if see else pipes.textured
		if lights_have_area(item.lights) {
			area_pipelines(r, pipes)
			which := Area_Pipeline.See if see else .Mesh
			if textured do which = .Textured_See if see else .Textured
			if pipes.area[which] != 0 do main = pipes.area[which]
		}
		// The skin's own shader has no area lights' code: a skinned item leaves them out.
		if skinned do main = pipes.skinned
		// A plain opaque item's wireframe is drawn in its own shading where the device
		// can (wire_pipeline): no second pass of its triangles. So are the polygon edges a
		// polygon level's wireframe draws (Mesh_Buffers.tri_edges), leaving out the
		// diagonals. The rest draw them as lines.
		wire_lines := item.wireframe
		poly_shaded := false
		if (item.wireframe || item.cage_lines && item.mesh.tri_edges != 0) && main == pipes.mesh {
			if wired := wire_pipeline(r, pipes); wired != 0 {
				main = wired
				wire_lines = false
				poly_shaded = !item.wireframe
			}
		}
		// A clipped item (the live stack's mirror) draws with the clipped variant of its
		// pipeline, its wireframe as lines and no area light.
		clipped := item.clip != {}
		if clipped {
			clip_pipelines(r, pipes)
			which: Maybe(Clip_Pipeline)
			switch {
			case skinned: which = .Skinned
			case textured: which = .Textured_See if see else .Textured
			case see: which = .See
			case: which = .Mesh
			}
			if c := pipes.clip[which.?]; c != 0 {
				main = c
				wire_lines = item.wireframe
				poly_shaded = false
			} else {
				clipped = false
			}
		}
		if stats != nil && (item.wireframe || poly_shaded) {
			if wire_lines do stats.wire_lines += 1
			else do stats.wire_shaded += 1
		}
		if main != bound {
			gpu.bind_graphics_pipeline(pass, main)
			bound = main
		}
		gpu.set_front_face(pass, reflected)
		mb := item.mesh
		show_paint, show_groups := item.paint && mb.paint != 0, item.groups && mb.paint != 0
		slotted := item.slots != nil && mb.paint != 0 && !textured
		frame := Frame_Uniforms{view_proj = proj * view, view = view, model = item.model, options = {f32(int(show_paint)), f32(int(show_groups)), f32(int(slotted)), f32(int(show_paint && mb.paint_material != 0))}}
		frame.slot_group = SLOT_NONE
		if slotted {
			frame.slot_group = item.slots.groups
			push_fragment(cmd, Mesh_Frag_Uniforms.Slot_Uniforms, &item.slots.uniforms)
		}
		params := item.material if item.material != {} else DEFAULT_MATERIAL
		surface := [4]f32{item.surface.x, item.surface.y, 1 if item.flat else 0, 1 if item.matcap != 0 else 0}
		lights := item.lights if item.lights != {} else lights_default()
		material := Material_Uniforms{base_color = item.color, params = params, surface = surface, checker = item.checker, look = item.look, lights = lights, style = item.style, pass = item.pass, fade = item.fade, wire = wire_color(r)}
		if poly_shaded do material.wire.w = 1
		if clipped do material.clip = {item.clip.x, item.clip.y, item.clip.z, 0}
		material_environment(r, &material)
		// Parallel projection: the shading takes the view's axis as the way to the eye
		// (mesh_shading.slang's env.w).
		if proj[3, 3] == 1 do material.env.w = 1
		// Drawn solid after all where the blended pipeline is missing, and opaque then.
		if !see do material.look.w = 0
		if textured {
			frame.options = {}
			draw_textured_item(r, cmd, pass, item, &frame, &material, stats)
			if item.wireframe && pipes.wire != 0 {
				// The wire pass draws the sculpt buffers, which hold the same surface.
				push_vertex(cmd, Mesh_Vert_Uniforms.Frame_Uniforms, &frame)
				paint := [Mesh_Vert_Buffers]gpu.Buffer{.paint = r.no_paint, .paint_material_words = r.no_paint}
				bind_vertex_storage(pass, &paint)
				samplers := [Mesh_Frag_Samplers]gpu.Texture_Sampler_Binding{.matcap = {texture = r.no_matcap, sampler = r.matcap_sampler}, .environment_map = environment_binding(r)}
				bind_fragment_samplers(pass, &samplers)
				vbufs := [2]gpu.Buffer_Binding{{buffer = mb.positions}, {buffer = mb.normals}}
				gpu.bind_vertex_buffers(pass, 0, &vbufs[0], len(vbufs))
				wire_pass(r, cmd, pass, pipes, item)
				bound = pipes.wire
			}
			if lines_pass(r, cmd, pass, pipes, item, frame, view, proj) do bound = pipes.lines
			continue
		}
		if skinned do frame.skin = {mb.skin_meta[0], mb.skin_meta[1], mb.skin_meta[2], 0}
		push_vertex(cmd, Mesh_Vert_Uniforms.Frame_Uniforms, &frame)
		push_fragment(cmd, Mesh_Frag_Uniforms.Material_Uniforms, &material)
		paint := [Mesh_Vert_Buffers]gpu.Buffer{.paint = mb.paint if mb.paint != 0 else r.no_paint, .paint_material_words = mb.paint_material if show_paint && mb.paint_material != 0 else r.no_paint}
		bind_vertex_storage(pass, &paint)
		samplers := [Mesh_Frag_Samplers]gpu.Texture_Sampler_Binding{.matcap = {texture = item.matcap if item.matcap != 0 else r.no_matcap, sampler = r.matcap_sampler}, .environment_map = environment_binding(r)}
		bind_fragment_samplers(pass, &samplers)
		if main == pipes.mesh_wire {
			edges := [Mesh_Wire_Frag_Buffers]gpu.Buffer{.tri_edges = mb.tri_edges if poly_shaded else r.no_paint}
			bind_fragment_storage(pass, &edges)
		}
		vbufs := [2]gpu.Buffer_Binding{{buffer = mb.positions}, {buffer = mb.normals}}
		if skinned {
			if draw_skinned_item(r, pass, pipes, item, stats) do bound = pipes.skin_tess
		} else {
			gpu.bind_vertex_buffers(pass, 0, &vbufs[0], len(vbufs))
			draw_item_triangles(r, pass, item, stats)
		}
		// The wireframe and the cage lines draw from the vertex buffers.
		if skinned && (wire_lines || item.cage_lines) do gpu.bind_vertex_buffers(pass, 0, &vbufs[0], len(vbufs))
		if wire_lines && pipes.wire != 0 {
			wire_pass(r, cmd, pass, pipes, item)
			bound = pipes.wire
		}
		if !poly_shaded && lines_pass(r, cmd, pass, pipes, item, frame, view, proj) do bound = pipes.lines
	}
}

// The item's edge pairs (Mesh_Buffers.edges) as lines in the cage colour, when it asks for
// them and the device made the line pipeline, with the item's vertex buffers bound by the
// caller. Returns whether it drew. The lines are pulled toward the eye so they win over
// the faces they border: in perspective by shrinking the view about the eye, which moves
// nothing on screen; in parallel projection by a step along the view's axis.
@(private)
lines_pass :: proc(r: ^Renderer, cmd: gpu.Cmd, pass: gpu.Render_Pass, pipes: ^Mesh_Pipelines, item: Draw_Item, frame: Frame_Uniforms, view, proj: Mat4) -> bool {
	mb := item.mesh
	if !item.cage_lines || pipes.lines == 0 || mb.edges == 0 || mb.edge_indices == 0 do return false
	nudge := linalg.identity(Mat4)
	if proj[3, 3] == 0 {
		nudge = linalg.matrix4_scale(geom.Vec3{1, 1, 1} * (1 - CAGE_LINE_PULL))
	} else if proj[2, 2] != 0 {
		// A step of CAGE_LINE_PULL / 4 of the depth range's units, toward the eye (+z).
		nudge[2, 3] = CAGE_LINE_PULL / 4 / abs(proj[2, 2])
	}
	f := frame
	f.view_proj = proj * nudge * view
	f.options = {}
	push_vertex(cmd, Mesh_Vert_Uniforms.Frame_Uniforms, &f)
	lines := Material_Uniforms{base_color = CAGE_LINE_COLOR, params = {0, -1, 0, 0}}
	push_fragment(cmd, Mesh_Frag_Uniforms.Material_Uniforms, &lines)
	gpu.bind_graphics_pipeline(pass, pipes.lines)
	gpu.bind_index_buffer(pass, {buffer = mb.edges}, .U32)
	gpu.draw_indexed_primitives(pass, mb.edge_indices, 1, 0, 0, 0)
	return true
}

// How much nearer the eye cage lines are drawn than the surface: a share of the distance in
// perspective, enough to clear the faces either side of an edge at a glancing angle.
CAGE_LINE_PULL :: 0.002
CAGE_LINE_COLOR :: [4]f32{0.02, 0.02, 0.025, 1}

// Gives `mb` the edge pairs `pairs` (vertex indices into its positions, two a line) to
// draw with Draw_Item.cage_lines, replacing any it had; nil or empty removes them; and,
// for polygon edges, the same edges per triangle as Mesh_Buffers.tri_edges holds them
// (tri_edge_flags), which let the wireframe be drawn in the shading pass where the device
// can. The copies are submitted at once. Returns false, with no edges, on a GPU failure.
mesh_buffers_set_edges :: proc(r: ^Renderer, mb: ^Mesh_Buffers, pairs: []u32, tri_edges: []u32 = nil) -> bool {
	if mb.edges != 0 || mb.tri_edges != 0 {
		if mb.edges != 0 do gpu.release_buffer(mb.edges)
		if mb.tri_edges != 0 do gpu.release_buffer(mb.tri_edges)
		mb.edges, mb.edge_indices, mb.tri_edges = 0, 0, 0
	}
	r.last_version += 1
	mb.version = r.last_version
	if len(pairs) == 0 do return true
	if len(tri_edges) > 0 {
		assert(len(tri_edges) == (int(mb.index_count / 3) + 7) / 8, "the triangles' edge bits do not match the buffers' triangles")
		mb.tri_edges = gpu.create_buffer({usage = {.Graphics_Storage_Read}, size = u32(len(tri_edges) * size_of(u32))})
		if mb.tri_edges == 0 || !upload_now(r, mb.tri_edges, slice.to_bytes(tri_edges)) {
			// The edges still draw as lines.
			log.warnf("polygon edge bits upload failed: %s", gpu.last_error())
			if mb.tri_edges != 0 do gpu.release_buffer(mb.tri_edges)
			mb.tri_edges = 0
		}
	}
	for v in pairs do assert(v < mb.vertex_capacity, "an edge names a vertex the buffers do not hold")
	mb.edges = gpu.create_buffer({usage = {.Index}, size = u32(len(pairs) * size_of(u32))})
	if mb.edges == 0 || !upload_now(r, mb.edges, slice.to_bytes(pairs)) {
		log.errorf("cage edge upload failed: %s", gpu.last_error())
		if mb.edges != 0 do gpu.release_buffer(mb.edges)
		mb.edges = 0
		return false
	}
	mb.edge_indices = u32(len(pairs))
	return true
}

// The item's triangles again as lines in one flat colour (a negative specular strength
// tells the shader so), with the sculpt buffers bound by the caller.
@(private)
wire_pass :: proc(r: ^Renderer, cmd: gpu.Cmd, pass: gpu.Render_Pass, pipes: ^Mesh_Pipelines, item: Draw_Item) {
	wire := Material_Uniforms{base_color = wire_color(r), params = {0, -1, 0, 0}}
	push_fragment(cmd, Mesh_Frag_Uniforms.Material_Uniforms, &wire)
	gpu.bind_graphics_pipeline(pass, pipes.wire)
	draw_item_triangles(r, pass, item, nil)
}

// Whether `item` is drawn see-through, blended over what is behind it: it asks to be
// (Draw_Item.look.w) and the device made the blended pipeline.
@(private)
blended :: proc(pipes: ^Mesh_Pipelines, item: Draw_Item) -> bool {
	if draws_textured(pipes, item) do return item.look.w > 0 && pipes.textured_see != 0
	return item.look.w > 0 && pipes.see != 0
}

// Draws the viewport's items whose `live` matches in the order blending needs: the opaque
// ones, then the reference planes behind the model and the floor grid, then the
// see-through ones over them, then the reference planes drawn through the model. In render_rect the opaque
// ones are drawn a pixel past the rectangle (see there); everything blended stays inside
// `inside`, as drawing it twice at the edge would blend it twice.
@(private)
draw_scene :: proc(r: ^Renderer, cmd: gpu.Cmd, pass: gpu.Render_Pass, pipes: ^Mesh_Pipelines, view, proj: Mat4, items: []Draw_Item, live: Maybe(bool), stats: ^Viewport_Stats, inside: Maybe(Rect) = nil) {
	draw_items(r, cmd, pass, pipes, view, proj, items, live, stats)
	if rect, ok := inside.?; ok do gpu.set_scissor(pass, {rect.x, rect.y, rect.w, rect.h})
	draw_ref_planes(r, cmd, pass, pipes, view, proj, through = false)
	draw_floor(r, cmd, pass, pipes, view, proj)
	if pipes.see != 0 || pipes.textured_see != 0 {
		for item in items do if blended(pipes, item) {
			draw_items(r, cmd, pass, pipes, view, proj, items, live, stats, see = true)
			break
		}
	}
	draw_ref_planes(r, cmd, pass, pipes, view, proj, through = true)
}

// Draws Renderer.floor's planes, each as a full-screen triangle whose pixels find where
// their ray meets the plane (floor.frag.slang).
@(private)
draw_floor :: proc(r: ^Renderer, cmd: gpu.Cmd, pass: gpu.Render_Pass, pipes: ^Mesh_Pipelines, view, proj: Mat4) {
	f := r.floor
	if pipes.floor == 0 || f.shown == {} || f.cell <= 0 do return
	view_proj := proj * view
	u := Floor_Uniforms {
		inv_view_proj = linalg.inverse(view_proj),
		view_proj     = view_proj,
		grid          = {f.cell, f.radius, f32(int(f.axes)), 0},
		center        = {f.center.x, f.center.y, f.center.z, 0},
	}
	gpu.bind_graphics_pipeline(pass, pipes.floor)
	for axis in 0 ..< 3 {
		if !f.shown[axis] do continue
		u.plane = {f32(axis), f.at[axis], 0, 0}
		push_fragment(cmd, Floor_Frag_Uniforms.Floor_Uniforms, &u)
		gpu.draw_primitives(pass, 3, 1, 0, 0)
	}
}

DEFAULT_MATERIAL :: [4]f32{0.08, 0.2, 40, 0}
// How many lights the shader takes (Lights): the mesh shader's arrays are this long.
LIGHT_COUNT :: 8

// What kind of light each of Lights' entries is, in its pos.w: a sun shines from a
// direction, a point light from a place in every direction, a spot from a place into a cone,
// an area light from one face of a rectangle or a disc, as a studio's softbox.
LIGHT_SUN :: 0
LIGHT_POINT :: 1
LIGHT_SPOT :: 2
LIGHT_AREA :: 3

// The lights a Draw_Item is shaded with, as Material_Uniforms carries them (light_x, y
// and z, light_pos, light_color, light_spot and light_shape in mesh_shading.slang), in
// view space.
Lights :: struct {
	// The columns of the rotation that takes the studio the physically based materials
	// reflect into view space, with the ambient light's strength in [0].w.
	rig:   [3][4]f32,
	// Toward a sun, unit length, or where a point, spot or area light is (an area's
	// middle), with its kind (LIGHT_SUN, LIGHT_POINT, LIGHT_SPOT, LIGHT_AREA) in w.
	pos:   [LIGHT_COUNT][4]f32,
	// Each light's colour in linear light, with its strength in w: 0 for a light that is
	// off, which the shader skips.
	color: [LIGHT_COUNT][4]f32,
	// A spot's axis, the way it shines, unit length, with the cosine of half its cone in w;
	// an area light's facing, the way its lit face looks, w unused.
	spot:  [LIGHT_COUNT][4]f32,
	// x: the distance at which a point or spot light is as bright as a sun of its strength
	// (it falls off with the square of the distance from there), y: where it fades to
	// nothing (0: never), z: the cosine of half a spot's cone less its blend, where its
	// edge starts to fade; w: how big the light is, the sine of the angle a sun's disc
	// spans from its middle to its edge, or a point or spot light's radius in view units,
	// 0 for a light with no size (which shades exactly as before lights had one); an area
	// light's is the radius of the disc of its area, which render mode and the studio's
	// shadows take it as.
	shape: [LIGHT_COUNT][4]f32,
	// An area light's first edge, unit length, with half its width in w (the second edge
	// is the facing crossed with it); zero for the other kinds.
	axis:  [LIGHT_COUNT][4]f32,
	// x: how much more or less highlight the light gives than usual, -1 none (a fill that
	// adds no shine) to 1 twice as much, 0 as usual; y: 1 for a light that casts no
	// shadow in the studio and render mode; z: an area light's half height; w: 1 for an
	// area light that is a disc of radius axis.w. All zero is a light as lights were
	// before these, so a Lights made without them shades as it always did.
	extra: [LIGHT_COUNT][4]f32,
}
#assert(size_of(Lights) == 816)

// The key and fill lights' directions as the lights fixed to the camera have them, toward
// the light in view space (not unit length): the key above and to the left of the
// viewer, the fill low on the right. The fill's strength is the share of the key's the
// classic clay shading has always given it.
KEY_DIR :: [3]f32{-0.5, 0.6, 0.6}
FILL_DIR :: [3]f32{0.7, -0.2, 0.4}
FILL_STRENGTH :: 0.3

// The lights fixed to the camera, unturned: the key at full strength and the fill, both
// white suns, the studio unturned and full ambient light. What a Draw_Item with no lights
// of its own is shaded with (thumbnails, the navigation head).
lights_default :: proc() -> Lights {
	l: Lights
	l.rig = {{1, 0, 0, 1}, {0, 1, 0, 0}, {0, 0, 1, 0}}
	key, fill := linalg.normalize(KEY_DIR), linalg.normalize(FILL_DIR)
	l.pos[0] = {key.x, key.y, key.z, LIGHT_SUN}
	l.pos[1] = {fill.x, fill.y, fill.z, LIGHT_SUN}
	l.color[0] = {1, 1, 1, 1}
	l.color[1] = {1, 1, 1, FILL_STRENGTH}
	return l
}

// The light that casts the studio render's shadow: the brightest one that is on and casts
// shadows (its strength times its strongest colour channel), as the direction toward it in
// view space from `centre` (the scene's middle, in view space), so a point, spot or area
// light shadows from where it stands; false with every light off, black or shadowless,
// when there is no shadow to cast.
lights_key :: proc(lights: Lights, centre: [3]f32) -> (dir: [3]f32, ok: bool) {
	l := lights if lights != {} else lights_default()
	best, at := f32(0), -1
	for c, i in l.color {
		if l.extra[i].y > 0.5 do continue
		if b := c.w * max(c.r, c.g, c.b); b > best do best, at = b, i
	}
	if at < 0 do return {}, false
	p := l.pos[at]
	if p.w == LIGHT_SUN do return linalg.normalize(p.xyz), true
	toward := p.xyz - centre
	if linalg.length(toward) < 1e-6 do return {}, false
	return linalg.normalize(toward), true
}
WIRE_COLOR :: [4]f32{0.05, 0.05, 0.06, 1}

// The first instance of a simplified copy's draws where commands carry their first
// triangle's number: none of its edges is a polygon's diagonal, so the wireframe draws
// them all (mesh_shading.slang's WIRE_ALL_EDGES).
WIRE_ALL_EDGES :: 0xffff_ffff

// The wireframe's colour, linear: the theme's, else WIRE_COLOR.
@(private)
wire_color :: proc(r: ^Renderer) -> [4]f32 {
	return r.wire_color if r.wire_color != {} else WIRE_COLOR
}

// The item's triangles: the visible runs prepare_draws found, or the whole mesh. Counts
// them in `stats` when given.
@(private)
draw_item_triangles :: proc(r: ^Renderer, pass: gpu.Render_Pass, item: Draw_Item, stats: ^Viewport_Stats) {
	mb := item.mesh
	gpu.bind_index_buffer(pass, {buffer = mb.indices}, .U32)
	if item.ranges != nil {
		for run in item.ranges do gpu.draw_indexed_primitives(pass, run.index_count, 1, run.first_index, 0, 0)
		if stats == nil do return
		for run in item.ranges do stats.triangles += u64(run.index_count / 3)
		stats.draws += u64(len(item.ranges))
	} else if item.copy > 0 && (r.cull || item.hidden != nil) && len(item.chunks) > 0 {
		if int(item.copy) > len(mb.copy_draws) do return
		cd := &mb.copy_draws[item.copy - 1]
		if cd.draw_count > 0 do gpu.draw_indexed_primitives_indirect(pass, cd.indirect, 0, cd.draw_count)
		if cd.lod_draw_count > 0 {
			gpu.bind_index_buffer(pass, {buffer = mb.lod_indices}, .U32)
			gpu.draw_indexed_primitives_indirect(pass, cd.indirect, cd.draw_count * size_of(gpu.Indexed_Indirect_Draw), cd.lod_draw_count)
		}
		if stats == nil do return
		for v in cd.visible do stats.triangles += u64(v.index_count / 3)
		for v in cd.lod_visible do stats.triangles += u64(v.index_count / 3)
		stats.draws += u64(cd.draw_count + cd.lod_draw_count)
	} else if mb.cull.culled && r.cull && len(item.chunks) > 0 && mb.indirect != 0 {
		// The kernels wrote the commands and their count; prepare_draws counted the stats.
		gpu.draw_indexed_primitives_indirect_count(pass, mb.indirect, CULL_HEADER, mb.indirect, 0, mb.draw_count)
	} else if (r.cull || item.hidden != nil) && len(item.chunks) > 0 && mb.indirect != 0 {
		if mb.draw_count > 0 do gpu.draw_indexed_primitives_indirect(pass, mb.indirect, 0, mb.draw_count)
		if mb.lod_draw_count > 0 {
			gpu.bind_index_buffer(pass, {buffer = mb.lod_indices}, .U32)
			gpu.draw_indexed_primitives_indirect(pass, mb.indirect, mb.draw_count * size_of(gpu.Indexed_Indirect_Draw), mb.lod_draw_count)
		}
		if stats == nil do return
		for v in mb.visible do stats.triangles += u64(v.index_count / 3)
		for v in mb.lod_visible do stats.triangles += u64(v.index_count / 3)
		stats.draws += u64(mb.draw_count + mb.lod_draw_count)
	} else {
		gpu.draw_indexed_primitives(pass, mb.index_count, 1, 0, 0, 0)
		if stats == nil do return
		stats.triangles += u64(mb.index_count / 3)
		stats.draws += 1
	}
}

// Reads the viewport colour back to the CPU (RGBA8, rows top to bottom), waiting for
// the GPU: `texture` (a viewport-sized RGBA8 one, such as the studio render's) or the
// target's own. For tests and debugging, not per frame. Returns nil on failure.
viewport_download :: proc(r: ^Renderer, vt: ^Viewport_Target, allocator := context.allocator, texture: gpu.Texture = 0) -> []u8 {
	return texture_download(r, texture if texture != 0 else vt.color, vt.width, vt.height, allocator)
}

// A texture read back without waiting for it: the copy is submitted after the frame's
// work and collected once its ticket is done, so the frame loop never stops for it
// (the scene file's preview picture).
Readback :: struct {
	readback:      gpu.Readback,
	width, height: u32,
}

// Starts reading the `width` by `height` RGBA8 `texture` back, dropping a readback still
// under way. False when the device refused, with nothing left to collect.
readback_start :: proc(r: ^Renderer, rb: ^Readback, texture: gpu.Texture, width, height: u32) -> bool {
	readback_cancel(r, rb)
	if texture == 0 || width == 0 || height == 0 do return false
	cmd := gpu.acquire_command_buffer()
	if cmd == nil do return false
	size := width * height * 4
	rb.readback = gpu.reserve_readback(cmd, size)
	if rb.readback == 0 {
		_ = gpu.cancel_command_buffer(cmd)
		return false
	}
	gpu.download_texture(cmd, rb.readback, 0, {texture = texture, w = width, h = height, d = 1}, size)
	if _, ok := gpu.submit(cmd); !ok {
		readback_cancel(r, rb)
		return false
	}
	rb.width, rb.height = width, height
	return true
}

// The pixels once the GPU has copied them (RGBA8, rows top to bottom), with done false
// while it has not; done with nil pixels when there was nothing to collect or mapping failed.
readback_poll :: proc(r: ^Renderer, rb: ^Readback, allocator := context.allocator) -> (pixels: []u8, done: bool) {
	if rb.readback == 0 do return nil, true
	data, ready := gpu.readback(rb.readback)
	if !ready do return nil, false
	if data != nil {
		pixels = make([]u8, len(data), allocator)
		copy(pixels, data)
	}
	readback_cancel(r, rb)
	return pixels, true
}

// Whether a readback was started and not yet collected or dropped.
readback_pending :: proc(rb: ^Readback) -> bool {
	return rb.readback != 0
}

// Drops a readback, collected or not.
readback_cancel :: proc(r: ^Renderer, rb: ^Readback) {
	gpu.release_readback(rb.readback)
	rb^ = {}
}

// Reads a `width` by `height` RGBA8 texture back as rows top to bottom, recorded into
// `cmd` after its work, which is submitted, and waits for the GPU; nil on failure.
texture_download_in :: proc(r: ^Renderer, cmd: gpu.Cmd, texture: gpu.Texture, width, height: u32, allocator := context.allocator) -> []u8 {
	size := width * height * 4
	rb := gpu.reserve_readback(cmd, size)
	defer gpu.release_readback(rb)
	if rb != 0 do gpu.download_texture(cmd, rb, 0, {texture = texture, w = width, h = height, d = 1}, size)
	ticket, ok := gpu.submit(cmd)
	if !ok || rb == 0 || !gpu.wait(ticket) do return nil
	data, _ := gpu.readback(rb)
	if data == nil do return nil
	pixels := make([]u8, size, allocator)
	copy(pixels, data)
	return pixels
}

// Reads a `width` by `height` RGBA8 texture back as rows top to bottom, after waiting
// for the GPU; nil on failure.
texture_download :: proc(r: ^Renderer, texture: gpu.Texture, width, height: u32, allocator := context.allocator) -> []u8 {
	cmd := gpu.acquire_command_buffer()
	if cmd == nil do return nil
	return texture_download_in(r, cmd, texture, width, height, allocator)
}
