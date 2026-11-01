#+build js
// Package webgpu draws the web build's viewport with WebGPU (vendor:wgpu's js backend):
// one sculpted mesh, lit, with the brush ring on it. It is the first stage of the web
// port (README "Web"): the GPU code lives under src/render, as every GPU call does, and
// gives way to a WebGPU backend for render's own seam (hal.odin) once that exists.
package webgpu

import "base:runtime"
import "core:fmt"
import "core:math"
import "vendor:wgpu"

import "../../geom"

Mat4 :: matrix[4, 4]f32

// What the shader reads each frame (viewport.wgsl's Frame), laid out as WGSL's uniform
// rules want it: matrices and vec4s only.
Frame :: struct #align (16) {
	view_proj: Mat4,
	view:      Mat4,
	cursor:    [4]f32, // centre xyz and radius; radius 0 hides the ring
	clay:      [4]f32, // linear RGB
}

Viewport :: struct {
	// Set once the device exists and the pipeline is built; until then nothing draws.
	ready:        bool,
	// Why the GPU could not start, for the page to show; empty while it can.
	failed:       string,
	on_ready:     proc(),
	instance:     wgpu.Instance,
	surface:      wgpu.Surface,
	adapter:      wgpu.Adapter,
	device:       wgpu.Device,
	queue:        wgpu.Queue,
	config:       wgpu.SurfaceConfiguration,
	pipeline:     wgpu.RenderPipeline,
	module:       wgpu.ShaderModule,
	uniforms:     wgpu.Buffer,
	bind_group:   wgpu.BindGroup,
	depth:        wgpu.Texture,
	depth_view:   wgpu.TextureView,
	positions:    wgpu.Buffer,
	normals:      wgpu.Buffer,
	indices:      wgpu.Buffer,
	vertex_count: int,
	index_count:  int,
	// The largest buffer the adapter allows, which caps the mesh the page can show.
	max_buffer:   u64,
}

DEPTH_FORMAT :: wgpu.TextureFormat.Depth24Plus

SHADER :: #load("viewport.wgsl", string)

// The context the browser's callbacks run in: WebGPU answers requests through procs with
// the C calling convention, which bring none of their own.
@(private)
g_ctx: runtime.Context
@(private)
g_viewport: ^Viewport

// Starts WebGPU on the canvas `selector` names (a CSS selector such as "#viewport"). The
// adapter and device come back asynchronously; `on_ready` runs once both exist and the
// pipeline is built, or `v.failed` says why not.
init :: proc(v: ^Viewport, selector: string, width, height: u32, on_ready: proc()) {
	g_ctx = context
	g_viewport = v
	v.on_ready = on_ready
	v.config.width, v.config.height = max(width, 1), max(height, 1)
	v.instance = wgpu.CreateInstance(nil)
	if v.instance == nil {
		v.failed = "This browser has no WebGPU. Use a current Chrome, Edge or Safari, or Firefox 141 or later."
		return
	}
	v.surface = wgpu.InstanceCreateSurface(v.instance, &wgpu.SurfaceDescriptor {
		nextInChain = &wgpu.SurfaceSourceCanvasHTMLSelector{sType = .SurfaceSourceCanvasHTMLSelector, selector = selector},
	})
	wgpu.InstanceRequestAdapter(v.instance, &{compatibleSurface = v.surface, powerPreference = .HighPerformance}, {callback = on_adapter})
}

@(private)
on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, userdata1, userdata2: rawptr) {
	context = g_ctx
	v := g_viewport
	if status != .Success || adapter == nil {
		v.failed = fmt.aprintf("No WebGPU adapter (%v): %s", status, message)
		return
	}
	v.adapter = adapter
	// WebGPU's default limits: 256 MB a buffer holds about 20 million triangles' indices,
	// more than one thread sculpts. Asking for the adapter's own would need wgpu.js to read
	// required limits where Odin writes them, which this Odin's does not (it reads them 8
	// bytes on), so the defaults it is until a mesh needs more.
	v.max_buffer = 256 << 20
	wgpu.AdapterRequestDevice(adapter, &{
		uncapturedErrorCallbackInfo = {callback = on_error},
	}, {callback = on_device})
}

@(private)
on_error :: proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: string, userdata1, userdata2: rawptr) {
	context = g_ctx
	fmt.eprintfln("WebGPU %v error: %s", type, message)
}

