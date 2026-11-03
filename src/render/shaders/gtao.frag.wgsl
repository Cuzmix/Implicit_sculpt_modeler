// slangc wgsl from gtao.frag.spv sha256 010cfb70d8ebda4d93a14b591d351523c866328085bfa651ec75b9310d4b969e
diagnostic(off, derivative_uniformity);
struct _MatrixStorage_float4x4std140_0
{
    @align(16) data_0 : array<vec4<f32>, i32(4)>,
};

struct SLANG_ParameterGroup_Gtao_Uniforms_std140_0
{
    @align(16) inv_proj_0 : _MatrixStorage_float4x4std140_0,
    @align(16) size_0 : vec4<f32>,
    @align(16) params_0 : vec4<f32>,
};

@binding(0) @group(3) var<uniform> Gtao_Uniforms_0 : SLANG_ParameterGroup_Gtao_Uniforms_std140_0;
@binding(0) @group(2) var view_depth_texture_0 : texture_2d<f32>;

@binding(1) @group(2) var view_depth_sampler_0 : sampler;

var<private> BAYER_0 : array<f32, i32(16)> = array<f32, i32(16)>( 0.0f, 8.0f, 2.0f, 10.0f, 12.0f, 4.0f, 14.0f, 6.0f, 3.0f, 11.0f, 1.0f, 9.0f, 15.0f, 7.0f, 13.0f, 5.0f );
fn depth_at_0( px_0 : vec2<i32>) -> f32
{
    return (textureLoad((view_depth_texture_0), ((view_depth_sampler_0)).xy, ((view_depth_sampler_0)).z)).x;
}

fn view_at_0( px_1 : vec2<i32>,  depth_0 : f32) -> vec3<f32>
{
    var v_0 : vec4<f32> = (((mat4x4<f32>(Gtao_Uniforms_0.inv_proj_0.data_0[i32(0)][i32(0)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(0)][i32(1)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(0)][i32(2)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(0)][i32(3)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(1)][i32(0)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(1)][i32(1)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(1)][i32(2)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(1)][i32(3)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(2)][i32(0)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(2)][i32(1)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(2)][i32(2)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(2)][i32(3)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(3)][i32(0)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(3)][i32(1)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(3)][i32(2)], Gtao_Uniforms_0.inv_proj_0.data_0[i32(3)][i32(3)])) * (vec4<f32>(vec2<f32>(2.0f * (f32(px_1.x) + 0.5f) / Gtao_Uniforms_0.size_0.x - 1.0f, 1.0f - 2.0f * (f32(px_1.y) + 0.5f) / Gtao_Uniforms_0.size_0.y), depth_0, 1.0f))));
    return v_0.xyz / vec3<f32>(v_0.w);
}

struct pixelOutput_0
{
    @location(0) output_0 : vec4<f32>,
};

