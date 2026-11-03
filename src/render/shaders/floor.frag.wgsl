// slangc wgsl from floor.frag.spv sha256 36e84be3612bb74ec3ca31b53b20f6baa6ab3d95935e601bc7db53e51f67169a
diagnostic(off, derivative_uniformity);
struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Floor_Uniforms_std140_0
{
    @align(16) inv_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) plane_0 : vec4<f32>,
    @align(16) grid_0 : vec4<f32>,
    @align(16) center_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Floor_Uniforms_0 : SLANG_ParameterGroup_Floor_Uniforms_std140_0;
fn lines_0( cells_0 : vec2<f32>,  per_pixel_0 : vec2<f32>) -> f32
{
    var _S1 : vec2<f32> = vec2<f32>(0.5f);
    var off_0 : vec2<f32> = abs(fract(cells_0 - _S1) - _S1) / max(per_pixel_0, vec2<f32>(9.99999997475242708e-07f));
    return 1.0f - min(min(off_0.x, off_0.y), 1.0f);
}

struct Fragment_Out_0
{
    @location(0) color_0 : vec4<f32>,
    @builtin(frag_depth) depth_0 : f32,
};

struct pixelInput_0
{
    @location(0) in_ndc_0 : vec2<f32>,
};

@fragment
fn main( _S2 : pixelInput_0) -> Fragment_Out_0
{
    var a_0 : vec4<f32> = (((mat4x4<f32>(Floor_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(0)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(1)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(2)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(3)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(0)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(1)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(2)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(3)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(0)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(1)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(2)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(3)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(0)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(1)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(2)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(_S2.in_ndc_0, 0.0f, 1.0f))));
    var b_0 : vec4<f32> = (((mat4x4<f32>(Floor_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(0)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(1)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(2)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(3)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(0)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(1)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(2)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(3)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(0)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(1)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(2)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(3)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(0)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(1)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(2)], Floor_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(_S2.in_ndc_0, 1.0f, 1.0f))));
    var from_0 : vec3<f32> = a_0.xyz / vec3<f32>(a_0.w);
    var dir_0 : vec3<f32> = b_0.xyz / vec3<f32>(b_0.w) - from_0;
    var k_0 : i32 = i32(Floor_Uniforms_0.plane_0.x + 0.5f);
    var _S3 : bool = (abs(dir_0[k_0])) < 9.99999971718068537e-10f;
    var across_0 : f32;
    if(_S3)
    {
        across_0 = 9.99999971718068537e-10f;
    }
    else
    {
        across_0 = dir_0[k_0];
    }
    var t_0 : f32 = (Floor_Uniforms_0.plane_0.y - from_0[k_0]) / across_0;
    var hit_0 : vec3<f32> = from_0 + vec3<f32>(t_0) * dir_0;
    var i_0 : i32;
    if(k_0 == i32(0))
    {
        i_0 = i32(1);
    }
    else
    {
        i_0 = i32(0);
    }
    var j_0 : i32;
    if(k_0 == i32(2))
    {
        j_0 = i32(1);
    }
    else
    {
        j_0 = i32(2);
    }
    var uv_0 : vec2<f32> = vec2<f32>(hit_0[i_0], hit_0[j_0]);
    var minor_cells_0 : vec2<f32> = uv_0 / vec2<f32>(Floor_Uniforms_0.grid_0.x);
    var minor_px_0 : vec2<f32> = (fwidth((minor_cells_0)));
    var uv_px_0 : vec2<f32> = (fwidth((uv_0)));
    var _S4 : vec2<f32> = vec2<f32>(5.0f);
    var major_px_0 : vec2<f32> = minor_px_0 / _S4;
    var fade_0 : f32 = 1.0f - smoothstep(0.55000001192092896f, 1.0f, length(uv_0 - vec2<f32>(Floor_Uniforms_0.center_0[i_0], Floor_Uniforms_0.center_0[j_0])) / max(Floor_Uniforms_0.grid_0.y, 9.99999997475242708e-07f));
    var _S5 : vec3<f32> = vec3<f32>(0.62000000476837158f);
    var _S6 : f32 = max(lines_0(minor_cells_0, minor_px_0) * (1.0f - smoothstep(0.11999999731779099f, 0.30000001192092896f, max(minor_px_0.x, minor_px_0.y))) * 0.2199999988079071f, lines_0(minor_cells_0 / _S4, major_px_0) * (1.0f - smoothstep(0.11999999731779099f, 0.30000001192092896f, max(major_px_0.x, major_px_0.y))) * 0.44999998807907104f);
    var alpha_0 : f32;
    var _S7 : bool;
    var color_1 : vec3<f32>;
    if((Floor_Uniforms_0.grid_0.z) > 0.5f)
    {
        var AXIS_0 : array<vec3<f32>, i32(3)> = array<vec3<f32>, i32(3)>( vec3<f32>(0.86000001430511475f, 0.30000001192092896f, 0.30000001192092896f), vec3<f32>(0.41999998688697815f, 0.80000001192092896f, 0.36000001430511475f), vec3<f32>(0.31999999284744263f, 0.51999998092651367f, 0.94999998807907104f) );
        var off_1 : vec2<f32> = abs(uv_0) / max(uv_px_0, vec2<f32>(9.99999997475242708e-07f));
        var along_j_0 : f32 = 1.0f - min(off_1.x / 1.5f, 1.0f);
        var along_i_0 : f32 = 1.0f - min(off_1.y / 1.5f, 1.0f);
        if(along_j_0 > 0.0f)
        {
            _S7 = true;
        }
        else
        {
            _S7 = along_i_0 > 0.0f;
        }
        if(_S7)
        {
            if(along_j_0 >= along_i_0)
            {
                color_1 = AXIS_0[j_0];
            }
            else
            {
                color_1 = AXIS_0[i_0];
            }
            alpha_0 = max(_S6, max(along_i_0, along_j_0) * 0.89999997615814209f);
        }
        else
        {
            color_1 = _S5;
            alpha_0 = _S6;
        }
    }
    else
    {
        color_1 = _S5;
        alpha_0 = _S6;
    }
    var alpha_1 : f32 = alpha_0 * fade_0;
    var clip_0 : vec4<f32> = (((mat4x4<f32>(Floor_Uniforms_0.view_proj_0.data_0[i32(0)][i32(0)], Floor_Uniforms_0.view_proj_0.data_0[i32(0)][i32(1)], Floor_Uniforms_0.view_proj_0.data_0[i32(0)][i32(2)], Floor_Uniforms_0.view_proj_0.data_0[i32(0)][i32(3)], Floor_Uniforms_0.view_proj_0.data_0[i32(1)][i32(0)], Floor_Uniforms_0.view_proj_0.data_0[i32(1)][i32(1)], Floor_Uniforms_0.view_proj_0.data_0[i32(1)][i32(2)], Floor_Uniforms_0.view_proj_0.data_0[i32(1)][i32(3)], Floor_Uniforms_0.view_proj_0.data_0[i32(2)][i32(0)], Floor_Uniforms_0.view_proj_0.data_0[i32(2)][i32(1)], Floor_Uniforms_0.view_proj_0.data_0[i32(2)][i32(2)], Floor_Uniforms_0.view_proj_0.data_0[i32(2)][i32(3)], Floor_Uniforms_0.view_proj_0.data_0[i32(3)][i32(0)], Floor_Uniforms_0.view_proj_0.data_0[i32(3)][i32(1)], Floor_Uniforms_0.view_proj_0.data_0[i32(3)][i32(2)], Floor_Uniforms_0.view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(hit_0, 1.0f))));
    var depth_1 : f32 = clip_0.z / clip_0.w;
    if(_S3)
    {
        _S7 = true;
    }
    else
    {
        _S7 = t_0 < 0.0f;
    }
    if(_S7)
    {
        _S7 = true;
    }
    else
    {
        _S7 = t_0 > 1.0f;
    }
    if(_S7)
    {
        _S7 = true;
    }
    else
    {
        _S7 = depth_1 < 0.0f;
    }
    if(_S7)
    {
        _S7 = true;
    }
    else
    {
        _S7 = depth_1 > 1.0f;
    }
    if(_S7)
    {
        _S7 = true;
    }
    else
    {
        _S7 = alpha_1 <= 0.0020000000949949f;
    }
    if(_S7)
    {
        discard;
    }
    var o_0 : Fragment_Out_0;
    o_0.depth_0 = depth_1;
    o_0.color_0 = vec4<f32>(color_1, alpha_1);
    return o_0;
}

