#+build darwin
package render

import "core:log"

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import sdl "vendor:sdl3"

// Buffers, textures, samplers, shaders and pipelines of the Metal backend. As in the Vulkan
// backend, a buffer or texture handle the app holds is a container: a write may "cycle" it,
// swapping in another backing object (made on demand, reused once idle) so the write never
// waits for the GPU. Each backing counts the command buffers that use it, and a released
// resource frees a backing once nothing uses it. Samplers and pipelines go at once, since a
// Metal command buffer keeps what it uses alive until it finishes.

// Vertex buffers sit above the uniform and storage buffers of the vertex stage, at
// SDL_GPU's slots, which the Metal shaders are compiled for.
MTL_FIRST_VERTEX_BUFFER :: 14

Mtl_Buffer_Backing :: struct {
	buffer: ^MTL.Buffer,
	refs:   i32,
	stamp:  u64,
	owner:  ^Mtl_Buffer,
}

Mtl_Buffer :: struct {
	backings: [dynamic]^Mtl_Buffer_Backing,
	active:   ^Mtl_Buffer_Backing,
	size:     u32,
	options:  MTL.ResourceOptions,
	released: bool,
	name:     cstring, // for Xcode's GPU capture, given to every backing; a literal, never freed
}

Mtl_Texture_Backing :: struct {
	texture: ^MTL.Texture,
	refs:    i32,
	stamp:   u64,
	owner:   ^Mtl_Texture,
}

Mtl_Texture :: struct {
	info:      sdl.GPUTextureCreateInfo,
	backings:  [dynamic]^Mtl_Texture_Backing,
	active:    ^Mtl_Texture_Backing,
	swapchain: bool, // a window's drawable: never cycled or freed here
	transient: bool, // memoryless, every backing (gpu_create_texture_transient)
	released:  bool,
	name:      cstring, // for Xcode's GPU capture, given to every backing; a literal, never freed
}

Mtl_Shader :: struct {
	library:  ^MTL.Library,
	function: ^MTL.Function,
	stage:    sdl.GPUShaderStage,
	counts:   [4]u32, // samplers, storage textures, storage buffers, uniform buffers
}

Mtl_Pipeline :: struct {
	state:         ^MTL.RenderPipelineState,
	depth_stencil: ^MTL.DepthStencilState, // nil without a depth target
	raster:        sdl.GPURasterizerState,
	primitive:     MTL.PrimitiveType,
	counts:        [8]u32, // the vertex shader's four counts, then the fragment shader's
}

// SDL_GPU's limits per compute pipeline, which size the command buffer's binding arrays.
MTL_SAMPLERS :: 16
MTL_STORAGE_BUFFERS :: 8
MTL_COMPUTE_WRITES :: 8

Mtl_Compute_Pipeline :: struct {
	state:              ^MTL.ComputePipelineState,
	samplers:           u32,
	readonly_textures:  u32,
	readwrite_textures: u32,
	uniforms:           u32,
	readonly_buffers:   u32,
	readwrite_buffers:  u32,
	threads:            MTL.Size, // threads a group, as the create info gave them
}

// ---- Buffers ------------------------------------------------------------------------

@(private = "file")
mtl_buffer_backing_make :: proc(b: ^Mtl_Buffer) -> ^Mtl_Buffer_Backing {
	// Storage buffers must be 4-byte aligned, so SDL_GPU aligns them all.
	size := NS.UInteger(max((b.size + 3) &~ 3, 4))
	buffer := MTL.Device_newBufferWithLength(mtl_state.device, size, b.options)
	if buffer == nil do return nil
	backing := new(Mtl_Buffer_Backing)
	backing.buffer, backing.owner = buffer, b
	mtl_name(buffer, b.name)
	append(&b.backings, backing)
	return backing
}

@(private = "file")
mtl_buffer_make :: proc(size: u32, options: MTL.ResourceOptions) -> ^Mtl_Buffer {
	NS.scoped_autoreleasepool()
	b := new(Mtl_Buffer)
	b.size, b.options = size, options
	b.active = mtl_buffer_backing_make(b)
	if b.active == nil {
		delete(b.backings)
		free(b)
		return nil
	}
	return b
}

