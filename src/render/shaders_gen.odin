package render

// Written by scripts/shaders_gen.py from each shader's slangc reflection: never edit it by hand.
// `build.sh` and `build.bat` remake it with the shaders, and `check` fails on a stale entry.

import "../gpu"

// ao_blur.frag.spv sha256 8418bdcbcc0f9561f215b107d665d2826cd0d711910d0291c89c7207d01a47a8
AO_BLUR_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/ao_blur.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 3,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Ao_Blur_Frag_Samplers :: enum u32 {view_color, ao_map, view_depth}
Ao_Blur_Frag_Uniforms :: enum u32 {Blur_Uniforms}

// blas_refit.comp.spv sha256 7025cc138e90d09c7dd4b21a01acbb9d43b161987c35280d807d1d29878bedda
BLAS_REFIT_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/blas_refit.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 4,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 1,
	num_uniform_buffers = 1,
	threadcount_x = 64,
	threadcount_y = 1,
	threadcount_z = 1,
}
Blas_Refit_Comp_Buffers :: enum u32 {positions, indices, order, chunks}
Blas_Refit_Comp_Write_Buffers :: enum u32 {nodes}
Blas_Refit_Comp_Uniforms :: enum u32 {Params}

// bloom_down.frag.spv sha256 0c6a396d73d52306182f7627e1d56be1719f216013f99d27b551d21626fa98f3
BLOOM_DOWN_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/bloom_down.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 1,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Bloom_Down_Frag_Samplers :: enum u32 {input}
Bloom_Down_Frag_Uniforms :: enum u32 {Bloom_Down_Uniforms}

// bloom_up.frag.spv sha256 5c31954aaf11c958715d6f765d9e7f352093db06e81724fddecfde1bbce58263
BLOOM_UP_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/bloom_up.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 2,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Bloom_Up_Frag_Samplers :: enum u32 {coarse, fine}
Bloom_Up_Frag_Uniforms :: enum u32 {Bloom_Up_Uniforms}

// clear.frag.spv sha256 7cc459a12d95caee7fadd940b75c635a402449001dffe971a49c38e08004fc0c
CLEAR_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/clear.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 1,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Clear_Frag_Samplers :: enum u32 {environment_map}
Clear_Frag_Uniforms :: enum u32 {Clear_Uniforms}

// clear.vert.spv sha256 68a8f109a83f930712bb14f07ade79583d5e556bd943527c9219bb7205f7c58d
CLEAR_VERT :: gpu.Shader_Desc{
	code = #load("shaders/clear.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 0,
}

// cull_count.comp.spv sha256 8e06e7ac8bba1c5fcbd952b4560bcb13f4c0147cad4f1fbb6cb775a9c1d407ec
when gpu.VULKAN {
	CULL_COUNT_COMP :: gpu.Compute_Pipeline_Desc{
		code = #load("shaders/cull_count.comp.spv", string),
		entrypoint = cstring("main"),
		format = SHADER_FORMAT,
		num_samplers = 0,
		num_readonly_storage_textures = 0,
		num_readonly_storage_buffers = 2,
		num_readwrite_storage_textures = 0,
		num_readwrite_storage_buffers = 1,
		num_uniform_buffers = 1,
		threadcount_x = 64,
		threadcount_y = 1,
		threadcount_z = 1,
	}
}
Cull_Count_Comp_Buffers :: enum u32 {chunks, groups}
Cull_Count_Comp_Write_Buffers :: enum u32 {totals}
Cull_Count_Comp_Uniforms :: enum u32 {Cull_Uniforms}

// cull_write.comp.spv sha256 b3832713eb98801e216f08fd991678d29e16703639e827c59b474555a4f457b6
when gpu.VULKAN {
	CULL_WRITE_COMP :: gpu.Compute_Pipeline_Desc{
		code = #load("shaders/cull_write.comp.spv", string),
		entrypoint = cstring("main"),
		format = SHADER_FORMAT,
		num_samplers = 0,
		num_readonly_storage_textures = 0,
		num_readonly_storage_buffers = 3,
		num_readwrite_storage_textures = 0,
		num_readwrite_storage_buffers = 1,
		num_uniform_buffers = 1,
		threadcount_x = 64,
		threadcount_y = 1,
		threadcount_z = 1,
	}
}
Cull_Write_Comp_Buffers :: enum u32 {chunks, groups, totals}
Cull_Write_Comp_Write_Buffers :: enum u32 {commands}
Cull_Write_Comp_Uniforms :: enum u32 {Cull_Uniforms}

