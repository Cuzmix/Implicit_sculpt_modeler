// slangc wgsl from studio_trace.comp.spv sha256 01c0be6d1e268688eb222b306753773626b0d1d05ef6ff3227d26533aa965c5b
diagnostic(off, derivative_uniformity);
@binding(0) @group(0) var view_depth_texture_0 : texture_2d<f32>;

@binding(1) @group(0) var view_depth_sampler_0 : sampler;

struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Trace_Uniforms_std140_0
{
    @align(16) inv_view_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) to_mesh_0 : _MatrixStorage_float4x4std140_0,
    @align(16) key_base_0 : vec4<f32>,
    @align(16) key_side_0 : vec4<f32>,
    @align(16) key_up_0 : vec4<f32>,
    @align(16) params_0 : vec4<f32>,
    @align(16) sphere_0 : vec4<f32>,
};

@binding(0) @group(2) var<uniform> Trace_Uniforms_0 : SLANG_ParameterGroup_Trace_Uniforms_std140_0;
struct Node_std430_0
{
    @align(16) lo_0 : vec3<f32>,
    @align(4) first_0 : u32,
    @align(16) hi_0 : vec3<f32>,
    @align(4) count_0 : u32,
};

@binding(12) @group(0) var<storage, read> tlas_0 : array<Node_std430_0>;

@binding(10) @group(0) var<storage, read> chunks_0 : array<vec4<u32>>;

@binding(6) @group(0) var<storage, read> nodes_0 : array<Node_std430_0>;

@binding(8) @group(0) var<storage, read> order_0 : array<u32>;

@binding(4) @group(0) var<storage, read> indices_0 : array<u32>;

@binding(2) @group(0) var<storage, read> positions_0 : array<f32>;

@binding(0) @group(1) var visible_0 : texture_storage_2d<r32float, read_write>;

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
    var w_1 : vec4<f32> = (((mat4x4<f32>(Trace_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(0)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(1)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(2)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(0)][i32(3)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(0)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(1)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(2)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(1)][i32(3)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(0)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(1)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(2)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(2)][i32(3)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(0)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(1)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(2)], Trace_Uniforms_0.inv_view_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(uv_0.x * 2.0f - 1.0f, 1.0f - uv_0.y * 2.0f, depth_0, 1.0f))));
    return w_1.xyz / vec3<f32>(w_1.w);
}

fn pixel_hash_0( v_0 : vec2<u32>) -> vec2<f32>
{
    var _S1 : vec2<u32> = v_0 * vec2<u32>(u32(1664525)) + vec2<u32>(u32(1013904223));
    var _S2 : vec2<u32> = _S1;
    _S2[i32(0)] = _S2[i32(0)] + _S1.y * u32(1664525);
    _S2[i32(1)] = _S2[i32(1)] + _S2.x * u32(1664525);
    var _S3 : vec2<u32> = vec2<u32>(u32(16));
    var _S4 : vec2<u32> = (_S2 ^ (((_S2 >> (_S3)))));
    _S2 = _S4;
    _S2[i32(0)] = _S2[i32(0)] + _S4.y * u32(1664525);
    _S2[i32(1)] = _S2[i32(1)] + _S2.x * u32(1664525);
    var _S5 : vec2<u32> = (_S2 ^ (((_S2 >> (_S3)))));
    _S2 = _S5;
    return vec2<f32>((_S5 >> (vec2<u32>(u32(8))))) / vec2<f32>(1.6777216e+07f);
}

fn enters_0( n_0 : ptr<function, Node_std430_0>,  o_0 : vec3<f32>,  inv_0 : vec3<f32>,  tmax_0 : f32) -> bool
{
    var _S6 : vec3<f32> = (*n_0).lo_0;
    var _S7 : vec3<f32> = (*n_0).hi_0;
    if(((*n_0).lo_0.x) > ((*n_0).hi_0.x))
    {
        return false;
    }
    var t0_0 : vec3<f32> = (_S6 - o_0) * inv_0;
    var t1_0 : vec3<f32> = (_S7 - o_0) * inv_0;
    var near_0 : vec3<f32> = min(t0_0, t1_0);
    var far_0 : vec3<f32> = max(t0_0, t1_0);
    return (max(max(near_0.x, near_0.y), max(near_0.z, 0.0f))) <= (min(min(far_0.x, tmax_0), min(far_0.y, far_0.z)));
}

