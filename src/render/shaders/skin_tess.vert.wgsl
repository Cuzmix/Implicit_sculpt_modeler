// slangc wgsl from skin_tess.vert.spv sha256 86761715b497e85df499a52459ed5e39951cb585729f148d90989a31e9d27921
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
@binding(2) @group(0) var<storage, read> indices_0 : array<u32>;

@binding(10) @group(0) var<storage, read> skin_tris_0 : array<vec4<u32>>;

@binding(4) @group(0) var<storage, read> positions_0 : array<f32>;

@binding(6) @group(0) var<storage, read> normals_0 : array<u32>;

@binding(12) @group(0) var<storage, read> skin_heights_0 : array<u32>;

@binding(8) @group(0) var<storage, read> skin_normals_0 : array<u32>;

@binding(0) @group(0) var<storage, read> paint_0 : array<vec2<u32>>;

fn mesh_point_0( v_0 : u32) -> vec3<f32>
{
    var _S1 : u32 = u32(3) * v_0;
    return vec3<f32>(positions_0[_S1], positions_0[_S1 + u32(1)], positions_0[_S1 + u32(2)]);
}

fn oct_decode_0( e_0 : vec2<f32>) -> vec3<f32>
{
    var _S2 : f32 = e_0.x;
    var _S3 : f32 = e_0.y;
    var _S4 : vec3<f32> = vec3<f32>(e_0, 1.0f - abs(_S2) - abs(_S3));
    var v_1 : vec3<f32> = _S4;
    if((_S4.z) < 0.0f)
    {
        var _S5 : vec2<f32> = vec2<f32>(1.0f) - abs(e_0.yx);
        var _S6 : f32;
        if(_S2 >= 0.0f)
        {
            _S6 = 1.0f;
        }
        else
        {
            _S6 = -1.0f;
        }
        var _S7 : f32;
        if(_S3 >= 0.0f)
        {
            _S7 = 1.0f;
        }
        else
        {
            _S7 = -1.0f;
        }
        var _S8 : vec2<f32> = _S5 * vec2<f32>(_S6, _S7);
        v_1.x = _S8.x;
        v_1.y = _S8.y;
    }
    return normalize(v_1);
}

fn decode_normal_mask_0( normal_oct_0 : vec2<f32>,  normal_0 : ptr<function, vec3<f32>>,  mask_0 : ptr<function, f32>)
{
    var _S9 : vec2<f32> = vec2<f32>(32767.0f);
    var _S10 : vec2<i32> = vec2<i32>(round(max(normal_oct_0, vec2<f32>(-1.0f)) * _S9));
    (*normal_0) = oct_decode_0(vec2<f32>((_S10 & (vec2<i32>(i32(-16))))) / _S9);
    (*mask_0) = f32(((((((_S10.x) & (i32(15)))) << (u32(4)))) | ((((_S10.y) & (i32(15))))))) / 255.0f;
    return;
}

fn mesh_normal_mask_0( v_2 : u32,  n_0 : ptr<function, vec3<f32>>,  mask_1 : ptr<function, f32>)
{
    var packed_0 : u32 = normals_0[v_2];
    decode_normal_mask_0(max(vec2<f32>(vec2<i32>((i32((packed_0 << (u32(16)))) >> (u32(16))), (i32(packed_0) >> (u32(16))))) / vec2<f32>(32767.0f), vec2<f32>(-1.0f)), &((*n_0)), &((*mask_1)));
    return;
}