// dab_area.comp.spv sha256 a442483d35866ef02a7bd09bcde3ef6ad1351eeee1500d8f932fc32273f9bdc5
DAB_AREA_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/dab_area.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 9,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 5,
	num_uniform_buffers = 1,
	threadcount_x = 256,
	threadcount_y = 1,
	threadcount_z = 1,
}
Dab_Area_Comp_Buffers :: enum u32 {indices, offsets, tris, slabs, dabs, normals, mask, tables, fade}
Dab_Area_Comp_Write_Buffers :: enum u32 {positions, partials, areas, scratch, heights}
Dab_Area_Comp_Uniforms :: enum u32 {Params}

// dab_move.comp.spv sha256 645bef0164085e2b415f2c071635f3863c76bbee82e503606bbb9d8a14c5118e
DAB_MOVE_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/dab_move.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 9,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 5,
	num_uniform_buffers = 1,
	threadcount_x = 256,
	threadcount_y = 1,
	threadcount_z = 1,
}
Dab_Move_Comp_Buffers :: enum u32 {indices, offsets, tris, slabs, dabs, normals, mask, tables, fade}
Dab_Move_Comp_Write_Buffers :: enum u32 {positions, partials, areas, scratch, heights}
Dab_Move_Comp_Uniforms :: enum u32 {Params}

// dab_reduce.comp.spv sha256 f1eafbd2b49beb23c595af521dad0feb2beb4ff817dae283b4ab3ba37ac6fb18
DAB_REDUCE_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/dab_reduce.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 9,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 5,
	num_uniform_buffers = 1,
	threadcount_x = 256,
	threadcount_y = 1,
	threadcount_z = 1,
}
Dab_Reduce_Comp_Buffers :: enum u32 {indices, offsets, tris, slabs, dabs, normals, mask, tables, fade}
Dab_Reduce_Comp_Write_Buffers :: enum u32 {positions, partials, areas, scratch, heights}
Dab_Reduce_Comp_Uniforms :: enum u32 {Params}

// dab_smooth_apply.comp.spv sha256 13c9945c7d39b85695c9ae7f5820cedb226da64448216948a81421f9fb3055b5
DAB_SMOOTH_APPLY_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/dab_smooth_apply.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 9,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 5,
	num_uniform_buffers = 1,
	threadcount_x = 256,
	threadcount_y = 1,
	threadcount_z = 1,
}
Dab_Smooth_Apply_Comp_Buffers :: enum u32 {indices, offsets, tris, slabs, dabs, normals, mask, tables, fade}
Dab_Smooth_Apply_Comp_Write_Buffers :: enum u32 {positions, partials, areas, scratch, heights}
Dab_Smooth_Apply_Comp_Uniforms :: enum u32 {Params}

// dab_smooth_targets.comp.spv sha256 252c9bda806713fd8a41ab608d3ebb84c7d6717aab2ed3eac286bc49656ab74a
DAB_SMOOTH_TARGETS_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/dab_smooth_targets.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 9,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 5,
	num_uniform_buffers = 1,
	threadcount_x = 256,
	threadcount_y = 1,
	threadcount_z = 1,
}
Dab_Smooth_Targets_Comp_Buffers :: enum u32 {indices, offsets, tris, slabs, dabs, normals, mask, tables, fade}
Dab_Smooth_Targets_Comp_Write_Buffers :: enum u32 {positions, partials, areas, scratch, heights}
Dab_Smooth_Targets_Comp_Uniforms :: enum u32 {Params}

