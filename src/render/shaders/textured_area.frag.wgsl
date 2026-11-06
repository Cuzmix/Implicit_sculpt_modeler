// slangc wgsl from textured_area.frag.spv sha256 7eb6fbbdfdcb5ffbe3db3e61c5015edff58900051966cdcb66ec528fe7d9e100
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
@binding(8) @group(2) var normal_map_texture_0 : texture_2d<f32>;

@binding(9) @group(2) var normal_map_sampler_0 : sampler;

@binding(14) @group(2) var paint_height_map_texture_0 : texture_2d<f32>;

@binding(15) @group(2) var paint_height_map_sampler_0 : sampler;

@binding(6) @group(2) var orm_map_texture_0 : texture_2d<f32>;

@binding(7) @group(2) var orm_map_sampler_0 : sampler;

@binding(12) @group(2) var paint_material_map_texture_0 : texture_2d<f32>;

@binding(13) @group(2) var paint_material_map_sampler_0 : sampler;

@binding(4) @group(2) var base_map_texture_0 : texture_2d<f32>;

@binding(5) @group(2) var base_map_sampler_0 : sampler;

@binding(10) @group(2) var paint_map_texture_0 : texture_2d<f32>;

@binding(11) @group(2) var paint_map_sampler_0 : sampler;

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
     uv_0 : vec2<f32>,
     view_tangent_0 : vec4<f32>,
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

fn paint_height_slope_0( uv_1 : vec2<f32>) -> vec2<f32>
{
    var w_0 : u32;
    var h_0 : u32;
    {var dim = textureDimensions((paint_height_map_texture_0));((w_0)) = dim.x;((h_0)) = dim.y;};
    if(w_0 <= u32(1))
    {
        return vec2<f32>(0.0f, 0.0f);
    }
    var _S2 : f32 = 1.0f / f32(h_0);
    var _S3 : vec2<f32> = vec2<f32>(1.0f / f32(w_0), 0.0f);
    var _S4 : vec2<f32> = uv_1 - _S3;
    ;
    var l_0 : f32 = (textureSample((paint_height_map_texture_0), (paint_height_map_sampler_0), (_S4))).x;
    var _S5 : vec2<f32> = uv_1 + _S3;
    ;
    var r_0 : f32 = (textureSample((paint_height_map_texture_0), (paint_height_map_sampler_0), (_S5))).x;
    var _S6 : vec2<f32> = vec2<f32>(0.0f, _S2);
    var _S7 : vec2<f32> = uv_1 - _S6;
    ;
    var up_0 : f32 = (textureSample((paint_height_map_texture_0), (paint_height_map_sampler_0), (_S7))).x;
    var _S8 : vec2<f32> = uv_1 + _S6;
    ;
    return vec2<f32>(r_0 - l_0, up_0 - (textureSample((paint_height_map_texture_0), (paint_height_map_sampler_0), (_S8))).x) * vec2<f32>(0.5f) * vec2<f32>((f32(w_0) / 64.0f));
}

fn paint_surface_0( surf_0 : vec2<f32>,  m_0 : vec4<f32>) -> vec2<f32>
{
    return vec2<f32>(mix(surf_0.x, m_0.z, m_0.w), max(mix(surf_0.y, m_0.x, m_0.y), 0.03999999910593033f));
}

fn curvature_0( n_0 : vec3<f32>,  p_0 : vec3<f32>) -> f32
{
    var dpx_0 : vec3<f32> = dpdx(p_0);
    var dpy_0 : vec3<f32> = dpdy(p_0);
    var dnx_0 : vec3<f32> = dpdx(n_0);
    var dny_0 : vec3<f32> = dpdy(n_0);
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

fn skin_detail_color_0( n_1 : vec3<f32>,  v_0 : vec3<f32>) -> vec3<f32>
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
    return vec3<f32>(0.5f, 0.5f, 1.0f) * vec3<f32>((0.69999998807907104f + 0.30000001192092896f * clamp(dot(flat_n_1, v_0), 0.0f, 1.0f)));
}

fn opacity_0() -> f32
{
    var _S9 : f32;
    if((Material_Uniforms_0.look_0.w) > 0.0f)
    {
        _S9 = Material_Uniforms_0.look_0.w;
    }
    else
    {
        _S9 = 1.0f;
    }
    return _S9;
}

fn glsl_mod_0( x_1 : f32,  y_0 : f32) -> f32
{
    return x_1 - y_0 * floor(x_1 / y_0);
}

fn uv_checker_0( uv_2 : vec2<f32>) -> vec3<f32>
{
    var c_2 : vec2<f32> = uv_2 * vec2<f32>(8.0f);
    var width_0 : vec2<f32> = max((fwidth((c_2))), vec2<f32>(9.99999997475242708e-07f));
    var _S10 : f32 = max(width_0.x, width_0.y);
    var f_0 : vec2<f32> = fract(c_2);
    var edge_0 : vec2<f32> = min(f_0, vec2<f32>(1.0f) - f_0) / width_0;
    var cell_0 : vec2<f32> = floor(c_2);
    var _S11 : f32 = cell_0.x;
    var _S12 : f32 = cell_0.y;
    var _S13 : vec3<f32> = vec3<f32>(3.0f);
    var _S14 : vec3<f32> = vec3<f32>(1.0f);
    return mix(mix(_S14, clamp(abs(fract(vec3<f32>(((_S11 + 0.5f) / 8.0f)) + vec3<f32>(0.0f, 2.0f, 1.0f) / _S13) * vec3<f32>(6.0f) - _S13) - vec3<f32>(1.0f), vec3<f32>(0.0f), _S14), vec3<f32>(0.34999999403953552f)) * vec3<f32>(mix(0.69999998807907104f, 1.0f, (_S12 + 0.5f) / 8.0f)) * vec3<f32>((mix(1.0f, 0.72000002861022949f, glsl_mod_0(_S11 + _S12, 2.0f)) * (1.0f - 0.5f * ((1.0f - smoothstep(0.5f, 1.5f, min(edge_0.x, edge_0.y))) * (1.0f - smoothstep(0.0625f, 0.125f, _S10)))))), vec3<f32>(0.75f), vec3<f32>(smoothstep(0.20000000298023224f, 0.40000000596046448f, _S10)));
}