@fragment
fn main(@builtin(position) frag_coord_0 : vec4<f32>) -> pixelOutput_0
{
    var _S1 : vec2<i32> = vec2<i32>(frag_coord_0.xy);
    var scale_0 : i32 = i32(Gtao_Uniforms_0.size_0.z);
    var px_2 : vec2<i32> = _S1 * vec2<i32>(scale_0) + vec2<i32>((scale_0 / i32(2)));
    var d_0 : f32 = depth_at_0(px_2);
    if(d_0 >= 1.0f)
    {
        var _S2 : pixelOutput_0 = pixelOutput_0( vec4<f32>(1.0f) );
        return _S2;
    }
    var p_0 : vec3<f32> = view_at_0(px_2, d_0);
    var v_1 : vec3<f32>;
    if((Gtao_Uniforms_0.size_0.w) > 0.5f)
    {
        v_1 = vec3<f32>(0.0f, 0.0f, 1.0f);
    }
    else
    {
        v_1 = normalize((vec3<f32>(0) - p_0));
    }
    const _S3 : vec2<i32> = vec2<i32>(i32(1), i32(0));
    var _S4 : vec2<i32> = px_2 - _S3;
    var dl_0 : f32 = depth_at_0(_S4);
    var _S5 : vec2<i32> = px_2 + _S3;
    var dr_0 : f32 = depth_at_0(_S5);
    const _S6 : vec2<i32> = vec2<i32>(i32(0), i32(1));
    var _S7 : vec2<i32> = px_2 - _S6;
    var du_0 : f32 = depth_at_0(_S7);
    var _S8 : vec2<i32> = px_2 + _S6;
    var dd_0 : f32 = depth_at_0(_S8);
    var right_0 : vec3<f32>;
    if((abs(dr_0 - d_0)) < (abs(d_0 - dl_0)))
    {
        right_0 = view_at_0(_S5, dr_0) - p_0;
    }
    else
    {
        right_0 = p_0 - view_at_0(_S4, dl_0);
    }
    var down_0 : vec3<f32>;
    if((abs(dd_0 - d_0)) < (abs(d_0 - du_0)))
    {
        down_0 = view_at_0(_S8, dd_0) - p_0;
    }
    else
    {
        down_0 = p_0 - view_at_0(_S7, du_0);
    }
    var n_0 : vec3<f32> = normalize(cross(right_0, down_0));
    var n_1 : vec3<f32>;
    if((dot(n_0, v_1)) < 0.0f)
    {
        n_1 = (vec3<f32>(0) - n_0);
    }
    else
    {
        n_1 = n_0;
    }
    var reach_0 : f32 = Gtao_Uniforms_0.params_0.x;
    var _S9 : f32 = reach_0 * Gtao_Uniforms_0.params_0.y;
    var visibility_0 : f32;
    if((Gtao_Uniforms_0.size_0.w) > 0.5f)
    {
        visibility_0 = 1.0f;
    }
    else
    {
        visibility_0 = - p_0.z;
    }
    var _S10 : f32 = min(_S9 / visibility_0, Gtao_Uniforms_0.params_0.z);
    if(_S10 < 1.29999995231628418f)
    {
        var _S11 : pixelOutput_0 = pixelOutput_0( vec4<f32>(1.0f) );
        return _S11;
    }
    var _S12 : f32 = -1.0f / (0.61500000953674316f * reach_0);
    var _S13 : i32 = _S1.y;
    var _S14 : i32 = _S1.x;
    var _S15 : f32 = (BAYER_0[((_S13 & (i32(3)))) * i32(4) + ((_S14 & (i32(3))))] + 0.5f) / 16.0f;
    var _S16 : f32 = (f32(((_S14 - _S13) & (i32(3)))) + 0.5f) / 4.0f;
    var _S17 : f32 = 1.29999995231628418f / _S10;
    var slice_0 : i32 = i32(0);
    visibility_0 = 0.0f;
    for(;;)
    {
        if(slice_0 < i32(2))
        {
        }
        else
        {
            break;
        }
        var phi_0 : f32 = (f32(slice_0) + _S15) * 3.14159274101257324f / 2.0f;
        var _S18 : f32 = cos(phi_0);
        var _S19 : f32 = sin(phi_0);
        var omega_0 : vec2<f32> = vec2<f32>(_S18, _S19);
        var dir_0 : vec3<f32> = vec3<f32>(_S18, - _S19, 0.0f);
        var ortho_0 : vec3<f32> = dir_0 - vec3<f32>(dot(dir_0, v_1)) * v_1;
        var axis_0 : vec3<f32> = normalize(cross(ortho_0, v_1));
        var projected_0 : vec3<f32> = n_1 - axis_0 * vec3<f32>(dot(n_1, axis_0));
        var projected_len_0 : f32 = length(projected_0);
        var cos_n_0 : f32 = clamp(dot(projected_0, v_1) / max(projected_len_0, 9.99999997475242708e-07f), -1.0f, 1.0f);
        var gamma_0 : f32 = f32((i32(sign((dot(ortho_0, projected_0)))))) * acos(cos_n_0);
        var low_plus_0 : f32 = cos(gamma_0 + 1.57079637050628662f);
        var low_minus_0 : f32 = cos(gamma_0 - 1.57079637050628662f);
        var horizon_plus_0 : f32 = low_plus_0;
        var horizon_minus_0 : f32 = low_minus_0;
        var step_0 : i32 = i32(0);
        for(;;)
        {
            if(step_0 < i32(6))
            {
            }
            else
            {
                break;
            }
            var s_0 : f32 = (f32(step_0) + _S16) / 6.0f;
            var _S20 : vec2<i32> = vec2<i32>(round(omega_0 * vec2<f32>((s_0 * s_0 + _S17)) * vec2<f32>(_S10)));
            var horizon_plus_1 : f32 = horizon_plus_0;
            var horizon_minus_1 : f32 = horizon_minus_0;
            var side_0 : i32 = i32(0);
            for(;;)
            {
                if(side_0 < i32(2))
                {
                }
                else
                {
                    break;
                }
                var _S21 : bool = side_0 == i32(0);
                var q_0 : vec2<i32>;
                if(_S21)
                {
                    q_0 = px_2 + _S20;
                }
                else
                {
                    q_0 = px_2 - _S20;
                }
                var delta_0 : vec3<f32> = view_at_0(q_0, depth_at_0(q_0)) - p_0;
                var dist_0 : f32 = length(delta_0);
                var c_0 : f32 = dot(delta_0, v_1) / max(dist_0, 9.99999997475242708e-07f);
                var w_0 : f32 = clamp(dist_0 * _S12 + 1.62601625919342041f, 0.0f, 1.0f);
                if(_S21)
                {
                    horizon_plus_1 = max(horizon_plus_1, mix(low_plus_0, c_0, w_0));
                }
                else
                {
                    horizon_minus_1 = max(horizon_minus_1, mix(low_minus_0, c_0, w_0));
                }
                side_0 = side_0 + i32(1);
            }
            var _S22 : i32 = step_0 + i32(1);
            horizon_plus_0 = horizon_plus_1;
            horizon_minus_0 = horizon_minus_1;
            step_0 = _S22;
        }
        var _S23 : f32 = 2.0f * (gamma_0 + clamp(- acos(clamp(horizon_minus_0, -1.0f, 1.0f)) - gamma_0, -1.57079637050628662f, 1.57079637050628662f));
        var _S24 : f32 = sin(gamma_0);
        var _S25 : f32 = 2.0f * (gamma_0 + clamp(acos(clamp(horizon_plus_0, -1.0f, 1.0f)) - gamma_0, -1.57079637050628662f, 1.57079637050628662f));
        var visibility_1 : f32 = visibility_0 + projected_len_0 * ((cos_n_0 + _S23 * _S24 - cos(_S23 - gamma_0)) / 4.0f + (cos_n_0 + _S25 * _S24 - cos(_S25 - gamma_0)) / 4.0f);
        slice_0 = slice_0 + i32(1);
        visibility_0 = visibility_1;
    }
    var _S26 : pixelOutput_0 = pixelOutput_0( vec4<f32>(max(visibility_0 / 2.0f, 0.0f)) );
    return _S26;
}