// env_prefilter.frag.spv sha256 2008435844bb971eb3c4cbcd02ad636b00489be5981e4ceedc1012285ce90b99
ENV_PREFILTER_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/env_prefilter.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 1,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Env_Prefilter_Frag_Samplers :: enum u32 {source}
Env_Prefilter_Frag_Uniforms :: enum u32 {Prefilter_Uniforms}

// finish.frag.spv sha256 8932938b2271fc1f4e00ac594bfd937fb2aceb3c5f4bb2ae21e406f2e503ad87
FINISH_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/finish.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 2,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Finish_Frag_Samplers :: enum u32 {source, bloom}
Finish_Frag_Uniforms :: enum u32 {Finish_Uniforms}

// floor.frag.spv sha256 36e84be3612bb74ec3ca31b53b20f6baa6ab3d95935e601bc7db53e51f67169a
FLOOR_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/floor.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Floor_Frag_Uniforms :: enum u32 {Floor_Uniforms}

// floor.vert.spv sha256 aacdd9ba553dbbdaa5f6e58f759b2dd54dd5f5f1ec54e9d6e8d7f793d8c07c4a
FLOOR_VERT :: gpu.Shader_Desc{
	code = #load("shaders/floor.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 0,
}

// gtao.frag.spv sha256 010cfb70d8ebda4d93a14b591d351523c866328085bfa651ec75b9310d4b969e
GTAO_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/gtao.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 1,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Gtao_Frag_Samplers :: enum u32 {view_depth}
Gtao_Frag_Uniforms :: enum u32 {Gtao_Uniforms}

// mesh.frag.spv sha256 fab59d260f09aec3e512eb8aa766ebb6060398717ed46ab8ff1f8bc49636bccb
MESH_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/mesh.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 2,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 2,
}
Mesh_Frag_Samplers :: enum u32 {matcap, environment_map}
Mesh_Frag_Uniforms :: enum u32 {Material_Uniforms, Slot_Uniforms}

// mesh.vert.spv sha256 7210bb53cb69eea984a2b3481c69813f790ff6ee8fb67fc9b0673bf097c6ecd4
MESH_VERT :: gpu.Shader_Desc{
	code = #load("shaders/mesh.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 1,
	num_uniform_buffers = 1,
}
Mesh_Vert_Buffers :: enum u32 {paint}
Mesh_Vert_Uniforms :: enum u32 {Frame_Uniforms}

// mesh_area.frag.spv sha256 c6ba3f094f1ad5be4e8c19cbdc2395f180a0cde2bc087094c4040a10b76a612e
MESH_AREA_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/mesh_area.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 2,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 2,
}
Mesh_Area_Frag_Samplers :: enum u32 {matcap, environment_map}
Mesh_Area_Frag_Uniforms :: enum u32 {Material_Uniforms, Slot_Uniforms}

// mesh_wire.frag.spv sha256 5e656c634b45494108f2ccc0f7efd209642545fde041abcf7c5f92cfff8e9e10
MESH_WIRE_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/mesh_wire.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 2,
	num_storage_textures = 0,
	num_storage_buffers = 1,
	num_uniform_buffers = 2,
}
Mesh_Wire_Frag_Samplers :: enum u32 {matcap, environment_map}
Mesh_Wire_Frag_Buffers :: enum u32 {tri_edges}
Mesh_Wire_Frag_Uniforms :: enum u32 {Material_Uniforms, Slot_Uniforms}

// mesh_wire.vert.spv sha256 873d2dc077f86d5f1347730b2fd1f6922f9f373f9fc38939823f560022e84f99
MESH_WIRE_VERT :: gpu.Shader_Desc{
	code = #load("shaders/mesh_wire.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 1,
	num_uniform_buffers = 1,
}
Mesh_Wire_Vert_Buffers :: enum u32 {paint}
Mesh_Wire_Vert_Uniforms :: enum u32 {Frame_Uniforms}

