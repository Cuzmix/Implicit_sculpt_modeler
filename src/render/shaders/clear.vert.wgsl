// slangc wgsl from clear.vert.spv sha256 68a8f109a83f930712bb14f07ade79583d5e556bd943527c9219bb7205f7c58d
struct vertexOutput_0
{
    @builtin(position) output_0 : vec4<f32>,
};

@vertex
fn main(@builtin(vertex_index) vertex_0 : u32) -> vertexOutput_0
{
    var i_0 : i32 = i32(vertex_0);
    var _S1 : vertexOutput_0 = vertexOutput_0( vec4<f32>(vec2<f32>(f32((((i_0 << (u32(1)))) & (i32(2)))), f32((i_0 & (i32(2))))) * vec2<f32>(2.0f) - vec2<f32>(1.0f), 1.0f, 1.0f) );
    return _S1;
}

