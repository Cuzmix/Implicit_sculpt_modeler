// slangc wgsl from env_prefilter.frag.spv sha256 2008435844bb971eb3c4cbcd02ad636b00489be5981e4ceedc1012285ce90b99
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Prefilter_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
    @align(16) target_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Prefilter_Uniforms_0 : SLANG_ParameterGroup_Prefilter_Uniforms_std140_0;
@binding(0) @group(2) var source_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var source_sampler_0 : sampler;

fn panorama_dir_0( uv_0 : vec2<f32>) -> vec3<f32>
{
    var theta_0 : f32 = uv_0.y * 3.14159274101257324f;
    var phi_0 : f32 = (uv_0.x - 0.5f) * 6.28318548202514648f;
    var s_0 : f32 = sin(theta_0);
    return vec3<f32>(sin(phi_0) * s_0, cos(theta_0), - cos(phi_0) * s_0);
}

fn hammersley_0( i_0 : u32) -> vec2<f32>
{
    return vec2<f32>(f32(i_0) / 64.0f, f32(reverseBits(i_0)) * 2.32830643653869629e-10f);
}

fn panorama_uv_0( d_0 : vec3<f32>) -> vec2<f32>
{
    return vec2<f32>(atan2(d_0.x, - d_0.z - 9.99999968265522539e-21f) * 0.15915493667125702f + 0.5f, acos(clamp(d_0.y, -1.0f, 1.0f)) * 0.31830990314483643f);
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var uv_1 : vec2<f32> = frag_coord_0.xy / Prefilter_Uniforms_0.target_0.xy;
    var rough_0 : f32 = Prefilter_Uniforms_0.params_0.x;
    if(rough_0 <= 0.0f)
    {
        var _S1 : pixelOutput_0 = pixelOutput_0( vec4<f32>((textureSampleLevel((source_texture_0), (source_sampler_0), (uv_1), (Prefilter_Uniforms_0.target_0.z))).xyz, 1.0f) );
        return _S1;
    }
    var n_0 : vec3<f32> = panorama_dir_0(uv_1);
    var up_0 : vec3<f32>;
    if((abs(n_0.y)) < 0.99900001287460327f)
    {
        up_0 = vec3<f32>(0.0f, 1.0f, 0.0f);
    }
    else
    {
        up_0 = vec3<f32>(1.0f, 0.0f, 0.0f);
    }
    var t_0 : vec3<f32> = normalize(cross(up_0, n_0));
    var _S2 : vec3<f32> = cross(n_0, t_0);
    var a_0 : f32 = rough_0 * rough_0;
    var _S3 : f32 = a_0 * a_0;
    var _S4 : f32 = 12.56637096405029297f / (Prefilter_Uniforms_0.params_0.y * Prefilter_Uniforms_0.params_0.z);
    var _S5 : vec3<f32> = vec3<f32>(0.0f);
    var i_1 : u32 = u32(0);
    var sum_0 : vec3<f32> = _S5;
    var weight_0 : f32 = 0.0f;
    for(;;)
    {
        if(i_1 < u32(64))
        {
        }
        else
        {
            break;
        }
        var xi_0 : vec2<f32> = hammersley_0(i_1);
        var phi_1 : f32 = 6.28318548202514648f * xi_0.x;
        var _S6 : f32 = xi_0.y;
        var _S7 : f32 = _S3 - 1.0f;
        var cos_t_0 : f32 = sqrt((1.0f - _S6) / (1.0f + _S7 * _S6));
        var _S8 : f32 = cos_t_0 * cos_t_0;
        var sin_t_0 : f32 = sqrt(max(1.0f - _S8, 0.0f));
        var h_0 : vec3<f32> = t_0 * vec3<f32>((sin_t_0 * cos(phi_1))) + _S2 * vec3<f32>((sin_t_0 * sin(phi_1))) + n_0 * vec3<f32>(cos_t_0);
        var l_0 : vec3<f32> = vec3<f32>((2.0f * dot(n_0, h_0))) * h_0 - n_0;
        var n_dot_l_0 : f32 = dot(n_0, l_0);
        if(n_dot_l_0 <= 0.0f)
        {
            i_1 = i_1 + u32(1);
            continue;
        }
        var d_1 : f32 = _S8 * _S7 + 1.0f;
        var weight_1 : f32 = weight_0 + n_dot_l_0;
        sum_0 = sum_0 + (textureSampleLevel((source_texture_0), (source_sampler_0), (panorama_uv_0(l_0)), (max(0.5f * log2(1.0f / (64.0f * (_S3 / (3.14159274101257324f * d_1 * d_1) / 4.0f) * _S4)) + 1.0f, 0.0f)))).xyz * vec3<f32>(n_dot_l_0);
        weight_0 = weight_1;
        i_1 = i_1 + u32(1);
    }
    var _S9 : pixelOutput_0 = pixelOutput_0( vec4<f32>(sum_0 / vec3<f32>(max(weight_0, 9.99999997475242708e-07f)), 1.0f) );
    return _S9;
}

