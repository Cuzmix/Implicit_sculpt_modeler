// slangc wgsl from shadow.vert.spv sha256 f08817dac5bbb8ba33ca67d5c483a5a81721c87a2ca22c6645dbad4ce784281a
diagnostic(off, derivative_uniformity);
struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Shadow_Uniforms_std140_0
{
    @align(16) light_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) model_0 : _MatrixStorage_float4x4std140_0,
    @align(16) blend_0 : vec4<u32>,
};

@binding(0) @group(1) var<uniform> Shadow_Uniforms_0 : SLANG_ParameterGroup_Shadow_Uniforms_std140_0;
@binding(0) @group(0) var<storage, read> blend_table_0 : array<u32>;

@binding(2) @group(0) var<storage, read> blend_pages_0 : array<vec4<u32>>;

fn blend_entry_0( vertex_0 : u32) -> vec4<u32>
{
    if((Shadow_Uniforms_0.blend_0.x) == u32(0))
    {
        return vec4<u32>(u32(0));
    }
    var page_0 : u32 = blend_table_0[(vertex_0 >> (u32(10)))];
    if(page_0 >= u32(2147483648))
    {
        return vec4<u32>(u32(0));
    }
    return blend_pages_0[page_0 * u32(1024) + ((vertex_0 & (u32(1023))))];
}

struct vertexOutput_0
{
    @builtin(position) output_0 : vec4<f32>,
};

struct vertexInput_0
{
    @location(0) position_0 : vec3<f32>,
};

@vertex
fn main( _S1 : vertexInput_0, @builtin(vertex_index) vertex_1 : u32) -> vertexOutput_0
{
    var _S2 : vertexOutput_0 = vertexOutput_0( ((((((mat4x4<f32>(Shadow_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(0)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(1)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(2)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(3)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(0)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(1)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(2)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(3)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(0)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(1)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(2)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(3)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(0)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(1)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(2)], Shadow_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(3)])) * (mat4x4<f32>(Shadow_Uniforms_0.model_0.data_0[i32(0)][i32(0)], Shadow_Uniforms_0.model_0.data_0[i32(0)][i32(1)], Shadow_Uniforms_0.model_0.data_0[i32(0)][i32(2)], Shadow_Uniforms_0.model_0.data_0[i32(0)][i32(3)], Shadow_Uniforms_0.model_0.data_0[i32(1)][i32(0)], Shadow_Uniforms_0.model_0.data_0[i32(1)][i32(1)], Shadow_Uniforms_0.model_0.data_0[i32(1)][i32(2)], Shadow_Uniforms_0.model_0.data_0[i32(1)][i32(3)], Shadow_Uniforms_0.model_0.data_0[i32(2)][i32(0)], Shadow_Uniforms_0.model_0.data_0[i32(2)][i32(1)], Shadow_Uniforms_0.model_0.data_0[i32(2)][i32(2)], Shadow_Uniforms_0.model_0.data_0[i32(2)][i32(3)], Shadow_Uniforms_0.model_0.data_0[i32(3)][i32(0)], Shadow_Uniforms_0.model_0.data_0[i32(3)][i32(1)], Shadow_Uniforms_0.model_0.data_0[i32(3)][i32(2)], Shadow_Uniforms_0.model_0.data_0[i32(3)][i32(3)]))))) * (vec4<f32>(_S1.position_0 + (bitcast<vec3<f32>>((blend_entry_0(vertex_1).xyz))), 1.0f)))) );
    return _S2;
}