fn vertex_0( v_1 : u32) -> vec3<f32>
{
    var _S8 : u32 = u32(3) * v_1;
    return vec3<f32>(positions_0[_S8], positions_0[_S8 + u32(1)], positions_0[_S8 + u32(2)]);
}

fn hits_0( tri_0 : u32,  o_1 : vec3<f32>,  d_0 : vec3<f32>,  tmax_1 : f32) -> bool
{
    var _S9 : u32 = u32(3) * tri_0;
    var a_0 : u32 = indices_0[_S9];
    var b_0 : u32 = indices_0[_S9 + u32(1)];
    var c_0 : u32 = indices_0[_S9 + u32(2)];
    var _S10 : bool;
    if(a_0 == b_0)
    {
        _S10 = true;
    }
    else
    {
        _S10 = b_0 == c_0;
    }
    if(_S10)
    {
        _S10 = true;
    }
    else
    {
        _S10 = a_0 == c_0;
    }
    if(_S10)
    {
        return false;
    }
    var p0_0 : vec3<f32> = vertex_0(a_0);
    var e1_0 : vec3<f32> = vertex_0(b_0) - p0_0;
    var e2_0 : vec3<f32> = vertex_0(c_0) - p0_0;
    var pv_0 : vec3<f32> = cross(d_0, e2_0);
    var det_0 : f32 = dot(e1_0, pv_0);
    if(det_0 == 0.0f)
    {
        return false;
    }
    var f_0 : f32 = 1.0f / det_0;
    var tv_0 : vec3<f32> = o_1 - p0_0;
    var u_0 : f32 = dot(tv_0, pv_0) * f_0;
    if(u_0 < 0.0f)
    {
        _S10 = true;
    }
    else
    {
        _S10 = u_0 > 1.0f;
    }
    if(_S10)
    {
        return false;
    }
    var qv_0 : vec3<f32> = cross(tv_0, e1_0);
    var v_2 : f32 = dot(d_0, qv_0) * f_0;
    if(v_2 < 0.0f)
    {
        _S10 = true;
    }
    else
    {
        _S10 = (u_0 + v_2) > 1.0f;
    }
    if(_S10)
    {
        return false;
    }
    var t_0 : f32 = dot(e2_0, qv_0) * f_0;
    if(t_0 > 0.0f)
    {
        _S10 = t_0 < tmax_1;
    }
    else
    {
        _S10 = false;
    }
    return _S10;
}

