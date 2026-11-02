// slangc wgsl from render_display_linear.frag.spv sha256 6f6054655839ff6f2dae82e2acb65d33bf48425e2cc27ec6dc69a72cf658ff26
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

fn srgb_decode_0( c_0 : vec3<f32>) -> vec3<f32>
{
    return mix(c_0 / vec3<f32>(12.92000007629394531f), pow((c_0 + vec3<f32>(0.05499999970197678f)) / vec3<f32>(1.0549999475479126f), vec3<f32>(2.40000009536743164f)), step(vec3<f32>(0.04044999927282333f), c_0));
}

fn neutral_inverse_0( y_0 : vec3<f32>) -> vec3<f32>
{
    var _S9 : f32 = min(max(y_0.x, max(y_0.y, y_0.z)), 0.99554997682571411f);
    var c_1 : vec3<f32>;
    if(_S9 >= 0.75999999046325684f)
    {
        var peak_0 : f32 = 0.51999998092651367f + 0.0576000027358532f / (1.0f - _S9);
        var g_0 : f32 = 1.0f - 1.0f / (0.15000000596046448f * (peak_0 - _S9) + 1.0f);
        c_1 = (min(y_0, vec3<f32>(_S9)) - vec3<f32>((g_0 * _S9))) / vec3<f32>((1.0f - g_0)) * vec3<f32>((peak_0 / _S9));
    }
    else
    {
        c_1 = y_0;
    }
    var _S10 : f32 = max(min(c_1.x, min(c_1.y, c_1.z)), 0.0f);
    var offset_0 : f32;
    if(_S10 < 0.03999999910593033f)
    {
        offset_0 = 0.40000000596046448f * sqrt(_S10) - _S10;
    }
    else
    {
        offset_0 = 0.03999999910593033f;
    }
    return max(c_1 + vec3<f32>(offset_0), vec3<f32>(0.0f));
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S11 : vec2<f32> = frag_coord_0.xy;
    var _S12 : vec2<i32> = vec2<i32>(_S11);
    var under_0 : vec3<f32> = (textureLoad((view_color_texture_0), ((view_color_sampler_0)).xy, ((view_color_sampler_0)).z)).xyz;
    var t_1 : vec4<f32>;
    if((Display_Uniforms_0.params_0.w) < 0.5f)
    {
        t_1 = traced_0(_S12);
    }
    else
    {
        var _S13 : vec2<i32> = vec2<i32>(i32(1));
        var hi_0 : vec2<i32> = texture_size_0(accum_texture_0, accum_sampler_0) - _S13;
        var at_0 : vec2<f32> = _S11 / vec2<f32>(texture_size_0(view_color_texture_0, view_color_sampler_0)) * vec2<f32>(hi_0 + _S13) - vec2<f32>(0.5f);
        var _S14 : vec2<i32> = vec2<i32>(floor(at_0));
        var f_0 : vec2<f32> = at_0 - vec2<f32>(_S14);
        var _S15 : vec2<i32> = vec2<i32>(i32(0));
        var _S16 : f32 = f_0.x;
        var _S17 : f32 = 1.0f - _S16;
        var _S18 : f32 = f_0.y;
        var _S19 : f32 = 1.0f - _S18;
        var _S20 : vec4<f32> = blended_0(clamp(_S14, _S15, hi_0), _S17 * _S19) + blended_0(clamp(_S14 + vec2<i32>(i32(1), i32(0)), _S15, hi_0), _S16 * _S19) + blended_0(clamp(_S14 + vec2<i32>(i32(0), i32(1)), _S15, hi_0), _S17 * _S18) + blended_0(clamp(_S14 + vec2<i32>(i32(1), i32(1)), _S15, hi_0), _S16 * _S18);
        t_1 = _S20;
        if((_S20.w) > 0.0f)
        {
            var _S21 : vec3<f32> = t_1.xyz / vec3<f32>(t_1.w);
            t_1.x = _S21.x;
            t_1.y = _S21.y;
            t_1.z = _S21.z;
        }
    }
    var below_0 : vec3<f32> = neutral_inverse_0(srgb_decode_0(under_0));
    var shown_0 : vec3<f32>;
    if((t_1.w) > 0.0f)
    {
        shown_0 = t_1.xyz * vec3<f32>(exp2(Display_Uniforms_0.params_0.x));
    }
    else
    {
        shown_0 = below_0;
    }
    var _S22 : pixelOutput_0 = pixelOutput_0( vec4<f32>(mix(below_0, shown_0, vec3<f32>(clamp(t_1.w, 0.0f, 1.0f))), 1.0f) );
    return _S22;
}

