// slangc wgsl from ui.frag.spv sha256 7d5ec14dc85dd7574a3f8210f9a76cbce217ff9689bd0f0ba420f2a29feab24f
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Ui_Fragment_Uniforms_std140_0
{
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Ui_Fragment_Uniforms_0 : SLANG_ParameterGroup_Ui_Fragment_Uniforms_std140_0;
@binding(0) @group(2) var tex_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var tex_sampler_0 : sampler;

fn ui_srgb_encode_0( c_0 : vec3<f32>) -> vec3<f32>
{
    var _S1 : vec3<f32> = clamp(c_0, vec3<f32>(0.0f), vec3<f32>(1.0f));
    return mix(vec3<f32>(12.92000007629394531f) * _S1, vec3<f32>(1.0549999475479126f) * pow(_S1, vec3<f32>(0.4166666567325592f)) - vec3<f32>(0.05499999970197678f), step(vec3<f32>(0.00313080009073019f), _S1));
}

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
fn main( _S2 : pixelInput_0) -> pixelOutput_0
{
    var _S3 : vec2<f32> = _S2.uv_0 * Ui_Fragment_Uniforms_0.params_0.xy;
    ;
    var s_0 : vec4<f32> = (textureSample((tex_texture_0), (tex_sampler_0), (_S3)));
    if((Ui_Fragment_Uniforms_0.params_0.w) > 0.5f)
    {
        var _S4 : vec3<f32> = s_0.xyz / vec3<f32>(max(s_0.w, 0.00392156885936856f));
        s_0.x = _S4.x;
        s_0.y = _S4.y;
        s_0.z = _S4.z;
    }
    if((Ui_Fragment_Uniforms_0.params_0.z) > 1.5f)
    {
        var _S5 : vec3<f32> = ui_srgb_encode_0(s_0.xyz);
        s_0.x = _S5.x;
        s_0.y = _S5.y;
        s_0.z = _S5.z;
    }
    var _S6 : vec4<f32>;
    if((Ui_Fragment_Uniforms_0.params_0.z) > 0.5f)
    {
        _S6 = _S2.color_0 * s_0;
    }
    else
    {
        _S6 = vec4<f32>(_S2.color_0.xyz, _S2.color_0.w * s_0.x);
    }
    var _S7 : pixelOutput_0 = pixelOutput_0( _S6 );
    return _S7;
}

