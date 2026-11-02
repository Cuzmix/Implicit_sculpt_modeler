// slangc wgsl from studio_gather.frag.spv sha256 a2b5bb1ba5f07cf3b06c709c2f9e52355ea4c3ec406031729408d10cd1090f7c
@binding(0) @group(2) var view_depth_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var view_depth_sampler_0 : sampler;

struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Gather_Uniforms_std140_0
{
    @align(16) inv_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) light_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) light_dir_0 : vec4<f32>,
    @align(16) params_0 : vec4<f32>,
    @align(16) shadow_pos_0 : array<vec4<f32>, i32(8)>,
    @align(16) shadow_shape_0 : array<vec4<f32>, i32(8)>,
    @align(16) shadow_spot_0 : array<vec4<f32>, i32(8)>,
    @align(16) shadow_pick_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Gather_Uniforms_0 : SLANG_ParameterGroup_Gather_Uniforms_std140_0;
@binding(2) @group(2) var shadow_depth_texture_0 : texture_2d<f32>;

@binding(3) @group(2) var shadow_depth_sampler_0 : sampler;

fn rsqrt_0( x_0 : f32) -> f32
{
    return 1.0f / sqrt(x_0);
}

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
    var w_1 : vec4<f32> = (((mat4x4<f32>(Gather_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(0)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(1)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(2)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(3)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(0)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(1)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(2)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(3)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(0)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(1)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(2)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(3)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(0)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(1)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(2)], Gather_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(uv_0.x * 2.0f - 1.0f, 1.0f - uv_0.y * 2.0f, depth_0, 1.0f))));
    return w_1.xyz / vec3<f32>(w_1.w);
}

fn depth_normal_0( view_depth_texture_1 : texture_2d<f32>,  view_depth_sampler_1 : sampler,  px_0 : vec2<i32>,  frag_1 : vec2<f32>,  d_0 : f32,  p_0 : vec3<f32>,  size_1 : vec2<f32>) -> vec3<f32>
{
    var hi_0 : vec2<i32> = vec2<i32>(size_1) - vec2<i32>(i32(1));
    const _S1 : vec2<i32> = vec2<i32>(i32(1), i32(0));
    var _S2 : vec2<i32> = vec2<i32>(i32(0));
    var dl_0 : f32 = (textureLoad((view_depth_texture_1), ((view_depth_sampler_1)).xy, ((view_depth_sampler_1)).z)).x;
    var dr_0 : f32 = (textureLoad((view_depth_texture_1), ((view_depth_sampler_1)).xy, ((view_depth_sampler_1)).z)).x;
    const _S3 : vec2<i32> = vec2<i32>(i32(0), i32(1));
    var du_0 : f32 = (textureLoad((view_depth_texture_1), ((view_depth_sampler_1)).xy, ((view_depth_sampler_1)).z)).x;
    var dd_0 : f32 = (textureLoad((view_depth_texture_1), ((view_depth_sampler_1)).xy, ((view_depth_sampler_1)).z)).x;
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
    var n_0 : vec3<f32> = normalize(cross(px_d_0, px_r_0));
    var n_1 : vec3<f32>;
    if((dot(n_0, world_at_0(frag_1, 0.0f, size_1) - p_0)) < 0.0f)
    {
        n_1 = (vec3<f32>(0) - n_0);
    }
    else
    {
        n_1 = n_0;
    }
    return n_1;
}

fn light_window_0( pos_0 : vec4<f32>,  shape_0 : vec4<f32>,  spot_0 : vec4<f32>,  d2_0 : f32,  l_0 : vec3<f32>) -> f32
{
    var _S4 : f32 = shape_0.y;
    var k_0 : f32;
    if(_S4 > 0.0f)
    {
        var x_1 : f32 = d2_0 / (_S4 * _S4);
        var w_2 : f32 = clamp(1.0f - x_1 * x_1, 0.0f, 1.0f);
        k_0 = w_2 * w_2;
    }
    else
    {
        k_0 = 1.0f;
    }
    var _S5 : f32 = pos_0.w;
    if(_S5 > 2.5f)
    {
        k_0 = k_0 * max(dot((vec3<f32>(0) - l_0), spot_0.xyz), 0.0f);
    }
    else
    {
        if(_S5 > 1.5f)
        {
            k_0 = k_0 * smoothstep(spot_0.w, shape_0.z, dot((vec3<f32>(0) - l_0), spot_0.xyz));
        }
    }
    return k_0;
}

fn shadow_light_0( i_0 : i32,  p_1 : vec3<f32>,  n_2 : vec3<f32>) -> f32
{
    var pos_1 : vec4<f32> = Gather_Uniforms_0.shadow_pos_0[i_0];
    if((Gather_Uniforms_0.shadow_shape_0[i_0].w) == 0.0f)
    {
        return 0.0f;
    }
    if((pos_1.w) < 0.5f)
    {
        return max(dot(n_2, pos_1.xyz), 0.0f);
    }
    var to_0 : vec3<f32> = pos_1.xyz - p_1;
    var _S6 : f32 = max(dot(to_0, to_0), 9.99999993922529029e-09f);
    var l_1 : vec3<f32> = to_0 * vec3<f32>(rsqrt_0(_S6));
    var ref_0 : f32 = Gather_Uniforms_0.shadow_shape_0[i_0].x;
    return max(dot(n_2, l_1), 0.0f) * (ref_0 * ref_0 / _S6) * light_window_0(pos_1, Gather_Uniforms_0.shadow_shape_0[i_0], Gather_Uniforms_0.shadow_spot_0[i_0], _S6, l_1);
}