@(private)
on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, userdata1, userdata2: rawptr) {
	context = g_ctx
	v := g_viewport
	if status != .Success || device == nil {
		v.failed = fmt.aprintf("No WebGPU device (%v): %s", status, message)
		return
	}
	v.device = device
	v.queue = wgpu.DeviceGetQueue(device)

	// The canvas's preferred format: BGRA on most desktops, RGBA on Android.
	format := wgpu.TextureFormat.BGRA8Unorm
	if caps, caps_status := wgpu.SurfaceGetCapabilities(v.surface, v.adapter); caps_status == .Success && caps.formatCount > 0 {
		format = caps.formats[0]
	}
	v.config = wgpu.SurfaceConfiguration {
		device      = device,
		usage       = {.RenderAttachment},
		format      = format,
		width       = v.config.width,
		height      = v.config.height,
		presentMode = .Fifo,
		alphaMode   = .Opaque,
	}
	wgpu.SurfaceConfigure(v.surface, &v.config)
	make_depth(v)

	v.module = wgpu.DeviceCreateShaderModule(device, &{
		nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = SHADER},
	})
	attributes := [2]wgpu.VertexAttribute {
		{format = .Float32x3, offset = 0, shaderLocation = 0},
		{format = .Float32x3, offset = 0, shaderLocation = 1},
	}
	// Positions and normals in buffers of their own, as the mesh keeps them, so a dab's
	// ranges upload straight from its arrays.
	buffers := [2]wgpu.VertexBufferLayout {
		{stepMode = .Vertex, arrayStride = size_of(geom.Vec3), attributeCount = 1, attributes = &attributes[0]},
		{stepMode = .Vertex, arrayStride = size_of(geom.Vec3), attributeCount = 1, attributes = &attributes[1]},
	}
	v.pipeline = wgpu.DeviceCreateRenderPipeline(device, &{
		vertex = {module = v.module, entryPoint = "vs_main", bufferCount = len(buffers), buffers = &buffers[0]},
		fragment = &{
			module = v.module,
			entryPoint = "fs_main",
			targetCount = 1,
			targets = &wgpu.ColorTargetState{format = format, writeMask = wgpu.ColorWriteMaskFlags_All},
		},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
		depthStencil = &{format = DEPTH_FORMAT, depthWriteEnabled = .True, depthCompare = .Less},
		multisample = {count = 1, mask = 0xFFFFFFFF},
	})
	v.uniforms = wgpu.DeviceCreateBuffer(device, &{usage = {.Uniform, .CopyDst}, size = size_of(Frame)})
	entry := wgpu.BindGroupEntry{binding = 0, buffer = v.uniforms, size = size_of(Frame)}
	v.bind_group = wgpu.DeviceCreateBindGroup(device, &{
		layout = wgpu.RenderPipelineGetBindGroupLayout(v.pipeline, 0),
		entryCount = 1,
		entries = &entry,
	})
	v.ready = true
	if v.on_ready != nil do v.on_ready()
}

@(private)
make_depth :: proc(v: ^Viewport) {
	if v.depth_view != nil do wgpu.TextureViewRelease(v.depth_view)
	if v.depth != nil do wgpu.TextureRelease(v.depth)
	v.depth = wgpu.DeviceCreateTexture(v.device, &{
		usage = {.RenderAttachment},
		dimension = ._2D,
		size = {v.config.width, v.config.height, 1},
		format = DEPTH_FORMAT,
		mipLevelCount = 1,
		sampleCount = 1,
	})
	v.depth_view = wgpu.TextureCreateView(v.depth, nil)
}

// Fits the drawing to a canvas of `width` by `height` device pixels.
resize :: proc(v: ^Viewport, width, height: u32) {
	w, h := max(width, 1), max(height, 1)
	if w == v.config.width && h == v.config.height do return
	v.config.width, v.config.height = w, h
	if !v.ready do return
	wgpu.SurfaceConfigure(v.surface, &v.config)
	make_depth(v)
}

// Uploads a whole mesh, replacing the one before (a new mesh, or one whose triangles
// changed). False when it is larger than the adapter allows a buffer to be.
set_mesh :: proc(v: ^Viewport, mesh: ^geom.Mesh) -> bool {
	if !v.ready do return false
	vertex_bytes := u64(len(mesh.positions) * size_of(geom.Vec3))
	index_bytes := u64(len(mesh.indices) * size_of(u32))
	if vertex_bytes > v.max_buffer || index_bytes > v.max_buffer do return false
	release_mesh(v)
	v.positions = wgpu.DeviceCreateBuffer(v.device, &{usage = {.Vertex, .CopyDst}, size = vertex_bytes})
	v.normals = wgpu.DeviceCreateBuffer(v.device, &{usage = {.Vertex, .CopyDst}, size = vertex_bytes})
	v.indices = wgpu.DeviceCreateBuffer(v.device, &{usage = {.Index, .CopyDst}, size = index_bytes})
	wgpu.QueueWriteBuffer(v.queue, v.positions, 0, raw_data(mesh.positions), uint(vertex_bytes))
	wgpu.QueueWriteBuffer(v.queue, v.normals, 0, raw_data(mesh.normals), uint(vertex_bytes))
	wgpu.QueueWriteBuffer(v.queue, v.indices, 0, raw_data(mesh.indices), uint(index_bytes))
	v.vertex_count, v.index_count = len(mesh.positions), len(mesh.indices)
	return true
}

