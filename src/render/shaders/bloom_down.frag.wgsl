// slangc wgsl from bloom_down.frag.spv sha256 0c6a396d73d52306182f7627e1d56be1719f216013f99d27b551d21626fa98f3
struct SLANG_ParameterGroup_Bloom_Down_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
    @align(16) size_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Bloom_Down_Uniforms_0 : SLANG_ParameterGroup_Bloom_Down_Uniforms_std140_0;
@binding(0) @group(2) var input_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var input_sampler_0 : sampler;

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

fn bloom_decode_0( v_0 : vec3<f32>) -> vec3<f32>
{
    var shown_0 : vec3<f32> = srgb_decode_0(v_0);
    var c_3 : vec3<f32> = neutral_inverse_0(shown_0);
    var residual_0 : vec3<f32> = shown_0 - tone_map_0(c_3);
    const weights_0 : vec3<f32> = vec3<f32>(0.2125999927520752f, 0.71520000696182251f, 0.07220000028610229f);
    return mix(c_3, shown_0 * vec3<f32>(dot(c_3, weights_0)) / vec3<f32>(max(dot(shown_0, weights_0), 0.00009999999747379f)), vec3<f32>(max(smoothstep(0.00999999977648258f, 0.05000000074505806f, max(abs(residual_0.x), max(abs(residual_0.y), abs(residual_0.z)))), smoothstep(0.85000002384185791f, 0.97000002861022949f, max(shown_0.x, max(shown_0.y, shown_0.z))))));
}

fn above_threshold_0( c_4 : vec3<f32>,  threshold_0 : f32) -> vec3<f32>
{
    if(threshold_0 <= 0.0f)
    {
        return c_4;
    }
    var _S6 : f32 = max(c_4.x, max(c_4.y, c_4.z));
    var knee_0 : f32 = 0.5f * threshold_0;
    var _S7 : f32 = _S6 - threshold_0;
    var q_0 : f32 = clamp(_S7 + knee_0, 0.0f, 2.0f * knee_0);
    return c_4 * vec3<f32>(max(q_0 * q_0 / (4.0f * knee_0), _S7)) / vec3<f32>(max(_S6, 0.00009999999747379f));
}

fn light_0( uv_0 : vec2<f32>) -> vec3<f32>
{
    var c_5 : vec3<f32> = (textureSampleLevel((input_texture_0), (input_sampler_0), (uv_0), (0.0f))).xyz;
    if((Bloom_Down_Uniforms_0.params_0.x) < 0.5f)
    {
        return c_5;
    }
    var c_6 : vec3<f32>;
    if((Bloom_Down_Uniforms_0.params_0.y) < 0.5f)
    {
        c_6 = bloom_decode_0(c_5);
    }
    else
    {
        c_6 = c_5;
    }
    return above_threshold_0(clamp(c_6, vec3<f32>(0.0f), vec3<f32>(30000.0f)), Bloom_Down_Uniforms_0.params_0.z);
}

fn box_0( a_0 : vec3<f32>,  b_0 : vec3<f32>,  c_7 : vec3<f32>,  d_0 : vec3<f32>,  weight_0 : ptr<function, f32>) -> vec3<f32>
{
    var m_0 : vec3<f32> = vec3<f32>(0.25f) * (a_0 + b_0 + c_7 + d_0);
    var _S8 : f32;
    if((Bloom_Down_Uniforms_0.params_0.x) > 0.5f)
    {
        _S8 = 1.0f / (1.0f + dot(m_0, vec3<f32>(0.2125999927520752f, 0.71520000696182251f, 0.07220000028610229f)));
    }
    else
    {
        _S8 = 1.0f;
    }
    (*weight_0) = _S8;
    return m_0;
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var uv_1 : vec2<f32> = frag_coord_0.xy * Bloom_Down_Uniforms_0.size_0.xy;
    var t_0 : vec2<f32> = vec2<f32>(1.0f) / vec2<f32>(texture_size_0(input_texture_0, input_sampler_0));
    var a_1 : vec3<f32> = light_0(uv_1 + t_0 * vec2<f32>(-2.0f, -2.0f));
    var b_1 : vec3<f32> = light_0(uv_1 + t_0 * vec2<f32>(0.0f, -2.0f));
    var c_8 : vec3<f32> = light_0(uv_1 + t_0 * vec2<f32>(2.0f, -2.0f));
    var d_1 : vec3<f32> = light_0(uv_1 + t_0 * vec2<f32>(-2.0f, 0.0f));
    var e_0 : vec3<f32> = light_0(uv_1);
    var f_0 : vec3<f32> = light_0(uv_1 + t_0 * vec2<f32>(2.0f, 0.0f));
    var g_1 : vec3<f32> = light_0(uv_1 + t_0 * vec2<f32>(-2.0f, 2.0f));
    var h_1 : vec3<f32> = light_0(uv_1 + t_0 * vec2<f32>(0.0f, 2.0f));
    var i_0 : vec3<f32> = light_0(uv_1 + t_0 * vec2<f32>(2.0f, 2.0f));
    var w0_0 : f32;
    var inner_0 : vec3<f32> = box_0(light_0(uv_1 + t_0 * vec2<f32>(-1.0f, -1.0f)), light_0(uv_1 + t_0 * vec2<f32>(1.0f, -1.0f)), light_0(uv_1 + t_0 * vec2<f32>(-1.0f, 1.0f)), light_0(uv_1 + t_0), &(w0_0));
    var w1_0 : f32;
    var b1_0 : vec3<f32> = box_0(a_1, b_1, d_1, e_0, &(w1_0));
    var w2_0 : f32;
    var b2_0 : vec3<f32> = box_0(b_1, c_8, e_0, f_0, &(w2_0));
    var w3_0 : f32;
    var b3_0 : vec3<f32> = box_0(d_1, e_0, g_1, h_1, &(w3_0));
    var w4_0 : f32;
    var b4_0 : vec3<f32> = box_0(e_0, f_0, h_1, i_0, &(w4_0));
    var _S9 : f32 = w0_0 * 0.5f;
    w0_0 = _S9;
    var _S10 : f32 = w1_0 * 0.125f;
    w1_0 = _S10;
    var _S11 : f32 = w2_0 * 0.125f;
    w2_0 = _S11;
    var _S12 : f32 = w3_0 * 0.125f;
    w3_0 = _S12;
    var _S13 : f32 = w4_0 * 0.125f;
    w4_0 = _S13;
    var _S14 : pixelOutput_0 = pixelOutput_0( vec4<f32>((inner_0 * vec3<f32>(_S9) + b1_0 * vec3<f32>(_S10) + b2_0 * vec3<f32>(_S11) + b3_0 * vec3<f32>(_S12) + b4_0 * vec3<f32>(_S13)) / vec3<f32>((_S9 + _S10 + _S11 + _S12 + _S13)), 1.0f) );
    return _S14;
}