// Labels a Metal resource for Xcode's GPU capture.
@(private = "file")
mtl_name :: proc(resource: ^MTL.Resource, name: cstring) {
	if name == nil do return
	NS.scoped_autoreleasepool()
	MTL.Resource_setLabel(resource, mtl_string(string(name)))
}

mtl_set_buffer_name :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer, text: cstring) {
	b := (^Mtl_Buffer)(buffer)
	b.name = text
	for backing in b.backings do mtl_name(backing.buffer, text)
}

mtl_set_texture_name :: proc(device: ^sdl.GPUDevice, texture: ^sdl.GPUTexture, text: cstring) {
	t := (^Mtl_Texture)(texture)
	t.name = text
	for backing in t.backings do mtl_name(backing.texture, text)
}

mtl_create_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUBufferCreateInfo) -> ^sdl.GPUBuffer {
	b := mtl_buffer_make(info.size, {.StorageModePrivate})
	if b == nil do log.errorf("Metal: a %d byte buffer could not be made", info.size)
	return (^sdl.GPUBuffer)(b)
}

// A device buffer in shared memory, filled by the CPU before its first use, where the GPU
// shares the CPU's memory (every Apple silicon GPU); nil elsewhere. A cycle of it makes
// another shared backing, which on unified memory costs what a private one would.
mtl_create_buffer_mapped :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUBufferCreateInfo) -> (^sdl.GPUBuffer, rawptr) {
	if !MTL.Device_hasUnifiedMemory(mtl_state.device) do return nil, nil
	b := mtl_buffer_make(info.size, MTL.ResourceStorageModeShared)
	if b == nil do return nil, nil
	return (^sdl.GPUBuffer)(b), MTL.Buffer_contentsPointer(b.active.buffer)
}

// Transfer buffers are shared memory the CPU maps in place; an upload buffer is only
// written by the CPU, so it is write-combined, as SDL_GPU makes it.
mtl_create_transfer_buffer :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUTransferBufferCreateInfo) -> ^sdl.GPUTransferBuffer {
	options := MTL.ResourceOptions{.CPUCacheModeWriteCombined} if info.usage == .UPLOAD else MTL.ResourceStorageModeShared
	b := mtl_buffer_make(info.size, options)
	if b == nil do log.errorf("Metal: a %d byte transfer buffer could not be made", info.size)
	return (^sdl.GPUTransferBuffer)(b)
}

// Frees what of a released buffer the GPU no longer uses, and the buffer with its last
// backing.
mtl_buffer_reap :: proc(b: ^Mtl_Buffer) {
	if !b.released do return
	for i := 0; i < len(b.backings); {
		backing := b.backings[i]
		if backing.refs > 0 {
			i += 1
			continue
		}
		NS.release(backing.buffer)
		free(backing)
		unordered_remove(&b.backings, i)
	}
	if len(b.backings) == 0 {
		delete(b.backings)
		free(b)
	}
}

mtl_release_buffer :: proc(device: ^sdl.GPUDevice, buffer: ^sdl.GPUBuffer) {
	b := (^Mtl_Buffer)(buffer)
	if b == nil do return
	b.released = true
	mtl_buffer_reap(b)
}

mtl_release_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {
	mtl_release_buffer(device, (^sdl.GPUBuffer)(transfer_buffer))
}

// Points `b` at a backing no command buffer uses, making one if every backing is in use.
mtl_buffer_cycle :: proc(b: ^Mtl_Buffer) {
	for backing in b.backings {
		if backing.refs == 0 {
			b.active = backing
			return
		}
	}
	NS.scoped_autoreleasepool()
	if backing := mtl_buffer_backing_make(b); backing != nil do b.active = backing
}

// The backing a write goes to: SDL_GPU cycles a buffer only when the GPU may still use it.
mtl_buffer_for_write :: proc(b: ^Mtl_Buffer, cycle: bool) -> ^Mtl_Buffer_Backing {
	if cycle && b.active.refs > 0 do mtl_buffer_cycle(b)
	return b.active
}

mtl_map_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer, cycle: bool) -> rawptr {
	b := (^Mtl_Buffer)(transfer_buffer)
	return MTL.Buffer_contentsPointer(mtl_buffer_for_write(b, cycle).buffer)
}

// Shared memory needs no flush on Apple silicon.
mtl_unmap_transfer_buffer :: proc(device: ^sdl.GPUDevice, transfer_buffer: ^sdl.GPUTransferBuffer) {}

