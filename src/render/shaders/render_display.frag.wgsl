// slangc wgsl from render_display.frag.spv sha256 e025e878a96555d028f2948b1b455e73f34df9ed7bee049f0119cfed37b7992c
@binding(0) @group(2) var view_color_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var view_color_sampler_0 : sampler;

struct SLANG_ParameterGroup_Display_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Display_Uniforms_0 : SLANG_ParameterGroup_Display_Uniforms_std140_0;
@binding(2) @group(2) var accum_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var accum_sampler_0 : sampler;

@binding(6) @group(2) var guide_albedo_texture_0 : texture_2d<f32>;

@binding(7) @group(2) var guide_albedo_sampler_0 : sampler;

@binding(4) @group(2) var denoised_texture_0 : texture_2d<f32>;

@binding(5) @group(2) var denoised_sampler_0 : sampler;

fn traced_0( q_0 : vec2<i32>) -> vec4<f32>
{
    var _S1 : vec3<i32> = vec3<i32>(q_0, i32(0));
    var _S2 : vec4<f32> = (textureLoad((accum_texture_0), ((accum_sampler_0)).xy, ((accum_sampler_0)).z));
    var _S3 : f32 = _S2.w;
    var covered_0 : f32 = _S3 / max(Display_Uniforms_0.params_0.y, 1.0f);
    var _S4 : vec3<f32> = _S2.xyz / vec3<f32>(max(_S3, 9.99999997475242708e-07f));
    var mean_0 : vec3<f32>;
    if((Display_Uniforms_0.params_0.z) > 0.5f)
    {
        var _S5 : vec4<f32> = (textureLoad((guide_albedo_texture_0), ((guide_albedo_sampler_0)).xy, ((guide_albedo_sampler_0)).z));
        var _S6 : vec3<f32> = (textureLoad((denoised_texture_0), ((denoised_sampler_0)).xy, ((denoised_sampler_0)).z)).xyz;
        if((_S5.w) > 0.0f)
        {
            mean_0 = max(_S5.xyz, vec3<f32>(0.01999999955296516f));
        }
        else
        {
            mean_0 = vec3<f32>(1.0f);
        }
        mean_0 = _S6 * mean_0;
    }
    else
    {
        mean_0 = _S4;
    }
    var _S7 : vec4<f32>;
    if(_S3 > 0.0f)
    {
        _S7 = vec4<f32>(mean_0, covered_0);
    }
    else
    {
        _S7 = vec4<f32>(0.0f);
    }
    return _S7;
}

fn texture_size_0( t_texture_0 : texture_2d<f32>,  t_sampler_0 : sampler) -> vec2<i32>
{
    var w_0 : u32;
    var h_0 : u32;
    var levels_0 : u32;
    {var dim = textureDimensions((t_texture_0), (u32(0)));((w_0)) = dim.x;((h_0)) = dim.y;((levels_0)) = textureNumLevels((t_texture_0));};
    return vec2<i32>(i32(w_0), i32(h_0));
}

fn blended_0( q_1 : vec2<i32>,  w_1 : f32) -> vec4<f32>
{
    var t_0 : vec4<f32> = traced_0(q_1);
    var _S8 : f32 = t_0.w;
    return vec4<f32>(t_0.xyz * vec3<f32>(_S8), _S8) * vec4<f32>(w_1);
}

fn tone_map_0( c_0 : vec3<f32>) -> vec3<f32>
{
    var _S9 : f32 = min(c_0.x, min(c_0.y, c_0.z));
    var offset_0 : f32;
    if(_S9 < 0.07999999821186066f)
    {
        offset_0 = _S9 - 6.25f * _S9 * _S9;
    }
    else
    {
        offset_0 = 0.03999999910593033f;
    }
    var _S10 : vec3<f32> = c_0 - vec3<f32>(offset_0);
    var _S11 : f32 = max(_S10.x, max(_S10.y, _S10.z));
    if(_S11 < 0.75999999046325684f)
    {
        return _S10;
    }
    var new_peak_0 : f32 = 1.0f - 0.0576000027358532f / (_S11 + 0.24000000953674316f - 0.75999999046325684f);
    return mix(_S10 * vec3<f32>((new_peak_0 / _S11)), vec3<f32>(new_peak_0), vec3<f32>((1.0f - 1.0f / (0.15000000596046448f * (_S11 - new_peak_0) + 1.0f))));
}

