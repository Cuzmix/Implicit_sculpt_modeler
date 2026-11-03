// slangc wgsl from bloom_up.frag.spv sha256 5c31954aaf11c958715d6f765d9e7f352093db06e81724fddecfde1bbce58263
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Bloom_Up_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
    @align(16) size_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Bloom_Up_Uniforms_0 : SLANG_ParameterGroup_Bloom_Up_Uniforms_std140_0;
@binding(0) @group(2) var coarse_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var coarse_sampler_0 : sampler;

@binding(2) @group(2) var fine_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var fine_sampler_0 : sampler;

fn texture_size_0( t_texture_0 : texture_2d<f32>,  t_sampler_0 : sampler) -> vec2<i32>
{
    var w_0 : u32;
    var h_0 : u32;
    var levels_0 : u32;
    {var dim = textureDimensions((t_texture_0), (u32(0)));((w_0)) = dim.x;((h_0)) = dim.y;((levels_0)) = textureNumLevels((t_texture_0));};
    return vec2<i32>(i32(w_0), i32(h_0));
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var uv_0 : vec2<f32> = frag_coord_0.xy * Bloom_Up_Uniforms_0.size_0.xy;
    var t_0 : vec2<f32> = vec2<f32>(1.0f) / vec2<f32>(texture_size_0(coarse_texture_0, coarse_sampler_0));
    var _S1 : pixelOutput_0 = pixelOutput_0( vec4<f32>(mix((textureSampleLevel((fine_texture_0), (fine_sampler_0), (uv_0), (0.0f))).xyz, (vec3<f32>(4.0f) * (textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0), (0.0f))).xyz + vec3<f32>(2.0f) * ((textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0 + t_0 * vec2<f32>(0.0f, -1.0f)), (0.0f))).xyz + (textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0 + t_0 * vec2<f32>(-1.0f, 0.0f)), (0.0f))).xyz + (textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0 + t_0 * vec2<f32>(1.0f, 0.0f)), (0.0f))).xyz + (textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0 + t_0 * vec2<f32>(0.0f, 1.0f)), (0.0f))).xyz) + ((textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0 + t_0 * vec2<f32>(-1.0f, -1.0f)), (0.0f))).xyz + (textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0 + t_0 * vec2<f32>(1.0f, -1.0f)), (0.0f))).xyz + (textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0 + t_0 * vec2<f32>(-1.0f, 1.0f)), (0.0f))).xyz + (textureSampleLevel((coarse_texture_0), (coarse_sampler_0), (uv_0 + t_0), (0.0f))).xyz)) / vec3<f32>(16.0f), vec3<f32>(Bloom_Up_Uniforms_0.params_0.x)), 1.0f) );
    return _S1;
}

