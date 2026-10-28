package render

import "core:log"
import "core:mem"
import "core:strings"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// Buffers, textures, samplers, shaders and pipelines of the Vulkan backend. A handle the app
// holds is a container: SDL_GPU lets a write "cycle" a resource the GPU may still be
// reading, which swaps in another backing object (made on demand, reused once idle) so the
// write never waits. Each backing counts the command buffers that use it; a released
// resource is destroyed once its last backing is idle.

Vk_Host :: enum u8 {
	None,     // device-local
	Upload,   // a transfer buffer the CPU writes
	Download, // a transfer buffer the CPU reads
}

Vk_Buffer_Backing :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	mapped: [^]u8,
	refs:   i32,
	stamp:  u64,
	owner:  ^Vk_Buffer,
}

Vk_Buffer :: struct {
	backings: [dynamic]^Vk_Buffer_Backing,
	active:   ^Vk_Buffer_Backing,
	size:     u32,
	usage:    vk.BufferUsageFlags,
	host:     Vk_Host,
	released: bool,
}

Vk_Image :: struct {
	image:       vk.Image,
	memory:      vk.DeviceMemory,
	view:        vk.ImageView,   // every level, for sampling; 0 for textures never sampled
	level_views: []vk.ImageView, // one per level, for render targets and storage writes
	refs:        i32,
	stamp:       u64,
	owner:       ^Vk_Texture,
}

Vk_Texture :: struct {
	info:           sdl.GPUTextureCreateInfo,
	format:         vk.Format,
	aspect:         vk.ImageAspectFlags,
	usage:          vk.ImageUsageFlags,
	default_layout: vk.ImageLayout,
	backings:       [dynamic]^Vk_Image,
	active:         ^Vk_Image,
	swapchain:      bool, // owned by a window's swapchain: never cycled or destroyed here
	released:       bool,
}

Vk_Sampler :: struct {
	sampler:  vk.Sampler,
	refs:     i32,
	stamp:    u64,
	released: bool,
}

Vk_Shader :: struct {
	module: vk.ShaderModule,
	entry:  cstring,
	stage:  sdl.GPUShaderStage,
	counts: [4]u32, // samplers, storage textures, storage buffers, uniform buffers
}

// Descriptor set layouts are shared by their binding counts. Read resources come first
// (samplers, then storage textures, then storage buffers), as SDL_GPU numbers them.
Vk_Set_Key :: struct {
	stage:           vk.ShaderStageFlags,
	samplers:        u32,
	storage_tex:     u32,
	storage_buf:     u32,
	write_tex:       u32,
	write_buf:       u32,
	uniform_buffers: u32,
}

Vk_Graphics_Layout_Key :: [8]u32 // the vertex shader's four counts, then the fragment shader's
Vk_Compute_Layout_Key :: [6]u32 // samplers, read-only textures and buffers, read-write textures and buffers, uniforms

Vk_Pipeline_Layout :: struct {
	layout: vk.PipelineLayout,
	sets:   [4]vk.DescriptorSetLayout,
	counts: [8]u32,
}

Vk_Pipeline :: struct {
	pipeline: vk.Pipeline,
	layout:   ^Vk_Pipeline_Layout,
	compute:  bool,
	refs:     i32,
	stamp:    u64,
	released: bool,
}

vk_set_layout :: proc(key: Vk_Set_Key) -> vk.DescriptorSetLayout {
	if layout, ok := vk_state.set_layouts[key]; ok do return layout
	bindings: [64]vk.DescriptorSetLayoutBinding
	n: u32
	add :: proc(bindings: ^[64]vk.DescriptorSetLayoutBinding, n: ^u32, count: u32, type: vk.DescriptorType, stage: vk.ShaderStageFlags) {
		for _ in 0 ..< count {
			bindings[n^] = {binding = n^, descriptorType = type, descriptorCount = 1, stageFlags = stage}
			n^ += 1
		}
	}
	add(&bindings, &n, key.samplers, .COMBINED_IMAGE_SAMPLER, key.stage)
	// SDL_GPU declares read-only storage textures as sampled images.
	add(&bindings, &n, key.storage_tex, .SAMPLED_IMAGE, key.stage)
	add(&bindings, &n, key.storage_buf, .STORAGE_BUFFER, key.stage)
	add(&bindings, &n, key.write_tex, .STORAGE_IMAGE, key.stage)
	add(&bindings, &n, key.write_buf, .STORAGE_BUFFER, key.stage)
	add(&bindings, &n, key.uniform_buffers, .UNIFORM_BUFFER_DYNAMIC, key.stage)
	info := vk.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, bindingCount = n, pBindings = &bindings[0]}
	layout: vk.DescriptorSetLayout
	if vk.CreateDescriptorSetLayout(vk_state.device, &info, nil, &layout) != .SUCCESS do return 0
	vk_state.set_layouts[key] = layout
	return layout
}

