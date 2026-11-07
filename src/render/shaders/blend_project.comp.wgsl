// slangc wgsl from blend_project.comp.spv sha256 b1d6df237f9e00d857e16bbf65c0aa7253e96d62cbc22fdd18693381784ff227
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
    @align(16) pair_table_0 : array<vec4<f32>, i32(32)>,
};

@binding(0) @group(2) var<uniform> Blend_Params_0 : SLANG_ParameterGroup_Blend_Params_std140_0;
@binding(2) @group(0) var<storage, read> page_list_0 : array<u32>;

@binding(0) @group(0) var<storage, read> positions_0 : array<f32>;

@binding(12) @group(0) var<storage, read> terms_0 : array<vec4<f32>>;

@binding(4) @group(0) var<storage, read> fields_0 : array<vec4<u32>>;

@binding(6) @group(0) var<storage, read> brick_table_0 : array<vec4<u32>>;

@binding(8) @group(0) var<storage, read> brick_values_0 : array<f32>;

@binding(10) @group(0) var<storage, read> brick_weights_0 : array<u32>;

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
    var mask_0 : u32 = ((fd_0.z) & (u32(2147483647)));
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

struct Cell_0
{
     base_0 : i32,
     l_0 : vec3<i32>,
     t_0 : vec3<f32>,
};

fn locate_0( f_1 : u32,  p_0 : vec3<f32>) -> Cell_0
{
    var q_0 : vec3<f32> = p_0 / vec3<f32>((bitcast<f32>((fields_0[f_1].x))));
    var cell_0 : vec3<f32> = floor(q_0);
    var _S9 : vec3<i32> = vec3<i32>(floor(cell_0 / vec3<f32>(8.0f)));
    var c_0 : Cell_0;
    c_0.base_0 = brick_base_0(f_1, _S9);
    c_0.l_0 = vec3<i32>(cell_0) - _S9 * vec3<i32>(i32(8));
    c_0.t_0 = q_0 - cell_0;
    return c_0;
}

fn sample_index_0( at_0 : vec3<i32>) -> u32
{
    return u32((at_0.z * i32(9) + at_0.y) * i32(9) + at_0.x);
}

fn sample_at_0( base_1 : i32,  l_1 : vec3<i32>,  k_0 : u32) -> f32
{
    return brick_values_0[u32(base_1) + sample_index_0(l_1 + vec3<i32>(i32((k_0 & (u32(1)))), i32((((k_0 >> (u32(1)))) & (u32(1)))), i32((((k_0 >> (u32(2)))) & (u32(1))))))];
}

fn weight_at_0( base_2 : i32,  l_2 : vec3<i32>,  k_1 : u32) -> f32
{
    var i_1 : u32 = u32(base_2) + sample_index_0(l_2 + vec3<i32>(i32((k_1 & (u32(1)))), i32((((k_1 >> (u32(1)))) & (u32(1)))), i32((((k_1 >> (u32(2)))) & (u32(1))))));
    return f32((((brick_weights_0[(i_1 >> (u32(2)))] >> ((u32(8) * ((i_1 & (u32(3)))))))) & (u32(255))));
}

fn mixf_0( a_0 : f32,  b_1 : f32,  t_1 : f32) -> f32
{
    return a_0 * (1.0f - t_1) + b_1 * t_1;
}

