// slangc wgsl from dab_smooth_apply.comp.spv sha256 13c9945c7d39b85695c9ae7f5820cedb226da64448216948a81421f9fb3055b5
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Params_std140_0
{
    @align(16) dab_0 : u32,
    @align(4) groups_x_0 : u32,
    @align(8) rate_0 : f32,
    @align(4) stroke_0 : u32,
};

@binding(0) @group(2) var<uniform> Params_0 : SLANG_ParameterGroup_Params_std140_0;
@binding(0) @group(0) var<storage, read> indices_0 : array<u32>;

@binding(2) @group(0) var<storage, read> offsets_0 : array<u32>;

@binding(4) @group(0) var<storage, read> tris_0 : array<u32>;

@binding(6) @group(0) var<storage, read> slabs_0 : array<vec2<u32>>;

struct Dab_std430_0
{
    @align(16) center_r2_0 : vec4<f32>,
    @align(16) view_inv_r2_0 : vec4<f32>,
    @align(16) facing_amount_0 : vec4<f32>,
    @align(16) tilt0_0 : vec4<f32>,
    @align(16) tilt1_0 : vec4<f32>,
    @align(16) tilt2_0 : vec4<f32>,
    @align(16) misc_0 : vec4<f32>,
    @align(16) alpha_up_0 : vec4<f32>,
    @align(16) slabs_1 : vec4<u32>,
};

@binding(8) @group(0) var<storage, read> dabs_0 : array<Dab_std430_0>;

@binding(10) @group(0) var<storage, read> normals_0 : array<u32>;

@binding(12) @group(0) var<storage, read> mask_0 : array<u32>;

@binding(16) @group(0) var<storage, read> fade_0 : array<u32>;

@binding(0) @group(1) var<storage, read_write> positions_0 : array<f32>;

@binding(14) @group(0) var<storage, read> tables_0 : array<f32>;

@binding(6) @group(1) var<storage, read_write> scratch_0 : array<vec4<f32>>;

@binding(4) @group(1) var<storage, read_write> areas_0 : array<vec4<f32>>;

fn keep_bindings_0()
{
    if((Params_0.groups_x_0) == u32(0))
    {
        positions_0[i32(0)] = f32(indices_0[i32(0)] + offsets_0[i32(0)] + tris_0[i32(0)] + slabs_0[i32(0)].x + dabs_0[i32(0)].slabs_1.x + normals_0[i32(0)] + mask_0[i32(0)] + fade_0[i32(0)]) + tables_0[i32(0)];
    }
    return;
}

fn at_0( v_0 : u32) -> vec3<f32>
{
    var _S1 : u32 = u32(3) * v_0;
    return vec3<f32>(positions_0[_S1], positions_0[_S1 + u32(1)], positions_0[_S1 + u32(2)]);
}

fn normal_at_0( v_1 : u32) -> vec3<f32>
{
    var e_0 : u32 = normals_0[v_1];
    var _S2 : f32 = max(f32((((i32((e_0 << (u32(16)))) >> (u32(16)))) & (i32(-16)))) / 32767.0f, -1.0f);
    var _S3 : f32 = max(f32((((i32(e_0) >> (u32(16)))) & (i32(-16)))) / 32767.0f, -1.0f);
    var _S4 : f32 = 1.0f - abs(_S2);
    var _S5 : f32 = abs(_S3);
    var _S6 : f32 = _S4 - _S5;
    var n_0 : vec3<f32> = vec3<f32>(_S2, _S3, _S6);
    if(_S6 < 0.0f)
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
        n_0[i32(0)] = (1.0f - _S5) * sx_0;
        n_0[i32(1)] = _S4 * sy_0;
    }
    var l_0 : f32 = length(n_0);
    var _S7 : vec3<f32>;
    if(l_0 > 0.0f)
    {
        _S7 = n_0 / vec3<f32>(l_0);
    }
    else
    {
        _S7 = vec3<f32>(0.0f);
    }
    return _S7;
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

