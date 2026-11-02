// slangc wgsl from ui.vert.spv sha256 9d9cf5632916c5e2f9ef95d2be7feee6066296d6e560d2e1a267eb0355c06100
struct SLANG_ParameterGroup_Ui_Vertex_Uniforms_std140_0
{
    @align(16) target_0 : vec4<f32>,
};

@binding(0) @group(1) var<uniform> Ui_Vertex_Uniforms_0 : SLANG_ParameterGroup_Ui_Vertex_Uniforms_std140_0;
struct Vertex_Out_0
{
    @builtin(position) position_0 : vec4<f32>,
    @location(0) uv_0 : vec2<f32>,
    @location(1) color_0 : vec4<f32>,
};

struct vertexInput_0
{
    @location(0) pos_0 : vec2<f32>,
    @location(1) uv_1 : vec2<f32>,
    @location(2) color_1 : vec4<f32>,
};

@vertex
fn main( _S1 : vertexInput_0) -> Vertex_Out_0
{
    var o_0 : Vertex_Out_0;
    o_0.uv_0 = _S1.uv_1;
    o_0.color_0 = _S1.color_1;
    var ndc_0 : vec2<f32> = _S1.pos_0 / Ui_Vertex_Uniforms_0.target_0.xy * vec2<f32>(2.0f) - vec2<f32>(1.0f);
    var _S2 : f32 = ndc_0.x;
    var _S3 : f32 = - ndc_0.y;
    o_0.position_0 = vec4<f32>(Ui_Vertex_Uniforms_0.target_0.z * _S2 + Ui_Vertex_Uniforms_0.target_0.w * _S3, Ui_Vertex_Uniforms_0.target_0.z * _S3 - Ui_Vertex_Uniforms_0.target_0.w * _S2, 0.0f, 1.0f);
    return o_0;
}

