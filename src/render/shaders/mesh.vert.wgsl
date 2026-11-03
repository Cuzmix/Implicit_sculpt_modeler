// slangc wgsl from mesh.vert.spv sha256 7210bb53cb69eea984a2b3481c69813f790ff6ee8fb67fc9b0673bf097c6ecd4
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
@binding(0) @group(0) var<storage, read> paint_0 : array<vec2<u32>>;

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

fn srgb_decode_0( c_0 : vec3<f32>) -> vec3<f32>
{
    return mix(c_0 / vec3<f32>(12.92000007629394531f), pow((c_0 + vec3<f32>(0.05499999970197678f)) / vec3<f32>(1.0549999475479126f), vec3<f32>(2.40000009536743164f)), step(vec3<f32>(0.04044999927282333f), c_0));
}

fn group_color_0( g_0 : u32) -> vec3<f32>
{
    var _S10 : vec3<f32> = vec3<f32>(3.0f);
    var _S11 : vec3<f32> = vec3<f32>(1.0f);
    var rgb_0 : vec3<f32> = clamp(abs(fract(vec3<f32>(fract(f32(g_0) * 0.6180340051651001f + 0.11999999731779099f)) + vec3<f32>(0.0f, 2.0f, 1.0f) / _S10) * vec3<f32>(6.0f) - _S10) - vec3<f32>(1.0f), vec3<f32>(0.0f), _S11);
    var light_0 : f32;
    if(((g_0 & (u32(1)))) == u32(0))
    {
        light_0 = 0.75f;
    }
    else
    {
        light_0 = 0.55000001192092896f;
    }
    return mix(_S11, rgb_0, vec3<f32>(0.55000001192092896f)) * vec3<f32>(light_0);
}

struct Mesh_Vertex_Out_0
{
    @builtin(position) position_0 : vec4<f32>,
    @location(0) view_normal_0 : vec3<f32>,
    @location(1) view_pos_0 : vec3<f32>,
    @location(3) mask_1 : f32,
    @location(4) paint_1 : vec4<f32>,
    @interpolate(flat) @location(5) group_0 : vec3<f32>,
    @location(2) mesh_pos_0 : vec3<f32>,
    @interpolate(flat) @location(6) slot_0 : u32,
};

struct vertexInput_0
{
    @location(0) in_position_0 : vec3<f32>,
    @location(1) in_normal_oct_0 : vec2<f32>,
};

struct Mesh_Varyings_0
{
     _S12 : vec3<f32>,
     _S13 : vec3<f32>,
     _S14 : f32,
     _S15 : vec4<f32>,
     _S16 : vec3<f32>,
     _S17 : vec3<f32>,
     _S18 : u32,
};

struct Mesh_Vertex_Out_1
{
     _S19 : vec4<f32>,
     v_1 : Mesh_Varyings_0,
};

@vertex
fn main( _S20 : vertexInput_0, @builtin(vertex_index) vertex_0 : u32) -> Mesh_Vertex_Out_0
{
    var o_0 : Mesh_Vertex_Out_1;
    var _S21 : f32 = o_0.v_1._S14;
    var in_normal_0 : vec3<f32>;
    decode_normal_mask_0(_S20.in_normal_oct_0, &(in_normal_0), &(_S21));
    o_0.v_1._S14 = _S21;
    o_0.v_1._S15 = vec4<f32>(0.0f);
    o_0.v_1._S16 = vec3<f32>(-1.0f);
    o_0.v_1._S18 = u32(0);
    var _S22 : bool;
    if((Frame_Uniforms_0.options_0.x) > 0.5f)
    {
        _S22 = true;
    }
    else
    {
        _S22 = (Frame_Uniforms_0.options_0.y) > 0.5f;
    }
    if(_S22)
    {
        _S22 = true;
    }
    else
    {
        _S22 = (Frame_Uniforms_0.options_0.z) > 0.5f;
    }
    if(_S22)
    {
        var p_0 : vec2<u32> = paint_0[vertex_0];
        var group_1 : u32 = ((p_0.y) & (u32(65535)));
        if((Frame_Uniforms_0.options_0.x) > 0.5f)
        {
            var _S23 : vec4<f32> = unpack4x8unorm(p_0.x);
            o_0.v_1._S15 = vec4<f32>(srgb_decode_0(_S23.xyz), _S23.w);
        }
        if((Frame_Uniforms_0.options_0.y) > 0.5f)
        {
            o_0.v_1._S16 = group_color_0(group_1);
        }
        if((Frame_Uniforms_0.options_0.z) > 0.5f)
        {
            var k_0 : u32 = u32(1);
            for(;;)
            {
                if(k_0 < u32(16))
                {
                }
                else
                {
                    break;
                }
                if((Frame_Uniforms_0.slot_group_0[(k_0 >> (u32(2)))][(k_0 & (u32(3)))]) == group_1)
                {
                    o_0.v_1._S18 = k_0;
                }
                k_0 = k_0 + u32(1);
            }
        }
    }
    var world_0 : vec4<f32> = (((mat4x4<f32>(Frame_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(_S20.in_position_0, 1.0f))));
    o_0._S19 = (((mat4x4<f32>(Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(3)])) * (world_0)));
    var _S24 : mat4x4<f32> = mat4x4<f32>(Frame_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(3)]);
    var _S25 : mat4x4<f32> = mat4x4<f32>(Frame_Uniforms_0.view_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(3)]);
    o_0.v_1._S12 = ((((((mat3x3<f32>(_S25[i32(0)].xyz, _S25[i32(1)].xyz, _S25[i32(2)].xyz)) * (mat3x3<f32>(_S24[i32(0)].xyz, _S24[i32(1)].xyz, _S24[i32(2)].xyz))))) * (in_normal_0)));
    o_0.v_1._S13 = (((mat4x4<f32>(Frame_Uniforms_0.view_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(3)])) * (world_0))).xyz;
    o_0.v_1._S17 = _S20.in_position_0;
    var _S26 : Mesh_Vertex_Out_0;
    _S26.position_0 = o_0._S19;
    _S26.view_normal_0 = o_0.v_1._S12;
    _S26.view_pos_0 = o_0.v_1._S13;
    _S26.mask_1 = o_0.v_1._S14;
    _S26.paint_1 = o_0.v_1._S15;
    _S26.group_0 = o_0.v_1._S16;
    _S26.mesh_pos_0 = o_0.v_1._S17;
    _S26.slot_0 = o_0.v_1._S18;
    return _S26;
}