// ---- Textures -----------------------------------------------------------------------

@(private = "file")
mtl_texture_backing_make :: proc(t: ^Mtl_Texture) -> ^Mtl_Texture_Backing {
	NS.scoped_autoreleasepool()
	info := &t.info
	desc := MTL.TextureDescriptor_init(MTL.TextureDescriptor_alloc())
	defer NS.release(desc)
	multisample := info.sample_count != ._1
	MTL.TextureDescriptor_setTextureType(desc, .Type2DMultisample if multisample else .Type2D)
	MTL.TextureDescriptor_setPixelFormat(desc, mtl_pixel_format(info.format))
	MTL.TextureDescriptor_setWidth(desc, NS.UInteger(info.width))
	MTL.TextureDescriptor_setHeight(desc, NS.UInteger(info.height))
	MTL.TextureDescriptor_setDepth(desc, 1)
	MTL.TextureDescriptor_setMipmapLevelCount(desc, NS.UInteger(info.num_levels))
	MTL.TextureDescriptor_setSampleCount(desc, mtl_samples(info.sample_count))
	MTL.TextureDescriptor_setArrayLength(desc, 1)
	MTL.TextureDescriptor_setStorageMode(desc, .Memoryless if t.transient else .Private)
	usage: MTL.TextureUsage
	if info.usage & {.COLOR_TARGET, .DEPTH_STENCIL_TARGET} != {} do usage += {.RenderTarget}
	if info.usage & {.SAMPLER, .GRAPHICS_STORAGE_READ, .COMPUTE_STORAGE_READ} != {} do usage += {.ShaderRead}
	if info.usage & {.COMPUTE_STORAGE_WRITE, .COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE} != {} do usage += {.ShaderWrite}
	MTL.TextureDescriptor_setUsage(desc, usage)
	texture := MTL.Device_newTextureWithDescriptor(mtl_state.device, desc)
	if texture == nil do return nil
	backing := new(Mtl_Texture_Backing)
	backing.texture, backing.owner = texture, t
	mtl_name(texture, t.name)
	append(&t.backings, backing)
	return backing
}

mtl_create_texture :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUTextureCreateInfo) -> ^sdl.GPUTexture {
	return mtl_texture_make(info, false)
}

// Memoryless: the texture lives in tile memory for its pass alone, which every Apple GPU
// offers; its pass must neither load nor store it (transient.odin checks).
mtl_create_texture_transient :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUTextureCreateInfo) -> ^sdl.GPUTexture {
	return mtl_texture_make(info, true)
}

@(private = "file")
mtl_texture_make :: proc(info: sdl.GPUTextureCreateInfo, transient: bool) -> ^sdl.GPUTexture {
	if info.type != .D2 || info.layer_count_or_depth > 1 {
		log.errorf("Metal: only 2D textures are supported (asked for %v)", info.type)
		return nil
	}
	if mtl_pixel_format(info.format) == .Invalid {
		log.errorf("Metal: the %v format is not offered", info.format)
		return nil
	}
	t := new(Mtl_Texture)
	t.info = info
	t.transient = transient
	t.active = mtl_texture_backing_make(t)
	if t.active == nil {
		log.errorf("Metal: a %dx%d %v texture could not be made", info.width, info.height, info.format)
		delete(t.backings)
		free(t)
		return nil
	}
	return (^sdl.GPUTexture)(t)
}

mtl_texture_reap :: proc(t: ^Mtl_Texture) {
	if !t.released || t.swapchain do return
	for i := 0; i < len(t.backings); {
		backing := t.backings[i]
		if backing.refs > 0 {
			i += 1
			continue
		}
		NS.release(backing.texture)
		free(backing)
		unordered_remove(&t.backings, i)
	}
	if len(t.backings) == 0 {
		delete(t.backings)
		free(t)
	}
}

mtl_release_texture :: proc(device: ^sdl.GPUDevice, texture: ^sdl.GPUTexture) {
	t := (^Mtl_Texture)(texture)
	if t == nil do return
	t.released = true
	mtl_texture_reap(t)
}

