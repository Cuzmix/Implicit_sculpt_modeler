// slangc wgsl from blend_project.comp.spv sha256 3c8ac46ec784f56e0278cfd6978d4ae16d7e761387447061d985a9e397db850a
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Blend_Params_std140_0
{
    @align(16) vertex_count_0 : u32,
    @align(4) slot_count_0 : u32,
    @align(8) term_count_0 : u32,
    @align(4) groups_x_0 : u32,
    @align(16) reach_0 : f32,
    @align(4) self_edge_0 : f32,
    @align(8) _pad0_0 : u32,
    @align(4) _pad1_0 : u32,
    @align(16) pair_table_0 : array<vec4<f32>, i32(64)>,
};

@binding(0) @group(2) var<uniform> Blend_Params_0 : SLANG_ParameterGroup_Blend_Params_std140_0;
@binding(2) @group(0) var<storage, read> page_list_0 : array<u32>;

@binding(0) @group(0) var<storage, read> positions_0 : array<f32>;

@binding(12) @group(0) var<storage, read> terms_0 : array<vec4<f32>>;

@binding(4) @group(0) var<storage, read> fields_0 : array<vec4<u32>>;

@binding(6) @group(0) var<storage, read> brick_table_0 : array<vec4<u32>>;

@binding(8) @group(0) var<storage, read> brick_values_0 : array<f32>;

@binding(10) @group(0) var<storage, read> brick_extras_0 : array<u32>;

@binding(0) @group(1) var<storage, read_write> pages_0 : array<vec4<u32>>;

fn key_hash_0( x_0 : u32,  y_0 : u32,  z_0 : u32) -> u32
{
    var h_0 : u32 = ((((x_0 * u32(73856093)) ^ ((y_0 * u32(19349663))))) ^ ((z_0 * u32(83492791))));
    var h_1 : u32 = ((h_0 ^ (((h_0 >> (u32(16))))))) * u32(2146121005);
    var h_2 : u32 = ((h_1 ^ (((h_1 >> (u32(15))))))) * u32(2221713035);
    return (h_2 ^ (((h_2 >> (u32(16))))));
}

fn brick_base_0( f_0 : u32,  b_0 : vec3<i32>) -> i32
{
    var _S1 : i32 = b_0.x;
    var _S2 : bool;
    if((abs(_S1)) >= i32(1048575))
    {
        _S2 = true;
    }
    else
    {
        _S2 = (abs(b_0.y)) >= i32(1048575);
    }
    if(_S2)
    {
        _S2 = true;
    }
    else
    {
        _S2 = (abs(b_0.z)) >= i32(1048575);
    }
    if(_S2)
    {
        return i32(-1);
    }
    var fd_0 : vec4<u32> = fields_0[f_0];
    var x_1 : u32 = (u32(_S1 + i32(1048576)) & (u32(2097151)));
    var y_1 : u32 = (u32(b_0.y + i32(1048576)) & (u32(2097151)));
    var z_1 : u32 = (u32(b_0.z + i32(1048576)) & (u32(2097151)));
    var _S3 : u32 = (x_1 | (((y_1 << (u32(21))))));
    var _S4 : u32 = (((y_1 >> (u32(11)))) | (((z_1 << (u32(10))))));
    var mask_0 : u32 = fd_0.z;
    var i_0 : u32 = ((key_hash_0(x_1, y_1, z_1)) & (mask_0));
    var n_0 : u32 = u32(0);
    for(;;)
    {
        if(n_0 <= mask_0)
        {
        }
        else
        {
            break;
        }
        var e_0 : vec4<u32> = brick_table_0[fd_0.y + i_0];
        var _S5 : u32 = e_0.x;
        if(_S5 == _S3)
        {
            _S2 = (e_0.y) == _S4;
        }
        else
        {
            _S2 = false;
        }
        if(_S2)
        {
            return i32((fd_0.w + e_0.z) * u32(729));
        }
        var _S6 : bool;
        if(_S5 == u32(4294967295))
        {
            _S6 = (e_0.y) == u32(4294967295);
        }
        else
        {
            _S6 = false;
        }
        if(_S6)
        {
            return i32(-1);
        }
        var _S7 : u32 = ((i_0 + u32(1)) & (mask_0));
        var _S8 : u32 = n_0 + u32(1);
        i_0 = _S7;
        n_0 = _S8;
    }
    return i32(-1);
}

