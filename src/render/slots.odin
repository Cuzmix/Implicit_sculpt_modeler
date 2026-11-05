package render

import "base:intrinsics"

import "../gpu"

// Binding by the shaders' own slot names. shaders_gen.odin gives each shader one enum per kind
// of slot it binds (Cull_Write_Comp_Buffers :: enum u32 {chunks, groups, totals}), its members
// the shader's parameter names in slot order. A binding array is an enumerated array of one,
// written with every member named ([Cull_Write_Comp_Buffers]gpu.Buffer{.chunks = ..., ...}), and
// the procs below bind all of it from slot 0: a parameter a shader renames, adds or reorders then
// fails to compile where it is bound, where a positional array would bind the wrong buffer.
// A uniform push names its block the same way (Cull_Write_Comp_Uniforms.Cull_Uniforms).
//
// Where one array serves a family of shaders with the same slots (the mesh fragment shaders,
// the dab kernels), it is typed by one of them and an `#assert` beside it ties the others'
// enums to it: `#assert(len(Mesh_Area_Frag_Samplers) == len(Mesh_Frag_Samplers))`, and where the
// members share names, each member's slot (`#assert(int(A.matcap) == int(B.matcap))`).

bind_compute_storage :: proc(pass: gpu.Compute_Pass, buffers: ^[$E]gpu.Buffer) {
	gpu.bind_compute_storage_buffers(pass, 0, &buffers[min(E)], u32(len(E)))
}

bind_compute_samplers :: proc(pass: gpu.Compute_Pass, samplers: ^[$E]gpu.Texture_Sampler_Binding) {
	gpu.bind_compute_samplers(pass, 0, &samplers[min(E)], u32(len(E)))
}

bind_vertex_storage :: proc(pass: gpu.Render_Pass, buffers: ^[$E]gpu.Buffer) {
	gpu.bind_vertex_storage_buffers(pass, 0, &buffers[min(E)], u32(len(E)))
}

bind_fragment_storage :: proc(pass: gpu.Render_Pass, buffers: ^[$E]gpu.Buffer) {
	gpu.bind_fragment_storage_buffers(pass, 0, &buffers[min(E)], u32(len(E)))
}

bind_fragment_samplers :: proc(pass: gpu.Render_Pass, samplers: ^[$E]gpu.Texture_Sampler_Binding) {
	gpu.bind_fragment_samplers(pass, 0, &samplers[min(E)], u32(len(E)))
}

// A compute pass writing a kernel's read-write buffers, textures or both, by its enums.
begin_compute :: proc {
	begin_compute_buffers,
	begin_compute_textures,
	begin_compute_both,
}

begin_compute_buffers :: proc(cmd: gpu.Cmd, buffers: ^[$E]gpu.Storage_Buffer_Binding) -> gpu.Compute_Pass {
	return gpu.begin_compute_pass(cmd, nil, 0, &buffers[min(E)], u32(len(E)))
}

begin_compute_textures :: proc(cmd: gpu.Cmd, textures: ^[$E]gpu.Storage_Texture_Binding) -> gpu.Compute_Pass {
	return gpu.begin_compute_pass(cmd, &textures[min(E)], u32(len(E)), nil, 0)
}

begin_compute_both :: proc(cmd: gpu.Cmd, textures: ^[$T]gpu.Storage_Texture_Binding, buffers: ^[$B]gpu.Storage_Buffer_Binding) -> gpu.Compute_Pass {
	return gpu.begin_compute_pass(cmd, &textures[min(T)], u32(len(T)), &buffers[min(B)], u32(len(B)))
}

push_vertex :: proc(cmd: gpu.Cmd, block: $E, data: ^$T) where intrinsics.type_is_enum(E) {
	gpu.push_vertex_uniform_data(cmd, u32(block), data, size_of(T))
}

push_fragment :: proc(cmd: gpu.Cmd, block: $E, data: ^$T) where intrinsics.type_is_enum(E) {
	gpu.push_fragment_uniform_data(cmd, u32(block), data, size_of(T))
}

push_compute :: proc(cmd: gpu.Cmd, block: $E, data: ^$T) where intrinsics.type_is_enum(E) {
	gpu.push_compute_uniform_data(cmd, u32(block), data, size_of(T))
}
