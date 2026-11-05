package gpu

// The GPU's own vocabulary: the formats, usages, states and descriptions render hands the
// seam, named for what Sculpt does with them rather than copied from SDL_GPU, and holding
// only what the backends read (no property ids, no padding). Each backend maps them to its
// API's own (vk_format, mtl_pixel_format, wgpu_format and their neighbours).

// The resources render holds: generational handles into the backend's objects (pool.odin),
// 0 for none. A handle kept past its release resolves to nothing rather than to freed
// memory. Render never looks inside one.
Buffer            :: distinct u32
Transfer_Buffer   :: distinct u32
// Memory a recording's downloads land in, read once its submission is done (readback).
Readback          :: distinct u32
Texture           :: distinct u32
Sampler           :: distinct u32
Shader            :: distinct u32
Graphics_Pipeline :: distinct u32
Compute_Pipeline  :: distinct u32
// The objects that live less than a frame are opaque pointers each backend points at its
// own (Vk_Cmd, Mtl_Cmd, ...), nil for none: a recording, valid from its acquire until it
// is submitted or cancelled, and the passes inside one, each valid until it ends.
Cmd               :: distinct ^Opaque
Render_Pass       :: distinct ^Opaque
Compute_Pass      :: distinct ^Opaque
Copy_Pass         :: distinct ^Opaque

// The queue a command buffer goes to, whose timeline its submissions count on: graphics
// (everything) or compute (acquire_compute_command_buffer, where async compute is offered).
Queue :: enum u8 {
	Graphics,
	Compute,
}

// A point on a queue's timeline, which submit hands back: done once the GPU has run every
// submission of that queue up to it (and, under WebGPU, every download those made has
// landed). A plain value: nothing to release, and the zero ticket is already done.
Ticket :: struct {
	value: u64,
	queue: Queue,
}

// What a handle points at, as far as render knows: nothing.
Opaque :: struct {}

// The texture formats Sculpt uses, and nothing else: colour targets and pictures (8-bit,
// sRGB, 10-bit), half and float images for light and data, one integer image for ids, and
// the four depth formats a device may offer.
Format :: enum u8 {
	Invalid,
	R8_Unorm,
	RG8_Unorm,
	RGBA8_Unorm,
	RGBA8_Srgb,
	BGRA8_Unorm,
	BGRA8_Srgb,
	RGB10A2_Unorm,
	RG11B10_Float,
	R16_Float,
	RG16_Float,
	RGBA16_Float,
	R32_Float,
	RG32_Float,
	RGBA32_Float,
	R32_Uint,
	D16_Unorm,
	D24_Unorm,
	D32_Float,
	D24_Unorm_S8,
	D32_Float_S8,
}

// Whether a format is one of the depth formats.
format_is_depth :: proc(f: Format) -> bool {
	#partial switch f {
	case .D16_Unorm, .D24_Unorm, .D32_Float, .D24_Unorm_S8, .D32_Float_S8:
		return true
	}
	return false
}

Texture_Type :: enum u8 {D2, D2_Array, D3, Cube, Cube_Array}

Sample_Count :: enum u8 {_1, _2, _4, _8}

Texture_Usage :: enum u8 {
	Sampled,
	Color_Target,
	Depth_Target,
	Graphics_Storage_Read,
	Storage_Read,
	Storage_Write,
	// Read and written by one compute pass, as one storage image.
	Storage_Read_Write,
}
Texture_Usages :: bit_set[Texture_Usage; u8]

Buffer_Usage :: enum u8 {Vertex, Index, Indirect, Graphics_Storage_Read, Storage_Read, Storage_Write}
Buffer_Usages :: bit_set[Buffer_Usage; u8]

Transfer_Usage :: enum u8 {Upload, Download}

Shader_Stage :: enum u8 {Vertex, Fragment}

// The one shader language the running backend reads: SPIR-V for Vulkan, Metal's source
// on Apple's platforms and WGSL in a browser.
Shader_Format :: enum u8 {Spirv, Msl, Wgsl}

Vertex_Format :: enum u8 {
	Invalid,
	Int, Int2, Int3, Int4,
	Uint, Uint2, Uint3, Uint4,
	Float, Float2, Float3, Float4,
	Ubyte4, Ubyte4_Norm, Byte4_Norm,
	Short2_Norm, Short4_Norm, Ushort2_Norm, Ushort4_Norm,
	Half2, Half4,
}

Vertex_Input_Rate :: enum u8 {Vertex, Instance}
Primitive :: enum u8 {Triangle_List, Triangle_Strip, Line_List, Line_Strip, Point_List}
Fill_Mode :: enum u8 {Fill, Line}
Cull_Mode :: enum u8 {None, Front, Back}
Front_Face :: enum u8 {Counter_Clockwise, Clockwise}
Index_Size :: enum u8 {U16, U32}

