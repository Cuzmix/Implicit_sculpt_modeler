// slangc metal from studio_trace_rq.comp.spv sha256 7fe039f4e2f2892d887ce9f23c542abc06e9cde6d8179ba55c69c2794e48300b
// slots s=0:0 rt= wt=1 rb=0,1 wb= u=3 a=2
#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

            raytracing::intersection_params _slang_ray_flags_to_intersection_params(uint flags){
                raytracing::intersection_params params;
                if (flags & 0x01) /* RAY_FLAG_FORCE_OPAQUE */
                    params.force_opacity(raytracing::forced_opacity::opaque);
                if (flags & 0x02) /* RAY_FLAG_FORCE_NON_OPAQUE */
                    params.force_opacity(raytracing::forced_opacity::non_opaque);
                if (flags & 0x10) /* RAY_FLAG_CULL_BACK_FACING_TRIANGLES */
                    params.set_triangle_cull_mode(raytracing::triangle_cull_mode::back);
                if (flags & 0x20) /* RAY_FLAG_CULL_FRONT_FACING_TRIANGLES */
                    params.set_triangle_cull_mode(raytracing::triangle_cull_mode::front);
                if (flags & 0x40) /* RAY_FLAG_CULL_OPAQUE */
                    params.set_opacity_cull_mode(raytracing::opacity_cull_mode::opaque);
                if (flags & 0x80) /* RAY_FLAG_CULL_NON_OPAQUE */
                    params.set_opacity_cull_mode(raytracing::opacity_cull_mode::non_opaque);
                if (flags & 0x100) /* RAY_FLAG_SKIP_TRIANGLES */
                    params.set_geometry_cull_mode(raytracing::geometry_cull_mode::triangle);
                if (flags & 0x200) /* RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES */
                    params.set_geometry_cull_mode(raytracing::geometry_cull_mode::bounding_box);
                return params;
            }
        

                uint _slang_committed_intersection_type_to_uint(raytracing::intersection_type type){
                    switch(type){
                        case raytracing::intersection_type::none:
                            return 0; /* COMMITTED_NOTHING */
                        case raytracing::intersection_type::triangle:
                            return 1; /* COMMITTED_TRIANGLE_HIT */
                        case raytracing::intersection_type::bounding_box:
                            return 2; /* COMMITTED_PROCEDURAL_PRIMITIVE_HIT */
                        default:
                            return 0xFFFFFFFF; // Invalid value to indicate error case, should never be returned by the API
                    }
                }
            

#line 9 "common.slang"
int2 texture_size_0(texture2d<float, access::sample> t_texture_0, sampler t_sampler_0)
{

#line 10
    thread uint w_0;

#line 10
    thread uint h_0;

#line 10
    thread uint levels_0;

#line 10
    (*((&w_0)) = (t_texture_0).get_width((0U))),(*((&h_0)) = (t_texture_0).get_height((0U))),(*((&levels_0)) = (t_texture_0).get_num_mip_levels());

    return int2(int(w_0), int(h_0));
}


#line 54 "studio_trace.comp.slang"
struct SLANG_ParameterGroup_Trace_Uniforms_0
{
    matrix<float,int(4),int(4)>  inv_view_proj_0;
    matrix<float,int(4),int(4)>  to_mesh_0;
    float4 key_base_0;
    float4 key_side_0;
    float4 key_up_0;
    float4 params_0;
    float4 sphere_0;
};


#line 31
struct Instance_natural_0
{
    packed_uint2 indices_0;
    uint runs_0;
    uint pad_0;
};


#line 5423 "hlsl.meta.slang"
struct KernelContext_0
{
    texture2d<float, access::sample> view_depth_texture_0;
    sampler view_depth_sampler_0;
    SLANG_ParameterGroup_Trace_Uniforms_0 constant* Trace_Uniforms_0;
    metal::raytracing::acceleration_structure<metal::raytracing::instancing> scene_0;
    Instance_natural_0 device* instances_0;
    uint device* run_first_0;
    texture2d<float, access::read_write> visible_0;
};


#line 70 "studio_trace.comp.slang"
float3 world_at_0(float2 frag_0, float depth_0, float2 size_0, KernelContext_0 thread* kernelContext_0)
{

#line 71
    float2 uv_0 = frag_0 / size_0;
    float4 w_1 = (((kernelContext_0->Trace_Uniforms_0->inv_view_proj_0) * (float4(uv_0.x * 2.0f - 1.0f, 1.0f - uv_0.y * 2.0f, depth_0, 1.0f))));
    return w_1.xyz / float3(w_1.w) ;
}