@(private = "file")
vk_pipeline_layout_make :: proc(sets: [4]vk.DescriptorSetLayout, set_count: u32, counts: [8]u32) -> ^Vk_Pipeline_Layout {
	sets := sets
	for s in sets[:set_count] do if s == 0 do return nil
	info := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = set_count, pSetLayouts = &sets[0]}
	layout := new(Vk_Pipeline_Layout)
	layout.sets, layout.counts = sets, counts
	if vk.CreatePipelineLayout(vk_state.device, &info, nil, &layout.layout) != .SUCCESS {
		free(layout)
		return nil
	}
	return layout
}

vk_graphics_layout :: proc(vertex, fragment: ^Vk_Shader) -> ^Vk_Pipeline_Layout {
	key: Vk_Graphics_Layout_Key
	copy(key[0:4], vertex.counts[:])
	copy(key[4:8], fragment.counts[:])
	if layout, ok := vk_state.graphics_layouts[key]; ok do return layout
	sets := [4]vk.DescriptorSetLayout {
		vk_set_layout({stage = {.VERTEX}, samplers = key[0], storage_tex = key[1], storage_buf = key[2]}),
		vk_set_layout({stage = {.VERTEX}, uniform_buffers = key[3]}),
		vk_set_layout({stage = {.FRAGMENT}, samplers = key[4], storage_tex = key[5], storage_buf = key[6]}),
		vk_set_layout({stage = {.FRAGMENT}, uniform_buffers = key[7]}),
	}
	layout := vk_pipeline_layout_make(sets, 4, key)
	if layout != nil do vk_state.graphics_layouts[key] = layout
	return layout
}

vk_compute_layout :: proc(info: sdl.GPUComputePipelineCreateInfo) -> ^Vk_Pipeline_Layout {
	key := Vk_Compute_Layout_Key{info.num_samplers, info.num_readonly_storage_textures, info.num_readonly_storage_buffers, info.num_readwrite_storage_textures, info.num_readwrite_storage_buffers, info.num_uniform_buffers}
	if layout, ok := vk_state.compute_layouts[key]; ok do return layout
	sets := [4]vk.DescriptorSetLayout {
		vk_set_layout({stage = {.COMPUTE}, samplers = key[0], storage_tex = key[1], storage_buf = key[2]}),
		vk_set_layout({stage = {.COMPUTE}, write_tex = key[3], write_buf = key[4]}),
		vk_set_layout({stage = {.COMPUTE}, uniform_buffers = key[5]}),
		0,
	}
	counts: [8]u32
	copy(counts[:], key[:])
	layout := vk_pipeline_layout_make(sets, 3, counts)
	if layout != nil do vk_state.compute_layouts[key] = layout
	return layout
}

// ---- Buffers ------------------------------------------------------------------------

@(private = "file")
vk_buffer_backing_make :: proc(b: ^Vk_Buffer) -> ^Vk_Buffer_Backing {
	info := vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = vk.DeviceSize(max(b.size, 4)), usage = b.usage, sharingMode = .EXCLUSIVE}
	backing := new(Vk_Buffer_Backing)
	backing.owner = b
	if vk.CreateBuffer(vk_state.device, &info, nil, &backing.buffer) != .SUCCESS {
		free(backing)
		return nil
	}
	reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(vk_state.device, backing.buffer, &reqs)
	ok: bool
	switch b.host {
	case .None:     backing.memory, ok = vk_allocate(reqs, {.DEVICE_LOCAL}, {})
	case .Upload:   backing.memory, ok = vk_allocate(reqs, {.HOST_VISIBLE, .HOST_COHERENT}, {})
	case .Download: backing.memory, ok = vk_allocate(reqs, {.HOST_VISIBLE, .HOST_COHERENT}, {.HOST_CACHED})
	}
	if !ok && b.host == .None do backing.memory, ok = vk_allocate(reqs, {}, {})
	if !ok || vk.BindBufferMemory(vk_state.device, backing.buffer, backing.memory, 0) != .SUCCESS {
		vk_buffer_backing_destroy(backing)
		return nil
	}
	if b.host != .None {
		data: rawptr
		if vk.MapMemory(vk_state.device, backing.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &data) != .SUCCESS {
			vk_buffer_backing_destroy(backing)
			return nil
		}
		backing.mapped = ([^]u8)(data)
	}
	append(&b.backings, backing)
	return backing
}

