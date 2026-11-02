// slangc wgsl from render_atrous.frag.spv sha256 9925bb31d909c91dc08f7950dac7a8b7a5c8e0d39104c0cfa6b4bd88507e2204
@binding(0) @group(2) var src_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var src_sampler_0 : sampler;

struct SLANG_ParameterGroup_Atrous_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Atrous_Uniforms_0 : SLANG_ParameterGroup_Atrous_Uniforms_std140_0;
@binding(2) @group(2) var guide_albedo_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var guide_albedo_sampler_0 : sampler;

@binding(4) @group(2) var guide_normal_texture_0 : texture_2d<f32>;

@binding(5) @group(2) var guide_normal_sampler_0 : sampler;

var<private> KERNEL_0 : array<f32, i32(3)> = array<f32, i32(3)>( 0.375f, 0.25f, 0.0625f );
fn texture_size_0( t_texture_0 : texture_2d<f32>,  t_sampler_0 : sampler) -> vec2<i32>
{
    var w_0 : u32;
    var h_0 : u32;
    var levels_0 : u32;
    {var dim = textureDimensions((t_texture_0), (u32(0)));((w_0)) = dim.x;((h_0)) = dim.y;((levels_0)) = textureNumLevels((t_texture_0));};
    return vec2<i32>(i32(w_0), i32(h_0));
}

fn light_at_0( px_0 : vec2<i32>) -> vec3<f32>
{
    var _S1 : vec3<i32> = vec3<i32>(px_0, i32(0));
    var _S2 : vec4<f32> = (textureLoad((src_texture_0), ((src_sampler_0)).xy, ((src_sampler_0)).z));
    if((Atrous_Uniforms_0.params_0.z) < 0.5f)
    {
        return _S2.xyz;
    }
    var mean_0 : vec3<f32> = _S2.xyz / vec3<f32>(max(_S2.w, 1.0f));
    var _S3 : vec4<f32> = (textureLoad((guide_albedo_texture_0), ((guide_albedo_sampler_0)).xy, ((guide_albedo_sampler_0)).z));
    var _S4 : vec3<f32>;
    if((_S3.w) > 0.0f)
    {
        _S4 = mean_0 / max(_S3.xyz, vec3<f32>(0.01999999955296516f));
    }
    else
    {
        _S4 = mean_0;
    }
    return _S4;
}

fn luminance_0( c_0 : vec3<f32>) -> f32
{
    return dot(c_0, vec3<f32>(0.2125999927520752f, 0.71520000696182251f, 0.07220000028610229f));
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S5 : vec2<i32> = vec2<i32>(frag_coord_0.xy);
    var _S6 : vec2<i32> = texture_size_0(src_texture_0, src_sampler_0) - vec2<i32>(i32(1));
    var centre_0 : vec3<f32> = light_at_0(_S5);
    var _S7 : vec3<i32> = vec3<i32>(_S5, i32(0));
    var _S8 : vec4<f32> = (textureLoad((guide_albedo_texture_0), ((guide_albedo_sampler_0)).xy, ((guide_albedo_sampler_0)).z));
    if((_S8.w) <= 0.0f)
    {
        var _S9 : pixelOutput_0 = pixelOutput_0( vec4<f32>(centre_0, 1.0f) );
        return _S9;
    }
    var gn_0 : vec4<f32> = (textureLoad((guide_normal_texture_0), ((guide_normal_sampler_0)).xy, ((guide_normal_sampler_0)).z));
    if((Atrous_Uniforms_0.params_0.w) > 0.5f)
    {
        var _S10 : vec3<f32> = normalize(gn_0.xyz + vec3<f32>(0.0f, 0.0f, 9.99999997475242708e-07f));
        gn_0.x = _S10.x;
        gn_0.y = _S10.y;
        gn_0.z = _S10.z;
    }
    var _S11 : i32 = i32(Atrous_Uniforms_0.params_0.x);
    var _S12 : f32 = luminance_0(centre_0);
    var _S13 : vec3<f32> = vec3<f32>(0.0f);
    var y_0 : i32 = i32(-2);
    var sum_0 : vec3<f32> = _S13;
    var total_0 : f32 = 0.0f;
    for(;;)
    {
        if(y_0 <= i32(2))
        {
        }
        else
        {
            break;
        }
        var x_0 : i32 = i32(-2);
        var sum_1 : vec3<f32> = sum_0;
        var total_1 : f32 = total_0;
        for(;;)
        {
            if(x_0 <= i32(2))
            {
            }
            else
            {
                break;
            }
            var q_0 : vec2<i32> = clamp(_S5 + vec2<i32>(x_0, y_0) * vec2<i32>(_S11), vec2<i32>(i32(0)), _S6);
            var _S14 : vec3<i32> = vec3<i32>(q_0, i32(0));
            var _S15 : vec4<f32> = (textureLoad((guide_albedo_texture_0), ((guide_albedo_sampler_0)).xy, ((guide_albedo_sampler_0)).z));
            if((_S15.w) <= 0.0f)
            {
                x_0 = x_0 + i32(1);
                continue;
            }
            var qn_0 : vec4<f32> = (textureLoad((guide_normal_texture_0), ((guide_normal_sampler_0)).xy, ((guide_normal_sampler_0)).z));
            if((Atrous_Uniforms_0.params_0.w) > 0.5f)
            {
                var _S16 : vec3<f32> = normalize(qn_0.xyz + vec3<f32>(0.0f, 0.0f, 9.99999997475242708e-07f));
                qn_0.x = _S16.x;
                qn_0.y = _S16.y;
                qn_0.z = _S16.z;
            }
            var c_1 : vec3<f32> = light_at_0(q_0);
            var da_0 : vec3<f32> = _S8.xyz - _S15.xyz;
            var _S17 : f32 = luminance_0(c_1);
            var w_1 : f32 = KERNEL_0[abs(x_0)] * KERNEL_0[abs(y_0)] * pow(max(dot(gn_0.xyz, qn_0.xyz), 0.0f), 64.0f) * exp(- abs(gn_0.w - qn_0.w) / (0.00999999977648258f * gn_0.w * f32(_S11) + 9.99999997475242708e-07f)) * exp(- dot(da_0, da_0) / 0.00999999977648258f) * exp(- (abs(_S17 - _S12) / (0.5f * (_S17 + _S12) + 0.00100000004749745f)) / Atrous_Uniforms_0.params_0.y);
            var total_2 : f32 = total_1 + w_1;
            sum_1 = sum_1 + c_1 * vec3<f32>(w_1);
            total_1 = total_2;
            x_0 = x_0 + i32(1);
        }
        y_0 = y_0 + i32(1);
        sum_0 = sum_1;
        total_0 = total_1;
    }
    if(total_0 > 0.0f)
    {
        sum_0 = sum_0 / vec3<f32>(total_0);
    }
    else
    {
        sum_0 = centre_0;
    }
    var _S18 : pixelOutput_0 = pixelOutput_0( vec4<f32>(sum_0, 1.0f) );
    return _S18;
}