fn sample_index_0( at_0 : vec3<i32>) -> u32
{
    return u32((at_0.z * i32(9) + at_0.y) * i32(9) + at_0.x);
}

fn corner_at_0( base_0 : i32,  l_0 : vec3<i32>,  k_0 : u32) -> u32
{
    return u32(base_0) + sample_index_0(l_0 + vec3<i32>(i32((k_0 & (u32(1)))), i32((((k_0 >> (u32(1)))) & (u32(1)))), i32((((k_0 >> (u32(2)))) & (u32(1))))));
}

fn normalize0_0( v_0 : vec3<f32>) -> vec3<f32>
{
    var l_1 : f32 = length(v_0);
    var _S9 : vec3<f32>;
    if(l_1 > 0.0f)
    {
        _S9 = v_0 / vec3<f32>(l_1);
    }
    else
    {
        _S9 = vec3<f32>(0.0f);
    }
    return _S9;
}

fn extra_normal_0( x_2 : u32,  w_0 : ptr<function, f32>) -> vec3<f32>
{
    (*w_0) = f32((x_2 >> (u32(24))));
    var qx_0 : u32 = (x_2 & (u32(4095)));
    var qy_0 : u32 = (((x_2 >> (u32(12)))) & (u32(4095)));
    if(qx_0 == u32(0))
    {
        return vec3<f32>(0.0f);
    }
    var _S10 : f32 = f32(qx_0 - u32(1)) / 4094.0f * 2.0f - 1.0f;
    var _S11 : f32 = f32(qy_0 - u32(1)) / 4094.0f * 2.0f - 1.0f;
    var _S12 : f32 = 1.0f - abs(_S10);
    var _S13 : f32 = abs(_S11);
    var _S14 : f32 = _S12 - _S13;
    var v_1 : vec3<f32> = vec3<f32>(_S10, _S11, _S14);
    if(_S14 < 0.0f)
    {
        var sx_0 : f32;
        if(_S10 >= 0.0f)
        {
            sx_0 = 1.0f;
        }
        else
        {
            sx_0 = -1.0f;
        }
        var sy_0 : f32;
        if(_S11 >= 0.0f)
        {
            sy_0 = 1.0f;
        }
        else
        {
            sy_0 = -1.0f;
        }
        v_1[i32(0)] = (1.0f - _S13) * sx_0;
        v_1[i32(1)] = _S12 * sy_0;
    }
    return normalize0_0(v_1);
}

fn mixf_0( a_0 : f32,  b_1 : f32,  t_0 : f32) -> f32
{
    return a_0 * (1.0f - t_0) + b_1 * t_0;
}

fn mix3_0( a_1 : vec3<f32>,  b_2 : vec3<f32>,  t_1 : f32) -> vec3<f32>
{
    return a_1 * vec3<f32>((1.0f - t_1)) + b_2 * vec3<f32>(t_1);
}

fn field_at_0( f_1 : u32,  p_0 : vec3<f32>,  d_0 : ptr<function, f32>,  g_0 : ptr<function, vec3<f32>>,  w_1 : ptr<function, f32>) -> bool
{
    (*d_0) = 0.0f;
    (*g_0) = vec3<f32>(0.0f);
    (*w_1) = 0.0f;
    var q_0 : vec3<f32> = p_0 / vec3<f32>((bitcast<f32>((fields_0[f_1].x))));
    var cell_0 : vec3<f32> = floor(q_0);
    var _S15 : vec3<i32> = vec3<i32>(floor(cell_0 / vec3<f32>(8.0f)));
    var base_1 : i32 = brick_base_0(f_1, _S15);
    if(base_1 < i32(0))
    {
        return false;
    }
    var _S16 : vec3<i32> = vec3<i32>(cell_0) - _S15 * vec3<i32>(i32(8));
    var t_2 : vec3<f32> = q_0 - cell_0;
    var v_2 : array<f32, i32(8)>;
    var gc_0 : array<vec3<f32>, i32(8)>;
    var wc_0 : array<f32, i32(8)>;
    var k_1 : u32 = u32(0);
    for(;;)
    {
        if(k_1 < u32(8))
        {
        }
        else
        {
            break;
        }
        var i_1 : u32 = corner_at_0(base_1, _S16, k_1);
        v_2[k_1] = brick_values_0[i_1];
        var wb_0 : f32;
        var _S17 : vec3<f32> = extra_normal_0(brick_extras_0[i_1], &(wb_0));
        gc_0[k_1] = _S17;
        wc_0[k_1] = wb_0;
        k_1 = k_1 + u32(1);
    }
    var _S18 : f32 = t_2.x;
    var _S19 : f32 = t_2.y;
    var _S20 : f32 = t_2.z;
    (*d_0) = mixf_0(mixf_0(mixf_0(v_2[i32(0)], v_2[i32(1)], _S18), mixf_0(v_2[i32(2)], v_2[i32(3)], _S18), _S19), mixf_0(mixf_0(v_2[i32(4)], v_2[i32(5)], _S18), mixf_0(v_2[i32(6)], v_2[i32(7)], _S18), _S19), _S20);
    (*g_0) = mix3_0(mix3_0(mix3_0(gc_0[i32(0)], gc_0[i32(1)], _S18), mix3_0(gc_0[i32(2)], gc_0[i32(3)], _S18), _S19), mix3_0(mix3_0(gc_0[i32(4)], gc_0[i32(5)], _S18), mix3_0(gc_0[i32(6)], gc_0[i32(7)], _S18), _S19), _S20);
    (*w_1) = 1.0f - mixf_0(mixf_0(mixf_0(wc_0[i32(0)], wc_0[i32(1)], _S18), mixf_0(wc_0[i32(2)], wc_0[i32(3)], _S18), _S19), mixf_0(mixf_0(wc_0[i32(4)], wc_0[i32(5)], _S18), mixf_0(wc_0[i32(6)], wc_0[i32(7)], _S18), _S19), _S20) / 255.0f;
    return true;
}