@(private = "file")
vk_buffer_backing_destroy :: proc(backing: ^Vk_Buffer_Backing) {
	if backing.buffer != 0 do vk.DestroyBuffer(vk_state.device, backing.buffer, nil)
	if backing.memory != 0 do vk.FreeMemory(vk_state.device, backing.memory, nil)
	free(backing)
}

@(private = "file")
vk_buffer_make :: proc(size: u32, usage: vk.BufferUsageFlags, host: Vk_Host) -> ^Vk_Buffer {
	b := new(Vk_Buffer)
	b.size, b.usage, b.host = size, usage, host
	b.active = vk_buffer_backing_make(b)
	if b.active == nil {
		delete(b.backings)
		free(b)
		return nil
	}
	return b
}

vk_create_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUBufferCreateInfo) -> ^sdl.GPUBuffer {
	usage := vk.BufferUsageFlags{.TRANSFER_SRC, .TRANSFER_DST}
	if .VERTEX in info.usage do usage += {.VERTEX_BUFFER}
	if .INDEX in info.usage do usage += {.INDEX_BUFFER}
	if .INDIRECT in info.usage do usage += {.INDIRECT_BUFFER}
	if info.usage & {.GRAPHICS_STORAGE_READ, .COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE} != {} do usage += {.STORAGE_BUFFER}
	b := vk_buffer_make(info.size, usage, .None)
	if b == nil do log.errorf("Vulkan: a %d byte buffer could not be made", info.size)
	return (^sdl.GPUBuffer)(b)
}

vk_create_transfer_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUTransferBufferCreateInfo) -> ^sdl.GPUTransferBuffer {
	b := vk_buffer_make(info.size, {.TRANSFER_SRC, .TRANSFER_DST}, .Upload if info.usage == .UPLOAD else .Download)
	if b == nil do log.errorf("Vulkan: a %d byte transfer buffer could not be made", info.size)
	return (^sdl.GPUTransferBuffer)(b)
}

// Frees what of a released buffer the GPU no longer uses, and the buffer with its last
// backing.
vk_buffer_reap :: proc(b: ^Vk_Buffer) {
	if !b.released do return
	for i := 0; i < len(b.backings); {
		if b.backings[i].refs > 0 {
			i += 1
			continue
		}
		vk_buffer_backing_destroy(b.backings[i])
		unordered_remove(&b.backings, i)
	}
	if len(b.backings) == 0 {
		delete(b.backings)
		free(b)
	}
}

vk_release_buffer :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer) {
	b := (^Vk_Buffer)(buffer)
	if b == nil do return
	b.released = true
	vk_buffer_reap(b)
}

vk_release_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {
	vk_release_buffer(device, (^sdl.GPUBuffer)(transfer_buffer))
}

// Swaps in a backing no command buffer uses, making one if every backing is in use.
vk_buffer_cycle :: proc(b: ^Vk_Buffer) {
	for backing in b.backings {
		if backing.refs == 0 {
			b.active = backing
			return
		}
	}
	if backing := vk_buffer_backing_make(b); backing != nil do b.active = backing
}

vk_map_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer, cycle: bool) -> rawptr {
	b := (^Vk_Buffer)(transfer_buffer)
	if cycle && b.active.refs > 0 do vk_buffer_cycle(b)
	return b.active.mapped
}

// Transfer memory is host-coherent, so writes need no flush.
vk_unmap_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {}

// ---- Textures -----------------------------------------------------------------------

vk_default_layout :: proc(usage: sdl.GPUTextureUsageFlags) -> vk.ImageLayout {
	// SDL_GPU's order: a texture rests in the layout its first listed use needs.
	switch {
	case .SAMPLER in usage:               return .SHADER_READ_ONLY_OPTIMAL
	case .GRAPHICS_STORAGE_READ in usage: return .GENERAL
	case .COLOR_TARGET in usage:          return .COLOR_ATTACHMENT_OPTIMAL
	case .DEPTH_STENCIL_TARGET in usage:  return .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
	}
	return .GENERAL
}

