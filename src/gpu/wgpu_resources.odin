#+build js
package gpu

import "base:runtime"
import "core:strconv"
import "core:strings"

import wgpu "vendor:wgpu"

// Buffers, textures, samplers, shaders and pipelines of the WebGPU backend. A handle the
// app holds points at one WebGPU object for its whole life: WebGPU orders a write after
// every earlier use itself, so nothing is cycled. Transfer buffers are memory of the
// page's own, which uploads copy from as they are recorded and downloads land in once the
// GPU has written them (wgpu_cmd.odin).

Wgpu_Stage :: enum u8 {
	Vertex,
	Fragment,
	Compute,
}

Wgpu_Buffer :: struct {
	buffer: wgpu.Buffer,
	size:   u32,
}

Wgpu_Transfer :: struct {
	data:  []u8, // with 4 bytes to spare, as WebGPU copies whole words
	usage: Transfer_Usage,
	size:  u32,
}

Wgpu_Texture :: struct {
	info:      Texture_Desc,
	texture:   wgpu.Texture,
	format:    wgpu.TextureFormat,
	view:      wgpu.TextureView, // every level, for sampling
	levels:    [dynamic]wgpu.TextureView, // one level each, made when first drawn into or written
	swapchain: bool, // the canvas's texture of this frame: replaced each acquire, never freed here
}

// What one binding of a shader declares, read from its WGSL.
Wgpu_Binding_Kind :: enum u8 {
	Uniform,
	Storage_Read,
	Storage_Write,
	Texture,
	Sampler,
	Storage_Texture,
}

Wgpu_Binding :: struct {
	group:   u32,
	binding: u32,
	kind:    Wgpu_Binding_Kind,
	format:  wgpu.TextureFormat, // a storage texture's
	access:  wgpu.StorageTextureAccess,
}

Wgpu_Shader :: struct {
	module:   wgpu.ShaderModule,
	stage:    Shader_Stage,
	bindings: [dynamic]Wgpu_Binding,
	counts:   [4]u32, // samplers, storage textures, storage buffers, uniform buffers
}

// A pipeline's resource bindings for one group: the layout, and each binding the
// shader declares, so a bind group names exactly those.
Wgpu_Group :: struct {
	layout:   wgpu.BindGroupLayout,
	bindings: [dynamic]Wgpu_Binding,
}

Wgpu_Pipeline :: struct {
	pipeline:   wgpu.RenderPipeline,
	layout:     wgpu.PipelineLayout,
	vertex:     Wgpu_Group, // group 0
	fragment:   Wgpu_Group, // group 2
	counts:     [8]u32, // the vertex shader's four counts, then the fragment shader's
	index_size: u32,
}

Wgpu_Compute_Pipeline :: struct {
	pipeline:  wgpu.ComputePipeline,
	layout:    wgpu.PipelineLayout,
	readonly:  Wgpu_Group, // group 0: samplers, read-only textures, read-only buffers
	readwrite: Wgpu_Group, // group 1: read-write textures, then buffers
	info:      Compute_Pipeline_Desc,
}

// ---- Buffers ------------------------------------------------------------------------

wgpu_create_buffer :: proc(#by_ptr info: Buffer_Desc) -> rawptr {
	usage := wgpu.BufferUsageFlags{.CopyDst, .CopySrc}
	if .Vertex in info.usage do usage += {.Vertex}
	if .Index in info.usage do usage += {.Index}
	if .Indirect in info.usage do usage += {.Indirect}
	if info.usage & {.Graphics_Storage_Read, .Storage_Read, .Storage_Write} != {} do usage += {.Storage}
	// Storage bindings and copies are whole words.
	size := u64(max((info.size + 3) &~ 3, 4))
	buffer := wgpu.DeviceCreateBuffer(wgpu_state.device, &{usage = usage, size = size})
	if buffer == nil {
		wgpu_fail("WebGPU: a %d byte buffer could not be made", info.size)
		return nil
	}
	b := new(Wgpu_Buffer)
	b.buffer, b.size = buffer, info.size
	return b
}