fn shadow_weight_0( p_2 : vec3<f32>,  n_3 : vec3<f32>) -> vec2<f32>
{
    var _S7 : f32 = Gather_Uniforms_0.shadow_pick_0.z;
    var _S8 : f32 = Gather_Uniforms_0.shadow_pick_0.z;
    var i_1 : i32 = i32(0);
    var total_0 : f32 = _S7;
    var unshadowed_0 : f32 = _S8;
    for(;;)
    {
        if(i_1 < i32(8))
        {
        }
        else
        {
            break;
        }
        var c_0 : f32 = Gather_Uniforms_0.shadow_shape_0[i_1].w;
        var lit_0 : f32 = abs(c_0) * shadow_light_0(i_1, p_2, n_3);
        var total_1 : f32 = total_0 + lit_0;
        if(c_0 < 0.0f)
        {
            unshadowed_0 = unshadowed_0 + lit_0;
        }
        i_1 = i_1 + i32(1);
        total_0 = total_1;
    }
    if(total_0 <= 0.0f)
    {
        return vec2<f32>(-1.0f, 0.0f);
    }
    return vec2<f32>(Gather_Uniforms_0.shadow_pick_0.y * shadow_light_0(i32(Gather_Uniforms_0.shadow_pick_0.x), p_2, n_3), unshadowed_0) / vec2<f32>(total_0);
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S9 : vec2<f32> = vec2<f32>(texture_size_0(view_depth_texture_0, view_depth_sampler_0));
    var _S10 : vec2<f32> = frag_coord_0.xy;
    var _S11 : vec2<i32> = vec2<i32>(_S10);
    var d_1 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    if(d_1 >= 1.0f)
    {
        var _S12 : pixelOutput_0 = pixelOutput_0( vec4<f32>(0.0f) );
        return _S12;
    }
    var p_3 : vec3<f32> = world_at_0(_S10, d_1, _S9);
    var _S13 : vec3<f32> = depth_normal_0(view_depth_texture_0, view_depth_sampler_0, _S11, _S10, d_1, p_3, _S9);
    var cosine_0 : f32 = dot(_S13, Gather_Uniforms_0.light_dir_0.xyz);
    var key_0 : bool = (Gather_Uniforms_0.light_dir_0.w) > 0.5f;
    var _S14 : vec2<f32> = vec2<f32>(0.0f);
    var weight_0 : vec2<f32>;
    if(key_0)
    {
        var weight_1 : vec2<f32> = shadow_weight_0(p_3, _S13);
        if((weight_1.x) < 0.0f)
        {
            var _S15 : pixelOutput_0 = pixelOutput_0( vec4<f32>(0.0f, 0.0f, 1.0f, 1.0f) );
            return _S15;
        }
        weight_0 = weight_1;
    }
    else
    {
        weight_0 = _S14;
    }
    var _S16 : vec4<f32>;
    if(cosine_0 <= 0.0f)
    {
        if(key_0)
        {
            _S16 = vec4<f32>(0.0f, 0.0f, 1.0f, 1.0f) * vec4<f32>((weight_0.x + weight_0.y));
        }
        else
        {
            _S16 = vec4<f32>(0.0f);
        }
        var _S17 : pixelOutput_0 = pixelOutput_0( _S16 );
        return _S17;
    }
    var c_1 : vec4<f32> = (((mat4x4<f32>(Gather_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(0)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(1)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(2)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(0)][i32(3)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(0)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(1)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(2)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(1)][i32(3)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(0)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(1)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(2)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(2)][i32(3)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(0)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(1)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(2)], Gather_Uniforms_0.light_view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(p_3 + _S13 * vec3<f32>(Gather_Uniforms_0.params_0.y), 1.0f))));
    var s_0 : vec3<f32> = c_1.xyz / vec3<f32>(c_1.w);
    var _S18 : vec2<f32> = vec2<f32>(s_0.x * 0.5f + 0.5f, 0.5f - s_0.y * 0.5f);
    var y_0 : i32 = i32(-1);
    var lit_1 : f32 = 0.0f;
    for(;;)
    {
        if(y_0 <= i32(1))
        {
        }
        else
        {
            break;
        }
        var x_2 : i32 = i32(-1);
        for(;;)
        {
            if(x_2 <= i32(1))
            {
            }
            else
            {
                break;
            }
            var _S19 : vec2<f32> = _S18 + vec2<f32>(f32(x_2), f32(y_0)) * vec2<f32>(Gather_Uniforms_0.params_0.z);
            ;
            var _S20 : f32;
            if((s_0.z - Gather_Uniforms_0.params_0.x) <= ((textureSample((shadow_depth_texture_0), (shadow_depth_sampler_0), (_S19))).x))
            {
                _S20 = 1.0f;
            }
            else
            {
                _S20 = 0.0f;
            }
            var lit_2 : f32 = lit_1 + _S20;
            x_2 = x_2 + i32(1);
            lit_1 = lit_2;
        }
        y_0 = y_0 + i32(1);
    }
    var lit_3 : f32 = lit_1 / 9.0f;
    if(key_0)
    {
        var _S21 : f32 = weight_0.x;
        var _S22 : f32 = weight_0.y;
        _S16 = vec4<f32>(0.0f, 0.0f, lit_3 * _S21 + _S22, _S21 + _S22);
    }
    else
    {
        _S16 = vec4<f32>(lit_3 * cosine_0, cosine_0, 0.0f, 0.0f);
    }
    var _S23 : pixelOutput_0 = pixelOutput_0( _S16 );
    return _S23;
}

