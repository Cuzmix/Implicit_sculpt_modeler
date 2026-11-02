// slangc wgsl from finish.frag.spv sha256 8932938b2271fc1f4e00ac594bfd937fb2aceb3c5f4bb2ae21e406f2e503ad87
@binding(0) @group(2) var source_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var source_sampler_0 : sampler;

struct SLANG_ParameterGroup_Finish_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
    @align(16) white_x_0 : vec4<f32>,
    @align(16) white_y_0 : vec4<f32>,
    @align(16) white_z_0 : vec4<f32>,
    @align(16) vignette_0 : vec4<f32>,
    @align(16) grade_0 : vec4<f32>,
    @align(16) grain_0 : vec4<f32>,
    @align(16) effects_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Finish_Uniforms_0 : SLANG_ParameterGroup_Finish_Uniforms_std140_0;
@binding(2) @group(2) var bloom_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var bloom_sampler_0 : sampler;

fn texture_size_0( t_texture_0 : texture_2d<f32>,  t_sampler_0 : sampler) -> vec2<i32>
{
    var w_0 : u32;
    var h_0 : u32;
    var levels_0 : u32;
    {var dim = textureDimensions((t_texture_0), (u32(0)));((w_0)) = dim.x;((h_0)) = dim.y;((levels_0)) = textureNumLevels((t_texture_0));};
    return vec2<i32>(i32(w_0), i32(h_0));
}

fn srgb_decode_0( c_0 : vec3<f32>) -> vec3<f32>
{
    return mix(c_0 / vec3<f32>(12.92000007629394531f), pow((c_0 + vec3<f32>(0.05499999970197678f)) / vec3<f32>(1.0549999475479126f), vec3<f32>(2.40000009536743164f)), step(vec3<f32>(0.04044999927282333f), c_0));
}

fn neutral_inverse_0( y_0 : vec3<f32>) -> vec3<f32>
{
    var _S1 : f32 = min(max(y_0.x, max(y_0.y, y_0.z)), 0.99554997682571411f);
    var c_1 : vec3<f32>;
    if(_S1 >= 0.75999999046325684f)
    {
        var peak_0 : f32 = 0.51999998092651367f + 0.0576000027358532f / (1.0f - _S1);
        var g_0 : f32 = 1.0f - 1.0f / (0.15000000596046448f * (peak_0 - _S1) + 1.0f);
        c_1 = (min(y_0, vec3<f32>(_S1)) - vec3<f32>((g_0 * _S1))) / vec3<f32>((1.0f - g_0)) * vec3<f32>((peak_0 / _S1));
    }
    else
    {
        c_1 = y_0;
    }
    var _S2 : f32 = max(min(c_1.x, min(c_1.y, c_1.z)), 0.0f);
    var offset_0 : f32;
    if(_S2 < 0.03999999910593033f)
    {
        offset_0 = 0.40000000596046448f * sqrt(_S2) - _S2;
    }
    else
    {
        offset_0 = 0.03999999910593033f;
    }
    return max(c_1 + vec3<f32>(offset_0), vec3<f32>(0.0f));
}

fn tone_map_0( c_2 : vec3<f32>) -> vec3<f32>
{
    var _S3 : f32 = min(c_2.x, min(c_2.y, c_2.z));
    var offset_1 : f32;
    if(_S3 < 0.07999999821186066f)
    {
        offset_1 = _S3 - 6.25f * _S3 * _S3;
    }
    else
    {
        offset_1 = 0.03999999910593033f;
    }
    var _S4 : vec3<f32> = c_2 - vec3<f32>(offset_1);
    var _S5 : f32 = max(_S4.x, max(_S4.y, _S4.z));
    if(_S5 < 0.75999999046325684f)
    {
        return _S4;
    }
    var new_peak_0 : f32 = 1.0f - 0.0576000027358532f / (_S5 + 0.24000000953674316f - 0.75999999046325684f);
    return mix(_S4 * vec3<f32>((new_peak_0 / _S5)), vec3<f32>(new_peak_0), vec3<f32>((1.0f - 1.0f / (0.15000000596046448f * (_S5 - new_peak_0) + 1.0f))));
}