wgpu_release_buffer :: proc(buffer: rawptr) {
	b := (^Wgpu_Buffer)(buffer)
	if b == nil do return
	append(&wgpu_state.doomed_buffers, b.buffer)
	free(b)
	wgpu_reap()
}

wgpu_set_buffer_name :: proc(buffer: Buffer, text: cstring) {
	if b := (^Wgpu_Buffer)(object(buffer)); b != nil do wgpu.BufferSetLabel(b.buffer, string(text))
}

wgpu_create_transfer_buffer :: proc(#by_ptr info: Transfer_Buffer_Desc) -> rawptr {
	data, err := make([]u8, int(info.size) + 4, runtime.heap_allocator())
	if err != nil {
		wgpu_fail("WebGPU: a %d byte transfer buffer could not be made", info.size)
		return nil
	}
	t := new(Wgpu_Transfer)
	t.data, t.usage, t.size = data, info.usage, info.size
	return t
}

wgpu_release_transfer_buffer :: proc(transfer_buffer: rawptr) {
	t := (^Wgpu_Transfer)(transfer_buffer)
	if t == nil do return
	delete(t.data, runtime.heap_allocator())
	free(t)
}

// The page's own memory: uploads copy it out as they are recorded, so it is free to write
// again at once, and a download's bytes are there once its submission's ticket is done.
wgpu_map_transfer_buffer :: proc(transfer_buffer: Transfer_Buffer, cycle: bool) -> rawptr {
	t := (^Wgpu_Transfer)(object(transfer_buffer))
	return raw_data(t.data) if t != nil else nil
}

wgpu_unmap_transfer_buffer :: proc(transfer_buffer: Transfer_Buffer) {}

// ---- Textures -----------------------------------------------------------------------

wgpu_create_texture :: proc(#by_ptr info: Texture_Desc) -> rawptr {
	if info.type != .D2 || info.layer_count_or_depth > 1 {
		wgpu_fail("WebGPU: only 2D textures are supported (asked for %v)", info.type)
		return nil
	}
	format := wgpu_format(info.format)
	if format == .Undefined {
		wgpu_fail("WebGPU: the %v format is not offered", info.format)
		return nil
	}
	samples := wgpu_samples(info.sample_count)
	depth := format_is_depth(info.format)
	usage: wgpu.TextureUsageFlags
	if samples == 1 && !depth do usage += {.CopySrc, .CopyDst}
	if .Sampled in info.usage do usage += {.TextureBinding}
	if info.usage & {.Color_Target, .Depth_Target} != {} do usage += {.RenderAttachment}
	if info.usage & {.Graphics_Storage_Read, .Storage_Read, .Storage_Write, .Storage_Read_Write} != {} do usage += {.StorageBinding}
	// Mipmaps are drawn level by level (wgpu_generate_mipmaps_for_texture).
	if info.num_levels > 1 && !depth do usage += {.RenderAttachment, .TextureBinding}
	texture := wgpu.DeviceCreateTexture(wgpu_state.device, &{
		usage = usage,
		dimension = ._2D,
		size = {max(info.width, 1), max(info.height, 1), 1},
		format = format,
		mipLevelCount = max(info.num_levels, 1),
		sampleCount = samples,
	})
	if texture == nil {
		wgpu_fail("WebGPU: a %dx%d %v texture could not be made", info.width, info.height, info.format)
		return nil
	}
	t := new(Wgpu_Texture)
	t.info, t.texture, t.format = info, texture, format
	t.info.num_levels = max(info.num_levels, 1)
	if .TextureBinding in usage do t.view = wgpu.TextureCreateView(texture, &{
		format = format, dimension = ._2D, mipLevelCount = t.info.num_levels, arrayLayerCount = 1,
		aspect = .DepthOnly if depth else .All,
	})
	return t
}

// WebGPU has no memoryless targets; a transient texture is an ordinary one, and
// transient_targets_offered says so.
wgpu_create_texture_transient :: proc(#by_ptr info: Texture_Desc) -> rawptr {
	return wgpu_create_texture(info)
}