// node_bounds.comp.spv sha256 d0ef7dd31637b49a1428fa1829a6b5992fe3ff0ce78975971132a4aa6c281a7c
NODE_BOUNDS_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/node_bounds.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 3,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 1,
	num_uniform_buffers = 1,
	threadcount_x = 256,
	threadcount_y = 1,
	threadcount_z = 1,
}
Node_Bounds_Comp_Buffers :: enum u32 {positions, nodes, shared}
Node_Bounds_Comp_Write_Buffers :: enum u32 {bounds}
Node_Bounds_Comp_Uniforms :: enum u32 {Params}

// node_normals.comp.spv sha256 95b2b2b708f549f07d3f978b968e3eb1969871aa4710aa37137132f008adbefa
NODE_NORMALS_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/node_normals.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 5,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 1,
	num_uniform_buffers = 1,
	threadcount_x = 256,
	threadcount_y = 1,
	threadcount_z = 1,
}
Node_Normals_Comp_Buffers :: enum u32 {indices, offsets, tris, positions, slabs}
Node_Normals_Comp_Write_Buffers :: enum u32 {normals}
Node_Normals_Comp_Uniforms :: enum u32 {Params}

// ray_query_check.comp.spv sha256 fe0652b4a07d5eb132524facd8b48c185074b8cc3914ddf3ff72d27829c3ac77
RAY_QUERY_CHECK_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/ray_query_check.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 1,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 1,
	num_uniform_buffers = 1,
	threadcount_x = 64,
	threadcount_y = 1,
	threadcount_z = 1,
}
Ray_Query_Check_Comp_Buffers :: enum u32 {rays}
Ray_Query_Check_Comp_Write_Buffers :: enum u32 {hits}
Ray_Query_Check_Comp_Uniforms :: enum u32 {Params}

// render_atrous.frag.spv sha256 9925bb31d909c91dc08f7950dac7a8b7a5c8e0d39104c0cfa6b4bd88507e2204
RENDER_ATROUS_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/render_atrous.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 3,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Render_Atrous_Frag_Samplers :: enum u32 {src, guide_albedo, guide_normal}
Render_Atrous_Frag_Uniforms :: enum u32 {Atrous_Uniforms}

// render_display.frag.spv sha256 e025e878a96555d028f2948b1b455e73f34df9ed7bee049f0119cfed37b7992c
RENDER_DISPLAY_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/render_display.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 4,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Render_Display_Frag_Samplers :: enum u32 {view_color, accum, denoised, guide_albedo}
Render_Display_Frag_Uniforms :: enum u32 {Display_Uniforms}

// render_display_linear.frag.spv sha256 6f6054655839ff6f2dae82e2acb65d33bf48425e2cc27ec6dc69a72cf658ff26
RENDER_DISPLAY_LINEAR_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/render_display_linear.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 4,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Render_Display_Linear_Frag_Samplers :: enum u32 {view_color, accum, denoised, guide_albedo}
Render_Display_Linear_Frag_Uniforms :: enum u32 {Display_Uniforms}

// render_trace.comp.spv sha256 749b3c1b613998d7e4257dfe972e14a93e41b0b457a8bf3cd5f3b6210606ce8f
RENDER_TRACE_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/render_trace.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 14,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 8,
	num_readwrite_storage_textures = 3,
	num_readwrite_storage_buffers = 0,
	num_uniform_buffers = 1,
	threadcount_x = 8,
	threadcount_y = 8,
	threadcount_z = 1,
}
Render_Trace_Comp_Samplers :: enum u32 {prev, environment_map, env_table, prev_albedo, prev_normal, map0, map1, map2, map3, map4, map5, map6, map7, map8}
Render_Trace_Comp_Buffers :: enum u32 {positions, indices, attributes, nodes, order, chunks, items, textured}
Render_Trace_Comp_Write_Textures :: enum u32 {next, guide_albedo, guide_normal}
Render_Trace_Comp_Uniforms :: enum u32 {Render_Uniforms}