fn term_at_0( j_0 : u32,  x_3 : vec3<f32>,  d_1 : ptr<function, f32>,  g_1 : ptr<function, vec3<f32>>,  w_2 : ptr<function, f32>) -> bool
{
    var _S21 : u32 = u32(4) * j_0;
    var r0_0 : vec4<f32> = terms_0[_S21];
    var r1_0 : vec4<f32> = terms_0[_S21 + u32(1)];
    var r2_0 : vec4<f32> = terms_0[_S21 + u32(2)];
    var info_0 : vec4<f32> = terms_0[_S21 + u32(3)];
    var _S22 : vec3<f32> = r0_0.xyz;
    var _S23 : vec3<f32> = r1_0.xyz;
    var _S24 : vec3<f32> = r2_0.xyz;
    var _S25 : bool = field_at_0((bitcast<u32>((info_0.w))), vec3<f32>(dot(_S22, x_3) + r0_0.w, dot(_S23, x_3) + r1_0.w, dot(_S24, x_3) + r2_0.w), &((*d_1)), &((*g_1)), &((*w_2)));
    if(!_S25)
    {
        return false;
    }
    var _S26 : f32 = info_0.x;
    (*d_1) = (*d_1) * _S26;
    (*g_1) = (_S22 * vec3<f32>((*g_1).x) + _S23 * vec3<f32>((*g_1).y) + _S24 * vec3<f32>((*g_1).z)) * vec3<f32>(_S26);
    return true;
}

fn term_at_1( j_1 : u32,  x_4 : vec3<f32>,  d_2 : ptr<function, f32>,  g_2 : ptr<function, vec3<f32>>,  w_3 : ptr<function, f32>) -> bool
{
    var _S27 : u32 = u32(4) * j_1;
    var r0_1 : vec4<f32> = terms_0[_S27];
    var r1_1 : vec4<f32> = terms_0[_S27 + u32(1)];
    var r2_1 : vec4<f32> = terms_0[_S27 + u32(2)];
    var info_1 : vec4<f32> = terms_0[_S27 + u32(3)];
    var _S28 : vec3<f32> = r0_1.xyz;
    var _S29 : vec3<f32> = r1_1.xyz;
    var _S30 : vec3<f32> = r2_1.xyz;
    var _S31 : bool = field_at_0((bitcast<u32>((info_1.w))), vec3<f32>(dot(_S28, x_4) + r0_1.w, dot(_S29, x_4) + r1_1.w, dot(_S30, x_4) + r2_1.w), &((*d_2)), &((*g_2)), &((*w_3)));
    if(!_S31)
    {
        return false;
    }
    var _S32 : f32 = info_1.x;
    (*d_2) = (*d_2) * _S32;
    (*g_2) = (_S28 * vec3<f32>((*g_2).x) + _S29 * vec3<f32>((*g_2).y) + _S30 * vec3<f32>((*g_2).z)) * vec3<f32>(_S32);
    return true;
}