fn decode_0( v_0 : vec3<f32>,  c_3 : ptr<function, vec3<f32>>,  shown_0 : ptr<function, vec3<f32>>,  residual_0 : ptr<function, vec3<f32>>)
{
    var _S6 : vec3<f32> = vec3<f32>(0.0f);
    (*shown_0) = _S6;
    (*residual_0) = _S6;
    if((Finish_Uniforms_0.params_0.y) > 0.5f)
    {
        (*c_3) = max(v_0, _S6);
    }
    else
    {
        var _S7 : vec3<f32> = srgb_decode_0(v_0);
        (*shown_0) = _S7;
        var _S8 : vec3<f32> = neutral_inverse_0(_S7);
        (*c_3) = _S8;
        (*residual_0) = (*shown_0) - tone_map_0(_S8);
    }
    return;
}

fn aberrated_0( frag_0 : vec2<f32>,  c_4 : ptr<function, vec3<f32>>,  shown_1 : ptr<function, vec3<f32>>,  residual_1 : ptr<function, vec3<f32>>)
{
    var _S9 : vec2<f32> = vec2<f32>(0.5f);
    var _S10 : vec2<f32> = frag_0 / vec2<f32>(texture_size_0(source_texture_0, source_sampler_0)) - _S9;
    var _S11 : vec3<f32> = vec3<f32>(0.0f);
    (*c_4) = _S11;
    (*shown_1) = _S11;
    (*residual_1) = _S11;
    var i_0 : i32 = i32(0);
    var total_0 : vec3<f32> = _S11;
    for(;;)
    {
        if(i_0 < i32(5))
        {
        }
        else
        {
            break;
        }
        var t_0 : f32 = f32(i_0) / 4.0f;
        var _S12 : f32 = 2.0f * t_0;
        var _S13 : f32 = _S12 - 1.0f;
        var w_1 : vec3<f32> = vec3<f32>(saturate(1.0f - _S12), 1.0f - abs(_S13), saturate(_S13));
        var tc_0 : vec3<f32>;
        var ts_0 : vec3<f32>;
        var tr_0 : vec3<f32>;
        decode_0((textureSampleLevel((source_texture_0), (source_sampler_0), (_S9 + _S10 * vec2<f32>((1.0f + Finish_Uniforms_0.effects_0.y * (t_0 - 0.5f)))), (0.0f))).xyz, &(tc_0), &(ts_0), &(tr_0));
        (*c_4) = (*c_4) + w_1 * tc_0;
        (*shown_1) = (*shown_1) + w_1 * ts_0;
        (*residual_1) = (*residual_1) + w_1 * tr_0;
        var total_1 : vec3<f32> = total_0 + w_1;
        i_0 = i_0 + i32(1);
        total_0 = total_1;
    }
    (*c_4) = (*c_4) / total_0;
    (*shown_1) = (*shown_1) / total_0;
    (*residual_1) = (*residual_1) / total_0;
    return;
}

fn above_threshold_0( c_5 : vec3<f32>,  threshold_0 : f32) -> vec3<f32>
{
    if(threshold_0 <= 0.0f)
    {
        return c_5;
    }
    var _S14 : f32 = max(c_5.x, max(c_5.y, c_5.z));
    var knee_0 : f32 = 0.5f * threshold_0;
    var _S15 : f32 = _S14 - threshold_0;
    var q_0 : f32 = clamp(_S15 + knee_0, 0.0f, 2.0f * knee_0);
    return c_5 * vec3<f32>(max(q_0 * q_0 / (4.0f * knee_0), _S15)) / vec3<f32>(max(_S14, 0.00009999999747379f));
}