// render_trace_maps.comp.spv sha256 24fcd68a5ea3648c6e25369a72378132380d0f2d93756a51c586e82065928a87
when gpu.VULKAN {
	RENDER_TRACE_MAPS_COMP :: gpu.Compute_Pipeline_Desc{
		code = #load("shaders/render_trace_maps.comp.spv", string),
		entrypoint = cstring("main"),
		format = SHADER_FORMAT,
		num_samplers = 5,
		num_readonly_storage_textures = 0,
		num_readonly_storage_buffers = 8,
		num_readwrite_storage_textures = 3,
		num_readwrite_storage_buffers = 0,
		num_uniform_buffers = 1,
		threadcount_x = 8,
		threadcount_y = 8,
		threadcount_z = 1,
	}
}
Render_Trace_Maps_Comp_Samplers :: enum u32 {prev, environment_map, env_table, prev_albedo, prev_normal}
Render_Trace_Maps_Comp_Buffers :: enum u32 {positions, indices, attributes, nodes, order, chunks, items, textured}
Render_Trace_Maps_Comp_Write_Textures :: enum u32 {next, guide_albedo, guide_normal}
Render_Trace_Maps_Comp_Uniforms :: enum u32 {Render_Uniforms}

// render_trace_maps_rq.comp.spv sha256 c0f91b238e87f647e524b58919dcd291eb803beeaee920722e92cdc3959d6dc9
when gpu.VULKAN {
	RENDER_TRACE_MAPS_RQ_COMP :: gpu.Compute_Pipeline_Desc{
		code = #load("shaders/render_trace_maps_rq.comp.spv", string),
		entrypoint = cstring("main"),
		format = SHADER_FORMAT,
		num_samplers = 5,
		num_readonly_storage_textures = 0,
		num_readonly_storage_buffers = 8,
		num_readwrite_storage_textures = 3,
		num_readwrite_storage_buffers = 0,
		num_uniform_buffers = 1,
		threadcount_x = 8,
		threadcount_y = 8,
		threadcount_z = 1,
	}
}
Render_Trace_Maps_Rq_Comp_Samplers :: enum u32 {prev, environment_map, env_table, prev_albedo, prev_normal}
Render_Trace_Maps_Rq_Comp_Buffers :: enum u32 {positions, indices, attributes, nodes, order, chunks, items, textured}
Render_Trace_Maps_Rq_Comp_Write_Textures :: enum u32 {next, guide_albedo, guide_normal}
Render_Trace_Maps_Rq_Comp_Uniforms :: enum u32 {Render_Uniforms}

// render_trace_rq.comp.spv sha256 89fc923d77c57d992ad44258eb0a20035697de8e11188ed3cf67a610595b81f6
RENDER_TRACE_RQ_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/render_trace_rq.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 14,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 8,
	num_readwrite_storage_textures = 3,
	num_readwrite_storage_buffers = 0,
	num_uniform_buffers = 1,
	threadcount_x = 8,
	threadcount_y = 8,
	threadcount_z = 1,
}
Render_Trace_Rq_Comp_Samplers :: enum u32 {prev, environment_map, env_table, prev_albedo, prev_normal, map0, map1, map2, map3, map4, map5, map6, map7, map8}
Render_Trace_Rq_Comp_Buffers :: enum u32 {positions, indices, attributes, nodes, order, chunks, items, textured}
Render_Trace_Rq_Comp_Write_Textures :: enum u32 {next, guide_albedo, guide_normal}
Render_Trace_Rq_Comp_Uniforms :: enum u32 {Render_Uniforms}

// shadow.frag.spv sha256 a64ba17c5c6cc597c34c55839d04afec66cc69a2cfe58cea1e62764ea83888ae
SHADOW_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/shadow.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 0,
}

// shadow.vert.spv sha256 67f5bdaedd655f3d3d4645c816d7fa3c342198996e711c1d978a355b70564690
SHADOW_VERT :: gpu.Shader_Desc{
	code = #load("shaders/shadow.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Shadow_Vert_Uniforms :: enum u32 {Shadow_Uniforms}

// sharpen.frag.spv sha256 1cf0840b1af5897bdec06a7096de32ca98fff55a9f872f5481f956da61542d7e
SHARPEN_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/sharpen.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 1,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Sharpen_Frag_Samplers :: enum u32 {graded}
Sharpen_Frag_Uniforms :: enum u32 {Sharpen_Uniforms}

// skin.frag.spv sha256 3eb63a8f46d19ddd8dd3ad78b984b3cbb5faee7e7f44ca6837a5c6f54f81f388
SKIN_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/skin.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 2,
	num_storage_textures = 0,
	num_storage_buffers = 2,
	num_uniform_buffers = 2,
}
Skin_Frag_Samplers :: enum u32 {matcap, environment_map}
Skin_Frag_Buffers :: enum u32 {skin_normals, skin_tris}
Skin_Frag_Uniforms :: enum u32 {Material_Uniforms, Slot_Uniforms}