fn occluded_0( o_2 : vec3<f32>,  d_1 : vec3<f32>,  tmax_2 : f32) -> bool
{
    var _S11 : vec3<f32> = vec3<f32>(1.0f) / select(d_1, vec3<f32>(9.99999968265522539e-21f), d_1 == vec3<f32>(0.0f));
    var stack_0 : array<u32, i32(114)>;
    stack_0[i32(0)] = u32(0);
    var ch_0 : vec4<u32> = vec4<u32>(u32(0));
    var top_0 : i32 = i32(1);
    for(;;)
    {
        if(top_0 > i32(0))
        {
        }
        else
        {
            break;
        }
        var top_1 : i32 = top_0 - i32(1);
        var e_0 : u32 = stack_0[top_1];
        if((((stack_0[top_1]) & (u32(2147483648)))) == u32(0))
        {
            var _S12 : Node_std430_0 = tlas_0[e_0];
            var _S13 : bool = enters_0(&(_S12), o_2, _S11, tmax_2);
            if(!_S13)
            {
                top_0 = top_1;
                continue;
            }
            if((_S12.count_0) == u32(0))
            {
                var top_2 : i32 = top_1 + i32(1);
                stack_0[top_1] = _S12.first_0;
                var _S14 : i32 = top_2 + i32(1);
                stack_0[top_2] = _S12.first_0 + u32(1);
                top_0 = _S14;
            }
            else
            {
                var _S15 : vec4<u32> = chunks_0[_S12.first_0];
                var _S16 : i32 = top_1 + i32(1);
                stack_0[top_1] = u32(2147483648);
                ch_0 = _S15;
                top_0 = _S16;
            }
            continue;
        }
        var _S17 : Node_std430_0 = nodes_0[ch_0.x + ((e_0 & (u32(2147483647))))];
        var _S18 : bool = enters_0(&(_S17), o_2, _S11, tmax_2);
        if(!_S18)
        {
            top_0 = top_1;
            continue;
        }
        var _S19 : u32 = _S17.count_0;
        if((_S17.count_0) == u32(0))
        {
            var top_3 : i32 = top_1 + i32(1);
            stack_0[top_1] = (u32(2147483648) | ((_S17.first_0)));
            var _S20 : i32 = top_3 + i32(1);
            stack_0[top_3] = (u32(2147483648) | ((_S17.first_0 + u32(1))));
            top_0 = _S20;
            continue;
        }
        var _S21 : u32 = _S17.first_0;
        var j_0 : u32 = _S17.first_0;
        for(;;)
        {
            if(j_0 < (_S21 + _S19))
            {
            }
            else
            {
                break;
            }
            var at_0 : u32 = ch_0.y + j_0;
            var word_0 : u32 = order_0[(at_0 >> (u32(1)))];
            var _S22 : u32 = ch_0.z;
            var _S23 : u32;
            if(((at_0 & (u32(1)))) == u32(0))
            {
                _S23 = (word_0 & (u32(65535)));
            }
            else
            {
                _S23 = (word_0 >> (u32(16)));
            }
            if(hits_0(_S22 + _S23, o_2, d_1, tmax_2))
            {
                return true;
            }
            j_0 = j_0 + u32(1);
        }
        top_0 = top_1;
    }
    return false;
}

