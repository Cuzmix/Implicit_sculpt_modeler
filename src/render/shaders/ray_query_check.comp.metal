// slangc metal from ray_query_check.comp.spv sha256 fe0652b4a07d5eb132524facd8b48c185074b8cc3914ddf3ff72d27829c3ac77
// slots s= rt= wt= rb=0 wb=1 u=2 a=3
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
        

                uint _slang_candidate_intersection_type_to_uint(raytracing::intersection_type type){
                    switch(type){
                        case raytracing::intersection_type::triangle:
                            return 0; /* CANDIDATE_NON_OPAQUE_TRIANGLE */
                        case raytracing::intersection_type::bounding_box:
                            return 1; /* CANDIDATE_PROCEDURAL_PRIMITIVE */
                        default:
                            return 0xFFFFFFFF; // Invalid value to indicate error case, should never be returned by the API
                    }
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
            

#line 11 "ray_query_check.comp.slang"
struct SLANG_ParameterGroup_Params_0
{
    uint ray_count_0;
};


#line 10
struct KernelContext_0
{
    SLANG_ParameterGroup_Params_0 constant* Params_0;
    packed_float4 device* rays_0;
    metal::raytracing::acceleration_structure<metal::raytracing::instancing> scene_0;
    packed_float4 device* hits_0;
};


#line 19687 "hlsl.meta.slang"
struct RayDesc_0
{
    float3 Origin_0;
    float TMin_0;
    float3 Direction_0;
    float TMax_0;
};


#line 17 "ray_query_check.comp.slang"
[[kernel]] void main_0(uint3 id_0 [[thread_position_in_grid]], SLANG_ParameterGroup_Params_0 constant* Params_1 [[buffer(2)]], packed_float4 device* rays_1 [[buffer(0)]], metal::raytracing::acceleration_structure<metal::raytracing::instancing> scene_1 [[buffer(3)]], packed_float4 device* hits_1 [[buffer(1)]])
{

#line 17
    thread KernelContext_0 kernelContext_0;

#line 17
    (&kernelContext_0)->Params_0 = Params_1;

#line 17
    (&kernelContext_0)->rays_0 = rays_1;

#line 17
    (&kernelContext_0)->scene_0 = scene_1;

#line 17
    (&kernelContext_0)->hits_0 = hits_1;
    uint _S1 = id_0.x;

#line 18
    if(_S1 >= (Params_1->ray_count_0))
    {

#line 18
        return;
    }

#line 19
    thread RayDesc_0 ray_0;
    uint _S2 = 2U * _S1;

#line 20
    (&ray_0)->Origin_0 = (float4(*((&kernelContext_0)->rays_0+_S2)) ).xyz;
    uint _S3 = _S2 + 1U;

#line 21
    (&ray_0)->Direction_0 = (float4(*((&kernelContext_0)->rays_0+_S3)) ).xyz;
    (&ray_0)->TMin_0 = 0.0f;
    (&ray_0)->TMax_0 = 1.00000001504746622e+30f;
    thread raytracing::intersection_query<raytracing::triangle_data, raytracing::instancing> q_0;
    (&q_0)->reset({ (ray_0.Origin_0), (ray_0.Direction_0), (ray_0.TMin_0), (ray_0.TMax_0) }, ((&kernelContext_0)->scene_0), (255U), _slang_ray_flags_to_intersection_params((0U)));

    for(;;)
    {

#line 27
        bool _S4 = ((&q_0)->next());

#line 27
        if(_S4)
        {
        }
        else
        {

#line 27
            break;
        }

#line 28
        uint _S5 = (
                        _slang_candidate_intersection_type_to_uint((&q_0)->get_candidate_intersection_type())
                    );

#line 28
        if(_S5 == 0U)
        {

#line 28
            (&q_0)->commit_triangle_intersection();

#line 28
        }

#line 27
    }


    float4 _S6 = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    float4 _S7 = float4(0.0f, 0.0f, 0.0f, 0.0f);
    uint _S8 = (_slang_committed_intersection_type_to_uint((&q_0)->get_committed_intersection_type()));

#line 32
    float4 hit_0;

#line 32
    float4 bary_0;

#line 32
    if(_S8 == 1U)
    {

#line 33
        float _S9 = ((&q_0)->get_committed_distance());

#line 33
        uint _S10 = ((&q_0)->get_committed_user_instance_id());

#line 33
        float _S11 = float(_S10);

#line 33
        uint _S12 = ((&q_0)->get_committed_primitive_id());

#line 33
        float _S13 = float(_S12);

#line 33
        uint _S14 = ((&q_0)->get_committed_geometry_id());

#line 33
        float4 _S15 = float4(_S9, _S11, _S13, float(_S14));
        float2 _S16 = ((&q_0)->get_committed_triangle_barycentric_coord());

#line 34
        float4 _S17 = float4(_S16, 0.0f, 0.0f);

#line 34
        hit_0 = _S15;

#line 34
        bary_0 = _S17;

#line 32
    }
    else
    {

#line 32
        hit_0 = _S6;

#line 32
        bary_0 = _S7;

#line 32
    }

#line 32
    *((&kernelContext_0)->hits_0+_S2) = packed_float4(hit_0) ;

#line 32
    *((&kernelContext_0)->hits_0+_S3) = packed_float4(bary_0) ;

#line 38
    return;
}