// Uploads the vertices a flush says changed (sculpt.sculptor_flush's ranges), positions
// and normals both. Returns the bytes sent.
update :: proc(v: ^Viewport, mesh: ^geom.Mesh, ranges: []geom.Vertex_Range) -> int {
	if !v.ready || v.positions == nil do return 0
	sent := 0
	for r in ranges {
		if r.count == 0 || int(r.first + r.count) > v.vertex_count do continue
		offset := u64(r.first) * size_of(geom.Vec3)
		bytes := uint(r.count) * size_of(geom.Vec3)
		wgpu.QueueWriteBuffer(v.queue, v.positions, offset, &mesh.positions[r.first], bytes)
		wgpu.QueueWriteBuffer(v.queue, v.normals, offset, &mesh.normals[r.first], bytes)
		sent += 2 * int(bytes)
	}
	return sent
}

@(private)
release_mesh :: proc(v: ^Viewport) {
	if v.positions != nil do wgpu.BufferRelease(v.positions)
	if v.normals != nil do wgpu.BufferRelease(v.normals)
	if v.indices != nil do wgpu.BufferRelease(v.indices)
	v.positions, v.normals, v.indices = nil, nil, nil
	v.vertex_count, v.index_count = 0, 0
}

// Draws one frame: clears to `background` (linear RGB), then the mesh with `frame`'s
// matrices and ring.
draw :: proc(v: ^Viewport, frame: Frame, background: [3]f32) {
	if !v.ready do return
	surface_texture := wgpu.SurfaceGetCurrentTexture(v.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout, .Outdated, .Lost:
		if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
		wgpu.SurfaceConfigure(v.surface, &v.config)
		return
	case .Occluded:
		return
	case .Error:
		v.failed = "The canvas lost its WebGPU surface."
		v.ready = false
		return
	}
	defer wgpu.TextureRelease(surface_texture.texture)
	target := wgpu.TextureCreateView(surface_texture.texture, nil)
	defer wgpu.TextureViewRelease(target)

	f := frame
	wgpu.QueueWriteBuffer(v.queue, v.uniforms, 0, &f, size_of(Frame))

	encoder := wgpu.DeviceCreateCommandEncoder(v.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)
	// The background as the canvas shows it, which is not sRGB: encoded by hand, as the
	// shader does.
	bg := srgb_encode(background)
	pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{
		colorAttachmentCount = 1,
		colorAttachments = &wgpu.RenderPassColorAttachment {
			view = target,
			loadOp = .Clear,
			storeOp = .Store,
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			clearValue = {f64(bg.r), f64(bg.g), f64(bg.b), 1},
		},
		depthStencilAttachment = &{
			view = v.depth_view,
			depthLoadOp = .Clear,
			depthStoreOp = .Discard,
			depthClearValue = 1,
		},
	})
	if v.index_count > 0 {
		wgpu.RenderPassEncoderSetPipeline(pass, v.pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, v.bind_group)
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, v.positions, 0, u64(v.vertex_count * size_of(geom.Vec3)))
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 1, v.normals, 0, u64(v.vertex_count * size_of(geom.Vec3)))
		wgpu.RenderPassEncoderSetIndexBuffer(pass, v.indices, .Uint32, 0, u64(v.index_count * size_of(u32)))
		wgpu.RenderPassEncoderDrawIndexed(pass, u32(v.index_count), 1, 0, 0, 0)
	}
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
	commands := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(commands)
	wgpu.QueueSubmit(v.queue, {commands})
	wgpu.SurfacePresent(v.surface)
}

@(private)
srgb_encode :: proc(c: [3]f32) -> [3]f32 {
	// The same curve as the shader's: a plain 2.2 power.
	return {math.pow(max(c.r, 0), 1 / 2.2), math.pow(max(c.g, 0), 1 / 2.2), math.pow(max(c.b, 0), 1 / 2.2)}
}