fn skin_index_0( i_0 : u32,  j_0 : u32,  S_0 : u32,  V_0 : u32,  E_0 : u32,  tri_0 : u32,  v_3 : vec3<u32>,  e_1 : vec3<u32>) -> u32
{
    var _S11 : bool = i_0 == u32(0);
    var _S12 : bool;
    if(_S11)
    {
        _S12 = j_0 == u32(0);
    }
    else
    {
        _S12 = false;
    }
    if(_S12)
    {
        return v_3.x;
    }
    if(i_0 == S_0)
    {
        return v_3.y;
    }
    if(j_0 == S_0)
    {
        return v_3.z;
    }
    var ref_0 : u32;
    var k_0 : u32;
    if(j_0 == u32(0))
    {
        ref_0 = e_1.x;
        k_0 = i_0;
    }
    else
    {
        if((i_0 + j_0) == S_0)
        {
            ref_0 = e_1.y;
            k_0 = j_0;
        }
        else
        {
            var _S13 : u32 = u32(0);
            var _S14 : u32 = u32(0);
            if(_S11)
            {
                _S14 = e_1.z;
                _S13 = S_0 - j_0;
            }
            else
            {
                var _S15 : u32 = j_0 - u32(1);
                var _S16 : u32 = S_0 - u32(2);
                var _S17 : u32 = S_0 - u32(1);
                return V_0 + E_0 * _S17 + tri_0 * (_S17 * _S16 / u32(2)) + (_S15 * _S16 - _S15 * (j_0 - u32(2)) / u32(2)) + (i_0 - u32(1));
            }
            ref_0 = _S14;
            k_0 = _S13;
        }
    }
    var along_0 : u32;
    if(((ref_0 & (u32(1)))) == u32(0))
    {
        along_0 = k_0;
    }
    else
    {
        along_0 = S_0 - k_0;
    }
    return V_0 + ((ref_0 >> (u32(1)))) * (S_0 - u32(1)) + (along_0 - u32(1));
}

fn half_bits_0( h_0 : u32) -> f32
{
    var e_2 : u32 = (((h_0 >> (u32(10)))) & (u32(31)));
    var m_0 : f32 = f32((h_0 & (u32(1023))));
    var v_4 : f32;
    if(e_2 == u32(0))
    {
        v_4 = m_0 * exp2(-24.0f);
    }
    else
    {
        v_4 = (1.0f + m_0 / 1024.0f) * exp2(f32(e_2) - 15.0f);
    }
    if(((h_0 & (u32(32768)))) != u32(0))
    {
        v_4 = - v_4;
    }
    return v_4;
}

fn octahedral_0( p_0 : u32) -> vec3<f32>
{
    return oct_decode_0(max(vec2<f32>(vec2<i32>((i32((p_0 << (u32(16)))) >> (u32(16))), (i32(p_0) >> (u32(16))))) / vec2<f32>(32767.0f), vec2<f32>(-1.0f)));
}

fn srgb_decode_0( c_0 : vec3<f32>) -> vec3<f32>
{
    return mix(c_0 / vec3<f32>(12.92000007629394531f), pow((c_0 + vec3<f32>(0.05499999970197678f)) / vec3<f32>(1.0549999475479126f), vec3<f32>(2.40000009536743164f)), step(vec3<f32>(0.04044999927282333f), c_0));
}

fn group_color_0( g_0 : u32) -> vec3<f32>
{
    var _S18 : vec3<f32> = vec3<f32>(3.0f);
    var _S19 : vec3<f32> = vec3<f32>(1.0f);
    var rgb_0 : vec3<f32> = clamp(abs(fract(vec3<f32>(fract(f32(g_0) * 0.6180340051651001f + 0.11999999731779099f)) + vec3<f32>(0.0f, 2.0f, 1.0f) / _S18) * vec3<f32>(6.0f) - _S18) - vec3<f32>(1.0f), vec3<f32>(0.0f), _S19);
    var light_0 : f32;
    if(((g_0 & (u32(1)))) == u32(0))
    {
        light_0 = 0.75f;
    }
    else
    {
        light_0 = 0.55000001192092896f;
    }
    return mix(_S19, rgb_0, vec3<f32>(0.55000001192092896f)) * vec3<f32>(light_0);
}

struct Mesh_Vertex_Out_0
{
    @builtin(position) position_0 : vec4<f32>,
    @location(0) view_normal_0 : vec3<f32>,
    @location(1) view_pos_0 : vec3<f32>,
    @location(3) mask_2 : f32,
    @location(4) paint_1 : vec4<f32>,
    @interpolate(flat) @location(5) group_0 : vec3<f32>,
    @location(2) mesh_pos_0 : vec3<f32>,
    @interpolate(flat) @location(6) slot_0 : u32,
};

struct Mesh_Varyings_0
{
     _S20 : vec3<f32>,
     _S21 : vec3<f32>,
     _S22 : f32,
     _S23 : vec4<f32>,
     _S24 : vec3<f32>,
     _S25 : vec3<f32>,
     _S26 : u32,
};

struct Mesh_Vertex_Out_1
{
     _S27 : vec4<f32>,
     v_5 : Mesh_Varyings_0,
};