fn ggx_albedo_0( mu_0 : f32,  r_1 : f32) -> f32
{
    var _S15 : f32 = clamp(mu_0, 0.02999999932944775f, 1.0f);
    var _S16 : f32 = clamp(r_1, 0.0f, 1.0f);
    return clamp(1.0f - _S16 * _S16 * (3.83702206611633301f + _S15 * (-8.94610023498535156f + _S15 * (-10.02859973907470703f + _S15 * (27.3765106201171875f + _S15 * (-13.70528984069824219f + _S15 * 2.40487289428710938f)))) + _S16 * (-13.97327995300292969f + _S15 * (57.33845138549804688f + _S15 * (-32.69089126586914062f + _S15 * (-23.426849365234375f + _S15 * 6.77839899063110352f))) + _S16 * (14.98353958129882812f + _S15 * (-75.88365936279296875f + _S15 * (71.32111358642578125f + _S15 * 4.00610685348510742f)) + _S16 * (-2.2494659423828125f + _S15 * (25.239959716796875f + _S15 * -33.6537017822265625f) + _S16 * (-3.07003307342529297f + _S15 * 4.50839805603027344f + _S16 * 0.52433747053146362f))))), 0.05000000074505806f, 1.0f);
}

fn energy_compensation_0( f0_0 : vec3<f32>,  mu_1 : f32,  r_2 : f32) -> vec3<f32>
{
    return vec3<f32>(1.0f) + f0_0 * vec3<f32>((1.0f / ggx_albedo_0(mu_1, r_2) - 1.0f));
}

fn area_clamp_0( i_0 : i32,  q_0 : vec2<f32>) -> vec2<f32>
{
    var hw_0 : f32 = Material_Uniforms_0.light_axis_0[i_0].w;
    if((Material_Uniforms_0.light_extra_0[i_0].w) > 0.5f)
    {
        var len_0 : f32 = length(q_0);
        var _S17 : vec2<f32>;
        if(len_0 > hw_0)
        {
            _S17 = q_0 * vec2<f32>((hw_0 / len_0));
        }
        else
        {
            _S17 = q_0;
        }
        return _S17;
    }
    return clamp(q_0, vec2<f32>(- hw_0, - Material_Uniforms_0.light_extra_0[i_0].z), vec2<f32>(hw_0, Material_Uniforms_0.light_extra_0[i_0].z));
}

fn area_at_0( i_1 : i32,  l_1 : ptr<function, vec3<f32>>,  spread_0 : ptr<function, f32>) -> f32
{
    var c_3 : vec3<f32> = Material_Uniforms_0.light_pos_0[i_1].xyz;
    var f_1 : vec3<f32> = Material_Uniforms_0.light_spot_0[i_1].xyz;
    var u_0 : vec3<f32> = Material_Uniforms_0.light_axis_0[i_1].xyz;
    var w_1 : vec3<f32> = cross(f_1, u_0);
    var shape_0 : vec4<f32> = Material_Uniforms_0.light_shape_0[i_1];
    var d_0 : vec3<f32> = frag_in_0.view_pos_0 - c_3;
    (*spread_0) = 0.0f;
    (*l_1) = f_1;
    if((dot(d_0, f_1)) <= 0.0f)
    {
        return 0.0f;
    }
    var q_1 : vec2<f32> = area_clamp_0(i_1, vec2<f32>(dot(d_0, u_0), dot(d_0, w_1)));
    (*l_1) = normalize(c_3 + u_0 * vec3<f32>(q_1.x) + w_1 * vec3<f32>(q_1.y) - frag_in_0.view_pos_0);
    var _S18 : f32 = shape_0.w;
    var _S19 : f32 = max(dot(d_0, d_0), _S18 * _S18);
    (*spread_0) = min(_S18 * rsqrt_0(_S19), 1.0f);
    var _S20 : f32 = shape_0.x;
    var k_0 : f32 = _S20 * _S20 / max(_S19, 9.99999993922529029e-09f) * max(dot((vec3<f32>(0) - (*l_1)), f_1), 0.0f);
    var _S21 : f32 = shape_0.y;
    var k_1 : f32;
    if(_S21 > 0.0f)
    {
        var x_2 : f32 = _S19 / (_S21 * _S21);
        var win_0 : f32 = clamp(1.0f - x_2 * x_2, 0.0f, 1.0f);
        k_1 = k_0 * (win_0 * win_0);
    }
    else
    {
        k_1 = k_0;
    }
    return k_1;
}

fn area_mirror_0( i_2 : i32,  r_3 : vec3<f32>) -> vec3<f32>
{
    var c_4 : vec3<f32> = Material_Uniforms_0.light_pos_0[i_2].xyz;
    var f_2 : vec3<f32> = Material_Uniforms_0.light_spot_0[i_2].xyz;
    var u_1 : vec3<f32> = Material_Uniforms_0.light_axis_0[i_2].xyz;
    var w_2 : vec3<f32> = cross(f_2, u_1);
    var to_0 : vec3<f32> = c_4 - frag_in_0.view_pos_0;
    var facing_0 : f32 = dot(r_3, f_2);
    var t_0 : f32;
    if(facing_0 < -0.00009999999747379f)
    {
        t_0 = dot(to_0, f_2) / facing_0;
    }
    else
    {
        t_0 = length(to_0);
    }
    var hit_0 : vec3<f32> = frag_in_0.view_pos_0 + r_3 * vec3<f32>(t_0) - c_4;
    var q_2 : vec2<f32> = area_clamp_0(i_2, vec2<f32>(dot(hit_0, u_1), dot(hit_0, w_2)));
    return normalize(to_0 + u_1 * vec3<f32>(q_2.x) + w_2 * vec3<f32>(q_2.y));
}

fn widened_0( a_0 : f32,  spread_1 : f32) -> f32
{
    var _S22 : f32 = min(a_0 + 0.5f * spread_1, 1.0f);
    return a_0 * a_0 / (_S22 * _S22);
}