// Invalid, the zero value, is "not set": a backend reads it as its own default.
Compare_Op :: enum u8 {Invalid, Never, Less, Equal, Less_Or_Equal, Greater, Not_Equal, Greater_Or_Equal, Always}
Stencil_Op :: enum u8 {Invalid, Keep, Zero, Replace, Increment_And_Clamp, Decrement_And_Clamp, Invert, Increment_And_Wrap, Decrement_And_Wrap}
Blend_Op :: enum u8 {Invalid, Add, Subtract, Reverse_Subtract, Min, Max}
Blend_Factor :: enum u8 {
	Invalid,
	Zero, One,
	Src_Color, One_Minus_Src_Color,
	Dst_Color, One_Minus_Dst_Color,
	Src_Alpha, One_Minus_Src_Alpha,
	Dst_Alpha, One_Minus_Dst_Alpha,
	Constant_Color, One_Minus_Constant_Color,
	Src_Alpha_Saturate,
}
Color_Component :: enum u8 {R, G, B, A}
Color_Components :: bit_set[Color_Component; u8]

Filter :: enum u8 {Nearest, Linear}
Mipmap_Mode :: enum u8 {Nearest, Linear}
Address_Mode :: enum u8 {Repeat, Mirrored_Repeat, Clamp_To_Edge}

Load_Op :: enum u8 {Load, Clear, Dont_Care}
Store_Op :: enum u8 {Store, Dont_Care, Resolve, Resolve_And_Store}

Present_Mode :: enum u8 {Vsync, Immediate, Mailbox}
Swapchain_Composition :: enum u8 {Sdr, Sdr_Linear, Hdr_Extended_Linear, Hdr10_St2084}

Viewport :: struct {
	x, y, w, h:           f32,
	min_depth, max_depth: f32,
}

// The layouts of the commands an indirect draw or dispatch reads from a buffer, as every
// API lays them out.
Indirect_Draw :: struct {
	num_vertices, num_instances, first_vertex, first_instance: u32,
}
Indexed_Indirect_Draw :: struct {
	num_indices:    u32,
	num_instances:  u32,
	first_index:    u32,
	vertex_offset:  i32,
	first_instance: u32,
}
Indirect_Dispatch :: struct {
	groupcount_x, groupcount_y, groupcount_z: u32,
}

Texture_Desc :: struct {
	type:                 Texture_Type,
	format:               Format,
	usage:                Texture_Usages,
	width, height:        u32,
	layer_count_or_depth: u32,
	num_levels:           u32,
	sample_count:         Sample_Count,
}

Buffer_Desc :: struct {
	usage: Buffer_Usages,
	size:  u32,
}

Transfer_Buffer_Desc :: struct {
	usage: Transfer_Usage,
	size:  u32,
}

Sampler_Desc :: struct {
	min_filter, mag_filter:                         Filter,
	mipmap_mode:                                    Mipmap_Mode,
	address_mode_u, address_mode_v, address_mode_w: Address_Mode,
	mip_lod_bias:                                   f32,
	max_anisotropy:                                 f32,
	compare_op:                                     Compare_Op,
	min_lod, max_lod:                               f32,
	enable_anisotropy:                              bool,
	enable_compare:                                 bool,
}

Shader_Desc :: struct {
	// The shader's bytes: SPIR-V, Metal source or WGSL. A string because render #loads its
	// shaders as strings (render/shaders.odin).
	code:                 string,
	entrypoint:           cstring,
	format:               Shader_Format,
	stage:                Shader_Stage,
	num_samplers:         u32,
	num_storage_textures: u32,
	num_storage_buffers:  u32,
	num_uniform_buffers:  u32,
}

Compute_Pipeline_Desc :: struct {
	code:                           string,
	entrypoint:                     cstring,
	format:                         Shader_Format,
	num_samplers:                   u32,
	num_readonly_storage_textures:  u32,
	num_readonly_storage_buffers:   u32,
	num_readwrite_storage_textures: u32,
	num_readwrite_storage_buffers:  u32,
	num_uniform_buffers:            u32,
	threadcount_x, threadcount_y, threadcount_z: u32,
	// Values for the kernel's specialization constants (Metal's function constants),
	// constant i taking constant_id i, each 32 bits: the driver folds the branches they
	// rule out. Empty leaves every constant at the default the shader gives it. WebGPU
	// refuses a kernel given any.
	constants:                      []u32,
}

