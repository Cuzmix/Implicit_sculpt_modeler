// slangc wgsl from cull_write.comp.spv sha256 b3832713eb98801e216f08fd991678d29e16703639e827c59b474555a4f457b6
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Cull_Uniforms_std140_0
{
    @align(16) planes_0 : array<vec4<f32>, i32(6)>,
    @align(16) eye_0 : vec4<f32>,
    @align(16) counts_0 : vec4<u32>,
};

@binding(0) @group(2) var<uniform> Cull_Uniforms_0 : SLANG_ParameterGroup_Cull_Uniforms_std140_0;
@binding(4) @group(0) var<storage, read> totals_0 : array<vec4<u32>>;

@binding(0) @group(1) var<storage, read_write> commands_0 : array<u32>;

@binding(2) @group(0) var<storage, read> groups_0 : array<u32>;

@binding(0) @group(0) var<storage, read> chunks_0 : array<u32>;

var<workgroup> lanes_0 : array<vec4<u32>, i32(64)>;

struct Record_0
{
     lo_0 : vec3<f32>,
     hi_0 : vec3<f32>,
     axis_0 : vec3<f32>,
     cutoff_0 : f32,
     first_index_0 : u32,
     index_count_0 : u32,
};

fn group_record_0( g_0 : u32) -> Record_0
{
    var b_0 : u32 = u32(12) * g_0;
    var r_0 : Record_0;
    r_0.lo_0 = (bitcast<vec3<f32>>((vec3<u32>(groups_0[b_0], groups_0[b_0 + u32(1)], groups_0[b_0 + u32(2)]))));
    r_0.hi_0 = (bitcast<vec3<f32>>((vec3<u32>(groups_0[b_0 + u32(3)], groups_0[b_0 + u32(4)], groups_0[b_0 + u32(5)]))));
    r_0.axis_0 = (bitcast<vec3<f32>>((vec3<u32>(groups_0[b_0 + u32(6)], groups_0[b_0 + u32(7)], groups_0[b_0 + u32(8)]))));
    r_0.cutoff_0 = (bitcast<f32>((groups_0[b_0 + u32(9)])));
    r_0.first_index_0 = u32(0);
    r_0.index_count_0 = u32(0);
    return r_0;
}

fn outside_0( r_1 : Record_0) -> bool
{
    var i_0 : i32 = i32(0);
    for(;;)
    {
        if(i_0 < i32(6))
        {
        }
        else
        {
            break;
        }
        var p_0 : vec4<f32> = Cull_Uniforms_0.planes_0[i_0];
        var _S1 : f32 = Cull_Uniforms_0.planes_0[i_0].x;
        var _S2 : f32;
        if(_S1 >= 0.0f)
        {
            _S2 = r_1.hi_0.x;
        }
        else
        {
            _S2 = r_1.lo_0.x;
        }
        var _S3 : f32 = p_0.y;
        var _S4 : f32;
        if(_S3 >= 0.0f)
        {
            _S4 = r_1.hi_0.y;
        }
        else
        {
            _S4 = r_1.lo_0.y;
        }
        var _S5 : f32 = p_0.z;
        var _S6 : f32;
        if(_S5 >= 0.0f)
        {
            _S6 = r_1.hi_0.z;
        }
        else
        {
            _S6 = r_1.lo_0.z;
        }
        if((_S1 * _S2 + _S3 * _S4 + _S5 * _S6 + p_0.w) < 0.0f)
        {
            return true;
        }
        i_0 = i_0 + i32(1);
    }
    return false;
}

fn backfacing_0( r_2 : Record_0) -> bool
{
    if((r_2.cutoff_0) >= 1.0f)
    {
        return false;
    }
    var radius_0 : f32 = length(r_2.hi_0 - r_2.lo_0) * 0.5f;
    var to_0 : vec3<f32> = (r_2.lo_0 + r_2.hi_0) * vec3<f32>(0.5f) - Cull_Uniforms_0.eye_0.xyz;
    return (dot(to_0, r_2.axis_0)) >= (r_2.cutoff_0 * (length(to_0) + radius_0) + radius_0);
}

fn group_verdict_0( g_1 : u32) -> u32
{
    var r_3 : Record_0 = group_record_0(g_1);
    if(outside_0(r_3))
    {
        return u32(1);
    }
    if(backfacing_0(r_3))
    {
        return u32(2);
    }
    return u32(0);
}

var<workgroup> verdict_0 : u32;

fn chunk_record_0( c_0 : u32) -> Record_0
{
    var b_1 : u32 = u32(12) * c_0;
    var r_4 : Record_0;
    r_4.lo_0 = (bitcast<vec3<f32>>((vec3<u32>(chunks_0[b_1], chunks_0[b_1 + u32(1)], chunks_0[b_1 + u32(2)]))));
    r_4.hi_0 = (bitcast<vec3<f32>>((vec3<u32>(chunks_0[b_1 + u32(3)], chunks_0[b_1 + u32(4)], chunks_0[b_1 + u32(5)]))));
    r_4.axis_0 = (bitcast<vec3<f32>>((vec3<u32>(chunks_0[b_1 + u32(6)], chunks_0[b_1 + u32(7)], chunks_0[b_1 + u32(8)]))));
    r_4.cutoff_0 = (bitcast<f32>((chunks_0[b_1 + u32(9)])));
    r_4.first_index_0 = chunks_0[b_1 + u32(10)];
    r_4.index_count_0 = chunks_0[b_1 + u32(11)];
    return r_4;
}