// The view of one level of `t`, made the first time it is asked for.
wgpu_texture_level :: proc(t: ^Wgpu_Texture, level: u32) -> wgpu.TextureView {
	if t.swapchain do return t.view
	for u32(len(t.levels)) <= level do append(&t.levels, nil)
	if t.levels[level] == nil {
		t.levels[level] = wgpu.TextureCreateView(t.texture, &{
			format = t.format, dimension = ._2D, baseMipLevel = level, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All,
		})
	}
	return t.levels[level]
}

wgpu_texture_free :: proc(t: ^Wgpu_Texture) {
	for v in t.levels do if v != nil do wgpu.TextureViewRelease(v)
	delete(t.levels)
	if t.view != nil do wgpu.TextureViewRelease(t.view)
	wgpu.TextureDestroy(t.texture)
	wgpu.TextureRelease(t.texture)
	free(t)
}

wgpu_release_texture :: proc(texture: rawptr) {
	t := (^Wgpu_Texture)(texture)
	if t == nil || t.swapchain do return
	append(&wgpu_state.doomed_textures, t)
	wgpu_reap()
}

wgpu_set_texture_name :: proc(texture: Texture, text: cstring) {
	if t := (^Wgpu_Texture)(object(texture)); t != nil && !t.swapchain do wgpu.TextureSetLabel(t.texture, string(text))
}

// ---- Samplers -----------------------------------------------------------------------

@(private = "file")
wgpu_address :: proc(mode: Address_Mode) -> wgpu.AddressMode {
	switch mode {
	case .Repeat:          return .Repeat
	case .Mirrored_Repeat: return .MirrorRepeat
	case .Clamp_To_Edge:   return .ClampToEdge
	}
	return .ClampToEdge
}

wgpu_compare :: proc(op: Compare_Op) -> wgpu.CompareFunction {
	switch op {
	case .Invalid:          return .Undefined
	case .Never:            return .Never
	case .Less:             return .Less
	case .Equal:            return .Equal
	case .Less_Or_Equal:    return .LessEqual
	case .Greater:          return .Greater
	case .Not_Equal:        return .NotEqual
	case .Greater_Or_Equal: return .GreaterEqual
	case .Always:           return .Always
	}
	return .Always
}

wgpu_create_sampler :: proc(#by_ptr info: Sampler_Desc) -> rawptr {
	desc := wgpu.SamplerDescriptor {
		addressModeU = wgpu_address(info.address_mode_u),
		addressModeV = wgpu_address(info.address_mode_v),
		addressModeW = wgpu_address(info.address_mode_w),
		magFilter = .Linear if info.mag_filter == .Linear else .Nearest,
		minFilter = .Linear if info.min_filter == .Linear else .Nearest,
		mipmapFilter = .Linear if info.mipmap_mode == .Linear else .Nearest,
		lodMinClamp = max(info.min_lod, 0),
		lodMaxClamp = clamp(info.max_lod, max(info.min_lod, 0), 32),
		compare = wgpu_compare(info.compare_op) if info.enable_compare else .Undefined,
		maxAnisotropy = 1,
	}
	// WebGPU filters anisotropically only with every filter linear.
	if info.enable_anisotropy && desc.magFilter == .Linear && desc.minFilter == .Linear && desc.mipmapFilter == .Linear {
		desc.maxAnisotropy = u16(clamp(info.max_anisotropy, 1, 16))
	}
	sampler := wgpu.DeviceCreateSampler(wgpu_state.device, &desc)
	if sampler == nil do wgpu_fail("WebGPU: the sampler could not be made")
	return sampler
}

wgpu_release_sampler :: proc(sampler: rawptr) {
	if sampler != nil do wgpu.SamplerRelease(wgpu.Sampler(sampler))
}

// ---- Shaders ------------------------------------------------------------------------

