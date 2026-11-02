// slangc wgsl from studio_composite.frag.spv sha256 685cca1bac19695ac23cbedf1f1bb14ea674f301b8388403eb8bc6f309963264
@binding(0) @group(2) var view_color_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var view_color_sampler_0 : sampler;

@binding(2) @group(2) var accum_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var accum_sampler_0 : sampler;

struct SLANG_ParameterGroup_Composite_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Composite_Uniforms_0 : SLANG_ParameterGroup_Composite_Uniforms_std140_0;
@binding(4) @group(2) var under_texture_0 : texture_2d<f32>;

@binding(5) @group(2) var under_sampler_0 : sampler;

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S1 : vec3<i32> = vec3<i32>(vec2<i32>(frag_coord_0.xy), i32(0));
    var _S2 : vec4<f32> = (textureLoad((view_color_texture_0), ((view_color_sampler_0)).xy, ((view_color_sampler_0)).z));
    var _S3 : vec4<f32> = (textureLoad((accum_texture_0), ((accum_sampler_0)).xy, ((accum_sampler_0)).z));
    var _S4 : f32 = _S3.y;
    var ao_0 : f32;
    if(_S4 > 0.0f)
    {
        ao_0 = _S3.x / _S4;
    }
    else
    {
        ao_0 = 1.0f;
    }
    var _S5 : f32 = _S3.w;
    var lit_0 : f32;
    if(_S5 > 0.0f)
    {
        lit_0 = _S3.z / _S5;
    }
    else
    {
        lit_0 = 1.0f;
    }
    if((Composite_Uniforms_0.params_0.z) > 0.0f)
    {
        lit_0 = mix(1.0f, lit_0, saturate(_S5 / Composite_Uniforms_0.params_0.w));
    }
    else
    {
    }
    var shade_0 : f32 = mix(1.0f, ao_0 * ao_0 * (3.0f - 2.0f * ao_0), Composite_Uniforms_0.params_0.x) * mix(1.0f, lit_0, Composite_Uniforms_0.params_0.y);
    if((Composite_Uniforms_0.params_0.z) <= 0.0f)
    {
        var _S6 : pixelOutput_0 = pixelOutput_0( vec4<f32>(_S2.xyz * vec3<f32>(shade_0), _S2.w) );
        return _S6;
    }
    var _S7 : pixelOutput_0 = pixelOutput_0( vec4<f32>(mix((textureLoad((under_texture_0), ((under_sampler_0)).xy, ((under_sampler_0)).z)).xyz, _S2.xyz * vec3<f32>(shade_0), vec3<f32>(saturate(_S4 / Composite_Uniforms_0.params_0.z))), _S2.w) );
    return _S7;
}

