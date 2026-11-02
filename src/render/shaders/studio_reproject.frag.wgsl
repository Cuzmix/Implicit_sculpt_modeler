// slangc wgsl from studio_reproject.frag.spv sha256 2c5e9cfde56a6c43de123a19b0e7e2a9c652563f35bba0af231fe9c45c737483
@binding(0) @group(2) var view_depth_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var view_depth_sampler_0 : sampler;

struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Reproject_Uniforms_std140_0
{
    @align(16) inv_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) prev_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) prev_inv_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Reproject_Uniforms_0 : SLANG_ParameterGroup_Reproject_Uniforms_std140_0;
@binding(2) @group(2) var prev_depth_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var prev_depth_sampler_0 : sampler;

@binding(4) @group(2) var prev_accum_texture_0 : texture_2d<f32>;

@binding(5) @group(2) var prev_accum_sampler_0 : sampler;

fn texture_size_0( t_texture_0 : texture_2d<f32>,  t_sampler_0 : sampler) -> vec2<i32>
{
    var w_0 : u32;
    var h_0 : u32;
    var levels_0 : u32;
    {var dim = textureDimensions((t_texture_0), (u32(0)));((w_0)) = dim.x;((h_0)) = dim.y;((levels_0)) = textureNumLevels((t_texture_0));};
    return vec2<i32>(i32(w_0), i32(h_0));
}

fn world_at_0( frag_0 : vec2<f32>,  depth_0 : f32,  size_0 : vec2<f32>) -> vec3<f32>
{
    var uv_0 : vec2<f32> = frag_0 / size_0;
    var w_1 : vec4<f32> = (((mat4x4<f32>(Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(0)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(1)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(2)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(3)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(0)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(1)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(2)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(3)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(0)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(1)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(2)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(3)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(0)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(1)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(2)], Reproject_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(uv_0.x * 2.0f - 1.0f, 1.0f - uv_0.y * 2.0f, depth_0, 1.0f))));
    return w_1.xyz / vec3<f32>(w_1.w);
}

fn normal_at_0( px_0 : vec2<i32>,  frag_1 : vec2<f32>,  d_0 : f32,  p_0 : vec3<f32>,  size_1 : vec2<f32>) -> vec3<f32>
{
    var hi_0 : vec2<i32> = vec2<i32>(size_1) - vec2<i32>(i32(1));
    const _S1 : vec2<i32> = vec2<i32>(i32(1), i32(0));
    var _S2 : vec2<i32> = vec2<i32>(i32(0));
    var dl_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    var dr_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    const _S3 : vec2<i32> = vec2<i32>(i32(0), i32(1));
    var du_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    var dd_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    var px_r_0 : vec3<f32>;
    if((abs(dr_0 - d_0)) < (abs(d_0 - dl_0)))
    {
        px_r_0 = world_at_0(frag_1 + vec2<f32>(1.0f, 0.0f), dr_0, size_1) - p_0;
    }
    else
    {
        px_r_0 = p_0 - world_at_0(frag_1 - vec2<f32>(1.0f, 0.0f), dl_0, size_1);
    }
    var px_d_0 : vec3<f32>;
    if((abs(dd_0 - d_0)) < (abs(d_0 - du_0)))
    {
        px_d_0 = world_at_0(frag_1 + vec2<f32>(0.0f, 1.0f), dd_0, size_1) - p_0;
    }
    else
    {
        px_d_0 = p_0 - world_at_0(frag_1 - vec2<f32>(0.0f, 1.0f), du_0, size_1);
    }
    return normalize(cross(px_d_0, px_r_0));
}