fn term_pair_0( a_2 : u32,  b_3 : u32) -> vec4<f32>
{
    return Blend_Params_0.pair_table_0[a_2 * u32(8) + b_3];
}

fn kappa_0( x_5 : f32) -> f32
{
    if(x_5 <= 0.0f)
    {
        return 0.0f;
    }
    if(x_5 >= 1.0f)
    {
        return 1.0f;
    }
    return 1.0f - exp(1.0f - 1.0f / (1.0f - exp(1.0f - 1.0f / x_5)));
}

fn opening_theta_0( opening_0 : u32,  alpha_0 : f32) -> f32
{
    var _S33 : bool = opening_0 == u32(0);
    var a1_0 : f32;
    if(_S33)
    {
        a1_0 = 1.04719758033752441f;
    }
    else
    {
        a1_0 = 1.57079637050628662f;
    }
    var a2_0 : f32;
    if(_S33)
    {
        a2_0 = 2.35619449615478516f;
    }
    else
    {
        a2_0 = 3.14159274101257324f;
    }
    var t0_0 : f32;
    if(_S33)
    {
        t0_0 = 0.52359879016876221f;
    }
    else
    {
        t0_0 = 0.78539818525314331f;
    }
    var w0_0 : f32;
    if(_S33)
    {
        w0_0 = 3.0f;
    }
    else
    {
        w0_0 = 1.0f;
    }
    if(alpha_0 <= 0.0f)
    {
        return t0_0;
    }
    if(alpha_0 <= a1_0)
    {
        return pow(kappa_0((alpha_0 - a1_0) / (0.0f - a1_0)), w0_0) * t0_0;
    }
    if(alpha_0 < a2_0)
    {
        return pow(kappa_0((alpha_0 - a1_0) / (a2_0 - a1_0)), 1.0f) * 0.78539818525314331f;
    }
    return 0.78539818525314331f;
}

fn radius_at_0( radius_0 : f32,  c_0 : f32,  w_4 : f32,  opening_1 : u32) -> f32
{
    return radius_0 * w_4 * (1.0f - opening_theta_0(opening_1, acos(clamp(c_0, -1.0f, 1.0f))) / 0.78539818525314331f);
}

struct Eval_0
{
     ok_0 : bool,
     g_3 : f32,
     grad_0 : vec3<f32>,
     amount_0 : f32,
     own_0 : f32,
     rival_0 : u32,
     rival_edge_0 : f32,
};

