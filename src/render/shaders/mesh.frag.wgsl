// slangc wgsl from mesh.frag.spv sha256 d4d8120905972a1bcc959ce37c782355fb1517b6fa82cabac737710c9a307643
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
    var _S2 : f32;
    if((Material_Uniforms_0.look_0.w) > 0.0f)
    {
        _S2 = Material_Uniforms_0.look_0.w;
    }
    else
    {
        _S2 = 1.0f;
    }
    return _S2;
}

fn glsl_mod_0( x_1 : f32,  y_0 : f32) -> f32
{
    return x_1 - y_0 * floor(x_1 / y_0);
}

fn ggx_albedo_0( mu_0 : f32,  r_0 : f32) -> f32
{
    var _S3 : f32 = clamp(mu_0, 0.02999999932944775f, 1.0f);
    var _S4 : f32 = clamp(r_0, 0.0f, 1.0f);
    return clamp(1.0f - _S4 * _S4 * (3.83702206611633301f + _S3 * (-8.94610023498535156f + _S3 * (-10.02859973907470703f + _S3 * (27.3765106201171875f + _S3 * (-13.70528984069824219f + _S3 * 2.40487289428710938f)))) + _S4 * (-13.97327995300292969f + _S3 * (57.33845138549804688f + _S3 * (-32.69089126586914062f + _S3 * (-23.426849365234375f + _S3 * 6.77839899063110352f))) + _S4 * (14.98353958129882812f + _S3 * (-75.88365936279296875f + _S3 * (71.32111358642578125f + _S3 * 4.00610685348510742f)) + _S4 * (-2.2494659423828125f + _S3 * (25.239959716796875f + _S3 * -33.6537017822265625f) + _S4 * (-3.07003307342529297f + _S3 * 4.50839805603027344f + _S4 * 0.52433747053146362f))))), 0.05000000074505806f, 1.0f);
}

fn energy_compensation_0( f0_0 : vec3<f32>,  mu_1 : f32,  r_1 : f32) -> vec3<f32>
{
    return vec3<f32>(1.0f) + f0_0 * vec3<f32>((1.0f / ggx_albedo_0(mu_1, r_1) - 1.0f));
}

fn light_at_0( i_0 : i32,  l_0 : ptr<function, vec3<f32>>,  spread_0 : ptr<function, f32>) -> f32
{
    var p_1 : vec4<f32> = Material_Uniforms_0.light_pos_0[i_0];
    var shape_0 : vec4<f32> = Material_Uniforms_0.light_shape_0[i_0];
    var _S5 : f32 = Material_Uniforms_0.light_pos_0[i_0].w;
    if(_S5 < 0.5f)
    {
        (*l_0) = p_1.xyz;
        (*spread_0) = shape_0.w;
        return 1.0f;
    }
    var d_0 : vec3<f32> = p_1.xyz - frag_in_0.view_pos_0;
    var _S6 : f32 = max(dot(d_0, d_0), 9.99999993922529029e-09f);
    var inv_0 : f32 = rsqrt_0(_S6);
    (*l_0) = d_0 * vec3<f32>(inv_0);
    (*spread_0) = min(shape_0.w * inv_0, 1.0f);
    var _S7 : f32 = shape_0.x;
    var k_0 : f32 = _S7 * _S7 / _S6;
    var _S8 : f32 = shape_0.y;
    var k_1 : f32;
    if(_S8 > 0.0f)
    {
        var x_2 : f32 = _S6 / (_S8 * _S8);
        var w_0 : f32 = clamp(1.0f - x_2 * x_2, 0.0f, 1.0f);
        k_1 = k_0 * (w_0 * w_0);
    }
    else
    {
        k_1 = k_0;
    }
    if(_S5 > 1.5f)
    {
        k_1 = k_1 * smoothstep(Material_Uniforms_0.light_spot_0[i_0].w, shape_0.z, dot((vec3<f32>(0) - (*l_0)), Material_Uniforms_0.light_spot_0[i_0].xyz));
    }
    return k_1;
}

