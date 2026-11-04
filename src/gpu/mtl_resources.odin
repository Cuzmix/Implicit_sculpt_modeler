#+build darwin
package gpu

import "core:log"
import "core:strconv"
import "core:strings"

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

// Buffers, textures, samplers, shaders and pipelines of the Metal backend. As in the Vulkan
// backend, a buffer or texture handle the app holds is a container: a write may "cycle" it,
// swapping in another backing object (made on demand, reused once idle) so the write never
// waits for the GPU. Each backing counts the command buffers that use it, and a released
// resource frees a backing once nothing uses it. Samplers and pipelines go at once, since a
// Metal command buffer keeps what it uses alive until it finishes.

// Vertex buffers sit above the uniform and storage buffers of the vertex stage, which
// scripts/shaders_msl.py keeps below this slot.
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
	info:      Texture_Desc,
	backings:  [dynamic]^Mtl_Texture_Backing,
	active:    ^Mtl_Texture_Backing,
	swapchain: bool, // a window's drawable: never cycled or freed here
	transient: bool, // memoryless, every backing (create_texture_transient)
	released:  bool,
	name:      cstring, // for Xcode's GPU capture, given to every backing; a literal, never freed
}

Mtl_Shader :: struct {
	library:  ^MTL.Library,
	function: ^MTL.Function,
	stage:    Shader_Stage,
	counts:   [4]u32, // samplers, storage textures, storage buffers, uniform buffers
	slots:    Mtl_Slots,
}

Mtl_Pipeline :: struct {
	state:         ^MTL.RenderPipelineState,
	depth_stencil: ^MTL.DepthStencilState, // nil without a depth target
	raster:        Rasterizer_State,
	primitive:     MTL.PrimitiveType,
	counts:        [8]u32, // the vertex shader's four counts, then the fragment shader's
	// Where each stage's bindings go (Mtl_Slots); a graphics stage uses the sampler,
	// read-only texture and buffer and uniform slots.
	vertex_slots:   Mtl_Slots,
	fragment_slots: Mtl_Slots,
}

// The limits per compute pipeline, which size the command buffer's binding arrays:
// SDL_GPU's, but for twice its eight read-only buffers, which the sculpt dab kernels
// need (sculpt_gpu.odin SCULPT_STORAGE_BUFFERS; uniforms, then read-only, then
// read-write buffers take 15 of Metal's 31 buffer slots), as the Vulkan backend's
// VK_COMPUTE_STORAGE_BUFFERS.
MTL_SAMPLERS :: 16
MTL_STORAGE_BUFFERS :: 16
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
	slots:              Mtl_Slots,
}

// Where each of a shader's or kernel's bindings goes, in the renderer's order of each kind
// (its SPIR-V set and binding). slangc numbers Metal's slots its own way and the shader's
// Metal source names them on its second line (scripts/shaders_msl.py, mtl_slots_parse).
Mtl_Slots :: struct {
	samplers:    [MTL_SAMPLERS][2]u32, // each sampled texture's texture slot, then its sampler's
	ro_textures: [MTL_SAMPLERS]u32,
	rw_textures: [MTL_COMPUTE_WRITES]u32,
	ro_buffers:  [MTL_STORAGE_BUFFERS]u32,
	rw_buffers:  [MTL_COMPUTE_WRITES]u32,
	uniforms:    [4]u32,
	accel:       i32, // the buffer slot of the top-level structure traced against; -1 for none
	// How many of each the table names: samplers, read-only and read-write textures,
	// read-only and read-write buffers, uniform blocks.
	counts:      [6]u32,
}

