// slangc wgsl from dab_smooth_apply.comp.spv sha256 8c29d594d6cc867c336e42f7bc20326d6e26cbc18602d1404378bbbe6b3b8873
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Params_std140_0
{
    @align(16) dab_0 : u32,
    @align(4) groups_x_0 : u32,
    @align(8) rate_0 : f32,
    @align(4) stroke_0 : u32,
};

@binding(0) @group(2) var<uniform> Params_0 : SLANG_ParameterGroup_Params_std140_0;
struct Dab_std430_0
{
    @align(16) center_r2_0 : vec4<f32>,
    @align(16) view_inv_r2_0 : vec4<f32>,
    @align(16) facing_amount_0 : vec4<f32>,
    @align(16) tilt0_0 : vec4<f32>,
    @align(16) tilt1_0 : vec4<f32>,
    @align(16) tilt2_0 : vec4<f32>,
    @align(16) misc_0 : vec4<f32>,
    @align(16) slabs_0 : vec4<u32>,
};

@binding(8) @group(0) var<storage, read> dabs_0 : array<Dab_std430_0>;

@binding(6) @group(0) var<storage, read> slabs_1 : array<vec2<u32>>;

@binding(0) @group(1) var<storage, read_write> positions_0 : array<f32>;

@binding(10) @group(0) var<storage, read> normals_0 : array<u32>;

@binding(6) @group(1) var<storage, read_write> scratch_0 : array<vec4<f32>>;

fn slab_vertex_0( d_0 : ptr<function, Dab_std430_0>,  group_id_0 : vec3<u32>,  local_id_0 : vec3<u32>,  g_0 : ptr<function, u32>,  v_0 : ptr<function, u32>) -> bool
{
    (*g_0) = group_id_0.y * Params_0.groups_x_0 + group_id_0.x;
    (*v_0) = u32(0);
    var _S1 : vec4<u32> = (*d_0).slabs_0;
    if((*g_0) >= ((*d_0).slabs_0.y))
    {
        return false;
    }
    var slab_0 : vec2<u32> = slabs_1[_S1.x + (*g_0)];
    var _S2 : u32 = local_id_0.x;
    if(_S2 >= (slab_0.y))
    {
        return false;
    }
    (*v_0) = slab_0.x + _S2;
    return true;
}

fn at_0( v_1 : u32) -> vec3<f32>
{
    var _S3 : u32 = u32(3) * v_1;
    return vec3<f32>(positions_0[_S3], positions_0[_S3 + u32(1)], positions_0[_S3 + u32(2)]);
}

fn normal_at_0( v_2 : u32) -> vec3<f32>
{
    var e_0 : u32 = normals_0[v_2];
    var _S4 : f32 = max(f32((((i32((e_0 << (u32(16)))) >> (u32(16)))) & (i32(-16)))) / 32767.0f, -1.0f);
    var _S5 : f32 = max(f32((((i32(e_0) >> (u32(16)))) & (i32(-16)))) / 32767.0f, -1.0f);
    var _S6 : f32 = 1.0f - abs(_S4);
    var _S7 : f32 = abs(_S5);
    var _S8 : f32 = _S6 - _S7;
    var n_0 : vec3<f32> = vec3<f32>(_S4, _S5, _S8);
    if(_S8 < 0.0f)
    {
        var sx_0 : f32;
        if((n_0.x) >= 0.0f)
        {
            sx_0 = 1.0f;
        }
        else
        {
            sx_0 = -1.0f;
        }
        var sy_0 : f32;
        if((n_0.y) >= 0.0f)
        {
            sy_0 = 1.0f;
        }
        else
        {
            sy_0 = -1.0f;
        }
        n_0[i32(0)] = (1.0f - _S7) * sx_0;
        n_0[i32(1)] = _S6 * sy_0;
    }
    var l_0 : f32 = length(n_0);
    var _S9 : vec3<f32>;
    if(l_0 > 0.0f)
    {
        _S9 = n_0 / vec3<f32>(l_0);
    }
    else
    {
        _S9 = vec3<f32>(0.0f);
    }
    return _S9;
}

