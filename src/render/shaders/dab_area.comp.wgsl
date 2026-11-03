// slangc wgsl from dab_area.comp.spv sha256 bb5ec7e3f399c35ec54baadf63df2e43867d08cb436b29baa4912ca2304ef1c9
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

@binding(10) @group(0) var<storage, read> normals_0 : array<u32>;

@binding(2) @group(1) var<storage, read_write> partials_0 : array<vec4<f32>>;

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

fn falloff_0( x2_0 : f32) -> f32
{
    if(x2_0 >= 1.0f)
    {
        return 0.0f;
    }
    var t_0 : f32 = 1.0f - x2_0;
    return t_0 * t_0;
}

fn normal_at_0( v_2 : u32) -> vec3<f32>
{
    var e_0 : u32 = normals_0[v_2];
    var _S4 : f32 = max(f32((((i32((e_0 << (u32(16)))) >> (u32(16)))) & (i32(-16)))) / 32767.0f, -1.0f);
    var _S5 : f32 = max(f32((((i32(e_0) >> (u32(16)))) & (i32(-16)))) / 32767.0f, -1.0f);
    var _S6 : f32 = 1.0f - abs(_S4);
    var _S7 : f32 = abs(_S5);
    var _S8 : f32 = _S6 - _S7;
    var n_0 : vec3<f32> = vec3<f32>(_S4, _S5, _S8);
    if(_S8 < 0.0f)
    {
        var sx_0 : f32;
        if((n_0.x) >= 0.0f)
        {
            sx_0 = 1.0f;
        }
        else
        {
            sx_0 = -1.0f;
        }
        var sy_0 : f32;
        if((n_0.y) >= 0.0f)
        {
            sy_0 = 1.0f;
        }
        else
        {
            sy_0 = -1.0f;
        }
        n_0[i32(0)] = (1.0f - _S7) * sx_0;
        n_0[i32(1)] = _S6 * sy_0;
    }
    var l_0 : f32 = length(n_0);
    var _S9 : vec3<f32>;
    if(l_0 > 0.0f)
    {
        _S9 = n_0 / vec3<f32>(l_0);
    }
    else
    {
        _S9 = vec3<f32>(0.0f);
    }
    return _S9;
}

var<workgroup> lane_normal_0 : array<vec4<f32>, i32(256)>;

var<workgroup> lane_center_0 : array<vec4<f32>, i32(256)>;

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_1 : vec3<u32>, @builtin(local_invocation_id) local_id_1 : vec3<u32>)
{
    var _S10 : Dab_std430_0 = dabs_0[Params_0.dab_0];
    var g_1 : u32;
    var v_3 : u32;
    var _S11 : bool = slab_vertex_0(&(_S10), group_id_1, local_id_1, &(g_1), &(v_3));
    var _S12 : vec4<f32> = vec4<f32>(0.0f);
    var normal_0 : vec4<f32>;
    var center_0 : vec4<f32>;
    if(_S11)
    {
        var delta_0 : vec3<f32> = at_0(v_3) - _S10.center_r2_0.xyz;
        var _S13 : f32 = dot(delta_0, delta_0) * _S10.tilt1_0.w;
        if(_S13 < 1.0f)
        {
            var w_0 : f32 = falloff_0(_S13);
            var _S14 : vec3<f32> = vec3<f32>(w_0);
            var _S15 : vec4<f32> = vec4<f32>(at_0(v_3) * _S14, 0.0f);
            normal_0 = vec4<f32>(normal_at_0(v_3) * _S14, w_0);
            center_0 = _S15;
        }
        else
        {
            normal_0 = _S12;
            center_0 = _S12;
        }
    }
    else
    {
        normal_0 = _S12;
        center_0 = _S12;
    }
    var _S16 : u32 = local_id_1.x;
    lane_normal_0[_S16] = normal_0;
    lane_center_0[_S16] = center_0;
    workgroupBarrier();
    var _S17 : bool;
    if(_S16 == u32(0))
    {
        _S17 = g_1 < (_S10.slabs_0.y);
    }
    else
    {
        _S17 = false;
    }
    if(_S17)
    {
        var k_0 : u32 = u32(0);
        var n_1 : vec4<f32> = _S12;
        var c_0 : vec4<f32> = _S12;
        for(;;)
        {
            if(k_0 < u32(256))
            {
            }
            else
            {
                break;
            }
            var n_2 : vec4<f32> = n_1 + lane_normal_0[k_0];
            var c_1 : vec4<f32> = c_0 + lane_center_0[k_0];
            k_0 = k_0 + u32(1);
            n_1 = n_2;
            c_0 = c_1;
        }
        var _S18 : u32 = _S10.slabs_0.x;
        partials_0[u32(2) * (_S18 + g_1)] = n_1;
        partials_0[u32(2) * (_S18 + g_1) + u32(1)] = c_0;
    }
    return;
}