@(private = "file")
vk_view_make :: proc(t: ^Vk_Texture, image: vk.Image, base_level, levels: u32) -> vk.ImageView {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image,
		viewType = .D2,
		format = t.format,
		subresourceRange = {aspectMask = t.aspect - {.STENCIL}, baseMipLevel = base_level, levelCount = levels, layerCount = 1},
	}
	view: vk.ImageView
	if vk.CreateImageView(vk_state.device, &info, nil, &view) != .SUCCESS do return 0
	return view
}

// Records, in `cmd` (or the setup command buffer when nil), the move of a new image out
// of the undefined layout into its texture's default one.
vk_image_backing_make :: proc(t: ^Vk_Texture, cmd: ^Vk_Cmd) -> ^Vk_Image {
	info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = t.format,
		extent = {t.info.width, t.info.height, 1},
		mipLevels = t.info.num_levels,
		arrayLayers = 1,
		samples = vk_samples(t.info.sample_count),
		tiling = .OPTIMAL,
		usage = t.usage,
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	img := new(Vk_Image)
	img.owner = t
	if vk.CreateImage(vk_state.device, &info, nil, &img.image) != .SUCCESS {
		free(img)
		return nil
	}
	reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(vk_state.device, img.image, &reqs)
	ok: bool
	img.memory, ok = vk_allocate(reqs, {.DEVICE_LOCAL}, {})
	if !ok || vk.BindImageMemory(vk_state.device, img.image, img.memory, 0) != .SUCCESS {
		vk_image_backing_destroy(img)
		return nil
	}
	if .SAMPLED in t.usage {
		img.view = vk_view_make(t, img.image, 0, t.info.num_levels)
		if img.view == 0 {
			vk_image_backing_destroy(img)
			return nil
		}
	}
	if t.usage & {.COLOR_ATTACHMENT, .DEPTH_STENCIL_ATTACHMENT, .STORAGE} != {} {
		img.level_views = make([]vk.ImageView, t.info.num_levels)
		for &view, level in img.level_views {
			view = vk_view_make(t, img.image, u32(level), 1)
			if view == 0 {
				vk_image_backing_destroy(img)
				return nil
			}
		}
	}
	append(&t.backings, img)
	target := cmd if cmd != nil else vk_setup_cmd()
	vk_cmd_track_image(target, img)
	vk_image_barrier(target, img, .UNDEFINED, t.default_layout)
	return img
}

vk_image_backing_destroy :: proc(img: ^Vk_Image) {
	for view in img.level_views do if view != 0 do vk.DestroyImageView(vk_state.device, view, nil)
	delete(img.level_views)
	if img.view != 0 do vk.DestroyImageView(vk_state.device, img.view, nil)
	if img.image != 0 do vk.DestroyImage(vk_state.device, img.image, nil)
	if img.memory != 0 do vk.FreeMemory(vk_state.device, img.memory, nil)
	free(img)
}

vk_create_texture :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUTextureCreateInfo) -> ^sdl.GPUTexture {
	if info.type != .D2 || info.layer_count_or_depth > 1 {
		log.errorf("Vulkan: only 2D textures are supported (asked for %v)", info.type)
		return nil
	}
	t := new(Vk_Texture)
	t.info = info
	t.format = vk_format(info.format)
	t.aspect = {.DEPTH} if vk_is_depth(info.format) else {.COLOR}
	if info.format == .D24_UNORM_S8_UINT || info.format == .D32_FLOAT_S8_UINT do t.aspect += {.STENCIL}
	t.usage = {.TRANSFER_SRC, .TRANSFER_DST}
	if info.usage & {.SAMPLER, .GRAPHICS_STORAGE_READ, .COMPUTE_STORAGE_READ} != {} do t.usage += {.SAMPLED}
	if .COLOR_TARGET in info.usage do t.usage += {.COLOR_ATTACHMENT}
	if .DEPTH_STENCIL_TARGET in info.usage do t.usage += {.DEPTH_STENCIL_ATTACHMENT}
	if info.usage & {.COMPUTE_STORAGE_WRITE, .COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE} != {} do t.usage += {.STORAGE}
	t.default_layout = vk_default_layout(info.usage)
	t.active = vk_image_backing_make(t, nil)
	if t.active == nil {
		log.errorf("Vulkan: a %dx%d %v texture could not be made", info.width, info.height, info.format)
		delete(t.backings)
		free(t)
		return nil
	}
	return (^sdl.GPUTexture)(t)
}