fn nearest_in_light_0( l_1 : vec3<f32>,  r_2 : vec3<f32>,  spread_1 : f32) -> vec3<f32>
{
    var cos_r_0 : f32 = sqrt(max(1.0f - spread_1 * spread_1, 0.0f));
    var l_dot_r_0 : f32 = dot(l_1, r_2);
    if(l_dot_r_0 >= cos_r_0)
    {
        return r_2;
    }
    var s_0 : vec3<f32> = r_2 - vec3<f32>(l_dot_r_0) * l_1;
    var s2_0 : f32 = dot(s_0, s_0);
    if(s2_0 < 9.999999960041972e-13f)
    {
        return l_1;
    }
    return normalize(l_1 * vec3<f32>(cos_r_0) + s_0 * vec3<f32>((rsqrt_0(s2_0) * spread_1)));
}

fn widened_0( a_0 : f32,  spread_2 : f32) -> f32
{
    var _S9 : f32 = min(a_0 + 0.5f * spread_2, 1.0f);
    return a_0 * a_0 / (_S9 * _S9);
}

fn direct_sized_0( n_2 : vec3<f32>,  v_1 : vec3<f32>,  l_2 : vec3<f32>,  ls_0 : vec3<f32>,  spread_3 : f32,  diffuse_0 : vec3<f32>,  f0_1 : vec3<f32>,  a_1 : f32,  shine_0 : f32,  comp_0 : vec3<f32>) -> vec3<f32>
{
    var color_0 : vec3<f32> = diffuse_0 / vec3<f32>(3.14159274101257324f) * vec3<f32>(max(dot(n_2, l_2), 0.0f));
    var _S10 : f32 = max(dot(n_2, ls_0), 0.0f);
    if(_S10 <= 0.0f)
    {
        return color_0;
    }
    var h_0 : vec3<f32> = normalize(ls_0 + v_1);
    var _S11 : f32 = max(dot(n_2, v_1), 0.00009999999747379f);
    var _S12 : f32 = max(dot(n_2, h_0), 0.0f);
    var a2_0 : f32 = a_1 * a_1;
    var d_1 : f32 = _S12 * _S12 * (a2_0 - 1.0f) + 1.0f;
    return color_0 + vec3<f32>((a2_0 / (3.14159274101257324f * d_1 * d_1) * widened_0(a_1, spread_3) * (0.5f / max(mix(2.0f * _S10 * _S11, _S10 + _S11, a_1), 0.00009999999747379f)))) * (f0_1 + (vec3<f32>(1.0f) - f0_1) * vec3<f32>(pow(1.0f - max(dot(v_1, h_0), 0.0f), 5.0f))) * comp_0 * vec3<f32>(_S10) * vec3<f32>(shine_0);
}

fn direct_0( n_3 : vec3<f32>,  v_2 : vec3<f32>,  l_3 : vec3<f32>,  diffuse_1 : vec3<f32>,  f0_2 : vec3<f32>,  a_2 : f32,  shine_1 : f32,  comp_1 : vec3<f32>) -> vec3<f32>
{
    var _S13 : f32 = max(dot(n_3, l_3), 0.0f);
    if(_S13 <= 0.0f)
    {
        return vec3<f32>(0.0f);
    }
    var h_1 : vec3<f32> = normalize(l_3 + v_2);
    var _S14 : f32 = max(dot(n_3, v_2), 0.00009999999747379f);
    var _S15 : f32 = max(dot(n_3, h_1), 0.0f);
    var a2_1 : f32 = a_2 * a_2;
    var d_2 : f32 = _S15 * _S15 * (a2_1 - 1.0f) + 1.0f;
    return (diffuse_1 / vec3<f32>(3.14159274101257324f) + vec3<f32>((a2_1 / (3.14159274101257324f * d_2 * d_2) * (0.5f / max(mix(2.0f * _S13 * _S14, _S13 + _S14, a_2), 0.00009999999747379f)))) * (f0_2 + (vec3<f32>(1.0f) - f0_2) * vec3<f32>(pow(1.0f - max(dot(v_2, h_1), 0.0f), 5.0f))) * comp_1 * vec3<f32>(shine_1)) * vec3<f32>(_S13);
}