// The line a shader with no WGSL form has after its header (scripts/shaders_wgsl.py).
WGPU_UNAVAILABLE :: "// not on the web: "

// Why `code` cannot be a WebGPU shader, or "" when it can.
@(private = "file")
wgpu_unavailable :: proc(code: string) -> string {
	_, _, rest := strings.partition(code, "\n")
	if strings.has_prefix(rest, WGPU_UNAVAILABLE) {
		reason, _, _ := strings.partition(rest[len(WGPU_UNAVAILABLE):], "\n")
		return reason
	}
	return ""
}

@(private = "file")
wgpu_storage_texel :: proc(name: string) -> wgpu.TextureFormat {
	switch name {
	case "rgba8unorm":  return .RGBA8Unorm
	case "rgba16float": return .RGBA16Float
	case "r32float":    return .R32Float
	case "rg32float":   return .RG32Float
	case "rgba32float": return .RGBA32Float
	case "r32uint":     return .R32Uint
	}
	return .Undefined
}

// The bindings a WGSL shader declares, one `@binding(b) @group(g) var...` line each, as
// slangc writes them and scripts/shaders_wgsl.py numbers them.
wgpu_parse_bindings :: proc(code: string, out: ^[dynamic]Wgpu_Binding) {
	rest := code
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "@binding(") do continue
		b: Wgpu_Binding
		close := strings.index_byte(line, ')')
		if close < 0 do continue
		n, _ := strconv.parse_uint(line[len("@binding("):close], 10)
		b.binding = u32(n)
		g := strings.index(line, "@group(")
		if g < 0 do continue
		gclose := strings.index_byte(line[g:], ')')
		gn, _ := strconv.parse_uint(line[g + len("@group("):g + gclose], 10)
		b.group = u32(gn)
		decl := line[g + gclose:]
		_, _, type := strings.partition(decl, " : ")
		switch {
		case strings.contains(decl, "var<uniform>"):             b.kind = .Uniform
		case strings.contains(decl, "var<storage, read_write>"): b.kind = .Storage_Write
		case strings.contains(decl, "var<storage"):              b.kind = .Storage_Read
		case strings.has_prefix(type, "texture_storage_2d<"):
			b.kind = .Storage_Texture
			args := type[len("texture_storage_2d<"):]
			fmt_name, _, access := strings.partition(args, ", ")
			b.format = wgpu_storage_texel(fmt_name)
			b.access = .ReadWrite if strings.has_prefix(access, "read_write") else .ReadOnly if strings.has_prefix(access, "read>") else .WriteOnly
		case strings.has_prefix(type, "texture_"): b.kind = .Texture
		case strings.has_prefix(type, "sampler"):  b.kind = .Sampler
		case: continue
		}
		append(out, b)
	}
}

wgpu_create_shader :: proc(#by_ptr info: Shader_Desc) -> rawptr {
	code := info.code
	if reason := wgpu_unavailable(code); reason != "" {
		wgpu_fail("WebGPU: this shader has no WGSL form (%s)", reason)
		return nil
	}
	module := wgpu.DeviceCreateShaderModule(wgpu_state.device, &{
		nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = code},
	})
	if module == nil {
		wgpu_fail("WebGPU: the shader did not compile")
		return nil
	}
	s := new(Wgpu_Shader)
	s.module, s.stage = module, info.stage
	s.counts = {info.num_samplers, info.num_storage_textures, info.num_storage_buffers, info.num_uniform_buffers}
	wgpu_parse_bindings(code, &s.bindings)
	return s
}

wgpu_release_shader :: proc(shader: rawptr) {
	s := (^Wgpu_Shader)(shader)
	if s == nil do return
	wgpu.ShaderModuleRelease(s.module)
	delete(s.bindings)
	free(s)
}

// ---- Bind group layouts -------------------------------------------------------------

@(private = "file")
wgpu_visibility :: proc(stage: Wgpu_Stage) -> wgpu.ShaderStageFlags {
	switch stage {
	case .Vertex:   return {.Vertex}
	case .Fragment: return {.Fragment}
	case .Compute:  return {.Compute}
	}
	return {}
}