vk_texture_reap :: proc(t: ^Vk_Texture) {
	if !t.released || t.swapchain do return
	for i := 0; i < len(t.backings); {
		if t.backings[i].refs > 0 {
			i += 1
			continue
		}
		vk_image_backing_destroy(t.backings[i])
		unordered_remove(&t.backings, i)
	}
	if len(t.backings) == 0 {
		delete(t.backings)
		free(t)
	}
}

vk_release_texture :: proc(device: ^sdl.GPUDevice, texture: ^sdl.GPUTexture) {
	t := (^Vk_Texture)(texture)
	if t == nil do return
	t.released = true
	vk_texture_reap(t)
}

// Points `t` at a backing no command buffer uses, as SDL_GPU's cycling does.
vk_texture_cycle :: proc(t: ^Vk_Texture, cmd: ^Vk_Cmd) {
	for img in t.backings {
		if img.refs == 0 {
			t.active = img
			return
		}
	}
	if img := vk_image_backing_make(t, cmd); img != nil do t.active = img
}

// ---- Samplers and shaders -----------------------------------------------------------

vk_create_sampler :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUSamplerCreateInfo) -> ^sdl.GPUSampler {
	filter :: proc(f: sdl.GPUFilter) -> vk.Filter {return .LINEAR if f == .LINEAR else .NEAREST}
	address :: proc(a: sdl.GPUSamplerAddressMode) -> vk.SamplerAddressMode {
		switch a {
		case .REPEAT:          return .REPEAT
		case .MIRRORED_REPEAT: return .MIRRORED_REPEAT
		case .CLAMP_TO_EDGE:   return .CLAMP_TO_EDGE
		}
		return .REPEAT
	}
	create := vk.SamplerCreateInfo {
		sType            = .SAMPLER_CREATE_INFO,
		magFilter        = filter(info.mag_filter),
		minFilter        = filter(info.min_filter),
		mipmapMode       = .LINEAR if info.mipmap_mode == .LINEAR else .NEAREST,
		addressModeU     = address(info.address_mode_u),
		addressModeV     = address(info.address_mode_v),
		addressModeW     = address(info.address_mode_w),
		mipLodBias       = info.mip_lod_bias,
		anisotropyEnable = b32(info.enable_anisotropy),
		maxAnisotropy    = info.max_anisotropy,
		compareEnable    = b32(info.enable_compare),
		compareOp        = vk_compare(info.compare_op),
		minLod           = info.min_lod,
		maxLod           = info.max_lod,
		borderColor      = .FLOAT_TRANSPARENT_BLACK,
	}
	s := new(Vk_Sampler)
	if vk.CreateSampler(vk_state.device, &create, nil, &s.sampler) != .SUCCESS {
		free(s)
		return nil
	}
	return (^sdl.GPUSampler)(s)
}

vk_sampler_reap :: proc(s: ^Vk_Sampler) {
	if !s.released || s.refs > 0 do return
	vk.DestroySampler(vk_state.device, s.sampler, nil)
	free(s)
}

vk_release_sampler :: proc(device: ^sdl.GPUDevice, sampler: ^sdl.GPUSampler) {
	s := (^Vk_Sampler)(sampler)
	if s == nil do return
	s.released = true
	vk_sampler_reap(s)
}

@(private = "file")
vk_module :: proc(code: []u8) -> vk.ShaderModule {
	// SPIR-V words must be 4-byte aligned; an embedded blob may not be.
	words := make([]u32, (len(code) + 3) / 4, context.temp_allocator)
	mem.copy(raw_data(words), raw_data(code), len(code))
	info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code), pCode = raw_data(words)}
	module: vk.ShaderModule
	if vk.CreateShaderModule(vk_state.device, &info, nil, &module) != .SUCCESS do return 0
	return module
}

vk_create_shader :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUShaderCreateInfo) -> ^sdl.GPUShader {
	if .SPIRV not_in info.format do return nil
	module := vk_module(info.code[:info.code_size])
	if module == 0 do return nil
	s := new(Vk_Shader)
	s.module, s.stage = module, info.stage
	s.entry = strings.clone_to_cstring(string(info.entrypoint) if info.entrypoint != nil else "main")
	s.counts = {info.num_samplers, info.num_storage_textures, info.num_storage_buffers, info.num_uniform_buffers}
	return (^sdl.GPUShader)(s)
}