#line 176
float2 pixel_hash_0(uint2 v_0)
{

#line 177
    uint2 _S1 = v_0 * uint2(1664525U)  + uint2(1013904223U) ;

#line 176
    thread uint2 _S2 = _S1;

    _S2.x = _S2.x + _S1.y * 1664525U;
    _S2.y = _S2.y + _S2.x * 1664525U;

#line 179
    uint2 _S3 = uint2(16U) ;
    uint2 _S4 = _S2 ^ (_S2 >> _S3);

#line 180
    _S2 = _S4;
    _S2.x = _S2.x + _S4.y * 1664525U;
    _S2.y = _S2.y + _S2.x * 1664525U;
    uint2 _S5 = _S2 ^ (_S2 >> _S3);

#line 183
    _S2 = _S5;
    return float2(_S5 >> (uint2(8U) )) / float2(1.6777216e+07f) ;
}


#line 19687 "hlsl.meta.slang"
struct RayDesc_0
{
    float3 Origin_0;
    float TMin_0;
    float3 Direction_0;
    float TMax_0;
};


#line 80 "studio_trace.comp.slang"
bool occluded_0(float3 o_0, float3 d_0, float tmax_0, KernelContext_0 thread* kernelContext_1)
{

#line 81
    thread RayDesc_0 ray_0;
    (&ray_0)->Origin_0 = o_0;
    (&ray_0)->TMin_0 = 0.0f;
    (&ray_0)->Direction_0 = d_0;
    (&ray_0)->TMax_0 = tmax_0;
    thread raytracing::intersection_query<raytracing::triangle_data, raytracing::instancing> q_0;
    (&q_0)->reset({ (ray_0.Origin_0), (ray_0.Direction_0), (ray_0.TMin_0), (ray_0.TMax_0) }, (kernelContext_1->scene_0), (255U), _slang_ray_flags_to_intersection_params((4U)));
    for(;;)
    {

#line 88
        bool _S6 = ((&q_0)->next());

#line 88
        if(_S6)
        {
        }
        else
        {

#line 88
            break;
        }

#line 89
        uint _S7 = ((&q_0)->get_candidate_user_instance_id());

#line 89
        Instance_natural_0 it_0 = kernelContext_1->instances_0[_S7];
        uint _S8 = ((&q_0)->get_candidate_geometry_id());

#line 90
        uint _S9 = kernelContext_1->run_first_0[it_0.runs_0 + _S8];

#line 90
        uint _S10 = ((&q_0)->get_candidate_primitive_id());

#line 90
        uint2 _S11 = uint2(it_0.indices_0) ;

        uint device* corner_0 = (uint device*)(((ulong(_S11.y) << 32U) | ulong(_S11.x)) + 12ULL * ulong(_S9 + _S10));
        uint device* _S12 = corner_0 + int(0);

#line 93
        uint a_0 = *_S12;

#line 93
        uint device* _S13 = corner_0 + int(1);

#line 93
        uint b_0 = *_S13;

#line 93
        uint c_0 = *(corner_0 + int(2));

#line 93
        bool _S14;
        if((*_S12) != (*_S13))
        {

#line 94
            _S14 = b_0 != c_0;

#line 94
        }
        else
        {

#line 94
            _S14 = false;

#line 94
        }

#line 94
        bool _S15;

#line 94
        if(_S14)
        {

#line 94
            _S15 = a_0 != c_0;

#line 94
        }
        else
        {

#line 94
            _S15 = false;

#line 94
        }

#line 94
        if(_S15)
        {

#line 94
            (&q_0)->commit_triangle_intersection();

#line 94
        }

#line 88
    }

#line 96
    uint _S16 = (_slang_committed_intersection_type_to_uint((&q_0)->get_committed_intersection_type()));

#line 96
    return _S16 == 1U;
}


