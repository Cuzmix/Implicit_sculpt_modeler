// slangc wgsl from textured_layers.frag.spv sha256 762a850bad3fc490ef35da390bdbe7c4e42fe6abdbc3b6d1433d07da0d6d22ab
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

struct SLANG_ParameterGroup_Layer_Uniforms_std140_0
{
    @align(16) layer_rows_0 : array<vec4<f32>, i32(128)>,
};

@binding(2) @group(3) var<uniform> Layer_Uniforms_0 : SLANG_ParameterGroup_Layer_Uniforms_std140_0;
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

fn thin_film_0( c1_0 : f32,  f0_1 : vec3<f32>,  nm_0 : f32,  n2_0 : f32) -> vec3<f32>
{
    var _S17 : f32 = clamp(c1_0, 0.00009999999747379f, 1.0f);
    var s1_0 : f32 = 1.0f - _S17 * _S17;
    var c2_0 : f32 = sqrt(max(1.0f - s1_0 / (n2_0 * n2_0), 0.0f));
    var _S18 : vec3<f32> = vec3<f32>(0.0f);
    var root_0 : vec3<f32> = sqrt(clamp(f0_1, _S18, vec3<f32>(0.98000001907348633f)));
    var _S19 : vec3<f32> = vec3<f32>(1.0f);
    var n3_0 : vec3<f32> = (_S19 + root_0) / (_S19 - root_0);
    var c3_0 : vec3<f32> = sqrt(max(_S19 - vec3<f32>(s1_0) / (n3_0 * n3_0), _S18));
    var _S20 : f32 = n2_0 * c2_0;
    var r12s_0 : f32 = (_S17 - _S20) / (_S17 + _S20);
    var _S21 : f32 = n2_0 * _S17;
    var r12p_0 : f32 = (_S21 - c2_0) / (_S21 + c2_0);
    var _S22 : vec3<f32> = n3_0 * c3_0;
    var _S23 : vec3<f32> = vec3<f32>(_S20);
    var r23s_0 : vec3<f32> = (_S23 - _S22) / (_S23 + _S22);
    var _S24 : vec3<f32> = n3_0 * vec3<f32>(c2_0);
    var _S25 : vec3<f32> = vec3<f32>(n2_0) * c3_0;
    var r23p_0 : vec3<f32> = (_S24 - _S25) / (_S24 + _S25);
    var cs_0 : vec3<f32> = cos(vec3<f32>((12.56637096405029297f * n2_0 * nm_0 * c2_0)) / vec3<f32>(650.0f, 532.0f, 450.0f));
    var _S26 : vec3<f32> = vec3<f32>((r12s_0 * r12s_0));
    var _S27 : vec3<f32> = vec3<f32>((2.0f * r12s_0)) * r23s_0 * cs_0;
    var _S28 : vec3<f32> = vec3<f32>((r12p_0 * r12p_0));
    var _S29 : vec3<f32> = vec3<f32>((2.0f * r12p_0)) * r23p_0 * cs_0;
    return saturate(vec3<f32>(0.5f) * ((_S26 + r23s_0 * r23s_0 + _S27) / (_S19 + _S26 * r23s_0 * r23s_0 + _S27) + (_S28 + r23p_0 * r23p_0 + _S29) / (_S19 + _S28 * r23p_0 * r23p_0 + _S29)));
}