fn facing_weight_0( d_1 : ptr<function, Dab_std430_0>,  n_1 : vec3<f32>) -> f32
{
    var facing_0 : vec3<f32> = (*d_1).facing_amount_0.xyz;
    if((all((facing_0 == vec3<f32>(0.0f)))))
    {
        return 1.0f;
    }
    return clamp(dot(n_1, facing_0) * 5.0f + 0.5f, 0.0f, 1.0f);
}

fn falloff_0( x2_0 : f32) -> f32
{
    if(x2_0 >= 1.0f)
    {
        return 0.0f;
    }
    var t_0 : f32 = 1.0f - x2_0;
    return t_0 * t_0;
}

fn dab_weight_0( d_2 : ptr<function, Dab_std430_0>,  delta_0 : vec3<f32>,  d2_0 : f32) -> f32
{
    var x2_1 : f32 = d2_0 * (*d_2).view_inv_r2_0.w;
    var view_0 : vec3<f32> = (*d_2).view_inv_r2_0.xyz;
    var x2_2 : f32;
    if((any((view_0 != vec3<f32>(0.0f)))))
    {
        var h_0 : f32 = dot(delta_0, view_0);
        var _S10 : f32 = h_0 * h_0;
        if(_S10 >= 1.0f)
        {
            return 0.0f;
        }
        x2_2 = x2_1 - _S10;
    }
    else
    {
        x2_2 = x2_1;
    }
    return falloff_0(x2_2);
}

fn put_0( v_3 : u32,  p_0 : vec3<f32>)
{
    var _S11 : u32 = u32(3) * v_3;
    positions_0[_S11] = p_0.x;
    positions_0[_S11 + u32(1)] = p_0.y;
    positions_0[_S11 + u32(2)] = p_0.z;
    return;
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_1 : vec3<u32>, @builtin(local_invocation_id) local_id_1 : vec3<u32>)
{
    var _S12 : Dab_std430_0 = dabs_0[Params_0.dab_0];
    var g_1 : u32;
    var v_4 : u32;
    var _S13 : bool = slab_vertex_0(&(_S12), group_id_1, local_id_1, &(g_1), &(v_4));
    if(!_S13)
    {
        return;
    }
    var p_1 : vec3<f32> = at_0(v_4);
    var delta_1 : vec3<f32> = p_1 - _S12.center_r2_0.xyz;
    var d2_1 : f32 = dot(delta_1, delta_1);
    if(d2_1 >= (_S12.center_r2_0.w))
    {
        return;
    }
    var n_2 : vec3<f32> = normal_at_0(v_4);
    var _S14 : f32 = facing_weight_0(&(_S12), n_2);
    if(_S14 <= 0.0f)
    {
        return;
    }
    var step_0 : vec3<f32> = scratch_0[g_1 * u32(256) + local_id_1.x].xyz - p_1;
    var flags_0 : u32 = _S12.slabs_0.w;
    var along_0 : f32 = dot(step_0, n_2);
    var _S15 : bool;
    if(((flags_0 & (u32(2)))) != u32(0))
    {
        _S15 = !(along_0 > 0.0f);
    }
    else
    {
        _S15 = false;
    }
    if(_S15)
    {
        return;
    }
    if(((flags_0 & (u32(4)))) != u32(0))
    {
        _S15 = !(along_0 < 0.0f);
    }
    else
    {
        _S15 = false;
    }
    if(_S15)
    {
        return;
    }
    var _S16 : f32 = dab_weight_0(&(_S12), delta_1, d2_1);
    var t_1 : f32 = clamp(Params_0.rate_0 * _S16, 0.0f, 1.0f) * _S14;
    var step_1 : vec3<f32>;
    if(((flags_0 & (u32(1)))) != u32(0))
    {
        step_1 = step_0 - n_2 * vec3<f32>(along_0);
    }
    else
    {
        step_1 = step_0;
    }
    put_0(v_4, p_1 + step_1 * vec3<f32>(t_1));
    return;
}

