// slangc wgsl from shadow.vert.spv sha256 67f5bdaedd655f3d3d4645c816d7fa3c342198996e711c1d978a355b70564690
struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Shadow_Uniforms_std140_0
{
    @align(16) light_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) model_0 : _MatrixStorage_float4x4std140_0,
};

@binding(0) @group(1) var<uniform> Shadow_Uniforms_0 : SLANG_ParameterGroup_Shadow_Uniforms_std140_0;
struct vertexOutput_0
{
    @builtin(position) output_0 : vec4<f32>,
};

struct vertexInput_0
{
    @location(0) position_0 : vec3<f32>,
};

@vertex
fn main( _S1 : vertexInput_0) -> vertexOutput_0
{
    var _S2 : vertexOutput_0 = vertexOutput_0( ((((((mat4x4<f32>(Shadow_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(0)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(1)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(2)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(3)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(0)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(1)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(2)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(3)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(0)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(1)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(2)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(3)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(0)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(1)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(2)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(3)])) * (mat4x4<f32>(Shadow_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Shadow_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Shadow_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Shadow_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Shadow_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Shadow_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Shadow_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Shadow_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Shadow_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Shadow_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Shadow_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Shadow_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Shadow_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Shadow_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Shadow_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Shadow_Uniforms_0.model_0.data_0[i32(3)][i32(3)]))))) * (vec4<f32>(_S1.position_0, 1.0f)))) );
    return _S2;
}