fn field_at_0( f_2 : u32,  p_1 : vec3<f32>,  d_0 : ptr<function, f32>,  g_0 : ptr<function, vec3<f32>>,  w_0 : ptr<function, f32>) -> bool
{
    (*d_0) = 0.0f;
    (*g_0) = vec3<f32>(0.0f);
    (*w_0) = 0.0f;
    var c_1 : Cell_0 = locate_0(f_2, p_1);
    if((c_1.base_0) < i32(0))
    {
        return false;
    }
    var h_3 : f32 = (bitcast<f32>((fields_0[f_2].x)));
    var _S10 : bool = (((fields_0[f_2].z) & (u32(2147483648)))) != u32(0);
    var v_0 : array<f32, i32(8)>;
    var wc_0 : array<f32, i32(8)>;
    var k_2 : u32 = u32(0);
    for(;;)
    {
        if(k_2 < u32(8))
        {
        }
        else
        {
            break;
        }
        v_0[k_2] = sample_at_0(c_1.base_0, c_1.l_0, k_2);
        var _S11 : f32;
        if(_S10)
        {
            _S11 = weight_at_0(c_1.base_0, c_1.l_0, k_2);
        }
        else
        {
            _S11 = 0.0f;
        }
        wc_0[k_2] = _S11;
        k_2 = k_2 + u32(1);
    }
    var _S12 : f32 = c_1.t_0.x;
    var _S13 : f32 = c_1.t_0.y;
    var y0_0 : f32 = mixf_0(mixf_0(v_0[i32(0)], v_0[i32(1)], _S12), mixf_0(v_0[i32(2)], v_0[i32(3)], _S12), _S13);
    var y1_0 : f32 = mixf_0(mixf_0(v_0[i32(4)], v_0[i32(5)], _S12), mixf_0(v_0[i32(6)], v_0[i32(7)], _S12), _S13);
    var _S14 : f32 = c_1.t_0.z;
    (*d_0) = mixf_0(y0_0, y1_0, _S14);
    (*g_0) = vec3<f32>(mixf_0(mixf_0(v_0[i32(1)] - v_0[i32(0)], v_0[i32(3)] - v_0[i32(2)], _S13), mixf_0(v_0[i32(5)] - v_0[i32(4)], v_0[i32(7)] - v_0[i32(6)], _S13), _S14), mixf_0(mixf_0(v_0[i32(2)] - v_0[i32(0)], v_0[i32(3)] - v_0[i32(1)], _S12), mixf_0(v_0[i32(6)] - v_0[i32(4)], v_0[i32(7)] - v_0[i32(5)], _S12), _S14), y1_0 - y0_0) / vec3<f32>(h_3);
    (*w_0) = 1.0f - mixf_0(mixf_0(mixf_0(wc_0[i32(0)], wc_0[i32(1)], _S12), mixf_0(wc_0[i32(2)], wc_0[i32(3)], _S12), _S13), mixf_0(mixf_0(wc_0[i32(4)], wc_0[i32(5)], _S12), mixf_0(wc_0[i32(6)], wc_0[i32(7)], _S12), _S13), _S14) / 255.0f;
    return true;
}

fn mix3_0( a_1 : vec3<f32>,  b_2 : vec3<f32>,  t_2 : f32) -> vec3<f32>
{
    return a_1 * vec3<f32>((1.0f - t_2)) + b_2 * vec3<f32>(t_2);
}

fn field_normal_0( f_3 : u32,  p_2 : vec3<f32>,  g_1 : ptr<function, vec3<f32>>) -> bool
{
    (*g_1) = vec3<f32>(0.0f);
    var c_2 : Cell_0 = locate_0(f_3, p_2);
    if((c_2.base_0) < i32(0))
    {
        return false;
    }
    var _S15 : f32 = (bitcast<f32>((fields_0[f_3].x)));
    var gc_0 : array<vec3<f32>, i32(8)>;
    var k_3 : u32 = u32(0);
    for(;;)
    {
        if(k_3 < u32(8))
        {
        }
        else
        {
            break;
        }
        var _S16 : vec3<i32> = c_2.l_0 + vec3<i32>(i32((k_3 & (u32(1)))), i32((((k_3 >> (u32(1)))) & (u32(1)))), i32((((k_3 >> (u32(2)))) & (u32(1)))));
        var a_2 : u32 = u32(0);
        for(;;)
        {
            if(a_2 < u32(3))
            {
            }
            else
            {
                break;
            }
            var lo_0 : vec3<i32> = _S16;
            var hi_0 : vec3<i32> = _S16;
            if((lo_0[a_2]) > i32(0))
            {
                lo_0[a_2] = lo_0[a_2] - i32(1);
            }
            if((hi_0[a_2]) < i32(8))
            {
                hi_0[a_2] = hi_0[a_2] + i32(1);
            }
            var _S17 : u32 = u32(c_2.base_0);
            gc_0[k_3][a_2] = (brick_values_0[_S17 + sample_index_0(hi_0)] - brick_values_0[_S17 + sample_index_0(lo_0)]) / (f32(hi_0[a_2] - lo_0[a_2]) * _S15);
            a_2 = a_2 + u32(1);
        }
        k_3 = k_3 + u32(1);
    }
    var _S18 : f32 = c_2.t_0.x;
    var _S19 : f32 = c_2.t_0.y;
    (*g_1) = mix3_0(mix3_0(mix3_0(gc_0[i32(0)], gc_0[i32(1)], _S18), mix3_0(gc_0[i32(2)], gc_0[i32(3)], _S18), _S19), mix3_0(mix3_0(gc_0[i32(4)], gc_0[i32(5)], _S18), mix3_0(gc_0[i32(6)], gc_0[i32(7)], _S18), _S19), c_2.t_0.z);
    return true;
}