fn bloomed_0( c_6 : vec3<f32>,  frag_1 : vec2<f32>) -> vec3<f32>
{
    if((Finish_Uniforms_0.effects_0.x) <= 0.0f)
    {
        return c_6;
    }
    return c_6 + vec3<f32>(Finish_Uniforms_0.effects_0.x) * ((textureSampleLevel((bloom_texture_0), (bloom_sampler_0), (frag_1 / vec2<f32>(texture_size_0(source_texture_0, source_sampler_0))), (0.0f))).xyz - above_threshold_0(c_6, Finish_Uniforms_0.effects_0.w));
}

fn luminance_0( c_7 : vec3<f32>) -> f32
{
    return dot(c_7, vec3<f32>(0.2125999927520752f, 0.71520000696182251f, 0.07220000028610229f));
}

fn aces_0( c_8 : vec3<f32>) -> vec3<f32>
{
    var v_1 : vec3<f32> = (((mat3x3<f32>(0.59719002246856689f, 0.07599999755620956f, 0.0284000001847744f, 0.35457998514175415f, 0.9083399772644043f, 0.1338299959897995f, 0.04822999984025955f, 0.01565999910235405f, 0.83776998519897461f)) * (c_8)));
    return clamp((((mat3x3<f32>(1.60475003719329834f, -0.10208000242710114f, -0.00326999998651445f, -0.53108000755310059f, 1.10812997817993164f, -0.07276000082492828f, -0.07366999983787537f, -0.00604999996721745f, 1.0760200023651123f)) * ((v_1 * (v_1 + vec3<f32>(0.02457859925925732f)) - vec3<f32>(0.0000905370034161f)) / (v_1 * (vec3<f32>(0.98372900485992432f) * v_1 + vec3<f32>(0.43295100331306458f)) + vec3<f32>(0.23808099329471588f))))), vec3<f32>(0.0f), vec3<f32>(1.0f));
}

fn agx_sigmoid_0( x_0 : f32) -> f32
{
    var shoulder_0 : bool = x_0 >= 0.60606056451797485f;
    var scale_0 : f32;
    if(shoulder_0)
    {
        scale_0 = 0.55935227870941162f;
    }
    else
    {
        scale_0 = 0.51227736473083496f;
    }
    var power_0 : f32;
    if(shoulder_0)
    {
        power_0 = 2.84999990463256836f;
    }
    else
    {
        power_0 = 3.0f;
    }
    var u_0 : f32 = 2.0f * (x_0 - 0.60606056451797485f) / scale_0;
    return 0.5f + scale_0 * u_0 / pow(1.0f + pow(abs(u_0), power_0), 1.0f / power_0);
}

fn agx_0( c_9 : vec3<f32>) -> vec3<f32>
{
    var _S16 : vec3<f32> = vec3<f32>(0.3333333432674408f);
    var x_1 : vec3<f32> = (clamp(log2(max(vec3<f32>(0.80000001192092896f) * c_9 + vec3<f32>((0.20000000298023224f * dot(c_9, _S16))), vec3<f32>(1.00000001335143196e-10f))), vec3<f32>(-12.47393035888671875f), vec3<f32>(4.02606916427612305f)) - vec3<f32>(-12.47393035888671875f)) / vec3<f32>(16.5f);
    var s_0 : vec3<f32> = vec3<f32>(agx_sigmoid_0(x_1.x), agx_sigmoid_0(x_1.y), agx_sigmoid_0(x_1.z));
    return pow(clamp((s_0 - vec3<f32>((0.40000000596046448f * dot(s_0, _S16)))) / vec3<f32>(0.60000002384185791f), vec3<f32>(0.0f), vec3<f32>(1.0f)), vec3<f32>(2.20000004768371582f));
}