// The backing a write goes to: SDL_GPU cycles a texture whenever asked, to the first
// backing no command buffer uses (which may be the active one), making one if all are busy.
mtl_texture_for_write :: proc(t: ^Mtl_Texture, cycle: bool) -> ^Mtl_Texture_Backing {
	if !cycle || t.swapchain do return t.active
	for backing in t.backings {
		if backing.refs == 0 {
			t.active = backing
			return backing
		}
	}
	if backing := mtl_texture_backing_make(t); backing != nil do t.active = backing
	return t.active
}

// ---- Samplers and shaders -----------------------------------------------------------

// A sampler handle is the Metal sampler itself.
mtl_create_sampler :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUSamplerCreateInfo) -> ^sdl.GPUSampler {
	NS.scoped_autoreleasepool()
	filter :: proc(f: sdl.GPUFilter) -> MTL.SamplerMinMagFilter {return .Linear if f == .LINEAR else .Nearest}
	address :: proc(a: sdl.GPUSamplerAddressMode) -> MTL.SamplerAddressMode {
		switch a {
		case .REPEAT:          return .Repeat
		case .MIRRORED_REPEAT: return .MirrorRepeat
		case .CLAMP_TO_EDGE:   return .ClampToEdge
		}
		return .Repeat
	}
	desc := MTL.SamplerDescriptor_init(MTL.SamplerDescriptor_alloc())
	defer NS.release(desc)
	MTL.SamplerDescriptor_setSAddressMode(desc, address(info.address_mode_u))
	MTL.SamplerDescriptor_setTAddressMode(desc, address(info.address_mode_v))
	MTL.SamplerDescriptor_setRAddressMode(desc, address(info.address_mode_w))
	MTL.SamplerDescriptor_setMinFilter(desc, filter(info.min_filter))
	MTL.SamplerDescriptor_setMagFilter(desc, filter(info.mag_filter))
	MTL.SamplerDescriptor_setMipFilter(desc, .Linear if info.mipmap_mode == .LINEAR else .Nearest)
	MTL.SamplerDescriptor_setLodMinClamp(desc, info.min_lod)
	MTL.SamplerDescriptor_setLodMaxClamp(desc, info.max_lod)
	MTL.SamplerDescriptor_setMaxAnisotropy(desc, NS.UInteger(info.max_anisotropy) if info.enable_anisotropy else 1)
	MTL.SamplerDescriptor_setCompareFunction(desc, mtl_compare(info.compare_op) if info.enable_compare else .Always)
	sampler := MTL.Device_newSamplerState(mtl_state.device, desc)
	if sampler == nil do sdl.SetError("Metal: the sampler could not be made")
	return (^sdl.GPUSampler)(sampler)
}

mtl_release_sampler :: proc(device: ^sdl.GPUDevice, sampler: ^sdl.GPUSampler) {
	if sampler != nil do NS.release((^MTL.SamplerState)(sampler))
}

// Compiles Metal source into a library and finds its entry point; nil, nil (with SDL's error
// set) when either fails. As SDL_GPU does, with Metal's default options (fast maths) unless
// `exact`, which turns fast maths off: divisions, square roots and the rest are then
// IEEE 754's, as SPIR-V's are under `-fp-mode precise` (gpu_create_compute_pipeline_exact).
@(private = "file")
mtl_compile :: proc(code: []u8, entrypoint: cstring, exact: bool) -> (^MTL.Library, ^MTL.Function) {
	options: ^MTL.CompileOptions
	if exact {
		options = MTL.CompileOptions_init(MTL.CompileOptions_alloc())
		MTL.CompileOptions_setFastMathEnabled(options, false)
	}
	defer if options != nil do NS.release(options)
	library, err := MTL.Device_newLibraryWithSource(mtl_state.device, mtl_string(string(code)), options)
	if library == nil {
		log.errorf("Metal: a shader did not compile: %s", mtl_error_text(err))
		sdl.SetError("Metal: a shader did not compile")
		return nil, nil
	}
	entry := string(entrypoint) if entrypoint != nil else "main0"
	function := MTL.Library_newFunctionWithName(library, mtl_string(entry))
	if function == nil {
		NS.release(library)
		log.errorf("Metal: the shader has no function %s", entry)
		sdl.SetError("Metal: the shader's entry point is missing")
		return nil, nil
	}
	return library, function
}