fn direct_sized_0( n_2 : vec3<f32>,  v_1 : vec3<f32>,  l_2 : vec3<f32>,  ls_0 : vec3<f32>,  spread_2 : f32,  diffuse_0 : vec3<f32>,  f0_1 : vec3<f32>,  a_1 : f32,  shine_0 : f32,  comp_0 : vec3<f32>) -> vec3<f32>
{
    var color_0 : vec3<f32> = diffuse_0 / vec3<f32>(3.14159274101257324f) * vec3<f32>(max(dot(n_2, l_2), 0.0f));
    var _S23 : f32 = max(dot(n_2, ls_0), 0.0f);
    if(_S23 <= 0.0f)
    {
        return color_0;
    }
    var h_1 : vec3<f32> = normalize(ls_0 + v_1);
    var _S24 : f32 = max(dot(n_2, v_1), 0.00009999999747379f);
    var _S25 : f32 = max(dot(n_2, h_1), 0.0f);
    var a2_0 : f32 = a_1 * a_1;
    var d_1 : f32 = _S25 * _S25 * (a2_0 - 1.0f) + 1.0f;
    return color_0 + vec3<f32>((a2_0 / (3.14159274101257324f * d_1 * d_1) * widened_0(a_1, spread_2) * (0.5f / max(mix(2.0f * _S23 * _S24, _S23 + _S24, a_1), 0.00009999999747379f)))) * (f0_1 + (vec3<f32>(1.0f) - f0_1) * vec3<f32>(pow(1.0f - max(dot(v_1, h_1), 0.0f), 5.0f))) * comp_0 * vec3<f32>(_S23) * vec3<f32>(shine_0);
}

fn light_at_0( i_3 : i32,  l_3 : ptr<function, vec3<f32>>,  spread_3 : ptr<function, f32>) -> f32
{
    var p_1 : vec4<f32> = Material_Uniforms_0.light_pos_0[i_3];
    var shape_1 : vec4<f32> = Material_Uniforms_0.light_shape_0[i_3];
    var _S26 : f32 = Material_Uniforms_0.light_pos_0[i_3].w;
    if(_S26 < 0.5f)
    {
        (*l_3) = p_1.xyz;
        (*spread_3) = shape_1.w;
        return 1.0f;
    }
    var d_2 : vec3<f32> = p_1.xyz - frag_in_0.view_pos_0;
    var _S27 : f32 = max(dot(d_2, d_2), 9.99999993922529029e-09f);
    var inv_0 : f32 = rsqrt_0(_S27);
    (*l_3) = d_2 * vec3<f32>(inv_0);
    (*spread_3) = min(shape_1.w * inv_0, 1.0f);
    var _S28 : f32 = shape_1.x;
    var k_2 : f32 = _S28 * _S28 / _S27;
    var _S29 : f32 = shape_1.y;
    var k_3 : f32;
    if(_S29 > 0.0f)
    {
        var x_3 : f32 = _S27 / (_S29 * _S29);
        var w_3 : f32 = clamp(1.0f - x_3 * x_3, 0.0f, 1.0f);
        k_3 = k_2 * (w_3 * w_3);
    }
    else
    {
        k_3 = k_2;
    }
    if(_S26 > 1.5f)
    {
        k_3 = k_3 * smoothstep(Material_Uniforms_0.light_spot_0[i_3].w, shape_1.z, dot((vec3<f32>(0) - (*l_3)), Material_Uniforms_0.light_spot_0[i_3].xyz));
    }
    return k_3;
}

fn nearest_in_light_0( l_4 : vec3<f32>,  r_4 : vec3<f32>,  spread_4 : f32) -> vec3<f32>
{
    var cos_r_0 : f32 = sqrt(max(1.0f - spread_4 * spread_4, 0.0f));
    var l_dot_r_0 : f32 = dot(l_4, r_4);
    if(l_dot_r_0 >= cos_r_0)
    {
        return r_4;
    }
    var s_0 : vec3<f32> = r_4 - vec3<f32>(l_dot_r_0) * l_4;
    var s2_0 : f32 = dot(s_0, s_0);
    if(s2_0 < 9.999999960041972e-13f)
    {
        return l_4;
    }
    return normalize(l_4 * vec3<f32>(cos_r_0) + s_0 * vec3<f32>((rsqrt_0(s2_0) * spread_4)));
}

fn direct_0( n_3 : vec3<f32>,  v_2 : vec3<f32>,  l_5 : vec3<f32>,  diffuse_1 : vec3<f32>,  f0_2 : vec3<f32>,  a_2 : f32,  shine_1 : f32,  comp_1 : vec3<f32>) -> vec3<f32>
{
    var _S30 : f32 = max(dot(n_3, l_5), 0.0f);
    if(_S30 <= 0.0f)
    {
        return vec3<f32>(0.0f);
    }
    var h_2 : vec3<f32> = normalize(l_5 + v_2);
    var _S31 : f32 = max(dot(n_3, v_2), 0.00009999999747379f);
    var _S32 : f32 = max(dot(n_3, h_2), 0.0f);
    var a2_1 : f32 = a_2 * a_2;
    var d_3 : f32 = _S32 * _S32 * (a2_1 - 1.0f) + 1.0f;
    return (diffuse_1 / vec3<f32>(3.14159274101257324f) + vec3<f32>((a2_1 / (3.14159274101257324f * d_3 * d_3) * (0.5f / max(mix(2.0f * _S30 * _S31, _S30 + _S31, a_2), 0.00009999999747379f)))) * (f0_2 + (vec3<f32>(1.0f) - f0_2) * vec3<f32>(pow(1.0f - max(dot(v_2, h_2), 0.0f), 5.0f))) * comp_1 * vec3<f32>(shine_1)) * vec3<f32>(_S30);
}