fn put_0( v_2 : u32,  p_0 : vec3<f32>)
{
    var _S8 : u32 = u32(3) * v_2;
    positions_0[_S8] = p_0.x;
    positions_0[_S8 + u32(1)] = p_0.y;
    positions_0[_S8 + u32(2)] = p_0.z;
    return;
}

fn slab_vertex_0( _S9 : u32,  _S10 : vec3<u32>,  _S11 : vec3<u32>,  _S12 : ptr<function, u32>,  _S13 : ptr<function, u32>) -> bool
{
    (*_S12) = _S10.y * Params_0.groups_x_0 + _S10.x;
    (*_S13) = u32(0);
    var _S14 : vec4<u32> = dabs_0[_S9].slabs_1;
    if((*_S12) >= (dabs_0[_S9].slabs_1.y))
    {
        return false;
    }
    var slab_0 : vec2<u32> = slabs_0[_S14.x + (*_S12)];
    var _S15 : u32 = _S11.x;
    if(_S15 >= (slab_0.y))
    {
        return false;
    }
    (*_S13) = slab_0.x + _S15;
    return true;
}

fn shield_0( _S16 : u32,  _S17 : u32) -> f32
{
    var shift_0 : u32 = ((_S17 & (u32(3)))) * u32(8);
    var _S18 : u32 = dabs_0[_S16].slabs_1.w;
    var w_0 : f32;
    if(((_S18 & (u32(128)))) != u32(0))
    {
        w_0 = f32((((fade_0[(_S17 >> (u32(2)))] >> (shift_0))) & (u32(255)))) * 0.00392156885936856f;
    }
    else
    {
        w_0 = 1.0f;
    }
    if(((_S18 & (u32(32)))) != u32(0))
    {
        w_0 = w_0 * (f32(u32(255) - ((((mask_0[(_S17 >> (u32(2)))] >> (shift_0))) & (u32(255))))) * 0.00392156885936856f);
    }
    else
    {
    }
    return w_0;
}

fn facing_weight_0( _S19 : u32,  _S20 : vec3<f32>) -> f32
{
    var facing_0 : vec3<f32> = dabs_0[_S19].facing_amount_0.xyz;
    if((all((facing_0 == vec3<f32>(0.0f)))))
    {
        return 1.0f;
    }
    return clamp(dot(_S20, facing_0) * 5.0f + 0.5f, 0.0f, 1.0f);
}

fn alpha_sample_0( _S21 : u32,  _S22 : f32,  _S23 : f32) -> f32
{
    var _S24 : bool;
    if((abs(_S22)) < 1.0f)
    {
        _S24 = (abs(_S23)) < 1.0f;
    }
    else
    {
        _S24 = false;
    }
    if(!_S24)
    {
        return 0.0f;
    }
    var size_0 : i32 = i32(dabs_0[_S21].alpha_up_0.w);
    var last_0 : f32 = f32(size_0 - i32(1));
    var x_0 : f32 = (_S22 * 0.5f + 0.5f) * last_0;
    var y_0 : f32 = (0.5f - _S23 * 0.5f) * last_0;
    var _S25 : i32 = size_0 - i32(2);
    var _S26 : i32 = min(i32(x_0), _S25);
    var _S27 : i32 = min(i32(y_0), _S25);
    var fx_0 : f32 = x_0 - f32(_S26);
    var row_0 : u32 = u32(dabs_0[_S21].misc_0.w) + u32(_S27 * size_0 + _S26);
    var below_0 : u32 = row_0 + u32(size_0);
    var top_0 : f32 = tables_0[row_0] + (tables_0[row_0 + u32(1)] - tables_0[row_0]) * fx_0;
    return top_0 + (tables_0[below_0] + (tables_0[below_0 + u32(1)] - tables_0[below_0]) * fx_0 - top_0) * (y_0 - f32(_S27));
}