// skin.vert.spv sha256 9a2d581e7dd24bb2640fd25d6f4dbe0c6fae5abb018aa7307da96f2265785b00
SKIN_VERT :: gpu.Shader_Desc{
	code = #load("shaders/skin.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 4,
	num_uniform_buffers = 1,
}
Skin_Vert_Buffers :: enum u32 {paint, indices, positions, normals}
Skin_Vert_Uniforms :: enum u32 {Frame_Uniforms}

// skin_tess.vert.spv sha256 86761715b497e85df499a52459ed5e39951cb585729f148d90989a31e9d27921
SKIN_TESS_VERT :: gpu.Shader_Desc{
	code = #load("shaders/skin_tess.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 7,
	num_uniform_buffers = 1,
}
Skin_Tess_Vert_Buffers :: enum u32 {paint, indices, positions, normals, skin_normals, skin_tris, skin_heights}
Skin_Tess_Vert_Uniforms :: enum u32 {Frame_Uniforms}

// smooth_all.comp.spv sha256 5b053976a10cbb7699d06d98698f7e1577599bda5da5246fe9e2b8ab1871f7bc
SMOOTH_ALL_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/smooth_all.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 0,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 5,
	num_readwrite_storage_textures = 0,
	num_readwrite_storage_buffers = 1,
	num_uniform_buffers = 1,
	threadcount_x = 256,
	threadcount_y = 1,
	threadcount_z = 1,
}
Smooth_All_Comp_Buffers :: enum u32 {indices, offsets, tris, weights, src}
Smooth_All_Comp_Write_Buffers :: enum u32 {dst}
Smooth_All_Comp_Uniforms :: enum u32 {Params}

// studio_composite.frag.spv sha256 685cca1bac19695ac23cbedf1f1bb14ea674f301b8388403eb8bc6f309963264
STUDIO_COMPOSITE_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/studio_composite.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 3,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Studio_Composite_Frag_Samplers :: enum u32 {view_color, accum, under}
Studio_Composite_Frag_Uniforms :: enum u32 {Composite_Uniforms}

// studio_depth_keep.frag.spv sha256 9850cb5ec8220cde809fb6b13cf23c465f7c5e05908af7b0657c65aea3f43929
STUDIO_DEPTH_KEEP_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/studio_depth_keep.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 1,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 0,
}
Studio_Depth_Keep_Frag_Samplers :: enum u32 {view_depth}

// studio_gather.frag.spv sha256 a2b5bb1ba5f07cf3b06c709c2f9e52355ea4c3ec406031729408d10cd1090f7c
STUDIO_GATHER_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/studio_gather.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 2,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Studio_Gather_Frag_Samplers :: enum u32 {view_depth, shadow_depth}
Studio_Gather_Frag_Uniforms :: enum u32 {Gather_Uniforms}

// studio_reproject.frag.spv sha256 2c5e9cfde56a6c43de123a19b0e7e2a9c652563f35bba0af231fe9c45c737483
STUDIO_REPROJECT_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/studio_reproject.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 3,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Studio_Reproject_Frag_Samplers :: enum u32 {view_depth, prev_depth, prev_accum}
Studio_Reproject_Frag_Uniforms :: enum u32 {Reproject_Uniforms}