fn env_brdf_0( n_dot_v_0 : f32,  rough_0 : f32) -> vec2<f32>
{
    var r_3 : vec4<f32> = vec4<f32>(rough_0) * vec4<f32>(-1.0f, -0.02749999985098839f, -0.57200002670288086f, 0.02199999988079071f) + vec4<f32>(1.0f, 0.04250000044703484f, 1.03999996185302734f, -0.03999999910593033f);
    var _S16 : f32 = r_3.x;
    return vec2<f32>(-1.03999996185302734f, 1.03999996185302734f) * vec2<f32>((min(_S16 * _S16, exp2(-9.27999973297119141f * n_dot_v_0)) * _S16 + r_3.y)) + r_3.zw;
}

fn irradiance_0( n_4 : vec3<f32>) -> vec3<f32>
{
    var d_3 : vec3<f32> = (((transpose(mat3x3<f32>(Material_Uniforms_0.env_x_0.xyz, Material_Uniforms_0.env_y_0.xyz, Material_Uniforms_0.env_z_0.xyz))) * (n_4)));
    var _S17 : f32 = d_3.y;
    var _S18 : f32 = d_3.z;
    var _S19 : f32 = d_3.x;
    var _S20 : f32 = 1.09254801273345947f * _S19;
    return max(Material_Uniforms_0.env_sh_0[i32(0)].xyz * vec3<f32>(0.28209498524665833f) + Material_Uniforms_0.env_sh_0[i32(1)].xyz * vec3<f32>((0.48860299587249756f * _S17)) + Material_Uniforms_0.env_sh_0[i32(2)].xyz * vec3<f32>((0.48860299587249756f * _S18)) + Material_Uniforms_0.env_sh_0[i32(3)].xyz * vec3<f32>((0.48860299587249756f * _S19)) + Material_Uniforms_0.env_sh_0[i32(4)].xyz * vec3<f32>((_S20 * _S17)) + Material_Uniforms_0.env_sh_0[i32(5)].xyz * vec3<f32>((1.09254801273345947f * _S17 * _S18)) + Material_Uniforms_0.env_sh_0[i32(6)].xyz * vec3<f32>((0.31539198756217957f * (3.0f * _S18 * _S18 - 1.0f))) + Material_Uniforms_0.env_sh_0[i32(7)].xyz * vec3<f32>((_S20 * _S18)) + Material_Uniforms_0.env_sh_0[i32(8)].xyz * vec3<f32>((0.54627400636672974f * (_S19 * _S19 - _S17 * _S17))), vec3<f32>(0.0f)) * vec3<f32>(Material_Uniforms_0.env_0.y);
}

fn lobe_0( dir_0 : vec3<f32>,  toward_0 : vec3<f32>,  color_1 : vec3<f32>,  sharp_0 : f32,  rough_1 : f32) -> vec3<f32>
{
    var e_0 : f32 = mix(sharp_0, 3.0f, sqrt(rough_1));
    return color_1 * vec3<f32>(pow(max(dot(dir_0, toward_0), 0.0f), e_0)) * vec3<f32>((e_0 + 2.0f)) / vec3<f32>((sharp_0 + 2.0f));
}

fn studio_0( dir_1 : vec3<f32>,  rough_2 : f32) -> vec3<f32>
{
    var w_1 : f32 = 0.07999999821186066f + 0.89999997615814209f * rough_2;
    var _S21 : f32 = dir_1.y;
    return mix(vec3<f32>(0.07000000029802322f, 0.06499999761581421f, 0.05999999865889549f), vec3<f32>(0.40000000596046448f, 0.43000000715255737f, 0.47999998927116394f), vec3<f32>(smoothstep(- w_1, w_1, _S21))) + vec3<f32>(0.12999999523162842f, 0.11999999731779099f, 0.10999999940395355f) * vec3<f32>(exp(- abs(_S21) / (0.05999999865889549f + 0.5f * rough_2))) + lobe_0(dir_1, vec3<f32>(-0.65590423345565796f, 0.7433580756187439f, 0.13118083775043488f), vec3<f32>(4.0f, 3.79999995231628418f, 3.5f), 300.0f, rough_2) + lobe_0(dir_1, vec3<f32>(0.84478187561035156f, 0.32852628827095032f, -0.42239093780517578f), vec3<f32>(1.60000002384185791f, 1.79999995231628418f, 2.09999990463256836f), 600.0f, rough_2) + lobe_0(dir_1, vec3<f32>(0.09396819770336151f, -0.32888868451118469f, 0.93968194723129272f), vec3<f32>(0.5f, 0.5f, 0.5f), 4.0f, rough_2);
}

