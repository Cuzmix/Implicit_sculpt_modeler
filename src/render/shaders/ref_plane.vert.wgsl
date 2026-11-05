// slangc wgsl from ref_plane.vert.spv sha256 23b3de9e44cf4d50b4150476d8f3787854776bc54327a7b1bd7c774f6db2c7bf
diagnostic(off, derivative_uniformity);
struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Ref_Plane_Uniforms_std140_0
{
    @align(16) view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) center_0 : vec4<f32>,
    @align(16) right_0 : vec4<f32>,
    @align(16) up_0 : vec4<f32>,
    @align(16) uv_top_0 : vec4<f32>,
    @align(16) uv_bottom_0 : vec4<f32>,
};

@binding(0) @group(1) var<uniform> Ref_Plane_Uniforms_0 : SLANG_ParameterGroup_Ref_Plane_Uniforms_std140_0;
struct Vertex_Out_0
{
    @builtin(position) position_0 : vec4<f32>,
    @location(0) uv_0 : vec2<f32>,
};

@vertex
fn main(@builtin(vertex_index) vertex_0 : u32) -> Vertex_Out_0
{
    var CORNER_0 : array<u32, i32(6)> = array<u32, i32(6)>( u32(0), u32(1), u32(2), u32(0), u32(2), u32(3) );
    var SIDE_0 : array<vec2<f32>, i32(4)> = array<vec2<f32>, i32(4)>( vec2<f32>(-1.0f, 1.0f), vec2<f32>(1.0f, 1.0f), vec2<f32>(1.0f, -1.0f), vec2<f32>(-1.0f, -1.0f) );
    var _S1 : u32 = vertex_0 % u32(6);
    var p_0 : vec3<f32> = Ref_Plane_Uniforms_0.center_0.xyz + Ref_Plane_Uniforms_0.right_0.xyz * vec3<f32>(SIDE_0[CORNER_0[_S1]].x) + Ref_Plane_Uniforms_0.up_0.xyz * vec3<f32>(SIDE_0[CORNER_0[_S1]].y);
    var uvs_0 : array<vec2<f32>, i32(4)> = array<vec2<f32>, i32(4)>( Ref_Plane_Uniforms_0.uv_top_0.xy, Ref_Plane_Uniforms_0.uv_top_0.zw, Ref_Plane_Uniforms_0.uv_bottom_0.xy, Ref_Plane_Uniforms_0.uv_bottom_0.zw );
    var o_0 : Vertex_Out_0;
    o_0.uv_0 = uvs_0[CORNER_0[_S1]];
    var clip_0 : vec4<f32> = (((mat4x4<f32>(Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(0)][i32(0)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(0)][i32(1)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(0)][i32(2)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(0)][i32(3)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(1)][i32(0)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(1)][i32(1)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(1)][i32(2)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(1)][i32(3)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(2)][i32(0)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(2)][i32(1)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(2)][i32(2)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(2)][i32(3)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(3)][i32(0)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(3)][i32(1)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(3)][i32(2)], Ref_Plane_Uniforms_0.view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(p_0, 1.0f))));
    var _S2 : f32 = clip_0.w;
    o_0.position_0 = vec4<f32>(clip_0.xy, _S2, _S2);
    return o_0;
}

