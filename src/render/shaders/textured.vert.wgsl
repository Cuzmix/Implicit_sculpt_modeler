// slangc wgsl from textured.vert.spv sha256 e83581949377b10115bd06830301111e2fc1207d80e7550deedb5e5604c1795e
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
    @align(16) blend_0 : vec4<u32>,
};

@binding(0) @group(1) var<uniform> Frame_Uniforms_0 : SLANG_ParameterGroup_Frame_Uniforms_std140_0;
@binding(0) @group(0) var<storage, read> slot_vertex_0 : array<u32>;

@binding(2) @group(0) var<storage, read> positions_0 : array<f32>;

@binding(4) @group(0) var<storage, read> normals_0 : array<u32>;

@binding(6) @group(0) var<storage, read> paint_0 : array<vec2<u32>>;

@binding(8) @group(0) var<storage, read> paint_material_words_0 : array<u32>;

@binding(10) @group(0) var<storage, read> blend_table_0 : array<u32>;

@binding(12) @group(0) var<storage, read> blend_pages_0 : array<vec4<u32>>;

fn srgb_decode_0( c_0 : vec3<f32>) -> vec3<f32>
{
    return mix(c_0 / vec3<f32>(12.92000007629394531f), pow((c_0 + vec3<f32>(0.05499999970197678f)) / vec3<f32>(1.0549999475479126f), vec3<f32>(2.40000009536743164f)), step(vec3<f32>(0.04044999927282333f), c_0));
}

fn paint_material_0( word_0 : u32) -> vec4<f32>
{
    return unpack4x8unorm(word_0);
}

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

fn blend_entry_0( vertex_0 : u32) -> vec4<u32>
{
    if((Frame_Uniforms_0.blend_0.x) == u32(0))
    {
        return vec4<u32>(u32(0));
    }
    var page_0 : u32 = blend_table_0[(vertex_0 >> (u32(10)))];
    if(page_0 == u32(4294967295))
    {
        return vec4<u32>(u32(0));
    }
    return blend_pages_0[page_0 * u32(1024) + ((vertex_0 & (u32(1023))))];
}

fn blend_apply_0( vertex_1 : u32,  position_0 : ptr<function, vec3<f32>>,  normal_1 : ptr<function, vec3<f32>>)
{
    var e_1 : vec4<u32> = blend_entry_0(vertex_1);
    (*position_0) = (*position_0) + (bitcast<vec3<f32>>((e_1.xyz)));
    var _S10 : u32 = e_1.w;
    var amount_0 : f32 = f32((((_S10 >> (u32(24)))) & (u32(15)))) / 15.0f;
    if(amount_0 <= 0.0f)
    {
        return;
    }
    (*normal_1) = normalize(mix((*normal_1), oct_decode_0(vec2<f32>(f32((_S10 & (u32(4095)))), f32((((_S10 >> (u32(12)))) & (u32(4095))))) / vec2<f32>(4095.0f) * vec2<f32>(2.0f) - vec2<f32>(1.0f)), vec3<f32>(amount_0)));
    return;
}

struct Mesh_Vertex_Out_0
{
    @builtin(position) position_1 : vec4<f32>,
    @location(0) view_normal_0 : vec3<f32>,
    @location(1) view_pos_0 : vec3<f32>,
    @location(3) mask_1 : f32,
    @location(4) paint_1 : vec4<f32>,
    @interpolate(flat) @location(5) group_0 : vec3<f32>,
    @location(2) mesh_pos_0 : vec3<f32>,
    @interpolate(flat) @location(6) slot_0 : u32,
    @location(7) uv_0 : vec2<f32>,
    @location(8) view_tangent_0 : vec4<f32>,
    @location(9) material_0 : vec4<f32>,
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
     _S11 : vec3<f32>,
     _S12 : vec3<f32>,
     _S13 : f32,
     _S14 : vec4<f32>,
     _S15 : vec3<f32>,
     _S16 : vec3<f32>,
     _S17 : u32,
     _S18 : vec2<f32>,
     _S19 : vec4<f32>,
     _S20 : vec4<f32>,
};

struct Mesh_Vertex_Out_1
{
     _S21 : vec4<f32>,
     v_1 : Mesh_Varyings_0,
};

