// slangc metal from render_trace_rq.comp.spv sha256 906064d7080ef47f54f00ce02378494749ceed94565670e635a4dfc1d2d047ac
// slots s=0:0,1:1,2:2,3:3,4:4,5:5,6:6,7:7,8:8,9:9,10:10,11:11,12:12,13:13 rt= wt=14,15,16 rb=1,2,3,4,5,6,7,8 wb= u=9 a=0
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


#line 135 "render_trace.slang"
struct SLANG_ParameterGroup_Render_Uniforms_0
{
    matrix<float,int(4),int(4)>  inv_view_proj_0;
    array<float4, int(8)> light_pos_0;
    array<float4, int(8)> light_color_0;
    array<float4, int(8)> light_spot_0;
    array<float4, int(8)> light_shape_0;
    array<float4, int(8)> light_size_0;
    float4 rig_x_0;
    float4 rig_y_0;
    float4 rig_z_0;
    array<float4, int(8)> light_extra_0;
    float4 env_x_0;
    float4 env_y_0;
    float4 env_z_0;
    float4 env_0;
    float4 scene_0;
    uint4 counts_0;
    uint4 extra_0;
    float4 lens_eye_0;
    float4 lens_right_0;
    float4 lens_up_0;
    float4 lens_fwd_0;
};


#line 120
struct _MatrixStorage_float4x4natural_0
{
    array<packed_float4, int(4)> data_0;
};


#line 120
struct _Array_natural_vectorx3Cuintx2C4x3E4_0
{
    array<packed_uint4, int(4)> data_1;
};


#line 120
struct _Array_natural_vectorx3Cfloatx2C4x3E16_0
{
    array<packed_float4, int(16)> data_2;
};


#line 120
struct Item_natural_0
{
    _MatrixStorage_float4x4natural_0 model_0;
    _MatrixStorage_float4x4natural_0 inv_model_0;
    packed_float4 color_0;
    packed_float4 surface_0;
    packed_uint4 offs_0;
    _Array_natural_vectorx3Cuintx2C4x3E4_0 slot_group_0;
    _Array_natural_vectorx3Cfloatx2C4x3E16_0 slot_color_0;
    _Array_natural_vectorx3Cfloatx2C4x3E16_0 slot_surface_0;
    packed_uint4 tex_0;
};


#line 189
struct KernelContext_0
{
    texture2d<float, access::sample> prev_texture_0;
    sampler prev_sampler_0;
    SLANG_ParameterGroup_Render_Uniforms_0 constant* Render_Uniforms_0;
    metal::raytracing::acceleration_structure<metal::raytracing::instancing> structure_0;
    Item_natural_0 device* items_0;
    uint device* order_0;
    uint device* indices_0;
    texture2d<float, access::sample> environment_map_texture_0;
    sampler environment_map_sampler_0;
    texture2d<float, access::sample> env_table_texture_0;
    sampler env_table_sampler_0;
    float device* positions_0;
    uint device* attributes_0;
    uint device* textured_0;
    texture2d<float, access::sample> map0_texture_0;
    sampler map0_sampler_0;
    texture2d<float, access::sample> map1_texture_0;
    sampler map1_sampler_0;
    texture2d<float, access::sample> map2_texture_0;
    sampler map2_sampler_0;
    texture2d<float, access::sample> map3_texture_0;
    sampler map3_sampler_0;
    texture2d<float, access::sample> map4_texture_0;
    sampler map4_sampler_0;
    texture2d<float, access::sample> map5_texture_0;
    sampler map5_sampler_0;
    texture2d<float, access::sample> map6_texture_0;
    sampler map6_sampler_0;
    texture2d<float, access::sample> map7_texture_0;
    sampler map7_sampler_0;
    texture2d<float, access::sample> map8_texture_0;
    sampler map8_sampler_0;
    texture2d<float, access::read_write> next_0;
    texture2d<float, access::sample> prev_albedo_texture_0;
    sampler prev_albedo_sampler_0;
    texture2d<float, access::sample> prev_normal_texture_0;
    sampler prev_normal_sampler_0;
    texture2d<float, access::read_write> guide_albedo_0;
    texture2d<float, access::read_write> guide_normal_0;
    uint rng_0;
};


#line 191
uint pcg_next_0(KernelContext_0 thread* kernelContext_0)
{

#line 192
    uint s_0 = kernelContext_0->rng_0;
    kernelContext_0->rng_0 = kernelContext_0->rng_0 * 747796405U + 2891336453U;
    uint w_1 = ((s_0 >> ((s_0 >> 28U) + 4U)) ^ s_0) * 277803737U;
    return (w_1 >> 22U) ^ w_1;
}


#line 191
uint pcg_next_1(KernelContext_0 thread* kernelContext_1)
{

#line 192
    uint s_1 = kernelContext_1->rng_0;
    kernelContext_1->rng_0 = kernelContext_1->rng_0 * 747796405U + 2891336453U;
    uint w_2 = ((s_1 >> ((s_1 >> 28U) + 4U)) ^ s_1) * 277803737U;
    return (w_2 >> 22U) ^ w_2;
}

float rnd_0(KernelContext_0 thread* kernelContext_2)
{

#line 198
    uint _S1 = pcg_next_1(kernelContext_2);
    return float(_S1 >> 8U) / 1.6777216e+07f;
}


#line 326
uint merged_triangle_0(uint item_0, uint geometry_0, uint primitive_0, KernelContext_0 thread* kernelContext_3)
{

#line 327
    return kernelContext_3->order_0[(uint4((kernelContext_3->items_0+item_0)->offs_0) ).z + geometry_0] + primitive_0;
}


#line 316
struct Hit_0
{
    float t_0;
    uint tri_0;
    uint item_1;
    float2 uv_0;
};


#line 19687 "hlsl.meta.slang"
struct RayDesc_0
{
    float3 Origin_0;
    float TMin_0;
    float3 Direction_0;
    float TMax_0;
};


#line 335 "render_trace.slang"
bool trace_0(float3 o_0, float3 d_0, float t_max_0, bool any_0, Hit_0 thread* hit_0, KernelContext_0 thread* kernelContext_4)
{

#line 336
    hit_0->t_0 = t_max_0;
    hit_0->tri_0 = 0U;
    hit_0->item_1 = 0U;
    hit_0->uv_0 = float2(0.0f) ;
    if((kernelContext_4->Render_Uniforms_0->extra_0.y) != 0U)
    {

#line 340
        return false;
    }

#line 341
    thread RayDesc_0 ray_0;
    (&ray_0)->Origin_0 = o_0;
    (&ray_0)->TMin_0 = 0.0f;
    (&ray_0)->Direction_0 = d_0;
    (&ray_0)->TMax_0 = t_max_0;
    thread raytracing::intersection_query<raytracing::triangle_data, raytracing::instancing> q_0;

#line 346
    uint _S2;
    if(any_0)
    {

#line 347
        _S2 = 4U;

#line 347
    }
    else
    {

#line 347
        _S2 = 0U;

#line 347
    }

#line 347
    (&q_0)->reset({ (ray_0.Origin_0), (ray_0.Direction_0), (ray_0.TMin_0), (ray_0.TMax_0) }, (kernelContext_4->structure_0), (255U), _slang_ray_flags_to_intersection_params((_S2 | 0U)));
    for(;;)
    {

#line 348
        bool _S3 = ((&q_0)->next());

#line 348
        if(_S3)
        {
        }
        else
        {

#line 348
            break;
        }

#line 349
        uint _S4 = ((&q_0)->get_candidate_user_instance_id());

#line 349
        uint _S5 = ((&q_0)->get_candidate_geometry_id());

#line 349
        uint _S6 = ((&q_0)->get_candidate_primitive_id());

#line 349
        uint _S7 = merged_triangle_0(_S4, _S5, _S6, kernelContext_4);
        uint _S8 = 3U * _S7;

#line 350
        uint ia_0 = kernelContext_4->indices_0[_S8];

#line 350
        uint ib_0 = kernelContext_4->indices_0[_S8 + 1U];

#line 350
        uint ic_0 = kernelContext_4->indices_0[_S8 + 2U];

#line 350
        bool _S9;
        if(ia_0 != ib_0)
        {

#line 351
            _S9 = ib_0 != ic_0;

#line 351
        }
        else
        {

#line 351
            _S9 = false;

#line 351
        }

#line 351
        bool _S10;

#line 351
        if(_S9)
        {

#line 351
            _S10 = ia_0 != ic_0;

#line 351
        }
        else
        {

#line 351
            _S10 = false;

#line 351
        }

#line 351
        if(_S10)
        {

#line 351
            (&q_0)->commit_triangle_intersection();

#line 351
        }

#line 348
    }

#line 353
    uint _S11 = (_slang_committed_intersection_type_to_uint((&q_0)->get_committed_intersection_type()));

#line 353
    if(_S11 != 1U)
    {

#line 353
        return false;
    }

#line 354
    float _S12 = ((&q_0)->get_committed_distance());

#line 354
    hit_0->t_0 = _S12;
    uint _S13 = ((&q_0)->get_committed_user_instance_id());

#line 355
    hit_0->item_1 = _S13;
    uint _S14 = ((&q_0)->get_committed_geometry_id());

#line 356
    uint _S15 = ((&q_0)->get_committed_primitive_id());

#line 356
    uint _S16 = merged_triangle_0(_S13, _S14, _S15, kernelContext_4);

#line 356
    hit_0->tri_0 = _S16;
    float2 _S17 = ((&q_0)->get_committed_triangle_barycentric_coord());

#line 357
    hit_0->uv_0 = _S17;
    return true;
}


#line 545
bool light_nee_only_0(int i_0, KernelContext_0 thread* kernelContext_5)
{

#line 545
    bool _S18;
    if((kernelContext_5->Render_Uniforms_0->light_extra_0[i_0].y) > 0.5f)
    {

#line 546
        _S18 = true;

#line 546
    }
    else
    {

#line 546
        _S18 = (kernelContext_5->Render_Uniforms_0->light_extra_0[i_0].x) != 0.0f;

#line 546
    }

#line 546
    return _S18;
}


#line 591
float cone_pdf_0(float cos_max_0)
{

#line 592
    return 1.0f / (6.28318548202514648f * max(1.0f - cos_max_0, 1.00000001168609742e-07f));
}


#line 602
float sphere_hit_0(float3 o_1, float3 d_1, float3 c_0, float r_0)
{

#line 603
    float3 oc_0 = o_1 - c_0;
    float b_0 = dot(oc_0, d_1);

    float disc_0 = b_0 * b_0 - (dot(oc_0, oc_0) - r_0 * r_0);
    if(disc_0 < 0.0f)
    {

#line 607
        return -1.0f;
    }

#line 608
    float s_2 = sqrt(disc_0);
    float _S19 = - b_0;

#line 609
    float t_1 = _S19 - s_2;

#line 609
    float t_2;
    if(t_1 < 0.0f)
    {

#line 610
        t_2 = _S19 + s_2;

#line 610
    }
    else
    {

#line 610
        t_2 = t_1;

#line 610
    }
    return t_2;
}