fn env_brdf_0( n_dot_v_0 : f32,  rough_0 : f32) -> vec2<f32>
{
    var r_5 : vec4<f32> = vec4<f32>(rough_0) * vec4<f32>(-1.0f, -0.02749999985098839f, -0.57200002670288086f, 0.02199999988079071f) + vec4<f32>(1.0f, 0.04250000044703484f, 1.03999996185302734f, -0.03999999910593033f);
    var _S33 : f32 = r_5.x;
    return vec2<f32>(-1.03999996185302734f, 1.03999996185302734f) * vec2<f32>((min(_S33 * _S33, exp2(-9.27999973297119141f * n_dot_v_0)) * _S33 + r_5.y)) + r_5.zw;
}

fn irradiance_0( n_4 : vec3<f32>) -> vec3<f32>
{
    var d_4 : vec3<f32> = (((transpose(mat3x3<f32>(Material_Uniforms_0.env_x_0.xyz, Material_Uniforms_0.env_y_0.xyz, Material_Uniforms_0.env_z_0.xyz))) * (n_4)));
    var _S34 : f32 = d_4.y;
    var _S35 : f32 = d_4.z;
    var _S36 : f32 = d_4.x;
    var _S37 : f32 = 1.09254801273345947f * _S36;
    return max(Material_Uniforms_0.env_sh_0[i32(0)].xyz * vec3<f32>(0.28209498524665833f) + Material_Uniforms_0.env_sh_0[i32(1)].xyz * vec3<f32>((0.48860299587249756f * _S34)) + Material_Uniforms_0.env_sh_0[i32(2)].xyz * vec3<f32>((0.48860299587249756f * _S35)) + Material_Uniforms_0.env_sh_0[i32(3)].xyz * vec3<f32>((0.48860299587249756f * _S36)) + Material_Uniforms_0.env_sh_0[i32(4)].xyz * vec3<f32>((_S37 * _S34)) + Material_Uniforms_0.env_sh_0[i32(5)].xyz * vec3<f32>((1.09254801273345947f * _S34 * _S35)) + Material_Uniforms_0.env_sh_0[i32(6)].xyz * vec3<f32>((0.31539198756217957f * (3.0f * _S35 * _S35 - 1.0f))) + Material_Uniforms_0.env_sh_0[i32(7)].xyz * vec3<f32>((_S37 * _S35)) + Material_Uniforms_0.env_sh_0[i32(8)].xyz * vec3<f32>((0.54627400636672974f * (_S36 * _S36 - _S34 * _S34))), vec3<f32>(0.0f)) * vec3<f32>(Material_Uniforms_0.env_0.y);
}

fn lobe_0( dir_0 : vec3<f32>,  toward_0 : vec3<f32>,  color_1 : vec3<f32>,  sharp_0 : f32,  rough_1 : f32) -> vec3<f32>
{
    var e_0 : f32 = mix(sharp_0, 3.0f, sqrt(rough_1));
    return color_1 * vec3<f32>(pow(max(dot(dir_0, toward_0), 0.0f), e_0)) * vec3<f32>((e_0 + 2.0f)) / vec3<f32>((sharp_0 + 2.0f));
}

fn studio_0( dir_1 : vec3<f32>,  rough_2 : f32) -> vec3<f32>
{
    var w_4 : f32 = 0.07999999821186066f + 0.89999997615814209f * rough_2;
    var _S38 : f32 = dir_1.y;
    return mix(vec3<f32>(0.07000000029802322f, 0.06499999761581421f, 0.05999999865889549f), vec3<f32>(0.40000000596046448f, 0.43000000715255737f, 0.47999998927116394f), vec3<f32>(smoothstep(- w_4, w_4, _S38))) + vec3<f32>(0.12999999523162842f, 0.11999999731779099f, 0.10999999940395355f) * vec3<f32>(exp(- abs(_S38) / (0.05999999865889549f + 0.5f * rough_2))) + lobe_0(dir_1, vec3<f32>(-0.65590423345565796f, 0.7433580756187439f, 0.13118083775043488f), vec3<f32>(4.0f, 3.79999995231628418f, 3.5f), 300.0f, rough_2) + lobe_0(dir_1, vec3<f32>(0.84478187561035156f, 0.32852628827095032f, -0.42239093780517578f), vec3<f32>(1.60000002384185791f, 1.79999995231628418f, 2.09999990463256836f), 600.0f, rough_2) + lobe_0(dir_1, vec3<f32>(0.09396819770336151f, -0.32888868451118469f, 0.93968194723129272f), vec3<f32>(0.5f, 0.5f, 0.5f), 4.0f, rough_2);
}

fn sky_facing_0( n_5 : vec3<f32>,  rig_0 : mat3x3<f32>) -> f32
{
    return 0.5f + 0.5f * dot(n_5, rig_0[i32(1)]);
}

fn underside_0( n_6 : vec3<f32>,  rig_1 : mat3x3<f32>) -> f32
{
    return mix(Material_Uniforms_0.style_0.y, 1.0f, sky_facing_0(n_6, rig_1));
}

fn panorama_uv_0( d_5 : vec3<f32>) -> vec2<f32>
{
    return vec2<f32>(atan2(d_5.x, - d_5.z - 9.99999968265522539e-21f) * 0.15915493667125702f + 0.5f, acos(clamp(d_5.y, -1.0f, 1.0f)) * 0.31830990314483643f);
}

fn reflected_0( dir_2 : vec3<f32>,  rough_3 : f32,  to_rig_0 : mat3x3<f32>) -> vec3<f32>
{
    if((Material_Uniforms_0.env_0.x) > 0.5f)
    {
        return (textureSampleLevel((environment_map_texture_0), (environment_map_sampler_0), (panorama_uv_0((((transpose(mat3x3<f32>(Material_Uniforms_0.env_x_0.xyz, Material_Uniforms_0.env_y_0.xyz, Material_Uniforms_0.env_z_0.xyz))) * (dir_2))))), (rough_3 * Material_Uniforms_0.env_0.z))).xyz * vec3<f32>(Material_Uniforms_0.env_0.y);
    }
    return studio_0((((to_rig_0) * (dir_2))), rough_3);
}