fn chunk_verdict_0( c_1 : u32) -> u32
{
    var r_5 : Record_0 = chunk_record_0(c_1);
    if(outside_0(r_5))
    {
        return u32(1);
    }
    if(backfacing_0(r_5))
    {
        return u32(2);
    }
    var _S7 : u32;
    if((r_5.index_count_0) == u32(0))
    {
        _S7 = u32(3);
    }
    else
    {
        _S7 = u32(0);
    }
    return _S7;
}

@compute
@workgroup_size(64, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    var g_2 : u32 = group_id_0.x;
    var i_1 : u32 = local_id_0.x;
    var c_2 : u32 = g_2 * u32(64) + i_1;
    var last_0 : bool = (g_2 + u32(1)) == (Cull_Uniforms_0.counts_0.y);
    var _S8 : vec4<u32> = vec4<u32>(u32(0));
    var k_0 : u32 = i_1;
    var before_0 : vec4<u32> = _S8;
    var all_0 : vec4<u32> = _S8;
    for(;;)
    {
        if(k_0 < (Cull_Uniforms_0.counts_0.y))
        {
        }
        else
        {
            break;
        }
        if(k_0 < g_2)
        {
            before_0 = before_0 + totals_0[k_0];
        }
        if(last_0)
        {
            all_0 = all_0 + totals_0[k_0];
        }
        k_0 = k_0 + u32(64);
    }
    lanes_0[i_1] = before_0;
    workgroupBarrier();
    k_0 = u32(0);
    var start_0 : u32 = u32(0);
    for(;;)
    {
        if(k_0 < u32(64))
        {
        }
        else
        {
            break;
        }
        var start_1 : u32 = start_0 + lanes_0[k_0].x;
        k_0 = k_0 + u32(1);
        start_0 = start_1;
    }
    workgroupBarrier();
    if(last_0)
    {
        lanes_0[i_1] = all_0;
        workgroupBarrier();
        if(i_1 == u32(0))
        {
            k_0 = u32(0);
            var sum_0 : vec4<u32> = _S8;
            for(;;)
            {
                if(k_0 < u32(64))
                {
                }
                else
                {
                    break;
                }
                var sum_1 : vec4<u32> = sum_0 + lanes_0[k_0];
                k_0 = k_0 + u32(1);
                sum_0 = sum_1;
            }
            commands_0[i32(0)] = sum_0.x;
            commands_0[i32(1)] = sum_0.y;
            commands_0[i32(2)] = sum_0.z;
            commands_0[i32(3)] = sum_0.w;
            commands_0[i32(4)] = u32(0);
        }
        workgroupBarrier();
    }
    if((totals_0[g_2].x) == u32(0))
    {
        return;
    }
    if(i_1 == u32(0))
    {
        verdict_0 = group_verdict_0(g_2);
    }
    workgroupBarrier();
    var drawn_0 : bool;
    if(c_2 < (Cull_Uniforms_0.counts_0.x))
    {
        drawn_0 = verdict_0 == u32(0);
    }
    else
    {
        drawn_0 = false;
    }
    if(drawn_0)
    {
        drawn_0 = (chunk_verdict_0(c_2)) == u32(0);
    }
    else
    {
        drawn_0 = false;
    }
    if(drawn_0)
    {
        k_0 = u32(1);
    }
    else
    {
        k_0 = u32(0);
    }
    lanes_0[i_1] = vec4<u32>(k_0, u32(0), u32(0), u32(0));
    workgroupBarrier();
    if(!drawn_0)
    {
        return;
    }
    k_0 = u32(0);
    var slot_0 : u32 = start_0;
    for(;;)
    {
        if(k_0 < i_1)
        {
        }
        else
        {
            break;
        }
        var slot_1 : u32 = slot_0 + lanes_0[k_0].x;
        k_0 = k_0 + u32(1);
        slot_0 = slot_1;
    }
    var r_6 : Record_0 = chunk_record_0(c_2);
    var at_0 : u32 = u32(5) + u32(5) * slot_0;
    commands_0[at_0] = r_6.index_count_0;
    commands_0[at_0 + u32(1)] = u32(1);
    commands_0[at_0 + u32(2)] = r_6.first_index_0;
    commands_0[at_0 + u32(3)] = u32(0);
    if((Cull_Uniforms_0.counts_0.z) != u32(0))
    {
        k_0 = r_6.first_index_0 / u32(3);
    }
    else
    {
        k_0 = u32(0);
    }
    commands_0[at_0 + u32(4)] = k_0;
    return;
}