// The layout of `count` uniform blocks of a stage, at bindings 0, 2, 4 and 6 with
// dynamic offsets, shared by every pipeline.
wgpu_uniform_layout :: proc(stage: Wgpu_Stage, count: u32) -> wgpu.BindGroupLayout {
	if count == 0 do return wgpu_state.empty_layout
	c := min(count, 4)
	l := &wgpu_state.uniform_layouts[stage][c]
	if l^ == nil {
		entries: [4]wgpu.BindGroupLayoutEntry
		for i in 0 ..< c {
			entries[i] = {
				binding = 2 * i,
				visibility = wgpu_visibility(stage),
				buffer = {type = .Uniform, hasDynamicOffset = true, minBindingSize = 0},
			}
		}
		l^ = wgpu.DeviceCreateBindGroupLayout(wgpu_state.device, &{entryCount = uint(c), entries = raw_data(entries[:])})
	}
	return l^
}

// A resource group's layout from the bindings a shader declares in `group`.
@(private = "file")
wgpu_group_make :: proc(stage: Wgpu_Stage, bindings: []Wgpu_Binding, group: u32) -> (g: Wgpu_Group) {
	entries := make([dynamic]wgpu.BindGroupLayoutEntry, context.temp_allocator)
	for b in bindings {
		if b.group != group do continue
		append(&g.bindings, b)
		e := wgpu.BindGroupLayoutEntry{binding = b.binding, visibility = wgpu_visibility(stage)}
		switch b.kind {
		case .Uniform:         e.buffer = {type = .Uniform}
		case .Storage_Read:    e.buffer = {type = .ReadOnlyStorage}
		case .Storage_Write:   e.buffer = {type = .Storage}
		case .Texture:         e.texture = {sampleType = .Float, viewDimension = ._2D}
		case .Sampler:         e.sampler = {type = .Filtering}
		case .Storage_Texture: e.storageTexture = {access = b.access, format = b.format, viewDimension = ._2D}
		}
		append(&entries, e)
	}
	if len(entries) == 0 {
		g.layout = wgpu_state.empty_layout
		return
	}
	g.layout = wgpu.DeviceCreateBindGroupLayout(wgpu_state.device, &{entryCount = uint(len(entries)), entries = raw_data(entries)})
	return
}

@(private = "file")
wgpu_group_free :: proc(g: ^Wgpu_Group) {
	if g.layout != nil && g.layout != wgpu_state.empty_layout do wgpu.BindGroupLayoutRelease(g.layout)
	delete(g.bindings)
}

// ---- Graphics pipelines -------------------------------------------------------------

@(private = "file")
wgpu_vertex_format :: proc(format: Vertex_Format) -> wgpu.VertexFormat {
	#partial switch format {
	case .Int:          return .Sint32
	case .Int2:         return .Sint32x2
	case .Int3:         return .Sint32x3
	case .Int4:         return .Sint32x4
	case .Uint:         return .Uint32
	case .Uint2:        return .Uint32x2
	case .Uint3:        return .Uint32x3
	case .Uint4:        return .Uint32x4
	case .Float:        return .Float32
	case .Float2:       return .Float32x2
	case .Float3:       return .Float32x3
	case .Float4:       return .Float32x4
	case .Ubyte4:       return .Uint8x4
	case .Ubyte4_Norm:  return .Unorm8x4
	case .Byte4_Norm:   return .Snorm8x4
	case .Short2_Norm:  return .Snorm16x2
	case .Short4_Norm:  return .Snorm16x4
	case .Ushort2_Norm: return .Unorm16x2
	case .Ushort4_Norm: return .Unorm16x4
	case .Half2:        return .Float16x2
	case .Half4:        return .Float16x4
	}
	return .Float32x4
}