fn tone_map_0( c_5 : vec3<f32>) -> vec3<f32>
{
    var _S39 : f32 = min(c_5.x, min(c_5.y, c_5.z));
    var offset_0 : f32;
    if(_S39 < 0.07999999821186066f)
    {
        offset_0 = _S39 - 6.25f * _S39 * _S39;
    }
    else
    {
        offset_0 = 0.03999999910593033f;
    }
    var _S40 : vec3<f32> = c_5 - vec3<f32>(offset_0);
    var _S41 : f32 = max(_S40.x, max(_S40.y, _S40.z));
    if(_S41 < 0.75999999046325684f)
    {
        return _S40;
    }
    var new_peak_0 : f32 = 1.0f - 0.0576000027358532f / (_S41 + 0.24000000953674316f - 0.75999999046325684f);
    return mix(_S40 * vec3<f32>((new_peak_0 / _S41)), vec3<f32>(new_peak_0), vec3<f32>((1.0f - 1.0f / (0.15000000596046448f * (_S41 - new_peak_0) + 1.0f))));
}

fn display_color_0( c_6 : vec3<f32>,  stops_0 : f32) -> vec3<f32>
{
    return srgb_encode_0(tone_map_0(c_6 * vec3<f32>(exp2(stops_0))));
}

fn display_0( c_7 : vec3<f32>) -> vec4<f32>
{
    return vec4<f32>(display_color_0(c_7, Material_Uniforms_0.look_0.x), opacity_0());
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
    @location(7) uv_3 : vec2<f32>,
    @location(8) view_tangent_1 : vec4<f32>,
    @location(9) material_1 : vec4<f32>,
};

