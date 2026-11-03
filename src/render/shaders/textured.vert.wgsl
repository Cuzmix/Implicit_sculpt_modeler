// slangc wgsl from textured.vert.spv sha256 033fbac66fe4bb7b2434f90c061c869f285ab7326720bcd84fcaaa9a89c0603f
diagnostic(off, derivative_uniformity);
struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Frame_Uniforms_std140_0
{
    @align(16) view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) view_0 : _MatrixStorage_float4x4std140_0,
    @align(16) model_0 : _MatrixStorage_float4x4std140_0,
    @align(16) options_0 : vec4<f32>,
    @align(16) slot_group_0 : array<vec4<u32>, i32(4)>,
    @align(16) skin_0 : vec4<u32>,
};

@binding(0) @group(1) var<uniform> Frame_Uniforms_0 : SLANG_ParameterGroup_Frame_Uniforms_std140_0;
fn oct_decode_0( e_0 : vec2<f32>) -> vec3<f32>
{
    var _S1 : f32 = e_0.x;
    var _S2 : f32 = e_0.y;
    var _S3 : vec3<f32> = vec3<f32>(e_0, 1.0f - abs(_S1) - abs(_S2));
    var v_0 : vec3<f32> = _S3;
    if((_S3.z) < 0.0f)
    {
        var _S4 : vec2<f32> = vec2<f32>(1.0f) - abs(e_0.yx);
        var _S5 : f32;
        if(_S1 >= 0.0f)
        {
            _S5 = 1.0f;
        }
        else
        {
            _S5 = -1.0f;
        }
        var _S6 : f32;
        if(_S2 >= 0.0f)
        {
            _S6 = 1.0f;
        }
        else
        {
            _S6 = -1.0f;
        }
        var _S7 : vec2<f32> = _S4 * vec2<f32>(_S5, _S6);
        v_0.x = _S7.x;
        v_0.y = _S7.y;
    }
    return normalize(v_0);
}

fn decode_normal_mask_0( normal_oct_0 : vec2<f32>,  normal_0 : ptr<function, vec3<f32>>,  mask_0 : ptr<function, f32>)
{
    var _S8 : vec2<f32> = vec2<f32>(32767.0f);
    var _S9 : vec2<i32> = vec2<i32>(round(max(normal_oct_0, vec2<f32>(-1.0f)) * _S8));
    (*normal_0) = oct_decode_0(vec2<f32>((_S9 & (vec2<i32>(i32(-16))))) / _S8);
    (*mask_0) = f32(((((((_S9.x) & (i32(15)))) << (u32(4)))) | ((((_S9.y) & (i32(15))))))) / 255.0f;
    return;
}

struct Mesh_Vertex_Out_0
{
    @builtin(position) position_0 : vec4<f32>,
    @location(0) view_normal_0 : vec3<f32>,
    @location(1) view_pos_0 : vec3<f32>,
    @location(3) mask_1 : f32,
    @location(4) paint_0 : vec4<f32>,
    @interpolate(flat) @location(5) group_0 : vec3<f32>,
    @location(2) mesh_pos_0 : vec3<f32>,
    @interpolate(flat) @location(6) slot_0 : u32,
    @location(7) uv_0 : vec2<f32>,
    @location(8) view_tangent_0 : vec4<f32>,
};

struct vertexInput_0
{
    @location(0) in_position_0 : vec3<f32>,
    @location(1) in_normal_oct_0 : vec2<f32>,
    @location(2) in_tangent_0 : vec4<f32>,
    @location(3) in_uv_0 : vec2<f32>,
};

struct Mesh_Varyings_0
{
     _S10 : vec3<f32>,
     _S11 : vec3<f32>,
     _S12 : f32,
     _S13 : vec4<f32>,
     _S14 : vec3<f32>,
     _S15 : vec3<f32>,
     _S16 : u32,
     _S17 : vec2<f32>,
     _S18 : vec4<f32>,
};

struct Mesh_Vertex_Out_1
{
     _S19 : vec4<f32>,
     v_1 : Mesh_Varyings_0,
};

@vertex
fn main( _S20 : vertexInput_0) -> Mesh_Vertex_Out_0
{
    var o_0 : Mesh_Vertex_Out_1;
    var _S21 : f32 = o_0.v_1._S12;
    var in_normal_0 : vec3<f32>;
    decode_normal_mask_0(_S20.in_normal_oct_0, &(in_normal_0), &(_S21));
    o_0.v_1._S12 = _S21;
    o_0.v_1._S13 = vec4<f32>(0.0f);
    o_0.v_1._S14 = vec3<f32>(-1.0f);
    o_0.v_1._S16 = u32(0);
    var world_0 : vec4<f32> = (((mat4x4<f32>(Frame_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(_S20.in_position_0, 1.0f))));
    o_0._S19 = (((mat4x4<f32>(Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(3)])) * (world_0)));
    var _S22 : mat4x4<f32> = mat4x4<f32>(Frame_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(3)]);
    var _S23 : mat4x4<f32> = mat4x4<f32>(Frame_Uniforms_0.view_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(3)]);
    var turn_0 : mat3x3<f32> = (((mat3x3<f32>(_S23[i32(0)].xyz, _S23[i32(1)].xyz, _S23[i32(2)].xyz)) * (mat3x3<f32>(_S22[i32(0)].xyz, _S22[i32(1)].xyz, _S22[i32(2)].xyz))));
    var _S24 : mat3x3<f32> = turn_0 * (1.0f / length(turn_0[i32(0)]));
    o_0.v_1._S10 = (((_S24) * (in_normal_0)));
    var _S25 : vec3<f32> = (((_S24) * (_S20.in_tangent_0.xyz)));
    var _S26 : f32;
    if((_S20.in_tangent_0.w) < 0.0f)
    {
        _S26 = -1.0f;
    }
    else
    {
        _S26 = 1.0f;
    }
    o_0.v_1._S18 = vec4<f32>(_S25, _S26);
    o_0.v_1._S11 = (((mat4x4<f32>(Frame_Uniforms_0.view_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(3)])) * (world_0))).xyz;
    o_0.v_1._S15 = _S20.in_position_0;
    o_0.v_1._S17 = _S20.in_uv_0;
    var _S27 : Mesh_Vertex_Out_0;
    _S27.position_0 = o_0._S19;
    _S27.view_normal_0 = o_0.v_1._S10;
    _S27.view_pos_0 = o_0.v_1._S11;
    _S27.mask_1 = o_0.v_1._S12;
    _S27.paint_0 = o_0.v_1._S13;
    _S27.group_0 = o_0.v_1._S14;
    _S27.mesh_pos_0 = o_0.v_1._S15;
    _S27.slot_0 = o_0.v_1._S16;
    _S27.uv_0 = o_0.v_1._S17;
    _S27.view_tangent_0 = o_0.v_1._S18;
    return _S27;
}

