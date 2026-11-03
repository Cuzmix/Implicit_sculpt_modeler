// slangc wgsl from node_normals.comp.spv sha256 c617e93944fd05bae148d89216805aa881341b4c821a6a9a713c78b875e7268b
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Params_std140_0
{
    @align(16) slab_count_0 : u32,
    @align(4) groups_x_0 : u32,
};

@binding(0) @group(2) var<uniform> Params_0 : SLANG_ParameterGroup_Params_std140_0;
@binding(8) @group(0) var<storage, read> slabs_0 : array<vec2<u32>>;

@binding(2) @group(0) var<storage, read> offsets_0 : array<u32>;

@binding(4) @group(0) var<storage, read> tris_0 : array<u32>;

@binding(0) @group(0) var<storage, read> indices_0 : array<u32>;

@binding(6) @group(0) var<storage, read> positions_0 : array<f32>;

@binding(0) @group(1) var<storage, read_write> normals_0 : array<u32>;

fn at_0( v_0 : u32) -> vec3<f32>
{
    var _S1 : u32 = u32(3) * v_0;
    return vec3<f32>(positions_0[_S1], positions_0[_S1 + u32(1)], positions_0[_S1 + u32(2)]);
}

fn encode_0( n_0 : vec3<f32>) -> vec2<i32>
{
    var _S2 : f32 = n_0.x;
    var _S3 : f32 = n_0.y;
    var _S4 : f32 = n_0.z;
    var l1_0 : f32 = abs(_S2) + abs(_S3) + abs(_S4);
    if(l1_0 == 0.0f)
    {
        return vec2<i32>(i32(0), i32(0));
    }
    var _S5 : f32 = _S2 / l1_0;
    var _S6 : f32 = _S3 / l1_0;
    var p_0 : vec2<f32> = vec2<f32>(_S5, _S6);
    var p_1 : vec2<f32>;
    if(_S4 < 0.0f)
    {
        var sx_0 : f32;
        if(_S5 >= 0.0f)
        {
            sx_0 = 1.0f;
        }
        else
        {
            sx_0 = -1.0f;
        }
        var sy_0 : f32;
        if(_S6 >= 0.0f)
        {
            sy_0 = 1.0f;
        }
        else
        {
            sy_0 = -1.0f;
        }
        p_1 = vec2<f32>((1.0f - abs(_S6)) * sx_0, (1.0f - abs(_S5)) * sy_0);
    }
    else
    {
        p_1 = p_0;
    }
    return vec2<i32>(clamp(((i32(round(clamp(p_1.x, -1.0f, 1.0f) * 32767.0f)) + i32(8)) & (i32(-16))), i32(-32752), i32(32752)), clamp(((i32(round(clamp(p_1.y, -1.0f, 1.0f) * 32767.0f)) + i32(8)) & (i32(-16))), i32(-32752), i32(32752)));
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    var g_0 : u32 = group_id_0.y * Params_0.groups_x_0 + group_id_0.x;
    if(g_0 >= (Params_0.slab_count_0))
    {
        return;
    }
    var slab_0 : vec2<u32> = slabs_0[g_0];
    var _S7 : u32 = local_id_0.x;
    if(_S7 >= (slab_0.y))
    {
        return;
    }
    var v_1 : u32 = slab_0.x + _S7;
    var _S8 : vec3<f32> = vec3<f32>(0.0f);
    var _S9 : u32 = offsets_0[v_1 + u32(1)];
    var k_0 : u32 = offsets_0[v_1];
    var sum_0 : vec3<f32> = _S8;
    for(;;)
    {
        if(k_0 < _S9)
        {
        }
        else
        {
            break;
        }
        var _S10 : u32 = u32(3) * tris_0[k_0];
        var p0_0 : vec3<f32> = at_0(indices_0[_S10]);
        var sum_1 : vec3<f32> = sum_0 + cross(at_0(indices_0[_S10 + u32(1)]) - p0_0, at_0(indices_0[_S10 + u32(2)]) - p0_0);
        k_0 = k_0 + u32(1);
        sum_0 = sum_1;
    }
    var len_0 : f32 = sqrt(dot(sum_0, sum_0));
    var n_1 : vec3<f32>;
    if(len_0 > 0.0f)
    {
        n_1 = sum_0 / vec3<f32>(len_0);
    }
    else
    {
        n_1 = _S8;
    }
    var e_0 : vec2<i32> = encode_0(n_1);
    normals_0[v_1] = (((((u32(e_0.x) & (u32(65535)))) | (((normals_0[v_1] & (u32(15))))))) | (((((((u32(e_0.y) & (u32(65535)))) | (((((normals_0[v_1] >> (u32(16)))) & (u32(15))))))) << (u32(16))))));
    return;
}

