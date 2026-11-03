// slangc wgsl from dab_smooth_targets.comp.spv sha256 825bb37c0f363681a10fd5b8860d5115d64f1cc0d91c100e62e853e016418ed6
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Params_std140_0
{
    @align(16) dab_0 : u32,
    @align(4) groups_x_0 : u32,
    @align(8) rate_0 : f32,
    @align(4) stroke_0 : u32,
};

@binding(0) @group(2) var<uniform> Params_0 : SLANG_ParameterGroup_Params_std140_0;
struct Dab_std430_0
{
    @align(16) center_r2_0 : vec4<f32>,
    @align(16) view_inv_r2_0 : vec4<f32>,
    @align(16) facing_amount_0 : vec4<f32>,
    @align(16) tilt0_0 : vec4<f32>,
    @align(16) tilt1_0 : vec4<f32>,
    @align(16) tilt2_0 : vec4<f32>,
    @align(16) misc_0 : vec4<f32>,
    @align(16) slabs_0 : vec4<u32>,
};

@binding(8) @group(0) var<storage, read> dabs_0 : array<Dab_std430_0>;

@binding(6) @group(0) var<storage, read> slabs_1 : array<vec2<u32>>;

@binding(0) @group(1) var<storage, read_write> positions_0 : array<f32>;

@binding(2) @group(0) var<storage, read> offsets_0 : array<u32>;

@binding(4) @group(0) var<storage, read> tris_0 : array<u32>;

@binding(0) @group(0) var<storage, read> indices_0 : array<u32>;

@binding(6) @group(1) var<storage, read_write> scratch_0 : array<vec4<f32>>;

fn slab_vertex_0( d_0 : ptr<function, Dab_std430_0>,  group_id_0 : vec3<u32>,  local_id_0 : vec3<u32>,  g_0 : ptr<function, u32>,  v_0 : ptr<function, u32>) -> bool
{
    (*g_0) = group_id_0.y * Params_0.groups_x_0 + group_id_0.x;
    (*v_0) = u32(0);
    var _S1 : vec4<u32> = (*d_0).slabs_0;
    if((*g_0) >= ((*d_0).slabs_0.y))
    {
        return false;
    }
    var slab_0 : vec2<u32> = slabs_1[_S1.x + (*g_0)];
    var _S2 : u32 = local_id_0.x;
    if(_S2 >= (slab_0.y))
    {
        return false;
    }
    (*v_0) = slab_0.x + _S2;
    return true;
}

fn at_0( v_1 : u32) -> vec3<f32>
{
    var _S3 : u32 = u32(3) * v_1;
    return vec3<f32>(positions_0[_S3], positions_0[_S3 + u32(1)], positions_0[_S3 + u32(2)]);
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_1 : vec3<u32>, @builtin(local_invocation_id) local_id_1 : vec3<u32>)
{
    var _S4 : Dab_std430_0 = dabs_0[Params_0.dab_0];
    var g_1 : u32;
    var v_2 : u32;
    var _S5 : bool = slab_vertex_0(&(_S4), group_id_1, local_id_1, &(g_1), &(v_2));
    if(!_S5)
    {
        return;
    }
    var delta_0 : vec3<f32> = at_0(v_2) - _S4.center_r2_0.xyz;
    if((dot(delta_0, delta_0)) >= (_S4.center_r2_0.w))
    {
        return;
    }
    var _S6 : vec3<f32> = vec3<f32>(0.0f);
    var first_0 : u32 = offsets_0[v_2];
    var _S7 : u32 = offsets_0[v_2 + u32(1)];
    var k_0 : u32 = first_0;
    var sum_0 : vec3<f32> = _S6;
    var odd_0 : u32 = u32(0);
    var n_0 : f32 = 0.0f;
    for(;;)
    {
        if(k_0 < _S7)
        {
        }
        else
        {
            break;
        }
        var _S8 : u32 = u32(3) * tris_0[k_0];
        var a_0 : u32 = indices_0[_S8];
        var b_0 : u32 = indices_0[_S8 + u32(1)];
        var c_0 : u32 = indices_0[_S8 + u32(2)];
        var sum_1 : vec3<f32> = sum_0 + (at_0(a_0) + at_0(b_0) + at_0(c_0));
        var odd_1 : u32 = (odd_0 ^ (((((((a_0 ^ (b_0))) ^ (c_0))) ^ (v_2)))));
        var n_1 : f32 = n_0 + 3.0f;
        k_0 = k_0 + u32(1);
        sum_0 = sum_1;
        odd_0 = odd_1;
        n_0 = n_1;
    }
    if(n_0 > 0.0f)
    {
        sum_0 = sum_0 / vec3<f32>(n_0);
    }
    else
    {
        sum_0 = at_0(v_2);
    }
    var _S9 : bool;
    if(odd_0 != u32(0))
    {
        _S9 = n_0 <= 96.0f;
    }
    else
    {
        _S9 = false;
    }
    var q_0 : vec3<f32>;
    if(_S9)
    {
        var seen_0 : array<u32, i32(64)>;
        var times_0 : array<u32, i32(64)>;
        var j_0 : u32 = u32(0);
        for(;;)
        {
            if(j_0 < u32(64))
            {
            }
            else
            {
                break;
            }
            seen_0[j_0] = u32(0);
            times_0[j_0] = u32(0);
            j_0 = j_0 + u32(1);
        }
        k_0 = first_0;
        var count_0 : u32 = u32(0);
        for(;;)
        {
            if(k_0 < _S7)
            {
            }
            else
            {
                break;
            }
            var _S10 : u32 = tris_0[k_0];
            var i_0 : u32 = u32(0);
            var count_1 : u32 = count_0;
            for(;;)
            {
                if(i_0 < u32(3))
                {
                }
                else
                {
                    break;
                }
                var w_0 : u32 = indices_0[u32(3) * _S10 + i_0];
                if(w_0 == v_2)
                {
                    i_0 = i_0 + u32(1);
                    continue;
                }
                j_0 = u32(0);
                for(;;)
                {
                    if(j_0 < count_1)
                    {
                        _S9 = (seen_0[j_0]) != w_0;
                    }
                    else
                    {
                        _S9 = false;
                    }
                    if(_S9)
                    {
                    }
                    else
                    {
                        break;
                    }
                    j_0 = j_0 + u32(1);
                }
                var count_2 : u32;
                if(j_0 == count_1)
                {
                    seen_0[j_0] = w_0;
                    times_0[j_0] = u32(0);
                    count_2 = count_1 + u32(1);
                }
                else
                {
                    count_2 = count_1;
                }
                times_0[j_0] = times_0[j_0] + u32(1);
                count_1 = count_2;
                i_0 = i_0 + u32(1);
            }
            k_0 = k_0 + u32(1);
            count_0 = count_1;
        }
        j_0 = u32(0);
        var border_0 : vec3<f32> = _S6;
        var b_1 : f32 = 0.0f;
        for(;;)
        {
            if(j_0 < count_0)
            {
            }
            else
            {
                break;
            }
            if((times_0[j_0]) == u32(1))
            {
                var b_2 : f32 = b_1 + 1.0f;
                border_0 = border_0 + at_0(seen_0[j_0]);
                b_1 = b_2;
            }
            j_0 = j_0 + u32(1);
        }
        if(b_1 > 0.0f)
        {
            q_0 = border_0 / vec3<f32>(b_1);
        }
        else
        {
            q_0 = sum_0;
        }
    }
    else
    {
        q_0 = sum_0;
    }
    scratch_0[g_1 * u32(256) + local_id_1.x] = vec4<f32>(q_0, 1.0f);
    return;
}