float sphere_cone_0(int i_1, float3 p_0, KernelContext_0 thread* kernelContext_6)
{

#line 617
    float3 d_2 = kernelContext_6->Render_Uniforms_0->light_pos_0[i_1].xyz - p_0;
    float d2_0 = dot(d_2, d_2);

#line 618
    float r_1 = kernelContext_6->Render_Uniforms_0->light_size_0[i_1].x;
    float _S20 = r_1 * r_1;

#line 619
    if(d2_0 <= _S20)
    {

#line 619
        return 2.0f;
    }

#line 620
    return sqrt(1.0f - _S20 / d2_0);
}


#line 7 "light_window.slang"
float light_window_0(float4 pos_0, float4 shape_0, float4 spot_0, float d2_1, float3 l_0)
{
    float _S21 = shape_0.y;

#line 9
    float k_0;

#line 9
    if(_S21 > 0.0f)
    {

#line 10
        float x_0 = d2_1 / (_S21 * _S21);
        float w_3 = clamp(1.0f - x_0 * x_0, 0.0f, 1.0f);

#line 11
        k_0 = w_3 * w_3;

#line 9
    }
    else
    {

#line 9
        k_0 = 1.0f;

#line 9
    }

#line 14
    float _S22 = pos_0.w;

#line 14
    if(_S22 > 2.5f)
    {

#line 14
        k_0 = k_0 * max(dot(- l_0, spot_0.xyz), 0.0f);

#line 14
    }
    else
    {

#line 16
        if(_S22 > 1.5f)
        {

#line 16
            k_0 = k_0 * smoothstep(spot_0.w, shape_0.z, dot(- l_0, spot_0.xyz));

#line 16
        }

#line 14
    }

#line 19
    return k_0;
}


#line 597 "render_trace.slang"
float light_falloff_0(int i_2, float d2_2, float3 l_1, KernelContext_0 thread* kernelContext_7)
{

#line 598
    return light_window_0(kernelContext_7->Render_Uniforms_0->light_pos_0[i_2], kernelContext_7->Render_Uniforms_0->light_shape_0[i_2], kernelContext_7->Render_Uniforms_0->light_spot_0[i_2], d2_2, l_1);
}


#line 623
float power_weight_0(float a_0, float b_1)
{

#line 624
    float _S23 = a_0 * a_0;

#line 624
    return _S23 / max(_S23 + b_1 * b_1, 1.00000000317107685e-30f);
}


#line 728
float3 lights_met_0(float3 o_2, float3 d_3, float t_hit_0, bool escaped_0, float pdf_bsdf_0, KernelContext_0 thread* kernelContext_8)
{

#line 729
    float3 _S24 = float3(0.0f) ;

#line 729
    int i_3 = int(0);

#line 729
    float3 sum_0 = _S24;
    for(;;)
    {

#line 730
        if(i_3 < int(8))
        {
        }
        else
        {

#line 730
            break;
        }

#line 730
        bool _S25;
        if((kernelContext_8->Render_Uniforms_0->light_size_0[i_3].w) <= 0.0f)
        {

#line 731
            _S25 = true;

#line 731
        }
        else
        {

#line 731
            bool _S26 = light_nee_only_0(i_3, kernelContext_8);

#line 731
            _S25 = _S26;

#line 731
        }

#line 731
        if(_S25)
        {

#line 731
            i_3 = i_3 + int(1);

#line 730
            continue;
        }
        float3 radiance_0 = kernelContext_8->Render_Uniforms_0->light_color_0[i_3].xyz * float3(kernelContext_8->Render_Uniforms_0->light_size_0[i_3].y) ;

#line 732
        float3 radiance_1;

#line 732
        bool _S27;

#line 732
        float pdf_dir_0;

        if((kernelContext_8->Render_Uniforms_0->light_pos_0[i_3].w) < 0.5f)
        {

#line 735
            if(!escaped_0)
            {

#line 735
                _S27 = true;

#line 735
            }
            else
            {

#line 735
                _S27 = (dot(d_3, kernelContext_8->Render_Uniforms_0->light_pos_0[i_3].xyz)) < (kernelContext_8->Render_Uniforms_0->light_size_0[i_3].x);

#line 735
            }

#line 735
            if(_S27)
            {

#line 735
                i_3 = i_3 + int(1);

#line 730
                continue;
            }

#line 730
            pdf_dir_0 = cone_pdf_0(kernelContext_8->Render_Uniforms_0->light_size_0[i_3].x);

#line 730
            radiance_1 = radiance_0;



        }
        else
        {

            float t_3 = sphere_hit_0(o_2, d_3, kernelContext_8->Render_Uniforms_0->light_pos_0[i_3].xyz, kernelContext_8->Render_Uniforms_0->light_size_0[i_3].x);

#line 738
            float _S28 = sphere_cone_0(i_3, o_2, kernelContext_8);

            if(t_3 <= 0.0f)
            {

#line 740
                _S27 = true;

#line 740
            }
            else
            {

#line 740
                _S27 = t_3 >= t_hit_0;

#line 740
            }

#line 740
            bool _S29;

#line 740
            if(_S27)
            {

#line 740
                _S29 = true;

#line 740
            }
            else
            {

#line 740
                _S29 = _S28 > 1.0f;

#line 740
            }

#line 740
            if(_S29)
            {

#line 740
                i_3 = i_3 + int(1);

#line 730
                continue;
            }

#line 741
            float3 to_0 = kernelContext_8->Render_Uniforms_0->light_pos_0[i_3].xyz - o_2;

#line 741
            float _S30 = light_falloff_0(i_3, dot(to_0, to_0), normalize(to_0), kernelContext_8);
            float3 radiance_2 = radiance_0 * float3(_S30) ;

#line 742
            pdf_dir_0 = cone_pdf_0(_S28);

#line 742
            radiance_1 = radiance_2;

#line 734
        }

#line 734
        sum_0 = sum_0 + radiance_1 * float3(power_weight_0(pdf_bsdf_0, kernelContext_8->Render_Uniforms_0->light_size_0[i_3].w * pdf_dir_0)) ;

#line 730
        i_3 = i_3 + int(1);

#line 730
    }

#line 747
    return sum_0;
}


#line 8 "panorama.slang"
float2 panorama_uv_0(float3 d_4)
{

    return float2(atan2(d_4.x, - d_4.z - 9.99999968265522539e-21f) * 0.15915493667125702f + 0.5f, acos(clamp(d_4.y, -1.0f, 1.0f)) * 0.31830990314483643f);
}


#line 22 "studio_env.slang"
float3 lobe_0(float3 dir_0, float3 toward_0, float3 color_1, float sharp_0, float rough_0)
{

#line 23
    float e_0 = mix(sharp_0, 3.0f, sqrt(rough_0));
    return color_1 * float3(pow(max(dot(dir_0, toward_0), 0.0f), e_0))  * float3((e_0 + 2.0f))  / float3((sharp_0 + 2.0f)) ;
}

float3 studio_0(float3 dir_1, float rough_1)
{

#line 28
    float w_4 = 0.07999999821186066f + 0.89999997615814209f * rough_1;
    float _S31 = dir_1.y;

#line 36
    return mix(float3(0.07000000029802322f, 0.06499999761581421f, 0.05999999865889549f), float3(0.40000000596046448f, 0.43000000715255737f, 0.47999998927116394f), float3(smoothstep(- w_4, w_4, _S31)) ) + float3(0.12999999523162842f, 0.11999999731779099f, 0.10999999940395355f) * float3(exp(- abs(_S31) / (0.05999999865889549f + 0.5f * rough_1)))  + lobe_0(dir_1, float3(-0.65590423345565796f, 0.7433580756187439f, 0.13118083775043488f), float3(4.0f, 3.79999995231628418f, 3.5f), 300.0f, rough_1) + lobe_0(dir_1, float3(0.84478187561035156f, 0.32852628827095032f, -0.42239093780517578f), float3(1.60000002384185791f, 1.79999995231628418f, 2.09999990463256836f), 600.0f, rough_1) + lobe_0(dir_1, float3(0.09396819770336151f, -0.32888868451118469f, 0.93968194723129272f), float3(0.5f, 0.5f, 0.5f), 4.0f, rough_1);
}


#line 629 "render_trace.slang"
float3 environment_0(float3 d_5, KernelContext_0 thread* kernelContext_9)
{

#line 630
    if((kernelContext_9->Render_Uniforms_0->env_0.x) > 0.5f)
    {
        return ((kernelContext_9->environment_map_texture_0).sample((kernelContext_9->environment_map_sampler_0), (panorama_uv_0((((transpose(matrix<float,int(3),int(3)> (kernelContext_9->Render_Uniforms_0->env_x_0.xyz, kernelContext_9->Render_Uniforms_0->env_y_0.xyz, kernelContext_9->Render_Uniforms_0->env_z_0.xyz))) * (d_5))))), level((0.0f)))).xyz * float3(kernelContext_9->Render_Uniforms_0->env_0.y) ;
    }

    return studio_0((((transpose(matrix<float,int(3),int(3)> (kernelContext_9->Render_Uniforms_0->rig_x_0.xyz, kernelContext_9->Render_Uniforms_0->rig_y_0.xyz, kernelContext_9->Render_Uniforms_0->rig_z_0.xyz))) * (d_5))), 0.25f) * float3((0.69999998807907104f * kernelContext_9->Render_Uniforms_0->rig_x_0.w)) ;
}


matrix<float,int(3),int(3)>  env_frame_0(KernelContext_0 thread* kernelContext_10)
{

#line 639
    matrix<float,int(3),int(3)>  _S32;
    if((kernelContext_10->Render_Uniforms_0->env_0.x) > 0.5f)
    {

#line 640
        _S32 = matrix<float,int(3),int(3)> (kernelContext_10->Render_Uniforms_0->env_x_0.xyz, kernelContext_10->Render_Uniforms_0->env_y_0.xyz, kernelContext_10->Render_Uniforms_0->env_z_0.xyz);

#line 640
    }
    else
    {

#line 640
        _S32 = matrix<float,int(3),int(3)> (kernelContext_10->Render_Uniforms_0->rig_x_0.xyz, kernelContext_10->Render_Uniforms_0->rig_y_0.xyz, kernelContext_10->Render_Uniforms_0->rig_z_0.xyz);

#line 640
    }

#line 640
    return _S32;
}


#line 661
float env_pdf_0(float3 d_6, KernelContext_0 thread* kernelContext_11)
{

#line 661
    matrix<float,int(3),int(3)>  _S33 = env_frame_0(kernelContext_11);
    float3 local_0 = (((transpose(_S33)) * (d_6)));

#line 662
    int2 _S34 = texture_size_0(kernelContext_11->env_table_texture_0, kernelContext_11->env_table_sampler_0);

#line 662
    sampler _S35 = kernelContext_11->env_table_sampler_0;


    float _S36 = local_0.y;

#line 665
    return ((kernelContext_11->env_table_texture_0).read(vec<uint,2>(((_S35)).xy), uint(((_S35)).z))).z / max(sqrt(max(1.0f - _S36 * _S36, 0.0f)), 0.00009999999747379f);
}