fn term_at_0( j_0 : u32,  x_2 : vec3<f32>,  smooth_0 : bool,  d_1 : ptr<function, f32>,  g_2 : ptr<function, vec3<f32>>,  w_1 : ptr<function, f32>) -> bool
{
    var _S20 : u32 = u32(4) * j_0;
    var r0_0 : vec4<f32> = terms_0[_S20];
    var r1_0 : vec4<f32> = terms_0[_S20 + u32(1)];
    var r2_0 : vec4<f32> = terms_0[_S20 + u32(2)];
    var info_0 : vec4<f32> = terms_0[_S20 + u32(3)];
    var f_4 : u32 = (bitcast<u32>((info_0.w)));
    var _S21 : vec3<f32> = r0_0.xyz;
    var _S22 : vec3<f32> = r1_0.xyz;
    var _S23 : vec3<f32> = r2_0.xyz;
    var p_3 : vec3<f32> = vec3<f32>(dot(_S21, x_2) + r0_0.w, dot(_S22, x_2) + r1_0.w, dot(_S23, x_2) + r2_0.w);
    var _S24 : bool = field_at_0(f_4, p_3, &((*d_1)), &((*g_2)), &((*w_1)));
    if(!_S24)
    {
        return false;
    }
    if(smooth_0)
    {
        var n_1 : vec3<f32>;
        var _S25 : bool = field_normal_0(f_4, p_3, &(n_1));
        if(_S25)
        {
            (*g_2) = n_1;
        }
    }
    var _S26 : f32 = info_0.x;
    (*d_1) = (*d_1) * _S26;
    (*g_2) = (_S21 * vec3<f32>((*g_2).x) + _S22 * vec3<f32>((*g_2).y) + _S23 * vec3<f32>((*g_2).z)) * vec3<f32>(_S26);
    return true;
}

fn term_at_1( j_1 : u32,  x_3 : vec3<f32>,  smooth_1 : bool,  d_2 : ptr<function, f32>,  g_3 : ptr<function, vec3<f32>>,  w_2 : ptr<function, f32>) -> bool
{
    var _S27 : u32 = u32(4) * j_1;
    var r0_1 : vec4<f32> = terms_0[_S27];
    var r1_1 : vec4<f32> = terms_0[_S27 + u32(1)];
    var r2_1 : vec4<f32> = terms_0[_S27 + u32(2)];
    var info_1 : vec4<f32> = terms_0[_S27 + u32(3)];
    var f_5 : u32 = (bitcast<u32>((info_1.w)));
    var _S28 : vec3<f32> = r0_1.xyz;
    var _S29 : vec3<f32> = r1_1.xyz;
    var _S30 : vec3<f32> = r2_1.xyz;
    var p_4 : vec3<f32> = vec3<f32>(dot(_S28, x_3) + r0_1.w, dot(_S29, x_3) + r1_1.w, dot(_S30, x_3) + r2_1.w);
    var _S31 : bool = field_at_0(f_5, p_4, &((*d_2)), &((*g_3)), &((*w_2)));
    if(!_S31)
    {
        return false;
    }
    if(smooth_1)
    {
        var n_2 : vec3<f32>;
        var _S32 : bool = field_normal_0(f_5, p_4, &(n_2));
        if(_S32)
        {
            (*g_3) = n_2;
        }
    }
    var _S33 : f32 = info_1.x;
    (*d_2) = (*d_2) * _S33;
    (*g_3) = (_S28 * vec3<f32>((*g_3).x) + _S29 * vec3<f32>((*g_3).y) + _S30 * vec3<f32>((*g_3).z)) * vec3<f32>(_S33);
    return true;
}

