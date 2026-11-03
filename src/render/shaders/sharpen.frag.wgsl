// slangc wgsl from sharpen.frag.spv sha256 1cf0840b1af5897bdec06a7096de32ca98fff55a9f872f5481f956da61542d7e
diagnostic(off, derivative_uniformity);
@binding(0) @group(2) var graded_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var graded_sampler_0 : sampler;

struct SLANG_ParameterGroup_Sharpen_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Sharpen_Uniforms_0 : SLANG_ParameterGroup_Sharpen_Uniforms_std140_0;
fn texture_size_0( t_texture_0 : texture_2d<f32>,  t_sampler_0 : sampler) -> vec2<i32>
{
    var w_0 : u32;
    var h_0 : u32;
    var levels_0 : u32;
    {var dim = textureDimensions((t_texture_0), (u32(0)));((w_0)) = dim.x;((h_0)) = dim.y;((levels_0)) = textureNumLevels((t_texture_0));};
    return vec2<i32>(i32(w_0), i32(h_0));
}

fn at_0( p_0 : vec2<i32>) -> vec3<f32>
{
    return saturate((textureLoad((graded_texture_0), ((graded_sampler_0)).xy, ((graded_sampler_0)).z)).xyz);
}

fn lattice_noise_0( p_1 : vec2<i32>,  seed_0 : u32) -> f32
{
    var h_1 : u32 = ((((u32(p_1.x) * u32(2376512323)) ^ ((u32(p_1.y) * u32(3625334849))))) ^ ((seed_0 * u32(3407524639))));
    var h_2 : u32 = ((h_1 ^ (((h_1 >> (u32(15))))))) * u32(739982445);
    var h_3 : u32 = ((h_2 ^ (((h_2 >> (u32(12))))))) * u32(695872825);
    return f32((h_3 ^ (((h_3 >> (u32(15))))))) / 2.147483648e+09f - 1.0f;
}

fn grain_at_0( px_0 : vec2<f32>,  size_0 : f32,  seed_1 : u32) -> f32
{
    var at_1 : vec2<f32> = px_0 / vec2<f32>(size_0);
    var _S1 : vec2<i32> = vec2<i32>(floor(at_1));
    var f_0 : vec2<f32> = at_1 - vec2<f32>(_S1);
    var f_1 : vec2<f32> = f_0 * f_0 * (vec2<f32>(3.0f) - vec2<f32>(2.0f) * f_0);
    var _S2 : f32 = f_1.x;
    return mix(mix(lattice_noise_0(_S1, seed_1), lattice_noise_0(_S1 + vec2<i32>(i32(1), i32(0)), seed_1), _S2), mix(lattice_noise_0(_S1 + vec2<i32>(i32(0), i32(1)), seed_1), lattice_noise_0(_S1 + vec2<i32>(i32(1), i32(1)), seed_1), _S2), f_1.y);
}

fn gradient_noise_0( px_1 : vec2<f32>) -> f32
{
    return fract(52.98291778564453125f * fract(dot(px_1, vec2<f32>(0.06711056083440781f, 0.00583714991807938f))));
}

fn grain_and_dither_0( e_0 : vec3<f32>,  px_2 : vec2<f32>,  strength_0 : f32,  size_1 : f32,  seed_2 : u32) -> vec3<f32>
{
    var _S3 : vec3<f32>;
    if(strength_0 > 0.0f)
    {
        var l_0 : f32 = clamp(dot(e_0, vec3<f32>(0.2125999927520752f, 0.71520000696182251f, 0.07220000028610229f)), 0.0f, 1.0f);
        _S3 = e_0 + vec3<f32>((0.11999999731779099f * strength_0 * 4.0f * l_0 * (1.0f - l_0) * grain_at_0(px_2, size_1, seed_2)));
    }
    else
    {
        _S3 = e_0;
    }
    return _S3 + vec3<f32>(((gradient_noise_0(px_2) - 0.5f) / 255.0f));
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S4 : vec2<f32> = frag_coord_0.xy;
    var _S5 : vec2<i32> = vec2<i32>(_S4);
    var a_0 : vec3<f32> = at_0(_S5 + vec2<i32>(i32(-1), i32(-1)));
    var b_0 : vec3<f32> = at_0(_S5 + vec2<i32>(i32(0), i32(-1)));
    var c_0 : vec3<f32> = at_0(_S5 + vec2<i32>(i32(1), i32(-1)));
    var d_0 : vec3<f32> = at_0(_S5 + vec2<i32>(i32(-1), i32(0)));
    var e_1 : vec3<f32> = at_0(_S5);
    var f_2 : vec3<f32> = at_0(_S5 + vec2<i32>(i32(1), i32(0)));
    var g_0 : vec3<f32> = at_0(_S5 + vec2<i32>(i32(-1), i32(1)));
    var h_4 : vec3<f32> = at_0(_S5 + vec2<i32>(i32(0), i32(1)));
    var i_0 : vec3<f32> = at_0(_S5 + vec2<i32>(i32(1), i32(1)));
    var lo_0 : vec3<f32> = min(min(min(d_0, e_1), min(f_2, b_0)), h_4);
    var lo_1 : vec3<f32> = lo_0 + min(lo_0, min(min(a_0, c_0), min(g_0, i_0)));
    var hi_0 : vec3<f32> = max(max(max(d_0, e_1), max(f_2, b_0)), h_4);
    var hi_1 : vec3<f32> = hi_0 + max(hi_0, max(max(a_0, c_0), max(g_0, i_0)));
    var w_1 : vec3<f32> = sqrt(saturate(min(lo_1, vec3<f32>(2.0f) - hi_1) / max(hi_1, vec3<f32>(0.00000999999974738f)))) * smoothstep(vec3<f32>(0.0058823530562222f), vec3<f32>(0.01568627543747425f), vec3<f32>(0.5f) * (hi_1 - lo_1)) * vec3<f32>((-1.0f / mix(8.0f, 5.0f, saturate(Sharpen_Uniforms_0.params_0.x))));
    var _S6 : pixelOutput_0 = pixelOutput_0( vec4<f32>(grain_and_dither_0(saturate((w_1 * (b_0 + d_0 + f_2 + h_4) + e_1) / (vec3<f32>(1.0f) + vec3<f32>(4.0f) * w_1)), _S4, Sharpen_Uniforms_0.params_0.y, Sharpen_Uniforms_0.params_0.z, (bitcast<u32>((Sharpen_Uniforms_0.params_0.w)))), (textureLoad((graded_texture_0), ((graded_sampler_0)).xy, ((graded_sampler_0)).z)).w) );
    return _S6;
}