fn sky_facing_0( n_5 : vec3<f32>,  rig_0 : mat3x3<f32>) -> f32
{
    return 0.5f + 0.5f * dot(n_5, rig_0[i32(1)]);
}

fn underside_0( n_6 : vec3<f32>,  rig_1 : mat3x3<f32>) -> f32
{
    return mix(Material_Uniforms_0.style_0.y, 1.0f, sky_facing_0(n_6, rig_1));
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
    var _S22 : f32 = min(c_2.x, min(c_2.y, c_2.z));
    var offset_0 : f32;
    if(_S22 < 0.07999999821186066f)
    {
        offset_0 = _S22 - 6.25f * _S22 * _S22;
    }
    else
    {
        offset_0 = 0.03999999910593033f;
    }
    var _S23 : vec3<f32> = c_2 - vec3<f32>(offset_0);
    var _S24 : f32 = max(_S23.x, max(_S23.y, _S23.z));
    if(_S24 < 0.75999999046325684f)
    {
        return _S23;
    }
    var new_peak_0 : f32 = 1.0f - 0.0576000027358532f / (_S24 + 0.24000000953674316f - 0.75999999046325684f);
    return mix(_S23 * vec3<f32>((new_peak_0 / _S24)), vec3<f32>(new_peak_0), vec3<f32>((1.0f - 1.0f / (0.15000000596046448f * (_S24 - new_peak_0) + 1.0f))));
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
    @location(7) material_1 : vec4<f32>,
};