fn area_clamp_0( i_0 : i32,  q_0 : vec2<f32>) -> vec2<f32>
{
    var hw_0 : f32 = Material_Uniforms_0.light_axis_0[i_0].w;
    if((Material_Uniforms_0.light_extra_0[i_0].w) > 0.5f)
    {
        var len_0 : f32 = length(q_0);
        var _S30 : vec2<f32>;
        if(len_0 > hw_0)
        {
            _S30 = q_0 * vec2<f32>((hw_0 / len_0));
        }
        else
        {
            _S30 = q_0;
        }
        return _S30;
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
    var _S31 : f32 = shape_0.w;
    var _S32 : f32 = max(dot(d_0, d_0), _S31 * _S31);
    (*spread_0) = min(_S31 * rsqrt_0(_S32), 1.0f);
    var _S33 : f32 = shape_0.x;
    var k_0 : f32 = _S33 * _S33 / max(_S32, 9.99999993922529029e-09f) * max(dot((vec3<f32>(0) - (*l_1)), f_1), 0.0f);
    var _S34 : f32 = shape_0.y;
    var k_1 : f32;
    if(_S34 > 0.0f)
    {
        var x_2 : f32 = _S32 / (_S34 * _S34);
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
    var _S35 : f32 = min(a_0 + 0.5f * spread_1, 1.0f);
    return a_0 * a_0 / (_S35 * _S35);
}

fn direct_sized_0( n_2 : vec3<f32>,  v_1 : vec3<f32>,  l_2 : vec3<f32>,  ls_0 : vec3<f32>,  spread_2 : f32,  diffuse_0 : vec3<f32>,  f0_2 : vec3<f32>,  a_1 : f32,  shine_0 : f32,  comp_0 : vec3<f32>) -> vec3<f32>
{
    var color_0 : vec3<f32> = diffuse_0 / vec3<f32>(3.14159274101257324f) * vec3<f32>(max(dot(n_2, l_2), 0.0f));
    var _S36 : f32 = max(dot(n_2, ls_0), 0.0f);
    if(_S36 <= 0.0f)
    {
        return color_0;
    }
    var h_1 : vec3<f32> = normalize(ls_0 + v_1);
    var _S37 : f32 = max(dot(n_2, v_1), 0.00009999999747379f);
    var _S38 : f32 = max(dot(n_2, h_1), 0.0f);
    var a2_0 : f32 = a_1 * a_1;
    var d_1 : f32 = _S38 * _S38 * (a2_0 - 1.0f) + 1.0f;
    return color_0 + vec3<f32>((a2_0 / (3.14159274101257324f * d_1 * d_1) * widened_0(a_1, spread_2) * (0.5f / max(mix(2.0f * _S36 * _S37, _S36 + _S37, a_1), 0.00009999999747379f)))) * (f0_2 + (vec3<f32>(1.0f) - f0_2) * vec3<f32>(pow(1.0f - max(dot(v_1, h_1), 0.0f), 5.0f))) * comp_0 * vec3<f32>(_S36) * vec3<f32>(shine_0);
}

fn layer_light_0( n_3 : vec3<f32>,  v_2 : vec3<f32>,  l_3 : vec3<f32>,  sss_albedo_0 : vec3<f32>,  wrap_0 : vec3<f32>,  coat_0 : f32,  coat_a_0 : f32,  coat_f0_0 : f32,  sheen_0 : vec3<f32>,  sheen_a_0 : f32) -> vec3<f32>
{
    var n_dot_l_0 : f32 = dot(n_3, l_3);
    var c_5 : vec3<f32> = sss_albedo_0 / vec3<f32>(3.14159274101257324f) * saturate((vec3<f32>(n_dot_l_0) + wrap_0) / (vec3<f32>(1.0f) + wrap_0));
    if(n_dot_l_0 <= 0.0f)
    {
        return c_5;
    }
    var h_2 : vec3<f32> = normalize(l_3 + v_2);
    var _S39 : f32 = max(dot(n_3, v_2), 0.00009999999747379f);
    var _S40 : f32 = max(dot(n_3, h_2), 0.0f);
    var c_6 : vec3<f32>;
    if(coat_0 > 0.0f)
    {
        var a2_1 : f32 = coat_a_0 * coat_a_0;
        var d_2 : f32 = _S40 * _S40 * (a2_1 - 1.0f) + 1.0f;
        c_6 = c_5 + vec3<f32>((coat_0 * (a2_1 / (3.14159274101257324f * d_2 * d_2)) * (0.5f / max(mix(2.0f * n_dot_l_0 * _S39, n_dot_l_0 + _S39, coat_a_0), 0.00009999999747379f)) * (coat_f0_0 + (1.0f - coat_f0_0) * pow(1.0f - max(dot(v_2, h_2), 0.0f), 5.0f)) * n_dot_l_0));
    }
    else
    {
        c_6 = c_5;
    }
    if((any((sheen_0 > vec3<f32>(0.0f)))))
    {
        var inv_0 : f32 = 1.0f / sheen_a_0;
        c_6 = c_6 + sheen_0 * vec3<f32>(((2.0f + inv_0) * pow(max(1.0f - _S40 * _S40, 0.0f), 0.5f * inv_0) / 6.28318548202514648f / (4.0f * (n_dot_l_0 + _S39 - n_dot_l_0 * _S39)) * n_dot_l_0));
    }
    return c_6;
}

fn light_at_0( i_3 : i32,  l_4 : ptr<function, vec3<f32>>,  spread_3 : ptr<function, f32>) -> f32
{
    var p_1 : vec4<f32> = Material_Uniforms_0.light_pos_0[i_3];
    var shape_1 : vec4<f32> = Material_Uniforms_0.light_shape_0[i_3];
    var _S41 : f32 = Material_Uniforms_0.light_pos_0[i_3].w;
    if(_S41 < 0.5f)
    {
        (*l_4) = p_1.xyz;
        (*spread_3) = shape_1.w;
        return 1.0f;
    }
    var d_3 : vec3<f32> = p_1.xyz - frag_in_0.view_pos_0;
    var _S42 : f32 = max(dot(d_3, d_3), 9.99999993922529029e-09f);
    var inv_1 : f32 = rsqrt_0(_S42);
    (*l_4) = d_3 * vec3<f32>(inv_1);
    (*spread_3) = min(shape_1.w * inv_1, 1.0f);
    var _S43 : f32 = shape_1.x;
    var k_2 : f32 = _S43 * _S43 / _S42;
    var _S44 : f32 = shape_1.y;
    var k_3 : f32;
    if(_S44 > 0.0f)
    {
        var x_3 : f32 = _S42 / (_S44 * _S44);
        var w_3 : f32 = clamp(1.0f - x_3 * x_3, 0.0f, 1.0f);
        k_3 = k_2 * (w_3 * w_3);
    }
    else
    {
        k_3 = k_2;
    }
    if(_S41 > 1.5f)
    {
        k_3 = k_3 * smoothstep(Material_Uniforms_0.light_spot_0[i_3].w, shape_1.z, dot((vec3<f32>(0) - (*l_4)), Material_Uniforms_0.light_spot_0[i_3].xyz));
    }
    return k_3;
}

fn nearest_in_light_0( l_5 : vec3<f32>,  r_4 : vec3<f32>,  spread_4 : f32) -> vec3<f32>
{
    var cos_r_0 : f32 = sqrt(max(1.0f - spread_4 * spread_4, 0.0f));
    var l_dot_r_0 : f32 = dot(l_5, r_4);
    if(l_dot_r_0 >= cos_r_0)
    {
        return r_4;
    }
    var s_0 : vec3<f32> = r_4 - vec3<f32>(l_dot_r_0) * l_5;
    var s2_0 : f32 = dot(s_0, s_0);
    if(s2_0 < 9.999999960041972e-13f)
    {
        return l_5;
    }
    return normalize(l_5 * vec3<f32>(cos_r_0) + s_0 * vec3<f32>((rsqrt_0(s2_0) * spread_4)));
}

fn direct_0( n_4 : vec3<f32>,  v_3 : vec3<f32>,  l_6 : vec3<f32>,  diffuse_1 : vec3<f32>,  f0_3 : vec3<f32>,  a_2 : f32,  shine_1 : f32,  comp_1 : vec3<f32>) -> vec3<f32>
{
    var _S45 : f32 = max(dot(n_4, l_6), 0.0f);
    if(_S45 <= 0.0f)
    {
        return vec3<f32>(0.0f);
    }
    var h_3 : vec3<f32> = normalize(l_6 + v_3);
    var _S46 : f32 = max(dot(n_4, v_3), 0.00009999999747379f);
    var _S47 : f32 = max(dot(n_4, h_3), 0.0f);
    var a2_2 : f32 = a_2 * a_2;
    var d_4 : f32 = _S47 * _S47 * (a2_2 - 1.0f) + 1.0f;
    return (diffuse_1 / vec3<f32>(3.14159274101257324f) + vec3<f32>((a2_2 / (3.14159274101257324f * d_4 * d_4) * (0.5f / max(mix(2.0f * _S45 * _S46, _S45 + _S46, a_2), 0.00009999999747379f)))) * (f0_3 + (vec3<f32>(1.0f) - f0_3) * vec3<f32>(pow(1.0f - max(dot(v_3, h_3), 0.0f), 5.0f))) * comp_1 * vec3<f32>(shine_1)) * vec3<f32>(_S45);
}

fn env_brdf_0( n_dot_v_0 : f32,  rough_0 : f32) -> vec2<f32>
{
    var r_5 : vec4<f32> = vec4<f32>(rough_0) * vec4<f32>(-1.0f, -0.02749999985098839f, -0.57200002670288086f, 0.02199999988079071f) + vec4<f32>(1.0f, 0.04250000044703484f, 1.03999996185302734f, -0.03999999910593033f);
    var _S48 : f32 = r_5.x;
    return vec2<f32>(-1.03999996185302734f, 1.03999996185302734f) * vec2<f32>((min(_S48 * _S48, exp2(-9.27999973297119141f * n_dot_v_0)) * _S48 + r_5.y)) + r_5.zw;
}

fn irradiance_0( n_5 : vec3<f32>) -> vec3<f32>
{
    var d_5 : vec3<f32> = (((transpose(mat3x3<f32>(Material_Uniforms_0.env_x_0.xyz, Material_Uniforms_0.env_y_0.xyz, Material_Uniforms_0.env_z_0.xyz))) * (n_5)));
    var _S49 : f32 = d_5.y;
    var _S50 : f32 = d_5.z;
    var _S51 : f32 = d_5.x;
    var _S52 : f32 = 1.09254801273345947f * _S51;
    return max(Material_Uniforms_0.env_sh_0[i32(0)].xyz * vec3<f32>(0.28209498524665833f) + Material_Uniforms_0.env_sh_0[i32(1)].xyz * vec3<f32>((0.48860299587249756f * _S49)) + Material_Uniforms_0.env_sh_0[i32(2)].xyz * vec3<f32>((0.48860299587249756f * _S50)) + Material_Uniforms_0.env_sh_0[i32(3)].xyz * vec3<f32>((0.48860299587249756f * _S51)) + Material_Uniforms_0.env_sh_0[i32(4)].xyz * vec3<f32>((_S52 * _S49)) + Material_Uniforms_0.env_sh_0[i32(5)].xyz * vec3<f32>((1.09254801273345947f * _S49 * _S50)) + Material_Uniforms_0.env_sh_0[i32(6)].xyz * vec3<f32>((0.31539198756217957f * (3.0f * _S50 * _S50 - 1.0f))) + Material_Uniforms_0.env_sh_0[i32(7)].xyz * vec3<f32>((_S52 * _S50)) + Material_Uniforms_0.env_sh_0[i32(8)].xyz * vec3<f32>((0.54627400636672974f * (_S51 * _S51 - _S49 * _S49))), vec3<f32>(0.0f)) * vec3<f32>(Material_Uniforms_0.env_0.y);
}

fn lobe_0( dir_0 : vec3<f32>,  toward_0 : vec3<f32>,  color_1 : vec3<f32>,  sharp_0 : f32,  rough_1 : f32) -> vec3<f32>
{
    var e_0 : f32 = mix(sharp_0, 3.0f, sqrt(rough_1));
    return color_1 * vec3<f32>(pow(max(dot(dir_0, toward_0), 0.0f), e_0)) * vec3<f32>((e_0 + 2.0f)) / vec3<f32>((sharp_0 + 2.0f));
}

fn studio_0( dir_1 : vec3<f32>,  rough_2 : f32) -> vec3<f32>
{
    var w_4 : f32 = 0.07999999821186066f + 0.89999997615814209f * rough_2;
    var _S53 : f32 = dir_1.y;
    return mix(vec3<f32>(0.07000000029802322f, 0.06499999761581421f, 0.05999999865889549f), vec3<f32>(0.40000000596046448f, 0.43000000715255737f, 0.47999998927116394f), vec3<f32>(smoothstep(- w_4, w_4, _S53))) + vec3<f32>(0.12999999523162842f, 0.11999999731779099f, 0.10999999940395355f) * vec3<f32>(exp(- abs(_S53) / (0.05999999865889549f + 0.5f * rough_2))) + lobe_0(dir_1, vec3<f32>(-0.65590423345565796f, 0.7433580756187439f, 0.13118083775043488f), vec3<f32>(4.0f, 3.79999995231628418f, 3.5f), 300.0f, rough_2) + lobe_0(dir_1, vec3<f32>(0.84478187561035156f, 0.32852628827095032f, -0.42239093780517578f), vec3<f32>(1.60000002384185791f, 1.79999995231628418f, 2.09999990463256836f), 600.0f, rough_2) + lobe_0(dir_1, vec3<f32>(0.09396819770336151f, -0.32888868451118469f, 0.93968194723129272f), vec3<f32>(0.5f, 0.5f, 0.5f), 4.0f, rough_2);
}

fn sky_facing_0( n_6 : vec3<f32>,  rig_0 : mat3x3<f32>) -> f32
{
    return 0.5f + 0.5f * dot(n_6, rig_0[i32(1)]);
}

fn underside_0( n_7 : vec3<f32>,  rig_1 : mat3x3<f32>) -> f32
{
    return mix(Material_Uniforms_0.style_0.y, 1.0f, sky_facing_0(n_7, rig_1));
}

fn panorama_uv_0( d_6 : vec3<f32>) -> vec2<f32>
{
    return vec2<f32>(atan2(d_6.x, - d_6.z - 9.99999968265522539e-21f) * 0.15915493667125702f + 0.5f, acos(clamp(d_6.y, -1.0f, 1.0f)) * 0.31830990314483643f);
}

fn reflected_0( dir_2 : vec3<f32>,  rough_3 : f32,  to_rig_0 : mat3x3<f32>) -> vec3<f32>
{
    if((Material_Uniforms_0.env_0.x) > 0.5f)
    {
        return (textureSampleLevel((environment_map_texture_0), (environment_map_sampler_0), (panorama_uv_0((((transpose(mat3x3<f32>(Material_Uniforms_0.env_x_0.xyz, Material_Uniforms_0.env_y_0.xyz, Material_Uniforms_0.env_z_0.xyz))) * (dir_2))))), (rough_3 * Material_Uniforms_0.env_0.z))).xyz * vec3<f32>(Material_Uniforms_0.env_0.y);
    }
    return studio_0((((to_rig_0) * (dir_2))), rough_3);
}

fn tone_map_0( c_7 : vec3<f32>) -> vec3<f32>
{
    var _S54 : f32 = min(c_7.x, min(c_7.y, c_7.z));
    var offset_0 : f32;
    if(_S54 < 0.07999999821186066f)
    {
        offset_0 = _S54 - 6.25f * _S54 * _S54;
    }
    else
    {
        offset_0 = 0.03999999910593033f;
    }
    var _S55 : vec3<f32> = c_7 - vec3<f32>(offset_0);
    var _S56 : f32 = max(_S55.x, max(_S55.y, _S55.z));
    if(_S56 < 0.75999999046325684f)
    {
        return _S55;
    }
    var new_peak_0 : f32 = 1.0f - 0.0576000027358532f / (_S56 + 0.24000000953674316f - 0.75999999046325684f);
    return mix(_S55 * vec3<f32>((new_peak_0 / _S56)), vec3<f32>(new_peak_0), vec3<f32>((1.0f - 1.0f / (0.15000000596046448f * (_S56 - new_peak_0) + 1.0f))));
}

fn display_color_0( c_8 : vec3<f32>,  stops_0 : f32) -> vec3<f32>
{
    return srgb_encode_0(tone_map_0(c_8 * vec3<f32>(exp2(stops_0))));
}

fn display_0( c_9 : vec3<f32>) -> vec4<f32>
{
    return vec4<f32>(display_color_0(c_9, Material_Uniforms_0.look_0.x), opacity_0());
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
fn main( _S57 : pixelInput_0, @builtin(position) position_0 : vec4<f32>, @builtin(front_facing) is_front_0 : bool) -> pixelOutput_0
{
    frag_in_0.view_normal_0 = _S57.view_normal_1;
    frag_in_0.view_pos_0 = _S57.view_pos_1;
    frag_in_0.mask_0 = _S57.mask_1;
    frag_in_0.paint_0 = _S57.paint_1;
    frag_in_0.group_0 = _S57.group_1;
    frag_in_0.mesh_pos_0 = _S57.mesh_pos_1;
    frag_in_0.slot_0 = _S57.slot_1;
    frag_in_0.uv_0 = _S57.uv_3;
    frag_in_0.view_tangent_0 = _S57.view_tangent_1;
    frag_in_0.material_0 = _S57.material_1;
    frag_coord_0 = position_0;
    front_facing_0 = is_front_0;
    if((Material_Uniforms_0.params_0.y) < 0.0f)
    {
        var _S58 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0(Material_Uniforms_0.base_color_0.xyz), 1.0f) );
        return _S58;
    }
    var base_0 : vec4<f32> = Material_Uniforms_0.base_color_0;
    var shading_0 : vec4<f32> = Material_Uniforms_0.params_0;
    var surf_1 : vec4<f32> = Material_Uniforms_0.surface_0;
    var v_4 : vec3<f32>;
    if((Material_Uniforms_0.env_0.w) > 0.5f)
    {
        v_4 = vec3<f32>(0.0f, 0.0f, 1.0f);
    }
    else
    {
        v_4 = normalize((vec3<f32>(0) - frag_in_0.view_pos_0));
    }
    var view_mode_0 : i32 = i32(Material_Uniforms_0.maps_0.w + 0.5f);
    var uv_4 : vec2<f32> = vec2<f32>(frag_in_0.uv_0.x, 1.0f - frag_in_0.uv_0.y);
    var nv_0 : vec3<f32> = frag_in_0.view_normal_0;
    var tv_0 : vec3<f32> = frag_in_0.view_tangent_0.xyz;
    var _S59 : vec3<f32> = normalize(frag_in_0.view_normal_0);
    var _S60 : bool = view_mode_0 == i32(1);
    var _S61 : bool;
    if(_S60)
    {
        _S61 = true;
    }
    else
    {
        _S61 = view_mode_0 == i32(2);
    }
    var n_8 : vec3<f32>;
    if(_S61)
    {
        var tn_0 : vec3<f32>;
        if((Material_Uniforms_0.maps_0.z) > 0.5f)
        {
            ;
            n_8 = (textureSample((normal_map_texture_0), (normal_map_sampler_0), (uv_4))).xyz * vec3<f32>(2.0f) - vec3<f32>(1.0f);
        }
        else
        {
            n_8 = vec3<f32>(0.0f, 0.0f, 1.0f);
        }
        tn_0 = n_8;
        var slope_0 : vec2<f32> = paint_height_slope_0(uv_4);
        var _S62 : vec2<f32> = n_8.xy - slope_0;
        tn_0.x = _S62.x;
        tn_0.y = _S62.y;
        if((Material_Uniforms_0.maps_0.z) > 0.5f)
        {
            _S61 = true;
        }
        else
        {
            _S61 = (any((slope_0 != vec2<f32>(0.0f))));
        }
        if(_S61)
        {
            var mapped_0 : vec3<f32> = vec3<f32>(tn_0.x) * tv_0 + vec3<f32>(tn_0.y) * (vec3<f32>(frag_in_0.view_tangent_0.w) * cross(nv_0, tv_0)) + vec3<f32>(tn_0.z) * nv_0;
            if((dot(mapped_0, mapped_0)) > 0.0f)
            {
                n_8 = normalize(mapped_0);
            }
            else
            {
                n_8 = _S59;
            }
        }
        else
        {
            n_8 = _S59;
        }
    }
    else
    {
        n_8 = _S59;
    }
    if(!front_facing_0)
    {
        n_8 = (vec3<f32>(0) - n_8);
    }
    if(_S60)
    {
        _S61 = (Material_Uniforms_0.maps_0.y) > 0.5f;
    }
    else
    {
        _S61 = false;
    }
    var ao_0 : f32;
    if(_S61)
    {
        ;
        var orm_0 : vec3<f32> = (textureSample((orm_map_texture_0), (orm_map_sampler_0), (uv_4))).xyz;
        var _S63 : f32 = orm_0.x;
        surf_1[i32(0)] = orm_0.z;
        surf_1[i32(1)] = max(orm_0.y, 0.03999999910593033f);
        ao_0 = _S63;
    }
    else
    {
        ao_0 = 1.0f;
    }
    if(_S60)
    {
        _S61 = (surf_1.y) > 0.0f;
    }
    else
    {
        _S61 = false;
    }
    if(_S61)
    {
        var _S64 : vec2<f32> = paint_surface_0(surf_1.xy, frag_in_0.material_0);
        surf_1.x = _S64.x;
        surf_1.y = _S64.y;
        ;
        var _S65 : vec4<f32> = (textureSample((paint_material_map_texture_0), (paint_material_map_sampler_0), (uv_4)));
        surf_1[i32(0)] = surf_1.x * (1.0f - _S65.w) + _S65.z;
        surf_1[i32(1)] = max(surf_1.y * (1.0f - _S65.y) + _S65.x, 0.03999999910593033f);
    }
    var dndx_0 : vec3<f32> = dpdx(n_8);
    var dndy_0 : vec3<f32> = dpdy(n_8);
    var bend_0 : f32 = curvature_0(n_8, frag_in_0.view_pos_0);
    var _S66 : i32 = i32(Material_Uniforms_0.pass_0.x + 0.5f);
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
            view_pass_0 = _S66;
        }
    }
    else
    {
        view_pass_0 = _S66;
    }
    if(view_pass_0 != i32(0))
    {
        _S61 = view_pass_0 != i32(7);
    }
    else
    {
        _S61 = false;
    }
    var shown_0 : vec3<f32>;
    var k_4 : f32;
    if(_S61)
    {
        if(view_pass_0 == i32(1))
        {
            var _S67 : vec3<f32> = vec3<f32>(0.5f);
            shown_0 = n_8 * _S67 + _S67;
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
                        k_4 = k_5 * smoothstep(0.10000000149011612f, 0.40000000596046448f, max(dot(n_8, v_4), 0.0f));
                    }
                    else
                    {
                        k_4 = k_5;
                    }
                    var _S68 : vec3<f32> = vec3<f32>(0.5f);
                    if(k_4 < 0.0f)
                    {
                        v_4 = vec3<f32>(0.15000000596046448f, 0.34999999403953552f, 0.85000002384185791f);
                    }
                    else
                    {
                        v_4 = vec3<f32>(0.94999998807907104f, 0.55000001192092896f, 0.15000000596046448f);
                    }
                    shown_0 = mix(_S68, v_4, vec3<f32>(abs(k_4)));
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
                            shown_0 = skin_detail_color_0(n_8, v_4);
                        }
                        else
                        {
                            shown_0 = vec3<f32>(0.05999999865889549f);
                        }
                    }
                }
            }
        }
        var _S69 : pixelOutput_0 = pixelOutput_0( vec4<f32>(shown_0, opacity_0()) );
        return _S69;
    }
    var _S70 : f32 = dot(n_8, v_4);
    var _S71 : f32 = max(_S70, 0.0f);
    var relief_0 : f32 = (1.0f - 0.75f * (Material_Uniforms_0.look_0.y * smoothstep(0.01999999955296516f, 0.23999999463558197f, - bend_0))) * (1.0f + 0.60000002384185791f * (Material_Uniforms_0.look_0.z * smoothstep(0.01999999955296516f, 0.23999999463558197f, bend_0) * smoothstep(0.10000000149011612f, 0.40000000596046448f, _S71)));
    var _S72 : vec3<f32> = base_0.xyz;
    var _S73 : vec3<f32> = mix(_S72, frag_in_0.paint_0.xyz, vec3<f32>(frag_in_0.paint_0.w));
    if((frag_in_0.group_0.x) >= 0.0f)
    {
        shown_0 = frag_in_0.group_0;
    }
    else
    {
        shown_0 = _S73;
    }
    if(_S60)
    {
        _S61 = (Material_Uniforms_0.maps_0.x) > 0.5f;
    }
    else
    {
        _S61 = false;
    }
    if(_S61)
    {
        ;
        shown_0 = _S72 * (textureSample((base_map_texture_0), (base_map_sampler_0), (uv_4))).xyz;
    }
    if(_S60)
    {
        ;
        var _S74 : vec4<f32> = (textureSample((paint_map_texture_0), (paint_map_sampler_0), (uv_4)));
        shown_0 = shown_0 * vec3<f32>((1.0f - _S74.w)) + _S74.xyz;
    }
    if(view_mode_0 == i32(3))
    {
        shown_0 = shown_0 * uv_checker_0(uv_4);
    }
    if((Material_Uniforms_0.fade_0.w) > 0.0f)
    {
        _S61 = (frag_in_0.group_0.x) < 0.0f;
    }
    else
    {
        _S61 = false;
    }
    if(_S61)
    {
        shown_0 = mix(shown_0, Material_Uniforms_0.fade_0.xyz, vec3<f32>(Material_Uniforms_0.fade_0.w));
    }
    if((Material_Uniforms_0.checker_0.w) > 0.0f)
    {
        var c_10 : vec3<f32> = (frag_in_0.mesh_pos_0 - Material_Uniforms_0.checker_0.xyz) / vec3<f32>(Material_Uniforms_0.checker_0.w);
        var width_1 : vec3<f32> = max((fwidth((c_10))), vec3<f32>(9.99999997475242708e-07f));
        var _S75 : f32 = max(max(width_1.x, width_1.y), width_1.z);
        var f_3 : vec3<f32> = fract(c_10);
        var edge_1 : vec3<f32> = min(f_3, vec3<f32>(1.0f) - f_3) / width_1;
        var cell_1 : vec3<f32> = floor(c_10);
        shown_0 = shown_0 * vec3<f32>(mix(mix(1.0f, 0.72000002861022949f, glsl_mod_0(cell_1.x + cell_1.y + cell_1.z, 2.0f)) * (1.0f - 0.34999999403953552f * ((1.0f - smoothstep(0.5f, 1.5f, min(min(edge_1.x, edge_1.y), edge_1.z))) * (1.0f - smoothstep(0.0625f, 0.125f, _S75)))), 0.86000001430511475f, smoothstep(0.20000000298023224f, 0.40000000596046448f, _S75)));
    }
    var rig_2 : mat3x3<f32> = mat3x3<f32>(Material_Uniforms_0.light_x_0.xyz, Material_Uniforms_0.light_y_0.xyz, Material_Uniforms_0.light_z_0.xyz);
    var ambient_0 : f32 = Material_Uniforms_0.light_x_0.w;
    var shown_mask_0 : f32 = frag_in_0.mask_0 * (1.0f - Material_Uniforms_0.style_0.z);
    var albedo_0 : vec3<f32> = shown_0 * vec3<f32>((1.0f - 0.69999998807907104f * shown_mask_0));
    var highlight_0 : f32 = 1.0f - 0.5f * shown_mask_0;
    if(view_pass_0 == i32(7))
    {
        var _S76 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0(albedo_0 * vec3<f32>(relief_0) * vec3<f32>(exp2(Material_Uniforms_0.look_0.x))), opacity_0()) );
        return _S76;
    }
    if((surf_1.w) > 0.5f)
    {
        var k_6 : f32 = 1.0f / (1.0f + v_4.z);
        var _S77 : f32 = v_4.x;
        var _S78 : f32 = - _S77;
        var _S79 : f32 = v_4.y;
        var b_0 : f32 = _S78 * _S79 * k_6;
        var _S80 : vec2<f32> = vec2<f32>(0.5f + 0.49599999189376831f * dot(vec3<f32>(1.0f - _S77 * _S77 * k_6, b_0, _S78), n_8), 0.5f - 0.49599999189376831f * dot(vec3<f32>(b_0, 1.0f - _S79 * _S79 * k_6, - _S79), n_8));
        ;
        var _S81 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0((textureSample((matcap_texture_0), (matcap_sampler_0), (_S80))).xyz * albedo_0 * vec3<f32>(relief_0) * vec3<f32>(exp2(Material_Uniforms_0.look_0.x))), opacity_0()) );
        return _S81;
    }
    var f0_4 : vec3<f32>;
    var color_2 : vec3<f32>;
    var lit_0 : vec3<f32>;
    var i_4 : i32;
    if((surf_1.y) > 0.0f)
    {
        var metallic_0 : f32 = clamp(surf_1.x, 0.0f, 1.0f);
        var a_3 : f32 = surf_1.y * surf_1.y;
        var rough_4 : f32 = clamp(sqrt(sqrt(clamp(a_3 * a_3 + min(2.0f * (0.25f * (dot(dndx_0, dndx_0) + dot(dndy_0, dndy_0))), 0.18000000715255737f), 0.0f, 1.0f))), 0.03999999910593033f, 1.0f);
        var _S82 : f32 = rough_4 * rough_4;
        var _S83 : f32 = 1.0f - metallic_0;
        var diffuse_2 : vec3<f32> = albedo_0 * vec3<f32>(_S83);
        var _S84 : f32 = max(_S70, 0.00009999999747379f);
        var _S85 : vec3<f32> = (vec3<f32>(0) - v_4);
        var r_6 : vec3<f32> = reflect(_S85, n_8);
        var L0_0 : vec4<f32> = Layer_Uniforms_0.layer_rows_0[u32(0)];
        var L1_0 : vec4<f32> = Layer_Uniforms_0.layer_rows_0[u32(1)];
        var L2_0 : vec4<f32> = Layer_Uniforms_0.layer_rows_0[u32(2)];
        var L3_0 : vec4<f32> = Layer_Uniforms_0.layer_rows_0[u32(3)];
        var L4_0 : vec4<f32> = Layer_Uniforms_0.layer_rows_0[u32(4)];
        var L5_0 : vec4<f32> = Layer_Uniforms_0.layer_rows_0[u32(5)];
        var L6_0 : vec4<f32> = Layer_Uniforms_0.layer_rows_0[u32(6)];
        var L7_0 : vec4<f32> = Layer_Uniforms_0.layer_rows_0[u32(7)];
        var _S86 : f32 = Layer_Uniforms_0.layer_rows_0[u32(2)].w;
        var r0_0 : f32 = (_S86 - 1.0f) / (_S86 + 1.0f);
        var f0_5 : vec3<f32> = mix(vec3<f32>((r0_0 * r0_0 * (1.0f - Layer_Uniforms_0.layer_rows_0[u32(7)].w))), albedo_0, vec3<f32>(metallic_0));
        var _S87 : f32 = Layer_Uniforms_0.layer_rows_0[u32(7)].x;
        if(_S87 > 0.0f)
        {
            f0_4 = mix(f0_5, thin_film_0(_S84, f0_5, L7_0.y, L7_0.z), vec3<f32>(_S87));
        }
        else
        {
            f0_4 = f0_5;
        }
        var _S88 : vec3<f32> = energy_compensation_0(f0_4, _S84, rough_4);
        var sss_0 : f32 = L0_0.w * _S83;
        var trans_0 : f32 = L5_0.w * _S83;
        var _S89 : f32 = 1.0f - trans_0;
        var sss_albedo_1 : vec3<f32> = albedo_0 * L0_0.xyz * vec3<f32>((sss_0 * _S89));
        var _S90 : vec3<f32> = saturate(L1_0.xyz * vec3<f32>((abs(bend_0) / max(length(dpdx(frag_in_0.view_pos_0)), 9.99999997475242708e-07f))));
        var diffuse_3 : vec3<f32> = diffuse_2 * vec3<f32>(((1.0f - sss_0) * _S89));
        var coat_1 : f32 = L2_0.x;
        var _S91 : f32 = L2_0.y;
        var _S92 : f32 = max(_S91 * _S91, 0.00100000004749745f);
        var _S93 : f32 = L2_0.z;
        var c0_0 : f32 = (_S93 - 1.0f) / (_S93 + 1.0f);
        var coat_f0_1 : f32 = c0_0 * c0_0;
        var _S94 : f32 = pow(1.0f - _S84, 5.0f);
        var sheen_1 : vec3<f32> = L3_0.xyz * vec3<f32>(L3_0.w);
        var _S95 : f32 = L6_0.z;
        var _S96 : f32 = max(_S95 * _S95, 0.00100000004749745f);
        var under_0 : f32 = 1.0f - coat_1 * (coat_f0_1 + (1.0f - coat_f0_1) * _S94);
        var _S97 : vec3<f32> = vec3<f32>(0.0f);
        i_4 = i32(0);
        color_2 = _S97;
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
                _S61 = true;
            }
            else
            {
                _S61 = (Material_Uniforms_0.light_pos_0[i_4].w) < 2.5f;
            }
            if(_S61)
            {
                i_4 = i_4 + i32(1);
                continue;
            }
            var l_7 : vec3<f32>;
            var spread_5 : f32;
            var k_7 : f32 = area_at_0(i_4, &(l_7), &(spread_5));
            if(k_7 <= 0.0f)
            {
                i_4 = i_4 + i32(1);
                continue;
            }
            color_2 = color_2 + (direct_sized_0(n_8, v_4, l_7, area_mirror_0(i_4, r_6), spread_5, diffuse_3, f0_4, _S82, 1.0f + Material_Uniforms_0.light_extra_0[i_4].x, _S88) * vec3<f32>(under_0) + layer_light_0(n_8, v_4, l_7, sss_albedo_1, _S90, coat_1, _S92, coat_f0_1, sheen_1, _S96)) * Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((3.0f * (s_1 * k_7)));
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
                _S61 = true;
            }
            else
            {
                _S61 = (Material_Uniforms_0.light_pos_0[i_4].w) > 2.5f;
            }
            if(_S61)
            {
                i_4 = i_4 + i32(1);
                continue;
            }
            var l_8 : vec3<f32>;
            var spread_6 : f32;
            var k_8 : f32 = light_at_0(i_4, &(l_8), &(spread_6));
            if(k_8 <= 0.0f)
            {
                i_4 = i_4 + i32(1);
                continue;
            }
            var shine_2 : f32 = 1.0f + Material_Uniforms_0.light_extra_0[i_4].x;
            if(spread_6 > 0.0f)
            {
                lit_0 = direct_sized_0(n_8, v_4, l_8, nearest_in_light_0(l_8, r_6, spread_6), spread_6, diffuse_3, f0_4, _S82, shine_2, _S88);
            }
            else
            {
                lit_0 = direct_0(n_8, v_4, l_8, diffuse_3, f0_4, _S82, shine_2, _S88);
            }
            color_2 = color_2 + (lit_0 * vec3<f32>(under_0) + layer_light_0(n_8, v_4, l_8, sss_albedo_1, _S90, coat_1, _S92, coat_f0_1, sheen_1, _S96)) * Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((3.0f * (s_2 * k_8)));
            i_4 = i_4 + i32(1);
        }
        var ab_0 : vec2<f32> = env_brdf_0(_S84, rough_4);
        var to_rig_1 : mat3x3<f32> = transpose(rig_2);
        if((Material_Uniforms_0.env_0.x) > 0.5f)
        {
            color_2 = color_2 + diffuse_3 * irradiance_0(n_8) * vec3<f32>(ao_0);
        }
        else
        {
            if((Material_Uniforms_0.style_0.w) > 0.5f)
            {
                color_2 = color_2 + diffuse_3 * studio_0((((to_rig_1) * (n_8))), 1.0f) * vec3<f32>((0.69999998807907104f * ao_0 * ambient_0 * underside_0(n_8, rig_2)));
            }
            else
            {
                color_2 = color_2 + diffuse_3 * studio_0((((to_rig_1) * (n_8))), 1.0f) * vec3<f32>((0.69999998807907104f * ao_0 * ambient_0));
            }
        }
        var _S98 : f32 = ab_0.x;
        var _S99 : f32 = ab_0.y;
        var _S100 : vec3<f32> = vec3<f32>((highlight_0 * ao_0));
        var color_3 : vec3<f32> = color_2 + reflected_0(r_6, rough_4, to_rig_1) * ((f0_4 * vec3<f32>(_S98) + vec3<f32>(_S99)) * (vec3<f32>(1.0f) + f0_4 * vec3<f32>((1.0f / max(_S98 + _S99, 0.05000000074505806f) - 1.0f)))) * _S100;
        if((Material_Uniforms_0.env_0.x) > 0.5f)
        {
            lit_0 = irradiance_0(n_8) * vec3<f32>(ao_0);
        }
        else
        {
            lit_0 = studio_0((((to_rig_1) * (n_8))), 1.0f) * vec3<f32>((0.69999998807907104f * ao_0 * ambient_0));
        }
        var coat_rough_0 : f32 = sqrt(_S92);
        var cab_0 : vec2<f32> = env_brdf_0(_S84, coat_rough_0);
        var color_4 : vec3<f32> = color_3 * vec3<f32>(under_0) + (sss_albedo_1 + vec3<f32>(0.20000000298023224f) * sheen_1) * lit_0 + reflected_0(r_6, coat_rough_0, to_rig_1) * vec3<f32>(((coat_f0_1 * cab_0.x + cab_0.y) * coat_1)) * _S100;
        var _S101 : bool = trans_0 > 0.0f;
        if(_S101)
        {
            _S61 = (Material_Uniforms_0.look_0.w) <= 0.0f;
        }
        else
        {
            _S61 = false;
        }
        if(_S61)
        {
            var bent_0 : vec3<f32> = refract(_S85, n_8, 1.0f / max(_S86, 1.0f));
            var bent_1 : vec3<f32>;
            if((dot(bent_0, bent_0)) <= 0.0f)
            {
                bent_1 = r_6;
            }
            else
            {
                bent_1 = bent_0;
            }
            var _S102 : f32 = f0_4.y;
            color_2 = color_4 + reflected_0(bent_1, rough_4, to_rig_1) * L5_0.xyz * vec3<f32>((trans_0 * (1.0f - (_S102 + (1.0f - _S102) * _S94)) * ao_0));
        }
        else
        {
            color_2 = color_4;
        }
        var shown_1 : vec4<f32> = display_0(color_2 * vec3<f32>(relief_0) + L4_0.xyz * vec3<f32>(L4_0.w));
        if(_S101)
        {
            var _S103 : f32 = f0_4.y;
            shown_1[i32(3)] = mix(shown_1.w, 1.0f, _S103 + (1.0f - _S103) * _S94);
        }
        var _S104 : pixelOutput_0 = pixelOutput_0( shown_1 );
        return _S104;
    }
    var _S105 : f32 = shading_0.w;
    var _S106 : f32 = shading_0.x * ao_0 * ambient_0;
    var _S107 : vec3<f32> = vec3<f32>(_S106);
    var _S108 : vec3<f32> = vec3<f32>(0.0f);
    var _S109 : vec3<f32> = reflect((vec3<f32>(0) - v_4), n_8);
    var _S110 : f32 = shading_0.z;
    var _S111 : f32 = _S110 + 2.0f;
    var _S112 : f32 = sqrt(2.0f / _S111);
    i_4 = i32(0);
    f0_4 = _S107;
    color_2 = _S108;
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
            _S61 = true;
        }
        else
        {
            _S61 = (Material_Uniforms_0.light_pos_0[i_4].w) < 2.5f;
        }
        if(_S61)
        {
            i_4 = i_4 + i32(1);
            continue;
        }
        var l_9 : vec3<f32>;
        var spread_7 : f32;
        var _S113 : f32 = area_at_0(i_4, &(l_9), &(spread_7));
        var s_4 : f32 = s_3 * _S113;
        if(s_4 <= 0.0f)
        {
            i_4 = i_4 + i32(1);
            continue;
        }
        var spec_0 : vec3<f32> = color_2 + Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((pow(max(dot(n_8, normalize(area_mirror_0(i_4, _S109) + v_4)), 0.0f), _S110) * shading_0.y * s_4 * ((1.0f + Material_Uniforms_0.light_extra_0[i_4].x) * widened_0(_S112, spread_7))));
        f0_4 = f0_4 + Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((max((dot(n_8, l_9) + _S105) / (1.0f + _S105), 0.0f) * s_4));
        color_2 = spec_0;
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
            _S61 = true;
        }
        else
        {
            _S61 = (Material_Uniforms_0.light_pos_0[i_4].w) > 2.5f;
        }
        if(_S61)
        {
            i_4 = i_4 + i32(1);
            continue;
        }
        var l_10 : vec3<f32>;
        var spread_8 : f32;
        var _S114 : f32 = light_at_0(i_4, &(l_10), &(spread_8));
        var s_6 : f32 = s_5 * _S114;
        if(s_6 <= 0.0f)
        {
            i_4 = i_4 + i32(1);
            continue;
        }
        var lit_1 : vec3<f32> = f0_4 + Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((max((dot(n_8, l_10) + _S105) / (1.0f + _S105), 0.0f) * s_6));
        var _S115 : vec3<f32> = normalize(l_10 + v_4);
        var shrink_0 : f32 = 1.0f + Material_Uniforms_0.light_extra_0[i_4].x;
        if(spread_8 > 0.0f)
        {
            var shrink_1 : f32 = shrink_0 * widened_0(sqrt(2.0f / _S111), spread_8);
            lit_0 = normalize(nearest_in_light_0(l_10, _S109, spread_8) + v_4);
            k_4 = shrink_1;
        }
        else
        {
            lit_0 = _S115;
            k_4 = shrink_0;
        }
        var spec_1 : vec3<f32> = color_2 + Material_Uniforms_0.light_color_0[i_4].xyz * vec3<f32>((pow(max(dot(n_8, lit_0), 0.0f), _S110) * shading_0.y * s_6 * k_4));
        f0_4 = lit_1;
        color_2 = spec_1;
        i_4 = i_4 + i32(1);
    }
    var _S116 : f32 = 1.0f - _S71;
    var _S117 : f32 = pow(_S116, 3.0f) * 0.25f;
    if((Material_Uniforms_0.style_0.w) > 0.5f)
    {
        var lit_2 : vec3<f32> = f0_4 - vec3<f32>((_S106 * (1.0f - underside_0(n_8, rig_2))));
        k_4 = pow(_S116, 4.0f) * Material_Uniforms_0.style_0.x * mix(0.30000001192092896f, 1.0f, sky_facing_0(n_8, rig_2));
        f0_4 = lit_2;
    }
    else
    {
        k_4 = _S117;
    }
    var _S118 : pixelOutput_0 = pixelOutput_0( display_0((albedo_0 * f0_4 + (color_2 + vec3<f32>(k_4)) * vec3<f32>(highlight_0)) * vec3<f32>(relief_0)) );
    return _S118;
}