fn term_pair_0( a_3 : u32,  b_3 : u32) -> vec2<f32>
{
    var i_2 : u32 = a_3 * u32(8) + b_3;
    var two_0 : vec4<f32> = Blend_Params_0.pair_table_0[(i_2 >> (u32(1)))];
    var _S34 : vec2<f32>;
    if(((i_2 & (u32(1)))) == u32(0))
    {
        _S34 = two_0.xy;
    }
    else
    {
        _S34 = two_0.zw;
    }
    return _S34;
}

fn normalize0_0( v_1 : vec3<f32>) -> vec3<f32>
{
    var l_3 : f32 = length(v_1);
    var _S35 : vec3<f32>;
    if(l_3 > 0.0f)
    {
        _S35 = v_1 / vec3<f32>(l_3);
    }
    else
    {
        _S35 = vec3<f32>(0.0f);
    }
    return _S35;
}

fn radius_at_0( radius_0 : f32,  c_3 : f32,  w_3 : f32) -> f32
{
    var t_3 : f32 = clamp((c_3 - -0.80000001192092896f) / 0.5f, 0.0f, 1.0f);
    return radius_0 * w_3 * t_3 * t_3 * (3.0f - 2.0f * t_3);
}

struct Eval_0
{
     ok_0 : bool,
     g_4 : f32,
     grad_0 : vec3<f32>,
     amount_0 : f32,
     own_0 : f32,
     rival_0 : u32,
     rival_edge_0 : f32,
};

