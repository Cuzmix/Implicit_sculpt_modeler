// slangc wgsl from dab_move.comp.spv sha256 75852b7e6a49b08b60210f6f27a0007a80f04ab5a7bb58beb9a34c9ede8c71be
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
    @align(16) alpha_up_0 : vec4<f32>,
    @align(16) slabs_0 : vec4<u32>,
};

@binding(8) @group(0) var<storage, read> dabs_0 : array<Dab_std430_0>;

@binding(6) @group(0) var<storage, read> slabs_1 : array<vec2<u32>>;

@binding(0) @group(1) var<storage, read_write> positions_0 : array<f32>;

@binding(10) @group(0) var<storage, read> normals_0 : array<u32>;

@binding(4) @group(1) var<storage, read_write> areas_0 : array<vec4<f32>>;

@binding(14) @group(0) var<storage, read> tables_0 : array<f32>;

@binding(16) @group(0) var<storage, read> fade_0 : array<u32>;

@binding(12) @group(0) var<storage, read> mask_0 : array<u32>;

@binding(8) @group(1) var<storage, read_write> heights_0 : array<vec2<u32>>;

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
    var _S14 : vec4<u32> = dabs_0[_S9].slabs_0;
    if((*_S12) >= (dabs_0[_S9].slabs_0.y))
    {
        return false;
    }
    var slab_0 : vec2<u32> = slabs_1[_S14.x + (*_S12)];
    var _S15 : u32 = _S11.x;
    if(_S15 >= (slab_0.y))
    {
        return false;
    }
    (*_S13) = slab_0.x + _S15;
    return true;
}

fn alpha_sample_0( _S16 : u32,  _S17 : f32,  _S18 : f32) -> f32
{
    var _S19 : bool;
    if((abs(_S17)) < 1.0f)
    {
        _S19 = (abs(_S18)) < 1.0f;
    }
    else
    {
        _S19 = false;
    }
    if(!_S19)
    {
        return 0.0f;
    }
    var size_0 : i32 = i32(dabs_0[_S16].alpha_up_0.w);
    var last_0 : f32 = f32(size_0 - i32(1));
    var x_0 : f32 = (_S17 * 0.5f + 0.5f) * last_0;
    var y_0 : f32 = (0.5f - _S18 * 0.5f) * last_0;
    var _S20 : i32 = size_0 - i32(2);
    var _S21 : i32 = min(i32(x_0), _S20);
    var _S22 : i32 = min(i32(y_0), _S20);
    var fx_0 : f32 = x_0 - f32(_S21);
    var row_0 : u32 = u32(dabs_0[_S16].misc_0.w) + u32(_S22 * size_0 + _S21);
    var below_0 : u32 = row_0 + u32(size_0);
    var top_0 : f32 = tables_0[row_0] + (tables_0[row_0 + u32(1)] - tables_0[row_0]) * fx_0;
    return top_0 + (tables_0[below_0] + (tables_0[below_0 + u32(1)] - tables_0[below_0]) * fx_0 - top_0) * (y_0 - f32(_S22));
}

fn falloff_drawn_0( _S23 : u32,  _S24 : f32) -> f32
{
    if(_S24 >= 1.0f)
    {
        return 0.0f;
    }
    var x_1 : f32 = _S24 * 256.0f;
    var i_0 : i32 = i32(x_1);
    var _S25 : u32 = u32(dabs_0[_S23].misc_0.w) + u32(i_0);
    var a_0 : f32 = tables_0[_S25];
    return a_0 + (tables_0[_S25 + u32(1)] - a_0) * (x_1 - f32(i_0));
}

fn dab_weight_0( _S26 : u32,  _S27 : vec3<f32>,  _S28 : f32) -> f32
{
    var _S29 : u32 = dabs_0[_S26].slabs_0.w;
    if(((_S29 & (u32(256)))) != u32(0))
    {
        var h_0 : f32 = dot(_S27, areas_0[u32(5) * Params_0.dab_0 + u32(4)].xyz);
        return alpha_sample_0(_S26, dot(_S27, areas_0[u32(5) * Params_0.dab_0 + u32(2)].xyz), dot(_S27, areas_0[u32(5) * Params_0.dab_0 + u32(3)].xyz)) * falloff_0(h_0 * h_0);
    }
    var x2_1 : f32 = _S28 * dabs_0[_S26].view_inv_r2_0.w;
    var view_0 : vec3<f32> = dabs_0[_S26].view_inv_r2_0.xyz;
    var x2_2 : f32;
    if((any((view_0 != vec3<f32>(0.0f)))))
    {
        var h_1 : f32 = dot(_S27, view_0);
        var _S30 : f32 = h_1 * h_1;
        if(_S30 >= 1.0f)
        {
            return 0.0f;
        }
        x2_2 = x2_1 - _S30;
    }
    else
    {
        x2_2 = x2_1;
    }
    if(((_S29 & (u32(64)))) != u32(0))
    {
        return falloff_drawn_0(_S26, x2_2);
    }
    return falloff_0(x2_2);
}

fn shield_0( _S31 : u32,  _S32 : u32) -> f32
{
    var shift_0 : u32 = ((_S32 & (u32(3)))) * u32(8);
    var _S33 : u32 = dabs_0[_S31].slabs_0.w;
    var w_0 : f32;
    if(((_S33 & (u32(128)))) != u32(0))
    {
        w_0 = f32((((fade_0[(_S32 >> (u32(2)))] >> (shift_0))) & (u32(255)))) * 0.00392156885936856f;
    }
    else
    {
        w_0 = 1.0f;
    }
    if(((_S33 & (u32(32)))) != u32(0))
    {
        w_0 = w_0 * (f32(u32(255) - ((((mask_0[(_S32 >> (u32(2)))] >> (shift_0))) & (u32(255))))) * 0.00392156885936856f);
    }
    else
    {
    }
    return w_0;
}