@fragment
fn main( _S42 : pixelInput_0, @builtin(position) position_0 : vec4<f32>, @builtin(front_facing) is_front_0 : bool) -> pixelOutput_0
{
    frag_in_0.view_normal_0 = _S42.view_normal_1;
    frag_in_0.view_pos_0 = _S42.view_pos_1;
    frag_in_0.mask_0 = _S42.mask_1;
    frag_in_0.paint_0 = _S42.paint_1;
    frag_in_0.group_0 = _S42.group_1;
    frag_in_0.mesh_pos_0 = _S42.mesh_pos_1;
    frag_in_0.slot_0 = _S42.slot_1;
    frag_in_0.uv_0 = _S42.uv_3;
    frag_in_0.view_tangent_0 = _S42.view_tangent_1;
    frag_in_0.material_0 = _S42.material_1;
    frag_coord_0 = position_0;
    front_facing_0 = is_front_0;
    if((Material_Uniforms_0.params_0.y) < 0.0f)
    {
        var _S43 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0(Material_Uniforms_0.base_color_0.xyz), 1.0f) );
        return _S43;
    }
    var base_0 : vec4<f32> = Material_Uniforms_0.base_color_0;
    var shading_0 : vec4<f32> = Material_Uniforms_0.params_0;
    var surf_1 : vec4<f32> = Material_Uniforms_0.surface_0;
    var v_3 : vec3<f32>;
    if((Material_Uniforms_0.env_0.w) > 0.5f)
    {
        v_3 = vec3<f32>(0.0f, 0.0f, 1.0f);
    }
    else
    {
        v_3 = normalize((vec3<f32>(0) - frag_in_0.view_pos_0));
    }
    var view_mode_0 : i32 = i32(Material_Uniforms_0.maps_0.w + 0.5f);
    var uv_4 : vec2<f32> = vec2<f32>(frag_in_0.uv_0.x, 1.0f - frag_in_0.uv_0.y);
    var nv_0 : vec3<f32> = frag_in_0.view_normal_0;
    var tv_0 : vec3<f32> = frag_in_0.view_tangent_0.xyz;
    var _S44 : vec3<f32> = normalize(frag_in_0.view_normal_0);
    var _S45 : bool = view_mode_0 == i32(1);
    var _S46 : bool;
    if(_S45)
    {
        _S46 = true;
    }
    else
    {
        _S46 = view_mode_0 == i32(2);
    }
    var n_7 : vec3<f32>;
    if(_S46)
    {
        var tn_0 : vec3<f32>;
        if((Material_Uniforms_0.maps_0.z) > 0.5f)
        {
            ;
            n_7 = (textureSample((normal_map_texture_0), (normal_map_sampler_0), (uv_4))).xyz * vec3<f32>(2.0f) - vec3<f32>(1.0f);
        }
        else
        {
            n_7 = vec3<f32>(0.0f, 0.0f, 1.0f);
        }
        tn_0 = n_7;
        var slope_0 : vec2<f32> = paint_height_slope_0(uv_4);
        var _S47 : vec2<f32> = n_7.xy - slope_0;
        tn_0.x = _S47.x;
        tn_0.y = _S47.y;
        if((Material_Uniforms_0.maps_0.z) > 0.5f)
        {
            _S46 = true;
        }
        else
        {
            _S46 = (any((slope_0 != vec2<f32>(0.0f))));
        }
        if(_S46)
        {
            var mapped_0 : vec3<f32> = vec3<f32>(tn_0.x) * tv_0 + vec3<f32>(tn_0.y) * (vec3<f32>(frag_in_0.view_tangent_0.w) * cross(nv_0, tv_0)) + vec3<f32>(tn_0.z) * nv_0;
            if((dot(mapped_0, mapped_0)) > 0.0f)
            {
                n_7 = normalize(mapped_0);
            }
            else
            {
                n_7 = _S44;
            }
        }
        else
        {
            n_7 = _S44;
        }
    }
    else
    {
        n_7 = _S44;
    }
    if(!front_facing_0)
    {
        n_7 = (vec3<f32>(0) - n_7);
    }
    if(_S45)
    {
        _S46 = (Material_Uniforms_0.maps_0.y) > 0.5f;
    }
    else
    {
        _S46 = false;
    }
    var ao_0 : f32;
    if(_S46)
    {
        ;
        var orm_0 : vec3<f32> = (textureSample((orm_map_texture_0), (orm_map_sampler_0), (uv_4))).xyz;
        var _S48 : f32 = orm_0.x;
        surf_1[i32(0)] = orm_0.z;
        surf_1[i32(1)] = max(orm_0.y, 0.03999999910593033f);
        ao_0 = _S48;
    }
    else
    {
        ao_0 = 1.0f;
    }
    if(_S45)
    {
        _S46 = (surf_1.y) > 0.0f;
    }
    else
    {
        _S46 = false;
    }
    if(_S46)
    {
        var _S49 : vec2<f32> = paint_surface_0(surf_1.xy, frag_in_0.material_0);
        surf_1.x = _S49.x;
        surf_1.y = _S49.y;
        ;
        var _S50 : vec4<f32> = (textureSample((paint_material_map_texture_0), (paint_material_map_sampler_0), (uv_4)));
        surf_1[i32(0)] = surf_1.x * (1.0f - _S50.w) + _S50.z;
        surf_1[i32(1)] = max(surf_1.y * (1.0f - _S50.y) + _S50.x, 0.03999999910593033f);
    }
    var dndx_0 : vec3<f32> = dpdx(n_7);
    var dndy_0 : vec3<f32> = dpdy(n_7);
    var bend_0 : f32 = curvature_0(n_7, frag_in_0.view_pos_0);
    var _S51 : i32 = i32(Material_Uniforms_0.pass_0.x + 0.5f);
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
            view_pass_0 = _S51;
        }
    }
    else
    {
        view_pass_0 = _S51;
    }
    if(view_pass_0 != i32(0))
    {
        _S46 = view_pass_0 != i32(7);
    }
    else
    {
        _S46 = false;
    }
    var shown_0 : vec3<f32>;
    var k_4 : f32;
    if(_S46)
    {
        if(view_pass_0 == i32(1))
        {
            var _S52 : vec3<f32> = vec3<f32>(0.5f);
            shown_0 = n_7 * _S52 + _S52;
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
                    var k_5 : f32 = clamp(bend_0 / 0.23999999463558197f, -1.0f, 1.0f);
                    if(k_5 > 0.0f)
                    {
                        k_4 = k_5 * smoothstep(0.10000000149011612f, 0.40000000596046448f, max(dot(n_7, v_3), 0.0f));
                    }
                    else
                    {
                        k_4 = k_5;
                    }
                    var _S53 : vec3<f32> = vec3<f32>(0.5f);
                    if(k_4 < 0.0f)
                    {
                        v_3 = vec3<f32>(0.15000000596046448f, 0.34999999403953552f, 0.85000002384185791f);
                    }
                    else
                    {
                        v_3 = vec3<f32>(0.94999998807907104f, 0.55000001192092896f, 0.15000000596046448f);
                    }
                    shown_0 = mix(_S53, v_3, vec3<f32>(abs(k_4)));
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
                            shown_0 = skin_detail_color_0(n_7, v_3);
                        }
                        else
                        {
                            shown_0 = vec3<f32>(0.05999999865889549f);
                        }
                    }
                }
            }
        }
        var _S54 : pixelOutput_0 = pixelOutput_0( vec4<f32>(shown_0, opacity_0()) );
        return _S54;
    }
    var _S55 : f32 = dot(n_7, v_3);
    var _S56 : f32 = max(_S55, 0.0f);
    var relief_0 : f32 = (1.0f - 0.75f * (Material_Uniforms_0.look_0.y * smoothstep(0.01999999955296516f, 0.23999999463558197f, - bend_0))) * (1.0f + 0.60000002384185791f * (Material_Uniforms_0.look_0.z * smoothstep(0.01999999955296516f, 0.23999999463558197f, bend_0) * smoothstep(0.10000000149011612f, 0.40000000596046448f, _S56)));
    var _S57 : vec3<f32> = base_0.xyz;
    var _S58 : vec3<f32> = mix(_S57, frag_in_0.paint_0.xyz, vec3<f32>(frag_in_0.paint_0.w));
    if((frag_in_0.group_0.x) >= 0.0f)
    {
        shown_0 = frag_in_0.group_0;
    }
    else
    {
        shown_0 = _S58;
    }
    if(_S45)
    {
        _S46 = (Material_Uniforms_0.maps_0.x) > 0.5f;
    }
    else
    {
        _S46 = false;
    }
    if(_S46)
    {
        ;
        shown_0 = _S57 * (textureSample((base_map_texture_0), (base_map_sampler_0), (uv_4))).xyz;
    }
    if(_S45)
    {
        ;
        var _S59 : vec4<f32> = (textureSample((paint_map_texture_0), (paint_map_sampler_0), (uv_4)));
        shown_0 = shown_0 * vec3<f32>((1.0f - _S59.w)) + _S59.xyz;
    }
    if(view_mode_0 == i32(3))
    {
        shown_0 = shown_0 * uv_checker_0(uv_4);
    }
    if((Material_Uniforms_0.fade_0.w) > 0.0f)
    {
        _S46 = (frag_in_0.group_0.x) < 0.0f;
    }
    else
    {
        _S46 = false;
    }
    if(_S46)
    {
        shown_0 = mix(shown_0, Material_Uniforms_0.fade_0.xyz, vec3<f32>(Material_Uniforms_0.fade_0.w));
    }
    if((Material_Uniforms_0.checker_0.w) > 0.0f)
    {
        var c_8 : vec3<f32> = (frag_in_0.mesh_pos_0 - Material_Uniforms_0.checker_0.xyz) / vec3<f32>(Material_Uniforms_0.checker_0.w);
        var width_1 : vec3<f32> = max((fwidth((c_8))), vec3<f32>(9.99999997475242708e-07f));
        var _S60 : f32 = max(max(width_1.x, width_1.y), width_1.z);
        var f_3 : vec3<f32> = fract(c_8);
        var edge_1 : vec3<f32> = min(f_3, vec3<f32>(1.0f) - f_3) / width_1;
        var cell_1 : vec3<f32> = floor(c_8);
        shown_0 = shown_0 * vec3<f32>(mix(mix(1.0f, 0.72000002861022949f, glsl_mod_0(cell_1.x + cell_1.y + cell_1.z, 2.0f)) * (1.0f - 0.34999999403953552f * ((1.0f - smoothstep(0.5f, 1.5f, min(min(edge_1.x, edge_1.y), edge_1.z))) * (1.0f - smoothstep(0.0625f, 0.125f, _S60)))), 0.86000001430511475f, smoothstep(0.20000000298023224f, 0.40000000596046448f, _S60)));
    }
    var rig_2 : mat3x3<f32> = mat3x3<f32>(Material_Uniforms_0.light_x_0.xyz, Material_Uniforms_0.light_y_0.xyz, Material_Uniforms_0.light_z_0.xyz);
    var ambient_0 : f32 = Material_Uniforms_0.light_x_0.w;
    var shown_mask_0 : f32 = frag_in_0.mask_0 * (1.0f - Material_Uniforms_0.style_0.z);
    var albedo_0 : vec3<f32> = shown_0 * vec3<f32>((1.0f - 0.69999998807907104f * shown_mask_0));
    var highlight_0 : f32 = 1.0f - 0.5f * shown_mask_0;
    if(view_pass_0 == i32(7))
    {
        var _S61 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0(albedo_0 * vec3<f32>(relief_0) * vec3<f32>(exp2(Material_Uniforms_0.look_0.x))), opacity_0()) );
        return _S61;
    }
    if((surf_1.w) > 0.5f)
    {
        var k_6 : f32 = 1.0f / (1.0f + v_3.z);
        var _S62 : f32 = v_3.x;
        var _S63 : f32 = - _S62;
        var _S64 : f32 = v_3.y;
        var b_0 : f32 = _S63 * _S64 * k_6;
        var _S65 : vec2<f32> = vec2<f32>(0.5f + 0.49599999189376831f * dot(vec3<f32>(1.0f - _S62 * _S62 * k_6, b_0, _S63), n_7), 0.5f - 0.49599999189376831f * dot(vec3<f32>(b_0, 1.0f - _S64 * _S64 * k_6, - _S64), n_7));
        ;
        var _S66 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0((textureSample((matcap_texture_0), (matcap_sampler_0), (_S65))).xyz * albedo_0 * vec3<f32>(relief_0) * vec3<f32>(exp2(Material_Uniforms_0.look_0.x))), opacity_0()) );
        return _S66;
    }
    var color_2 : vec3<f32>;
    var lit_0 : vec3<f32>;
    var i_4 : i32;
    if((surf_1.y) > 0.0f)
    {
        var metallic_0 : f32 = clamp(surf_1.x, 0.0f, 1.0f);
        var a_3 : f32 = surf_1.y * surf_1.y;
        var rough_4 : f32 = clamp(sqrt(sqrt(clamp(a_3 * a_3 + min(2.0f * (0.25f * (dot(dndx_0, dndx_0) + dot(dndy_0, dndy_0))), 0.18000000715255737f), 0.0f, 1.0f))), 0.03999999910593033f, 1.0f);
        var _S67 : f32 = rough_4 * rough_4;
        var diffuse_2 : vec3<f32> = albedo_0 * vec3<f32>((1.0f - metallic_0));
        var f0_3 : vec3<f32> = mix(vec3<f32>(0.03999999910593033f), albedo_0, vec3<f32>(metallic_0));
        var _S68 : f32 = max(_S55, 0.00009999999747379f);
        var r_6 : vec3<f32> = reflect((vec3<f32>(0) - v_3), n_7);
        var _S69 : vec3<f32> = energy_compensation_0(f0_3, _S68, rough_4);
        var _S70 : vec3<f32> = vec3<f32>(0.0f);
        i_4 = i32(0);
        color_2 = _S70;
        for(;;)
        {
            if(i_4 < i32(8))
            {
            }
            else
            {
                break;
            }
            var s_1 : f32 = Material_Uniforms_0.light_color_0[i_4].w;
            if(s_1 <= 0.0f)
            {
                _S46 = true;
            }
            else
            {
                _S46 = (Material_Uniforms_0.light_pos_0[i_4].w) < 2.5f;
            }
            if(_S46)
            {
                i_4 = i_4 + i32(1);
                continue;
            }
            var l_6 : vec3<f32>;
            var spread_5 : f32;
            var k_7 : f32 = area_at_0(i_4, &(l_6), &(spread_5));
            if(k_7 <= 0.0f)
            {
                i_4 = i_4 + i32(1);
                continue;
            }
            color_2 = color_2 + direct_sized_0(n_7, v_3, l_6, area_mirror_0(i_4, r_6), spread_5, diffuse_2, f0_3, _S67, 1.0f + Material_Uniforms_0.light_extra_0[i_4].x, _S69) * Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((3.0f * (s_1 * k_7)));
            i_4 = i_4 + i32(1);
        }
        i_4 = i32(0);
        for(;;)
        {
            if(i_4 < i32(8))
            {
            }
            else
            {
                break;
            }
            var s_2 : f32 = Material_Uniforms_0.light_color_0[i_4].w;
            if(s_2 <= 0.0f)
            {
                _S46 = true;
            }
            else
            {
                _S46 = (Material_Uniforms_0.light_pos_0[i_4].w) > 2.5f;
            }
            if(_S46)
            {
                i_4 = i_4 + i32(1);
                continue;
            }
            var l_7 : vec3<f32>;
            var spread_6 : f32;
            var k_8 : f32 = light_at_0(i_4, &(l_7), &(spread_6));
            if(k_8 <= 0.0f)
            {
                i_4 = i_4 + i32(1);
                continue;
            }
            var shine_2 : f32 = 1.0f + Material_Uniforms_0.light_extra_0[i_4].x;
            if(spread_6 > 0.0f)
            {
                lit_0 = direct_sized_0(n_7, v_3, l_7, nearest_in_light_0(l_7, r_6, spread_6), spread_6, diffuse_2, f0_3, _S67, shine_2, _S69);
            }
            else
            {
                lit_0 = direct_0(n_7, v_3, l_7, diffuse_2, f0_3, _S67, shine_2, _S69);
            }
            color_2 = color_2 + lit_0 * Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((3.0f * (s_2 * k_8)));
            i_4 = i_4 + i32(1);
        }
        var ab_0 : vec2<f32> = env_brdf_0(_S68, rough_4);
        var to_rig_1 : mat3x3<f32> = transpose(rig_2);
        if((Material_Uniforms_0.env_0.x) > 0.5f)
        {
            color_2 = color_2 + diffuse_2 * irradiance_0(n_7) * vec3<f32>(ao_0);
        }
        else
        {
            if((Material_Uniforms_0.style_0.w) > 0.5f)
            {
                color_2 = color_2 + diffuse_2 * studio_0((((to_rig_1) * (n_7))), 1.0f) * vec3<f32>((0.69999998807907104f * ao_0 * ambient_0 * underside_0(n_7, rig_2)));
            }
            else
            {
                color_2 = color_2 + diffuse_2 * studio_0((((to_rig_1) * (n_7))), 1.0f) * vec3<f32>((0.69999998807907104f * ao_0 * ambient_0));
            }
        }
        var _S71 : f32 = ab_0.x;
        var _S72 : f32 = ab_0.y;
        var _S73 : pixelOutput_0 = pixelOutput_0( display_0((color_2 + reflected_0(r_6, rough_4, to_rig_1) * ((f0_3 * vec3<f32>(_S71) + vec3<f32>(_S72)) * (vec3<f32>(1.0f) + f0_3 * vec3<f32>((1.0f / max(_S71 + _S72, 0.05000000074505806f) - 1.0f)))) * vec3<f32>((highlight_0 * ao_0))) * vec3<f32>(relief_0)) );
        return _S73;
    }
    var _S74 : f32 = shading_0.w;
    var _S75 : f32 = shading_0.x * ao_0 * ambient_0;
    var _S76 : vec3<f32> = vec3<f32>(_S75);
    var _S77 : vec3<f32> = vec3<f32>(0.0f);
    var _S78 : vec3<f32> = reflect((vec3<f32>(0) - v_3), n_7);
    var _S79 : f32 = shading_0.z;
    var _S80 : f32 = _S79 + 2.0f;
    var _S81 : f32 = sqrt(2.0f / _S80);
    i_4 = i32(0);
    color_2 = _S76;
    lit_0 = _S77;
    for(;;)
    {
        if(i_4 < i32(8))
        {
        }
        else
        {
            break;
        }
        var s_3 : f32 = Material_Uniforms_0.light_color_0[i_4].w;
        if(s_3 <= 0.0f)
        {
            _S46 = true;
        }
        else
        {
            _S46 = (Material_Uniforms_0.light_pos_0[i_4].w) < 2.5f;
        }
        if(_S46)
        {
            i_4 = i_4 + i32(1);
            continue;
        }
        var l_8 : vec3<f32>;
        var spread_7 : f32;
        var _S82 : f32 = area_at_0(i_4, &(l_8), &(spread_7));
        var s_4 : f32 = s_3 * _S82;
        if(s_4 <= 0.0f)
        {
            i_4 = i_4 + i32(1);
            continue;
        }
        var spec_0 : vec3<f32> = lit_0 + Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((pow(max(dot(n_7, normalize(area_mirror_0(i_4, _S78) + v_3)), 0.0f), _S79) * shading_0.y * s_4 * ((1.0f + Material_Uniforms_0.light_extra_0[i_4].x) * widened_0(_S81, spread_7))));
        color_2 = color_2 + Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((max((dot(n_7, l_8) + _S74) / (1.0f + _S74), 0.0f) * s_4));
        lit_0 = spec_0;
        i_4 = i_4 + i32(1);
    }
    i_4 = i32(0);
    for(;;)
    {
        if(i_4 < i32(8))
        {
        }
        else
        {
            break;
        }
        var s_5 : f32 = Material_Uniforms_0.light_color_0[i_4].w;
        if(s_5 <= 0.0f)
        {
            _S46 = true;
        }
        else
        {
            _S46 = (Material_Uniforms_0.light_pos_0[i_4].w) > 2.5f;
        }
        if(_S46)
        {
            i_4 = i_4 + i32(1);
            continue;
        }
        var l_9 : vec3<f32>;
        var spread_8 : f32;
        var _S83 : f32 = light_at_0(i_4, &(l_9), &(spread_8));
        var s_6 : f32 = s_5 * _S83;
        if(s_6 <= 0.0f)
        {
            i_4 = i_4 + i32(1);
            continue;
        }
        var lit_1 : vec3<f32> = color_2 + Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((max((dot(n_7, l_9) + _S74) / (1.0f + _S74), 0.0f) * s_6));
        var _S84 : vec3<f32> = normalize(l_9 + v_3);
        var shrink_0 : f32 = 1.0f + Material_Uniforms_0.light_extra_0[i_4].x;
        var h_3 : vec3<f32>;
        if(spread_8 > 0.0f)
        {
            var shrink_1 : f32 = shrink_0 * widened_0(sqrt(2.0f / _S80), spread_8);
            h_3 = normalize(nearest_in_light_0(l_9, _S78, spread_8) + v_3);
            k_4 = shrink_1;
        }
        else
        {
            h_3 = _S84;
            k_4 = shrink_0;
        }
        var spec_1 : vec3<f32> = lit_0 + Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((pow(max(dot(n_7, h_3), 0.0f), _S79) * shading_0.y * s_6 * k_4));
        color_2 = lit_1;
        lit_0 = spec_1;
        i_4 = i_4 + i32(1);
    }
    var _S85 : f32 = 1.0f - _S56;
    var _S86 : f32 = pow(_S85, 3.0f) * 0.25f;
    if((Material_Uniforms_0.style_0.w) > 0.5f)
    {
        var lit_2 : vec3<f32> = color_2 - vec3<f32>((_S75 * (1.0f - underside_0(n_7, rig_2))));
        k_4 = pow(_S85, 4.0f) * Material_Uniforms_0.style_0.x * mix(0.30000001192092896f, 1.0f, sky_facing_0(n_7, rig_2));
        color_2 = lit_2;
    }
    else
    {
        k_4 = _S86;
    }
    var _S87 : pixelOutput_0 = pixelOutput_0( display_0((albedo_0 * color_2 + (lit_0 + vec3<f32>(k_4)) * vec3<f32>(highlight_0)) * vec3<f32>(relief_0)) );
    return _S87;
}