#line 202
float3 vertex_0(uint v_0, KernelContext_0 thread* kernelContext_12)
{

#line 203
    uint _S37 = 3U * v_0;

#line 203
    return float3(kernelContext_12->positions_0[_S37], kernelContext_12->positions_0[_S37 + 1U], kernelContext_12->positions_0[_S37 + 2U]);
}

float3 oct_decode_0(float2 e_1)
{

#line 207
    float _S38 = e_1.x;

#line 207
    float _S39 = e_1.y;

#line 207
    float3 _S40 = float3(e_1, 1.0f - abs(_S38) - abs(_S39));

#line 207
    thread float3 v_1 = _S40;
    if((_S40.z) < 0.0f)
    {

#line 208
        float2 _S41 = float2(1.0f)  - abs(e_1.yx);

#line 208
        float _S42;

#line 208
        if(_S38 >= 0.0f)
        {

#line 208
            _S42 = 1.0f;

#line 208
        }
        else
        {

#line 208
            _S42 = -1.0f;

#line 208
        }

#line 208
        float _S43;

#line 208
        if(_S39 >= 0.0f)
        {

#line 208
            _S43 = 1.0f;

#line 208
        }
        else
        {

#line 208
            _S43 = -1.0f;

#line 208
        }

#line 208
        v_1.xy = _S41 * float2(_S42, _S43);

#line 208
    }
    return normalize(v_1);
}



float3 normal_decode_0(uint w_5)
{
    return oct_decode_0(float2(int2(int(w_5 << 16U) >> 16U, int(w_5) >> 16U) & (int2(int(-16)) )) / float2(32767.0f) );
}


float3 vertex_normal_0(uint v_2, KernelContext_0 thread* kernelContext_13)
{

#line 221
    return normal_decode_0(kernelContext_13->attributes_0[v_2]);
}


#line 283
uint2 vertex_paint_0(uint v_3, KernelContext_0 thread* kernelContext_14)
{

#line 284
    uint at_0 = kernelContext_14->Render_Uniforms_0->counts_0.w + 2U * v_3;
    return uint2(kernelContext_14->attributes_0[at_0], kernelContext_14->attributes_0[at_0 + 1U]);
}

float3 srgb_decode_0(float3 c_1)
{

#line 289
    return mix(c_1 / float3(12.92000007629394531f) , pow((c_1 + float3(0.05499999970197678f) ) / float3(1.0549999475479126f) , float3(2.40000009536743164f) ), step(float3(0.04044999927282333f) , c_1));
}


float3 group_color_0(uint g_0)
{

#line 293
    float3 _S44 = float3(3.0f) ;

    float3 _S45 = float3(1.0f) ;

#line 295
    float3 rgb_0 = clamp(abs(fract(float3(fract(float(g_0) * 0.6180340051651001f + 0.11999999731779099f))  + float3(0.0f, 2.0f, 1.0f) / _S44) * float3(6.0f)  - _S44) - float3(1.0f) , float3(0.0f) , _S45);

#line 295
    float light_0;
    if((g_0 & 1U) == 0U)
    {

#line 296
        light_0 = 0.75f;

#line 296
    }
    else
    {

#line 296
        light_0 = 0.55000001192092896f;

#line 296
    }
    return mix(_S45, rgb_0, float3(0.55000001192092896f) ) * float3(light_0) ;
}


#line 226
struct Tex_Vertex_0
{
    float3 n_0;
    float4 t_4;
    float2 uv_1;
};


#line 232
Tex_Vertex_0 tex_vertex_0(uint at_1, KernelContext_0 thread* kernelContext_15)
{

#line 233
    thread Tex_Vertex_0 v_4;
    (&v_4)->n_0 = normal_decode_0(kernelContext_15->textured_0[at_1 + 3U]);
    uint a_1 = kernelContext_15->textured_0[at_1 + 4U];

#line 235
    uint b_2 = kernelContext_15->textured_0[at_1 + 5U];
    (&v_4)->t_4 = max(float4(float(int(a_1 << 16U) >> 16U), float(int(a_1) >> 16U), float(int(b_2 << 16U) >> 16U), float(int(b_2) >> 16U)) / float4(32767.0f) , float4(-1.0f) );
    (&v_4)->uv_1 = float2((as_type<float>((kernelContext_15->textured_0[at_1 + 6U]))), (as_type<float>((kernelContext_15->textured_0[at_1 + 7U]))));
    return v_4;
}


#line 252
float4 map_at_0(uint slot_0, uint kind_0, float2 uv_2, float lod_0, KernelContext_0 thread* kernelContext_16)
{

#line 253
    switch(slot_0 * 3U + kind_0)
    {
    case 0U:
        {

#line 246
            float2 _S46 = float2(texture_size_0(kernelContext_16->map0_texture_0, kernelContext_16->map0_sampler_0));

#line 246
            return ((kernelContext_16->map0_texture_0).sample((kernelContext_16->map0_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S46.x * _S46.y), 0.0f)))));
        }
    case 1U:
        {

#line 246
            float2 _S47 = float2(texture_size_0(kernelContext_16->map1_texture_0, kernelContext_16->map1_sampler_0));

#line 246
            return ((kernelContext_16->map1_texture_0).sample((kernelContext_16->map1_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S47.x * _S47.y), 0.0f)))));
        }
    case 2U:
        {

#line 246
            float2 _S48 = float2(texture_size_0(kernelContext_16->map2_texture_0, kernelContext_16->map2_sampler_0));

#line 246
            return ((kernelContext_16->map2_texture_0).sample((kernelContext_16->map2_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S48.x * _S48.y), 0.0f)))));
        }
    case 3U:
        {

#line 246
            float2 _S49 = float2(texture_size_0(kernelContext_16->map3_texture_0, kernelContext_16->map3_sampler_0));

#line 246
            return ((kernelContext_16->map3_texture_0).sample((kernelContext_16->map3_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S49.x * _S49.y), 0.0f)))));
        }
    case 4U:
        {

#line 246
            float2 _S50 = float2(texture_size_0(kernelContext_16->map4_texture_0, kernelContext_16->map4_sampler_0));

#line 246
            return ((kernelContext_16->map4_texture_0).sample((kernelContext_16->map4_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S50.x * _S50.y), 0.0f)))));
        }
    case 5U:
        {

#line 246
            float2 _S51 = float2(texture_size_0(kernelContext_16->map5_texture_0, kernelContext_16->map5_sampler_0));

#line 246
            return ((kernelContext_16->map5_texture_0).sample((kernelContext_16->map5_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S51.x * _S51.y), 0.0f)))));
        }
    case 6U:
        {

#line 246
            float2 _S52 = float2(texture_size_0(kernelContext_16->map6_texture_0, kernelContext_16->map6_sampler_0));

#line 246
            return ((kernelContext_16->map6_texture_0).sample((kernelContext_16->map6_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S52.x * _S52.y), 0.0f)))));
        }
    case 7U:
        {

#line 246
            float2 _S53 = float2(texture_size_0(kernelContext_16->map7_texture_0, kernelContext_16->map7_sampler_0));

#line 246
            return ((kernelContext_16->map7_texture_0).sample((kernelContext_16->map7_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S53.x * _S53.y), 0.0f)))));
        }
    case 8U:
        {

#line 246
            float2 _S54 = float2(texture_size_0(kernelContext_16->map8_texture_0, kernelContext_16->map8_sampler_0));

#line 246
            return ((kernelContext_16->map8_texture_0).sample((kernelContext_16->map8_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S54.x * _S54.y), 0.0f)))));
        }
    }

#line 264
    return float4(0.0f) ;
}


#line 4 "common.slang"
float glsl_mod_0(float x_1, float y_0)
{

#line 5
    return x_1 - y_0 * floor(x_1 / y_0);
}


#line 271 "render_trace.slang"
float3 uv_checker_0(float2 uv_3)
{

#line 272
    float2 c_2 = uv_3 * float2(8.0f) ;
    float2 f_0 = fract(c_2);
    float _S55 = f_0.x;

#line 274
    float _S56 = f_0.y;
    float2 cell_0 = floor(c_2);
    float _S57 = cell_0.x;

#line 276
    float _S58 = cell_0.y;

#line 276
    float3 _S59 = float3(3.0f) ;

    float3 _S60 = float3(1.0f) ;

    return mix(_S60, clamp(abs(fract(float3(((_S57 + 0.5f) / 8.0f))  + float3(0.0f, 2.0f, 1.0f) / _S59) * float3(6.0f)  - _S59) - float3(1.0f) , float3(0.0f) , _S60), float3(0.34999999403953552f) ) * float3(mix(0.69999998807907104f, 1.0f, (_S58 + 0.5f) / 8.0f))  * float3(mix(1.0f, 0.72000002861022949f, glsl_mod_0(_S57 + _S58, 2.0f)))  * float3((1.0f - 0.5f * step(min(min(_S55, 1.0f - _S55), min(_S56, 1.0f - _S56)), 0.01499999966472387f))) ;
}


#line 15 "panorama.slang"
float3 panorama_dir_0(float2 uv_4)
{

#line 16
    float theta_0 = uv_4.y * 3.14159274101257324f;
    float phi_0 = (uv_4.x - 0.5f) * 6.28318548202514648f;
    float s_3 = sin(theta_0);
    return float3(sin(phi_0) * s_3, cos(theta_0), - cos(phi_0) * s_3);
}


#line 644 "render_trace.slang"
float3 env_sample_0(float thread* pdf_0, KernelContext_0 thread* kernelContext_17)
{

#line 644
    int2 _S61 = texture_size_0(kernelContext_17->env_table_texture_0, kernelContext_17->env_table_sampler_0);

    int _S62 = _S61.x;

#line 646
    int count_0 = _S62 * _S61.y;

#line 646
    float _S63 = rnd_0(kernelContext_17);
    float u_0 = _S63 * float(count_0);
    int _S64 = min(int(u_0), count_0 - int(1));
    int _S65 = _S64 % _S62;

#line 649
    int _S66 = _S64 / _S62;

#line 649
    sampler _S67 = kernelContext_17->env_table_sampler_0;

#line 649
    float4 _S68 = ((kernelContext_17->env_table_texture_0).read(vec<uint,2>(((_S67)).xy), uint(((_S67)).z)));

#line 649
    int i_4;

#line 649
    float4 e_2;
    if((fract(u_0)) >= (_S68.x))
    {

#line 651
        int i_5 = int(_S68.y);
        int _S69 = i_5 % _S62;

#line 652
        int _S70 = i_5 / _S62;

#line 652
        sampler _S71 = kernelContext_17->env_table_sampler_0;

#line 652
        float4 _S72 = ((kernelContext_17->env_table_texture_0).read(vec<uint,2>(((_S71)).xy), uint(((_S71)).z)));

#line 652
        i_4 = i_5;

#line 652
        e_2 = _S72;

#line 650
    }
    else
    {

#line 650
        i_4 = _S64;

#line 650
        e_2 = _S68;

#line 650
    }



    int _S73 = i_4 % _S62;

#line 654
    float _S74 = float(_S73);

#line 654
    int _S75 = i_4 / _S62;

#line 654
    float2 _S76 = float2(_S74, float(_S75));

#line 654
    float _S77 = rnd_0(kernelContext_17);

#line 654
    float _S78 = rnd_0(kernelContext_17);
    float3 local_1 = panorama_dir_0((_S76 + float2(_S77, _S78)) / float2(_S61));
    float _S79 = local_1.y;

#line 656
    *pdf_0 = e_2.z / max(sqrt(max(1.0f - _S79 * _S79, 0.0f)), 0.00009999999747379f);

#line 656
    matrix<float,int(3),int(3)>  _S80 = env_frame_0(kernelContext_17);
    return (((_S80) * (local_1)));
}