#line 188
[[kernel]] void main_0(uint3 group_id_0 [[threadgroup_position_in_grid]], uint3 local_id_0 [[thread_position_in_threadgroup]], uint3 global_id_0 [[thread_position_in_grid]], texture2d<float, access::sample> view_depth_texture_1 [[texture(0)]], sampler view_depth_sampler_1 [[sampler(0)]], SLANG_ParameterGroup_Trace_Uniforms_0 constant* Trace_Uniforms_1 [[buffer(3)]], metal::raytracing::acceleration_structure<metal::raytracing::instancing> scene_1 [[buffer(2)]], Instance_natural_0 device* instances_1 [[buffer(0)]], uint device* run_first_1 [[buffer(1)]], texture2d<float, access::read_write> visible_1 [[texture(1)]])
{

#line 188
    thread KernelContext_0 kernelContext_2;

#line 188
    (&kernelContext_2)->view_depth_texture_0 = view_depth_texture_1;

#line 188
    (&kernelContext_2)->view_depth_sampler_0 = view_depth_sampler_1;

#line 188
    (&kernelContext_2)->Trace_Uniforms_0 = Trace_Uniforms_1;

#line 188
    (&kernelContext_2)->scene_0 = scene_1;

#line 188
    (&kernelContext_2)->instances_0 = instances_1;

#line 188
    (&kernelContext_2)->run_first_0 = run_first_1;

#line 188
    (&kernelContext_2)->visible_0 = visible_1;
    float2 _S17 = float2(texture_size_0(view_depth_texture_1, view_depth_sampler_1));
    int2 _S18 = int2(global_id_0.xy);

#line 190
    bool _S19;
    if((_S18.x) >= int(_S17.x))
    {

#line 191
        _S19 = true;

#line 191
    }
    else
    {

#line 191
        _S19 = (_S18.y) >= int(_S17.y);

#line 191
    }

#line 191
    if(_S19)
    {

#line 191
        return;
    }

#line 191
    sampler _S20 = (&kernelContext_2)->view_depth_sampler_0;
    float d_1 = (((&kernelContext_2)->view_depth_texture_0).read(vec<uint,2>(((_S20)).xy), uint(((_S20)).z))).x;
    if(d_1 >= 1.0f)
    {

#line 193
        return;
    }

#line 194
    float2 frag_1 = float2(_S18) + float2(0.5f) ;

#line 194
    float3 _S21 = world_at_0(frag_1, d_1, _S17, &kernelContext_2);


    int2 hi_0 = int2(_S17) - int2(int(1)) ;
    int2 _S22 = int2(int(1), int(0));

#line 198
    int2 _S23 = int2(int(0)) ;

#line 198
    sampler _S24 = (&kernelContext_2)->view_depth_sampler_0;

#line 198
    float dl_0 = (((&kernelContext_2)->view_depth_texture_0).read(vec<uint,2>(((_S24)).xy), uint(((_S24)).z))).x;

#line 198
    sampler _S25 = (&kernelContext_2)->view_depth_sampler_0;
    float dr_0 = (((&kernelContext_2)->view_depth_texture_0).read(vec<uint,2>(((_S25)).xy), uint(((_S25)).z))).x;
    int2 _S26 = int2(int(0), int(1));

#line 200
    sampler _S27 = (&kernelContext_2)->view_depth_sampler_0;

#line 200
    float du_0 = (((&kernelContext_2)->view_depth_texture_0).read(vec<uint,2>(((_S27)).xy), uint(((_S27)).z))).x;

#line 200
    sampler _S28 = (&kernelContext_2)->view_depth_sampler_0;
    float dd_0 = (((&kernelContext_2)->view_depth_texture_0).read(vec<uint,2>(((_S28)).xy), uint(((_S28)).z))).x;

#line 201
    float3 px_r_0;
    if((abs(dr_0 - d_1)) < (abs(d_1 - dl_0)))
    {

#line 202
        float3 _S29 = world_at_0(frag_1 + float2(1.0f, 0.0f), dr_0, _S17, &kernelContext_2);

#line 202
        px_r_0 = _S29 - _S21;

#line 202
    }
    else
    {

#line 202
        float3 _S30 = world_at_0(frag_1 - float2(1.0f, 0.0f), dl_0, _S17, &kernelContext_2);

#line 202
        px_r_0 = _S21 - _S30;

#line 202
    }

#line 202
    float3 px_d_0;
    if((abs(dd_0 - d_1)) < (abs(d_1 - du_0)))
    {

#line 203
        float3 _S31 = world_at_0(frag_1 + float2(0.0f, 1.0f), dd_0, _S17, &kernelContext_2);

#line 203
        px_d_0 = _S31 - _S21;

#line 203
    }
    else
    {

#line 203
        float3 _S32 = world_at_0(frag_1 - float2(0.0f, 1.0f), du_0, _S17, &kernelContext_2);

#line 203
        px_d_0 = _S21 - _S32;

#line 203
    }
    float3 n_0 = normalize(cross(px_d_0, px_r_0));

#line 204
    float3 _S33 = world_at_0(frag_1, 0.0f, _S17, &kernelContext_2);
    float3 toward_eye_0 = normalize(_S33 - _S21);

#line 205
    float3 n_1;
    if((dot(n_0, toward_eye_0)) < 0.0f)
    {

#line 206
        n_1 = - n_0;

#line 206
    }
    else
    {

#line 206
        n_1 = n_0;

#line 206
    }

    uint2 _S34 = uint2(_S18);

#line 208
    float2 r2_0 = fract((&kernelContext_2)->Trace_Uniforms_0->params_0.xy + pixel_hash_0(_S34));



    float _S35 = (as_type<float>((2139095040U)));
    if(((&kernelContext_2)->Trace_Uniforms_0->key_base_0.w) > 0.5f)
    {

#line 213
        _S19 = ((&kernelContext_2)->Trace_Uniforms_0->params_0.w) > 0.5f;

#line 213
    }
    else
    {

#line 213
        _S19 = false;

#line 213
    }

#line 213
    float3 dir_0;

#line 213
    float tmax_1;

#line 213
    if(_S19)
    {


        float3 to_0 = (&kernelContext_2)->Trace_Uniforms_0->sphere_0.xyz - _S21;
        float d2_0 = dot(to_0, to_0);

#line 218
        float r_0 = (&kernelContext_2)->Trace_Uniforms_0->sphere_0.w;
        float _S36 = r_0 * r_0;

#line 219
        if(d2_0 <= _S36)
        {

#line 219
            return;
        }

#line 220
        float3 axis_0 = to_0 * float3(rsqrt(d2_0)) ;
        if((abs(axis_0.y)) < 0.99000000953674316f)
        {

#line 221
            px_r_0 = float3(0.0f, 1.0f, 0.0f);

#line 221
        }
        else
        {

#line 221
            px_r_0 = float3(1.0f, 0.0f, 0.0f);

#line 221
        }

#line 221
        float3 side_0 = normalize(cross(axis_0, px_r_0));

        float a_1 = 6.28318548202514648f * r2_0.y;
        float3 dir_1 = to_0 + (side_0 * float3(cos(a_1))  + cross(side_0, axis_0) * float3(sin(a_1)) ) * float3((r_0 * sqrt(d2_0 / (d2_0 - _S36)) * sqrt(r2_0.x))) ;
        if((dot(n_1, dir_1)) <= 0.0f)
        {

#line 225
            return;
        }

#line 225
        tmax_1 = 1.0f;

#line 225
        dir_0 = dir_1;

#line 213
    }
    else
    {

#line 227
        if(((&kernelContext_2)->Trace_Uniforms_0->key_base_0.w) > 0.5f)
        {

#line 228
            float a_2 = 6.28318548202514648f * r2_0.y;
            float3 dir_2 = normalize((&kernelContext_2)->Trace_Uniforms_0->key_base_0.xyz + ((&kernelContext_2)->Trace_Uniforms_0->key_side_0.xyz * float3(cos(a_2))  + (&kernelContext_2)->Trace_Uniforms_0->key_up_0.xyz * float3(sin(a_2)) ) * float3(((&kernelContext_2)->Trace_Uniforms_0->key_side_0.w * sqrt(r2_0.x))) );


            if((dot(n_1, dir_2)) <= 0.0f)
            {

#line 232
                return;
            }

#line 232
            dir_0 = dir_2;

#line 227
        }
        else
        {

#line 235
            float _S37 = n_1.z;

#line 235
            if(_S37 >= 0.0f)
            {

#line 235
                tmax_1 = 1.0f;

#line 235
            }
            else
            {

#line 235
                tmax_1 = -1.0f;

#line 235
            }
            float a_3 = -1.0f / (tmax_1 + _S37);
            float _S38 = n_1.x;

#line 237
            float _S39 = n_1.y;

#line 237
            float b_1 = _S38 * _S39 * a_3;


            float _S40 = r2_0.x;

#line 240
            float r_1 = sqrt(_S40);

#line 240
            float phi_0 = 6.28318548202514648f * r2_0.y;

#line 240
            dir_0 = normalize(float3(1.0f + tmax_1 * _S38 * _S38 * a_3, tmax_1 * b_1, - tmax_1 * _S38) * float3((r_1 * cos(phi_0)))  + float3(b_1, tmax_1 + _S39 * _S39 * a_3, - _S39) * float3((r_1 * sin(phi_0)))  + n_1 * float3(sqrt(max(1.0f - _S40, 0.0f))) );

#line 227
        }

#line 227
        tmax_1 = _S35;

#line 213
    }

#line 213
    float3 _S41 = world_at_0(frag_1 + float2(1.0f, 0.0f), d_1, _S17, &kernelContext_2);

#line 250
    float3 o_1 = _S21 + (n_1 + toward_eye_0) * float3(((&kernelContext_2)->Trace_Uniforms_0->params_0.z + min(2.0f * length(_S41 - _S21), 100.0f * (&kernelContext_2)->Trace_Uniforms_0->params_0.z))) ;


    if(tmax_1 == 1.0f)
    {

#line 253
        dir_0 = _S21 + dir_0 - o_1;

#line 253
    }

#line 253
    bool _S42 = occluded_0(o_1, dir_0, tmax_1, &kernelContext_2);

    if(_S42)
    {

#line 255
        (&kernelContext_2)->visible_0.write(float4(0.0f) ,_S34);

#line 255
    }

#line 261
    return;
}