fn evaluate_0( x_4 : vec3<f32>,  smooth_2 : bool) -> Eval_0
{
    var at_1 : u32;
    var others_0 : f32;
    var self_d_0 : f32;
    var e_1 : Eval_0;
    e_1.ok_0 = false;
    e_1.g_4 = 0.0f;
    var _S36 : vec3<f32> = vec3<f32>(0.0f);
    e_1.grad_0 = _S36;
    e_1.amount_0 = 0.0f;
    e_1.own_0 = 1.0f;
    e_1.rival_0 = u32(4294967295);
    e_1.rival_edge_0 = 0.0f;
    var d_3 : array<f32, i32(8)>;
    var g_5 : array<vec3<f32>, i32(8)>;
    var w_4 : array<f32, i32(8)>;
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
        g_5[z_2] = _S36;
        w_4[z_2] = 0.0f;
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
        var _S37 : bool = term_at_0(j_2, x_4, smooth_2, &(td_0), &(tg_0), &(tw_0));
        if(!_S37)
        {
            if(j_2 == u32(0))
            {
                return e_1;
            }
            others_0 = others_1;
            var _S38 : u32 = j_2 + u32(1);
            others_1 = others_0;
            j_2 = _S38;
            continue;
        }
        var _S39 : u32 = u32(4) * j_2 + u32(3);
        var tid_0 : u32 = (bitcast<u32>((terms_0[_S39].z)));
        var _S40 : bool;
        if(j_2 == u32(0))
        {
            others_0 = others_1;
            self_d_0 = td_0;
        }
        else
        {
            if(td_0 < others_1)
            {
                _S40 = true;
            }
            else
            {
                if(td_0 == others_1)
                {
                    _S40 = tid_0 < (e_1.rival_0);
                }
                else
                {
                    _S40 = false;
                }
            }
            if(_S40)
            {
                e_1.rival_0 = tid_0;
                e_1.rival_edge_0 = terms_0[_S39].y;
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
                var _S41 : u32 = at_1 - u32(1);
                if(td_0 < (d_3[_S41]))
                {
                    _S40 = true;
                }
                else
                {
                    if(td_0 == (d_3[_S41]))
                    {
                        _S40 = tid_0 < (id_0[_S41]);
                    }
                    else
                    {
                        _S40 = false;
                    }
                }
            }
            else
            {
                _S40 = false;
            }
            if(_S40)
            {
            }
            else
            {
                break;
            }
            var _S42 : u32 = at_1 - u32(1);
            d_3[at_1] = d_3[_S42];
            g_5[at_1] = g_5[_S42];
            w_4[at_1] = w_4[_S42];
            id_0[at_1] = id_0[_S42];
            term_0[at_1] = term_0[_S42];
            at_1 = _S42;
        }
        d_3[at_1] = td_0;
        g_5[at_1] = tg_0;
        w_4[at_1] = tw_0;
        id_0[at_1] = tid_0;
        term_0[at_1] = j_2;
        var _S43 : u32 = count_0 + u32(1);
        self_d_1 = self_d_0;
        count_0 = _S43;
        var _S38 : u32 = j_2 + u32(1);
        others_1 = others_0;
        j_2 = _S38;
    }
    var grad_1 : vec3<f32> = g_5[i32(0)];
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
        var strength_0 : f32 = 0.0f;
        at_1 = u32(0);
        for(;;)
        {
            if(at_1 < j_2)
            {
            }
            else
            {
                break;
            }
            var p_5 : vec2<f32> = term_pair_0(term_0[j_2], term_0[at_1]);
            var _S44 : f32 = p_5.x;
            if(_S44 > radius_1)
            {
                var _S45 : f32 = p_5.y;
                var _S46 : f32 = w_4[j_2] * w_4[at_1];
                radius_1 = _S44;
                pw_0 = _S46;
                strength_0 = _S45;
            }
            at_1 = at_1 + u32(1);
        }
        var k_4 : f32 = radius_at_0(radius_1, dot(normalize0_0(grad_1), normalize0_0(g_5[j_2])), pw_0);
        var b_4 : f32 = d_3[j_2];
        var grad_2 : vec3<f32>;
        if(k_4 <= 0.0f)
        {
            var acc_0 : f32;
            if(others_0 <= b_4)
            {
                grad_2 = grad_1;
                acc_0 = others_0;
            }
            else
            {
                grad_2 = g_5[j_2];
                acc_0 = b_4;
            }
            others_0 = acc_0;
        }
        else
        {
            var h_4 : f32 = max(k_4 - abs(others_0 - b_4), 0.0f) / k_4;
            var _S47 : f32 = strength_0 * h_4;
            var _S48 : f32 = min(others_0, b_4) - _S47 * h_4 * k_4 * 0.25f;
            if(others_0 <= b_4)
            {
                var _S49 : f32 = _S47 * 0.5f;
                grad_2 = grad_1 * vec3<f32>((1.0f - _S49)) + g_5[j_2] * vec3<f32>(_S49);
            }
            else
            {
                var _S50 : f32 = _S47 * 0.5f;
                grad_2 = g_5[j_2] * vec3<f32>((1.0f - _S50)) + grad_1 * vec3<f32>(_S50);
            }
            var _S51 : f32 = max(self_d_0, _S47);
            others_0 = _S48;
            self_d_0 = _S51;
        }
        var _S52 : u32 = j_2 + u32(1);
        grad_1 = grad_2;
        j_2 = _S52;
    }
    e_1.ok_0 = true;
    e_1.g_4 = others_0;
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
    var n_3 : vec3<f32> = normalize0_0(normal_0);
    var _S53 : f32 = n_3.z;
    var l_4 : f32 = abs(n_3.x) + abs(n_3.y) + abs(_S53);
    var _S54 : vec2<f32> = vec2<f32>(0.0f);
    var e_2 : vec2<f32>;
    if(l_4 > 0.0f)
    {
        var e_3 : vec2<f32> = n_3.xy / vec2<f32>(l_4);
        if(_S53 < 0.0f)
        {
            var _S55 : f32 = e_3.x;
            var sx_0 : f32;
            if(_S55 >= 0.0f)
            {
                sx_0 = 1.0f;
            }
            else
            {
                sx_0 = -1.0f;
            }
            var _S56 : f32 = e_3.y;
            var sy_0 : f32;
            if(_S56 >= 0.0f)
            {
                sy_0 = 1.0f;
            }
            else
            {
                sy_0 = -1.0f;
            }
            e_2 = vec2<f32>((1.0f - abs(_S56)) * sx_0, (1.0f - abs(_S55)) * sy_0);
        }
        else
        {
            e_2 = e_3;
        }
    }
    else
    {
        e_2 = _S54;
    }
    return vec4<u32>((bitcast<u32>((offset_0.x))), (bitcast<u32>((offset_0.y))), (bitcast<u32>((offset_0.z))), (((((u32(round(clamp(e_2.x * 0.5f + 0.5f, 0.0f, 1.0f) * 4095.0f)) | (((u32(round(clamp(e_2.y * 0.5f + 0.5f, 0.0f, 1.0f) * 4095.0f)) << (u32(12))))))) | (((u32(round(clamp(amount_1, 0.0f, 1.0f) * 15.0f)) << (u32(24))))))) | (((u32(round(clamp(own_1 * 0.5f + 0.5f, 0.0f, 1.0f) * 15.0f)) << (u32(28)))))));
}