@(private = "file")
wgpu_blend_factor :: proc(f: Blend_Factor) -> wgpu.BlendFactor {
	switch f {
	case .Invalid, .Zero:            return .Zero
	case .One:                       return .One
	case .Src_Color:                 return .Src
	case .One_Minus_Src_Color:       return .OneMinusSrc
	case .Dst_Color:                 return .Dst
	case .One_Minus_Dst_Color:       return .OneMinusDst
	case .Src_Alpha:                 return .SrcAlpha
	case .One_Minus_Src_Alpha:       return .OneMinusSrcAlpha
	case .Dst_Alpha:                 return .DstAlpha
	case .One_Minus_Dst_Alpha:       return .OneMinusDstAlpha
	case .Constant_Color:            return .Constant
	case .One_Minus_Constant_Color:  return .OneMinusConstant
	case .Src_Alpha_Saturate:        return .SrcAlphaSaturated
	}
	return .One
}

@(private = "file")
wgpu_blend_op :: proc(op: Blend_Op) -> wgpu.BlendOperation {
	switch op {
	case .Invalid, .Add:     return .Add
	case .Subtract:          return .Subtract
	case .Reverse_Subtract:  return .ReverseSubtract
	case .Min:               return .Min
	case .Max:               return .Max
	}
	return .Add
}

@(private = "file")
wgpu_stencil_op :: proc(op: Stencil_Op) -> wgpu.StencilOperation {
	switch op {
	case .Invalid, .Keep:        return .Keep
	case .Zero:                  return .Zero
	case .Replace:               return .Replace
	case .Increment_And_Clamp:   return .IncrementClamp
	case .Decrement_And_Clamp:   return .DecrementClamp
	case .Invert:                return .Invert
	case .Increment_And_Wrap:    return .IncrementWrap
	case .Decrement_And_Wrap:    return .DecrementWrap
	}
	return .Keep
}

@(private = "file")
wgpu_stencil_face :: proc(s: Stencil_Op_State, on: bool) -> wgpu.StencilFaceState {
	if !on do return {compare = .Always, failOp = .Keep, depthFailOp = .Keep, passOp = .Keep}
	return {compare = wgpu_compare(s.compare_op), failOp = wgpu_stencil_op(s.fail_op), depthFailOp = wgpu_stencil_op(s.depth_fail_op), passOp = wgpu_stencil_op(s.pass_op)}
}