mtl_create_shader :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUShaderCreateInfo) -> ^sdl.GPUShader {
	NS.scoped_autoreleasepool()
	if .MSL not_in info.format {
		sdl.SetError("Metal: shaders must be Metal source")
		return nil
	}
	library, function := mtl_compile(info.code[:info.code_size], info.entrypoint, false)
	if function == nil do return nil
	s := new(Mtl_Shader)
	s.library, s.function, s.stage = library, function, info.stage
	s.counts = {info.num_samplers, info.num_storage_textures, info.num_storage_buffers, info.num_uniform_buffers}
	return (^sdl.GPUShader)(s)
}

// A shader is only read while pipelines are made from it, so it goes at once.
mtl_release_shader :: proc(device: ^sdl.GPUDevice, shader: ^sdl.GPUShader) {
	s := (^Mtl_Shader)(shader)
	if s == nil do return
	NS.release(s.function)
	NS.release(s.library)
	free(s)
}

// ---- Pipelines ----------------------------------------------------------------------

mtl_compare :: proc(op: sdl.GPUCompareOp) -> MTL.CompareFunction {
	switch op {
	case .INVALID, .NEVER:  return .Never
	case .LESS:             return .Less
	case .EQUAL:            return .Equal
	case .LESS_OR_EQUAL:    return .LessEqual
	case .GREATER:          return .Greater
	case .NOT_EQUAL:        return .NotEqual
	case .GREATER_OR_EQUAL: return .GreaterEqual
	case .ALWAYS:           return .Always
	}
	return .Never
}

@(private = "file")
mtl_blend_factor :: proc(f: sdl.GPUBlendFactor) -> MTL.BlendFactor {
	switch f {
	case .INVALID, .ZERO:           return .Zero
	case .ONE:                      return .One
	case .SRC_COLOR:                return .SourceColor
	case .ONE_MINUS_SRC_COLOR:      return .OneMinusSourceColor
	case .DST_COLOR:                return .DestinationColor
	case .ONE_MINUS_DST_COLOR:      return .OneMinusDestinationColor
	case .SRC_ALPHA:                return .SourceAlpha
	case .ONE_MINUS_SRC_ALPHA:      return .OneMinusSourceAlpha
	case .DST_ALPHA:                return .DestinationAlpha
	case .ONE_MINUS_DST_ALPHA:      return .OneMinusDestinationAlpha
	case .CONSTANT_COLOR:           return .BlendColor
	case .ONE_MINUS_CONSTANT_COLOR: return .OneMinusBlendColor
	case .SRC_ALPHA_SATURATE:       return .SourceAlphaSaturated
	}
	return .Zero
}

@(private = "file")
mtl_blend_op :: proc(op: sdl.GPUBlendOp) -> MTL.BlendOperation {
	switch op {
	case .INVALID, .ADD:    return .Add
	case .SUBTRACT:         return .Subtract
	case .REVERSE_SUBTRACT: return .ReverseSubtract
	case .MIN:              return .Min
	case .MAX:              return .Max
	}
	return .Add
}

@(private = "file")
mtl_stencil_op :: proc(op: sdl.GPUStencilOp) -> MTL.StencilOperation {
	switch op {
	case .INVALID, .KEEP:      return .Keep
	case .ZERO:                return .Zero
	case .REPLACE:             return .Replace
	case .INCREMENT_AND_CLAMP: return .IncrementClamp
	case .DECREMENT_AND_CLAMP: return .DecrementClamp
	case .INVERT:              return .Invert
	case .INCREMENT_AND_WRAP:  return .IncrementWrap
	case .DECREMENT_AND_WRAP:  return .DecrementWrap
	}
	return .Keep
}

@(private = "file")
mtl_vertex_format :: proc(f: sdl.GPUVertexElementFormat) -> MTL.VertexFormat {
	#partial switch f {
	case .INT:          return .Int
	case .INT2:         return .Int2
	case .INT3:         return .Int3
	case .INT4:         return .Int4
	case .UINT:         return .UInt
	case .UINT2:        return .UInt2
	case .UINT3:        return .UInt3
	case .UINT4:        return .UInt4
	case .FLOAT:        return .Float
	case .FLOAT2:       return .Float2
	case .FLOAT3:       return .Float3
	case .FLOAT4:       return .Float4
	case .UBYTE4:       return .UChar4
	case .UBYTE4_NORM:  return .UChar4Normalized
	case .BYTE4_NORM:   return .Char4Normalized
	case .SHORT2_NORM:  return .Short2Normalized
	case .SHORT4_NORM:  return .Short4Normalized
	case .USHORT2_NORM: return .UShort2Normalized
	case .USHORT4_NORM: return .UShort4Normalized
	case .HALF2:        return .Half2
	case .HALF4:        return .Half4
	}
	return .Invalid
}