fn srgb_encode_0( c_1 : vec3<f32>) -> vec3<f32>
{
    var _S12 : vec3<f32> = clamp(c_1, vec3<f32>(0.0f), vec3<f32>(1.0f));
    return mix(vec3<f32>(12.92000007629394531f) * _S12, vec3<f32>(1.0549999475479126f) * pow(_S12, vec3<f32>(0.4166666567325592f)) - vec3<f32>(0.05499999970197678f), step(vec3<f32>(0.00313080009073019f), _S12));
}

fn display_color_0( c_2 : vec3<f32>,  stops_0 : f32) -> vec3<f32>
{
    return srgb_encode_0(tone_map_0(c_2 * vec3<f32>(exp2(stops_0))));
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S13 : vec2<f32> = frag_coord_0.xy;
    var _S14 : vec2<i32> = vec2<i32>(_S13);
    var under_0 : vec3<f32> = (textureLoad((view_color_texture_0), ((view_color_sampler_0)).xy, ((view_color_sampler_0)).z)).xyz;
    var t_1 : vec4<f32>;
    if((Display_Uniforms_0.params_0.w) < 0.5f)
    {
        t_1 = traced_0(_S14);
    }
    else
    {
        var _S15 : vec2<i32> = vec2<i32>(i32(1));
        var hi_0 : vec2<i32> = texture_size_0(accum_texture_0, accum_sampler_0) - _S15;
        var at_0 : vec2<f32> = _S13 / vec2<f32>(texture_size_0(view_color_texture_0, view_color_sampler_0)) * vec2<f32>(hi_0 + _S15) - vec2<f32>(0.5f);
        var _S16 : vec2<i32> = vec2<i32>(floor(at_0));
        var f_0 : vec2<f32> = at_0 - vec2<f32>(_S16);
        var _S17 : vec2<i32> = vec2<i32>(i32(0));
        var _S18 : f32 = f_0.x;
        var _S19 : f32 = 1.0f - _S18;
        var _S20 : f32 = f_0.y;
        var _S21 : f32 = 1.0f - _S20;
        var _S22 : vec4<f32> = blended_0(clamp(_S16, _S17, hi_0), _S19 * _S21) + blended_0(clamp(_S16 + vec2<i32>(i32(1), i32(0)), _S17, hi_0), _S18 * _S21) + blended_0(clamp(_S16 + vec2<i32>(i32(0), i32(1)), _S17, hi_0), _S19 * _S20) + blended_0(clamp(_S16 + vec2<i32>(i32(1), i32(1)), _S17, hi_0), _S18 * _S20);
        t_1 = _S22;
        if((_S22.w) > 0.0f)
        {
            var _S23 : vec3<f32> = t_1.xyz / vec3<f32>(t_1.w);
            t_1.x = _S23.x;
            t_1.y = _S23.y;
            t_1.z = _S23.z;
        }
    }
    var shown_0 : vec3<f32>;
    if((t_1.w) > 0.0f)
    {
        shown_0 = display_color_0(t_1.xyz, Display_Uniforms_0.params_0.x);
    }
    else
    {
        shown_0 = under_0;
    }
    var _S24 : pixelOutput_0 = pixelOutput_0( vec4<f32>(mix(under_0, shown_0, vec3<f32>(clamp(t_1.w, 0.0f, 1.0f))), 1.0f) );
    return _S24;
}