fn graded_0( c_10 : vec3<f32>,  frag_2 : vec2<f32>) -> vec3<f32>
{
    var _S17 : vec3<f32>;
    if((Finish_Uniforms_0.vignette_0.x) > 0.0f)
    {
        var _S18 : vec2<f32> = vec2<f32>(0.5f);
        var _S19 : f32 = max(Finish_Uniforms_0.vignette_0.y, 0.05000000074505806f);
        _S17 = c_10 * vec3<f32>((1.0f - Finish_Uniforms_0.vignette_0.x * smoothstep(0.0f, 1.0f, (length((frag_2 / vec2<f32>(texture_size_0(source_texture_0, source_sampler_0)) - _S18) * vec2<f32>(Finish_Uniforms_0.vignette_0.z, 1.0f)) / length(vec2<f32>(Finish_Uniforms_0.vignette_0.z, 1.0f) * _S18) - (1.0f - _S19)) / _S19)));
    }
    else
    {
        _S17 = c_10;
    }
    var _S20 : vec3<f32> = (((mat3x3<f32>(Finish_Uniforms_0.white_x_0.xyz, Finish_Uniforms_0.white_y_0.xyz, Finish_Uniforms_0.white_z_0.xyz)) * (_S17)));
    if((Finish_Uniforms_0.params_0.z) != 1.0f)
    {
        var _S21 : vec3<f32> = vec3<f32>(0.18000000715255737f);
        _S17 = _S21 * pow(max(_S20, vec3<f32>(0.0f)) / _S21, vec3<f32>(Finish_Uniforms_0.params_0.z));
    }
    else
    {
        _S17 = _S20;
    }
    var _S22 : vec3<f32> = max(mix(vec3<f32>(luminance_0(_S17)), _S17, vec3<f32>(Finish_Uniforms_0.params_0.w)), vec3<f32>(0.0f));
    if((Finish_Uniforms_0.params_0.x) > 1.5f)
    {
        return aces_0(_S22 * vec3<f32>(1.21597909927368164f));
    }
    if((Finish_Uniforms_0.params_0.x) > 0.5f)
    {
        return agx_0(_S22 * vec3<f32>(0.5942082405090332f));
    }
    return tone_map_0(_S22);
}

fn srgb_encode_0( c_11 : vec3<f32>) -> vec3<f32>
{
    var _S23 : vec3<f32> = clamp(c_11, vec3<f32>(0.0f), vec3<f32>(1.0f));
    return mix(vec3<f32>(12.92000007629394531f) * _S23, vec3<f32>(1.0549999475479126f) * pow(_S23, vec3<f32>(0.4166666567325592f)) - vec3<f32>(0.05499999970197678f), step(vec3<f32>(0.00313080009073019f), _S23));
}

fn lattice_noise_0( p_0 : vec2<i32>,  seed_0 : u32) -> f32
{
    var h_1 : u32 = ((((u32(p_0.x) * u32(2376512323)) ^ ((u32(p_0.y) * u32(3625334849))))) ^ ((seed_0 * u32(3407524639))));
    var h_2 : u32 = ((h_1 ^ (((h_1 >> (u32(15))))))) * u32(739982445);
    var h_3 : u32 = ((h_2 ^ (((h_2 >> (u32(12))))))) * u32(695872825);
    return f32((h_3 ^ (((h_3 >> (u32(15))))))) / 2.147483648e+09f - 1.0f;
}

fn grain_at_0( px_0 : vec2<f32>,  size_0 : f32,  seed_1 : u32) -> f32
{
    var at_0 : vec2<f32> = px_0 / vec2<f32>(size_0);
    var _S24 : vec2<i32> = vec2<i32>(floor(at_0));
    var f_0 : vec2<f32> = at_0 - vec2<f32>(_S24);
    var f_1 : vec2<f32> = f_0 * f_0 * (vec2<f32>(3.0f) - vec2<f32>(2.0f) * f_0);
    var _S25 : f32 = f_1.x;
    return mix(mix(lattice_noise_0(_S24, seed_1), lattice_noise_0(_S24 + vec2<i32>(i32(1), i32(0)), seed_1), _S25), mix(lattice_noise_0(_S24 + vec2<i32>(i32(0), i32(1)), seed_1), lattice_noise_0(_S24 + vec2<i32>(i32(1), i32(1)), seed_1), _S25), f_1.y);
}