#line 499
float ggx_d_0(float n_dot_h_0, float a_2)
{

#line 500
    float a2_0 = a_2 * a_2;
    float d_7 = n_dot_h_0 * n_dot_h_0 * (a2_0 - 1.0f) + 1.0f;
    return a2_0 / (3.14159274101257324f * d_7 * d_7);
}


float ggx_lambda_0(float c_3, float a_3)
{

#line 507
    float _S81 = max(c_3 * c_3, 9.99999993922529029e-09f);
    return 0.5f * (-1.0f + sqrt(1.0f + a_3 * a_3 * (1.0f - _S81) / _S81));
}


#line 495
float3 fresnel_0(float3 f0_0, float c_4)
{

#line 496
    return f0_0 + (float3(1.0f)  - f0_0) * float3(pow(1.0f - clamp(c_4, 0.0f, 1.0f), 5.0f)) ;
}


#line 485
float luminance_0(float3 c_5)
{

#line 486
    return dot(c_5, float3(0.2125999927520752f, 0.71520000696182251f, 0.07220000028610229f));
}

struct Surface_0
{
    float3 diffuse_0;
    float3 f0_1;
    float a_4;
};


#line 513
float specular_chance_0(const Surface_0 thread* s_4, float n_dot_v_0)
{

#line 514
    float3 fv_0 = fresnel_0(s_4->f0_1, n_dot_v_0);
    float es_0 = luminance_0(fv_0);

#line 515
    float ed_0 = luminance_0(s_4->diffuse_0 * (float3(1.0f)  - fv_0));
    if(ed_0 <= 0.0f)
    {

#line 516
        return 1.0f;
    }

#line 517
    return clamp(es_0 / max(es_0 + ed_0, 9.99999997475242708e-07f), 0.05000000074505806f, 0.94999998807907104f);
}




float3 bsdf_eval_0(const Surface_0 thread* s_5, float3 n_1, float3 v_5, float3 l_2, float thread* pdf_1, float shine_0)
{

#line 524
    *pdf_1 = 0.0f;
    float n_dot_l_0 = dot(n_1, l_2);

#line 525
    float n_dot_v_1 = dot(n_1, v_5);

#line 525
    bool _S82;
    if(n_dot_l_0 <= 0.0f)
    {

#line 526
        _S82 = true;

#line 526
    }
    else
    {

#line 526
        _S82 = n_dot_v_1 <= 0.0f;

#line 526
    }

#line 526
    if(_S82)
    {

#line 526
        return float3(0.0f) ;
    }

#line 527
    float3 h_1 = normalize(v_5 + l_2);

    float D_0 = ggx_d_0(max(dot(n_1, h_1), 0.0f), s_5->a_4);


    float _S83 = 1.0f + ggx_lambda_0(n_dot_v_1, s_5->a_4);

#line 532
    float3 spec_0 = fresnel_0(s_5->f0_1, max(dot(v_5, h_1), 0.0f)) * float3((D_0 / ((_S83 + ggx_lambda_0(n_dot_l_0, s_5->a_4)) * 4.0f * n_dot_v_1 * n_dot_l_0))) ;
    float3 diff_0 = s_5->diffuse_0 * (float3(1.0f)  - fresnel_0(s_5->f0_1, n_dot_v_1)) / float3(3.14159274101257324f) ;

#line 533
    float _S84 = specular_chance_0(s_5, n_dot_v_1);



    *pdf_1 = _S84 * (D_0 / (_S83 * 4.0f * n_dot_v_1)) + (1.0f - _S84) * n_dot_l_0 / 3.14159274101257324f;
    return (diff_0 + spec_0 * float3(shine_0) ) * float3(n_dot_l_0) ;
}


#line 461
float3 offset_ray_0(float3 p_1, float3 n_2)
{


    int3 _S85 = int3(float3(256.0f)  * n_2);

    float _S86 = p_1.x;

#line 467
    int _S87 = (as_type<int>((_S86)));

#line 467
    int _S88;

#line 467
    if(_S86 < 0.0f)
    {

#line 467
        _S88 = - _S85.x;

#line 467
    }
    else
    {

#line 467
        _S88 = _S85.x;

#line 467
    }

#line 467
    float _S89 = (as_type<float>((_S87 + _S88)));
    float _S90 = p_1.y;

#line 468
    int _S91 = (as_type<int>((_S90)));

#line 468
    if(_S90 < 0.0f)
    {

#line 468
        _S88 = - _S85.y;

#line 468
    }
    else
    {

#line 468
        _S88 = _S85.y;

#line 468
    }

#line 468
    float _S92 = (as_type<float>((_S91 + _S88)));
    float _S93 = p_1.z;

#line 469
    int _S94 = (as_type<int>((_S93)));

#line 469
    if(_S93 < 0.0f)
    {

#line 469
        _S88 = - _S85.z;

#line 469
    }
    else
    {

#line 469
        _S88 = _S85.z;

#line 469
    }

#line 469
    float _S95 = (as_type<float>((_S94 + _S88)));

#line 469
    float _S96;

    if((abs(_S86)) < 0.03125f)
    {

#line 471
        _S96 = _S86 + 0.0000152587890625f * n_2.x;

#line 471
    }
    else
    {

#line 471
        _S96 = _S89;

#line 471
    }

#line 471
    float _S97;
    if((abs(_S90)) < 0.03125f)
    {

#line 472
        _S97 = _S90 + 0.0000152587890625f * n_2.y;

#line 472
    }
    else
    {

#line 472
        _S97 = _S92;

#line 472
    }

#line 472
    float _S98;
    if((abs(_S93)) < 0.03125f)
    {

#line 473
        _S98 = _S93 + 0.0000152587890625f * n_2.z;

#line 473
    }
    else
    {

#line 473
        _S98 = _S95;

#line 473
    }

#line 470
    return float3(_S96, _S97, _S98);
}


#line 477
void basis_0(float3 n_3, float3 thread* t_5, float3 thread* b_3)
{

#line 478
    float _S99 = n_3.z;

#line 478
    float s_6;

#line 478
    if(_S99 >= 0.0f)
    {

#line 478
        s_6 = 1.0f;

#line 478
    }
    else
    {

#line 478
        s_6 = -1.0f;

#line 478
    }
    float a_5 = -1.0f / (s_6 + _S99);
    float _S100 = n_3.x;

#line 480
    float _S101 = n_3.y;

#line 480
    float c_6 = _S100 * _S101 * a_5;
    *t_5 = float3(1.0f + s_6 * _S100 * _S100 * a_5, s_6 * c_6, - s_6 * _S100);
    *b_3 = float3(c_6, s_6 + _S101 * _S101 * a_5, - _S101);
    return;
}


#line 583
float3 sample_cone_0(float3 axis_0, float cos_max_1, KernelContext_0 thread* kernelContext_18)
{

#line 584
    thread float3 t_6;

#line 584
    thread float3 b_4;
    basis_0(axis_0, &t_6, &b_4);

#line 585
    float _S102 = rnd_0(kernelContext_18);
    float c_7 = 1.0f - _S102 * (1.0f - cos_max_1);
    float s_7 = sqrt(max(1.0f - c_7 * c_7, 0.0f));

#line 587
    float _S103 = rnd_0(kernelContext_18);

#line 587
    float phi_1 = 6.28318548202514648f * _S103;
    return normalize(t_6 * float3((s_7 * cos(phi_1)))  + b_4 * float3((s_7 * sin(phi_1)))  + axis_0 * float3(c_7) );
}