// Reads a shader's slot table, the second line of its Metal source:
// "// slots s=T:S,T:S rt=T wt=T rb=B wb=B u=B a=B".
mtl_slots_parse :: proc(code: string) -> (slots: Mtl_Slots, ok: bool) {
	slots.accel = -1
	text := code
	_ = strings.split_lines_iterator(&text) or_return
	line := strings.split_lines_iterator(&text) or_return
	fields := strings.trim_prefix(line, "// slots ")
	if len(fields) == len(line) do return
	for field in strings.split_iterator(&fields, " ") {
		key, _, values := strings.partition(field, "=")
		n := 0
		list := values
		for value in strings.split_iterator(&list, ",") {
			if key == "s" {
				t, _, s := strings.partition(value, ":")
				tex, tok := strconv.parse_int(t)
				samp, sok := strconv.parse_int(s)
				if !tok || !sok || n >= MTL_SAMPLERS do return
				slots.samplers[n] = {u32(tex), u32(samp)}
			} else {
				at, vok := strconv.parse_int(value)
				if !vok do return
				switch key {
				case "rt": if n >= MTL_SAMPLERS do return; slots.ro_textures[n] = u32(at)
				case "wt": if n >= MTL_COMPUTE_WRITES do return; slots.rw_textures[n] = u32(at)
				case "rb": if n >= MTL_STORAGE_BUFFERS do return; slots.ro_buffers[n] = u32(at)
				case "wb": if n >= MTL_COMPUTE_WRITES do return; slots.rw_buffers[n] = u32(at)
				case "u":  if n >= 4 do return; slots.uniforms[n] = u32(at)
				case "a":  if n >= 1 do return; slots.accel = i32(at)
				case:      return
				}
			}
			n += 1
		}
		switch key {
		case "s":  slots.counts[0] = u32(n)
		case "rt": slots.counts[1] = u32(n)
		case "wt": slots.counts[2] = u32(n)
		case "rb": slots.counts[3] = u32(n)
		case "wb": slots.counts[4] = u32(n)
		case "u":  slots.counts[5] = u32(n)
		}
	}
	return slots, true
}