// SDL names the channels red first; Metal's mask counts from alpha.
@(private = "file")
mtl_write_mask :: proc(mask: sdl.GPUColorComponentFlags) -> MTL.ColorWriteMask {
	out: MTL.ColorWriteMask
	if .R in mask do out += {.Red}
	if .G in mask do out += {.Green}
	if .B in mask do out += {.Blue}
	if .A in mask do out += {.Alpha}
	return out
}

@(private = "file")
mtl_stencil :: proc(s: sdl.GPUStencilOpState, ds: sdl.GPUDepthStencilState) -> ^MTL.StencilDescriptor {
	desc := MTL.StencilDescriptor_init(MTL.StencilDescriptor_alloc())
	MTL.StencilDescriptor_setStencilCompareFunction(desc, mtl_compare(s.compare_op))
	MTL.StencilDescriptor_setStencilFailureOperation(desc, mtl_stencil_op(s.fail_op))
	MTL.StencilDescriptor_setDepthStencilPassOperation(desc, mtl_stencil_op(s.pass_op))
	MTL.StencilDescriptor_setDepthFailureOperation(desc, mtl_stencil_op(s.depth_fail_op))
	MTL.StencilDescriptor_setReadMask(desc, u32(ds.compare_mask))
	MTL.StencilDescriptor_setWriteMask(desc, u32(ds.write_mask))
	return desc
}

// The depth-stencil state SDL_GPU makes for a pipeline with a depth target: a depth test
// that is off compares Always and writes nothing, as on the other APIs.
@(private = "file")
mtl_depth_stencil_state :: proc(ds: sdl.GPUDepthStencilState) -> ^MTL.DepthStencilState {
	desc := MTL.DepthStencilDescriptor_init(MTL.DepthStencilDescriptor_alloc())
	defer NS.release(desc)
	if ds.enable_stencil_test {
		front := mtl_stencil(ds.front_stencil_state, ds)
		back := mtl_stencil(ds.back_stencil_state, ds)
		MTL.DepthStencilDescriptor_setFrontFaceStencil(desc, front)
		MTL.DepthStencilDescriptor_setBackFaceStencil(desc, back)
		NS.release(front)
		NS.release(back)
	}
	MTL.DepthStencilDescriptor_setDepthCompareFunction(desc, mtl_compare(ds.compare_op) if ds.enable_depth_test else .Always)
	MTL.DepthStencilDescriptor_setDepthWriteEnabled(desc, ds.enable_depth_write && ds.enable_depth_test)
	return MTL.Device_newDepthStencilState(mtl_state.device, desc)
}