fn gradient_noise_0( px_1 : vec2<f32>) -> f32
{
    return fract(52.98291778564453125f * fract(dot(px_1, vec2<f32>(0.06711056083440781f, 0.00583714991807938f))));
}

fn grain_and_dither_0( e_0 : vec3<f32>,  px_2 : vec2<f32>,  strength_0 : f32,  size_1 : f32,  seed_2 : u32) -> vec3<f32>
{
    var _S26 : vec3<f32>;
    if(strength_0 > 0.0f)
    {
        var l_0 : f32 = clamp(dot(e_0, vec3<f32>(0.2125999927520752f, 0.71520000696182251f, 0.07220000028610229f)), 0.0f, 1.0f);
        _S26 = e_0 + vec3<f32>((0.11999999731779099f * strength_0 * 4.0f * l_0 * (1.0f - l_0) * grain_at_0(px_2, size_1, seed_2)));
    }
    else
    {
        _S26 = e_0;
    }
    return _S26 + vec3<f32>(((gradient_noise_0(px_2) - 0.5f) / 255.0f));
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S27 : vec2<f32> = frag_coord_0.xy;
    var _S28 : vec4<f32> = (textureLoad((source_texture_0), ((source_sampler_0)).xy, ((source_sampler_0)).z));
    var c_12 : vec3<f32>;
    var shown_2 : vec3<f32>;
    var residual_2 : vec3<f32>;
    if((Finish_Uniforms_0.effects_0.y) > 0.0f)
    {
        aberrated_0(_S27, &(c_12), &(shown_2), &(residual_2));
    }
    else
    {
        decode_0(_S28.xyz, &(c_12), &(shown_2), &(residual_2));
    }
    var kept_0 : vec3<f32> = graded_0(bloomed_0(c_12, _S27), _S27) + residual_2;
    var kept_1 : vec3<f32>;
    if((Finish_Uniforms_0.params_0.y) < 0.5f)
    {
        var grey_0 : vec3<f32> = neutral_inverse_0(vec3<f32>(luminance_0(shown_2)));
        var grey_graded_0 : vec3<f32> = graded_0(grey_0, _S27);
        var scaled_0 : vec3<f32> = shown_2 * grey_graded_0 / max(tone_map_0(grey_0), vec3<f32>(0.00009999999747379f));
        if((Finish_Uniforms_0.effects_0.x) > 0.0f)
        {
            kept_1 = scaled_0 + (graded_0(bloomed_0(grey_0, _S27), _S27) - grey_graded_0);
        }
        else
        {
            kept_1 = scaled_0;
        }
        kept_1 = mix(kept_0, kept_1, vec3<f32>(max(smoothstep(0.00999999977648258f, 0.05000000074505806f, max(abs(residual_2.x), max(abs(residual_2.y), abs(residual_2.z)))), smoothstep(0.85000002384185791f, 0.97000002861022949f, max(shown_2.x, max(shown_2.y, shown_2.z))))));
    }
    else
    {
        kept_1 = kept_0;
    }
    var e_1 : vec3<f32> = srgb_encode_0(kept_1);
    var e_2 : vec3<f32> = pow(max(vec3<f32>(Finish_Uniforms_0.grade_0.z) * (e_1 + vec3<f32>(Finish_Uniforms_0.grade_0.x) * (vec3<f32>(1.0f) - e_1)), vec3<f32>(0.0f)), vec3<f32>((1.0f / Finish_Uniforms_0.grade_0.y)));
    var e_3 : vec3<f32>;
    if((Finish_Uniforms_0.effects_0.z) > 0.5f)
    {
        e_3 = grain_and_dither_0(e_2, _S27, Finish_Uniforms_0.grade_0.w, Finish_Uniforms_0.grain_0.x, (bitcast<u32>((Finish_Uniforms_0.grain_0.y))));
    }
    else
    {
        e_3 = e_2;
    }
    var _S29 : pixelOutput_0 = pixelOutput_0( vec4<f32>(e_3, _S28.w) );
    return _S29;
}