// The most specialization constants a kernel takes (Compute_Pipeline_Desc.constants): the
// Vulkan backend lays them out on the stack.
COMPUTE_CONSTANTS_MAX :: 8

Vertex_Buffer :: struct {
	slot:       u32,
	pitch:      u32,
	input_rate: Vertex_Input_Rate,
}

Vertex_Attribute :: struct {
	location:    u32,
	buffer_slot: u32,
	format:      Vertex_Format,
	offset:      u32,
}

Vertex_Input :: struct {
	buffers:    []Vertex_Buffer,
	attributes: []Vertex_Attribute,
}

Rasterizer_State :: struct {
	fill_mode:                  Fill_Mode,
	cull_mode:                  Cull_Mode,
	front_face:                 Front_Face,
	depth_bias_constant_factor: f32,
	depth_bias_clamp:           f32,
	depth_bias_slope_factor:    f32,
	enable_depth_bias:          bool,
	enable_depth_clip:          bool,
}

Multisample_State :: struct {
	sample_count: Sample_Count,
}

Stencil_Op_State :: struct {
	fail_op, pass_op, depth_fail_op: Stencil_Op,
	compare_op:                      Compare_Op,
}

Depth_Stencil_State :: struct {
	compare_op:                              Compare_Op,
	back_stencil_state, front_stencil_state: Stencil_Op_State,
	compare_mask, write_mask:                u8,
	enable_depth_test:                       bool,
	enable_depth_write:                      bool,
	enable_stencil_test:                     bool,
}

Blend_State :: struct {
	src_color_blendfactor, dst_color_blendfactor: Blend_Factor,
	color_blend_op:                               Blend_Op,
	src_alpha_blendfactor, dst_alpha_blendfactor: Blend_Factor,
	alpha_blend_op:                               Blend_Op,
	color_write_mask:                             Color_Components,
	enable_blend:                                 bool,
	enable_color_write_mask:                      bool,
}

Color_Target_Desc :: struct {
	format:      Format,
	blend_state: Blend_State,
}

Pipeline_Targets :: struct {
	color_targets:            []Color_Target_Desc,
	depth_stencil_format:     Format,
	has_depth_stencil_target: bool,
}

Graphics_Pipeline_Desc :: struct {
	vertex_shader:       Shader,
	fragment_shader:     Shader,
	vertex_input:        Vertex_Input,
	primitive:           Primitive,
	rasterizer_state:    Rasterizer_State,
	multisample_state:   Multisample_State,
	depth_stencil_state: Depth_Stencil_State,
	targets:             Pipeline_Targets,
}

Color_Target :: struct {
	texture:               Texture,
	mip_level:             u32,
	layer_or_depth_plane:  u32,
	clear_color:           [4]f32,
	load_op:               Load_Op,
	store_op:              Store_Op,
	resolve_texture:       Texture,
	resolve_mip_level:     u32,
	resolve_layer:         u32,
	cycle:                 bool,
	cycle_resolve_texture: bool,
}

Depth_Target :: struct {
	texture:          Texture,
	clear_depth:      f32,
	load_op:          Load_Op,
	store_op:         Store_Op,
	stencil_load_op:  Load_Op,
	stencil_store_op: Store_Op,
	cycle:            bool,
	clear_stencil:    u8,
	mip_level:        u8,
	layer:            u8,
}

Texture_Transfer_Info :: struct {
	transfer_buffer: Transfer_Buffer,
	offset:          u32,
	pixels_per_row:  u32,
	rows_per_layer:  u32,
}

Transfer_Buffer_Location :: struct {
	transfer_buffer: Transfer_Buffer,
	offset:          u32,
}

Texture_Location :: struct {
	texture:          Texture,
	mip_level, layer: u32,
	x, y, z:          u32,
}

Texture_Region :: struct {
	texture:          Texture,
	mip_level, layer: u32,
	x, y, z:          u32,
	w, h, d:          u32,
}

Buffer_Location :: struct {
	buffer: Buffer,
	offset: u32,
}

Buffer_Region :: struct {
	buffer: Buffer,
	offset: u32,
	size:   u32,
}

Buffer_Binding :: struct {
	buffer: Buffer,
	offset: u32,
}

Texture_Sampler_Binding :: struct {
	texture: Texture,
	sampler: Sampler,
}

Storage_Buffer_Binding :: struct {
	buffer: Buffer,
	cycle:  bool,
}

Storage_Texture_Binding :: struct {
	texture:          Texture,
	mip_level, layer: u32,
	cycle:            bool,
}

// A rectangle of a target in pixels, from its top left corner: the scissor.
Rect :: struct {
	x, y, w, h: i32,
}