// studio_trace.comp.spv sha256 01c0be6d1e268688eb222b306753773626b0d1d05ef6ff3227d26533aa965c5b
STUDIO_TRACE_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/studio_trace.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 1,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 6,
	num_readwrite_storage_textures = 1,
	num_readwrite_storage_buffers = 0,
	num_uniform_buffers = 1,
	threadcount_x = 8,
	threadcount_y = 8,
	threadcount_z = 1,
}
Studio_Trace_Comp_Samplers :: enum u32 {view_depth}
Studio_Trace_Comp_Buffers :: enum u32 {positions, indices, nodes, order, chunks, tlas}
Studio_Trace_Comp_Write_Textures :: enum u32 {visible}
Studio_Trace_Comp_Uniforms :: enum u32 {Trace_Uniforms}

// studio_trace_add.frag.spv sha256 a035bc36ededd91e986bb2774b8124d7f6b1d42549b5d634b7357b8b5da70759
STUDIO_TRACE_ADD_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/studio_trace_add.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 2,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Studio_Trace_Add_Frag_Samplers :: enum u32 {visible, view_depth}
Studio_Trace_Add_Frag_Uniforms :: enum u32 {Add_Uniforms}

// studio_trace_rq.comp.spv sha256 7fe039f4e2f2892d887ce9f23c542abc06e9cde6d8179ba55c69c2794e48300b
STUDIO_TRACE_RQ_COMP :: gpu.Compute_Pipeline_Desc{
	code = #load("shaders/studio_trace_rq.comp" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	num_samplers = 1,
	num_readonly_storage_textures = 0,
	num_readonly_storage_buffers = 2,
	num_readwrite_storage_textures = 1,
	num_readwrite_storage_buffers = 0,
	num_uniform_buffers = 1,
	threadcount_x = 8,
	threadcount_y = 8,
	threadcount_z = 1,
}
Studio_Trace_Rq_Comp_Samplers :: enum u32 {view_depth}
Studio_Trace_Rq_Comp_Buffers :: enum u32 {instances, run_first}
Studio_Trace_Rq_Comp_Write_Textures :: enum u32 {visible}
Studio_Trace_Rq_Comp_Uniforms :: enum u32 {Trace_Uniforms}

// textured.frag.spv sha256 9482079816e4dad21087c23b1babde2db067e294f135f543fd462ada49adc6a8
TEXTURED_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/textured.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 5,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Textured_Frag_Samplers :: enum u32 {matcap, environment_map, base_map, orm_map, normal_map}
Textured_Frag_Uniforms :: enum u32 {Material_Uniforms}

// textured.vert.spv sha256 033fbac66fe4bb7b2434f90c061c869f285ab7326720bcd84fcaaa9a89c0603f
TEXTURED_VERT :: gpu.Shader_Desc{
	code = #load("shaders/textured.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Textured_Vert_Uniforms :: enum u32 {Frame_Uniforms}

// textured_area.frag.spv sha256 23c9a87eae41f2dd4210a38c261da62ed37595aadc8807bb175c83e9e5aa5650
TEXTURED_AREA_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/textured_area.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 5,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Textured_Area_Frag_Samplers :: enum u32 {matcap, environment_map, base_map, orm_map, normal_map}
Textured_Area_Frag_Uniforms :: enum u32 {Material_Uniforms}

// ui.frag.spv sha256 27b36442b9eb8e6ead0810a4529e9bfe0b995ed5c481cb5e7586856a36706ff2
UI_FRAG :: gpu.Shader_Desc{
	code = #load("shaders/ui.frag" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Fragment,
	num_samplers = 1,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Ui_Frag_Samplers :: enum u32 {tex}
Ui_Frag_Uniforms :: enum u32 {Ui_Fragment_Uniforms}

// ui.vert.spv sha256 9d9cf5632916c5e2f9ef95d2be7feee6066296d6e560d2e1a267eb0355c06100
UI_VERT :: gpu.Shader_Desc{
	code = #load("shaders/ui.vert" + SHADER_EXT, string),
	entrypoint = SHADER_ENTRY,
	format = SHADER_FORMAT,
	stage = .Vertex,
	num_samplers = 0,
	num_storage_textures = 0,
	num_storage_buffers = 0,
	num_uniform_buffers = 1,
}
Ui_Vert_Uniforms :: enum u32 {Ui_Vertex_Uniforms}