// A pipeline as SDL_GPU describes it. WebGPU has no line fill (the wireframe overlay then
// stays off, as on a device that cannot draw lines) and no depth bias on lines or points.
wgpu_create_graphics_pipeline :: proc(#by_ptr info: Graphics_Pipeline_Desc) -> rawptr {
	vs := (^Wgpu_Shader)(object(info.vertex_shader))
	fs := (^Wgpu_Shader)(object(info.fragment_shader))
	if vs == nil || fs == nil {
		wgpu_fail("WebGPU: a pipeline needs both shaders")
		return nil
	}
	if info.rasterizer_state.fill_mode == .Line {
		wgpu_fail("WebGPU draws no polygons as lines")
		return nil
	}
	p := new(Wgpu_Pipeline)
	p.vertex = wgpu_group_make(.Vertex, vs.bindings[:], 0)
	p.fragment = wgpu_group_make(.Fragment, fs.bindings[:], 2)
	p.counts = {vs.counts[0], vs.counts[1], vs.counts[2], vs.counts[3], fs.counts[0], fs.counts[1], fs.counts[2], fs.counts[3]}
	layouts := [4]wgpu.BindGroupLayout{p.vertex.layout, wgpu_uniform_layout(.Vertex, vs.counts[3]), p.fragment.layout, wgpu_uniform_layout(.Fragment, fs.counts[3])}
	p.layout = wgpu.DeviceCreatePipelineLayout(wgpu_state.device, &{bindGroupLayoutCount = 4, bindGroupLayouts = raw_data(layouts[:])})

	// Vertex buffers by slot: WebGPU numbers them densely from 0, as the renderer does.
	vi := info.vertex_input
	buffers := make([]wgpu.VertexBufferLayout, len(vi.buffers), context.temp_allocator)
	attributes := make([]wgpu.VertexAttribute, len(vi.attributes), context.temp_allocator)
	for d in vi.buffers {
		if int(d.slot) >= len(buffers) do continue
		buffers[d.slot] = {stepMode = .Instance if d.input_rate == .Instance else .Vertex, arrayStride = u64(d.pitch)}
	}
	// Each buffer's attributes, in order, from one shared array.
	n := 0
	for slot in 0 ..< len(buffers) {
		first := n
		for a in vi.attributes {
			if int(a.buffer_slot) != slot do continue
			attributes[n] = {format = wgpu_vertex_format(a.format), offset = u64(a.offset), shaderLocation = a.location}
			n += 1
		}
		buffers[slot].attributeCount = uint(n - first)
		buffers[slot].attributes = raw_data(attributes[first:]) if n > first else nil
	}

	targets := make([]wgpu.ColorTargetState, len(info.targets.color_targets), context.temp_allocator)
	blends := make([]wgpu.BlendState, len(targets), context.temp_allocator)
	for d, i in info.targets.color_targets {
		bs := d.blend_state
		targets[i] = {format = wgpu_format(d.format), writeMask = wgpu.ColorWriteMaskFlags_All}
		if bs.enable_color_write_mask {
			mask: wgpu.ColorWriteMaskFlags
			if .R in bs.color_write_mask do mask += {.Red}
			if .G in bs.color_write_mask do mask += {.Green}
			if .B in bs.color_write_mask do mask += {.Blue}
			if .A in bs.color_write_mask do mask += {.Alpha}
			targets[i].writeMask = mask
		}
		if bs.enable_blend {
			blends[i] = {
				color = {operation = wgpu_blend_op(bs.color_blend_op), srcFactor = wgpu_blend_factor(bs.src_color_blendfactor), dstFactor = wgpu_blend_factor(bs.dst_color_blendfactor)},
				alpha = {operation = wgpu_blend_op(bs.alpha_blend_op), srcFactor = wgpu_blend_factor(bs.src_alpha_blendfactor), dstFactor = wgpu_blend_factor(bs.dst_alpha_blendfactor)},
			}
			targets[i].blend = &blends[i]
		}
	}

	topology: wgpu.PrimitiveTopology
	switch info.primitive {
	case .Triangle_List:  topology = .TriangleList
	case .Triangle_Strip: topology = .TriangleStrip
	case .Line_List:      topology = .LineList
	case .Line_Strip:     topology = .LineStrip
	case .Point_List:     topology = .PointList
	}
	triangles := topology == .TriangleList || topology == .TriangleStrip
	rs := info.rasterizer_state
	cull: wgpu.CullMode = .None
	if rs.cull_mode == .Front do cull = .Front
	if rs.cull_mode == .Back do cull = .Back
	primitive := wgpu.PrimitiveState {
		topology = topology,
		frontFace = .CW if rs.front_face == .Clockwise else .CCW,
		cullMode = cull,
		// Depth is clipped unless the pipeline says not to; WebGPU leaves it unclipped only with its feature.
		unclippedDepth = b32(!rs.enable_depth_clip && wgpu_state.depth_clip),
	}
	if topology == .TriangleStrip do primitive.stripIndexFormat = .Undefined

	ds: wgpu.DepthStencilState
	has_depth := info.targets.has_depth_stencil_target
	if has_depth {
		d := info.depth_stencil_state
		format := info.targets.depth_stencil_format
		ds = {
			format = wgpu_format(format),
			depthWriteEnabled = .True if d.enable_depth_test && d.enable_depth_write else .False,
			depthCompare = wgpu_compare(d.compare_op) if d.enable_depth_test else .Always,
			stencilFront = wgpu_stencil_face(d.front_stencil_state, d.enable_stencil_test),
			stencilBack = wgpu_stencil_face(d.back_stencil_state, d.enable_stencil_test),
			stencilReadMask = u32(d.compare_mask) if d.enable_stencil_test else 0xFF,
			stencilWriteMask = u32(d.write_mask) if d.enable_stencil_test else 0,
		}
		if ds.depthCompare == .Undefined do ds.depthCompare = .Always
		if rs.enable_depth_bias && triangles {
			ds.depthBias = i32(rs.depth_bias_constant_factor)
			ds.depthBiasSlopeScale = rs.depth_bias_slope_factor
			ds.depthBiasClamp = rs.depth_bias_clamp
		}
		if !wgpu_is_stencil(format) do ds.stencilWriteMask = 0
	}

	fragment := wgpu.FragmentState {
		module = fs.module, entryPoint = "main",
		targetCount = uint(len(targets)), targets = raw_data(targets),
	}
	p.pipeline = wgpu.DeviceCreateRenderPipeline(wgpu_state.device, &{
		layout = p.layout,
		vertex = {module = vs.module, entryPoint = "main", bufferCount = uint(len(buffers)), buffers = raw_data(buffers)},
		primitive = primitive,
		depthStencil = &ds if has_depth else nil,
		multisample = {count = wgpu_samples(info.multisample_state.sample_count), mask = max(u32)},
		fragment = &fragment,
	})
	if p.pipeline == nil {
		wgpu_release_graphics_pipeline(p)
		wgpu_fail("WebGPU: the graphics pipeline could not be made")
		return nil
	}
	return p
}

