// slangc wgsl from ref_plane.frag.spv sha256 2d7585f7d9bca39e57929e8e13ce7d0c1c787417d8887c9f1508ce6f897740a7
diagnostic(off, derivative_uniformity);
@binding(0) @group(2) var picture_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var picture_sampler_0 : sampler;

struct SLANG_ParameterGroup_Ref_Plane_Look_std140_0
{
    @align(16) look_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Ref_Plane_Look_0 : SLANG_ParameterGroup_Ref_Plane_Look_std140_0;
struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

struct pixelInput_0
{
    @location(0) uv_0 : vec2<f32>,
};

@fragment
fn main( _S1 : pixelInput_0) -> pixelOutput_0
{
    ;
    var _S2 : vec4<f32> = (textureSample((picture_texture_0), (picture_sampler_0), (_S1.uv_0)));
    var _S3 : pixelOutput_0 = pixelOutput_0( vec4<f32>(_S2.xyz, _S2.w * Ref_Plane_Look_0.look_0.x) );
    return _S3;
}