fn evaluate_0( x_6 : vec3<f32>) -> Eval_0
{
    var at_1 : u32;
    var others_0 : f32;
    var self_d_0 : f32;
    var e_1 : Eval_0;
    e_1.ok_0 = false;
    e_1.g_3 = 0.0f;
    var _S34 : vec3<f32> = vec3<f32>(0.0f);
    e_1.grad_0 = _S34;
    e_1.amount_0 = 0.0f;
    e_1.own_0 = 1.0f;
    e_1.rival_0 = u32(4294967295);
    e_1.rival_edge_0 = 0.0f;
    var d_3 : array<f32, i32(8)>;
    var g_4 : array<vec3<f32>, i32(8)>;
    var w_5 : array<f32, i32(8)>;
    var id_0 : array<u32, i32(8)>;
    var term_0 : array<u32, i32(8)>;
    var z_2 : u32 = u32(0);
    for(;;)
    {
        if(z_2 < u32(8))
        {
        }
        else
        {
            break;
        }
        d_3[z_2] = 0.0f;
        g_4[z_2] = _S34;
        w_5[z_2] = 0.0f;
        id_0[z_2] = u32(0);
        term_0[z_2] = u32(0);
        z_2 = z_2 + u32(1);
    }
    var others_1 : f32 = 3.4028234663852886e+38f;
    var self_d_1 : f32 = 0.0f;
    var j_2 : u32 = u32(0);
    var count_0 : u32 = u32(0);
    for(;;)
    {
        if(j_2 < (Blend_Params_0.term_count_0))
        {
        }
        else
        {
            break;
        }
        var td_0 : f32;
        var tg_0 : vec3<f32>;
        var tw_0 : f32;
        var _S35 : bool = term_at_0(j_2, x_6, &(td_0), &(tg_0), &(tw_0));
        if(!_S35)
        {
            if(j_2 == u32(0))
            {
                return e_1;
            }
            others_0 = others_1;
            var _S36 : u32 = j_2 + u32(1);
            others_1 = others_0;
            j_2 = _S36;
            continue;
        }
        var _S37 : u32 = u32(4) * j_2 + u32(3);
        var tid_0 : u32 = (bitcast<u32>((terms_0[_S37].z)));
        var _S38 : bool;
        if(j_2 == u32(0))
        {
            others_0 = others_1;
            self_d_0 = td_0;
        }
        else
        {
            if(td_0 < others_1)
            {
                _S38 = true;
            }
            else
            {
                if(td_0 == others_1)
                {
                    _S38 = tid_0 < (e_1.rival_0);
                }
                else
                {
                    _S38 = false;
                }
            }
            if(_S38)
            {
                e_1.rival_0 = tid_0;
                e_1.rival_edge_0 = terms_0[_S37].y;
                others_0 = td_0;
            }
            else
            {
                others_0 = others_1;
            }
            self_d_0 = self_d_1;
        }
        at_1 = count_0;
        for(;;)
        {
            if(at_1 > u32(0))
            {
                var _S39 : u32 = at_1 - u32(1);
                if(td_0 < (d_3[_S39]))
                {
                    _S38 = true;
                }
                else
                {
                    if(td_0 == (d_3[_S39]))
                    {
                        _S38 = tid_0 < (id_0[_S39]);
                    }
                    else
                    {
                        _S38 = false;
                    }
                }
            }
            else
            {
                _S38 = false;
            }
            if(_S38)
            {
            }
            else
            {
                break;
            }
            var _S40 : u32 = at_1 - u32(1);
            d_3[at_1] = d_3[_S40];
            g_4[at_1] = g_4[_S40];
            w_5[at_1] = w_5[_S40];
            id_0[at_1] = id_0[_S40];
            term_0[at_1] = term_0[_S40];
            at_1 = _S40;
        }
        d_3[at_1] = td_0;
        g_4[at_1] = tg_0;
        w_5[at_1] = tw_0;
        id_0[at_1] = tid_0;
        term_0[at_1] = j_2;
        var _S41 : u32 = count_0 + u32(1);
        self_d_1 = self_d_0;
        count_0 = _S41;
        var _S36 : u32 = j_2 + u32(1);
        others_1 = others_0;
        j_2 = _S36;
    }
    var grad_1 : vec3<f32> = g_4[i32(0)];
    others_0 = d_3[i32(0)];
    self_d_0 = 0.0f;
    j_2 = u32(1);
    for(;;)
    {
        if(j_2 < count_0)
        {
        }
        else
        {
            break;
        }
        var radius_1 : f32 = 0.0f;
        var pw_0 : f32 = 0.0f;
        at_1 = u32(0);
        var strength_0 : f32 = 0.0f;
        var i_2 : u32 = u32(0);
        for(;;)
        {
            if(i_2 < j_2)
            {
            }
            else
            {
                break;
            }
            var p_1 : vec4<f32> = term_pair_0(term_0[j_2], term_0[i_2]);
            var _S42 : f32 = p_1.x;
            if(_S42 > radius_1)
            {
                var _S43 : f32 = p_1.y;
                var _S44 : f32 = w_5[j_2] * w_5[i_2];
                var _S45 : u32 = u32(p_1.z);
                radius_1 = _S42;
                pw_0 = _S44;
                at_1 = _S45;
                strength_0 = _S43;
            }
            i_2 = i_2 + u32(1);
        }
        var k_2 : f32 = radius_at_0(radius_1, dot(normalize0_0(grad_1), normalize0_0(g_4[j_2])), pw_0, at_1);
        var b_4 : f32 = d_3[j_2];
        var grad_2 : vec3<f32>;
        if(k_2 <= 0.0f)
        {
            var acc_0 : f32;
            if(others_0 <= b_4)
            {
                grad_2 = grad_1;
                acc_0 = others_0;
            }
            else
            {
                grad_2 = g_4[j_2];
                acc_0 = b_4;
            }
            others_0 = acc_0;
        }
        else
        {
            var h_3 : f32 = max(k_2 - abs(others_0 - b_4), 0.0f) / k_2;
            var _S46 : f32 = strength_0 * h_3;
            var _S47 : f32 = min(others_0, b_4) - _S46 * h_3 * k_2 * 0.25f;
            if(others_0 <= b_4)
            {
                var _S48 : f32 = _S46 * 0.5f;
                grad_2 = grad_1 * vec3<f32>((1.0f - _S48)) + g_4[j_2] * vec3<f32>(_S48);
            }
            else
            {
                var _S49 : f32 = _S46 * 0.5f;
                grad_2 = g_4[j_2] * vec3<f32>((1.0f - _S49)) + grad_1 * vec3<f32>(_S49);
            }
            var _S50 : f32 = max(self_d_0, _S46);
            others_0 = _S47;
            self_d_0 = _S50;
        }
        var _S51 : u32 = j_2 + u32(1);
        grad_1 = grad_2;
        j_2 = _S51;
    }
    e_1.ok_0 = true;
    e_1.g_3 = others_0;
    e_1.grad_0 = grad_1;
    e_1.amount_0 = self_d_0;
    if(others_1 < 3.4028234663852886e+38f)
    {
        e_1.own_0 = clamp((others_1 - self_d_1) / Blend_Params_0.reach_0, -1.0f, 1.0f);
    }
    return e_1;
}

