// slangc wgsl from floor.vert.spv sha256 aacdd9ba553dbbdaa5f6e58f759b2dd54dd5f5f1ec54e9d6e8d7f793d8c07c4a
struct Vertex_Out_0
{
    @builtin(position) position_0 : vec4<f32>,
    @location(0) ndc_0 : vec2<f32>,
};

@vertex
fn main(@builtin(vertex_index) vertex_0 : u32) -> Vertex_Out_0
{
    var i_0 : i32 = i32(vertex_0);
    var p_0 : vec2<f32> = vec2<f32>(f32((((i_0 << (u32(1)))) & (i32(2)))), f32((i_0 & (i32(2))))) * vec2<f32>(2.0f) - vec2<f32>(1.0f);
    var o_0 : Vertex_Out_0;
    o_0.ndc_0 = p_0;
    o_0.position_0 = vec4<f32>(p_0, 1.0f, 1.0f);
    return o_0;
}

