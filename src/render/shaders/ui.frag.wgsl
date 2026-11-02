// slangc wgsl from ui.frag.spv sha256 27b36442b9eb8e6ead0810a4529e9bfe0b995ed5c481cb5e7586856a36706ff2
struct SLANG_ParameterGroup_Ui_Fragment_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Ui_Fragment_Uniforms_0 : SLANG_ParameterGroup_Ui_Fragment_Uniforms_std140_0;
@binding(0) @group(2) var tex_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var tex_sampler_0 : sampler;

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

struct pixelInput_0
{
    @location(0) uv_0 : vec2<f32>,
    @location(1) color_0 : vec4<f32>,
};

@fragment
fn main( _S1 : pixelInput_0) -> pixelOutput_0
{
    var _S2 : vec2<f32> = _S1.uv_0 * Ui_Fragment_Uniforms_0.params_0.xy;
    ;
    var s_0 : vec4<f32> = (textureSample((tex_texture_0), (tex_sampler_0), (_S2)));
    if((Ui_Fragment_Uniforms_0.params_0.w) > 0.5f)
    {
        var _S3 : vec3<f32> = s_0.xyz / vec3<f32>(max(s_0.w, 0.00392156885936856f));
        s_0.x = _S3.x;
        s_0.y = _S3.y;
        s_0.z = _S3.z;
    }
    var _S4 : vec4<f32>;
    if((Ui_Fragment_Uniforms_0.params_0.z) > 0.5f)
    {
        _S4 = _S1.color_0 * s_0;
    }
    else
    {
        _S4 = vec4<f32>(_S1.color_0.xyz, _S1.color_0.w * s_0.x);
    }
    var _S5 : pixelOutput_0 = pixelOutput_0( _S4 );
    return _S5;
}