@fragment
fn main( _S25 : pixelInput_0, @builtin(position) position_0 : vec4<f32>, @builtin(front_facing) is_front_0 : bool) -> pixelOutput_0
{
    frag_in_0.view_normal_0 = _S25.view_normal_1;
    frag_in_0.view_pos_0 = _S25.view_pos_1;
    frag_in_0.mask_0 = _S25.mask_1;
    frag_in_0.paint_0 = _S25.paint_1;
    frag_in_0.group_0 = _S25.group_1;
    frag_in_0.mesh_pos_0 = _S25.mesh_pos_1;
    frag_in_0.slot_0 = _S25.slot_1;
    frag_in_0.material_0 = _S25.material_1;
    frag_coord_0 = position_0;
    front_facing_0 = is_front_0;
    if((Material_Uniforms_0.params_0.y) < 0.0f)
    {
        var _S26 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0(Material_Uniforms_0.base_color_0.xyz), 1.0f) );
        return _S26;
    }
    var _S27 : vec4<f32> = Material_Uniforms_0.base_color_0;
    var _S28 : vec4<f32> = Material_Uniforms_0.params_0;
    var surf_1 : vec4<f32> = Material_Uniforms_0.surface_0;
    var base_0 : vec4<f32>;
    var shading_0 : vec4<f32>;
    if((frag_in_0.slot_0) > u32(0))
    {
        var _S29 : vec2<f32> = Slot_Uniforms_0.slot_surface_0[frag_in_0.slot_0].xy;
        surf_1.x = _S29.x;
        surf_1.y = _S29.y;
        surf_1[i32(3)] = 0.0f;
        base_0 = Slot_Uniforms_0.slot_color_0[frag_in_0.slot_0];
        shading_0 = Slot_Uniforms_0.slot_params_0[frag_in_0.slot_0];
    }
    else
    {
        base_0 = _S27;
        shading_0 = _S28;
    }
    if((surf_1.y) > 0.0f)
    {
        var _S30 : vec2<f32> = paint_surface_0(surf_1.xy, frag_in_0.material_0);
        surf_1.x = _S30.x;
        surf_1.y = _S30.y;
    }
    var v_3 : vec3<f32>;
    if((Material_Uniforms_0.env_0.w) > 0.5f)
    {
        v_3 = vec3<f32>(0.0f, 0.0f, 1.0f);
    }
    else
    {
        v_3 = normalize((vec3<f32>(0) - frag_in_0.view_pos_0));
    }
    var n_7 : vec3<f32>;
    if((Material_Uniforms_0.surface_0.z) > 0.5f)
    {
        var n_8 : vec3<f32> = normalize(cross(dpdx(frag_in_0.view_pos_0), dpdy(frag_in_0.view_pos_0)));
        if((dot(n_8, v_3)) < 0.0f)
        {
            n_7 = (vec3<f32>(0) - n_8);
        }
        else
        {
            n_7 = n_8;
        }
    }
    else
    {
        var n_9 : vec3<f32> = normalize(frag_in_0.view_normal_0);
        if(!front_facing_0)
        {
            n_7 = (vec3<f32>(0) - n_9);
        }
        else
        {
            n_7 = n_9;
        }
    }
    var _S31 : vec3<f32> = dpdx(n_7);
    var _S32 : vec3<f32> = dpdy(n_7);
    var _S33 : f32 = curvature_0(n_7, frag_in_0.view_pos_0);
    var dndx_0 : vec3<f32>;
    var dndy_0 : vec3<f32>;
    var bend_0 : f32;
    if((Material_Uniforms_0.surface_0.z) > 0.5f)
    {
        var _S34 : vec3<f32> = vec3<f32>(0.0f);
        bend_0 = 0.0f;
        dndx_0 = _S34;
        dndy_0 = _S34;
    }
    else
    {
        bend_0 = _S33;
        dndx_0 = _S31;
        dndy_0 = _S32;
    }
    var _S35 : i32 = i32(Material_Uniforms_0.pass_0.x + 0.5f);
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
            view_pass_0 = _S35;
        }
    }
    else
    {
        view_pass_0 = _S35;
    }
    var _S36 : bool;
    if(view_pass_0 != i32(0))
    {
        _S36 = view_pass_0 != i32(7);
    }
    else
    {
        _S36 = false;
    }
    var shown_0 : vec3<f32>;
    var c_5 : f32;
    if(_S36)
    {
        if(view_pass_0 == i32(1))
        {
            var _S37 : vec3<f32> = vec3<f32>(0.5f);
            shown_0 = n_7 * _S37 + _S37;
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
                    if((Material_Uniforms_0.surface_0.z) > 0.5f)
                    {
                        var smooth_n_0 : vec3<f32> = normalize(frag_in_0.view_normal_0);
                        if(!front_facing_0)
                        {
                            shown_0 = (vec3<f32>(0) - smooth_n_0);
                        }
                        else
                        {
                            shown_0 = smooth_n_0;
                        }
                        c_5 = curvature_0(shown_0, frag_in_0.view_pos_0);
                    }
                    else
                    {
                        c_5 = bend_0;
                    }
                    var k_2 : f32 = clamp(c_5 / 0.23999999463558197f, -1.0f, 1.0f);
                    var k_3 : f32;
                    if(k_2 > 0.0f)
                    {
                        k_3 = k_2 * smoothstep(0.10000000149011612f, 0.40000000596046448f, max(dot(n_7, v_3), 0.0f));
                    }
                    else
                    {
                        k_3 = k_2;
                    }
                    var _S38 : vec3<f32> = vec3<f32>(0.5f);
                    if(k_3 < 0.0f)
                    {
                        v_3 = vec3<f32>(0.15000000596046448f, 0.34999999403953552f, 0.85000002384185791f);
                    }
                    else
                    {
                        v_3 = vec3<f32>(0.94999998807907104f, 0.55000001192092896f, 0.15000000596046448f);
                    }
                    shown_0 = mix(_S38, v_3, vec3<f32>(abs(k_3)));
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
        var _S39 : pixelOutput_0 = pixelOutput_0( vec4<f32>(shown_0, opacity_0()) );
        return _S39;
    }
    var _S40 : f32 = dot(n_7, v_3);
    var _S41 : f32 = max(_S40, 0.0f);
    var relief_0 : f32 = (1.0f - 0.75f * (Material_Uniforms_0.look_0.y * smoothstep(0.01999999955296516f, 0.23999999463558197f, - bend_0))) * (1.0f + 0.60000002384185791f * (Material_Uniforms_0.look_0.z * smoothstep(0.01999999955296516f, 0.23999999463558197f, bend_0) * smoothstep(0.10000000149011612f, 0.40000000596046448f, _S41)));
    var _S42 : vec3<f32> = mix(base_0.xyz, frag_in_0.paint_0.xyz, vec3<f32>(frag_in_0.paint_0.w));
    if((frag_in_0.group_0.x) >= 0.0f)
    {
        shown_0 = frag_in_0.group_0;
    }
    else
    {
        shown_0 = _S42;
    }
    if((Material_Uniforms_0.fade_0.w) > 0.0f)
    {
        _S36 = (frag_in_0.group_0.x) < 0.0f;
    }
    else
    {
        _S36 = false;
    }
    if(_S36)
    {
        shown_0 = mix(shown_0, Material_Uniforms_0.fade_0.xyz, vec3<f32>(Material_Uniforms_0.fade_0.w));
    }
    if((Material_Uniforms_0.checker_0.w) > 0.0f)
    {
        var c_6 : vec3<f32> = (frag_in_0.mesh_pos_0 - Material_Uniforms_0.checker_0.xyz) / vec3<f32>(Material_Uniforms_0.checker_0.w);
        var width_0 : vec3<f32> = max((fwidth((c_6))), vec3<f32>(9.99999997475242708e-07f));
        var _S43 : f32 = max(max(width_0.x, width_0.y), width_0.z);
        var f_0 : vec3<f32> = fract(c_6);
        var edge_0 : vec3<f32> = min(f_0, vec3<f32>(1.0f) - f_0) / width_0;
        var cell_0 : vec3<f32> = floor(c_6);
        shown_0 = shown_0 * vec3<f32>(mix(mix(1.0f, 0.72000002861022949f, glsl_mod_0(cell_0.x + cell_0.y + cell_0.z, 2.0f)) * (1.0f - 0.34999999403953552f * ((1.0f - smoothstep(0.5f, 1.5f, min(min(edge_0.x, edge_0.y), edge_0.z))) * (1.0f - smoothstep(0.0625f, 0.125f, _S43)))), 0.86000001430511475f, smoothstep(0.20000000298023224f, 0.40000000596046448f, _S43)));
    }
    var rig_2 : mat3x3<f32> = mat3x3<f32>(Material_Uniforms_0.light_x_0.xyz, Material_Uniforms_0.light_y_0.xyz, Material_Uniforms_0.light_z_0.xyz);
    var ambient_0 : f32 = Material_Uniforms_0.light_x_0.w;
    var shown_mask_0 : f32 = frag_in_0.mask_0 * (1.0f - Material_Uniforms_0.style_0.z);
    var albedo_0 : vec3<f32> = shown_0 * vec3<f32>((1.0f - 0.69999998807907104f * shown_mask_0));
    var highlight_0 : f32 = 1.0f - 0.5f * shown_mask_0;
    if(view_pass_0 == i32(7))
    {
        var _S44 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0(albedo_0 * vec3<f32>(relief_0) * vec3<f32>(exp2(Material_Uniforms_0.look_0.x))), opacity_0()) );
        return _S44;
    }
    if((surf_1.w) > 0.5f)
    {
        var k_4 : f32 = 1.0f / (1.0f + v_3.z);
        var _S45 : f32 = v_3.x;
        var _S46 : f32 = - _S45;
        var _S47 : f32 = v_3.y;
        var b_0 : f32 = _S46 * _S47 * k_4;
        var _S48 : vec2<f32> = vec2<f32>(0.5f + 0.49599999189376831f * dot(vec3<f32>(1.0f - _S45 * _S45 * k_4, b_0, _S46), n_7), 0.5f - 0.49599999189376831f * dot(vec3<f32>(b_0, 1.0f - _S47 * _S47 * k_4, - _S47), n_7));
        ;
        var _S49 : pixelOutput_0 = pixelOutput_0( vec4<f32>(srgb_encode_0((textureSample((matcap_texture_0), (matcap_sampler_0), (_S48))).xyz * albedo_0 * vec3<f32>(relief_0) * vec3<f32>(exp2(Material_Uniforms_0.look_0.x))), opacity_0()) );
        return _S49;
    }
    var color_2 : vec3<f32>;
    var lit_0 : vec3<f32>;
    var i_1 : i32;
    if((surf_1.y) > 0.0f)
    {
        var metallic_0 : f32 = clamp(surf_1.x, 0.0f, 1.0f);
        var a_3 : f32 = surf_1.y * surf_1.y;
        var rough_4 : f32 = clamp(sqrt(sqrt(clamp(a_3 * a_3 + min(2.0f * (0.25f * (dot(dndx_0, dndx_0) + dot(dndy_0, dndy_0))), 0.18000000715255737f), 0.0f, 1.0f))), 0.03999999910593033f, 1.0f);
        var _S50 : f32 = rough_4 * rough_4;
        var diffuse_2 : vec3<f32> = albedo_0 * vec3<f32>((1.0f - metallic_0));
        var f0_3 : vec3<f32> = mix(vec3<f32>(0.03999999910593033f), albedo_0, vec3<f32>(metallic_0));
        var _S51 : f32 = max(_S40, 0.00009999999747379f);
        var r_4 : vec3<f32> = reflect((vec3<f32>(0) - v_3), n_7);
        var _S52 : vec3<f32> = energy_compensation_0(f0_3, _S51, rough_4);
        var _S53 : vec3<f32> = vec3<f32>(0.0f);
        i_1 = i32(0);
        color_2 = _S53;
        for(;;)
        {
            if(i_1 < i32(8))
            {
            }
            else
            {
                break;
            }
            var s_1 : f32 = Material_Uniforms_0.light_color_0[i_1].w;
            if(s_1 <= 0.0f)
            {
                _S36 = true;
            }
            else
            {
                _S36 = (Material_Uniforms_0.light_pos_0[i_1].w) > 2.5f;
            }
            if(_S36)
            {
                i_1 = i_1 + i32(1);
                continue;
            }
            var l_4 : vec3<f32>;
            var spread_4 : f32;
            var k_5 : f32 = light_at_0(i_1, &(l_4), &(spread_4));
            if(k_5 <= 0.0f)
            {
                i_1 = i_1 + i32(1);
                continue;
            }
            var shine_2 : f32 = 1.0f + Material_Uniforms_0.light_extra_0[i_1].x;
            if(spread_4 > 0.0f)
            {
                lit_0 = direct_sized_0(n_7, v_3, l_4, nearest_in_light_0(l_4, r_4, spread_4), spread_4, diffuse_2, f0_3, _S50, shine_2, _S52);
            }
            else
            {
                lit_0 = direct_0(n_7, v_3, l_4, diffuse_2, f0_3, _S50, shine_2, _S52);
            }
            color_2 = color_2 + lit_0 * Material_Uniforms_0.light_color_0[i_1].xyz * vec3<f32>((3.0f * (s_1 * k_5)));
            i_1 = i_1 + i32(1);
        }
        var ab_0 : vec2<f32> = env_brdf_0(_S51, rough_4);
        var to_rig_1 : mat3x3<f32> = transpose(rig_2);
        if((Material_Uniforms_0.env_0.x) > 0.5f)
        {
            color_2 = color_2 + diffuse_2 * irradiance_0(n_7);
        }
        else
        {
            if((Material_Uniforms_0.style_0.w) > 0.5f)
            {
                color_2 = color_2 + diffuse_2 * studio_0((((to_rig_1) * (n_7))), 1.0f) * vec3<f32>((0.69999998807907104f * ambient_0 * underside_0(n_7, rig_2)));
            }
            else
            {
                color_2 = color_2 + diffuse_2 * studio_0((((to_rig_1) * (n_7))), 1.0f) * vec3<f32>((0.69999998807907104f * ambient_0));
            }
        }
        var _S54 : f32 = ab_0.x;
        var _S55 : f32 = ab_0.y;
        var _S56 : pixelOutput_0 = pixelOutput_0( display_0((color_2 + reflected_0(r_4, rough_4, to_rig_1) * ((f0_3 * vec3<f32>(_S54) + vec3<f32>(_S55)) * (vec3<f32>(1.0f) + f0_3 * vec3<f32>((1.0f / max(_S54 + _S55, 0.05000000074505806f) - 1.0f)))) * vec3<f32>(highlight_0)) * vec3<f32>(relief_0)) );
        return _S56;
    }
    var _S57 : f32 = shading_0.w;
    var _S58 : f32 = shading_0.x * ambient_0;
    var _S59 : vec3<f32> = vec3<f32>(_S58);
    var _S60 : vec3<f32> = vec3<f32>(0.0f);
    var _S61 : vec3<f32> = reflect((vec3<f32>(0) - v_3), n_7);
    i_1 = i32(0);
    color_2 = _S59;
    lit_0 = _S60;
    for(;;)
    {
        if(i_1 < i32(8))
        {
        }
        else
        {
            break;
        }
        var s_2 : f32 = Material_Uniforms_0.light_color_0[i_1].w;
        if(s_2 <= 0.0f)
        {
            _S36 = true;
        }
        else
        {
            _S36 = (Material_Uniforms_0.light_pos_0[i_1].w) > 2.5f;
        }
        if(_S36)
        {
            i_1 = i_1 + i32(1);
            continue;
        }
        var l_5 : vec3<f32>;
        var spread_5 : f32;
        var _S62 : f32 = light_at_0(i_1, &(l_5), &(spread_5));
        var s_3 : f32 = s_2 * _S62;
        if(s_3 <= 0.0f)
        {
            i_1 = i_1 + i32(1);
            continue;
        }
        var lit_1 : vec3<f32> = color_2 + Material_Uniforms_0.light_color_0[i_1].xyz * vec3<f32>((max((dot(n_7, l_5) + _S57) / (1.0f + _S57), 0.0f) * s_3));
        var _S63 : vec3<f32> = normalize(l_5 + v_3);
        var shrink_0 : f32 = 1.0f + Material_Uniforms_0.light_extra_0[i_1].x;
        var h_2 : vec3<f32>;
        if(spread_5 > 0.0f)
        {
            var shrink_1 : f32 = shrink_0 * widened_0(sqrt(2.0f / (shading_0.z + 2.0f)), spread_5);
            h_2 = normalize(nearest_in_light_0(l_5, _S61, spread_5) + v_3);
            c_5 = shrink_1;
        }
        else
        {
            h_2 = _S63;
            c_5 = shrink_0;
        }
        var spec_0 : vec3<f32> = lit_0 + Material_Uniforms_0.light_color_0[i_1].xyz * vec3<f32>((pow(max(dot(n_7, h_2), 0.0f), shading_0.z) * shading_0.y * s_3 * c_5));
        color_2 = lit_1;
        lit_0 = spec_0;
        i_1 = i_1 + i32(1);
    }
    var _S64 : f32 = 1.0f - _S41;
    var _S65 : f32 = pow(_S64, 3.0f) * 0.25f;
    if((Material_Uniforms_0.style_0.w) > 0.5f)
    {
        var lit_2 : vec3<f32> = color_2 - vec3<f32>((_S58 * (1.0f - underside_0(n_7, rig_2))));
        c_5 = pow(_S64, 4.0f) * Material_Uniforms_0.style_0.x * mix(0.30000001192092896f, 1.0f, sky_facing_0(n_7, rig_2));
        color_2 = lit_2;
    }
    else
    {
        c_5 = _S65;
    }
    var _S66 : pixelOutput_0 = pixelOutput_0( display_0((albedo_0 * color_2 + (lit_0 + vec3<f32>(c_5)) * vec3<f32>(highlight_0)) * vec3<f32>(relief_0)) );
    return _S66;
}