wgpu_release_graphics_pipeline :: proc(graphics_pipeline: rawptr) {
	p := (^Wgpu_Pipeline)(graphics_pipeline)
	if p == nil do return
	if p.pipeline != nil do wgpu.RenderPipelineRelease(p.pipeline)
	if p.layout != nil do wgpu.PipelineLayoutRelease(p.layout)
	wgpu_group_free(&p.vertex)
	wgpu_group_free(&p.fragment)
	free(p)
}

// ---- Compute pipelines --------------------------------------------------------------

wgpu_create_compute_pipeline :: proc(#by_ptr info: Compute_Pipeline_Desc) -> rawptr {
	code := info.code
	if reason := wgpu_unavailable(code); reason != "" {
		wgpu_fail("WebGPU: this kernel has no WGSL form (%s)", reason)
		return nil
	}
	module := wgpu.DeviceCreateShaderModule(wgpu_state.device, &{
		nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = code},
	})
	if module == nil {
		wgpu_fail("WebGPU: the kernel did not compile")
		return nil
	}
	defer wgpu.ShaderModuleRelease(module)
	bindings := make([dynamic]Wgpu_Binding, context.temp_allocator)
	wgpu_parse_bindings(code, &bindings)
	p := new(Wgpu_Compute_Pipeline)
	p.info = info
	p.readonly = wgpu_group_make(.Compute, bindings[:], 0)
	p.readwrite = wgpu_group_make(.Compute, bindings[:], 1)
	layouts := [3]wgpu.BindGroupLayout{p.readonly.layout, p.readwrite.layout, wgpu_uniform_layout(.Compute, info.num_uniform_buffers)}
	p.layout = wgpu.DeviceCreatePipelineLayout(wgpu_state.device, &{bindGroupLayoutCount = 3, bindGroupLayouts = raw_data(layouts[:])})
	p.pipeline = wgpu.DeviceCreateComputePipeline(wgpu_state.device, &{layout = p.layout, compute = {module = module, entryPoint = "main"}})
	if p.pipeline == nil {
		wgpu_release_compute_pipeline(p)
		wgpu_fail("WebGPU: the compute pipeline could not be made")
		return nil
	}
	return p
}

wgpu_release_compute_pipeline :: proc(compute_pipeline: rawptr) {
	p := (^Wgpu_Compute_Pipeline)(compute_pipeline)
	if p == nil do return
	if p.pipeline != nil do wgpu.ComputePipelineRelease(p.pipeline)
	if p.layout != nil do wgpu.PipelineLayoutRelease(p.layout)
	wgpu_group_free(&p.readonly)
	wgpu_group_free(&p.readwrite)
	free(p)
}

