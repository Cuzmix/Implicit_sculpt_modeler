// slangc wgsl from dab_reduce.comp.spv sha256 8ad3a07de6e07fbcba1e2c518001c3b95cb158151062bb52d760ca358db60365
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

@binding(2) @group(1) var<storage, read_write> partials_0 : array<vec4<f32>>;

@binding(4) @group(1) var<storage, read_write> areas_0 : array<vec4<f32>>;

var<workgroup> lane_normal_0 : array<vec4<f32>, i32(256)>;

var<workgroup> lane_center_0 : array<vec4<f32>, i32(256)>;

fn normalize0_0( v_0 : vec3<f32>) -> vec3<f32>
{
    var l_0 : f32 = length(v_0);
    var _S1 : vec3<f32>;
    if(l_0 > 0.0f)
    {
        _S1 = v_0 / vec3<f32>(l_0);
    }
    else
    {
        _S1 = vec3<f32>(0.0f);
    }
    return _S1;
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    var _S2 : vec4<u32>;
    var d_0 : Dab_std430_0 = dabs_0[Params_0.dab_0];
    var _S3 : vec4<f32> = vec4<f32>(0.0f);
    var _S4 : u32 = local_id_0.x;
    var k_0 : u32 = _S4;
    var n_0 : vec4<f32> = _S3;
    var c_0 : vec4<f32> = _S3;
    for(;;)
    {
        _S2 = d_0.slabs_0;
        if(k_0 < (d_0.slabs_0.y))
        {
        }
        else
        {
            break;
        }
        var _S5 : u32 = u32(2) * (d_0.slabs_0.x + k_0);
        var n_1 : vec4<f32> = n_0 + partials_0[_S5];
        var c_1 : vec4<f32> = c_0 + partials_0[_S5 + u32(1)];
        k_0 = k_0 + u32(256);
        n_0 = n_1;
        c_0 = c_1;
    }
    lane_normal_0[_S4] = n_0;
    lane_center_0[_S4] = c_0;
    workgroupBarrier();
    if(_S4 != u32(0))
    {
        return;
    }
    k_0 = u32(0);
    var sum_n_0 : vec4<f32> = _S3;
    var sum_c_0 : vec4<f32> = _S3;
    for(;;)
    {
        if(k_0 < u32(256))
        {
        }
        else
        {
            break;
        }
        var sum_n_1 : vec4<f32> = sum_n_0 + lane_normal_0[k_0];
        var sum_c_1 : vec4<f32> = sum_c_0 + lane_center_0[k_0];
        k_0 = k_0 + u32(1);
        sum_n_0 = sum_n_1;
        sum_c_0 = sum_c_1;
    }
    var normal_0 : vec3<f32> = normalize0_0(sum_n_0.xyz);
    var _S6 : f32 = sum_n_0.w;
    var plane_0 : vec3<f32>;
    if(_S6 > 0.0f)
    {
        plane_0 = sum_c_0.xyz / vec3<f32>(_S6);
    }
    else
    {
        plane_0 = vec3<f32>(0.0f);
    }
    var normal_1 : vec3<f32>;
    if((((_S2.w) & (u32(8)))) != u32(0))
    {
        normal_1 = normalize0_0((((normal_0) * (mat3x3<f32>(d_0.tilt0_0.xyz, d_0.tilt1_0.xyz, d_0.tilt2_0.xyz)))));
    }
    else
    {
        normal_1 = normal_0;
    }
    var plane_1 : vec3<f32> = plane_0 + normal_1 * vec3<f32>(d_0.tilt2_0.w);
    areas_0[u32(2) * Params_0.dab_0] = vec4<f32>(normal_1, 0.0f);
    areas_0[u32(2) * Params_0.dab_0 + u32(1)] = vec4<f32>(plane_1, 0.0f);
    return;
}

