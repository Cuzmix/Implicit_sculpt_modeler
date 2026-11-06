// slangc wgsl from skin.frag.spv sha256 02577904d6dc283edf47043e4529dcc35b5e9e083e4c2383b969416dbc5f9b8e
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Material_Uniforms_std140_0
{
    @align(16) base_color_0 : vec4<f32>,
    @align(16) params_0 : vec4<f32>,
    @align(16) surface_0 : vec4<f32>,
    @align(16) checker_0 : vec4<f32>,
    @align(16) look_0 : vec4<f32>,
    @align(16) light_x_0 : vec4<f32>,
    @align(16) light_y_0 : vec4<f32>,
    @align(16) light_z_0 : vec4<f32>,
    @align(16) light_pos_0 : array<vec4<f32>, i32(8)>,
    @align(16) light_color_0 : array<vec4<f32>, i32(8)>,
    @align(16) light_spot_0 : array<vec4<f32>, i32(8)>,
    @align(16) light_shape_0 : array<vec4<f32>, i32(8)>,
    @align(16) light_axis_0 : array<vec4<f32>, i32(8)>,
    @align(16) light_extra_0 : array<vec4<f32>, i32(8)>,
    @align(16) maps_0 : vec4<f32>,
    @align(16) env_0 : vec4<f32>,
    @align(16) env_x_0 : vec4<f32>,
    @align(16) env_y_0 : vec4<f32>,
    @align(16) env_z_0 : vec4<f32>,
    @align(16) env_sh_0 : array<vec4<f32>, i32(9)>,
    @align(16) style_0 : vec4<f32>,
    @align(16) pass_0 : vec4<f32>,
    @align(16) fade_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Material_Uniforms_0 : SLANG_ParameterGroup_Material_Uniforms_std140_0;
struct SLANG_ParameterGroup_Slot_Uniforms_std140_0
{
    @align(16) slot_color_0 : array<vec4<f32>, i32(16)>,
    @align(16) slot_params_0 : array<vec4<f32>, i32(16)>,
    @align(16) slot_surface_0 : array<vec4<f32>, i32(16)>,
};

@binding(2) @group(3) var<uniform> Slot_Uniforms_0 : SLANG_ParameterGroup_Slot_Uniforms_std140_0;
@binding(6) @group(2) var<storage, read> skin_tris_0 : array<vec4<u32>>;

@binding(4) @group(2) var<storage, read> skin_normals_0 : array<u32>;

@binding(0) @group(2) var matcap_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var matcap_sampler_0 : sampler;

@binding(2) @group(2) var environment_map_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var environment_map_sampler_0 : sampler;

fn rsqrt_0( x_0 : f32) -> f32
{
    return 1.0f / sqrt(x_0);
}

struct Mesh_Varyings_0
{
     view_normal_0 : vec3<f32>,
     view_pos_0 : vec3<f32>,
     mask_0 : f32,
     paint_0 : vec4<f32>,
    group_0 : vec3<f32>,
     mesh_pos_0 : vec3<f32>,
    slot_0 : u32,
     bary_0 : vec3<f32>,
    skin_tri_0 : vec4<u32>,
    turn_x_0 : vec3<f32>,
    turn_y_0 : vec3<f32>,
    turn_z_0 : vec3<f32>,
    skin_meta_0 : vec4<u32>,
     material_0 : vec4<f32>,
};

var<private> frag_in_0 : Mesh_Varyings_0;

var<private> frag_coord_0 : vec4<f32>;

var<private> front_facing_0 : bool;

fn srgb_encode_0( c_0 : vec3<f32>) -> vec3<f32>
{
    var _S1 : vec3<f32> = clamp(c_0, vec3<f32>(0.0f), vec3<f32>(1.0f));
    return mix(vec3<f32>(12.92000007629394531f) * _S1, vec3<f32>(1.0549999475479126f) * pow(_S1, vec3<f32>(0.4166666567325592f)) - vec3<f32>(0.05499999970197678f), step(vec3<f32>(0.00313080009073019f), _S1));
}

fn paint_surface_0( surf_0 : vec2<f32>,  m_0 : vec4<f32>) -> vec2<f32>
{
    return vec2<f32>(mix(surf_0.x, m_0.z, m_0.w), max(mix(surf_0.y, m_0.x, m_0.y), 0.03999999910593033f));
}

fn skin_index_0( i_0 : u32,  j_0 : u32,  S_0 : u32,  V_0 : u32,  E_0 : u32,  tri_0 : u32,  v_0 : vec3<u32>,  e_0 : vec3<u32>) -> u32
{
    var _S2 : bool = i_0 == u32(0);
    var _S3 : bool;
    if(_S2)
    {
        _S3 = j_0 == u32(0);
    }
    else
    {
        _S3 = false;
    }
    if(_S3)
    {
        return v_0.x;
    }
    if(i_0 == S_0)
    {
        return v_0.y;
    }
    if(j_0 == S_0)
    {
        return v_0.z;
    }
    var ref_0 : u32;
    var k_0 : u32;
    if(j_0 == u32(0))
    {
        ref_0 = e_0.x;
        k_0 = i_0;
    }
    else
    {
        if((i_0 + j_0) == S_0)
        {
            ref_0 = e_0.y;
            k_0 = j_0;
        }
        else
        {
            var _S4 : u32 = u32(0);
            var _S5 : u32 = u32(0);
            if(_S2)
            {
                _S5 = e_0.z;
                _S4 = S_0 - j_0;
            }
            else
            {
                var _S6 : u32 = j_0 - u32(1);
                var _S7 : u32 = S_0 - u32(2);
                var _S8 : u32 = S_0 - u32(1);
                return V_0 + E_0 * _S8 + tri_0 * (_S8 * _S7 / u32(2)) + (_S6 * _S7 - _S6 * (j_0 - u32(2)) / u32(2)) + (i_0 - u32(1));
            }
            ref_0 = _S5;
            k_0 = _S4;
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

fn skin_grid_corners_0( S_1 : u32,  V_1 : u32,  E_1 : u32,  tri_1 : u32,  rec_0 : vec4<u32>,  gb_0 : vec3<f32>,  gv_0 : vec3<u32>,  x_1 : ptr<function, vec3<u32>>,  w_0 : ptr<function, vec3<f32>>)
{
    var lead_0 : u32 = ((rec_0.w) & (u32(3)));
    var b_0 : vec3<f32>;
    var v_1 : vec3<u32>;
    if(lead_0 == u32(1))
    {
        var _S9 : vec3<u32> = gv_0.zxy;
        b_0 = gb_0.zxy;
        v_1 = _S9;
    }
    else
    {
        if(lead_0 == u32(2))
        {
            var _S10 : vec3<u32> = gv_0.yzx;
            b_0 = gb_0.yzx;
            v_1 = _S10;
        }
        else
        {
            b_0 = gb_0;
            v_1 = gv_0;
        }
    }
    var fs_0 : f32 = f32(S_1);
    var u_0 : f32 = clamp(b_0.y, 0.0f, 1.0f) * fs_0;
    var t_0 : f32 = clamp(b_0.z, 0.0f, 1.0f) * fs_0;
    var _S11 : u32 = S_1 - u32(1);
    var _S12 : u32 = min(u32(u_0), _S11);
    var _S13 : u32 = min(u32(t_0), _S11);
    var i0_0 : u32;
    var j0_0 : u32;
    if((_S12 + _S13) > _S11)
    {
        if(u_0 > t_0)
        {
            i0_0 = _S11 - _S13;
            j0_0 = _S13;
        }
        else
        {
            var _S14 : u32 = _S11 - _S12;
            i0_0 = _S12;
            j0_0 = _S14;
        }
    }
    else
    {
        i0_0 = _S12;
        j0_0 = _S13;
    }
    var fu_0 : f32 = u_0 - f32(i0_0);
    var fw_0 : f32 = t_0 - f32(j0_0);
    var _S15 : f32 = fu_0 + fw_0;
    var _S16 : bool;
    if(_S15 <= 1.0f)
    {
        _S16 = true;
    }
    else
    {
        _S16 = (i0_0 + j0_0 + u32(1)) > _S11;
    }
    if(_S16)
    {
        var _S17 : vec3<u32> = rec_0.xyz;
        (*x_1) = vec3<u32>(skin_index_0(i0_0, j0_0, S_1, V_1, E_1, tri_1, v_1, _S17), skin_index_0(i0_0 + u32(1), j0_0, S_1, V_1, E_1, tri_1, v_1, _S17), skin_index_0(i0_0, j0_0 + u32(1), S_1, V_1, E_1, tri_1, v_1, _S17));
        (*w_0) = vec3<f32>(1.0f - fu_0 - fw_0, fu_0, fw_0);
    }
    else
    {
        var _S18 : u32 = i0_0 + u32(1);
        var _S19 : u32 = j0_0 + u32(1);
        var _S20 : vec3<u32> = rec_0.xyz;
        (*x_1) = vec3<u32>(skin_index_0(_S18, _S19, S_1, V_1, E_1, tri_1, v_1, _S20), skin_index_0(i0_0, _S19, S_1, V_1, E_1, tri_1, v_1, _S20), skin_index_0(_S18, j0_0, S_1, V_1, E_1, tri_1, v_1, _S20));
        (*w_0) = vec3<f32>(_S15 - 1.0f, 1.0f - fu_0, 1.0f - fw_0);
    }
    return;
}

fn oct_decode_0( e_1 : vec2<f32>) -> vec3<f32>
{
    var _S21 : f32 = e_1.x;
    var _S22 : f32 = e_1.y;
    var _S23 : vec3<f32> = vec3<f32>(e_1, 1.0f - abs(_S21) - abs(_S22));
    var v_2 : vec3<f32> = _S23;
    if((_S23.z) < 0.0f)
    {
        var _S24 : vec2<f32> = vec2<f32>(1.0f) - abs(e_1.yx);
        var _S25 : f32;
        if(_S21 >= 0.0f)
        {
            _S25 = 1.0f;
        }
        else
        {
            _S25 = -1.0f;
        }
        var _S26 : f32;
        if(_S22 >= 0.0f)
        {
            _S26 = 1.0f;
        }
        else
        {
            _S26 = -1.0f;
        }
        var _S27 : vec2<f32> = _S24 * vec2<f32>(_S25, _S26);
        v_2.x = _S27.x;
        v_2.y = _S27.y;
    }
    return normalize(v_2);
}

fn skin_normal_at_0( x_2 : u32) -> vec3<f32>
{
    var p_0 : u32 = skin_normals_0[x_2];
    return oct_decode_0(max(vec2<f32>(vec2<i32>((i32((p_0 << (u32(16)))) >> (u32(16))), (i32(p_0) >> (u32(16))))) / vec2<f32>(32767.0f), vec2<f32>(-1.0f)));
}

fn skin_view_normal_0() -> vec3<f32>
{
    var tri_2 : u32 = frag_in_0.skin_tri_0.x;
    var x_3 : vec3<u32>;
    var w_1 : vec3<f32>;
    skin_grid_corners_0(frag_in_0.skin_meta_0.x, frag_in_0.skin_meta_0.y, frag_in_0.skin_meta_0.z, tri_2, skin_tris_0[tri_2], frag_in_0.bary_0, frag_in_0.skin_tri_0.yzw, &(x_3), &(w_1));
    var n_0 : vec3<f32> = skin_normal_at_0(x_3.x) * vec3<f32>(w_1.x) + skin_normal_at_0(x_3.y) * vec3<f32>(w_1.y) + skin_normal_at_0(x_3.z) * vec3<f32>(w_1.z);
    return vec3<f32>(n_0.x) * frag_in_0.turn_x_0 + vec3<f32>(n_0.y) * frag_in_0.turn_y_0 + vec3<f32>(n_0.z) * frag_in_0.turn_z_0;
}

fn curvature_0( n_1 : vec3<f32>,  p_1 : vec3<f32>) -> f32
{
    var dpx_0 : vec3<f32> = dpdx(p_1);
    var dpy_0 : vec3<f32> = dpdy(p_1);
    var dnx_0 : vec3<f32> = dpdx(n_1);
    var dny_0 : vec3<f32> = dpdy(n_1);
    var lx_0 : f32 = length(dpx_0);
    var ly_0 : f32 = length(dpy_0);
    var c_1 : f32;
    if(lx_0 > 0.0f)
    {
        c_1 = dot(dnx_0, dpx_0) / lx_0;
    }
    else
    {
        c_1 = 0.0f;
    }
    if(ly_0 > 0.0f)
    {
        c_1 = c_1 + dot(dny_0, dpy_0) / ly_0;
    }
    return c_1;
}

fn skin_detail_color_0( n_2 : vec3<f32>,  v_3 : vec3<f32>) -> vec3<f32>
{
    var flat_n_0 : vec3<f32> = normalize(frag_in_0.view_normal_0);
    var flat_n_1 : vec3<f32>;
    if(!front_facing_0)
    {
        flat_n_1 = (vec3<f32>(0) - flat_n_0);
    }
    else
    {
        flat_n_1 = flat_n_0;
    }
    var m_1 : vec3<f32> = normalize(vec3<f32>(dot(flat_n_1, frag_in_0.turn_x_0), dot(flat_n_1, frag_in_0.turn_y_0), dot(flat_n_1, frag_in_0.turn_z_0)));
    var s_0 : vec3<f32> = normalize(vec3<f32>(dot(n_2, frag_in_0.turn_x_0), dot(n_2, frag_in_0.turn_y_0), dot(n_2, frag_in_0.turn_z_0)));
    var ref_1 : vec3<f32>;
    if((abs(m_1.y)) < 0.99000000953674316f)
    {
        ref_1 = vec3<f32>(0.0f, 1.0f, 0.0f);
    }
    else
    {
        ref_1 = vec3<f32>(1.0f, 0.0f, 0.0f);
    }
    var t_1 : vec3<f32> = normalize(cross(ref_1, m_1));
    var _S28 : vec3<f32> = vec3<f32>(0.5f);
    var rgb_0 : vec3<f32> = vec3<f32>(clamp(2.0f * dot(s_0, t_1), -1.0f, 1.0f), clamp(2.0f * dot(s_0, cross(m_1, t_1)), -1.0f, 1.0f), dot(s_0, m_1)) * _S28 + _S28;
    var heat_0 : u32 = ((skin_tris_0[frag_in_0.skin_tri_0.x].w) >> (u32(16)));
    var rgb_1 : vec3<f32>;
    if(heat_0 > u32(0))
    {
        var h_0 : f32 = f32(heat_0 - u32(1)) / 65534.0f;
        if(h_0 < 0.5f)
        {
            rgb_1 = mix(vec3<f32>(0.15000000596046448f, 0.75f, 0.25f), vec3<f32>(0.94999998807907104f, 0.85000002384185791f, 0.20000000298023224f), vec3<f32>((h_0 * 2.0f)));
        }
        else
        {
            rgb_1 = mix(vec3<f32>(0.94999998807907104f, 0.85000002384185791f, 0.20000000298023224f), vec3<f32>(0.89999997615814209f, 0.15000000596046448f, 0.10000000149011612f), vec3<f32>((h_0 * 2.0f - 1.0f)));
        }
        rgb_1 = mix(rgb_0, rgb_1, vec3<f32>(0.69999998807907104f));
    }
    else
    {
        rgb_1 = rgb_0;
    }
    return rgb_1 * vec3<f32>((0.69999998807907104f + 0.30000001192092896f * clamp(dot(flat_n_1, v_3), 0.0f, 1.0f)));
}

fn opacity_0() -> f32
{
    var _S29 : f32;
    if((Material_Uniforms_0.look_0.w) > 0.0f)
    {
        _S29 = Material_Uniforms_0.look_0.w;
    }
    else
    {
        _S29 = 1.0f;
    }
    return _S29;
}

fn glsl_mod_0( x_4 : f32,  y_0 : f32) -> f32
{
    return x_4 - y_0 * floor(x_4 / y_0);
}

fn light_at_0( i_1 : i32,  l_0 : ptr<function, vec3<f32>>,  spread_0 : ptr<function, f32>) -> f32
{
    var p_2 : vec4<f32> = Material_Uniforms_0.light_pos_0[i_1];
    var shape_0 : vec4<f32> = Material_Uniforms_0.light_shape_0[i_1];
    var _S30 : f32 = Material_Uniforms_0.light_pos_0[i_1].w;
    if(_S30 < 0.5f)
    {
        (*l_0) = p_2.xyz;
        (*spread_0) = shape_0.w;
        return 1.0f;
    }
    var d_0 : vec3<f32> = p_2.xyz - frag_in_0.view_pos_0;
    var _S31 : f32 = max(dot(d_0, d_0), 9.99999993922529029e-09f);
    var inv_0 : f32 = rsqrt_0(_S31);
    (*l_0) = d_0 * vec3<f32>(inv_0);
    (*spread_0) = min(shape_0.w * inv_0, 1.0f);
    var _S32 : f32 = shape_0.x;
    var k_1 : f32 = _S32 * _S32 / _S31;
    var _S33 : f32 = shape_0.y;
    var k_2 : f32;
    if(_S33 > 0.0f)
    {
        var x_5 : f32 = _S31 / (_S33 * _S33);
        var w_2 : f32 = clamp(1.0f - x_5 * x_5, 0.0f, 1.0f);
        k_2 = k_1 * (w_2 * w_2);
    }
    else
    {
        k_2 = k_1;
    }
    if(_S30 > 1.5f)
    {
        k_2 = k_2 * smoothstep(Material_Uniforms_0.light_spot_0[i_1].w, shape_0.z, dot((vec3<f32>(0) - (*l_0)), Material_Uniforms_0.light_spot_0[i_1].xyz));
    }
    return k_2;
}

fn nearest_in_light_0( l_1 : vec3<f32>,  r_0 : vec3<f32>,  spread_1 : f32) -> vec3<f32>
{
    var cos_r_0 : f32 = sqrt(max(1.0f - spread_1 * spread_1, 0.0f));
    var l_dot_r_0 : f32 = dot(l_1, r_0);
    if(l_dot_r_0 >= cos_r_0)
    {
        return r_0;
    }
    var s_1 : vec3<f32> = r_0 - vec3<f32>(l_dot_r_0) * l_1;
    var s2_0 : f32 = dot(s_1, s_1);
    if(s2_0 < 9.999999960041972e-13f)
    {
        return l_1;
    }
    return normalize(l_1 * vec3<f32>(cos_r_0) + s_1 * vec3<f32>((rsqrt_0(s2_0) * spread_1)));
}

fn widened_0( a_0 : f32,  spread_2 : f32) -> f32
{
    var _S34 : f32 = min(a_0 + 0.5f * spread_2, 1.0f);
    return a_0 * a_0 / (_S34 * _S34);
}

fn direct_sized_0( n_3 : vec3<f32>,  v_4 : vec3<f32>,  l_2 : vec3<f32>,  ls_0 : vec3<f32>,  spread_3 : f32,  diffuse_0 : vec3<f32>,  f0_0 : vec3<f32>,  a_1 : f32,  shine_0 : f32) -> vec3<f32>
{
    var color_0 : vec3<f32> = diffuse_0 / vec3<f32>(3.14159274101257324f) * vec3<f32>(max(dot(n_3, l_2), 0.0f));
    var _S35 : f32 = max(dot(n_3, ls_0), 0.0f);
    if(_S35 <= 0.0f)
    {
        return color_0;
    }
    var h_1 : vec3<f32> = normalize(ls_0 + v_4);
    var _S36 : f32 = max(dot(n_3, v_4), 0.00009999999747379f);
    var _S37 : f32 = max(dot(n_3, h_1), 0.0f);
    var a2_0 : f32 = a_1 * a_1;
    var d_1 : f32 = _S37 * _S37 * (a2_0 - 1.0f) + 1.0f;
    return color_0 + vec3<f32>((a2_0 / (3.14159274101257324f * d_1 * d_1) * widened_0(a_1, spread_3) * (0.5f / max(mix(2.0f * _S35 * _S36, _S35 + _S36, a_1), 0.00009999999747379f)))) * (f0_0 + (vec3<f32>(1.0f) - f0_0) * vec3<f32>(pow(1.0f - max(dot(v_4, h_1), 0.0f), 5.0f))) * vec3<f32>(_S35) * vec3<f32>(shine_0);
}

fn direct_0( n_4 : vec3<f32>,  v_5 : vec3<f32>,  l_3 : vec3<f32>,  diffuse_1 : vec3<f32>,  f0_1 : vec3<f32>,  a_2 : f32,  shine_1 : f32) -> vec3<f32>
{
    var _S38 : f32 = max(dot(n_4, l_3), 0.0f);
    if(_S38 <= 0.0f)
    {
        return vec3<f32>(0.0f);
    }
    var h_2 : vec3<f32> = normalize(l_3 + v_5);
    var _S39 : f32 = max(dot(n_4, v_5), 0.00009999999747379f);
    var _S40 : f32 = max(dot(n_4, h_2), 0.0f);
    var a2_1 : f32 = a_2 * a_2;
    var d_2 : f32 = _S40 * _S40 * (a2_1 - 1.0f) + 1.0f;
    return (diffuse_1 / vec3<f32>(3.14159274101257324f) + vec3<f32>((a2_1 / (3.14159274101257324f * d_2 * d_2) * (0.5f / max(mix(2.0f * _S38 * _S39, _S38 + _S39, a_2), 0.00009999999747379f)))) * (f0_1 + (vec3<f32>(1.0f) - f0_1) * vec3<f32>(pow(1.0f - max(dot(v_5, h_2), 0.0f), 5.0f))) * vec3<f32>(shine_1)) * vec3<f32>(_S38);
}

fn env_brdf_0( n_dot_v_0 : f32,  rough_0 : f32) -> vec2<f32>
{
    var r_1 : vec4<f32> = vec4<f32>(rough_0) * vec4<f32>(-1.0f, -0.02749999985098839f, -0.57200002670288086f, 0.02199999988079071f) + vec4<f32>(1.0f, 0.04250000044703484f, 1.03999996185302734f, -0.03999999910593033f);
    var _S41 : f32 = r_1.x;
    return vec2<f32>(-1.03999996185302734f, 1.03999996185302734f) * vec2<f32>((min(_S41 * _S41, exp2(-9.27999973297119141f * n_dot_v_0)) * _S41 + r_1.y)) + r_1.zw;
}

fn irradiance_0( n_5 : vec3<f32>) -> vec3<f32>
{
    var d_3 : vec3<f32> = (((transpose(mat3x3<f32>(Material_Uniforms_0.env_x_0.xyz, Material_Uniforms_0.env_y_0.xyz, Material_Uniforms_0.env_z_0.xyz))) * (n_5)));
    var _S42 : f32 = d_3.y;
    var _S43 : f32 = d_3.z;
    var _S44 : f32 = d_3.x;
    var _S45 : f32 = 1.09254801273345947f * _S44;
    return max(Material_Uniforms_0.env_sh_0[i32(0)].xyz * vec3<f32>(0.28209498524665833f) + Material_Uniforms_0.env_sh_0[i32(1)].xyz * vec3<f32>((0.48860299587249756f * _S42)) + Material_Uniforms_0.env_sh_0[i32(2)].xyz * vec3<f32>((0.48860299587249756f * _S43)) + Material_Uniforms_0.env_sh_0[i32(3)].xyz * vec3<f32>((0.48860299587249756f * _S44)) + Material_Uniforms_0.env_sh_0[i32(4)].xyz * vec3<f32>((_S45 * _S42)) + Material_Uniforms_0.env_sh_0[i32(5)].xyz * vec3<f32>((1.09254801273345947f * _S42 * _S43)) + Material_Uniforms_0.env_sh_0[i32(6)].xyz * vec3<f32>((0.31539198756217957f * (3.0f * _S43 * _S43 - 1.0f))) + Material_Uniforms_0.env_sh_0[i32(7)].xyz * vec3<f32>((_S45 * _S43)) + Material_Uniforms_0.env_sh_0[i32(8)].xyz * vec3<f32>((0.54627400636672974f * (_S44 * _S44 - _S42 * _S42))), vec3<f32>(0.0f)) * vec3<f32>(Material_Uniforms_0.env_0.y);
}

fn lobe_0( dir_0 : vec3<f32>,  toward_0 : vec3<f32>,  color_1 : vec3<f32>,  sharp_0 : f32,  rough_1 : f32) -> vec3<f32>
{
    var e_2 : f32 = mix(sharp_0, 3.0f, sqrt(rough_1));
    return color_1 * vec3<f32>(pow(max(dot(dir_0, toward_0), 0.0f), e_2)) * vec3<f32>((e_2 + 2.0f)) / vec3<f32>((sharp_0 + 2.0f));
}

fn studio_0( dir_1 : vec3<f32>,  rough_2 : f32) -> vec3<f32>
{
    var w_3 : f32 = 0.07999999821186066f + 0.89999997615814209f * rough_2;
    var _S46 : f32 = dir_1.y;
    return mix(vec3<f32>(0.07000000029802322f, 0.06499999761581421f, 0.05999999865889549f), vec3<f32>(0.40000000596046448f, 0.43000000715255737f, 0.47999998927116394f), vec3<f32>(smoothstep(- w_3, w_3, _S46))) + vec3<f32>(0.12999999523162842f, 0.11999999731779099f, 0.10999999940395355f) * vec3<f32>(exp(- abs(_S46) / (0.05999999865889549f + 0.5f * rough_2))) + lobe_0(dir_1, vec3<f32>(-0.65590423345565796f, 0.7433580756187439f, 0.13118083775043488f), vec3<f32>(4.0f, 3.79999995231628418f, 3.5f), 300.0f, rough_2) + lobe_0(dir_1, vec3<f32>(0.84478187561035156f, 0.32852628827095032f, -0.42239093780517578f), vec3<f32>(1.60000002384185791f, 1.79999995231628418f, 2.09999990463256836f), 600.0f, rough_2) + lobe_0(dir_1, vec3<f32>(0.09396819770336151f, -0.32888868451118469f, 0.93968194723129272f), vec3<f32>(0.5f, 0.5f, 0.5f), 4.0f, rough_2);
}

fn sky_facing_0( n_6 : vec3<f32>,  rig_0 : mat3x3<f32>) -> f32
{
    return 0.5f + 0.5f * dot(n_6, rig_0[i32(1)]);
}

fn underside_0( n_7 : vec3<f32>,  rig_1 : mat3x3<f32>) -> f32
{
    return mix(Material_Uniforms_0.style_0.y, 1.0f, sky_facing_0(n_7, rig_1));
}

fn panorama_uv_0( d_4 : vec3<f32>) -> vec2<f32>
{
    return vec2<f32>(atan2(d_4.x, - d_4.z - 9.99999968265522539e-21f) * 0.15915493667125702f + 0.5f, acos(clamp(d_4.y, -1.0f, 1.0f)) * 0.31830990314483643f);
}

fn reflected_0( dir_2 : vec3<f32>,  rough_3 : f32,  to_rig_0 : mat3x3<f32>) -> vec3<f32>
{
    if((Material_Uniforms_0.env_0.x) > 0.5f)
    {
        return (textureSampleLevel((environment_map_texture_0), (environment_map_sampler_0), (panorama_uv_0((((transpose(mat3x3<f32>(Material_Uniforms_0.env_x_0.xyz, Material_Uniforms_0.env_y_0.xyz, Material_Uniforms_0.env_z_0.xyz))) * (dir_2))))), (rough_3 * Material_Uniforms_0.env_0.z))).xyz * vec3<f32>(Material_Uniforms_0.env_0.y);
    }
    return studio_0((((to_rig_0) * (dir_2))), rough_3);
}

fn tone_map_0( c_2 : vec3<f32>) -> vec3<f32>
{
    var _S47 : f32 = min(c_2.x, min(c_2.y, c_2.z));
    var offset_0 : f32;
    if(_S47 < 0.07999999821186066f)
    {
        offset_0 = _S47 - 6.25f * _S47 * _S47;
    }
    else
    {
        offset_0 = 0.03999999910593033f;
    }
    var _S48 : vec3<f32> = c_2 - vec3<f32>(offset_0);
    var _S49 : f32 = max(_S48.x, max(_S48.y, _S48.z));
    if(_S49 < 0.75999999046325684f)
    {
        return _S48;
    }
    var new_peak_0 : f32 = 1.0f - 0.0576000027358532f / (_S49 + 0.24000000953674316f - 0.75999999046325684f);
    return mix(_S48 * vec3<f32>((new_peak_0 / _S49)), vec3<f32>(new_peak_0), vec3<f32>((1.0f - 1.0f / (0.15000000596046448f * (_S49 - new_peak_0) + 1.0f))));
}

fn display_color_0( c_3 : vec3<f32>,  stops_0 : f32) -> vec3<f32>
{
    return srgb_encode_0(tone_map_0(c_3 * vec3<f32>(exp2(stops_0))));
}

fn display_0( c_4 : vec3<f32>) -> vec4<f32>
{
    return vec4<f32>(display_color_0(c_4, Material_Uniforms_0.look_0.x), opacity_0());
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

struct pixelInput_0
{
    @location(0) view_normal_1 : vec3<f32>,
    @location(1) view_pos_1 : vec3<f32>,
    @location(3) mask_1 : f32,
    @location(4) paint_1 : vec4<f32>,
    @interpolate(flat) @location(5) group_1 : vec3<f32>,
    @location(2) mesh_pos_1 : vec3<f32>,
    @interpolate(flat) @location(6) slot_1 : u32,
    @location(7) bary_1 : vec3<f32>,
    @interpolate(flat) @location(8) skin_tri_1 : vec4<u32>,
    @interpolate(flat) @location(9) turn_x_1 : vec3<f32>,
    @interpolate(flat) @location(10) turn_y_1 : vec3<f32>,
    @interpolate(flat) @location(11) turn_z_1 : vec3<f32>,
    @interpolate(flat) @location(12) skin_meta_1 : vec4<u32>,
    @location(13) material_1 : vec4<f32>,
};

@fragment
fn main( _S50 : pixelInput_0, @builtin(position) position_0 : vec4<f32>, @builtin(front_facing) is_front_0 : bool) -> pixelOutput_0
{
    frag_in_0.view_normal_0 = _S50.view_normal_1;
    frag_in_0.view_pos_0 = _S50.view_pos_1;
    frag_in_0.mask_0 = _S50.mask_1;
    frag_in_0.paint_0 = _S50.paint_1;
    frag_in_0.group_0 = _S50.group_1;
    frag_in_0.mesh_pos_0 = _S50.mesh_pos_1;
    frag_in_0.slot_0 = _S50.slot_1;
    frag_in_0.bary_0 = _S50.bary_1;
    frag_in_0.skin_tri_0 = _S50.skin_tri_1;
    frag_in_0.turn_x_0 = _S50.turn_x_1;
    frag_in_0.turn_y_0 = _S50.turn_y_1;
    frag_in_0.turn_z_0 = _S50.turn_z_1;
    frag_in_0.skin_meta_0 = _S50.skin_meta_1;
    frag_in_0.material_0 = _S50.material_1;
    frag_coord_0 = position_0;
    front_facing_0 = is_front_0;
    if((Material_Uniforms_0.params_0.y) < 0.0f)
    {
        var _S51 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0(Material_Uniforms_0.base_color_0.xyz), 1.0f) );
        return _S51;
    }
    var _S52 : vec4<f32> = Material_Uniforms_0.base_color_0;
    var _S53 : vec4<f32> = Material_Uniforms_0.params_0;
    var surf_1 : vec4<f32> = Material_Uniforms_0.surface_0;
    var base_0 : vec4<f32>;
    var shading_0 : vec4<f32>;
    if((frag_in_0.slot_0) > u32(0))
    {
        var _S54 : vec2<f32> = Slot_Uniforms_0.slot_surface_0[frag_in_0.slot_0].xy;
        surf_1.x = _S54.x;
        surf_1.y = _S54.y;
        surf_1[i32(3)] = 0.0f;
        base_0 = Slot_Uniforms_0.slot_color_0[frag_in_0.slot_0];
        shading_0 = Slot_Uniforms_0.slot_params_0[frag_in_0.slot_0];
    }
    else
    {
        base_0 = _S52;
        shading_0 = _S53;
    }
    if((surf_1.y) > 0.0f)
    {
        var _S55 : vec2<f32> = paint_surface_0(surf_1.xy, frag_in_0.material_0);
        surf_1.x = _S55.x;
        surf_1.y = _S55.y;
    }
    var v_6 : vec3<f32>;
    if((Material_Uniforms_0.env_0.w) > 0.5f)
    {
        v_6 = vec3<f32>(0.0f, 0.0f, 1.0f);
    }
    else
    {
        v_6 = normalize((vec3<f32>(0) - frag_in_0.view_pos_0));
    }
    var n_8 : vec3<f32> = normalize(skin_view_normal_0());
    var n_9 : vec3<f32>;
    if(!front_facing_0)
    {
        n_9 = (vec3<f32>(0) - n_8);
    }
    else
    {
        n_9 = n_8;
    }
    var dndx_0 : vec3<f32> = dpdx(n_9);
    var dndy_0 : vec3<f32> = dpdy(n_9);
    var bend_0 : f32 = curvature_0(n_9, frag_in_0.view_pos_0);
    var _S56 : i32 = i32(Material_Uniforms_0.pass_0.x + 0.5f);
    var view_pass_0 : i32;
    if((Material_Uniforms_0.pass_0.w) > 0.5f)
    {
        var wipe_0 : f32 = Material_Uniforms_0.pass_0.w - 1.0f;
        var line_px_0 : f32 = floor(wipe_0 / 16.0f);
        if((frag_coord_0.x) >= line_px_0)
        {
            view_pass_0 = i32(wipe_0 - line_px_0 * 16.0f + 0.5f);
        }
        else
        {
            view_pass_0 = _S56;
        }
    }
    else
    {
        view_pass_0 = _S56;
    }
    var _S57 : bool;
    if(view_pass_0 != i32(0))
    {
        _S57 = view_pass_0 != i32(7);
    }
    else
    {
        _S57 = false;
    }
    var shown_0 : vec3<f32>;
    var k_3 : f32;
    if(_S57)
    {
        if(view_pass_0 == i32(1))
        {
            var _S58 : vec3<f32> = vec3<f32>(0.5f);
            shown_0 = n_9 * _S58 + _S58;
        }
        else
        {
            if(view_pass_0 == i32(2))
            {
                shown_0 = vec3<f32>((1.0f - clamp((- frag_in_0.view_pos_0.z - Material_Uniforms_0.pass_0.y) / max(Material_Uniforms_0.pass_0.z - Material_Uniforms_0.pass_0.y, 9.99999997475242708e-07f), 0.0f, 1.0f)));
            }
            else
            {
                if(view_pass_0 == i32(3))
                {
                    var k_4 : f32 = clamp(bend_0 / 0.11999999731779099f, -1.0f, 1.0f);
                    if(k_4 > 0.0f)
                    {
                        k_3 = k_4 * smoothstep(0.10000000149011612f, 0.40000000596046448f, max(dot(n_9, v_6), 0.0f));
                    }
                    else
                    {
                        k_3 = k_4;
                    }
                    var _S59 : vec3<f32> = vec3<f32>(0.5f);
                    if(k_3 < 0.0f)
                    {
                        v_6 = vec3<f32>(0.15000000596046448f, 0.34999999403953552f, 0.85000002384185791f);
                    }
                    else
                    {
                        v_6 = vec3<f32>(0.94999998807907104f, 0.55000001192092896f, 0.15000000596046448f);
                    }
                    shown_0 = mix(_S59, v_6, vec3<f32>(abs(k_3)));
                }
                else
                {
                    if(view_pass_0 == i32(4))
                    {
                        shown_0 = vec3<f32>(0.85000002384185791f);
                    }
                    else
                    {
                        if(view_pass_0 == i32(6))
                        {
                            shown_0 = skin_detail_color_0(n_9, v_6);
                        }
                        else
                        {
                            shown_0 = vec3<f32>(0.05999999865889549f);
                        }
                    }
                }
            }
        }
        var _S60 : pixelOutput_0 = pixelOutput_0( vec4<f32>(shown_0, opacity_0()) );
        return _S60;
    }
    var _S61 : f32 = dot(n_9, v_6);
    var _S62 : f32 = max(_S61, 0.0f);
    var relief_0 : f32 = (1.0f - 0.75f * (Material_Uniforms_0.look_0.y * smoothstep(0.00999999977648258f, 0.11999999731779099f, - bend_0))) * (1.0f + 0.60000002384185791f * (Material_Uniforms_0.look_0.z * smoothstep(0.00999999977648258f, 0.11999999731779099f, bend_0) * smoothstep(0.10000000149011612f, 0.40000000596046448f, _S62)));
    var _S63 : vec3<f32> = mix(base_0.xyz, frag_in_0.paint_0.xyz, vec3<f32>(frag_in_0.paint_0.w));
    if((frag_in_0.group_0.x) >= 0.0f)
    {
        shown_0 = frag_in_0.group_0;
    }
    else
    {
        shown_0 = _S63;
    }
    if((Material_Uniforms_0.fade_0.w) > 0.0f)
    {
        _S57 = (frag_in_0.group_0.x) < 0.0f;
    }
    else
    {
        _S57 = false;
    }
    if(_S57)
    {
        shown_0 = mix(shown_0, Material_Uniforms_0.fade_0.xyz, vec3<f32>(Material_Uniforms_0.fade_0.w));
    }
    if((Material_Uniforms_0.checker_0.w) > 0.0f)
    {
        var c_5 : vec3<f32> = (frag_in_0.mesh_pos_0 - Material_Uniforms_0.checker_0.xyz) / vec3<f32>(Material_Uniforms_0.checker_0.w);
        var width_0 : vec3<f32> = max((fwidth((c_5))), vec3<f32>(9.99999997475242708e-07f));
        var _S64 : f32 = max(max(width_0.x, width_0.y), width_0.z);
        var f_0 : vec3<f32> = fract(c_5);
        var edge_0 : vec3<f32> = min(f_0, vec3<f32>(1.0f) - f_0) / width_0;
        var cell_0 : vec3<f32> = floor(c_5);
        shown_0 = shown_0 * vec3<f32>(mix(mix(1.0f, 0.72000002861022949f, glsl_mod_0(cell_0.x + cell_0.y + cell_0.z, 2.0f)) * (1.0f - 0.34999999403953552f * ((1.0f - smoothstep(0.5f, 1.5f, min(min(edge_0.x, edge_0.y), edge_0.z))) * (1.0f - smoothstep(0.0625f, 0.125f, _S64)))), 0.86000001430511475f, smoothstep(0.20000000298023224f, 0.40000000596046448f, _S64)));
    }
    var rig_2 : mat3x3<f32> = mat3x3<f32>(Material_Uniforms_0.light_x_0.xyz, Material_Uniforms_0.light_y_0.xyz, Material_Uniforms_0.light_z_0.xyz);
    var ambient_0 : f32 = Material_Uniforms_0.light_x_0.w;
    var shown_mask_0 : f32 = frag_in_0.mask_0 * (1.0f - Material_Uniforms_0.style_0.z);
    var albedo_0 : vec3<f32> = shown_0 * vec3<f32>((1.0f - 0.69999998807907104f * shown_mask_0));
    var highlight_0 : f32 = 1.0f - 0.5f * shown_mask_0;
    if(view_pass_0 == i32(7))
    {
        var _S65 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0(albedo_0 * vec3<f32>(relief_0) * vec3<f32>(exp2(Material_Uniforms_0.look_0.x))), opacity_0()) );
        return _S65;
    }
    if((surf_1.w) > 0.5f)
    {
        var k_5 : f32 = 1.0f / (1.0f + v_6.z);
        var _S66 : f32 = v_6.x;
        var _S67 : f32 = - _S66;
        var _S68 : f32 = v_6.y;
        var b_1 : f32 = _S67 * _S68 * k_5;
        var _S69 : vec2<f32> = vec2<f32>(0.5f + 0.49599999189376831f * dot(vec3<f32>(1.0f - _S66 * _S66 * k_5, b_1, _S67), n_9), 0.5f - 0.49599999189376831f * dot(vec3<f32>(b_1, 1.0f - _S68 * _S68 * k_5, - _S68), n_9));
        ;
        var _S70 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0((textureSample((matcap_texture_0), (matcap_sampler_0), (_S69))).xyz * albedo_0 * vec3<f32>(relief_0) * vec3<f32>(exp2(Material_Uniforms_0.look_0.x))), opacity_0()) );
        return _S70;
    }
    var color_2 : vec3<f32>;
    var lit_0 : vec3<f32>;
    var i_2 : i32;
    if((surf_1.y) > 0.0f)
    {
        var metallic_0 : f32 = clamp(surf_1.x, 0.0f, 1.0f);
        var a_3 : f32 = surf_1.y * surf_1.y;
        var rough_4 : f32 = clamp(sqrt(sqrt(clamp(a_3 * a_3 + min(2.0f * (0.25f * (dot(dndx_0, dndx_0) + dot(dndy_0, dndy_0))), 0.18000000715255737f), 0.0f, 1.0f))), 0.03999999910593033f, 1.0f);
        var _S71 : f32 = rough_4 * rough_4;
        var diffuse_2 : vec3<f32> = albedo_0 * vec3<f32>((1.0f - metallic_0));
        var f0_2 : vec3<f32> = mix(vec3<f32>(0.03999999910593033f), albedo_0, vec3<f32>(metallic_0));
        var _S72 : f32 = max(_S61, 0.00009999999747379f);
        var r_2 : vec3<f32> = reflect((vec3<f32>(0) - v_6), n_9);
        var _S73 : vec3<f32> = vec3<f32>(0.0f);
        i_2 = i32(0);
        color_2 = _S73;
        for(;;)
        {
            if(i_2 < i32(8))
            {
            }
            else
            {
                break;
            }
            var s_2 : f32 = Material_Uniforms_0.light_color_0[i_2].w;
            if(s_2 <= 0.0f)
            {
                _S57 = true;
            }
            else
            {
                _S57 = (Material_Uniforms_0.light_pos_0[i_2].w) > 2.5f;
            }
            if(_S57)
            {
                i_2 = i_2 + i32(1);
                continue;
            }
            var l_4 : vec3<f32>;
            var spread_4 : f32;
            var k_6 : f32 = light_at_0(i_2, &(l_4), &(spread_4));
            if(k_6 <= 0.0f)
            {
                i_2 = i_2 + i32(1);
                continue;
            }
            var shine_2 : f32 = 1.0f + Material_Uniforms_0.light_extra_0[i_2].x;
            if(spread_4 > 0.0f)
            {
                lit_0 = direct_sized_0(n_9, v_6, l_4, nearest_in_light_0(l_4, r_2, spread_4), spread_4, diffuse_2, f0_2, _S71, shine_2);
            }
            else
            {
                lit_0 = direct_0(n_9, v_6, l_4, diffuse_2, f0_2, _S71, shine_2);
            }
            color_2 = color_2 + lit_0 * Material_Uniforms_0.light_color_0[i_2].xyz * vec3<f32>((3.0f * (s_2 * k_6)));
            i_2 = i_2 + i32(1);
        }
        var ab_0 : vec2<f32> = env_brdf_0(_S72, rough_4);
        var to_rig_1 : mat3x3<f32> = transpose(rig_2);
        if((Material_Uniforms_0.env_0.x) > 0.5f)
        {
            color_2 = color_2 + diffuse_2 * irradiance_0(n_9);
        }
        else
        {
            if((Material_Uniforms_0.style_0.w) > 0.5f)
            {
                color_2 = color_2 + diffuse_2 * studio_0((((to_rig_1) * (n_9))), 1.0f) * vec3<f32>((0.69999998807907104f * ambient_0 * underside_0(n_9, rig_2)));
            }
            else
            {
                color_2 = color_2 + diffuse_2 * studio_0((((to_rig_1) * (n_9))), 1.0f) * vec3<f32>((0.69999998807907104f * ambient_0));
            }
        }
        var _S74 : pixelOutput_0 = pixelOutput_0( display_0((color_2 + reflected_0(r_2, rough_4, to_rig_1) * (f0_2 * vec3<f32>(ab_0.x) + vec3<f32>(ab_0.y)) * vec3<f32>(highlight_0)) * vec3<f32>(relief_0)) );
        return _S74;
    }
    var _S75 : f32 = shading_0.w;
    var _S76 : f32 = shading_0.x * ambient_0;
    var _S77 : vec3<f32> = vec3<f32>(_S76);
    var _S78 : vec3<f32> = vec3<f32>(0.0f);
    var _S79 : vec3<f32> = reflect((vec3<f32>(0) - v_6), n_9);
    i_2 = i32(0);
    color_2 = _S77;
    lit_0 = _S78;
    for(;;)
    {
        if(i_2 < i32(8))
        {
        }
        else
        {
            break;
        }
        var s_3 : f32 = Material_Uniforms_0.light_color_0[i_2].w;
        if(s_3 <= 0.0f)
        {
            _S57 = true;
        }
        else
        {
            _S57 = (Material_Uniforms_0.light_pos_0[i_2].w) > 2.5f;
        }
        if(_S57)
        {
            i_2 = i_2 + i32(1);
            continue;
        }
        var l_5 : vec3<f32>;
        var spread_5 : f32;
        var _S80 : f32 = light_at_0(i_2, &(l_5), &(spread_5));
        var s_4 : f32 = s_3 * _S80;
        if(s_4 <= 0.0f)
        {
            i_2 = i_2 + i32(1);
            continue;
        }
        var lit_1 : vec3<f32> = color_2 + Material_Uniforms_0.light_color_0[i_2].xyz * vec3<f32>((max((dot(n_9, l_5) + _S75) / (1.0f + _S75), 0.0f) * s_4));
        var _S81 : vec3<f32> = normalize(l_5 + v_6);
        var shrink_0 : f32 = 1.0f + Material_Uniforms_0.light_extra_0[i_2].x;
        var h_3 : vec3<f32>;
        if(spread_5 > 0.0f)
        {
            var shrink_1 : f32 = shrink_0 * widened_0(sqrt(2.0f / (shading_0.z + 2.0f)), spread_5);
            h_3 = normalize(nearest_in_light_0(l_5, _S79, spread_5) + v_6);
            k_3 = shrink_1;
        }
        else
        {
            h_3 = _S81;
            k_3 = shrink_0;
        }
        var spec_0 : vec3<f32> = lit_0 + Material_Uniforms_0.light_color_0[i_2].xyz * vec3<f32>((pow(max(dot(n_9, h_3), 0.0f), shading_0.z) * shading_0.y * s_4 * k_3));
        color_2 = lit_1;
        lit_0 = spec_0;
        i_2 = i_2 + i32(1);
    }
    var _S82 : f32 = 1.0f - _S62;
    var _S83 : f32 = pow(_S82, 3.0f) * 0.25f;
    if((Material_Uniforms_0.style_0.w) > 0.5f)
    {
        var lit_2 : vec3<f32> = color_2 - vec3<f32>((_S76 * (1.0f - underside_0(n_9, rig_2))));
        k_3 = pow(_S82, 4.0f) * Material_Uniforms_0.style_0.x * mix(0.30000001192092896f, 1.0f, sky_facing_0(n_9, rig_2));
        color_2 = lit_2;
    }
    else
    {
        k_3 = _S83;
    }
    var _S84 : pixelOutput_0 = pixelOutput_0( display_0((albedo_0 * color_2 + (lit_0 + vec3<f32>(k_3)) * vec3<f32>(highlight_0)) * vec3<f32>(relief_0)) );
    return _S84;
}

