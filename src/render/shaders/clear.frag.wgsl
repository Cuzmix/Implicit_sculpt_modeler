// slangc wgsl from clear.frag.spv sha256 7cc459a12d95caee7fadd940b75c635a402449001dffe971a49c38e08004fc0c
struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Clear_Uniforms_std140_0
{
    @align(16) top_0 : vec4<f32>,
    @align(16) bottom_0 : vec4<f32>,
    @align(16) extent_0 : vec4<f32>,
    @align(16) env_0 : vec4<f32>,
    @align(16) clip_to_env_0 : _MatrixStorage_float4x4std140_0,
};

@binding(0) @group(3) var<uniform> Clear_Uniforms_0 : SLANG_ParameterGroup_Clear_Uniforms_std140_0;
@binding(0) @group(2) var environment_map_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var environment_map_sampler_0 : sampler;

var<private> BAYER_0 : array<f32, i32(16)> = array<f32, i32(16)>( 0.0f, 8.0f, 2.0f, 10.0f, 12.0f, 4.0f, 14.0f, 6.0f, 3.0f, 11.0f, 1.0f, 9.0f, 15.0f, 7.0f, 13.0f, 5.0f );
fn panorama_uv_0( d_0 : vec3<f32>) -> vec2<f32>
{
    return vec2<f32>(atan2(d_0.x, - d_0.z - 9.99999968265522539e-21f) * 0.15915493667125702f + 0.5f, acos(clamp(d_0.y, -1.0f, 1.0f)) * 0.31830990314483643f);
}

fn tone_map_0( c_0 : vec3<f32>) -> vec3<f32>
{
    var _S1 : f32 = min(c_0.x, min(c_0.y, c_0.z));
    var offset_0 : f32;
    if(_S1 < 0.07999999821186066f)
    {
        offset_0 = _S1 - 6.25f * _S1 * _S1;
    }
    else
    {
        offset_0 = 0.03999999910593033f;
    }
    var _S2 : vec3<f32> = c_0 - vec3<f32>(offset_0);
    var _S3 : f32 = max(_S2.x, max(_S2.y, _S2.z));
    if(_S3 < 0.75999999046325684f)
    {
        return _S2;
    }
    var new_peak_0 : f32 = 1.0f - 0.0576000027358532f / (_S3 + 0.24000000953674316f - 0.75999999046325684f);
    return mix(_S2 * vec3<f32>((new_peak_0 / _S3)), vec3<f32>(new_peak_0), vec3<f32>((1.0f - 1.0f / (0.15000000596046448f * (_S3 - new_peak_0) + 1.0f))));
}

fn srgb_encode_0( c_1 : vec3<f32>) -> vec3<f32>
{
    var _S4 : vec3<f32> = clamp(c_1, vec3<f32>(0.0f), vec3<f32>(1.0f));
    return mix(vec3<f32>(12.92000007629394531f) * _S4, vec3<f32>(1.0549999475479126f) * pow(_S4, vec3<f32>(0.4166666567325592f)) - vec3<f32>(0.05499999970197678f), step(vec3<f32>(0.00313080009073019f), _S4));
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
    var p_0 : vec2<i32> = (vec2<i32>(frag_coord_0.xy) & (vec2<i32>(i32(3))));
    var dither_0 : f32 = ((BAYER_0[p_0.y * i32(4) + p_0.x] + 0.5f) / 16.0f - 0.5f) / 255.0f;
    if((Clear_Uniforms_0.env_0.x) > 0.5f)
    {
        var ndc_0 : vec2<f32> = vec2<f32>(2.0f * frag_coord_0.x / Clear_Uniforms_0.extent_0.y - 1.0f, 1.0f - 2.0f * frag_coord_0.y / Clear_Uniforms_0.extent_0.x);
        var a_0 : vec4<f32> = (((mat4x4<f32>(Clear_Uniforms_0.clip_to_env_0.data_0[i32(0)][i32(0)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(0)][i32(1)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(0)][i32(2)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(0)][i32(3)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(1)][i32(0)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(1)][i32(1)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(1)][i32(2)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(1)][i32(3)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(2)][i32(0)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(2)][i32(1)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(2)][i32(2)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(2)][i32(3)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(3)][i32(0)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(3)][i32(1)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(3)][i32(2)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(ndc_0, 0.0f, 1.0f))));
        var b_0 : vec4<f32> = (((mat4x4<f32>(Clear_Uniforms_0.clip_to_env_0.data_0[i32(0)][i32(0)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(0)][i32(1)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(0)][i32(2)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(0)][i32(3)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(1)][i32(0)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(1)][i32(1)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(1)][i32(2)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(1)][i32(3)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(2)][i32(0)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(2)][i32(1)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(2)][i32(2)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(2)][i32(3)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(3)][i32(0)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(3)][i32(1)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(3)][i32(2)], Clear_Uniforms_0.clip_to_env_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(ndc_0, 1.0f, 1.0f))));
        var _S5 : pixelOutput_0 = pixelOutput_0( vec4<f32>(display_color_0((textureSampleLevel((environment_map_texture_0), (environment_map_sampler_0), (panorama_uv_0(normalize(b_0.xyz / vec3<f32>(b_0.w) - a_0.xyz / vec3<f32>(a_0.w)))), (Clear_Uniforms_0.env_0.z))).xyz * vec3<f32>(Clear_Uniforms_0.env_0.y), Clear_Uniforms_0.env_0.w) + vec3<f32>(dither_0), 1.0f) );
        return _S5;
    }
    if((all(((Clear_Uniforms_0.top_0) == (Clear_Uniforms_0.bottom_0)))))
    {
        var _S6 : pixelOutput_0 = pixelOutput_0( Clear_Uniforms_0.top_0 );
        return _S6;
    }
    var t_0 : f32 = clamp(frag_coord_0.y / Clear_Uniforms_0.extent_0.x, 0.0f, 1.0f);
    var _S7 : pixelOutput_0 = pixelOutput_0( vec4<f32>(mix(Clear_Uniforms_0.top_0.xyz, Clear_Uniforms_0.bottom_0.xyz, vec3<f32>(t_0)) + vec3<f32>(dither_0), mix(Clear_Uniforms_0.top_0.w, Clear_Uniforms_0.bottom_0.w, t_0)) );
    return _S7;
}