mtl_create_graphics_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUGraphicsPipelineCreateInfo) -> ^sdl.GPUGraphicsPipeline {
	NS.scoped_autoreleasepool()
	vertex, fragment := (^Mtl_Shader)(info.vertex_shader), (^Mtl_Shader)(info.fragment_shader)
	if vertex == nil || fragment == nil do return nil
	desc := MTL.RenderPipelineDescriptor_init(MTL.RenderPipelineDescriptor_alloc())
	defer NS.release(desc)

	ti := info.target_info
	colors := MTL.RenderPipelineDescriptor_colorAttachments(desc)
	for i in 0 ..< ti.num_color_targets {
		d := ti.color_target_descriptions[i]
		b := d.blend_state
		mask := b.color_write_mask if b.enable_color_write_mask else {.R, .G, .B, .A}
		a := MTL.RenderPipelineColorAttachmentDescriptorArray_object(colors, NS.UInteger(i))
		MTL.RenderPipelineColorAttachmentDescriptor_setPixelFormat(a, mtl_pixel_format(d.format))
		MTL.RenderPipelineColorAttachmentDescriptor_setWriteMask(a, mtl_write_mask(mask))
		MTL.RenderPipelineColorAttachmentDescriptor_setBlendingEnabled(a, b.enable_blend)
		MTL.RenderPipelineColorAttachmentDescriptor_setRgbBlendOperation(a, mtl_blend_op(b.color_blend_op))
		MTL.RenderPipelineColorAttachmentDescriptor_setAlphaBlendOperation(a, mtl_blend_op(b.alpha_blend_op))
		MTL.RenderPipelineColorAttachmentDescriptor_setSourceRGBBlendFactor(a, mtl_blend_factor(b.src_color_blendfactor))
		MTL.RenderPipelineColorAttachmentDescriptor_setSourceAlphaBlendFactor(a, mtl_blend_factor(b.src_alpha_blendfactor))
		MTL.RenderPipelineColorAttachmentDescriptor_setDestinationRGBBlendFactor(a, mtl_blend_factor(b.dst_color_blendfactor))
		MTL.RenderPipelineColorAttachmentDescriptor_setDestinationAlphaBlendFactor(a, mtl_blend_factor(b.dst_alpha_blendfactor))
	}
	MTL.RenderPipelineDescriptor_setRasterSampleCount(desc, mtl_samples(info.multisample_state.sample_count))
	MTL.RenderPipelineDescriptor_setAlphaToCoverageEnabled(desc, info.multisample_state.enable_alpha_to_coverage)

	depth_stencil: ^MTL.DepthStencilState
	if ti.has_depth_stencil_target {
		format := mtl_pixel_format(ti.depth_stencil_format)
		MTL.RenderPipelineDescriptor_setDepthAttachmentPixelFormat(desc, format)
		if mtl_is_stencil(ti.depth_stencil_format) do MTL.RenderPipelineDescriptor_setStencilAttachmentPixelFormat(desc, format)
		depth_stencil = mtl_depth_stencil_state(info.depth_stencil_state)
		if depth_stencil == nil {
			sdl.SetError("Metal: the depth-stencil state could not be made")
			return nil
		}
	}

	MTL.RenderPipelineDescriptor_setVertexFunction(desc, vertex.function)
	MTL.RenderPipelineDescriptor_setFragmentFunction(desc, fragment.function)

	vi := info.vertex_input_state
	if vi.num_vertex_buffers > 0 {
		vd := MTL.VertexDescriptor_vertexDescriptor()
		attributes := MTL.VertexDescriptor_attributes(vd)
		for i in 0 ..< vi.num_vertex_attributes {
			a := vi.vertex_attributes[i]
			ad := MTL.VertexAttributeDescriptorArray_object(attributes, NS.UInteger(a.location))
			MTL.VertexAttributeDescriptor_setFormat(ad, mtl_vertex_format(a.format))
			MTL.VertexAttributeDescriptor_setOffset(ad, NS.UInteger(a.offset))
			MTL.VertexAttributeDescriptor_setBufferIndex(ad, NS.UInteger(MTL_FIRST_VERTEX_BUFFER + a.buffer_slot))
		}
		layouts := MTL.VertexDescriptor_layouts(vd)
		for i in 0 ..< vi.num_vertex_buffers {
			b := vi.vertex_buffer_descriptions[i]
			ld := MTL.VertexBufferLayoutDescriptorArray_object(layouts, NS.UInteger(MTL_FIRST_VERTEX_BUFFER + b.slot))
			MTL.VertexBufferLayoutDescriptor_setStepFunction(ld, .PerInstance if b.input_rate == .INSTANCE else .PerVertex)
			MTL.VertexBufferLayoutDescriptor_setStepRate(ld, 1)
			MTL.VertexBufferLayoutDescriptor_setStride(ld, NS.UInteger(b.pitch))
		}
		MTL.RenderPipelineDescriptor_setVertexDescriptor(desc, vd)
	}

	state, err := MTL.Device_newRenderPipelineStateWithDescriptor(mtl_state.device, desc)
	if state == nil {
		if depth_stencil != nil do NS.release(depth_stencil)
		log.errorf("Metal: a render pipeline could not be made: %s", mtl_error_text(err))
		sdl.SetError("Metal: a render pipeline could not be made")
		return nil
	}
	p := new(Mtl_Pipeline)
	p.state, p.depth_stencil, p.raster = state, depth_stencil, info.rasterizer_state
	switch info.primitive_type {
	case .TRIANGLELIST:  p.primitive = .Triangle
	case .TRIANGLESTRIP: p.primitive = .TriangleStrip
	case .LINELIST:      p.primitive = .Line
	case .LINESTRIP:     p.primitive = .LineStrip
	case .POINTLIST:     p.primitive = .Point
	}
	copy(p.counts[0:4], vertex.counts[:])
	copy(p.counts[4:8], fragment.counts[:])
	return (^sdl.GPUGraphicsPipeline)(p)
}

