// slangc wgsl from studio_depth_keep.frag.spv sha256 9850cb5ec8220cde809fb6b13cf23c465f7c5e05908af7b0657c65aea3f43929
diagnostic(off, derivative_uniformity);
@binding(0) @group(2) var view_depth_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var view_depth_sampler_0 : sampler;

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S1 : pixelOutput_0 = pixelOutput_0( vec4<f32>((textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x, 0.0f, 0.0f, 0.0f) );
    return _S1;
}