fn entry_0( offset_0 : vec3<f32>,  normal_0 : vec3<f32>,  amount_1 : f32,  own_1 : f32) -> vec4<u32>
{
    var n_1 : vec3<f32> = normalize0_0(normal_0);
    var _S52 : f32 = n_1.z;
    var l_2 : f32 = abs(n_1.x) + abs(n_1.y) + abs(_S52);
    var _S53 : vec2<f32> = vec2<f32>(0.0f);
    var e_2 : vec2<f32>;
    if(l_2 > 0.0f)
    {
        var e_3 : vec2<f32> = n_1.xy / vec2<f32>(l_2);
        if(_S52 < 0.0f)
        {
            var _S54 : f32 = e_3.x;
            var sx_1 : f32;
            if(_S54 >= 0.0f)
            {
                sx_1 = 1.0f;
            }
            else
            {
                sx_1 = -1.0f;
            }
            var _S55 : f32 = e_3.y;
            var sy_1 : f32;
            if(_S55 >= 0.0f)
            {
                sy_1 = 1.0f;
            }
            else
            {
                sy_1 = -1.0f;
            }
            e_2 = vec2<f32>((1.0f - abs(_S55)) * sx_1, (1.0f - abs(_S54)) * sy_1);
        }
        else
        {
            e_2 = e_3;
        }
    }
    else
    {
        e_2 = _S53;
    }
    return vec4<u32>((bitcast<u32>((offset_0.x))), (bitcast<u32>((offset_0.y))), (bitcast<u32>((offset_0.z))), (((((u32(round(clamp(e_2.x * 0.5f + 0.5f, 0.0f, 1.0f) * 4095.0f)) | (((u32(round(clamp(e_2.y * 0.5f + 0.5f, 0.0f, 1.0f) * 4095.0f)) << (u32(12))))))) | (((u32(round(clamp(amount_1, 0.0f, 1.0f) * 15.0f)) << (u32(24))))))) | (((u32(round(clamp(own_1 * 0.5f + 0.5f, 0.0f, 1.0f) * 15.0f)) << (u32(28)))))));
}