@vertex
fn main( _S22 : vertexInput_0, @builtin(vertex_index) slot_1 : u32) -> Mesh_Vertex_Out_0
{
    var position_2 : vec3<f32> = _S22.in_position_0;
    var tangent_0 : vec3<f32> = _S22.in_tangent_0.xyz;
    var o_0 : Mesh_Vertex_Out_1;
    var _S23 : vec4<f32> = vec4<f32>(0.0f);
    o_0.v_1._S14 = _S23;
    o_0.v_1._S20 = _S23;
    var normal_oct_1 : vec2<f32>;
    var v_2 : u32;
    if((Frame_Uniforms_0.skin_0.x) != u32(0))
    {
        var v_3 : u32 = slot_vertex_0[slot_1];
        var _S24 : u32 = u32(3) * v_3;
        position_2 = vec3<f32>(positions_0[_S24], positions_0[_S24 + u32(1)], positions_0[_S24 + u32(2)]);
        var packed_0 : u32 = normals_0[v_3];
        var _S25 : vec2<f32> = max(vec2<f32>(vec2<i32>((i32((packed_0 << (u32(16)))) >> (u32(16))), (i32(packed_0) >> (u32(16))))) / vec2<f32>(32767.0f), vec2<f32>(-1.0f));
        if((Frame_Uniforms_0.options_0.x) > 0.5f)
        {
            var p_0 : vec4<f32> = unpack4x8unorm(paint_0[v_3].x);
            o_0.v_1._S14 = vec4<f32>(srgb_decode_0(p_0.xyz), p_0.w);
            if((Frame_Uniforms_0.options_0.w) > 0.5f)
            {
                o_0.v_1._S20 = paint_material_0(paint_material_words_0[v_3]);
            }
        }
        normal_oct_1 = _S25;
        v_2 = v_3;
    }
    else
    {
        normal_oct_1 = _S22.in_normal_oct_0;
        v_2 = u32(0);
    }
    var _S26 : f32 = o_0.v_1._S13;
    var in_normal_0 : vec3<f32>;
    decode_normal_mask_0(normal_oct_1, &(in_normal_0), &(_S26));
    o_0.v_1._S13 = _S26;
    if((Frame_Uniforms_0.skin_0.x) != u32(0))
    {
        blend_apply_0(v_2, &(position_2), &(in_normal_0));
    }
    var tangent_1 : vec3<f32>;
    if((Frame_Uniforms_0.skin_0.x) != u32(0))
    {
        var t_0 : vec3<f32> = tangent_0 - in_normal_0 * vec3<f32>(dot(in_normal_0, tangent_0));
        if((dot(t_0, t_0)) > 9.999999960041972e-13f)
        {
            tangent_1 = normalize(t_0);
        }
        else
        {
            tangent_1 = tangent_0;
        }
    }
    else
    {
        tangent_1 = tangent_0;
    }
    o_0.v_1._S15 = vec3<f32>(-1.0f);
    o_0.v_1._S17 = u32(0);
    var world_0 : vec4<f32> = (((mat4x4<f32>(Frame_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(position_2, 1.0f))));
    o_0._S21 = (((mat4x4<f32>(Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(3)])) * (world_0)));
    var _S27 : mat4x4<f32> = mat4x4<f32>(Frame_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(3)]);
    var _S28 : mat4x4<f32> = mat4x4<f32>(Frame_Uniforms_0.view_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(3)]);
    var turn_0 : mat3x3<f32> = (((mat3x3<f32>(_S28[i32(0)].xyz, _S28[i32(1)].xyz, _S28[i32(2)].xyz)) * (mat3x3<f32>(_S27[i32(0)].xyz, _S27[i32(1)].xyz, _S27[i32(2)].xyz))));
    var _S29 : mat3x3<f32> = turn_0 * (1.0f / length(turn_0[i32(0)]));
    o_0.v_1._S11 = (((_S29) * (in_normal_0)));
    var _S30 : vec3<f32> = (((_S29) * (tangent_1)));
    var _S31 : f32;
    if((_S22.in_tangent_0.w) < 0.0f)
    {
        _S31 = -1.0f;
    }
    else
    {
        _S31 = 1.0f;
    }
    o_0.v_1._S19 = vec4<f32>(_S30, _S31);
    o_0.v_1._S12 = (((mat4x4<f32>(Frame_Uniforms_0.view_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(3)])) * (world_0))).xyz;
    o_0.v_1._S16 = position_2;
    o_0.v_1._S18 = _S22.in_uv_0;
    var _S32 : Mesh_Vertex_Out_0;
    _S32.position_1 = o_0._S21;
    _S32.view_normal_0 = o_0.v_1._S11;
    _S32.view_pos_0 = o_0.v_1._S12;
    _S32.mask_1 = o_0.v_1._S13;
    _S32.paint_1 = o_0.v_1._S14;
    _S32.group_0 = o_0.v_1._S15;
    _S32.mesh_pos_0 = o_0.v_1._S16;
    _S32.slot_0 = o_0.v_1._S17;
    _S32.uv_0 = o_0.v_1._S18;
    _S32.view_tangent_0 = o_0.v_1._S19;
    _S32.material_0 = o_0.v_1._S20;
    return _S32;
}

