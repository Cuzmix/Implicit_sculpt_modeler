// slangc wgsl from dab_smooth_targets.comp.spv sha256 252c9bda806713fd8a41ab608d3ebb84c7d6717aab2ed3eac286bc49656ab74a
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Params_std140_0
{
    @align(16) dab_0 : u32,
    @align(4) groups_x_0 : u32,
    @align(8) rate_0 : f32,
    @align(4) stroke_0 : u32,
};

@binding(0) @group(2) var<uniform> Params_0 : SLANG_ParameterGroup_Params_std140_0;
@binding(0) @group(0) var<storage, read> indices_0 : array<u32>;

@binding(2) @group(0) var<storage, read> offsets_0 : array<u32>;

@binding(4) @group(0) var<storage, read> tris_0 : array<u32>;

@binding(6) @group(0) var<storage, read> slabs_0 : array<vec2<u32>>;

struct Dab_std430_0
{
    @align(16) center_r2_0 : vec4<f32>,
    @align(16) view_inv_r2_0 : vec4<f32>,
    @align(16) facing_amount_0 : vec4<f32>,
    @align(16) tilt0_0 : vec4<f32>,
    @align(16) tilt1_0 : vec4<f32>,
    @align(16) tilt2_0 : vec4<f32>,
    @align(16) misc_0 : vec4<f32>,
    @align(16) alpha_up_0 : vec4<f32>,
    @align(16) slabs_1 : vec4<u32>,
};

@binding(8) @group(0) var<storage, read> dabs_0 : array<Dab_std430_0>;

@binding(10) @group(0) var<storage, read> normals_0 : array<u32>;

@binding(12) @group(0) var<storage, read> mask_0 : array<u32>;

@binding(16) @group(0) var<storage, read> fade_0 : array<u32>;

@binding(0) @group(1) var<storage, read_write> positions_0 : array<f32>;

@binding(14) @group(0) var<storage, read> tables_0 : array<f32>;

@binding(6) @group(1) var<storage, read_write> scratch_0 : array<vec4<f32>>;

fn keep_bindings_0()
{
    if((Params_0.groups_x_0) == u32(0))
    {
        positions_0[i32(0)] = f32(indices_0[i32(0)] + offsets_0[i32(0)] + tris_0[i32(0)] + slabs_0[i32(0)].x + dabs_0[i32(0)].slabs_1.x + normals_0[i32(0)] + mask_0[i32(0)] + fade_0[i32(0)]) + tables_0[i32(0)];
    }
    return;
}

fn at_0( v_0 : u32) -> vec3<f32>
{
    var _S1 : u32 = u32(3) * v_0;
    return vec3<f32>(positions_0[_S1], positions_0[_S1 + u32(1)], positions_0[_S1 + u32(2)]);
}

fn slab_vertex_0( _S2 : u32,  _S3 : vec3<u32>,  _S4 : vec3<u32>,  _S5 : ptr<function, u32>,  _S6 : ptr<function, u32>) -> bool
{
    (*_S5) = _S3.y * Params_0.groups_x_0 + _S3.x;
    (*_S6) = u32(0);
    var _S7 : vec4<u32> = dabs_0[_S2].slabs_1;
    if((*_S5) >= (dabs_0[_S2].slabs_1.y))
    {
        return false;
    }
    var slab_0 : vec2<u32> = slabs_0[_S7.x + (*_S5)];
    var _S8 : u32 = _S4.x;
    if(_S8 >= (slab_0.y))
    {
        return false;
    }
    (*_S6) = slab_0.x + _S8;
    return true;
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    keep_bindings_0();
    var g_0 : u32;
    var v_1 : u32;
    var _S9 : bool = slab_vertex_0(Params_0.dab_0, group_id_0, local_id_0, &(g_0), &(v_1));
    if(!_S9)
    {
        return;
    }
    var delta_0 : vec3<f32> = at_0(v_1) - dabs_0[Params_0.dab_0].center_r2_0.xyz;
    if((dot(delta_0, delta_0)) >= (dabs_0[Params_0.dab_0].center_r2_0.w))
    {
        return;
    }
    var _S10 : vec3<f32> = vec3<f32>(0.0f);
    var first_0 : u32 = offsets_0[v_1];
    var _S11 : u32 = offsets_0[v_1 + u32(1)];
    var k_0 : u32 = first_0;
    var sum_0 : vec3<f32> = _S10;
    var odd_0 : u32 = u32(0);
    var n_0 : f32 = 0.0f;
    for(;;)
    {
        if(k_0 < _S11)
        {
        }
        else
        {
            break;
        }
        var _S12 : u32 = u32(3) * tris_0[k_0];
        var a_0 : u32 = indices_0[_S12];
        var b_0 : u32 = indices_0[_S12 + u32(1)];
        var c_0 : u32 = indices_0[_S12 + u32(2)];
        var sum_1 : vec3<f32> = sum_0 + (at_0(a_0) + at_0(b_0) + at_0(c_0));
        var odd_1 : u32 = (odd_0 ^ (((((((a_0 ^ (b_0))) ^ (c_0))) ^ (v_1)))));
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
        sum_0 = at_0(v_1);
    }
    var _S13 : bool;
    if(odd_0 != u32(0))
    {
        _S13 = n_0 <= 96.0f;
    }
    else
    {
        _S13 = false;
    }
    var q_0 : vec3<f32>;
    if(_S13)
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
            if(k_0 < _S11)
            {
            }
            else
            {
                break;
            }
            var _S14 : u32 = tris_0[k_0];
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
                var w_0 : u32 = indices_0[u32(3) * _S14 + i_0];
                if(w_0 == v_1)
                {
                    i_0 = i_0 + u32(1);
                    continue;
                }
                j_0 = u32(0);
                for(;;)
                {
                    if(j_0 < count_1)
                    {
                        _S13 = (seen_0[j_0]) != w_0;
                    }
                    else
                    {
                        _S13 = false;
                    }
                    if(_S13)
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
        var border_0 : vec3<f32> = _S10;
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
    scratch_0[g_0 * u32(256) + local_id_0.x] = vec4<f32>(q_0, 1.0f);
    return;
}