mtl_release_graphics_pipeline :: proc(device: ^sdl.GPUDevice, pipeline: ^sdl.GPUGraphicsPipeline) {
	p := (^Mtl_Pipeline)(pipeline)
	if p == nil do return
	NS.release(p.state)
	if p.depth_stencil != nil do NS.release(p.depth_stencil)
	free(p)
}

// Made as SDL_GPU's Metal backend makes it, keeping the counts its binding slots follow:
// sampled textures and samplers from 0, then the read-only and read-write storage textures;
// uniform buffers from buffer 0, then the read-only and read-write storage buffers.
mtl_create_compute_pipeline :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	return mtl_compute_pipeline_make(info, false)
}

// The same with fast maths off, for kernels whose result must equal the CPU's.
mtl_create_compute_pipeline_exact :: proc(device: ^sdl.GPUDevice, #by_ptr info: sdl.GPUComputePipelineCreateInfo) -> ^sdl.GPUComputePipeline {
	return mtl_compute_pipeline_make(info, true)
}

@(private = "file")
mtl_compute_pipeline_make :: proc(info: sdl.GPUComputePipelineCreateInfo, exact: bool) -> ^sdl.GPUComputePipeline {
	NS.scoped_autoreleasepool()
	if .MSL not_in info.format {
		sdl.SetError("Metal: shaders must be Metal source")
		return nil
	}
	if info.num_readwrite_storage_textures > MTL_COMPUTE_WRITES || info.num_readwrite_storage_buffers > MTL_COMPUTE_WRITES || info.num_readonly_storage_buffers > MTL_STORAGE_BUFFERS || info.num_samplers > MTL_SAMPLERS || info.num_uniform_buffers > 4 {
		sdl.SetError("Metal: a compute pipeline binds more than SDL_GPU allows")
		return nil
	}
	library, function := mtl_compile(info.code[:info.code_size], info.entrypoint, exact)
	if function == nil do return nil
	defer {
		NS.release(function)
		NS.release(library)
	}
	desc := MTL.ComputePipelineDescriptor_init(MTL.ComputePipelineDescriptor_alloc())
	defer NS.release(desc)
	MTL.ComputePipelineDescriptor_setComputeFunction(desc, function)
	state, err := MTL.Device_newComputePipelineStateWithDescriptorWithReflection(mtl_state.device, desc, {}, nil)
	if state == nil {
		log.errorf("Metal: a compute pipeline could not be made: %s", mtl_error_text(err))
		sdl.SetError("Metal: a compute pipeline could not be made")
		return nil
	}
	// A dispatch of more threads a group than the kernel can run is dropped by Metal, so a
	// pipeline that asks for them is refused here and its feature stays off.
	threads := info.threadcount_x * info.threadcount_y * info.threadcount_z
	if NS.UInteger(threads) > MTL.ComputePipelineState_maxTotalThreadsPerThreadgroup(state) {
		NS.release(state)
		log.errorf("Metal: a compute kernel cannot run %d threads a group", threads)
		sdl.SetError("Metal: too many threads a group for this kernel")
		return nil
	}
	p := new(Mtl_Compute_Pipeline)
	p.state = state
	p.samplers, p.readonly_textures, p.readwrite_textures = info.num_samplers, info.num_readonly_storage_textures, info.num_readwrite_storage_textures
	p.uniforms, p.readonly_buffers, p.readwrite_buffers = info.num_uniform_buffers, info.num_readonly_storage_buffers, info.num_readwrite_storage_buffers
	p.threads = {NS.Integer(info.threadcount_x), NS.Integer(info.threadcount_y), NS.Integer(info.threadcount_z)}
	return (^sdl.GPUComputePipeline)(p)
}

// Released at once: a command buffer keeps the pipeline state it used alive until it ends.
mtl_release_compute_pipeline :: proc(device: ^sdl.GPUDevice, pipeline: ^sdl.GPUComputePipeline) {
	p := (^Mtl_Compute_Pipeline)(pipeline)
	if p == nil do return
	NS.release(p.state)
	free(p)
}
