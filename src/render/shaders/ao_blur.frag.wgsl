// slangc wgsl from ao_blur.frag.spv sha256 8418bdcbcc0f9561f215b107d665d2826cd0d711910d0291c89c7207d01a47a8
diagnostic(off, derivative_uniformity);
@binding(0) @group(2) var view_color_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var view_color_sampler_0 : sampler;

@binding(4) @group(2) var view_depth_texture_0 : texture_2d<f32>;

@binding(5) @group(2) var view_depth_sampler_0 : sampler;

struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Blur_Uniforms_std140_0
{
    @align(16) inv_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) size_0 : vec4<f32>,
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Blur_Uniforms_0 : SLANG_ParameterGroup_Blur_Uniforms_std140_0;
@binding(2) @group(2) var ao_map_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var ao_map_sampler_0 : sampler;

fn view_z_0( depth_0 : f32) -> f32
{
    var v_0 : vec4<f32> = (((mat4x4<f32>(Blur_Uniforms_0.inv_proj_0.data_0[i32(0)][i32(0)], Blur_Uniforms_0.inv_proj_0.data_0[i32(0)][i32(1)], Blur_Uniforms_0.inv_proj_0.data_0[i32(0)][i32(2)], Blur_Uniforms_0.inv_proj_0.data_0[i32(0)][i32(3)], Blur_Uniforms_0.inv_proj_0.data_0[i32(1)][i32(0)], Blur_Uniforms_0.inv_proj_0.data_0[i32(1)][i32(1)], Blur_Uniforms_0.inv_proj_0.data_0[i32(1)][i32(2)], Blur_Uniforms_0.inv_proj_0.data_0[i32(1)][i32(3)], Blur_Uniforms_0.inv_proj_0.data_0[i32(2)][i32(0)], Blur_Uniforms_0.inv_proj_0.data_0[i32(2)][i32(1)], Blur_Uniforms_0.inv_proj_0.data_0[i32(2)][i32(2)], Blur_Uniforms_0.inv_proj_0.data_0[i32(2)][i32(3)], Blur_Uniforms_0.inv_proj_0.data_0[i32(3)][i32(0)], Blur_Uniforms_0.inv_proj_0.data_0[i32(3)][i32(1)], Blur_Uniforms_0.inv_proj_0.data_0[i32(3)][i32(2)], Blur_Uniforms_0.inv_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(0.0f, 0.0f, depth_0, 1.0f))));
    return v_0.z / v_0.w;
}

fn texture_size_0( t_texture_0 : texture_2d<f32>,  t_sampler_0 : sampler) -> vec2<i32>
{
    var w_0 : u32;
    var h_0 : u32;
    var levels_0 : u32;
    {var dim = textureDimensions((t_texture_0), (u32(0)));((w_0)) = dim.x;((h_0)) = dim.y;((levels_0)) = textureNumLevels((t_texture_0));};
    return vec2<i32>(i32(w_0), i32(h_0));
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var sum_0 : f32;
    var weight_0 : f32;
    var _S1 : vec2<i32> = vec2<i32>(frag_coord_0.xy);
    var _S2 : vec3<i32> = vec3<i32>(_S1, i32(0));
    var _S3 : vec4<f32> = (textureLoad((view_color_texture_0), ((view_color_sampler_0)).xy, ((view_color_sampler_0)).z));
    var d_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    if(d_0 >= 1.0f)
    {
        var _S4 : pixelOutput_0 = pixelOutput_0( _S3 );
        return _S4;
    }
    var _S5 : f32 = view_z_0(d_0);
    var scale_0 : i32 = i32(Blur_Uniforms_0.size_0.z);
    var _S6 : vec2<i32> = texture_size_0(ao_map_texture_0, ao_map_sampler_0);
    var _S7 : vec2<i32> = vec2<i32>(i32(1));
    var _S8 : vec2<i32> = vec2<i32>(Blur_Uniforms_0.size_0.xy) - _S7;
    var _S9 : vec2<i32> = vec2<i32>(scale_0);
    var _S10 : vec2<i32> = _S1 / _S9;
    var y_0 : i32 = i32(-2);
    var sum_1 : f32 = 0.0f;
    var weight_1 : f32 = 0.0f;
    for(;;)
    {
        if(y_0 <= i32(1))
        {
        }
        else
        {
            break;
        }
        var x_0 : i32 = i32(-2);
        sum_0 = sum_1;
        weight_0 = weight_1;
        for(;;)
        {
            if(x_0 <= i32(1))
            {
            }
            else
            {
                break;
            }
            var _S11 : vec2<i32> = vec2<i32>(i32(0));
            var t_0 : vec2<i32> = clamp(_S10 + vec2<i32>(x_0, y_0), _S11, _S6 - _S7);
            var td_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
            if(td_0 >= 1.0f)
            {
                x_0 = x_0 + i32(1);
                continue;
            }
            var _S12 : f32 = max(1.0f - abs(view_z_0(td_0) - _S5) / Blur_Uniforms_0.params_0.y, 0.0f);
            var weight_2 : f32 = weight_0 + _S12;
            sum_0 = sum_0 + _S12 * (textureLoad((ao_map_texture_0), ((ao_map_sampler_0)).xy, ((ao_map_sampler_0)).z)).x;
            weight_0 = weight_2;
            x_0 = x_0 + i32(1);
        }
        y_0 = y_0 + i32(1);
        sum_1 = sum_0;
        weight_1 = weight_0;
    }
    if(weight_1 > 0.0f)
    {
        sum_0 = min(sum_1 / weight_1, 1.0f);
    }
    else
    {
        sum_0 = 1.0f;
    }
    var _S13 : bool;
    if((Blur_Uniforms_0.params_0.z) >= 0.0f)
    {
        _S13 = (frag_coord_0.x) >= (Blur_Uniforms_0.params_0.z);
    }
    else
    {
        _S13 = false;
    }
    if(_S13)
    {
        weight_0 = Blur_Uniforms_0.params_0.w;
    }
    else
    {
        weight_0 = Blur_Uniforms_0.params_0.x;
    }
    var _S14 : pixelOutput_0 = pixelOutput_0( vec4<f32>(_S3.xyz * vec3<f32>(mix(1.0f, sum_0 * sum_0 * (3.0f - 2.0f * sum_0), weight_0)), _S3.w) );
    return _S14;
}