fn project_0( v_2 : u32) -> vec4<u32>
{
    var converged_0 : bool;
    var offset_1 : vec3<f32>;
    var none_0 : vec4<u32> = vec4<u32>(u32(0));
    var _S57 : u32 = u32(3) * v_2;
    var x0_0 : vec3<f32> = vec3<f32>(positions_0[_S57], positions_0[_S57 + u32(1)], positions_0[_S57 + u32(2)]);
    var a0_0 : f32;
    var ga_0 : vec3<f32>;
    var wa_0 : f32;
    var _S58 : bool = term_at_1(u32(0), x0_0, false, &(a0_0), &(ga_0), &(wa_0));
    if(!_S58)
    {
        return none_0;
    }
    var near_0 : bool = false;
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
        var wb_0 : f32;
        var _S59 : bool = term_at_1(j_3, x0_0, false, &(b_5), &(gb_0), &(wb_0));
        if(_S59)
        {
            converged_0 = b_5 > (-0.5f * radius_2);
        }
        else
        {
            converged_0 = false;
        }
        var _S60 : bool;
        if(converged_0)
        {
            _S60 = b_5 < radius_2;
        }
        else
        {
            _S60 = false;
        }
        var near_1 : bool;
        if(_S60)
        {
            near_1 = true;
        }
        else
        {
            near_1 = near_0;
        }
        near_0 = near_1;
        j_3 = j_3 + u32(1);
    }
    if(!near_0)
    {
        return none_0;
    }
    var e0_0 : Eval_0 = evaluate_0(x0_0, false);
    if((e0_0.amount_0) <= 0.0f)
    {
        near_0 = (e0_0.g_4) < a0_0;
    }
    else
    {
        near_0 = false;
    }
    if(near_0)
    {
        return none_0;
    }
    var target_0 : f32 = a0_0 * (1.0f - e0_0.amount_0);
    var best_0 : f32 = abs(e0_0.g_4 - target_0);
    var _S61 : bool = best_0 < (0.00009999999747379f * Blend_Params_0.reach_0);
    var best_1 : f32 = best_0;
    var best_x_0 : vec3<f32> = x0_0;
    var steps_0 : u32 = u32(0);
    var x_5 : vec3<f32> = x0_0;
    for(;;)
    {
        if(!_S61)
        {
            near_0 = steps_0 < u32(6);
        }
        else
        {
            near_0 = false;
        }
        if(near_0)
        {
        }
        else
        {
            converged_0 = _S61;
            break;
        }
        var e_4 : Eval_0 = evaluate_0(x_5, false);
        if(!e_4.ok_0)
        {
            converged_0 = _S61;
            break;
        }
        var _S62 : u32 = steps_0 + u32(1);
        var r_0 : f32 = e_4.g_4 - target_0;
        var _S63 : f32 = abs(r_0);
        var best_2 : f32;
        if(_S63 < best_1)
        {
            best_2 = _S63;
            offset_1 = x_5;
        }
        else
        {
            best_2 = best_1;
            offset_1 = best_x_0;
        }
        if(_S63 < (0.00009999999747379f * Blend_Params_0.reach_0))
        {
            converged_0 = true;
            best_1 = best_2;
            best_x_0 = offset_1;
            break;
        }
        var _S64 : vec3<f32> = e_4.grad_0;
        var gg_0 : f32 = dot(_S64, _S64);
        if(gg_0 < 9.99999993922529029e-09f)
        {
            converged_0 = _S61;
            best_1 = best_2;
            best_x_0 = offset_1;
            break;
        }
        var step_0 : vec3<f32> = e_4.grad_0 * vec3<f32>((r_0 / gg_0));
        var l_5 : f32 = length(step_0);
        var step_1 : vec3<f32>;
        if(l_5 > (0.5f * Blend_Params_0.reach_0))
        {
            step_1 = step_0 * vec3<f32>((0.5f * Blend_Params_0.reach_0 / l_5));
        }
        else
        {
            step_1 = step_0;
        }
        var x_6 : vec3<f32> = x_5 - step_1;
        best_1 = best_2;
        best_x_0 = offset_1;
        steps_0 = _S62;
        x_5 = x_6;
    }
    if(converged_0)
    {
        best_x_0 = x_5;
    }
    else
    {
        var e_5 : Eval_0 = evaluate_0(x_5, false);
        if(e_5.ok_0)
        {
            near_0 = (abs(e_5.g_4 - target_0)) < best_1;
        }
        else
        {
            near_0 = false;
        }
        if(near_0)
        {
            best_x_0 = x_5;
        }
    }
    if((all((best_x_0 == x0_0))))
    {
        return none_0;
    }
    var f_6 : Eval_0 = evaluate_0(best_x_0, true);
    var n_4 : vec3<f32> = normalize0_0(f_6.grad_0);
    var offset_2 : vec3<f32> = best_x_0 - x0_0;
    if((bitcast<u32>((terms_0[u32(3)].z))) < (f_6.rival_0))
    {
        if((f_6.own_0) < -0.05000000074505806f)
        {
            return none_0;
        }
        var _S65 : f32 = max(Blend_Params_0.self_edge_0, f_6.rival_edge_0);
        offset_1 = offset_2 + n_4 * vec3<f32>((max(0.0020000000949949f * Blend_Params_0.reach_0, 0.75f * _S65 * _S65 / Blend_Params_0.reach_0) * clamp(1.0f - f_6.own_0 / 0.5f, 0.0f, 1.0f)));
    }
    else
    {
        offset_1 = offset_2;
    }
    return entry_0(offset_1, n_4, f_6.amount_0, f_6.own_0);
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    var g_6 : u32 = group_id_0.y * Blend_Params_0.groups_x_0 + group_id_0.x;
    var slot_0 : u32 = (g_6 >> (u32(2)));
    if(slot_0 >= (Blend_Params_0.slot_count_0))
    {
        return;
    }
    var k_5 : u32 = ((g_6 & (u32(3)))) * u32(256) + local_id_0.x;
    var v_3 : u32 = page_list_0[slot_0] * u32(1024) + k_5;
    var _S66 : vec4<u32> = vec4<u32>(u32(0));
    var result_0 : vec4<u32>;
    if(v_3 < (Blend_Params_0.vertex_count_0))
    {
        result_0 = project_0(v_3);
    }
    else
    {
        result_0 = _S66;
    }
    pages_0[slot_0 * u32(1024) + k_5] = result_0;
    return;
}