// The slot table of `code`, which must name exactly the bindings `counts` gives (the
// counts' order of Mtl_Slots.counts); false, with the error set, when it does not.
@(private = "file")
mtl_slots_for :: proc(code: string, counts: [6]u32) -> (Mtl_Slots, bool) {
	slots, ok := mtl_slots_parse(code)
	if !ok || slots.counts != counts {
		log.errorf("Metal: a shader's slot table does not match its description (%v against %v)", slots.counts, counts)
		fail(.Invalid, "Metal: a shader's slot table does not match its description")
		return {}, false
	}
	return slots, true
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

mtl_set_buffer_name :: proc(buffer: Buffer, text: cstring) {
	b := (^Mtl_Buffer)(object(buffer))
	b.name = text
	for backing in b.backings do mtl_name(backing.buffer, text)
}

mtl_set_texture_name :: proc(texture: Texture, text: cstring) {
	t := (^Mtl_Texture)(object(texture))
	t.name = text
	for backing in t.backings do mtl_name(backing.texture, text)
}

mtl_create_buffer :: proc(#by_ptr info: Buffer_Desc) -> rawptr {
	b := mtl_buffer_make(info.size, {.StorageModePrivate})
	if b == nil do log.errorf("Metal: a %d byte buffer could not be made", info.size)
	return b
}

// A device buffer in shared memory, filled by the CPU before its first use, where the GPU
// shares the CPU's memory (every Apple silicon GPU); nil elsewhere. A cycle of it makes
// another shared backing, which on unified memory costs what a private one would.
mtl_create_buffer_mapped :: proc(#by_ptr info: Buffer_Desc) -> (rawptr, rawptr) {
	if !MTL.Device_hasUnifiedMemory(mtl_state.device) do return nil, nil
	b := mtl_buffer_make(info.size, MTL.ResourceStorageModeShared)
	if b == nil do return nil, nil
	return b, MTL.Buffer_contentsPointer(b.active.buffer)
}

// Transfer buffers are shared memory the CPU maps in place; an upload buffer is only
// written by the CPU, so it is write-combined, as SDL_GPU makes it.
mtl_create_transfer_buffer :: proc(#by_ptr info: Transfer_Buffer_Desc) -> rawptr {
	options := MTL.ResourceOptions{.CPUCacheModeWriteCombined} if info.usage == .Upload else MTL.ResourceStorageModeShared
	b := mtl_buffer_make(info.size, options)
	if b == nil do log.errorf("Metal: a %d byte transfer buffer could not be made", info.size)
	return b
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

mtl_release_buffer :: proc(buffer: rawptr) {
	b := (^Mtl_Buffer)(buffer)
	if b == nil do return
	b.released = true
	mtl_buffer_reap(b)
}

mtl_release_transfer_buffer :: proc(transfer_buffer: rawptr) {
	mtl_release_buffer(transfer_buffer)
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

mtl_map_transfer_buffer :: proc(transfer_buffer: Transfer_Buffer, cycle: bool) -> rawptr {
	b := (^Mtl_Buffer)(object(transfer_buffer))
	return MTL.Buffer_contentsPointer(mtl_buffer_for_write(b, cycle).buffer)
}

// Shared memory needs no flush on Apple silicon.
mtl_unmap_transfer_buffer :: proc(transfer_buffer: Transfer_Buffer) {}

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
	if info.usage & {.Color_Target, .Depth_Target} != {} do usage += {.RenderTarget}
	if info.usage & {.Sampled, .Graphics_Storage_Read, .Storage_Read} != {} do usage += {.ShaderRead}
	if info.usage & {.Storage_Write, .Storage_Read_Write} != {} do usage += {.ShaderWrite}
	MTL.TextureDescriptor_setUsage(desc, usage)
	texture := MTL.Device_newTextureWithDescriptor(mtl_state.device, desc)
	if texture == nil do return nil
	backing := new(Mtl_Texture_Backing)
	backing.texture, backing.owner = texture, t
	mtl_name(texture, t.name)
	append(&t.backings, backing)
	return backing
}

mtl_create_texture :: proc(#by_ptr info: Texture_Desc) -> rawptr {
	return mtl_texture_make(info, false)
}

// Memoryless: the texture lives in tile memory for its pass alone, which every Apple GPU
// offers; its pass must neither load nor store it (transient.odin checks).
mtl_create_texture_transient :: proc(#by_ptr info: Texture_Desc) -> rawptr {
	return mtl_texture_make(info, true)
}

@(private = "file")
mtl_texture_make :: proc(info: Texture_Desc, transient: bool) -> rawptr {
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
	return t
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

mtl_release_texture :: proc(texture: rawptr) {
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
mtl_create_sampler :: proc(#by_ptr info: Sampler_Desc) -> rawptr {
	NS.scoped_autoreleasepool()
	filter :: proc(f: Filter) -> MTL.SamplerMinMagFilter {return .Linear if f == .Linear else .Nearest}
	address :: proc(a: Address_Mode) -> MTL.SamplerAddressMode {
		switch a {
		case .Repeat:          return .Repeat
		case .Mirrored_Repeat: return .MirrorRepeat
		case .Clamp_To_Edge:   return .ClampToEdge
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
	MTL.SamplerDescriptor_setMipFilter(desc, .Linear if info.mipmap_mode == .Linear else .Nearest)
	MTL.SamplerDescriptor_setLodMinClamp(desc, info.min_lod)
	MTL.SamplerDescriptor_setLodMaxClamp(desc, info.max_lod)
	MTL.SamplerDescriptor_setMaxAnisotropy(desc, NS.UInteger(info.max_anisotropy) if info.enable_anisotropy else 1)
	MTL.SamplerDescriptor_setCompareFunction(desc, mtl_compare(info.compare_op) if info.enable_compare else .Always)
	sampler := MTL.Device_newSamplerState(mtl_state.device, desc)
	if sampler == nil do fail(.Refused, "Metal: the sampler could not be made")
	return sampler
}

mtl_release_sampler :: proc(sampler: rawptr) {
	mtl_release_later(sampler, proc(object: rawptr) {NS.release((^MTL.SamplerState)(object))})
}

// Compiles Metal source into a library and finds its entry point; nil, nil (with SDL's error
// set) when either fails. As SDL_GPU does, with Metal's default options (fast maths) unless
// `exact`, which turns fast maths off: divisions, square roots and the rest are then
// IEEE 754's, as SPIR-V's are under `-fp-mode precise` (create_compute_pipeline_exact).
@(private = "file")
mtl_compile :: proc(code: string, entrypoint: cstring, exact: bool) -> (^MTL.Library, ^MTL.Function) {
	options: ^MTL.CompileOptions
	if exact {
		options = MTL.CompileOptions_init(MTL.CompileOptions_alloc())
		MTL.CompileOptions_setFastMathEnabled(options, false)
	}
	defer if options != nil do NS.release(options)
	library, err := MTL.Device_newLibraryWithSource(mtl_state.device, mtl_string(code), options)
	if library == nil {
		log.errorf("Metal: a shader did not compile: %s", mtl_error_text(err))
		fail(.Refused, "Metal: a shader did not compile")
		return nil, nil
	}
	entry := string(entrypoint) if entrypoint != nil else "main_0"
	function := MTL.Library_newFunctionWithName(library, mtl_string(entry))
	if function == nil {
		NS.release(library)
		log.errorf("Metal: the shader has no function %s", entry)
		fail(.Refused, "Metal: the shader's entry point is missing")
		return nil, nil
	}
	return library, function
}

mtl_create_shader :: proc(#by_ptr info: Shader_Desc) -> rawptr {
	NS.scoped_autoreleasepool()
	if info.format != .Msl {
		fail(.Invalid, "Metal: shaders must be Metal source")
		return nil
	}
	slots, ok := mtl_slots_for(info.code, {info.num_samplers, info.num_storage_textures, 0, info.num_storage_buffers, 0, info.num_uniform_buffers})
	if !ok do return nil
	library, function := mtl_compile(info.code, info.entrypoint, false)
	if function == nil do return nil
	s := new(Mtl_Shader)
	s.library, s.function, s.stage, s.slots = library, function, info.stage, slots
	s.counts = {info.num_samplers, info.num_storage_textures, info.num_storage_buffers, info.num_uniform_buffers}
	return s
}

// A shader is only read while pipelines are made from it, so it goes at once.
mtl_release_shader :: proc(shader: rawptr) {
	mtl_release_later(shader, proc(object: rawptr) {
		s := (^Mtl_Shader)(object)
		NS.release(s.function)
		NS.release(s.library)
		free(s)
	})
}

// ---- Pipelines ----------------------------------------------------------------------

mtl_compare :: proc(op: Compare_Op) -> MTL.CompareFunction {
	switch op {
	case .Invalid, .Never:  return .Never
	case .Less:             return .Less
	case .Equal:            return .Equal
	case .Less_Or_Equal:    return .LessEqual
	case .Greater:          return .Greater
	case .Not_Equal:        return .NotEqual
	case .Greater_Or_Equal: return .GreaterEqual
	case .Always:           return .Always
	}
	return .Never
}

@(private = "file")
mtl_blend_factor :: proc(f: Blend_Factor) -> MTL.BlendFactor {
	switch f {
	case .Invalid, .Zero:           return .Zero
	case .One:                      return .One
	case .Src_Color:                return .SourceColor
	case .One_Minus_Src_Color:      return .OneMinusSourceColor
	case .Dst_Color:                return .DestinationColor
	case .One_Minus_Dst_Color:      return .OneMinusDestinationColor
	case .Src_Alpha:                return .SourceAlpha
	case .One_Minus_Src_Alpha:      return .OneMinusSourceAlpha
	case .Dst_Alpha:                return .DestinationAlpha
	case .One_Minus_Dst_Alpha:      return .OneMinusDestinationAlpha
	case .Constant_Color:           return .BlendColor
	case .One_Minus_Constant_Color: return .OneMinusBlendColor
	case .Src_Alpha_Saturate:       return .SourceAlphaSaturated
	}
	return .Zero
}

@(private = "file")
mtl_blend_op :: proc(op: Blend_Op) -> MTL.BlendOperation {
	switch op {
	case .Invalid, .Add:    return .Add
	case .Subtract:         return .Subtract
	case .Reverse_Subtract: return .ReverseSubtract
	case .Min:              return .Min
	case .Max:              return .Max
	}
	return .Add
}

@(private = "file")
mtl_stencil_op :: proc(op: Stencil_Op) -> MTL.StencilOperation {
	switch op {
	case .Invalid, .Keep:      return .Keep
	case .Zero:                return .Zero
	case .Replace:             return .Replace
	case .Increment_And_Clamp: return .IncrementClamp
	case .Decrement_And_Clamp: return .DecrementClamp
	case .Invert:              return .Invert
	case .Increment_And_Wrap:  return .IncrementWrap
	case .Decrement_And_Wrap:  return .DecrementWrap
	}
	return .Keep
}

@(private = "file")
mtl_vertex_format :: proc(f: Vertex_Format) -> MTL.VertexFormat {
	#partial switch f {
	case .Int:          return .Int
	case .Int2:         return .Int2
	case .Int3:         return .Int3
	case .Int4:         return .Int4
	case .Uint:         return .UInt
	case .Uint2:        return .UInt2
	case .Uint3:        return .UInt3
	case .Uint4:        return .UInt4
	case .Float:        return .Float
	case .Float2:       return .Float2
	case .Float3:       return .Float3
	case .Float4:       return .Float4
	case .Ubyte4:       return .UChar4
	case .Ubyte4_Norm:  return .UChar4Normalized
	case .Byte4_Norm:   return .Char4Normalized
	case .Short2_Norm:  return .Short2Normalized
	case .Short4_Norm:  return .Short4Normalized
	case .Ushort2_Norm: return .UShort2Normalized
	case .Ushort4_Norm: return .UShort4Normalized
	case .Half2:        return .Half2
	case .Half4:        return .Half4
	}
	return .Invalid
}

// SDL names the channels red first; Metal's mask counts from alpha.
@(private = "file")
mtl_write_mask :: proc(mask: Color_Components) -> MTL.ColorWriteMask {
	out: MTL.ColorWriteMask
	if .R in mask do out += {.Red}
	if .G in mask do out += {.Green}
	if .B in mask do out += {.Blue}
	if .A in mask do out += {.Alpha}
	return out
}

@(private = "file")
mtl_stencil :: proc(s: Stencil_Op_State, ds: Depth_Stencil_State) -> ^MTL.StencilDescriptor {
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
mtl_depth_stencil_state :: proc(ds: Depth_Stencil_State) -> ^MTL.DepthStencilState {
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

mtl_create_graphics_pipeline :: proc(#by_ptr info: Graphics_Pipeline_Desc) -> rawptr {
	NS.scoped_autoreleasepool()
	vertex, fragment := (^Mtl_Shader)(object(info.vertex_shader)), (^Mtl_Shader)(object(info.fragment_shader))
	if vertex == nil || fragment == nil do return nil
	desc := MTL.RenderPipelineDescriptor_init(MTL.RenderPipelineDescriptor_alloc())
	defer NS.release(desc)

	ti := info.targets
	colors := MTL.RenderPipelineDescriptor_colorAttachments(desc)
	for d, i in ti.color_targets {
		b := d.blend_state
		mask := b.color_write_mask if b.enable_color_write_mask else Color_Components{.R, .G, .B, .A}
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

	depth_stencil: ^MTL.DepthStencilState
	if ti.has_depth_stencil_target {
		format := mtl_pixel_format(ti.depth_stencil_format)
		MTL.RenderPipelineDescriptor_setDepthAttachmentPixelFormat(desc, format)
		if mtl_is_stencil(ti.depth_stencil_format) do MTL.RenderPipelineDescriptor_setStencilAttachmentPixelFormat(desc, format)
		depth_stencil = mtl_depth_stencil_state(info.depth_stencil_state)
		if depth_stencil == nil {
			fail(.Refused, "Metal: the depth-stencil state could not be made")
			return nil
		}
	}

	MTL.RenderPipelineDescriptor_setVertexFunction(desc, vertex.function)
	MTL.RenderPipelineDescriptor_setFragmentFunction(desc, fragment.function)

	vi := info.vertex_input
	if len(vi.buffers) > 0 {
		vd := MTL.VertexDescriptor_vertexDescriptor()
		attributes := MTL.VertexDescriptor_attributes(vd)
		for a in vi.attributes {
			ad := MTL.VertexAttributeDescriptorArray_object(attributes, NS.UInteger(a.location))
			MTL.VertexAttributeDescriptor_setFormat(ad, mtl_vertex_format(a.format))
			MTL.VertexAttributeDescriptor_setOffset(ad, NS.UInteger(a.offset))
			MTL.VertexAttributeDescriptor_setBufferIndex(ad, NS.UInteger(MTL_FIRST_VERTEX_BUFFER + a.buffer_slot))
		}
		layouts := MTL.VertexDescriptor_layouts(vd)
		for b in vi.buffers {
			ld := MTL.VertexBufferLayoutDescriptorArray_object(layouts, NS.UInteger(MTL_FIRST_VERTEX_BUFFER + b.slot))
			MTL.VertexBufferLayoutDescriptor_setStepFunction(ld, .PerInstance if b.input_rate == .Instance else .PerVertex)
			MTL.VertexBufferLayoutDescriptor_setStepRate(ld, 1)
			MTL.VertexBufferLayoutDescriptor_setStride(ld, NS.UInteger(b.pitch))
		}
		MTL.RenderPipelineDescriptor_setVertexDescriptor(desc, vd)
	}

	state, err := MTL.Device_newRenderPipelineStateWithDescriptor(mtl_state.device, desc)
	if state == nil {
		if depth_stencil != nil do NS.release(depth_stencil)
		log.errorf("Metal: a render pipeline could not be made: %s", mtl_error_text(err))
		fail(.Refused, "Metal: a render pipeline could not be made")
		return nil
	}
	p := new(Mtl_Pipeline)
	p.state, p.depth_stencil, p.raster = state, depth_stencil, info.rasterizer_state
	switch info.primitive {
	case .Triangle_List:  p.primitive = .Triangle
	case .Triangle_Strip: p.primitive = .TriangleStrip
	case .Line_List:      p.primitive = .Line
	case .Line_Strip:     p.primitive = .LineStrip
	case .Point_List:     p.primitive = .Point
	}
	copy(p.counts[0:4], vertex.counts[:])
	copy(p.counts[4:8], fragment.counts[:])
	p.vertex_slots, p.fragment_slots = vertex.slots, fragment.slots
	return p
}

mtl_release_graphics_pipeline :: proc(pipeline: rawptr) {
	mtl_release_later(pipeline, proc(object: rawptr) {
		p := (^Mtl_Pipeline)(object)
		NS.release(p.state)
		if p.depth_stencil != nil do NS.release(p.depth_stencil)
		free(p)
	})
}

// Keeps the counts and the slot table its bindings go to (Mtl_Slots).
mtl_create_compute_pipeline :: proc(#by_ptr info: Compute_Pipeline_Desc) -> rawptr {
	return mtl_compute_pipeline_make(info, false)
}

// The same with fast maths off, for kernels whose result must equal the CPU's.
mtl_create_compute_pipeline_exact :: proc(#by_ptr info: Compute_Pipeline_Desc) -> rawptr {
	return mtl_compute_pipeline_make(info, true)
}

@(private = "file")
mtl_compute_pipeline_make :: proc(info: Compute_Pipeline_Desc, exact: bool) -> rawptr {
	NS.scoped_autoreleasepool()
	if info.format != .Msl {
		fail(.Invalid, "Metal: shaders must be Metal source")
		return nil
	}
	if info.num_readwrite_storage_textures > MTL_COMPUTE_WRITES || info.num_readwrite_storage_buffers > MTL_COMPUTE_WRITES || info.num_readonly_storage_buffers > MTL_STORAGE_BUFFERS || info.num_samplers > MTL_SAMPLERS || info.num_uniform_buffers > 4 {
		fail(.Unsupported, "Metal: a compute pipeline binds more than the Metal backend binds")
		return nil
	}
	slots, ok := mtl_slots_for(info.code, {info.num_samplers, info.num_readonly_storage_textures, info.num_readwrite_storage_textures, info.num_readonly_storage_buffers, info.num_readwrite_storage_buffers, info.num_uniform_buffers})
	if !ok do return nil
	library, function := mtl_compile(info.code, info.entrypoint, exact)
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
		fail(.Refused, "Metal: a compute pipeline could not be made")
		return nil
	}
	// A dispatch of more threads a group than the kernel can run is dropped by Metal, so a
	// pipeline that asks for them is refused here and its feature stays off.
	threads := info.threadcount_x * info.threadcount_y * info.threadcount_z
	if NS.UInteger(threads) > MTL.ComputePipelineState_maxTotalThreadsPerThreadgroup(state) {
		NS.release(state)
		log.errorf("Metal: a compute kernel cannot run %d threads a group", threads)
		fail(.Unsupported, "Metal: too many threads a group for this kernel")
		return nil
	}
	p := new(Mtl_Compute_Pipeline)
	p.state = state
	p.samplers, p.readonly_textures, p.readwrite_textures = info.num_samplers, info.num_readonly_storage_textures, info.num_readwrite_storage_textures
	p.uniforms, p.readonly_buffers, p.readwrite_buffers = info.num_uniform_buffers, info.num_readonly_storage_buffers, info.num_readwrite_storage_buffers
	p.threads = {NS.Integer(info.threadcount_x), NS.Integer(info.threadcount_y), NS.Integer(info.threadcount_z)}
	p.slots = slots
	return p
}

// Released at once: a command buffer keeps the pipeline state it used alive until it ends.
mtl_release_compute_pipeline :: proc(pipeline: rawptr) {
	mtl_release_later(pipeline, proc(object: rawptr) {
		p := (^Mtl_Compute_Pipeline)(object)
		NS.release(p.state)
		free(p)
	})
}