// A shader is only read while pipelines are made from it, so it goes at once.
vk_release_shader :: proc(device: ^sdl.GPUDevice, shader: ^sdl.GPUShader) {
	s := (^Vk_Shader)(shader)
	if s == nil do return
	vk.DestroyShaderModule(vk_state.device, s.module, nil)
	delete(s.entry)
	free(s)
}

// ---- Pipelines ----------------------------------------------------------------------

vk_compare :: proc(op: sdl.GPUCompareOp) -> vk.CompareOp {
	switch op {
	case .INVALID, .NEVER:    return .NEVER
	case .LESS:               return .LESS
	case .EQUAL:              return .EQUAL
	case .LESS_OR_EQUAL:      return .LESS_OR_EQUAL
	case .GREATER:            return .GREATER
	case .NOT_EQUAL:          return .NOT_EQUAL
	case .GREATER_OR_EQUAL:   return .GREATER_OR_EQUAL
	case .ALWAYS:             return .ALWAYS
	}
	return .NEVER
}

@(private = "file")
vk_blend_factor :: proc(f: sdl.GPUBlendFactor) -> vk.BlendFactor {
	switch f {
	case .INVALID, .ZERO:            return .ZERO
	case .ONE:                       return .ONE
	case .SRC_COLOR:                 return .SRC_COLOR
	case .ONE_MINUS_SRC_COLOR:       return .ONE_MINUS_SRC_COLOR
	case .DST_COLOR:                 return .DST_COLOR
	case .ONE_MINUS_DST_COLOR:       return .ONE_MINUS_DST_COLOR
	case .SRC_ALPHA:                 return .SRC_ALPHA
	case .ONE_MINUS_SRC_ALPHA:       return .ONE_MINUS_SRC_ALPHA
	case .DST_ALPHA:                 return .DST_ALPHA
	case .ONE_MINUS_DST_ALPHA:       return .ONE_MINUS_DST_ALPHA
	case .CONSTANT_COLOR:            return .CONSTANT_COLOR
	case .ONE_MINUS_CONSTANT_COLOR:  return .ONE_MINUS_CONSTANT_COLOR
	case .SRC_ALPHA_SATURATE:        return .SRC_ALPHA_SATURATE
	}
	return .ZERO
}

@(private = "file")
vk_blend_op :: proc(op: sdl.GPUBlendOp) -> vk.BlendOp {
	switch op {
	case .INVALID, .ADD:     return .ADD
	case .SUBTRACT:          return .SUBTRACT
	case .REVERSE_SUBTRACT:  return .REVERSE_SUBTRACT
	case .MIN:               return .MIN
	case .MAX:               return .MAX
	}
	return .ADD
}

@(private = "file")
vk_stencil_op :: proc(op: sdl.GPUStencilOp) -> vk.StencilOp {
	switch op {
	case .INVALID, .KEEP:        return .KEEP
	case .ZERO:                  return .ZERO
	case .REPLACE:               return .REPLACE
	case .INCREMENT_AND_CLAMP:   return .INCREMENT_AND_CLAMP
	case .DECREMENT_AND_CLAMP:   return .DECREMENT_AND_CLAMP
	case .INVERT:                return .INVERT
	case .INCREMENT_AND_WRAP:    return .INCREMENT_AND_WRAP
	case .DECREMENT_AND_WRAP:    return .DECREMENT_AND_WRAP
	}
	return .KEEP
}

@(private = "file")
vk_vertex_format :: proc(f: sdl.GPUVertexElementFormat) -> vk.Format {
	#partial switch f {
	case .INT:          return .R32_SINT
	case .INT2:         return .R32G32_SINT
	case .INT3:         return .R32G32B32_SINT
	case .INT4:         return .R32G32B32A32_SINT
	case .UINT:         return .R32_UINT
	case .UINT2:        return .R32G32_UINT
	case .UINT3:        return .R32G32B32_UINT
	case .UINT4:        return .R32G32B32A32_UINT
	case .FLOAT:        return .R32_SFLOAT
	case .FLOAT2:       return .R32G32_SFLOAT
	case .FLOAT3:       return .R32G32B32_SFLOAT
	case .FLOAT4:       return .R32G32B32A32_SFLOAT
	case .UBYTE4:       return .R8G8B8A8_UINT
	case .UBYTE4_NORM:  return .R8G8B8A8_UNORM
	case .BYTE4_NORM:   return .R8G8B8A8_SNORM
	case .SHORT2_NORM:  return .R16G16_SNORM
	case .SHORT4_NORM:  return .R16G16B16A16_SNORM
	case .USHORT2_NORM: return .R16G16_UNORM
	case .USHORT4_NORM: return .R16G16B16A16_UNORM
	case .HALF2:        return .R16G16_SFLOAT
	case .HALF4:        return .R16G16B16A16_SFLOAT
	}
	return .UNDEFINED
}