#line 671
float3 direct_light_0(const Surface_0 thread* s_8, float3 p_2, float3 ng_0, float3 n_4, float3 v_6, KernelContext_0 thread* kernelContext_19)
{

#line 671
    int i_6;

#line 671
    float _S104 = rnd_0(kernelContext_19);

#line 671
    bool _S105;

    if(_S104 < (kernelContext_19->Render_Uniforms_0->env_0.z))
    {

#line 674
        thread float pdf_env_0;

#line 674
        float3 _S106 = env_sample_0(&pdf_env_0, kernelContext_19);

        if((dot(ng_0, _S106)) <= 0.0f)
        {

#line 676
            return float3(0.0f) ;
        }

#line 677
        thread float pdf_bsdf_1;

#line 677
        float3 _S107 = bsdf_eval_0(s_8, n_4, v_6, _S106, &pdf_bsdf_1, 1.0f);

        if((luminance_0(_S107)) <= 0.0f)
        {

#line 679
            return float3(0.0f) ;
        }

#line 679
        float3 _S108 = environment_0(_S106, kernelContext_19);

        float pdf_light_0 = kernelContext_19->Render_Uniforms_0->env_0.z * pdf_env_0;
        if((luminance_0(_S108)) <= 0.0f)
        {

#line 682
            _S105 = true;

#line 682
        }
        else
        {

#line 682
            _S105 = pdf_light_0 <= 0.0f;

#line 682
        }

#line 682
        if(_S105)
        {

#line 682
            return float3(0.0f) ;
        }

#line 683
        thread Hit_0 shadow_0;

#line 683
        bool _S109 = trace_0(offset_ray_0(p_2, ng_0), _S106, 3.00000000549775576e+38f, true, &shadow_0, kernelContext_19);
        if(_S109)
        {

#line 684
            return float3(0.0f) ;
        }

#line 685
        return _S107 * _S108 * float3((power_weight_0(pdf_light_0, pdf_bsdf_1) / pdf_light_0)) ;
    }

#line 685
    int k_1 = int(0);


    for(;;)
    {

#line 688
        if(k_1 < int(8))
        {
        }
        else
        {

#line 688
            i_6 = int(-1);

#line 688
            break;
        }

#line 689
        if((kernelContext_19->Render_Uniforms_0->light_size_0[k_1].w) > 0.0f)
        {

#line 689
            _S105 = _S104 < (kernelContext_19->Render_Uniforms_0->light_size_0[k_1].z);

#line 689
        }
        else
        {

#line 689
            _S105 = false;

#line 689
        }

#line 689
        if(_S105)
        {

#line 689
            i_6 = k_1;

            break;
        }

#line 688
        k_1 = k_1 + int(1);

#line 688
    }

#line 694
    if(i_6 < int(0))
    {

#line 694
        return float3(0.0f) ;
    }

    float3 radiance_3 = kernelContext_19->Render_Uniforms_0->light_color_0[i_6].xyz * float3(kernelContext_19->Render_Uniforms_0->light_size_0[i_6].y) ;

#line 697
    float3 l_3;

#line 697
    float3 radiance_4;

#line 697
    float pdf_dir_1;

#line 697
    float dist_0;
    if((kernelContext_19->Render_Uniforms_0->light_pos_0[i_6].w) < 0.5f)
    {

#line 698
        float3 _S110 = sample_cone_0(kernelContext_19->Render_Uniforms_0->light_pos_0[i_6].xyz, kernelContext_19->Render_Uniforms_0->light_size_0[i_6].x, kernelContext_19);

        float _S111 = cone_pdf_0(kernelContext_19->Render_Uniforms_0->light_size_0[i_6].x);

#line 700
        l_3 = _S110;

#line 700
        pdf_dir_1 = _S111;

#line 700
        dist_0 = 3.00000000549775576e+38f;

#line 700
        radiance_4 = radiance_3;

#line 698
    }
    else
    {

#line 698
        float _S112 = sphere_cone_0(i_6, p_2, kernelContext_19);

#line 703
        if(_S112 > 1.0f)
        {

#line 703
            return float3(0.0f) ;
        }

#line 704
        float3 to_1 = kernelContext_19->Render_Uniforms_0->light_pos_0[i_6].xyz - p_2;
        float3 _S113 = normalize(to_1);

#line 705
        float3 _S114 = sample_cone_0(_S113, _S112, kernelContext_19);
        float _S115 = cone_pdf_0(_S112);
        float dist_1 = sphere_hit_0(p_2, _S114, kernelContext_19->Render_Uniforms_0->light_pos_0[i_6].xyz, kernelContext_19->Render_Uniforms_0->light_size_0[i_6].x);
        if(dist_1 <= 0.0f)
        {

#line 708
            return float3(0.0f) ;
        }

#line 708
        float _S116 = light_falloff_0(i_6, dot(to_1, to_1), _S113, kernelContext_19);
        float3 radiance_5 = radiance_3 * float3(_S116) ;

#line 709
        l_3 = _S114;

#line 709
        pdf_dir_1 = _S115;

#line 709
        dist_0 = dist_1;

#line 709
        radiance_4 = radiance_5;

#line 698
    }

#line 711
    if((dot(ng_0, l_3)) <= 0.0f)
    {

#line 711
        _S105 = true;

#line 711
    }
    else
    {

#line 711
        _S105 = (luminance_0(radiance_4)) <= 0.0f;

#line 711
    }

#line 711
    if(_S105)
    {

#line 711
        return float3(0.0f) ;
    }

#line 712
    thread float pdf_bsdf_2;

#line 712
    float3 _S117 = bsdf_eval_0(s_8, n_4, v_6, l_3, &pdf_bsdf_2, 1.0f + kernelContext_19->Render_Uniforms_0->light_extra_0[i_6].x);

    if((luminance_0(_S117)) <= 0.0f)
    {

#line 714
        return float3(0.0f) ;
    }

#line 715
    float pdf_light_1 = kernelContext_19->Render_Uniforms_0->light_size_0[i_6].w * pdf_dir_1;

#line 715
    bool _S118 = light_nee_only_0(i_6, kernelContext_19);
    if(_S118)
    {

#line 717
        thread Hit_0 blocked_0;
        if((kernelContext_19->Render_Uniforms_0->light_extra_0[i_6].y) < 0.5f)
        {

#line 718
            bool _S119 = trace_0(offset_ray_0(p_2, ng_0), l_3, dist_0, true, &blocked_0, kernelContext_19);

#line 718
            _S105 = _S119;

#line 718
        }
        else
        {

#line 718
            _S105 = false;

#line 718
        }

#line 718
        if(_S105)
        {

#line 718
            return float3(0.0f) ;
        }

#line 719
        return _S117 * (radiance_4 / float3(pdf_light_1) );
    }
    thread Hit_0 shadow_1;

#line 721
    bool _S120 = trace_0(offset_ray_0(p_2, ng_0), l_3, dist_0, true, &shadow_1, kernelContext_19);
    if(_S120)
    {

#line 722
        return float3(0.0f) ;
    }

#line 723
    return _S117 * radiance_4 * float3((power_weight_0(pdf_light_1, pdf_bsdf_2) / pdf_light_1)) ;
}


#line 550
float3 sample_vndf_0(float3 ve_0, float a_6, float2 u_1)
{

#line 551
    float3 vh_0 = normalize(float3(a_6 * ve_0.x, a_6 * ve_0.y, ve_0.z));
    float _S121 = vh_0.x;

#line 552
    float _S122 = vh_0.y;

#line 552
    float lensq_0 = _S121 * _S121 + _S122 * _S122;

#line 552
    float3 t1_0;
    if(lensq_0 > 0.0f)
    {

#line 553
        t1_0 = float3(- _S122, _S121, 0.0f) * float3(rsqrt(lensq_0)) ;

#line 553
    }
    else
    {

#line 553
        t1_0 = float3(1.0f, 0.0f, 0.0f);

#line 553
    }

    float r_2 = sqrt(u_1.x);

#line 555
    float phi_2 = 6.28318548202514648f * u_1.y;
    float p1_0 = r_2 * cos(phi_2);
    float s_9 = 0.5f * (1.0f + vh_0.z);
    float _S123 = 1.0f - p1_0 * p1_0;

#line 558
    float p2_0 = (1.0f - s_9) * sqrt(max(_S123, 0.0f)) + s_9 * (r_2 * sin(phi_2));
    float3 nh_0 = float3(p1_0)  * t1_0 + float3(p2_0)  * cross(vh_0, t1_0) + float3(sqrt(max(_S123 - p2_0 * p2_0, 0.0f)))  * vh_0;
    return normalize(float3(a_6 * nh_0.x, a_6 * nh_0.y, max(nh_0.z, 0.0f)));
}



bool bsdf_sample_0(const Surface_0 thread* s_10, float3 n_5, float3 v_7, float3 thread* l_4, KernelContext_0 thread* kernelContext_20)
{

#line 566
    thread float3 t_7;

#line 566
    thread float3 b_5;
    basis_0(n_5, &t_7, &b_5);
    float _S124 = max(dot(n_5, v_7), 0.00009999999747379f);

#line 568
    float _S125 = rnd_0(kernelContext_20);

#line 568
    float _S126 = rnd_0(kernelContext_20);
    float2 u_2 = float2(_S125, _S126);

#line 569
    float _S127 = rnd_0(kernelContext_20);

#line 569
    float _S128 = specular_chance_0(s_10, _S124);
    if(_S127 < _S128)
    {
        float3 hl_0 = sample_vndf_0(float3(dot(v_7, t_7), dot(v_7, b_5), dot(v_7, n_5)), s_10->a_4, u_2);

        *l_4 = reflect(- v_7, t_7 * float3(hl_0.x)  + b_5 * float3(hl_0.y)  + n_5 * float3(hl_0.z) );

#line 570
    }
    else
    {



        float r_3 = sqrt(_S125);

#line 576
        float phi_3 = 6.28318548202514648f * _S126;
        *l_4 = normalize(t_7 * float3((r_3 * cos(phi_3)))  + b_5 * float3((r_3 * sin(phi_3)))  + n_5 * float3(sqrt(max(1.0f - _S125, 0.0f))) );

#line 570
    }

#line 579
    return (dot(n_5, *l_4)) > 0.0f;
}


