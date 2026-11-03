// slangc wgsl from blas_refit.comp.spv sha256 7025cc138e90d09c7dd4b21a01acbb9d43b161987c35280d807d1d29878bedda
diagnostic(off, derivative_uniformity);
struct SLANG_ParameterGroup_Params_std140_0
{
    @align(16) chunk_count_0 : u32,
    @align(4) groups_x_0 : u32,
};

@binding(0) @group(2) var<uniform> Params_0 : SLANG_ParameterGroup_Params_std140_0;
@binding(6) @group(0) var<storage, read> chunks_0 : array<vec4<u32>>;

struct Node_std430_0
{
    @align(16) lo_0 : vec3<f32>,
    @align(4) first_0 : u32,
    @align(16) hi_0 : vec3<f32>,
    @align(4) count_0 : u32,
};

@binding(0) @group(1) var<storage, read_write> nodes_0 : array<Node_std430_0>;

@binding(4) @group(0) var<storage, read> order_0 : array<u32>;

@binding(2) @group(0) var<storage, read> indices_0 : array<u32>;

@binding(0) @group(0) var<storage, read> positions_0 : array<f32>;

fn at_0( v_0 : u32) -> vec3<f32>
{
    var _S1 : u32 = u32(3) * v_0;
    return vec3<f32>(positions_0[_S1], positions_0[_S1 + u32(1)], positions_0[_S1 + u32(2)]);
}

@compute
@workgroup_size(64, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>, @builtin(global_invocation_id) global_id_0 : vec3<u32>)
{
    var c_0 : u32 = (group_id_0.y * Params_0.groups_x_0 + group_id_0.x) * u32(64) + local_id_0.x;
    if(c_0 >= (Params_0.chunk_count_0))
    {
        return;
    }
    var ch_0 : vec4<u32> = chunks_0[c_0];
    var _S2 : u32 = ch_0.x;
    var k_0 : u32 = ch_0.w;
    for(;;)
    {
        if(k_0 > u32(0))
        {
        }
        else
        {
            break;
        }
        var i_0 : u32 = _S2 + k_0 - u32(1);
        var n_0 : Node_std430_0 = nodes_0[i_0];
        var _S3 : vec3<f32> = vec3<f32>(3.00000000549775576e+38f);
        var _S4 : vec3<f32> = vec3<f32>(-3.00000000549775576e+38f);
        var lo_1 : vec3<f32>;
        var hi_1 : vec3<f32>;
        if((nodes_0[i_0].count_0) == u32(0))
        {
            var _S5 : u32 = _S2 + n_0.first_0;
            var _S6 : vec3<f32> = max(nodes_0[_S5].hi_0, nodes_0[_S5 + u32(1)].hi_0);
            lo_1 = min(nodes_0[_S5].lo_0, nodes_0[_S5 + u32(1)].lo_0);
            hi_1 = _S6;
        }
        else
        {
            lo_1 = _S3;
            hi_1 = _S4;
            var j_0 : u32 = n_0.first_0;
            for(;;)
            {
                if(j_0 < (n_0.first_0 + n_0.count_0))
                {
                }
                else
                {
                    break;
                }
                var at_order_0 : u32 = ch_0.y + j_0;
                var word_0 : u32 = order_0[(at_order_0 >> (u32(1)))];
                var _S7 : u32 = ch_0.z;
                var _S8 : u32;
                if(((at_order_0 & (u32(1)))) == u32(0))
                {
                    _S8 = (word_0 & (u32(65535)));
                }
                else
                {
                    _S8 = (word_0 >> (u32(16)));
                }
                var _S9 : u32 = u32(3) * (_S7 + _S8);
                var a_0 : u32 = indices_0[_S9];
                var b_0 : u32 = indices_0[_S9 + u32(1)];
                var d_0 : u32 = indices_0[_S9 + u32(2)];
                var _S10 : bool;
                if(a_0 == b_0)
                {
                    _S10 = true;
                }
                else
                {
                    _S10 = b_0 == d_0;
                }
                var _S11 : bool;
                if(_S10)
                {
                    _S11 = true;
                }
                else
                {
                    _S11 = a_0 == d_0;
                }
                if(_S11)
                {
                    j_0 = j_0 + u32(1);
                    continue;
                }
                var p0_0 : vec3<f32> = at_0(a_0);
                var p1_0 : vec3<f32> = at_0(b_0);
                var p2_0 : vec3<f32> = at_0(d_0);
                var _S12 : vec3<f32> = max(hi_1, max(p0_0, max(p1_0, p2_0)));
                lo_1 = min(lo_1, min(p0_0, min(p1_0, p2_0)));
                hi_1 = _S12;
                j_0 = j_0 + u32(1);
            }
        }
        nodes_0[i_0].lo_0 = lo_1;
        nodes_0[i_0].hi_0 = hi_1;
        k_0 = k_0 - u32(1);
    }
    return;
}