vk_create_graphics_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUGraphicsPipelineCreateInfo) -> ^sdl.GPUGraphicsPipeline {
	vertex, fragment := (^Vk_Shader)(info.vertex_shader), (^Vk_Shader)(info.fragment_shader)
	if vertex == nil || fragment == nil do return nil
	layout := vk_graphics_layout(vertex, fragment)
	if layout == nil do return nil
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vertex.module, pName = vertex.entry},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment.module, pName = fragment.entry},
	}
	vi := info.vertex_input_state
	buffers := make([]vk.VertexInputBindingDescription, vi.num_vertex_buffers, context.temp_allocator)
	for &b, i in buffers {
		d := vi.vertex_buffer_descriptions[i]
		b = {binding = d.slot, stride = d.pitch, inputRate = .INSTANCE if d.input_rate == .INSTANCE else .VERTEX}
	}
	attributes := make([]vk.VertexInputAttributeDescription, vi.num_vertex_attributes, context.temp_allocator)
	for &a, i in attributes {
		d := vi.vertex_attributes[i]
		a = {location = d.location, binding = d.buffer_slot, format = vk_vertex_format(d.format), offset = d.offset}
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = u32(len(buffers)),
		pVertexBindingDescriptions      = raw_data(buffers),
		vertexAttributeDescriptionCount = u32(len(attributes)),
		pVertexAttributeDescriptions    = raw_data(attributes),
	}
	topology: vk.PrimitiveTopology
	switch info.primitive_type {
	case .TRIANGLELIST:  topology = .TRIANGLE_LIST
	case .TRIANGLESTRIP: topology = .TRIANGLE_STRIP
	case .LINELIST:      topology = .LINE_LIST
	case .LINESTRIP:     topology = .LINE_STRIP
	case .POINTLIST:     topology = .POINT_LIST
	}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = topology}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	rs := info.rasterizer_state
	if rs.fill_mode == .LINE && !vk_state.wireframe do return nil
	cull: vk.CullModeFlags
	switch rs.cull_mode {
	case .NONE:
	case .FRONT: cull = {.FRONT}
	case .BACK:  cull = {.BACK}
	}
	raster := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = b32(!rs.enable_depth_clip && vk_state.depth_clamp),
		polygonMode             = .LINE if rs.fill_mode == .LINE else .FILL,
		cullMode                = cull,
		frontFace               = .CLOCKWISE if rs.front_face == .CLOCKWISE else .COUNTER_CLOCKWISE,
		depthBiasEnable         = b32(rs.enable_depth_bias),
		depthBiasConstantFactor = rs.depth_bias_constant_factor,
		depthBiasClamp          = rs.depth_bias_clamp,
		depthBiasSlopeFactor    = rs.depth_bias_slope_factor,
		lineWidth               = 1,
	}
	sample_mask := vk.SampleMask(0xFFFFFFFF)
	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                 = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples  = vk_samples(info.multisample_state.sample_count),
		minSampleShading      = 1,
		pSampleMask           = &sample_mask,
		alphaToCoverageEnable = b32(info.multisample_state.enable_alpha_to_coverage),
	}
	ds := info.depth_stencil_state
	stencil :: proc(s: sdl.GPUStencilOpState, ds: sdl.GPUDepthStencilState) -> vk.StencilOpState {
		return {failOp = vk_stencil_op(s.fail_op), passOp = vk_stencil_op(s.pass_op), depthFailOp = vk_stencil_op(s.depth_fail_op), compareOp = vk_compare(s.compare_op), compareMask = u32(ds.compare_mask), writeMask = u32(ds.write_mask)}
	}
	depth := vk.PipelineDepthStencilStateCreateInfo {
		sType             = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable   = b32(ds.enable_depth_test),
		depthWriteEnable  = b32(ds.enable_depth_write),
		depthCompareOp    = vk_compare(ds.compare_op),
		stencilTestEnable = b32(ds.enable_stencil_test),
		front             = stencil(ds.front_stencil_state, ds),
		back              = stencil(ds.back_stencil_state, ds),
	}
	ti := info.target_info
	blends := make([]vk.PipelineColorBlendAttachmentState, ti.num_color_targets, context.temp_allocator)
	formats := make([]vk.Format, ti.num_color_targets, context.temp_allocator)
	for i in 0 ..< int(ti.num_color_targets) {
		d := ti.color_target_descriptions[i]
		b := d.blend_state
		mask := b.color_write_mask if b.enable_color_write_mask else {.R, .G, .B, .A}
		blends[i] = {
			blendEnable         = b32(b.enable_blend),
			srcColorBlendFactor = vk_blend_factor(b.src_color_blendfactor),
			dstColorBlendFactor = vk_blend_factor(b.dst_color_blendfactor),
			colorBlendOp        = vk_blend_op(b.color_blend_op),
			srcAlphaBlendFactor = vk_blend_factor(b.src_alpha_blendfactor),
			dstAlphaBlendFactor = vk_blend_factor(b.dst_alpha_blendfactor),
			alphaBlendOp        = vk_blend_op(b.alpha_blend_op),
			colorWriteMask      = transmute(vk.ColorComponentFlags)u32(transmute(u8)mask),
		}
		formats[i] = vk_format(d.format)
	}
	blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = ti.num_color_targets,
		pAttachments    = raw_data(blends),
		blendConstants  = {1, 1, 1, 1},
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamics := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = 2, pDynamicStates = &dynamic_states[0]}
	rendering := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = ti.num_color_targets,
		pColorAttachmentFormats = raw_data(formats),
	}
	if ti.has_depth_stencil_target {
		rendering.depthAttachmentFormat = vk_format(ti.depth_stencil_format)
		if ti.depth_stencil_format == .D24_UNORM_S8_UINT || ti.depth_stencil_format == .D32_FLOAT_S8_UINT do rendering.stencilAttachmentFormat = rendering.depthAttachmentFormat
	}
	create := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering,
		stageCount          = 2,
		pStages             = &stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState      = &viewport,
		pRasterizationState = &raster,
		pMultisampleState   = &multisample,
		pDepthStencilState  = &depth,
		pColorBlendState    = &blend,
		pDynamicState       = &dynamics,
		layout              = layout.layout,
	}
	p := new(Vk_Pipeline)
	p.layout = layout
	if r := vk.CreateGraphicsPipelines(vk_state.device, 0, 1, &create, nil, &p.pipeline); r != .SUCCESS {
		log.errorf("Vulkan: vkCreateGraphicsPipelines failed: %v", r)
		free(p)
		return nil
	}
	return (^sdl.GPUGraphicsPipeline)(p)
}