@vertex
fn main(@builtin(vertex_index) id_0 : u32) -> Mesh_Vertex_Out_0
{
    var S_1 : u32 = Frame_Uniforms_0.skin_0.x;
    var V_1 : u32 = Frame_Uniforms_0.skin_0.y;
    var E_1 : u32 = Frame_Uniforms_0.skin_0.z;
    var per_0 : u32 = u32(3) * S_1 * S_1;
    var tri_1 : u32 = id_0 / per_0;
    var _S28 : u32 = id_0 - tri_1 * per_0;
    var small_0 : u32 = _S28 / u32(3);
    var c_1 : u32 = _S28 - u32(3) * small_0;
    var first_0 : u32 = u32(0);
    var j_1 : u32 = u32(0);
    for(;;)
    {
        var _S29 : u32 = u32(2) * (S_1 - j_1);
        if((first_0 + _S29 - u32(1)) <= small_0)
        {
        }
        else
        {
            break;
        }
        var _S30 : u32 = j_1 + u32(1);
        first_0 = first_0 + (_S29 - u32(1));
        j_1 = _S30;
    }
    var q_0 : u32 = small_0 - first_0;
    var i_1 : u32 = (q_0 >> (u32(1)));
    var gi_0 : u32;
    var gj_0 : u32;
    if(((q_0 & (u32(1)))) == u32(0))
    {
        if(c_1 == u32(1))
        {
            first_0 = u32(1);
        }
        else
        {
            first_0 = u32(0);
        }
        var _S31 : u32 = i_1 + first_0;
        if(c_1 == u32(2))
        {
            first_0 = u32(1);
        }
        else
        {
            first_0 = u32(0);
        }
        var _S32 : u32 = j_1 + first_0;
        gi_0 = _S31;
        gj_0 = _S32;
    }
    else
    {
        if(c_1 == u32(2))
        {
            first_0 = i_1;
        }
        else
        {
            first_0 = i_1 + u32(1);
        }
        if(c_1 == u32(0))
        {
        }
        else
        {
            j_1 = j_1 + u32(1);
        }
        gi_0 = first_0;
        gj_0 = j_1;
    }
    var _S33 : u32 = u32(3) * tri_1;
    var _S34 : u32 = indices_0[_S33];
    var _S35 : u32 = indices_0[_S33 + u32(1)];
    var _S36 : u32 = indices_0[_S33 + u32(2)];
    var v_6 : vec3<u32> = vec3<u32>(_S34, _S35, _S36);
    var rec_0 : vec4<u32> = skin_tris_0[tri_1];
    var _S37 : vec3<f32> = mesh_point_0(_S34);
    var _S38 : vec3<f32> = mesh_point_0(_S35);
    var _S39 : vec3<f32> = mesh_point_0(_S36);
    var P_0 : array<vec3<f32>, i32(3)> = array<vec3<f32>, i32(3)>( _S37, _S38, _S39 );
    var N_0 : array<vec3<f32>, i32(3)>;
    var M_0 : array<f32, i32(3)>;
    var _S40 : vec3<f32> = N_0[i32(0)];
    var _S41 : f32 = M_0[i32(0)];
    mesh_normal_mask_0(_S34, &(_S40), &(_S41));
    N_0[i32(0)] = _S40;
    M_0[i32(0)] = _S41;
    var _S42 : vec3<f32> = N_0[i32(1)];
    var _S43 : f32 = M_0[i32(1)];
    mesh_normal_mask_0(_S35, &(_S42), &(_S43));
    N_0[i32(1)] = _S42;
    M_0[i32(1)] = _S43;
    var _S44 : vec3<f32> = N_0[i32(2)];
    var _S45 : f32 = M_0[i32(2)];
    mesh_normal_mask_0(_S36, &(_S44), &(_S45));
    N_0[i32(2)] = _S44;
    M_0[i32(2)] = _S45;
    var fS_0 : f32 = f32(S_1);
    var _S46 : f32 = f32(gi_0);
    var _S47 : f32 = f32(gj_0);
    var _S48 : f32 = 1.0f - _S46 / fS_0 - _S47 / fS_0;
    var _S49 : f32 = _S46 / fS_0;
    var _S50 : f32 = _S47 / fS_0;
    var w_0 : vec3<f32> = vec3<f32>(_S48, _S49, _S50);
    var _S51 : vec3<f32> = vec3<f32>(0.0f);
    var _S52 : bool = gi_0 == u32(0);
    var _S53 : bool;
    if(_S52)
    {
        _S53 = gj_0 == u32(0);
    }
    else
    {
        _S53 = false;
    }
    var a_0 : u32;
    var k_1 : u32;
    var e_3 : u32;
    var nb_0 : vec3<f32>;
    var b_0 : vec3<f32>;
    if(_S53)
    {
        a_0 = u32(3);
        k_1 = u32(0);
        e_3 = u32(0);
        nb_0 = N_0[i32(0)];
        b_0 = _S37;
    }
    else
    {
        if(gi_0 == S_1)
        {
            a_0 = u32(3);
            k_1 = u32(0);
            e_3 = u32(0);
            nb_0 = N_0[i32(1)];
            b_0 = _S38;
        }
        else
        {
            if(gj_0 == S_1)
            {
                a_0 = u32(3);
                k_1 = u32(0);
                e_3 = u32(0);
                nb_0 = N_0[i32(2)];
                b_0 = _S39;
            }
            else
            {
                if(gj_0 == u32(0))
                {
                    var _S54 : u32 = rec_0.x;
                    a_0 = u32(0);
                    k_1 = gi_0;
                    e_3 = _S54;
                    nb_0 = _S51;
                    b_0 = _S51;
                }
                else
                {
                    if((gi_0 + gj_0) == S_1)
                    {
                        var _S55 : u32 = rec_0.y;
                        a_0 = u32(1);
                        k_1 = gj_0;
                        e_3 = _S55;
                        nb_0 = _S51;
                        b_0 = _S51;
                    }
                    else
                    {
                        if(_S52)
                        {
                            var _S56 : u32 = rec_0.z;
                            var _S57 : u32 = S_1 - gj_0;
                            a_0 = u32(2);
                            k_1 = _S57;
                            e_3 = _S56;
                            nb_0 = _S51;
                            b_0 = _S51;
                        }
                        else
                        {
                            var _S58 : vec3<f32> = vec3<f32>(_S48);
                            var _S59 : vec3<f32> = vec3<f32>(_S49);
                            var _S60 : vec3<f32> = vec3<f32>(_S50);
                            var _S61 : vec3<f32> = _S37 * _S58 + _S38 * _S59 + _S39 * _S60;
                            var _S62 : vec3<f32> = N_0[i32(0)] * _S58 + N_0[i32(1)] * _S59 + N_0[i32(2)] * _S60;
                            a_0 = u32(3);
                            k_1 = u32(0);
                            e_3 = u32(0);
                            nb_0 = _S62;
                            b_0 = _S61;
                        }
                    }
                }
            }
        }
    }
    var m_1 : u32;
    if(a_0 < u32(3))
    {
        var to_0 : u32 = (a_0 + u32(1)) % u32(3);
        var from_0 : u32;
        var to_1 : u32;
        if(((e_3 & (u32(1)))) == u32(1))
        {
            m_1 = S_1 - k_1;
            from_0 = to_0;
            to_1 = a_0;
        }
        else
        {
            m_1 = k_1;
            from_0 = a_0;
            to_1 = to_0;
        }
        var _S63 : vec3<f32> = vec3<f32>((f32(m_1) / fS_0));
        var _S64 : vec3<f32> = P_0[from_0] + (P_0[to_1] - P_0[from_0]) * _S63;
        nb_0 = N_0[from_0] + (N_0[to_1] - N_0[from_0]) * _S63;
        b_0 = _S64;
    }
    var nu_0 : vec3<f32> = normalize(nb_0);
    m_1 = u32(0);
    var curved_0 : vec3<f32> = _S51;
    for(;;)
    {
        if(m_1 < u32(3))
        {
        }
        else
        {
            break;
        }
        var curved_1 : vec3<f32> = curved_0 + (b_0 - N_0[m_1] * vec3<f32>(dot(b_0 - P_0[m_1], N_0[m_1]))) * vec3<f32>(w_0[m_1]);
        m_1 = m_1 + u32(1);
        curved_0 = curved_1;
    }
    var x_0 : u32 = skin_index_0(gi_0, gj_0, S_1, V_1, E_1, tri_1, v_6, rec_0.xyz);
    var in_position_0 : vec3<f32> = b_0 + nu_0 * vec3<f32>((dot(curved_0 - b_0, nu_0) + half_bits_0((((skin_heights_0[(x_0 >> (u32(1)))] >> ((u32(16) * ((x_0 & (u32(1)))))))) & (u32(65535))))));
    var in_normal_0 : vec3<f32> = octahedral_0(skin_normals_0[x_0]);
    var o_0 : Mesh_Vertex_Out_1;
    o_0.v_5._S22 = M_0[i32(0)] * _S48 + M_0[i32(1)] * _S49 + M_0[i32(2)] * _S50;
    var _S65 : u32 = ((rec_0.w) & (u32(3)));
    o_0.v_5._S23 = vec4<f32>(0.0f);
    o_0.v_5._S24 = vec3<f32>(-1.0f);
    o_0.v_5._S26 = u32(0);
    if((Frame_Uniforms_0.options_0.x) > 0.5f)
    {
        m_1 = u32(0);
        for(;;)
        {
            if(m_1 < u32(3))
            {
            }
            else
            {
                break;
            }
            var p_1 : vec4<f32> = unpack4x8unorm(paint_0[v_6[m_1]].x);
            o_0.v_5._S23 = o_0.v_5._S23 + vec4<f32>(srgb_decode_0(p_1.xyz), p_1.w) * vec4<f32>(w_0[m_1]);
            m_1 = m_1 + u32(1);
        }
    }
    if((Frame_Uniforms_0.options_0.y) > 0.5f)
    {
        _S53 = true;
    }
    else
    {
        _S53 = (Frame_Uniforms_0.options_0.z) > 0.5f;
    }
    if(_S53)
    {
        var group_1 : u32 = ((paint_0[v_6[_S65]].y) & (u32(65535)));
        if((Frame_Uniforms_0.options_0.y) > 0.5f)
        {
            o_0.v_5._S24 = group_color_0(group_1);
        }
        if((Frame_Uniforms_0.options_0.z) > 0.5f)
        {
            k_1 = u32(1);
            for(;;)
            {
                if(k_1 < u32(16))
                {
                }
                else
                {
                    break;
                }
                if((Frame_Uniforms_0.slot_group_0[(k_1 >> (u32(2)))][(k_1 & (u32(3)))]) == group_1)
                {
                    o_0.v_5._S26 = k_1;
                }
                k_1 = k_1 + u32(1);
            }
        }
    }
    var world_0 : vec4<f32> = (((mat4x4<f32>(Frame_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(in_position_0, 1.0f))));
    o_0._S27 = (((mat4x4<f32>(Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_proj_0.data_0[i32(3)][i32(3)])) * (world_0)));
    var _S66 : mat4x4<f32> = mat4x4<f32>(Frame_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.model_0.data_0[i32(3)][i32(3)]);
    var _S67 : mat4x4<f32> = mat4x4<f32>(Frame_Uniforms_0.view_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(3)]);
    o_0.v_5._S20 = ((((((mat3x3<f32>(_S67[i32(0)].xyz, _S67[i32(1)].xyz, _S67[i32(2)].xyz)) * (mat3x3<f32>(_S66[i32(0)].xyz, _S66[i32(1)].xyz, _S66[i32(2)].xyz))))) * (in_normal_0)));
    o_0.v_5._S21 = (((mat4x4<f32>(Frame_Uniforms_0.view_0.data_0[i32(0)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(0)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(1)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(2)][i32(3)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(0)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(1)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(2)], Frame_Uniforms_0.view_0.data_0[i32(3)][i32(3)])) * (world_0))).xyz;
    o_0.v_5._S25 = in_position_0;
    var _S68 : Mesh_Vertex_Out_0;
    _S68.position_0 = o_0._S27;
    _S68.view_normal_0 = o_0.v_5._S20;
    _S68.view_pos_0 = o_0.v_5._S21;
    _S68.mask_2 = o_0.v_5._S22;
    _S68.paint_1 = o_0.v_5._S23;
    _S68.group_0 = o_0.v_5._S24;
    _S68.mesh_pos_0 = o_0.v_5._S25;
    _S68.slot_0 = o_0.v_5._S26;
    return _S68;
}