fn facing_weight_0( _S34 : u32,  _S35 : vec3<f32>) -> f32
{
    var facing_0 : vec3<f32> = dabs_0[_S34].facing_amount_0.xyz;
    if((all((facing_0 == vec3<f32>(0.0f)))))
    {
        return 1.0f;
    }
    return clamp(dot(_S35, facing_0) * 5.0f + 0.5f, 0.0f, 1.0f);
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    var _S36 : u32 = Params_0.dab_0;
    var g_0 : u32;
    var v_3 : u32;
    var _S37 : bool = slab_vertex_0(Params_0.dab_0, group_id_0, local_id_0, &(g_0), &(v_3));
    if(!_S37)
    {
        return;
    }
    var p_1 : vec3<f32> = at_0(v_3);
    var center_0 : vec3<f32> = dabs_0[Params_0.dab_0].center_r2_0.xyz;
    var delta_0 : vec3<f32> = p_1 - center_0;
    var d2_0 : f32 = dot(delta_0, delta_0);
    if(d2_0 >= (dabs_0[Params_0.dab_0].center_r2_0.w))
    {
        return;
    }
    var n_1 : vec3<f32> = normal_at_0(v_3);
    var w_1 : f32 = dab_weight_0(_S36, delta_0, d2_0) * shield_0(_S36, v_3) * facing_weight_0(_S36, n_1);
    if(w_1 <= 0.0f)
    {
        return;
    }
    var amount_0 : f32 = dabs_0[Params_0.dab_0].facing_amount_0.w;
    var strength_0 : f32 = dabs_0[Params_0.dab_0].tilt0_0.w;
    var normal_0 : vec3<f32> = areas_0[u32(5) * Params_0.dab_0].xyz;
    var plane_0 : vec3<f32> = areas_0[u32(5) * Params_0.dab_0 + u32(1)].xyz;
    var kind_0 : u32 = dabs_0[Params_0.dab_0].slabs_0.z;
    var p_2 : vec3<f32>;
    var h_2 : f32;
    if((((dabs_0[Params_0.dab_0].slabs_0.w) & (u32(16)))) != u32(0))
    {
        var l_1 : vec2<u32> = heights_0[v_3];
        if((heights_0[v_3].x) == (Params_0.stroke_0))
        {
            h_2 = (bitcast<f32>((l_1.y)));
        }
        else
        {
            h_2 = 0.0f;
        }
        var want_0 : f32 = amount_0 * w_1;
        var next_0 : f32;
        if(amount_0 > 0.0f)
        {
            next_0 = max(h_2, want_0);
        }
        else
        {
            next_0 = min(h_2, want_0);
        }
        if(kind_0 == u32(0))
        {
            p_2 = normal_0;
        }
        else
        {
            p_2 = n_1;
        }
        var p_3 : vec3<f32> = p_1 + p_2 * vec3<f32>((next_0 - h_2));
        heights_0[v_3] = vec2<u32>(Params_0.stroke_0, (bitcast<u32>((next_0))));
        p_2 = p_3;
    }
    else
    {
        if(kind_0 == u32(0))
        {
            p_2 = p_1 + normal_0 * vec3<f32>((amount_0 * w_1));
        }
        else
        {
            if(kind_0 == u32(1))
            {
                p_2 = p_1 + n_1 * vec3<f32>((amount_0 * w_1));
            }
            else
            {
                if(kind_0 == u32(2))
                {
                    var h_3 : f32 = dot(p_1 - plane_0, normal_0);
                    if((h_3 * amount_0) < 0.0f)
                    {
                        p_2 = p_1 - normal_0 * vec3<f32>((h_3 * min(strength_0 * w_1 * 0.5f, 1.0f)));
                    }
                    else
                    {
                        p_2 = p_1;
                    }
                }
                else
                {
                    if(kind_0 == u32(3))
                    {
                        var h_4 : f32 = dot(p_1 - plane_0, normal_0);
                        var _S38 : vec4<f32> = dabs_0[Params_0.dab_0].misc_0;
                        var _S39 : f32 = dabs_0[Params_0.dab_0].misc_0.z;
                        if(h_4 > 0.0f)
                        {
                            h_2 = _S38.x;
                        }
                        else
                        {
                            h_2 = _S38.y;
                        }
                        if((abs(h_4)) <= (_S39 * (1.0f - clamp(h_2, 0.0f, 1.0f))))
                        {
                            p_2 = p_1 - normal_0 * vec3<f32>((h_4 * amount_0 * min(strength_0 * w_1 * 0.5f, 1.0f)));
                        }
                        else
                        {
                            p_2 = p_1;
                        }
                    }
                    else
                    {
                        if(kind_0 == u32(4))
                        {
                            var to_0 : vec3<f32> = center_0 - p_1;
                            p_2 = p_1 + (to_0 - normal_0 * vec3<f32>(dot(to_0, normal_0))) * vec3<f32>((amount_0 * min(strength_0 * w_1 * 0.25f, 1.0f)));
                        }
                        else
                        {
                            var _S40 : vec3<f32>;
                            if(kind_0 == u32(5))
                            {
                                var to_1 : vec3<f32> = center_0 - p_1;
                                _S40 = p_1 + (normal_0 * vec3<f32>((amount_0 * w_1 * w_1)) + (to_1 - normal_0 * vec3<f32>(dot(to_1, normal_0))) * vec3<f32>(min(strength_0 * w_1 * 0.20000000298023224f, 1.0f)));
                            }
                            else
                            {
                                return;
                            }
                            p_2 = _S40;
                        }
                    }
                }
            }
        }
    }
    put_0(v_3, p_2);
    return;
}

