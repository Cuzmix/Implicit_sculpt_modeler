// slangc wgsl from dab_area.comp.spv sha256 0af46b4cc0482801f44b6879b6819c9a2aec450ececd918958493746c2976a14
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
    @align(16) alpha_up_0 : vec4<f32>,
    @align(16) slabs_0 : vec4<u32>,
};

@binding(8) @group(0) var<storage, read> dabs_0 : array<Dab_std430_0>;

@binding(6) @group(0) var<storage, read> slabs_1 : array<vec2<u32>>;

@binding(0) @group(1) var<storage, read_write> positions_0 : array<f32>;

@binding(10) @group(0) var<storage, read> normals_0 : array<u32>;

@binding(2) @group(1) var<storage, read_write> partials_0 : array<vec4<f32>>;

fn at_0( v_0 : u32) -> vec3<f32>
{
    var _S1 : u32 = u32(3) * v_0;
    return vec3<f32>(positions_0[_S1], positions_0[_S1 + u32(1)], positions_0[_S1 + u32(2)]);
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

fn normal_at_0( v_1 : u32) -> vec3<f32>
{
    var e_0 : u32 = normals_0[v_1];
    var _S2 : f32 = max(f32((((i32((e_0 << (u32(16)))) >> (u32(16)))) & (i32(-16)))) / 32767.0f, -1.0f);
    var _S3 : f32 = max(f32((((i32(e_0) >> (u32(16)))) & (i32(-16)))) / 32767.0f, -1.0f);
    var _S4 : f32 = 1.0f - abs(_S2);
    var _S5 : f32 = abs(_S3);
    var _S6 : f32 = _S4 - _S5;
    var n_0 : vec3<f32> = vec3<f32>(_S2, _S3, _S6);
    if(_S6 < 0.0f)
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
        n_0[i32(0)] = (1.0f - _S5) * sx_0;
        n_0[i32(1)] = _S4 * sy_0;
    }
    var l_0 : f32 = length(n_0);
    var _S7 : vec3<f32>;
    if(l_0 > 0.0f)
    {
        _S7 = n_0 / vec3<f32>(l_0);
    }
    else
    {
        _S7 = vec3<f32>(0.0f);
    }
    return _S7;
}

var<workgroup> lane_normal_0 : array<vec4<f32>, i32(256)>;

var<workgroup> lane_center_0 : array<vec4<f32>, i32(256)>;

fn slab_vertex_0( _S8 : u32,  _S9 : vec3<u32>,  _S10 : vec3<u32>,  _S11 : ptr<function, u32>,  _S12 : ptr<function, u32>) -> bool
{
    (*_S11) = _S9.y * Params_0.groups_x_0 + _S9.x;
    (*_S12) = u32(0);
    var _S13 : vec4<u32> = dabs_0[_S8].slabs_0;
    if((*_S11) >= (dabs_0[_S8].slabs_0.y))
    {
        return false;
    }
    var slab_0 : vec2<u32> = slabs_1[_S13.x + (*_S11)];
    var _S14 : u32 = _S10.x;
    if(_S14 >= (slab_0.y))
    {
        return false;
    }
    (*_S12) = slab_0.x + _S14;
    return true;
}

@compute
@workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) group_id_0 : vec3<u32>, @builtin(local_invocation_id) local_id_0 : vec3<u32>)
{
    var g_0 : u32;
    var v_2 : u32;
    var _S15 : bool = slab_vertex_0(Params_0.dab_0, group_id_0, local_id_0, &(g_0), &(v_2));
    var _S16 : vec4<f32> = vec4<f32>(0.0f);
    var normal_0 : vec4<f32>;
    var center_0 : vec4<f32>;
    if(_S15)
    {
        var delta_0 : vec3<f32> = at_0(v_2) - dabs_0[Params_0.dab_0].center_r2_0.xyz;
        var _S17 : f32 = dot(delta_0, delta_0) * dabs_0[Params_0.dab_0].tilt1_0.w;
        if(_S17 < 1.0f)
        {
            var w_0 : f32 = falloff_0(_S17);
            var _S18 : vec3<f32> = vec3<f32>(w_0);
            var _S19 : vec4<f32> = vec4<f32>(at_0(v_2) * _S18, 0.0f);
            normal_0 = vec4<f32>(normal_at_0(v_2) * _S18, w_0);
            center_0 = _S19;
        }
        else
        {
            normal_0 = _S16;
            center_0 = _S16;
        }
    }
    else
    {
        normal_0 = _S16;
        center_0 = _S16;
    }
    var _S20 : u32 = local_id_0.x;
    lane_normal_0[_S20] = normal_0;
    lane_center_0[_S20] = center_0;
    workgroupBarrier();
    var _S21 : bool;
    if(_S20 == u32(0))
    {
        _S21 = g_0 < (dabs_0[Params_0.dab_0].slabs_0.y);
    }
    else
    {
        _S21 = false;
    }
    if(_S21)
    {
        var k_0 : u32 = u32(0);
        var n_1 : vec4<f32> = _S16;
        var c_0 : vec4<f32> = _S16;
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
        var _S22 : u32 = dabs_0[Params_0.dab_0].slabs_0.x;
        partials_0[u32(2) * (_S22 + g_0)] = n_1;
        partials_0[u32(2) * (_S22 + g_0) + u32(1)] = c_0;
    }
    return;
}