fn falloff_drawn_0( _S28 : u32,  _S29 : f32) -> f32
{
    if(_S29 >= 1.0f)
    {
        return 0.0f;
    }
    var x_1 : f32 = _S29 * 256.0f;
    var i_0 : i32 = i32(x_1);
    var _S30 : u32 = u32(dabs_0[_S28].misc_0.w) + u32(i_0);
    var a_0 : f32 = tables_0[_S30];
    return a_0 + (tables_0[_S30 + u32(1)] - a_0) * (x_1 - f32(i_0));
}

fn dab_weight_0( _S31 : u32,  _S32 : vec3<f32>,  _S33 : f32) -> f32
{
    var _S34 : u32 = dabs_0[_S31].slabs_1.w;
    if(((_S34 & (u32(256)))) != u32(0))
    {
        var h_0 : f32 = dot(_S32, areas_0[u32(5) * Params_0.dab_0 + u32(4)].xyz);
        return alpha_sample_0(_S31, dot(_S32, areas_0[u32(5) * Params_0.dab_0 + u32(2)].xyz), dot(_S32, areas_0[u32(5) * Params_0.dab_0 + u32(3)].xyz)) * falloff_0(h_0 * h_0);
    }
    var x2_1 : f32 = _S33 * dabs_0[_S31].view_inv_r2_0.w;
    var view_0 : vec3<f32> = dabs_0[_S31].view_inv_r2_0.xyz;
    var x2_2 : f32;
    if((any((view_0 != vec3<f32>(0.0f)))))
    {
        var h_1 : f32 = dot(_S32, view_0);
        var _S35 : f32 = h_1 * h_1;
        if(_S35 >= 1.0f)
        {
            return 0.0f;
        }
        x2_2 = x2_1 - _S35;
    }
    else
    {
        x2_2 = x2_1;
    }
    if(((_S34 & (u32(64)))) != u32(0))
    {
        return falloff_drawn_0(_S31, x2_2);
    }
    return falloff_0(x2_2);
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    keep_bindings_0();
    var _S36 : u32 = Params_0.dab_0;
    var g_0 : u32;
    var v_3 : u32;
    var _S37 : bool = slab_vertex_0(Params_0.dab_0, group_id_0, local_id_0, &(g_0), &(v_3));
    if(!_S37)
    {
        return;
    }
    var p_1 : vec3<f32> = at_0(v_3);
    var delta_0 : vec3<f32> = p_1 - dabs_0[Params_0.dab_0].center_r2_0.xyz;
    var d2_0 : f32 = dot(delta_0, delta_0);
    if(d2_0 >= (dabs_0[Params_0.dab_0].center_r2_0.w))
    {
        return;
    }
    var n_1 : vec3<f32> = normal_at_0(v_3);
    var w_1 : f32 = shield_0(_S36, v_3) * facing_weight_0(_S36, n_1);
    if(w_1 <= 0.0f)
    {
        return;
    }
    var step_0 : vec3<f32> = scratch_0[g_0 * u32(256) + local_id_0.x].xyz - p_1;
    var flags_0 : u32 = dabs_0[Params_0.dab_0].slabs_1.w;
    var along_0 : f32 = dot(step_0, n_1);
    var _S38 : bool;
    if(((flags_0 & (u32(2)))) != u32(0))
    {
        _S38 = !(along_0 > 0.0f);
    }
    else
    {
        _S38 = false;
    }
    if(_S38)
    {
        return;
    }
    if(((flags_0 & (u32(4)))) != u32(0))
    {
        _S38 = !(along_0 < 0.0f);
    }
    else
    {
        _S38 = false;
    }
    if(_S38)
    {
        return;
    }
    var t_1 : f32 = clamp(Params_0.rate_0 * dab_weight_0(_S36, delta_0, d2_0), 0.0f, 1.0f) * w_1;
    var step_1 : vec3<f32>;
    if(((flags_0 & (u32(1)))) != u32(0))
    {
        step_1 = step_0 - n_1 * vec3<f32>(along_0);
    }
    else
    {
        step_1 = step_0;
    }
    put_0(v_3, p_1 + step_1 * vec3<f32>(t_1));
    return;
}

