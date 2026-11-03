// slangc wgsl from smooth_all.comp.spv sha256 5b053976a10cbb7699d06d98698f7e1577599bda5da5246fe9e2b8ab1871f7bc
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Params_std140_0
{
    @align(16) vertex_count_0 : u32,
    @align(4) groups_x_0 : u32,
};

@binding(0) @group(2) var<uniform> Params_0 : SLANG_ParameterGroup_Params_std140_0;
@binding(8) @group(0) var<storage, read> src_0 : array<f32>;

@binding(6) @group(0) var<storage, read> weights_0 : array<f32>;

@binding(2) @group(0) var<storage, read> offsets_0 : array<u32>;

@binding(4) @group(0) var<storage, read> tris_0 : array<u32>;

@binding(0) @group(0) var<storage, read> indices_0 : array<u32>;

@binding(0) @group(1) var<storage, read_write> dst_0 : array<f32>;

fn at_0( v_0 : u32) -> vec3<f32>
{
    var _S1 : u32 = u32(3) * v_0;
    return vec3<f32>(src_0[_S1], src_0[_S1 + u32(1)], src_0[_S1 + u32(2)]);
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>, @builtin(global_invocation_id) global_id_0 : vec3<u32>)
{
    var v_1 : u32 = (group_id_0.y * Params_0.groups_x_0 + group_id_0.x) * u32(256) + local_id_0.x;
    if(v_1 >= (Params_0.vertex_count_0))
    {
        return;
    }
    var p_0 : vec3<f32> = at_0(v_1);
    var w_0 : f32 = weights_0[v_1];
    var first_0 : u32 = offsets_0[v_1];
    var last_0 : u32 = offsets_0[v_1 + u32(1)];
    var _S2 : bool;
    if(w_0 > 0.0f)
    {
        _S2 = last_0 > first_0;
    }
    else
    {
        _S2 = false;
    }
    var p_1 : vec3<f32>;
    if(_S2)
    {
        var _S3 : vec3<f32> = vec3<f32>(0.0f);
        var k_0 : u32 = first_0;
        p_1 = _S3;
        for(;;)
        {
            if(k_0 < last_0)
            {
            }
            else
            {
                break;
            }
            var _S4 : u32 = u32(3) * tris_0[k_0];
            var sum_0 : vec3<f32> = p_1 + (at_0(indices_0[_S4]) + at_0(indices_0[_S4 + u32(1)]) + at_0(indices_0[_S4 + u32(2)]));
            k_0 = k_0 + u32(1);
            p_1 = sum_0;
        }
        p_1 = p_0 * vec3<f32>((1.0f - w_0)) + p_1 / vec3<f32>(f32(u32(3) * (last_0 - first_0))) * vec3<f32>(w_0);
    }
    else
    {
        p_1 = p_0;
    }
    var _S5 : u32 = u32(3) * v_1;
    dst_0[_S5] = p_1.x;
    dst_0[_S5 + u32(1)] = p_1.y;
    dst_0[_S5 + u32(2)] = p_1.z;
    return;
}