fn project_0( v_3 : u32) -> vec4<u32>
{
    var has_out_0 : bool;
    var has_in_0 : bool;
    var near_0 : bool;
    var turned_0 : bool;
    var offset_1 : vec3<f32>;
    var none_0 : vec4<u32> = vec4<u32>(u32(0));
    var _S56 : u32 = u32(3) * v_3;
    var x0_0 : vec3<f32> = vec3<f32>(positions_0[_S56], positions_0[_S56 + u32(1)], positions_0[_S56 + u32(2)]);
    var a0_0 : f32;
    var ga_0 : vec3<f32>;
    var wa_0 : f32;
    var _S57 : bool = term_at_1(u32(0), x0_0, &(a0_0), &(ga_0), &(wa_0));
    if(!_S57)
    {
        return none_0;
    }
    var near_1 : bool = false;
    var j_3 : u32 = u32(1);
    for(;;)
    {
        if(j_3 < (Blend_Params_0.term_count_0))
        {
        }
        else
        {
            break;
        }
        var radius_2 : f32 = term_pair_0(u32(0), j_3).x;
        if(radius_2 <= 0.0f)
        {
            j_3 = j_3 + u32(1);
            continue;
        }
        var b_5 : f32;
        var gb_0 : vec3<f32>;
        var wb_1 : f32;
        var _S58 : bool = term_at_1(j_3, x0_0, &(b_5), &(gb_0), &(wb_1));
        if(_S58)
        {
            has_out_0 = b_5 > (-0.5f * radius_2);
        }
        else
        {
            has_out_0 = false;
        }
        if(has_out_0)
        {
            has_in_0 = b_5 < radius_2;
        }
        else
        {
            has_in_0 = false;
        }
        if(has_in_0)
        {
            near_0 = true;
        }
        else
        {
            near_0 = near_1;
        }
        near_1 = near_0;
        j_3 = j_3 + u32(1);
    }
    if(!near_1)
    {
        return none_0;
    }
    var e0_0 : Eval_0 = evaluate_0(x0_0);
    if((e0_0.amount_0) <= 0.0f)
    {
        near_1 = (e0_0.g_3) < a0_0;
    }
    else
    {
        near_1 = false;
    }
    if(near_1)
    {
        return none_0;
    }
    var target_0 : f32 = a0_0 * (1.0f - e0_0.amount_0);
    var best_0 : f32 = abs(e0_0.g_3 - target_0);
    var _S59 : bool = best_0 < (0.00009999999747379f * Blend_Params_0.reach_0);
    var _S60 : vec3<f32> = vec3<f32>(0.0f);
    var last_dir_0 : vec3<f32> = _S60;
    var best_1 : f32 = best_0;
    var kept_0 : i32 = i32(0);
    has_out_0 = false;
    has_in_0 = false;
    var out_x_0 : vec3<f32> = _S60;
    var in_x_0 : vec3<f32> = _S60;
    var best_x_0 : vec3<f32> = x0_0;
    var steps_0 : u32 = u32(0);
    var x_7 : vec3<f32> = x0_0;
    var in_r_0 : f32 = 0.0f;
    var out_r_0 : f32 = 0.0f;
    for(;;)
    {
        if(!_S59)
        {
            near_1 = steps_0 < u32(10);
        }
        else
        {
            near_1 = false;
        }
        if(near_1)
        {
        }
        else
        {
            near_0 = _S59;
            turned_0 = false;
            break;
        }
        var e_4 : Eval_0 = evaluate_0(x_7);
        if(!e_4.ok_0)
        {
            near_0 = _S59;
            turned_0 = false;
            break;
        }
        var dir_0 : vec3<f32> = normalize0_0(e_4.grad_0);
        if(steps_0 > u32(0))
        {
            near_0 = (dot(dir_0, last_dir_0)) < 0.57357639074325562f;
        }
        else
        {
            near_0 = false;
        }
        if(near_0)
        {
            near_0 = _S59;
            turned_0 = true;
            break;
        }
        var _S61 : u32 = steps_0 + u32(1);
        var r_0 : f32 = e_4.g_3 - target_0;
        var _S62 : f32 = abs(r_0);
        var best_2 : f32;
        if(_S62 < best_1)
        {
            best_2 = _S62;
            offset_1 = x_7;
        }
        else
        {
            best_2 = best_1;
            offset_1 = best_x_0;
        }
        if(_S62 < (0.00009999999747379f * Blend_Params_0.reach_0))
        {
            near_0 = true;
            turned_0 = false;
            best_1 = best_2;
            best_x_0 = offset_1;
            break;
        }
        var has_in_1 : bool;
        var out_x_1 : vec3<f32>;
        var in_x_1 : vec3<f32>;
        var out_r_1 : f32;
        var in_r_1 : f32;
        var kept_1 : i32;
        if(r_0 > 0.0f)
        {
            if(kept_0 > i32(0))
            {
                out_r_1 = in_r_0 * 0.5f;
            }
            else
            {
                out_r_1 = in_r_0;
            }
            var _S63 : f32 = out_r_1;
            turned_0 = true;
            has_in_1 = has_in_0;
            out_x_1 = x_7;
            in_x_1 = in_x_0;
            kept_1 = i32(1);
            out_r_1 = r_0;
            in_r_1 = _S63;
        }
        else
        {
            if(kept_0 < i32(0))
            {
                out_r_1 = out_r_0 * 0.5f;
            }
            else
            {
                out_r_1 = out_r_0;
            }
            turned_0 = has_out_0;
            has_in_1 = true;
            out_x_1 = out_x_0;
            in_x_1 = x_7;
            kept_1 = i32(-1);
            in_r_1 = r_0;
        }
        var _S64 : bool;
        if(turned_0)
        {
            _S64 = has_in_1;
        }
        else
        {
            _S64 = false;
        }
        if(_S64)
        {
            var _S65 : vec3<f32> = out_x_1 + (in_x_1 - out_x_1) * vec3<f32>((out_r_1 / (out_r_1 - in_r_1)));
            last_dir_0 = dir_0;
            best_1 = best_2;
            kept_0 = kept_1;
            has_out_0 = turned_0;
            has_in_0 = has_in_1;
            out_x_0 = out_x_1;
            in_x_0 = in_x_1;
            best_x_0 = offset_1;
            steps_0 = _S61;
            x_7 = _S65;
            in_r_0 = in_r_1;
            out_r_0 = out_r_1;
            continue;
        }
        var gg_0 : f32 = dot(e_4.grad_0, e_4.grad_0);
        if(gg_0 < 9.99999993922529029e-09f)
        {
            near_0 = _S59;
            turned_0 = false;
            best_1 = best_2;
            best_x_0 = offset_1;
            break;
        }
        var step_0 : vec3<f32> = e_4.grad_0 * vec3<f32>((r_0 / gg_0));
        var l_3 : f32 = length(step_0);
        var step_1 : vec3<f32>;
        if(l_3 > (0.5f * Blend_Params_0.reach_0))
        {
            step_1 = step_0 * vec3<f32>((0.5f * Blend_Params_0.reach_0 / l_3));
        }
        else
        {
            step_1 = step_0;
        }
        var x_8 : vec3<f32> = x_7 - step_1;
        last_dir_0 = dir_0;
        best_1 = best_2;
        kept_0 = kept_1;
        has_out_0 = turned_0;
        has_in_0 = has_in_1;
        out_x_0 = out_x_1;
        in_x_0 = in_x_1;
        best_x_0 = offset_1;
        steps_0 = _S61;
        x_7 = x_8;
        in_r_0 = in_r_1;
        out_r_0 = out_r_1;
    }
    if(near_0)
    {
        best_x_0 = x_7;
    }
    else
    {
        if(!turned_0)
        {
            var e_5 : Eval_0 = evaluate_0(x_7);
            if(e_5.ok_0)
            {
                near_1 = (abs(e_5.g_3 - target_0)) < best_1;
            }
            else
            {
                near_1 = false;
            }
            if(near_1)
            {
                best_x_0 = x_7;
            }
        }
    }
    if((all((best_x_0 == x0_0))))
    {
        return none_0;
    }
    var f_2 : Eval_0 = evaluate_0(best_x_0);
    if((e0_0.g_3) < a0_0)
    {
        near_1 = (f_2.amount_0) < 0.05000000074505806f;
    }
    else
    {
        near_1 = false;
    }
    if(near_1)
    {
        return none_0;
    }
    var n_2 : vec3<f32> = normalize0_0(f_2.grad_0);
    var offset_2 : vec3<f32> = best_x_0 - x0_0;
    if((bitcast<u32>((terms_0[u32(3)].z))) < (f_2.rival_0))
    {
        if((f_2.own_0) < -0.05000000074505806f)
        {
            return none_0;
        }
        var _S66 : f32 = max(Blend_Params_0.self_edge_0, f_2.rival_edge_0);
        offset_1 = offset_2 + n_2 * vec3<f32>((max(0.0020000000949949f * Blend_Params_0.reach_0, 0.75f * _S66 * _S66 / Blend_Params_0.reach_0) * clamp(1.0f - f_2.own_0 / 0.5f, 0.0f, 1.0f)));
    }
    else
    {
        offset_1 = offset_2;
    }
    return entry_0(offset_1, n_2, f_2.amount_0, f_2.own_0);
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    var g_5 : u32 = group_id_0.y * Blend_Params_0.groups_x_0 + group_id_0.x;
    var slot_0 : u32 = (g_5 >> (u32(2)));
    if(slot_0 >= (Blend_Params_0.slot_count_0))
    {
        return;
    }
    var k_3 : u32 = ((g_5 & (u32(3)))) * u32(256) + local_id_0.x;
    var v_4 : u32 = page_list_0[slot_0] * u32(1024) + k_3;
    var _S67 : vec4<u32> = vec4<u32>(u32(0));
    var result_0 : vec4<u32>;
    if(v_4 < (Blend_Params_0.vertex_count_0))
    {
        result_0 = project_0(v_4);
    }
    else
    {
        result_0 = _S67;
    }
    pages_0[slot_0 * u32(1024) + k_3] = result_0;
    return;
}