fn prev_world_at_0( frag_2 : vec2<f32>,  depth_1 : f32,  size_2 : vec2<f32>) -> vec3<f32>
{
    var uv_1 : vec2<f32> = frag_2 / size_2;
    var w_2 : vec4<f32> = (((mat4x4<f32>(Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(0)][i32(0)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(0)][i32(1)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(0)][i32(2)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(0)][i32(3)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(1)][i32(0)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(1)][i32(1)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(1)][i32(2)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(1)][i32(3)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(2)][i32(0)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(2)][i32(1)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(2)][i32(2)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(2)][i32(3)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(3)][i32(0)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(3)][i32(1)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(3)][i32(2)], Reproject_Uniforms_0.prev_inv_view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(uv_1.x * 2.0f - 1.0f, 1.0f - uv_1.y * 2.0f, depth_1, 1.0f))));
    return w_2.xyz / vec3<f32>(w_2.w);
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S4 : vec2<f32> = vec2<f32>(texture_size_0(view_depth_texture_0, view_depth_sampler_0));
    var _S5 : vec2<f32> = frag_coord_0.xy;
    var _S6 : vec2<i32> = vec2<i32>(_S5);
    var d_1 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    if(d_1 >= 1.0f)
    {
        var _S7 : pixelOutput_0 = pixelOutput_0( vec4<f32>(0.0f) );
        return _S7;
    }
    var p_1 : vec3<f32> = world_at_0(_S5, d_1, _S4);
    var _S8 : vec3<f32> = normal_at_0(_S6, _S5, d_1, p_1, _S4);
    var footprint_0 : f32 = length(world_at_0(_S5 + vec2<f32>(1.0f, 0.0f), d_1, _S4) - p_1);
    var distance_0 : f32 = length(p_1 - world_at_0(_S5, 0.0f, _S4));
    var _S9 : f32 = 0.5f * footprint_0 + 0.00300000002607703f * distance_0;
    var _S10 : f32 = 0.10000000149011612f * distance_0 + 4.0f * footprint_0;
    var c_0 : vec4<f32> = (((mat4x4<f32>(Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(0)][i32(0)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(0)][i32(1)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(0)][i32(2)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(0)][i32(3)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(1)][i32(0)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(1)][i32(1)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(1)][i32(2)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(1)][i32(3)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(2)][i32(0)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(2)][i32(1)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(2)][i32(2)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(2)][i32(3)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(3)][i32(0)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(3)][i32(1)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(3)][i32(2)], Reproject_Uniforms_0.prev_view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(p_1, 1.0f))));
    var _S11 : f32 = c_0.w;
    if(_S11 <= 0.0f)
    {
        var _S12 : pixelOutput_0 = pixelOutput_0( vec4<f32>(0.0f) );
        return _S12;
    }
    var _S13 : vec2<f32> = vec2<f32>(0.5f);
    var at_0 : vec2<f32> = vec2<f32>(c_0.x / _S11 * 0.5f + 0.5f, 0.5f - c_0.y / _S11 * 0.5f) * _S4 - _S13;
    var _S14 : vec2<i32> = vec2<i32>(floor(at_0));
    var _S15 : vec2<f32> = at_0 - vec2<f32>(_S14);
    var _S16 : vec2<i32> = vec2<i32>(_S4) - vec2<i32>(i32(1));
    var _S17 : vec4<f32> = vec4<f32>(0.0f);
    var y_0 : i32 = i32(0);
    var sum_0 : vec4<f32> = _S17;
    var total_0 : f32 = 0.0f;
    for(;;)
    {
        if(y_0 <= i32(1))
        {
        }
        else
        {
            break;
        }
        var x_0 : i32 = i32(0);
        var sum_1 : vec4<f32> = sum_0;
        var total_1 : f32 = total_0;
        for(;;)
        {
            if(x_0 <= i32(1))
            {
            }
            else
            {
                break;
            }
            var q_0 : vec2<i32> = _S14 + vec2<i32>(x_0, y_0);
            var _S18 : bool;
            if((any((q_0 < vec2<i32>(i32(0))))))
            {
                _S18 = true;
            }
            else
            {
                _S18 = (any((q_0 > _S16)));
            }
            if(_S18)
            {
                x_0 = x_0 + i32(1);
                continue;
            }
            var _S19 : f32;
            if(x_0 == i32(1))
            {
                _S19 = _S15.x;
            }
            else
            {
                _S19 = 1.0f - _S15.x;
            }
            var _S20 : f32;
            if(y_0 == i32(1))
            {
                _S20 = _S15.y;
            }
            else
            {
                _S20 = 1.0f - _S15.y;
            }
            var w_3 : f32 = _S19 * _S20;
            if(w_3 <= 0.0f)
            {
                x_0 = x_0 + i32(1);
                continue;
            }
            var _S21 : vec3<i32> = vec3<i32>(q_0, i32(0));
            var qd_0 : f32 = (textureLoad((prev_depth_texture_0), ((prev_depth_sampler_0)).xy, ((prev_depth_sampler_0)).z)).x;
            if(qd_0 >= 1.0f)
            {
                x_0 = x_0 + i32(1);
                continue;
            }
            var off_0 : vec3<f32> = prev_world_at_0(vec2<f32>(q_0) + _S13, qd_0, _S4) - p_1;
            var _S22 : bool;
            if((abs(dot(_S8, off_0))) > _S9)
            {
                _S22 = true;
            }
            else
            {
                _S22 = (length(off_0)) > _S10;
            }
            if(_S22)
            {
                x_0 = x_0 + i32(1);
                continue;
            }
            var total_2 : f32 = total_1 + w_3;
            sum_1 = sum_1 + vec4<f32>(w_3) * (textureLoad((prev_accum_texture_0), ((prev_accum_sampler_0)).xy, ((prev_accum_sampler_0)).z));
            total_1 = total_2;
            x_0 = x_0 + i32(1);
        }
        y_0 = y_0 + i32(1);
        sum_0 = sum_1;
        total_0 = total_1;
    }
    if(total_0 <= 0.0f)
    {
        var _S23 : pixelOutput_0 = pixelOutput_0( _S17 );
        return _S23;
    }
    var _S24 : vec4<f32> = sum_0 / vec4<f32>(total_0);
    var kept_0 : vec4<f32> = _S24;
    var _S25 : vec2<f32> = _S24.xy * vec2<f32>(min(1.0f, Reproject_Uniforms_0.params_0.x / max(_S24.y, 9.99999997475242708e-07f)));
    kept_0.x = _S25.x;
    kept_0.y = _S25.y;
    var _S26 : vec2<f32>;
    if((Reproject_Uniforms_0.params_0.z) > 0.5f)
    {
        _S26 = kept_0.zw * vec2<f32>(min(1.0f, Reproject_Uniforms_0.params_0.y / max(kept_0.w, 9.99999997475242708e-07f)));
    }
    else
    {
        _S26 = vec2<f32>(0.0f);
    }
    var _S27 : vec2<f32> = _S26;
    kept_0.z = _S27.x;
    kept_0.w = _S27.y;
    var _S28 : pixelOutput_0 = pixelOutput_0( kept_0 );
    return _S28;
}

