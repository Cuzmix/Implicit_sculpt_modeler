// slangc wgsl from node_bounds.comp.spv sha256 d0ef7dd31637b49a1428fa1829a6b5992fe3ff0ce78975971132a4aa6c281a7c
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Params_std140_0
{
    @align(16) node_count_0 : u32,
    @align(4) groups_x_0 : u32,
};

@binding(0) @group(2) var<uniform> Params_0 : SLANG_ParameterGroup_Params_std140_0;
@binding(2) @group(0) var<storage, read> nodes_0 : array<vec4<u32>>;

@binding(0) @group(0) var<storage, read> positions_0 : array<f32>;

@binding(4) @group(0) var<storage, read> shared_0 : array<u32>;

@binding(0) @group(1) var<storage, read_write> bounds_0 : array<vec4<f32>>;

fn at_0( v_0 : u32) -> vec3<f32>
{
    var _S1 : u32 = u32(3) * v_0;
    return vec3<f32>(positions_0[_S1], positions_0[_S1 + u32(1)], positions_0[_S1 + u32(2)]);
}

var<workgroup> lane_lo_0 : array<vec3<f32>, i32(256)>;

var<workgroup> lane_hi_0 : array<vec3<f32>, i32(256)>;

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    var g_0 : u32 = group_id_0.y * Params_0.groups_x_0 + group_id_0.x;
    if(g_0 >= (Params_0.node_count_0))
    {
        return;
    }
    var _S2 : vec4<u32> = nodes_0[g_0];
    const _S3 : vec3<f32> = vec3<f32>(-3.4028234663852886e+38f, -3.4028234663852886e+38f, -3.4028234663852886e+38f);
    var _S4 : u32 = local_id_0.x;
    var lo_0 : vec3<f32> = vec3<f32>(3.4028234663852886e+38f, 3.4028234663852886e+38f, 3.4028234663852886e+38f);
    var hi_0 : vec3<f32> = _S3;
    var k_0 : u32 = _S4;
    for(;;)
    {
        if(k_0 < (_S2.y))
        {
        }
        else
        {
            break;
        }
        var p_0 : vec3<f32> = at_0(_S2.x + k_0);
        var _S5 : vec3<f32> = min(lo_0, p_0);
        var _S6 : vec3<f32> = max(hi_0, p_0);
        var k_1 : u32 = k_0 + u32(256);
        lo_0 = _S5;
        hi_0 = _S6;
        k_0 = k_1;
    }
    k_0 = _S4;
    for(;;)
    {
        if(k_0 < (_S2.w))
        {
        }
        else
        {
            break;
        }
        var p_1 : vec3<f32> = at_0(shared_0[_S2.z + k_0]);
        var _S7 : vec3<f32> = min(lo_0, p_1);
        var _S8 : vec3<f32> = max(hi_0, p_1);
        var k_2 : u32 = k_0 + u32(256);
        lo_0 = _S7;
        hi_0 = _S8;
        k_0 = k_2;
    }
    lane_lo_0[_S4] = lo_0;
    lane_hi_0[_S4] = hi_0;
    workgroupBarrier();
    var width_0 : u32 = u32(128);
    for(;;)
    {
        if(width_0 > u32(0))
        {
        }
        else
        {
            break;
        }
        if(_S4 < width_0)
        {
            lane_lo_0[_S4] = min(lane_lo_0[_S4], lane_lo_0[_S4 + width_0]);
            lane_hi_0[_S4] = max(lane_hi_0[_S4], lane_hi_0[_S4 + width_0]);
        }
        workgroupBarrier();
        width_0 = width_0 / u32(2);
    }
    if(_S4 != u32(0))
    {
        return;
    }
    var _S9 : u32 = u32(2) * g_0;
    bounds_0[_S9] = vec4<f32>(lane_lo_0[i32(0)], 0.0f);
    bounds_0[_S9 + u32(1)] = vec4<f32>(lane_hi_0[i32(0)], 0.0f);
    return;
}