@compute
@workgroup_size(8, 8, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>, @builtin(global_invocation_id) global_id_0 : vec3<u32>)
{
    var _S24 : vec2<f32> = vec2<f32>(texture_size_0(view_depth_texture_0, view_depth_sampler_0));
    var _S25 : vec2<i32> = vec2<i32>(global_id_0.xy);
    var _S26 : bool;
    if((_S25.x) >= i32(_S24.x))
    {
        _S26 = true;
    }
    else
    {
        _S26 = (_S25.y) >= i32(_S24.y);
    }
    if(_S26)
    {
        return;
    }
    var d_2 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    if(d_2 >= 1.0f)
    {
        return;
    }
    var frag_1 : vec2<f32> = vec2<f32>(_S25) + vec2<f32>(0.5f);
    var p_0 : vec3<f32> = world_at_0(frag_1, d_2, _S24);
    var hi_1 : vec2<i32> = vec2<i32>(_S24) - vec2<i32>(i32(1));
    const _S27 : vec2<i32> = vec2<i32>(i32(1), i32(0));
    var _S28 : vec2<i32> = vec2<i32>(i32(0));
    var dl_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    var dr_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    const _S29 : vec2<i32> = vec2<i32>(i32(0), i32(1));
    var du_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    var dd_0 : f32 = (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
    var px_r_0 : vec3<f32>;
    if((abs(dr_0 - d_2)) < (abs(d_2 - dl_0)))
    {
        px_r_0 = world_at_0(frag_1 + vec2<f32>(1.0f, 0.0f), dr_0, _S24) - p_0;
    }
    else
    {
        px_r_0 = p_0 - world_at_0(frag_1 - vec2<f32>(1.0f, 0.0f), dl_0, _S24);
    }
    var px_d_0 : vec3<f32>;
    if((abs(dd_0 - d_2)) < (abs(d_2 - du_0)))
    {
        px_d_0 = world_at_0(frag_1 + vec2<f32>(0.0f, 1.0f), dd_0, _S24) - p_0;
    }
    else
    {
        px_d_0 = p_0 - world_at_0(frag_1 - vec2<f32>(0.0f, 1.0f), du_0, _S24);
    }
    var n_1 : vec3<f32> = normalize(cross(px_d_0, px_r_0));
    var toward_eye_0 : vec3<f32> = normalize(world_at_0(frag_1, 0.0f, _S24) - p_0);
    var n_2 : vec3<f32>;
    if((dot(n_1, toward_eye_0)) < 0.0f)
    {
        n_2 = (vec3<f32>(0) - n_1);
    }
    else
    {
        n_2 = n_1;
    }
    var _S30 : vec2<u32> = vec2<u32>(_S25);
    var r2_0 : vec2<f32> = fract(Trace_Uniforms_0.params_0.xy + pixel_hash_0(_S30));
    var _S31 : f32 = (bitcast<f32>((u32(2139095040))));
    if((Trace_Uniforms_0.key_base_0.w) > 0.5f)
    {
        _S26 = (Trace_Uniforms_0.params_0.w) > 0.5f;
    }
    else
    {
        _S26 = false;
    }
    var dir_0 : vec3<f32>;
    var tmax_3 : f32;
    if(_S26)
    {
        var to_0 : vec3<f32> = Trace_Uniforms_0.sphere_0.xyz - p_0;
        var d2_0 : f32 = dot(to_0, to_0);
        var r_0 : f32 = Trace_Uniforms_0.sphere_0.w;
        var _S32 : f32 = r_0 * r_0;
        if(d2_0 <= _S32)
        {
            return;
        }
        var axis_0 : vec3<f32> = to_0 * vec3<f32>(rsqrt_0(d2_0));
        if((abs(axis_0.y)) < 0.99000000953674316f)
        {
            px_r_0 = vec3<f32>(0.0f, 1.0f, 0.0f);
        }
        else
        {
            px_r_0 = vec3<f32>(1.0f, 0.0f, 0.0f);
        }
        var side_0 : vec3<f32> = normalize(cross(axis_0, px_r_0));
        var a_1 : f32 = 6.28318548202514648f * r2_0.y;
        var dir_1 : vec3<f32> = to_0 + (side_0 * vec3<f32>(cos(a_1)) + cross(side_0, axis_0) * vec3<f32>(sin(a_1))) * vec3<f32>((r_0 * sqrt(d2_0 / (d2_0 - _S32)) * sqrt(r2_0.x)));
        if((dot(n_2, dir_1)) <= 0.0f)
        {
            return;
        }
        tmax_3 = 1.0f;
        dir_0 = dir_1;
    }
    else
    {
        if((Trace_Uniforms_0.key_base_0.w) > 0.5f)
        {
            var a_2 : f32 = 6.28318548202514648f * r2_0.y;
            var dir_2 : vec3<f32> = normalize(Trace_Uniforms_0.key_base_0.xyz + (Trace_Uniforms_0.key_side_0.xyz * vec3<f32>(cos(a_2)) + Trace_Uniforms_0.key_up_0.xyz * vec3<f32>(sin(a_2))) * vec3<f32>((Trace_Uniforms_0.key_side_0.w * sqrt(r2_0.x))));
            if((dot(n_2, dir_2)) <= 0.0f)
            {
                return;
            }
            dir_0 = dir_2;
        }
        else
        {
            var _S33 : f32 = n_2.z;
            if(_S33 >= 0.0f)
            {
                tmax_3 = 1.0f;
            }
            else
            {
                tmax_3 = -1.0f;
            }
            var a_3 : f32 = -1.0f / (tmax_3 + _S33);
            var _S34 : f32 = n_2.x;
            var _S35 : f32 = n_2.y;
            var b_1 : f32 = _S34 * _S35 * a_3;
            var _S36 : f32 = r2_0.x;
            var r_1 : f32 = sqrt(_S36);
            var phi_0 : f32 = 6.28318548202514648f * r2_0.y;
            dir_0 = normalize(vec3<f32>(1.0f + tmax_3 * _S34 * _S34 * a_3, tmax_3 * b_1, - tmax_3 * _S34) * vec3<f32>((r_1 * cos(phi_0))) + vec3<f32>(b_1, tmax_3 + _S35 * _S35 * a_3, - _S35) * vec3<f32>((r_1 * sin(phi_0))) + n_2 * vec3<f32>(sqrt(max(1.0f - _S36, 0.0f))));
        }
        tmax_3 = _S31;
    }
    var o_3 : vec3<f32> = p_0 + (n_2 + toward_eye_0) * vec3<f32>((Trace_Uniforms_0.params_0.z + min(2.0f * length(world_at_0(frag_1 + vec2<f32>(1.0f, 0.0f), d_2, _S24) - p_0), 100.0f * Trace_Uniforms_0.params_0.z)));
    if(tmax_3 == 1.0f)
    {
        dir_0 = p_0 + dir_0 - o_3;
    }
    var _S37 : mat4x4<f32> = mat4x4<f32>(Trace_Uniforms_0.to_mesh_0.data_0[i32(0)][i32(0)], Trace_Uniforms_0.to_mesh_0.data_0[i32(0)][i32(1)], Trace_Uniforms_0.to_mesh_0.data_0[i32(0)][i32(2)], Trace_Uniforms_0.to_mesh_0.data_0[i32(0)][i32(3)], Trace_Uniforms_0.to_mesh_0.data_0[i32(1)][i32(0)], Trace_Uniforms_0.to_mesh_0.data_0[i32(1)][i32(1)], Trace_Uniforms_0.to_mesh_0.data_0[i32(1)][i32(2)], Trace_Uniforms_0.to_mesh_0.data_0[i32(1)][i32(3)], Trace_Uniforms_0.to_mesh_0.data_0[i32(2)][i32(0)], Trace_Uniforms_0.to_mesh_0.data_0[i32(2)][i32(1)], Trace_Uniforms_0.to_mesh_0.data_0[i32(2)][i32(2)], Trace_Uniforms_0.to_mesh_0.data_0[i32(2)][i32(3)], Trace_Uniforms_0.to_mesh_0.data_0[i32(3)][i32(0)], Trace_Uniforms_0.to_mesh_0.data_0[i32(3)][i32(1)], Trace_Uniforms_0.to_mesh_0.data_0[i32(3)][i32(2)], Trace_Uniforms_0.to_mesh_0.data_0[i32(3)][i32(3)]);
    if(occluded_0((((mat4x4<f32>(Trace_Uniforms_0.to_mesh_0.data_0[i32(0)][i32(0)], Trace_Uniforms_0.to_mesh_0.data_0[i32(0)][i32(1)], Trace_Uniforms_0.to_mesh_0.data_0[i32(0)][i32(2)], Trace_Uniforms_0.to_mesh_0.data_0[i32(0)][i32(3)], Trace_Uniforms_0.to_mesh_0.data_0[i32(1)][i32(0)], Trace_Uniforms_0.to_mesh_0.data_0[i32(1)][i32(1)], Trace_Uniforms_0.to_mesh_0.data_0[i32(1)][i32(2)], Trace_Uniforms_0.to_mesh_0.data_0[i32(1)][i32(3)], Trace_Uniforms_0.to_mesh_0.data_0[i32(2)][i32(0)], Trace_Uniforms_0.to_mesh_0.data_0[i32(2)][i32(1)], Trace_Uniforms_0.to_mesh_0.data_0[i32(2)][i32(2)], Trace_Uniforms_0.to_mesh_0.data_0[i32(2)][i32(3)], Trace_Uniforms_0.to_mesh_0.data_0[i32(3)][i32(0)], Trace_Uniforms_0.to_mesh_0.data_0[i32(3)][i32(1)], Trace_Uniforms_0.to_mesh_0.data_0[i32(3)][i32(2)], Trace_Uniforms_0.to_mesh_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(o_3, 1.0f)))).xyz, (((mat3x3<f32>(_S37[i32(0)].xyz, _S37[i32(1)].xyz, _S37[i32(2)].xyz)) * (dir_0))), tmax_3))
    {
        textureStore((visible_0), (_S30), (vec4<f32>(0.0f)));
    }
    return;
}