#line 752
[[kernel]] void main_0(uint3 group_id_0 [[threadgroup_position_in_grid]], uint3 local_id_0 [[thread_position_in_threadgroup]], uint3 global_id_0 [[thread_position_in_grid]], texture2d<float, access::sample> prev_texture_1 [[texture(0)]], sampler prev_sampler_1 [[sampler(0)]], SLANG_ParameterGroup_Render_Uniforms_0 constant* Render_Uniforms_1 [[buffer(9)]], metal::raytracing::acceleration_structure<metal::raytracing::instancing> structure_1 [[buffer(0)]], Item_natural_0 device* items_1 [[buffer(7)]], uint device* order_1 [[buffer(5)]], uint device* indices_1 [[buffer(2)]], texture2d<float, access::sample> environment_map_texture_1 [[texture(1)]], sampler environment_map_sampler_1 [[sampler(1)]], texture2d<float, access::sample> env_table_texture_1 [[texture(2)]], sampler env_table_sampler_1 [[sampler(2)]], float device* positions_1 [[buffer(1)]], uint device* attributes_1 [[buffer(3)]], uint device* textured_1 [[buffer(8)]], texture2d<float, access::sample> map0_texture_1 [[texture(5)]], sampler map0_sampler_1 [[sampler(5)]], texture2d<float, access::sample> map1_texture_1 [[texture(6)]], sampler map1_sampler_1 [[sampler(6)]], texture2d<float, access::sample> map2_texture_1 [[texture(7)]], sampler map2_sampler_1 [[sampler(7)]], texture2d<float, access::sample> map3_texture_1 [[texture(8)]], sampler map3_sampler_1 [[sampler(8)]], texture2d<float, access::sample> map4_texture_1 [[texture(9)]], sampler map4_sampler_1 [[sampler(9)]], texture2d<float, access::sample> map5_texture_1 [[texture(10)]], sampler map5_sampler_1 [[sampler(10)]], texture2d<float, access::sample> map6_texture_1 [[texture(11)]], sampler map6_sampler_1 [[sampler(11)]], texture2d<float, access::sample> map7_texture_1 [[texture(12)]], sampler map7_sampler_1 [[sampler(12)]], texture2d<float, access::sample> map8_texture_1 [[texture(13)]], sampler map8_sampler_1 [[sampler(13)]], texture2d<float, access::read_write> next_1 [[texture(14)]], texture2d<float, access::sample> prev_albedo_texture_1 [[texture(3)]], sampler prev_albedo_sampler_1 [[sampler(3)]], texture2d<float, access::sample> prev_normal_texture_1 [[texture(4)]], sampler prev_normal_sampler_1 [[sampler(4)]], texture2d<float, access::read_write> guide_albedo_1 [[texture(15)]], texture2d<float, access::read_write> guide_normal_1 [[texture(16)]])
{

#line 752
    float4 sum_1;

#line 752
    float4 prev_a_0;

#line 752
    thread KernelContext_0 kernelContext_21;

#line 752
    (&kernelContext_21)->prev_texture_0 = prev_texture_1;

#line 752
    (&kernelContext_21)->prev_sampler_0 = prev_sampler_1;

#line 752
    (&kernelContext_21)->Render_Uniforms_0 = Render_Uniforms_1;

#line 752
    (&kernelContext_21)->structure_0 = structure_1;

#line 752
    (&kernelContext_21)->items_0 = items_1;

#line 752
    (&kernelContext_21)->order_0 = order_1;

#line 752
    (&kernelContext_21)->indices_0 = indices_1;

#line 752
    (&kernelContext_21)->environment_map_texture_0 = environment_map_texture_1;

#line 752
    (&kernelContext_21)->environment_map_sampler_0 = environment_map_sampler_1;

#line 752
    (&kernelContext_21)->env_table_texture_0 = env_table_texture_1;

#line 752
    (&kernelContext_21)->env_table_sampler_0 = env_table_sampler_1;

#line 752
    (&kernelContext_21)->positions_0 = positions_1;

#line 752
    (&kernelContext_21)->attributes_0 = attributes_1;

#line 752
    (&kernelContext_21)->textured_0 = textured_1;

#line 752
    (&kernelContext_21)->map0_texture_0 = map0_texture_1;

#line 752
    (&kernelContext_21)->map0_sampler_0 = map0_sampler_1;

#line 752
    (&kernelContext_21)->map1_texture_0 = map1_texture_1;

#line 752
    (&kernelContext_21)->map1_sampler_0 = map1_sampler_1;

#line 752
    (&kernelContext_21)->map2_texture_0 = map2_texture_1;

#line 752
    (&kernelContext_21)->map2_sampler_0 = map2_sampler_1;

#line 752
    (&kernelContext_21)->map3_texture_0 = map3_texture_1;

#line 752
    (&kernelContext_21)->map3_sampler_0 = map3_sampler_1;

#line 752
    (&kernelContext_21)->map4_texture_0 = map4_texture_1;

#line 752
    (&kernelContext_21)->map4_sampler_0 = map4_sampler_1;

#line 752
    (&kernelContext_21)->map5_texture_0 = map5_texture_1;

#line 752
    (&kernelContext_21)->map5_sampler_0 = map5_sampler_1;

#line 752
    (&kernelContext_21)->map6_texture_0 = map6_texture_1;

#line 752
    (&kernelContext_21)->map6_sampler_0 = map6_sampler_1;

#line 752
    (&kernelContext_21)->map7_texture_0 = map7_texture_1;

#line 752
    (&kernelContext_21)->map7_sampler_0 = map7_sampler_1;

#line 752
    (&kernelContext_21)->map8_texture_0 = map8_texture_1;

#line 752
    (&kernelContext_21)->map8_sampler_0 = map8_sampler_1;

#line 752
    (&kernelContext_21)->next_0 = next_1;

#line 752
    (&kernelContext_21)->prev_albedo_texture_0 = prev_albedo_texture_1;

#line 752
    (&kernelContext_21)->prev_albedo_sampler_0 = prev_albedo_sampler_1;

#line 752
    (&kernelContext_21)->prev_normal_texture_0 = prev_normal_texture_1;

#line 752
    (&kernelContext_21)->prev_normal_sampler_0 = prev_normal_sampler_1;

#line 752
    (&kernelContext_21)->guide_albedo_0 = guide_albedo_1;

#line 752
    (&kernelContext_21)->guide_normal_0 = guide_normal_1;

#line 752
    int2 _S129 = texture_size_0(prev_texture_1, prev_sampler_1);

    int _S130 = int(global_id_0.x);

#line 754
    int _S131 = int(global_id_0.y + Render_Uniforms_1->counts_0.y);

#line 754
    int2 px_0 = int2(_S130, _S131);
    int _S132 = _S129.x;

#line 755
    bool _S133;

#line 755
    if(_S130 >= _S132)
    {

#line 755
        _S133 = true;

#line 755
    }
    else
    {

#line 755
        _S133 = _S131 >= (_S129.y);

#line 755
    }

#line 755
    if(_S133)
    {

#line 755
        return;
    }

#line 756
    (&kernelContext_21)->rng_0 = uint(_S131 * _S132 + _S130) * 9781U + Render_Uniforms_1->counts_0.x * 6271U + 1U;

#line 756
    uint _S134 = pcg_next_0(&kernelContext_21);

    (&kernelContext_21)->rng_0 = ((&kernelContext_21)->rng_0) ^ (Render_Uniforms_1->counts_0.x * 2654435761U);

#line 758
    uint _S135 = pcg_next_0(&kernelContext_21);

#line 758
    float _S136 = rnd_0(&kernelContext_21);

#line 758
    float _S137 = rnd_0(&kernelContext_21);

#line 763
    float2 _S138 = float2(_S136, _S137);
    bool first_0 = (Render_Uniforms_1->counts_0.x) == 0U;

#line 764
    float2 jitter_0;
    if(first_0)
    {

#line 765
        jitter_0 = float2(0.5f) ;

#line 765
    }
    else
    {

#line 765
        jitter_0 = _S138;

#line 765
    }
    float2 uv_5 = (float2(px_0) + jitter_0) / float2(_S129);
    float2 ndc_0 = float2(uv_5.x * 2.0f - 1.0f, 1.0f - uv_5.y * 2.0f);
    float4 near_0 = ((((&kernelContext_21)->Render_Uniforms_0->inv_view_proj_0) * (float4(ndc_0, 0.0f, 1.0f))));
    float4 far_0 = ((((&kernelContext_21)->Render_Uniforms_0->inv_view_proj_0) * (float4(ndc_0, 1.0f, 1.0f))));
    float3 o_3 = near_0.xyz / float3(near_0.w) ;
    float3 d_8 = normalize(far_0.xyz / float3(far_0.w)  - o_3);


    float2 ndc_dx_0 = ndc_0 + float2(2.0f / float(_S132), 0.0f);
    float4 near_dx_0 = ((((&kernelContext_21)->Render_Uniforms_0->inv_view_proj_0) * (float4(ndc_dx_0, 0.0f, 1.0f))));
    float4 far_dx_0 = ((((&kernelContext_21)->Render_Uniforms_0->inv_view_proj_0) * (float4(ndc_dx_0, 1.0f, 1.0f))));
    float3 o_dx_0 = near_dx_0.xyz / float3(near_dx_0.w) ;
    float3 _S139 = normalize(far_dx_0.xyz / float3(far_dx_0.w)  - o_dx_0);

#line 784
    bool lens_0 = ((&kernelContext_21)->Render_Uniforms_0->lens_eye_0.w) > 0.0f;

#line 784
    float2 surf_0;

#line 784
    float covered_0;

#line 784
    float covered_1;

#line 784
    float3 o_4;

#line 784
    float3 d_9;
    if(lens_0)
    {

#line 785
        float _S140 = rnd_0(&kernelContext_21);

#line 785
        float _S141 = rnd_0(&kernelContext_21);
        float2 u_3 = float2(2.0f)  * float2(_S140, _S141) - float2(1.0f) ;
        float2 _S142 = float2(0.0f) ;
        if(any(u_3 != _S142))
        {

#line 789
            float _S143 = u_3.x;

#line 789
            float _S144 = u_3.y;

#line 789
            bool wide_0 = (abs(_S143)) > (abs(_S144));
            if(wide_0)
            {

#line 790
                covered_0 = _S143;

#line 790
            }
            else
            {

#line 790
                covered_0 = _S144;

#line 790
            }
            if(wide_0)
            {

#line 791
                covered_1 = 0.78539818525314331f * (_S144 / _S143);

#line 791
            }
            else
            {

#line 791
                covered_1 = 1.57079637050628662f - 0.78539818525314331f * (_S143 / _S144);

#line 791
            }

#line 791
            surf_0 = float2(covered_0)  * float2(cos(covered_1), sin(covered_1));

#line 788
        }
        else
        {

#line 788
            surf_0 = _S142;

#line 788
        }

#line 794
        float3 fwd_0 = (&kernelContext_21)->Render_Uniforms_0->lens_fwd_0.xyz;
        float along_0 = dot(d_8, fwd_0);
        float3 e_3 = o_3 + d_8 * float3((dot((&kernelContext_21)->Render_Uniforms_0->lens_eye_0.xyz - o_3, fwd_0) / along_0)) ;

        float3 from_0 = e_3 + float3((&kernelContext_21)->Render_Uniforms_0->lens_eye_0.w)  * (float3(surf_0.x)  * (&kernelContext_21)->Render_Uniforms_0->lens_right_0.xyz + float3(surf_0.y)  * (&kernelContext_21)->Render_Uniforms_0->lens_up_0.xyz);
        float3 dl_0 = normalize(e_3 + d_8 * float3(((&kernelContext_21)->Render_Uniforms_0->lens_right_0.w / along_0))  - from_0);

#line 799
        o_4 = from_0 + dl_0 * float3((dot(o_3 - from_0, fwd_0) / dot(dl_0, fwd_0))) ;

#line 799
        d_9 = dl_0;

#line 785
    }
    else
    {

#line 785
        o_4 = o_3;

#line 785
        d_9 = d_8;

#line 785
    }

#line 804
    float3 _S145 = float3(0.0f) ;

#line 804
    float3 _S146 = float3(1.0f) ;
    thread float pdf_bsdf_3 = 0.0f;
    float4 _S147 = float4(0.0f) ;
    int _S148 = int(Render_Uniforms_1->counts_0.z);

#line 807
    covered_0 = 0.0f;

#line 807
    float4 guide_a_0 = _S147;

#line 807
    float4 guide_n_0 = _S147;

#line 807
    int bounce_0 = int(0);

#line 807
    float3 weight_0 = _S146;

#line 807
    float3 radiance_6 = _S145;
    for(;;)
    {

#line 808
        if(bounce_0 <= _S148)
        {
        }
        else
        {

#line 808
            break;
        }

#line 809
        thread Hit_0 hit_1;

#line 809
        bool _S149 = trace_0(o_4, d_9, 3.00000000549775576e+38f, false, &hit_1, &kernelContext_21);


        bool _S150 = bounce_0 > int(0);

#line 812
        float3 radiance_7;

#line 812
        if(_S150)
        {

#line 812
            if(_S149)
            {

#line 812
                covered_1 = (&hit_1)->t_0;

#line 812
            }
            else
            {

#line 812
                covered_1 = 3.00000000549775576e+38f;

#line 812
            }

#line 812
            float3 _S151 = lights_met_0(o_4, d_9, covered_1, !_S149, pdf_bsdf_3, &kernelContext_21);

#line 812
            radiance_7 = radiance_6 + weight_0 * _S151;

#line 812
        }
        else
        {

#line 812
            radiance_7 = radiance_6;

#line 812
        }
        if(!_S149)
        {
            if(_S150)
            {

#line 815
                float3 _S152 = environment_0(d_9, &kernelContext_21);

#line 815
                float3 _S153 = weight_0 * _S152;

#line 815
                if(((&kernelContext_21)->Render_Uniforms_0->env_0.z) > 0.0f)
                {

#line 815
                    float _S154 = (&kernelContext_21)->Render_Uniforms_0->env_0.z;

#line 815
                    float _S155 = env_pdf_0(d_9, &kernelContext_21);

#line 815
                    covered_1 = power_weight_0(pdf_bsdf_3, _S154 * _S155);

#line 815
                }
                else
                {

#line 815
                    covered_1 = 1.0f;

#line 815
                }

#line 815
                radiance_6 = radiance_7 + _S153 * float3(covered_1) ;

#line 815
            }
            else
            {

#line 815
                radiance_6 = radiance_7;

#line 815
            }
            break;
        }
        bool _S156 = bounce_0 == int(0);

#line 818
        if(_S156)
        {

#line 818
            covered_1 = 1.0f;

#line 818
        }
        else
        {

#line 818
            covered_1 = covered_0;

#line 818
        }
        if(bounce_0 == _S148)
        {

#line 819
            covered_0 = covered_1;

#line 819
            radiance_6 = radiance_7;

#line 819
            break;
        }
        uint ib_1 = (&kernelContext_21)->indices_0[3U * (&hit_1)->tri_0 + 1U];

#line 821
        uint ic_1 = (&kernelContext_21)->indices_0[3U * (&hit_1)->tri_0 + 2U];
        uint base_0 = (uint4(((&kernelContext_21)->items_0+(&hit_1)->item_1)->offs_0) ).x;

#line 822
        uint flags_0 = (uint4(((&kernelContext_21)->items_0+(&hit_1)->item_1)->offs_0) ).y;

#line 822
        matrix<float,int(4),int(4)>  _S157 = matrix<float,int(4),int(4)> (((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(0)][int(0)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(0)][int(1)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(0)][int(2)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(0)][int(3)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(1)][int(0)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(1)][int(1)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(1)][int(2)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(1)][int(3)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(2)][int(0)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(2)][int(1)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(2)][int(2)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(2)][int(3)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(3)][int(0)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(3)][int(1)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(3)][int(2)], ((&kernelContext_21)->items_0+(&hit_1)->item_1)->model_0.data_0[int(3)][int(3)]);

        float w0_0 = 1.0f - (&hit_1)->uv_0.x - (&hit_1)->uv_0.y;
        uint _S158 = base_0 + (&kernelContext_21)->indices_0[3U * (&hit_1)->tri_0];

#line 825
        float3 _S159 = vertex_0(_S158, &kernelContext_21);

#line 825
        uint _S160 = base_0 + ib_1;

#line 825
        float3 _S161 = vertex_0(_S160, &kernelContext_21);

#line 825
        uint _S162 = base_0 + ic_1;

#line 825
        float3 _S163 = vertex_0(_S162, &kernelContext_21);

#line 825
        float3 _S164 = float3(w0_0) ;
        float3 p_3 = (((_S157) * (float4(_S159 * _S164 + _S161 * float3((&hit_1)->uv_0.x)  + _S163 * float3((&hit_1)->uv_0.y) , 1.0f)))).xyz;
        float3 _S165 = _S161 - _S159;

#line 827
        float3 _S166 = _S163 - _S159;

#line 827
        float3 _S167 = _S157[int(0)].xyz;

#line 827
        matrix<float,int(3),int(3)>  _S168 = matrix<float,int(3),int(3)> (_S167, _S157[int(1)].xyz, _S157[int(2)].xyz);

#line 827
        float3 _S169 = (((_S168) * (cross(_S165, _S166))));

#line 827
        float3 ng_1 = normalize(_S169);

#line 827
        float3 ng_2;
        if((dot(ng_1, d_9)) > 0.0f)
        {

#line 828
            ng_2 = - ng_1;

#line 828
        }
        else
        {

#line 828
            ng_2 = ng_1;

#line 828
        }

#line 828
        float3 _S170 = vertex_normal_0(_S158, &kernelContext_21);
        float3 _S171 = _S170 * _S164;

#line 829
        float3 _S172 = vertex_normal_0(_S160, &kernelContext_21);

#line 829
        float3 _S173 = _S171 + _S172 * float3((&hit_1)->uv_0.x) ;

#line 829
        float3 _S174 = vertex_normal_0(_S162, &kernelContext_21);

#line 829
        float3 n_6 = normalize((((_S168) * (_S173 + _S174 * float3((&hit_1)->uv_0.y) ))));

#line 829
        float3 n_7;
        if((dot(n_6, ng_2)) < 0.0f)
        {

#line 830
            n_7 = - n_6;

#line 830
        }
        else
        {

#line 830
            n_7 = n_6;

#line 830
        }
        float3 v_8 = - d_9;

#line 831
        float3 n_8;

        if((dot(n_7, v_8)) <= 0.0f)
        {

#line 833
            n_8 = ng_2;

#line 833
        }
        else
        {

#line 833
            n_8 = n_7;

#line 833
        }

        float3 _S175 = (float4(((&kernelContext_21)->items_0+(&hit_1)->item_1)->color_0) ).xyz;
        float2 _S176 = (float4(((&kernelContext_21)->items_0+(&hit_1)->item_1)->surface_0) ).xy;

#line 836
        float3 albedo_0;

#line 836
        float3 albedo_1;

#line 836
        float3 mapped_0;
        if((flags_0 & 7U) != 0U)
        {

#line 837
            uint2 _S177 = vertex_paint_0(_S158, &kernelContext_21);

            uint group_0 = (_S177.y) & 65535U;
            if((flags_0 & 4U) != 0U)
            {

#line 840
                surf_0 = _S176;

#line 840
                uint k_2 = 1U;

#line 840
                albedo_0 = _S175;
                for(;;)
                {

#line 841
                    if(k_2 < 16U)
                    {
                    }
                    else
                    {

#line 841
                        break;
                    }

#line 842
                    if(((uint4((&((&kernelContext_21)->items_0+(&hit_1)->item_1)->slot_group_0)->data_1[k_2 >> 2U]) )[k_2 & 3U]) == group_0)
                    {

#line 843
                        float3 _S178 = (float4((&((&kernelContext_21)->items_0+(&hit_1)->item_1)->slot_color_0)->data_2[k_2]) ).xyz;

#line 843
                        surf_0 = (float4((&((&kernelContext_21)->items_0+(&hit_1)->item_1)->slot_surface_0)->data_2[k_2]) ).xy;

#line 843
                        albedo_0 = _S178;

#line 842
                    }

#line 841
                    k_2 = k_2 + 1U;

#line 841
                }

#line 840
            }
            else
            {

#line 840
                surf_0 = _S176;

#line 840
                albedo_0 = _S175;

#line 840
            }

#line 848
            if((flags_0 & 1U) != 0U)
            {

#line 848
                uint2 _S179 = vertex_paint_0(_S158, &kernelContext_21);
                float4 c0_0 = unpack_unorm4x8_to_float(_S179.x);

#line 849
                uint2 _S180 = vertex_paint_0(_S160, &kernelContext_21);
                float4 c1_0 = unpack_unorm4x8_to_float(_S180.x);

#line 850
                uint2 _S181 = vertex_paint_0(_S162, &kernelContext_21);
                float4 c2_0 = unpack_unorm4x8_to_float(_S181.x);
                float4 paint_0 = float4(srgb_decode_0(c0_0.xyz), c0_0.w) * float4(w0_0)  + float4(srgb_decode_0(c1_0.xyz), c1_0.w) * float4((&hit_1)->uv_0.x)  + float4(srgb_decode_0(c2_0.xyz), c2_0.w) * float4((&hit_1)->uv_0.y) ;

#line 852
                albedo_1 = mix(albedo_0, paint_0.xyz, float3(paint_0.w) );

#line 848
            }
            else
            {

#line 848
                albedo_1 = albedo_0;

#line 848
            }

#line 855
            if((flags_0 & 2U) != 0U)
            {

#line 855
                mapped_0 = group_color_0(group_0);

#line 855
            }
            else
            {

#line 855
                mapped_0 = albedo_1;

#line 855
            }

#line 855
            albedo_0 = mapped_0;

#line 837
        }
        else
        {

#line 837
            surf_0 = _S176;

#line 837
            albedo_0 = _S175;

#line 837
        }

#line 837
        float2 surf_1;

#line 837
        float3 n_9;

#line 857
        if((flags_0 & 8U) != 0U)
        {

#line 857
            uint4 _S182 = uint4(((&kernelContext_21)->items_0+(&hit_1)->item_1)->tex_0) ;


            uint at_2 = _S182.y + 3U * ((&hit_1)->tri_0 - _S182.x);
            uint _S183 = _S182.z;

#line 861
            Tex_Vertex_0 _S184 = tex_vertex_0(_S183 + 8U * (&kernelContext_21)->textured_0[at_2], &kernelContext_21);

#line 861
            Tex_Vertex_0 _S185 = tex_vertex_0(_S183 + 8U * (&kernelContext_21)->textured_0[at_2 + 1U], &kernelContext_21);

#line 861
            Tex_Vertex_0 _S186 = tex_vertex_0(_S183 + 8U * (&kernelContext_21)->textured_0[at_2 + 2U], &kernelContext_21);

#line 867
            uint _S187 = _S182.w;

#line 867
            uint slot_1 = _S187 & 15U;

#line 867
            uint view_0 = (_S187 >> 4U) & 15U;

#line 867
            uint maps_0 = _S187 >> 8U;

            float2 uv_up_0 = _S184.uv_1 * float2(w0_0)  + _S185.uv_1 * float2((&hit_1)->uv_0.x)  + _S186.uv_1 * float2((&hit_1)->uv_0.y) ;
            float2 uv_6 = float2(uv_up_0.x, 1.0f - uv_up_0.y);

#line 870
            float lod_1;

#line 875
            if(_S156)
            {
                float2 u1_0 = _S185.uv_1 - _S184.uv_1;

#line 877
                float2 u2_0 = _S186.uv_1 - _S184.uv_1;

#line 877
                lod_1 = log2(max(length(o_dx_0 + _S139 * float3((&hit_1)->t_0)  - p_3) * sqrt(abs(u1_0.x * u2_0.y - u1_0.y * u2_0.x) / max(length(cross((((_S168) * (_S165))), (((_S168) * (_S166))))), 1.00000000317107685e-30f)), 9.999999960041972e-13f));

#line 875
            }
            else
            {

#line 875
                lod_1 = -6.0f;

#line 875
            }

#line 888
            matrix<float,int(3),int(3)>  turn_0 = _S168 / length(_S167);
            float3 nv_0 = (((turn_0) * (_S184.n_0 * _S164 + _S185.n_0 * float3((&hit_1)->uv_0.x)  + _S186.n_0 * float3((&hit_1)->uv_0.y) )));
            float4 tw_0 = _S184.t_4 * float4(w0_0)  + _S185.t_4 * float4((&hit_1)->uv_0.x)  + _S186.t_4 * float4((&hit_1)->uv_0.y) ;
            float3 tv_0 = (((turn_0) * (tw_0.xyz)));
            float3 _S188 = normalize(nv_0);
            bool _S189 = view_0 == 1U;

#line 893
            if(_S189)
            {

#line 893
                _S133 = true;

#line 893
            }
            else
            {

#line 893
                _S133 = view_0 == 2U;

#line 893
            }

#line 893
            bool _S190;

#line 893
            if(_S133)
            {

#line 893
                _S190 = (maps_0 & 4U) != 0U;

#line 893
            }
            else
            {

#line 893
                _S190 = false;

#line 893
            }

#line 893
            if(_S190)
            {

#line 893
                float4 _S191 = map_at_0(slot_1, 2U, uv_6, lod_1, &kernelContext_21);
                float3 tn_0 = _S191.xyz * float3(2.0f)  - float3(1.0f) ;

#line 894
                float _S192;
                if((tw_0.w) < 0.0f)
                {

#line 895
                    _S192 = -1.0f;

#line 895
                }
                else
                {

#line 895
                    _S192 = 1.0f;

#line 895
                }
                float3 m_0 = float3(tn_0.x)  * tv_0 + float3(tn_0.y)  * (float3(_S192)  * cross(nv_0, tv_0)) + float3(tn_0.z)  * nv_0;
                if((dot(m_0, m_0)) > 0.0f)
                {

#line 897
                    albedo_1 = normalize(m_0);

#line 897
                }
                else
                {

#line 897
                    albedo_1 = _S188;

#line 897
                }

#line 893
            }
            else
            {

#line 893
                albedo_1 = _S188;

#line 893
            }

#line 899
            if((dot(_S169, d_9)) > 0.0f)
            {

#line 899
                mapped_0 = - albedo_1;

#line 899
            }
            else
            {

#line 899
                mapped_0 = albedo_1;

#line 899
            }
            if((dot(mapped_0, v_8)) > 0.0f)
            {

#line 900
                n_9 = mapped_0;

#line 900
            }
            else
            {

#line 900
                n_9 = ng_2;

#line 900
            }

#line 906
            float3 r_4 = reflect(- v_8, n_9);
            float under_0 = dot(ng_2, r_4);

#line 907
            float3 n_10;
            if(under_0 < 0.0f)
            {

#line 908
                n_10 = normalize(v_8 + normalize(r_4 - ng_2 * float3((under_0 - 0.00100000004749745f)) ));

#line 908
            }
            else
            {

#line 908
                n_10 = n_9;

#line 908
            }

#line 908
            bool _S193;
            if(_S189)
            {

#line 909
                _S193 = (maps_0 & 1U) != 0U;

#line 909
            }
            else
            {

#line 909
                _S193 = false;

#line 909
            }

#line 909
            float3 albedo_2;

#line 909
            if(_S193)
            {

#line 909
                float3 _S194 = (float4(((&kernelContext_21)->items_0+(&hit_1)->item_1)->color_0) ).xyz;

#line 909
                float4 _S195 = map_at_0(slot_1, 0U, uv_6, lod_1, &kernelContext_21);

#line 909
                albedo_2 = _S194 * _S195.xyz;

#line 909
            }
            else
            {

#line 909
                albedo_2 = albedo_0;

#line 909
            }

#line 909
            bool _S196;
            if(_S189)
            {

#line 910
                _S196 = (maps_0 & 2U) != 0U;

#line 910
            }
            else
            {

#line 910
                _S196 = false;

#line 910
            }

#line 910
            if(_S196)
            {

#line 910
                float4 _S197 = map_at_0(slot_1, 1U, uv_6, lod_1, &kernelContext_21);
                float3 orm_0 = _S197.xyz;

#line 911
                surf_1 = float2(orm_0.z, max(orm_0.y, 0.03999999910593033f));

#line 910
            }
            else
            {

#line 910
                surf_1 = surf_0;

#line 910
            }

#line 910
            float3 albedo_3;



            if(view_0 == 3U)
            {

#line 914
                albedo_3 = albedo_2 * uv_checker_0(uv_6);

#line 914
            }
            else
            {

#line 914
                albedo_3 = albedo_2;

#line 914
            }

#line 914
            n_9 = n_10;

#line 914
            albedo_1 = albedo_3;

#line 857
        }
        else
        {

#line 857
            n_9 = n_8;

#line 857
            surf_1 = surf_0;

#line 857
            albedo_1 = albedo_0;

#line 857
        }

#line 916
        if(_S156)
        {
            float4 _S198 = float4(n_9, (&hit_1)->t_0);

#line 918
            sum_1 = float4(albedo_1, 1.0f);

#line 918
            prev_a_0 = _S198;

#line 916
        }
        else
        {

#line 916
            sum_1 = guide_a_0;

#line 916
            prev_a_0 = guide_n_0;

#line 916
        }

#line 921
        float metallic_0 = clamp(surf_1.x, 0.0f, 1.0f);

#line 920
        thread Surface_0 s_11;

        (&s_11)->diffuse_0 = albedo_1 * float3((1.0f - metallic_0)) ;
        (&s_11)->f0_1 = mix(float3(0.03999999910593033f) , albedo_1, float3(metallic_0) );
        float _S199 = surf_1.y;

#line 924
        (&s_11)->a_4 = max(_S199 * _S199, 0.00100000004749745f);

#line 924
        thread Surface_0 _S200 = s_11;

#line 924
        float3 _S201 = direct_light_0(&_S200, p_3, ng_2, n_9, v_8, &kernelContext_21);

        float3 radiance_8 = radiance_7 + weight_0 * _S201;

#line 926
        thread Surface_0 _S202 = s_11;

        thread float3 l_5;

#line 928
        bool _S203 = bsdf_sample_0(&_S202, n_9, v_8, &l_5, &kernelContext_21);
        if(!_S203)
        {

#line 929
            _S133 = true;

#line 929
        }
        else
        {

#line 929
            _S133 = (dot(l_5, ng_2)) <= 0.0f;

#line 929
        }

#line 929
        if(_S133)
        {

#line 929
            covered_0 = covered_1;

#line 929
            guide_a_0 = sum_1;

#line 929
            guide_n_0 = prev_a_0;

#line 929
            radiance_6 = radiance_8;

#line 929
            break;
        }

#line 929
        thread Surface_0 _S204 = s_11;

#line 929
        float3 _S205 = bsdf_eval_0(&_S204, n_9, v_8, l_5, &pdf_bsdf_3, 1.0f);

        if(pdf_bsdf_3 <= 0.0f)
        {

#line 931
            covered_0 = covered_1;

#line 931
            guide_a_0 = sum_1;

#line 931
            guide_n_0 = prev_a_0;

#line 931
            radiance_6 = radiance_8;

#line 931
            break;
        }

#line 932
        float3 weight_1 = weight_0 * (_S205 / float3(pdf_bsdf_3) );
        float3 _S206 = offset_ray_0(p_3, ng_2);
        float3 _S207 = l_5;

        if(bounce_0 >= int(2))
        {

#line 937
            float q_1 = clamp(max(weight_1.x, max(weight_1.y, weight_1.z)), 0.05000000074505806f, 0.94999998807907104f);

#line 937
            float _S208 = rnd_0(&kernelContext_21);
            if(_S208 > q_1)
            {

#line 938
                covered_0 = covered_1;

#line 938
                guide_a_0 = sum_1;

#line 938
                guide_n_0 = prev_a_0;

#line 938
                radiance_6 = radiance_8;

#line 938
                break;
            }

#line 938
            weight_0 = weight_1 / float3(q_1) ;

#line 936
        }
        else
        {

#line 936
            weight_0 = weight_1;

#line 936
        }

#line 808
        int _S209 = bounce_0 + int(1);

#line 808
        o_4 = _S206;

#line 808
        d_9 = _S207;

#line 808
        covered_0 = covered_1;

#line 808
        guide_a_0 = sum_1;

#line 808
        guide_n_0 = prev_a_0;

#line 808
        bounce_0 = _S209;

#line 808
        radiance_6 = radiance_8;

#line 808
    }

#line 942
    float lum_0 = luminance_0(radiance_6);
    if(lum_0 > 16.0f)
    {

#line 943
        radiance_6 = radiance_6 * float3((16.0f / lum_0)) ;

#line 943
    }
    if(first_0)
    {

#line 944
        sum_1 = _S147;

#line 944
    }
    else
    {

#line 944
        sampler _S210 = (&kernelContext_21)->prev_sampler_0;

#line 944
        sum_1 = (((&kernelContext_21)->prev_texture_0).read(vec<uint,2>(((_S210)).xy), uint(((_S210)).z)));

#line 944
    }
    uint2 _S211 = uint2(px_0);

#line 945
    (&kernelContext_21)->next_0.write(sum_1 + float4(radiance_6, covered_0),_S211);
    if(lens_0)
    {

        if(first_0)
        {

#line 949
            prev_a_0 = _S147;

#line 949
        }
        else
        {

#line 949
            sampler _S212 = (&kernelContext_21)->prev_albedo_sampler_0;

#line 949
            prev_a_0 = (((&kernelContext_21)->prev_albedo_texture_0).read(vec<uint,2>(((_S212)).xy), uint(((_S212)).z)));

#line 949
        }

#line 949
        float4 prev_n_0;
        if(first_0)
        {

#line 950
            prev_n_0 = _S147;

#line 950
        }
        else
        {

#line 950
            sampler _S213 = (&kernelContext_21)->prev_normal_sampler_0;

#line 950
            prev_n_0 = (((&kernelContext_21)->prev_normal_texture_0).read(vec<uint,2>(((_S213)).xy), uint(((_S213)).z)));

#line 950
        }
        float done_0 = float(Render_Uniforms_1->counts_0.x);
        float hit_2 = guide_a_0.w;

#line 952
        float hits_before_0 = prev_a_0.w * done_0;
        float hits_0 = hits_before_0 + hit_2;
        if(hits_0 > 0.0f)
        {
            float4 _S214 = (prev_n_0 * float4(hits_before_0)  + guide_n_0 * float4(hit_2) ) / float4(hits_0) ;

#line 956
            guide_a_0 = float4((prev_a_0.xyz * float3(hits_before_0)  + guide_a_0.xyz * float3(hit_2) ) / float3(hits_0) , hits_0 / (done_0 + 1.0f));

#line 956
            guide_n_0 = _S214;

#line 954
        }



        (&kernelContext_21)->guide_albedo_0.write(guide_a_0,_S211);
        (&kernelContext_21)->guide_normal_0.write(guide_n_0,_S211);

#line 946
    }
    else
    {

#line 960
        if(first_0)
        {

#line 961
            (&kernelContext_21)->guide_albedo_0.write(guide_a_0,_S211);
            (&kernelContext_21)->guide_normal_0.write(guide_n_0,_S211);

#line 960
        }

#line 946
    }

#line 964
    return;
}