vk_create_compute_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	if .SPIRV not_in info.format do return nil
	layout := vk_compute_layout(info)
	if layout == nil do return nil
	module := vk_module(info.code[:info.code_size])
	if module == 0 do return nil
	defer vk.DestroyShaderModule(vk_state.device, module, nil)
	entry := info.entrypoint if info.entrypoint != nil else "main"
	create := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		stage  = {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.COMPUTE}, module = module, pName = entry},
		layout = layout.layout,
	}
	p := new(Vk_Pipeline)
	p.layout, p.compute = layout, true
	if r := vk.CreateComputePipelines(vk_state.device, 0, 1, &create, nil, &p.pipeline); r != .SUCCESS {
		log.errorf("Vulkan: vkCreateComputePipelines failed: %v", r)
		free(p)
		return nil
	}
	return (^sdl.GPUComputePipeline)(p)
}

vk_pipeline_reap :: proc(p: ^Vk_Pipeline) {
	if !p.released || p.refs > 0 do return
	vk.DestroyPipeline(vk_state.device, p.pipeline, nil)
	free(p)
}

vk_release_graphics_pipeline :: proc(device: ^sdl.GPUDevice, pipeline: ^sdl.GPUGraphicsPipeline) {
	p := (^Vk_Pipeline)(pipeline)
	if p == nil do return
	p.released = true
	vk_pipeline_reap(p)
}

vk_release_compute_pipeline :: proc(device: ^sdl.GPUDevice, pipeline: ^sdl.GPUComputePipeline) {
	p := (^Vk_Pipeline)(pipeline)
	if p == nil do return
	p.released = true
	vk_pipeline_reap(p)
}
