// slangc metal from render_trace_rq.comp.spv sha256 572b7a1595e1e2c0fe5afde1c6194538fb2d1e0c0278a815aee74973473e1043
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


#line 186
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


#line 188
uint pcg_next_0(KernelContext_0 thread* kernelContext_0)
{

#line 189
    uint s_0 = kernelContext_0->rng_0;
    kernelContext_0->rng_0 = kernelContext_0->rng_0 * 747796405U + 2891336453U;
    uint w_1 = ((s_0 >> ((s_0 >> 28U) + 4U)) ^ s_0) * 277803737U;
    return (w_1 >> 22U) ^ w_1;
}


#line 188
uint pcg_next_1(KernelContext_0 thread* kernelContext_1)
{

#line 189
    uint s_1 = kernelContext_1->rng_0;
    kernelContext_1->rng_0 = kernelContext_1->rng_0 * 747796405U + 2891336453U;
    uint w_2 = ((s_1 >> ((s_1 >> 28U) + 4U)) ^ s_1) * 277803737U;
    return (w_2 >> 22U) ^ w_2;
}

float rnd_0(KernelContext_0 thread* kernelContext_2)
{

#line 195
    uint _S1 = pcg_next_1(kernelContext_2);
    return float(_S1 >> 8U) / 1.6777216e+07f;
}


#line 323
uint merged_triangle_0(uint item_0, uint geometry_0, uint primitive_0, KernelContext_0 thread* kernelContext_3)
{

#line 324
    return kernelContext_3->order_0[(uint4((kernelContext_3->items_0+item_0)->offs_0) ).z + geometry_0] + primitive_0;
}


#line 313
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


#line 332 "render_trace.slang"
bool trace_0(float3 o_0, float3 d_0, float t_max_0, bool any_0, Hit_0 thread* hit_0, KernelContext_0 thread* kernelContext_4)
{

#line 333
    hit_0->t_0 = t_max_0;
    hit_0->tri_0 = 0U;
    hit_0->item_1 = 0U;
    hit_0->uv_0 = float2(0.0f) ;
    if((kernelContext_4->Render_Uniforms_0->extra_0.y) != 0U)
    {

#line 337
        return false;
    }

#line 338
    thread RayDesc_0 ray_0;
    (&ray_0)->Origin_0 = o_0;
    (&ray_0)->TMin_0 = 0.0f;
    (&ray_0)->Direction_0 = d_0;
    (&ray_0)->TMax_0 = t_max_0;
    thread raytracing::intersection_query<raytracing::triangle_data, raytracing::instancing> q_0;

#line 343
    uint _S2;
    if(any_0)
    {

#line 344
        _S2 = 4U;

#line 344
    }
    else
    {

#line 344
        _S2 = 0U;

#line 344
    }

#line 344
    (&q_0)->reset({ (ray_0.Origin_0), (ray_0.Direction_0), (ray_0.TMin_0), (ray_0.TMax_0) }, (kernelContext_4->structure_0), (255U), _slang_ray_flags_to_intersection_params((_S2 | 0U)));
    for(;;)
    {

#line 345
        bool _S3 = ((&q_0)->next());

#line 345
        if(_S3)
        {
        }
        else
        {

#line 345
            break;
        }

#line 346
        uint _S4 = ((&q_0)->get_candidate_user_instance_id());

#line 346
        uint _S5 = ((&q_0)->get_candidate_geometry_id());

#line 346
        uint _S6 = ((&q_0)->get_candidate_primitive_id());

#line 346
        uint _S7 = merged_triangle_0(_S4, _S5, _S6, kernelContext_4);
        uint _S8 = 3U * _S7;

#line 347
        uint ia_0 = kernelContext_4->indices_0[_S8];

#line 347
        uint ib_0 = kernelContext_4->indices_0[_S8 + 1U];

#line 347
        uint ic_0 = kernelContext_4->indices_0[_S8 + 2U];

#line 347
        bool _S9;
        if(ia_0 != ib_0)
        {

#line 348
            _S9 = ib_0 != ic_0;

#line 348
        }
        else
        {

#line 348
            _S9 = false;

#line 348
        }

#line 348
        bool _S10;

#line 348
        if(_S9)
        {

#line 348
            _S10 = ia_0 != ic_0;

#line 348
        }
        else
        {

#line 348
            _S10 = false;

#line 348
        }

#line 348
        if(_S10)
        {

#line 348
            (&q_0)->commit_triangle_intersection();

#line 348
        }

#line 345
    }

#line 350
    uint _S11 = (_slang_committed_intersection_type_to_uint((&q_0)->get_committed_intersection_type()));

#line 350
    if(_S11 != 1U)
    {

#line 350
        return false;
    }

#line 351
    float _S12 = ((&q_0)->get_committed_distance());

#line 351
    hit_0->t_0 = _S12;
    uint _S13 = ((&q_0)->get_committed_user_instance_id());

#line 352
    hit_0->item_1 = _S13;
    uint _S14 = ((&q_0)->get_committed_geometry_id());

#line 353
    uint _S15 = ((&q_0)->get_committed_primitive_id());

#line 353
    uint _S16 = merged_triangle_0(_S13, _S14, _S15, kernelContext_4);

#line 353
    hit_0->tri_0 = _S16;
    float2 _S17 = ((&q_0)->get_committed_triangle_barycentric_coord());

#line 354
    hit_0->uv_0 = _S17;
    return true;
}


#line 579
float cone_pdf_0(float cos_max_0)
{

#line 580
    return 1.0f / (6.28318548202514648f * max(1.0f - cos_max_0, 1.00000001168609742e-07f));
}


#line 590
float sphere_hit_0(float3 o_1, float3 d_1, float3 c_0, float r_0)
{

#line 591
    float3 oc_0 = o_1 - c_0;
    float b_0 = dot(oc_0, d_1);

    float disc_0 = b_0 * b_0 - (dot(oc_0, oc_0) - r_0 * r_0);
    if(disc_0 < 0.0f)
    {

#line 595
        return -1.0f;
    }

#line 596
    float s_2 = sqrt(disc_0);
    float _S18 = - b_0;

#line 597
    float t_1 = _S18 - s_2;

#line 597
    float t_2;
    if(t_1 < 0.0f)
    {

#line 598
        t_2 = _S18 + s_2;

#line 598
    }
    else
    {

#line 598
        t_2 = t_1;

#line 598
    }
    return t_2;
}



float sphere_cone_0(int i_0, float3 p_0, KernelContext_0 thread* kernelContext_5)
{

#line 605
    float3 d_2 = kernelContext_5->Render_Uniforms_0->light_pos_0[i_0].xyz - p_0;
    float d2_0 = dot(d_2, d_2);

#line 606
    float r_1 = kernelContext_5->Render_Uniforms_0->light_size_0[i_0].x;
    float _S19 = r_1 * r_1;

#line 607
    if(d2_0 <= _S19)
    {

#line 607
        return 2.0f;
    }

#line 608
    return sqrt(1.0f - _S19 / d2_0);
}


#line 6 "light_window.slang"
float light_window_0(float4 pos_0, float4 shape_0, float4 spot_0, float d2_1, float3 l_0)
{
    float _S20 = shape_0.y;

#line 8
    float k_0;

#line 8
    if(_S20 > 0.0f)
    {

#line 9
        float x_0 = d2_1 / (_S20 * _S20);
        float w_3 = clamp(1.0f - x_0 * x_0, 0.0f, 1.0f);

#line 10
        k_0 = w_3 * w_3;

#line 8
    }
    else
    {

#line 8
        k_0 = 1.0f;

#line 8
    }

#line 13
    if((pos_0.w) > 1.5f)
    {

#line 13
        k_0 = k_0 * smoothstep(spot_0.w, shape_0.z, dot(- l_0, spot_0.xyz));

#line 13
    }
    return k_0;
}


#line 585 "render_trace.slang"
float light_falloff_0(int i_1, float d2_2, float3 l_1, KernelContext_0 thread* kernelContext_6)
{

#line 586
    return light_window_0(kernelContext_6->Render_Uniforms_0->light_pos_0[i_1], kernelContext_6->Render_Uniforms_0->light_shape_0[i_1], kernelContext_6->Render_Uniforms_0->light_spot_0[i_1], d2_2, l_1);
}


#line 611
float power_weight_0(float a_0, float b_1)
{

#line 612
    float _S21 = a_0 * a_0;

#line 612
    return _S21 / max(_S21 + b_1 * b_1, 1.00000000317107685e-30f);
}


#line 711
float3 lights_met_0(float3 o_2, float3 d_3, float t_hit_0, bool escaped_0, float pdf_bsdf_0, KernelContext_0 thread* kernelContext_7)
{

#line 712
    float3 _S22 = float3(0.0f) ;

#line 712
    int i_2 = int(0);

#line 712
    float3 sum_0 = _S22;
    for(;;)
    {

#line 713
        if(i_2 < int(8))
        {
        }
        else
        {

#line 713
            break;
        }

#line 714
        if((kernelContext_7->Render_Uniforms_0->light_size_0[i_2].w) <= 0.0f)
        {

#line 714
            i_2 = i_2 + int(1);

#line 713
            continue;
        }
        float3 radiance_0 = kernelContext_7->Render_Uniforms_0->light_color_0[i_2].xyz * float3(kernelContext_7->Render_Uniforms_0->light_size_0[i_2].y) ;

#line 715
        float3 radiance_1;

#line 715
        bool _S23;

#line 715
        float pdf_dir_0;

        if((kernelContext_7->Render_Uniforms_0->light_pos_0[i_2].w) < 0.5f)
        {

#line 718
            if(!escaped_0)
            {

#line 718
                _S23 = true;

#line 718
            }
            else
            {

#line 718
                _S23 = (dot(d_3, kernelContext_7->Render_Uniforms_0->light_pos_0[i_2].xyz)) < (kernelContext_7->Render_Uniforms_0->light_size_0[i_2].x);

#line 718
            }

#line 718
            if(_S23)
            {

#line 718
                i_2 = i_2 + int(1);

#line 713
                continue;
            }

#line 713
            pdf_dir_0 = cone_pdf_0(kernelContext_7->Render_Uniforms_0->light_size_0[i_2].x);

#line 713
            radiance_1 = radiance_0;



        }
        else
        {

            float t_3 = sphere_hit_0(o_2, d_3, kernelContext_7->Render_Uniforms_0->light_pos_0[i_2].xyz, kernelContext_7->Render_Uniforms_0->light_size_0[i_2].x);

#line 721
            float _S24 = sphere_cone_0(i_2, o_2, kernelContext_7);

            if(t_3 <= 0.0f)
            {

#line 723
                _S23 = true;

#line 723
            }
            else
            {

#line 723
                _S23 = t_3 >= t_hit_0;

#line 723
            }

#line 723
            bool _S25;

#line 723
            if(_S23)
            {

#line 723
                _S25 = true;

#line 723
            }
            else
            {

#line 723
                _S25 = _S24 > 1.0f;

#line 723
            }

#line 723
            if(_S25)
            {

#line 723
                i_2 = i_2 + int(1);

#line 713
                continue;
            }

#line 724
            float3 to_0 = kernelContext_7->Render_Uniforms_0->light_pos_0[i_2].xyz - o_2;

#line 724
            float _S26 = light_falloff_0(i_2, dot(to_0, to_0), normalize(to_0), kernelContext_7);
            float3 radiance_2 = radiance_0 * float3(_S26) ;

#line 725
            pdf_dir_0 = cone_pdf_0(_S24);

#line 725
            radiance_1 = radiance_2;

#line 717
        }

#line 717
        sum_0 = sum_0 + radiance_1 * float3(power_weight_0(pdf_bsdf_0, kernelContext_7->Render_Uniforms_0->light_size_0[i_2].w * pdf_dir_0)) ;

#line 713
        i_2 = i_2 + int(1);

#line 713
    }

#line 730
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
    float _S27 = dir_1.y;

#line 36
    return mix(float3(0.07000000029802322f, 0.06499999761581421f, 0.05999999865889549f), float3(0.40000000596046448f, 0.43000000715255737f, 0.47999998927116394f), float3(smoothstep(- w_4, w_4, _S27)) ) + float3(0.12999999523162842f, 0.11999999731779099f, 0.10999999940395355f) * float3(exp(- abs(_S27) / (0.05999999865889549f + 0.5f * rough_1)))  + lobe_0(dir_1, float3(-0.65590423345565796f, 0.7433580756187439f, 0.13118083775043488f), float3(4.0f, 3.79999995231628418f, 3.5f), 300.0f, rough_1) + lobe_0(dir_1, float3(0.84478187561035156f, 0.32852628827095032f, -0.42239093780517578f), float3(1.60000002384185791f, 1.79999995231628418f, 2.09999990463256836f), 600.0f, rough_1) + lobe_0(dir_1, float3(0.09396819770336151f, -0.32888868451118469f, 0.93968194723129272f), float3(0.5f, 0.5f, 0.5f), 4.0f, rough_1);
}


#line 617 "render_trace.slang"
float3 environment_0(float3 d_5, KernelContext_0 thread* kernelContext_8)
{

#line 618
    if((kernelContext_8->Render_Uniforms_0->env_0.x) > 0.5f)
    {
        return ((kernelContext_8->environment_map_texture_0).sample((kernelContext_8->environment_map_sampler_0), (panorama_uv_0((((transpose(matrix<float,int(3),int(3)> (kernelContext_8->Render_Uniforms_0->env_x_0.xyz, kernelContext_8->Render_Uniforms_0->env_y_0.xyz, kernelContext_8->Render_Uniforms_0->env_z_0.xyz))) * (d_5))))), level((0.0f)))).xyz * float3(kernelContext_8->Render_Uniforms_0->env_0.y) ;
    }

    return studio_0((((transpose(matrix<float,int(3),int(3)> (kernelContext_8->Render_Uniforms_0->rig_x_0.xyz, kernelContext_8->Render_Uniforms_0->rig_y_0.xyz, kernelContext_8->Render_Uniforms_0->rig_z_0.xyz))) * (d_5))), 0.25f) * float3((0.69999998807907104f * kernelContext_8->Render_Uniforms_0->rig_x_0.w)) ;
}


matrix<float,int(3),int(3)>  env_frame_0(KernelContext_0 thread* kernelContext_9)
{

#line 627
    matrix<float,int(3),int(3)>  _S28;
    if((kernelContext_9->Render_Uniforms_0->env_0.x) > 0.5f)
    {

#line 628
        _S28 = matrix<float,int(3),int(3)> (kernelContext_9->Render_Uniforms_0->env_x_0.xyz, kernelContext_9->Render_Uniforms_0->env_y_0.xyz, kernelContext_9->Render_Uniforms_0->env_z_0.xyz);

#line 628
    }
    else
    {

#line 628
        _S28 = matrix<float,int(3),int(3)> (kernelContext_9->Render_Uniforms_0->rig_x_0.xyz, kernelContext_9->Render_Uniforms_0->rig_y_0.xyz, kernelContext_9->Render_Uniforms_0->rig_z_0.xyz);

#line 628
    }

#line 628
    return _S28;
}


#line 649
float env_pdf_0(float3 d_6, KernelContext_0 thread* kernelContext_10)
{

#line 649
    matrix<float,int(3),int(3)>  _S29 = env_frame_0(kernelContext_10);
    float3 local_0 = (((transpose(_S29)) * (d_6)));

#line 650
    int2 _S30 = texture_size_0(kernelContext_10->env_table_texture_0, kernelContext_10->env_table_sampler_0);

#line 650
    sampler _S31 = kernelContext_10->env_table_sampler_0;


    float _S32 = local_0.y;

#line 653
    return ((kernelContext_10->env_table_texture_0).read(vec<uint,2>(((_S31)).xy), uint(((_S31)).z))).z / max(sqrt(max(1.0f - _S32 * _S32, 0.0f)), 0.00009999999747379f);
}


#line 199
float3 vertex_0(uint v_0, KernelContext_0 thread* kernelContext_11)
{

#line 200
    uint _S33 = 3U * v_0;

#line 200
    return float3(kernelContext_11->positions_0[_S33], kernelContext_11->positions_0[_S33 + 1U], kernelContext_11->positions_0[_S33 + 2U]);
}

float3 oct_decode_0(float2 e_1)
{

#line 204
    float _S34 = e_1.x;

#line 204
    float _S35 = e_1.y;

#line 204
    float3 _S36 = float3(e_1, 1.0f - abs(_S34) - abs(_S35));

#line 204
    thread float3 v_1 = _S36;
    if((_S36.z) < 0.0f)
    {

#line 205
        float2 _S37 = float2(1.0f)  - abs(e_1.yx);

#line 205
        float _S38;

#line 205
        if(_S34 >= 0.0f)
        {

#line 205
            _S38 = 1.0f;

#line 205
        }
        else
        {

#line 205
            _S38 = -1.0f;

#line 205
        }

#line 205
        float _S39;

#line 205
        if(_S35 >= 0.0f)
        {

#line 205
            _S39 = 1.0f;

#line 205
        }
        else
        {

#line 205
            _S39 = -1.0f;

#line 205
        }

#line 205
        v_1.xy = _S37 * float2(_S38, _S39);

#line 205
    }
    return normalize(v_1);
}



float3 normal_decode_0(uint w_5)
{
    return oct_decode_0(float2(int2(int(w_5 << 16U) >> 16U, int(w_5) >> 16U) & (int2(int(-16)) )) / float2(32767.0f) );
}


float3 vertex_normal_0(uint v_2, KernelContext_0 thread* kernelContext_12)
{

#line 218
    return normal_decode_0(kernelContext_12->attributes_0[v_2]);
}


#line 280
uint2 vertex_paint_0(uint v_3, KernelContext_0 thread* kernelContext_13)
{

#line 281
    uint at_0 = kernelContext_13->Render_Uniforms_0->counts_0.w + 2U * v_3;
    return uint2(kernelContext_13->attributes_0[at_0], kernelContext_13->attributes_0[at_0 + 1U]);
}

float3 srgb_decode_0(float3 c_1)
{

#line 286
    return mix(c_1 / float3(12.92000007629394531f) , pow((c_1 + float3(0.05499999970197678f) ) / float3(1.0549999475479126f) , float3(2.40000009536743164f) ), step(float3(0.04044999927282333f) , c_1));
}


float3 group_color_0(uint g_0)
{

#line 290
    float3 _S40 = float3(3.0f) ;

    float3 _S41 = float3(1.0f) ;

#line 292
    float3 rgb_0 = clamp(abs(fract(float3(fract(float(g_0) * 0.6180340051651001f + 0.11999999731779099f))  + float3(0.0f, 2.0f, 1.0f) / _S40) * float3(6.0f)  - _S40) - float3(1.0f) , float3(0.0f) , _S41);

#line 292
    float light_0;
    if((g_0 & 1U) == 0U)
    {

#line 293
        light_0 = 0.75f;

#line 293
    }
    else
    {

#line 293
        light_0 = 0.55000001192092896f;

#line 293
    }
    return mix(_S41, rgb_0, float3(0.55000001192092896f) ) * float3(light_0) ;
}


#line 223
struct Tex_Vertex_0
{
    float3 n_0;
    float4 t_4;
    float2 uv_1;
};


#line 229
Tex_Vertex_0 tex_vertex_0(uint at_1, KernelContext_0 thread* kernelContext_14)
{

#line 230
    thread Tex_Vertex_0 v_4;
    (&v_4)->n_0 = normal_decode_0(kernelContext_14->textured_0[at_1 + 3U]);
    uint a_1 = kernelContext_14->textured_0[at_1 + 4U];

#line 232
    uint b_2 = kernelContext_14->textured_0[at_1 + 5U];
    (&v_4)->t_4 = max(float4(float(int(a_1 << 16U) >> 16U), float(int(a_1) >> 16U), float(int(b_2 << 16U) >> 16U), float(int(b_2) >> 16U)) / float4(32767.0f) , float4(-1.0f) );
    (&v_4)->uv_1 = float2((as_type<float>((kernelContext_14->textured_0[at_1 + 6U]))), (as_type<float>((kernelContext_14->textured_0[at_1 + 7U]))));
    return v_4;
}


#line 249
float4 map_at_0(uint slot_0, uint kind_0, float2 uv_2, float lod_0, KernelContext_0 thread* kernelContext_15)
{

#line 250
    switch(slot_0 * 3U + kind_0)
    {
    case 0U:
        {

#line 243
            float2 _S42 = float2(texture_size_0(kernelContext_15->map0_texture_0, kernelContext_15->map0_sampler_0));

#line 243
            return ((kernelContext_15->map0_texture_0).sample((kernelContext_15->map0_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S42.x * _S42.y), 0.0f)))));
        }
    case 1U:
        {

#line 243
            float2 _S43 = float2(texture_size_0(kernelContext_15->map1_texture_0, kernelContext_15->map1_sampler_0));

#line 243
            return ((kernelContext_15->map1_texture_0).sample((kernelContext_15->map1_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S43.x * _S43.y), 0.0f)))));
        }
    case 2U:
        {

#line 243
            float2 _S44 = float2(texture_size_0(kernelContext_15->map2_texture_0, kernelContext_15->map2_sampler_0));

#line 243
            return ((kernelContext_15->map2_texture_0).sample((kernelContext_15->map2_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S44.x * _S44.y), 0.0f)))));
        }
    case 3U:
        {

#line 243
            float2 _S45 = float2(texture_size_0(kernelContext_15->map3_texture_0, kernelContext_15->map3_sampler_0));

#line 243
            return ((kernelContext_15->map3_texture_0).sample((kernelContext_15->map3_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S45.x * _S45.y), 0.0f)))));
        }
    case 4U:
        {

#line 243
            float2 _S46 = float2(texture_size_0(kernelContext_15->map4_texture_0, kernelContext_15->map4_sampler_0));

#line 243
            return ((kernelContext_15->map4_texture_0).sample((kernelContext_15->map4_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S46.x * _S46.y), 0.0f)))));
        }
    case 5U:
        {

#line 243
            float2 _S47 = float2(texture_size_0(kernelContext_15->map5_texture_0, kernelContext_15->map5_sampler_0));

#line 243
            return ((kernelContext_15->map5_texture_0).sample((kernelContext_15->map5_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S47.x * _S47.y), 0.0f)))));
        }
    case 6U:
        {

#line 243
            float2 _S48 = float2(texture_size_0(kernelContext_15->map6_texture_0, kernelContext_15->map6_sampler_0));

#line 243
            return ((kernelContext_15->map6_texture_0).sample((kernelContext_15->map6_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S48.x * _S48.y), 0.0f)))));
        }
    case 7U:
        {

#line 243
            float2 _S49 = float2(texture_size_0(kernelContext_15->map7_texture_0, kernelContext_15->map7_sampler_0));

#line 243
            return ((kernelContext_15->map7_texture_0).sample((kernelContext_15->map7_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S49.x * _S49.y), 0.0f)))));
        }
    case 8U:
        {

#line 243
            float2 _S50 = float2(texture_size_0(kernelContext_15->map8_texture_0, kernelContext_15->map8_sampler_0));

#line 243
            return ((kernelContext_15->map8_texture_0).sample((kernelContext_15->map8_sampler_0), (uv_2), level((max(lod_0 + 0.5f * log2(_S50.x * _S50.y), 0.0f)))));
        }
    }

#line 261
    return float4(0.0f) ;
}


#line 4 "common.slang"
float glsl_mod_0(float x_1, float y_0)
{

#line 5
    return x_1 - y_0 * floor(x_1 / y_0);
}


#line 268 "render_trace.slang"
float3 uv_checker_0(float2 uv_3)
{

#line 269
    float2 c_2 = uv_3 * float2(8.0f) ;
    float2 f_0 = fract(c_2);
    float _S51 = f_0.x;

#line 271
    float _S52 = f_0.y;
    float2 cell_0 = floor(c_2);
    float _S53 = cell_0.x;

#line 273
    float _S54 = cell_0.y;

#line 273
    float3 _S55 = float3(3.0f) ;

    float3 _S56 = float3(1.0f) ;

    return mix(_S56, clamp(abs(fract(float3(((_S53 + 0.5f) / 8.0f))  + float3(0.0f, 2.0f, 1.0f) / _S55) * float3(6.0f)  - _S55) - float3(1.0f) , float3(0.0f) , _S56), float3(0.34999999403953552f) ) * float3(mix(0.69999998807907104f, 1.0f, (_S54 + 0.5f) / 8.0f))  * float3(mix(1.0f, 0.72000002861022949f, glsl_mod_0(_S53 + _S54, 2.0f)))  * float3((1.0f - 0.5f * step(min(min(_S51, 1.0f - _S51), min(_S52, 1.0f - _S52)), 0.01499999966472387f))) ;
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


#line 632 "render_trace.slang"
float3 env_sample_0(float thread* pdf_0, KernelContext_0 thread* kernelContext_16)
{

#line 632
    int2 _S57 = texture_size_0(kernelContext_16->env_table_texture_0, kernelContext_16->env_table_sampler_0);

    int _S58 = _S57.x;

#line 634
    int count_0 = _S58 * _S57.y;

#line 634
    float _S59 = rnd_0(kernelContext_16);
    float u_0 = _S59 * float(count_0);
    int _S60 = min(int(u_0), count_0 - int(1));
    int _S61 = _S60 % _S58;

#line 637
    int _S62 = _S60 / _S58;

#line 637
    sampler _S63 = kernelContext_16->env_table_sampler_0;

#line 637
    float4 _S64 = ((kernelContext_16->env_table_texture_0).read(vec<uint,2>(((_S63)).xy), uint(((_S63)).z)));

#line 637
    int i_3;

#line 637
    float4 e_2;
    if((fract(u_0)) >= (_S64.x))
    {

#line 639
        int i_4 = int(_S64.y);
        int _S65 = i_4 % _S58;

#line 640
        int _S66 = i_4 / _S58;

#line 640
        sampler _S67 = kernelContext_16->env_table_sampler_0;

#line 640
        float4 _S68 = ((kernelContext_16->env_table_texture_0).read(vec<uint,2>(((_S67)).xy), uint(((_S67)).z)));

#line 640
        i_3 = i_4;

#line 640
        e_2 = _S68;

#line 638
    }
    else
    {

#line 638
        i_3 = _S60;

#line 638
        e_2 = _S64;

#line 638
    }



    int _S69 = i_3 % _S58;

#line 642
    float _S70 = float(_S69);

#line 642
    int _S71 = i_3 / _S58;

#line 642
    float2 _S72 = float2(_S70, float(_S71));

#line 642
    float _S73 = rnd_0(kernelContext_16);

#line 642
    float _S74 = rnd_0(kernelContext_16);
    float3 local_1 = panorama_dir_0((_S72 + float2(_S73, _S74)) / float2(_S57));
    float _S75 = local_1.y;

#line 644
    *pdf_0 = e_2.z / max(sqrt(max(1.0f - _S75 * _S75, 0.0f)), 0.00009999999747379f);

#line 644
    matrix<float,int(3),int(3)>  _S76 = env_frame_0(kernelContext_16);
    return (((_S76) * (local_1)));
}


#line 496
float ggx_d_0(float n_dot_h_0, float a_2)
{

#line 497
    float a2_0 = a_2 * a_2;
    float d_7 = n_dot_h_0 * n_dot_h_0 * (a2_0 - 1.0f) + 1.0f;
    return a2_0 / (3.14159274101257324f * d_7 * d_7);
}


float ggx_lambda_0(float c_3, float a_3)
{

#line 504
    float _S77 = max(c_3 * c_3, 9.99999993922529029e-09f);
    return 0.5f * (-1.0f + sqrt(1.0f + a_3 * a_3 * (1.0f - _S77) / _S77));
}


#line 492
float3 fresnel_0(float3 f0_0, float c_4)
{

#line 493
    return f0_0 + (float3(1.0f)  - f0_0) * float3(pow(1.0f - clamp(c_4, 0.0f, 1.0f), 5.0f)) ;
}


#line 482
float luminance_0(float3 c_5)
{

#line 483
    return dot(c_5, float3(0.2125999927520752f, 0.71520000696182251f, 0.07220000028610229f));
}

struct Surface_0
{
    float3 diffuse_0;
    float3 f0_1;
    float a_4;
};


#line 510
float specular_chance_0(const Surface_0 thread* s_4, float n_dot_v_0)
{

#line 511
    float3 fv_0 = fresnel_0(s_4->f0_1, n_dot_v_0);
    float es_0 = luminance_0(fv_0);

#line 512
    float ed_0 = luminance_0(s_4->diffuse_0 * (float3(1.0f)  - fv_0));
    if(ed_0 <= 0.0f)
    {

#line 513
        return 1.0f;
    }

#line 514
    return clamp(es_0 / max(es_0 + ed_0, 9.99999997475242708e-07f), 0.05000000074505806f, 0.94999998807907104f);
}



float3 bsdf_eval_0(const Surface_0 thread* s_5, float3 n_1, float3 v_5, float3 l_2, float thread* pdf_1)
{

#line 520
    *pdf_1 = 0.0f;
    float n_dot_l_0 = dot(n_1, l_2);

#line 521
    float n_dot_v_1 = dot(n_1, v_5);

#line 521
    bool _S78;
    if(n_dot_l_0 <= 0.0f)
    {

#line 522
        _S78 = true;

#line 522
    }
    else
    {

#line 522
        _S78 = n_dot_v_1 <= 0.0f;

#line 522
    }

#line 522
    if(_S78)
    {

#line 522
        return float3(0.0f) ;
    }

#line 523
    float3 h_1 = normalize(v_5 + l_2);

    float D_0 = ggx_d_0(max(dot(n_1, h_1), 0.0f), s_5->a_4);


    float _S79 = 1.0f + ggx_lambda_0(n_dot_v_1, s_5->a_4);

#line 528
    float3 spec_0 = fresnel_0(s_5->f0_1, max(dot(v_5, h_1), 0.0f)) * float3((D_0 / ((_S79 + ggx_lambda_0(n_dot_l_0, s_5->a_4)) * 4.0f * n_dot_v_1 * n_dot_l_0))) ;
    float3 diff_0 = s_5->diffuse_0 * (float3(1.0f)  - fresnel_0(s_5->f0_1, n_dot_v_1)) / float3(3.14159274101257324f) ;

#line 529
    float _S80 = specular_chance_0(s_5, n_dot_v_1);



    *pdf_1 = _S80 * (D_0 / (_S79 * 4.0f * n_dot_v_1)) + (1.0f - _S80) * n_dot_l_0 / 3.14159274101257324f;
    return (diff_0 + spec_0) * float3(n_dot_l_0) ;
}


#line 458
float3 offset_ray_0(float3 p_1, float3 n_2)
{


    int3 _S81 = int3(float3(256.0f)  * n_2);

    float _S82 = p_1.x;

#line 464
    int _S83 = (as_type<int>((_S82)));

#line 464
    int _S84;

#line 464
    if(_S82 < 0.0f)
    {

#line 464
        _S84 = - _S81.x;

#line 464
    }
    else
    {

#line 464
        _S84 = _S81.x;

#line 464
    }

#line 464
    float _S85 = (as_type<float>((_S83 + _S84)));
    float _S86 = p_1.y;

#line 465
    int _S87 = (as_type<int>((_S86)));

#line 465
    if(_S86 < 0.0f)
    {

#line 465
        _S84 = - _S81.y;

#line 465
    }
    else
    {

#line 465
        _S84 = _S81.y;

#line 465
    }

#line 465
    float _S88 = (as_type<float>((_S87 + _S84)));
    float _S89 = p_1.z;

#line 466
    int _S90 = (as_type<int>((_S89)));

#line 466
    if(_S89 < 0.0f)
    {

#line 466
        _S84 = - _S81.z;

#line 466
    }
    else
    {

#line 466
        _S84 = _S81.z;

#line 466
    }

#line 466
    float _S91 = (as_type<float>((_S90 + _S84)));

#line 466
    float _S92;

    if((abs(_S82)) < 0.03125f)
    {

#line 468
        _S92 = _S82 + 0.0000152587890625f * n_2.x;

#line 468
    }
    else
    {

#line 468
        _S92 = _S85;

#line 468
    }

#line 468
    float _S93;
    if((abs(_S86)) < 0.03125f)
    {

#line 469
        _S93 = _S86 + 0.0000152587890625f * n_2.y;

#line 469
    }
    else
    {

#line 469
        _S93 = _S88;

#line 469
    }

#line 469
    float _S94;
    if((abs(_S89)) < 0.03125f)
    {

#line 470
        _S94 = _S89 + 0.0000152587890625f * n_2.z;

#line 470
    }
    else
    {

#line 470
        _S94 = _S91;

#line 470
    }

#line 467
    return float3(_S92, _S93, _S94);
}


#line 474
void basis_0(float3 n_3, float3 thread* t_5, float3 thread* b_3)
{

#line 475
    float _S95 = n_3.z;

#line 475
    float s_6;

#line 475
    if(_S95 >= 0.0f)
    {

#line 475
        s_6 = 1.0f;

#line 475
    }
    else
    {

#line 475
        s_6 = -1.0f;

#line 475
    }
    float a_5 = -1.0f / (s_6 + _S95);
    float _S96 = n_3.x;

#line 477
    float _S97 = n_3.y;

#line 477
    float c_6 = _S96 * _S97 * a_5;
    *t_5 = float3(1.0f + s_6 * _S96 * _S96 * a_5, s_6 * c_6, - s_6 * _S96);
    *b_3 = float3(c_6, s_6 + _S97 * _S97 * a_5, - _S97);
    return;
}


#line 571
float3 sample_cone_0(float3 axis_0, float cos_max_1, KernelContext_0 thread* kernelContext_17)
{

#line 572
    thread float3 t_6;

#line 572
    thread float3 b_4;
    basis_0(axis_0, &t_6, &b_4);

#line 573
    float _S98 = rnd_0(kernelContext_17);
    float c_7 = 1.0f - _S98 * (1.0f - cos_max_1);
    float s_7 = sqrt(max(1.0f - c_7 * c_7, 0.0f));

#line 575
    float _S99 = rnd_0(kernelContext_17);

#line 575
    float phi_1 = 6.28318548202514648f * _S99;
    return normalize(t_6 * float3((s_7 * cos(phi_1)))  + b_4 * float3((s_7 * sin(phi_1)))  + axis_0 * float3(c_7) );
}


#line 659
float3 direct_light_0(const Surface_0 thread* s_8, float3 p_2, float3 ng_0, float3 n_4, float3 v_6, KernelContext_0 thread* kernelContext_18)
{

#line 659
    int i_5;

#line 659
    float _S100 = rnd_0(kernelContext_18);

#line 659
    bool _S101;

    if(_S100 < (kernelContext_18->Render_Uniforms_0->env_0.z))
    {

#line 662
        thread float pdf_env_0;

#line 662
        float3 _S102 = env_sample_0(&pdf_env_0, kernelContext_18);

        if((dot(ng_0, _S102)) <= 0.0f)
        {

#line 664
            return float3(0.0f) ;
        }

#line 665
        thread float pdf_bsdf_1;

#line 665
        float3 _S103 = bsdf_eval_0(s_8, n_4, v_6, _S102, &pdf_bsdf_1);

        if((luminance_0(_S103)) <= 0.0f)
        {

#line 667
            return float3(0.0f) ;
        }

#line 667
        float3 _S104 = environment_0(_S102, kernelContext_18);

        float pdf_light_0 = kernelContext_18->Render_Uniforms_0->env_0.z * pdf_env_0;
        if((luminance_0(_S104)) <= 0.0f)
        {

#line 670
            _S101 = true;

#line 670
        }
        else
        {

#line 670
            _S101 = pdf_light_0 <= 0.0f;

#line 670
        }

#line 670
        if(_S101)
        {

#line 670
            return float3(0.0f) ;
        }

#line 671
        thread Hit_0 shadow_0;

#line 671
        bool _S105 = trace_0(offset_ray_0(p_2, ng_0), _S102, 3.00000000549775576e+38f, true, &shadow_0, kernelContext_18);
        if(_S105)
        {

#line 672
            return float3(0.0f) ;
        }

#line 673
        return _S103 * _S104 * float3((power_weight_0(pdf_light_0, pdf_bsdf_1) / pdf_light_0)) ;
    }

#line 673
    int k_1 = int(0);


    for(;;)
    {

#line 676
        if(k_1 < int(8))
        {
        }
        else
        {

#line 676
            i_5 = int(-1);

#line 676
            break;
        }

#line 677
        if((kernelContext_18->Render_Uniforms_0->light_size_0[k_1].w) > 0.0f)
        {

#line 677
            _S101 = _S100 < (kernelContext_18->Render_Uniforms_0->light_size_0[k_1].z);

#line 677
        }
        else
        {

#line 677
            _S101 = false;

#line 677
        }

#line 677
        if(_S101)
        {

#line 677
            i_5 = k_1;

            break;
        }

#line 676
        k_1 = k_1 + int(1);

#line 676
    }

#line 682
    if(i_5 < int(0))
    {

#line 682
        return float3(0.0f) ;
    }

    float3 radiance_3 = kernelContext_18->Render_Uniforms_0->light_color_0[i_5].xyz * float3(kernelContext_18->Render_Uniforms_0->light_size_0[i_5].y) ;

#line 685
    float3 l_3;

#line 685
    float3 radiance_4;

#line 685
    float pdf_dir_1;

#line 685
    float dist_0;
    if((kernelContext_18->Render_Uniforms_0->light_pos_0[i_5].w) < 0.5f)
    {

#line 686
        float3 _S106 = sample_cone_0(kernelContext_18->Render_Uniforms_0->light_pos_0[i_5].xyz, kernelContext_18->Render_Uniforms_0->light_size_0[i_5].x, kernelContext_18);

        float _S107 = cone_pdf_0(kernelContext_18->Render_Uniforms_0->light_size_0[i_5].x);

#line 688
        l_3 = _S106;

#line 688
        pdf_dir_1 = _S107;

#line 688
        dist_0 = 3.00000000549775576e+38f;

#line 688
        radiance_4 = radiance_3;

#line 686
    }
    else
    {

#line 686
        float _S108 = sphere_cone_0(i_5, p_2, kernelContext_18);

#line 691
        if(_S108 > 1.0f)
        {

#line 691
            return float3(0.0f) ;
        }

#line 692
        float3 to_1 = kernelContext_18->Render_Uniforms_0->light_pos_0[i_5].xyz - p_2;
        float3 _S109 = normalize(to_1);

#line 693
        float3 _S110 = sample_cone_0(_S109, _S108, kernelContext_18);
        float _S111 = cone_pdf_0(_S108);
        float dist_1 = sphere_hit_0(p_2, _S110, kernelContext_18->Render_Uniforms_0->light_pos_0[i_5].xyz, kernelContext_18->Render_Uniforms_0->light_size_0[i_5].x);
        if(dist_1 <= 0.0f)
        {

#line 696
            return float3(0.0f) ;
        }

#line 696
        float _S112 = light_falloff_0(i_5, dot(to_1, to_1), _S109, kernelContext_18);
        float3 radiance_5 = radiance_3 * float3(_S112) ;

#line 697
        l_3 = _S110;

#line 697
        pdf_dir_1 = _S111;

#line 697
        dist_0 = dist_1;

#line 697
        radiance_4 = radiance_5;

#line 686
    }

#line 699
    if((dot(ng_0, l_3)) <= 0.0f)
    {

#line 699
        _S101 = true;

#line 699
    }
    else
    {

#line 699
        _S101 = (luminance_0(radiance_4)) <= 0.0f;

#line 699
    }

#line 699
    if(_S101)
    {

#line 699
        return float3(0.0f) ;
    }

#line 700
    thread float pdf_bsdf_2;

#line 700
    float3 _S113 = bsdf_eval_0(s_8, n_4, v_6, l_3, &pdf_bsdf_2);

    if((luminance_0(_S113)) <= 0.0f)
    {

#line 702
        return float3(0.0f) ;
    }

#line 703
    float pdf_light_1 = kernelContext_18->Render_Uniforms_0->light_size_0[i_5].w * pdf_dir_1;
    thread Hit_0 shadow_1;

#line 704
    bool _S114 = trace_0(offset_ray_0(p_2, ng_0), l_3, dist_0, true, &shadow_1, kernelContext_18);
    if(_S114)
    {

#line 705
        return float3(0.0f) ;
    }

#line 706
    return _S113 * radiance_4 * float3((power_weight_0(pdf_light_1, pdf_bsdf_2) / pdf_light_1)) ;
}


#line 538
float3 sample_vndf_0(float3 ve_0, float a_6, float2 u_1)
{

#line 539
    float3 vh_0 = normalize(float3(a_6 * ve_0.x, a_6 * ve_0.y, ve_0.z));
    float _S115 = vh_0.x;

#line 540
    float _S116 = vh_0.y;

#line 540
    float lensq_0 = _S115 * _S115 + _S116 * _S116;

#line 540
    float3 t1_0;
    if(lensq_0 > 0.0f)
    {

#line 541
        t1_0 = float3(- _S116, _S115, 0.0f) * float3(rsqrt(lensq_0)) ;

#line 541
    }
    else
    {

#line 541
        t1_0 = float3(1.0f, 0.0f, 0.0f);

#line 541
    }

    float r_2 = sqrt(u_1.x);

#line 543
    float phi_2 = 6.28318548202514648f * u_1.y;
    float p1_0 = r_2 * cos(phi_2);
    float s_9 = 0.5f * (1.0f + vh_0.z);
    float _S117 = 1.0f - p1_0 * p1_0;

#line 546
    float p2_0 = (1.0f - s_9) * sqrt(max(_S117, 0.0f)) + s_9 * (r_2 * sin(phi_2));
    float3 nh_0 = float3(p1_0)  * t1_0 + float3(p2_0)  * cross(vh_0, t1_0) + float3(sqrt(max(_S117 - p2_0 * p2_0, 0.0f)))  * vh_0;
    return normalize(float3(a_6 * nh_0.x, a_6 * nh_0.y, max(nh_0.z, 0.0f)));
}



bool bsdf_sample_0(const Surface_0 thread* s_10, float3 n_5, float3 v_7, float3 thread* l_4, KernelContext_0 thread* kernelContext_19)
{

#line 554
    thread float3 t_7;

#line 554
    thread float3 b_5;
    basis_0(n_5, &t_7, &b_5);
    float _S118 = max(dot(n_5, v_7), 0.00009999999747379f);

#line 556
    float _S119 = rnd_0(kernelContext_19);

#line 556
    float _S120 = rnd_0(kernelContext_19);
    float2 u_2 = float2(_S119, _S120);

#line 557
    float _S121 = rnd_0(kernelContext_19);

#line 557
    float _S122 = specular_chance_0(s_10, _S118);
    if(_S121 < _S122)
    {
        float3 hl_0 = sample_vndf_0(float3(dot(v_7, t_7), dot(v_7, b_5), dot(v_7, n_5)), s_10->a_4, u_2);

        *l_4 = reflect(- v_7, t_7 * float3(hl_0.x)  + b_5 * float3(hl_0.y)  + n_5 * float3(hl_0.z) );

#line 558
    }
    else
    {



        float r_3 = sqrt(_S119);

#line 564
        float phi_3 = 6.28318548202514648f * _S120;
        *l_4 = normalize(t_7 * float3((r_3 * cos(phi_3)))  + b_5 * float3((r_3 * sin(phi_3)))  + n_5 * float3(sqrt(max(1.0f - _S119, 0.0f))) );

#line 558
    }

#line 567
    return (dot(n_5, *l_4)) > 0.0f;
}


#line 735
[[kernel]] void main_0(uint3 group_id_0 [[threadgroup_position_in_grid]], uint3 local_id_0 [[thread_position_in_threadgroup]], uint3 global_id_0 [[thread_position_in_grid]], texture2d<float, access::sample> prev_texture_1 [[texture(0)]], sampler prev_sampler_1 [[sampler(0)]], SLANG_ParameterGroup_Render_Uniforms_0 constant* Render_Uniforms_1 [[buffer(9)]], metal::raytracing::acceleration_structure<metal::raytracing::instancing> structure_1 [[buffer(0)]], Item_natural_0 device* items_1 [[buffer(7)]], uint device* order_1 [[buffer(5)]], uint device* indices_1 [[buffer(2)]], texture2d<float, access::sample> environment_map_texture_1 [[texture(1)]], sampler environment_map_sampler_1 [[sampler(1)]], texture2d<float, access::sample> env_table_texture_1 [[texture(2)]], sampler env_table_sampler_1 [[sampler(2)]], float device* positions_1 [[buffer(1)]], uint device* attributes_1 [[buffer(3)]], uint device* textured_1 [[buffer(8)]], texture2d<float, access::sample> map0_texture_1 [[texture(5)]], sampler map0_sampler_1 [[sampler(5)]], texture2d<float, access::sample> map1_texture_1 [[texture(6)]], sampler map1_sampler_1 [[sampler(6)]], texture2d<float, access::sample> map2_texture_1 [[texture(7)]], sampler map2_sampler_1 [[sampler(7)]], texture2d<float, access::sample> map3_texture_1 [[texture(8)]], sampler map3_sampler_1 [[sampler(8)]], texture2d<float, access::sample> map4_texture_1 [[texture(9)]], sampler map4_sampler_1 [[sampler(9)]], texture2d<float, access::sample> map5_texture_1 [[texture(10)]], sampler map5_sampler_1 [[sampler(10)]], texture2d<float, access::sample> map6_texture_1 [[texture(11)]], sampler map6_sampler_1 [[sampler(11)]], texture2d<float, access::sample> map7_texture_1 [[texture(12)]], sampler map7_sampler_1 [[sampler(12)]], texture2d<float, access::sample> map8_texture_1 [[texture(13)]], sampler map8_sampler_1 [[sampler(13)]], texture2d<float, access::read_write> next_1 [[texture(14)]], texture2d<float, access::sample> prev_albedo_texture_1 [[texture(3)]], sampler prev_albedo_sampler_1 [[sampler(3)]], texture2d<float, access::sample> prev_normal_texture_1 [[texture(4)]], sampler prev_normal_sampler_1 [[sampler(4)]], texture2d<float, access::read_write> guide_albedo_1 [[texture(15)]], texture2d<float, access::read_write> guide_normal_1 [[texture(16)]])
{

#line 735
    float4 sum_1;

#line 735
    float4 prev_a_0;

#line 735
    thread KernelContext_0 kernelContext_20;

#line 735
    (&kernelContext_20)->prev_texture_0 = prev_texture_1;

#line 735
    (&kernelContext_20)->prev_sampler_0 = prev_sampler_1;

#line 735
    (&kernelContext_20)->Render_Uniforms_0 = Render_Uniforms_1;

#line 735
    (&kernelContext_20)->structure_0 = structure_1;

#line 735
    (&kernelContext_20)->items_0 = items_1;

#line 735
    (&kernelContext_20)->order_0 = order_1;

#line 735
    (&kernelContext_20)->indices_0 = indices_1;

#line 735
    (&kernelContext_20)->environment_map_texture_0 = environment_map_texture_1;

#line 735
    (&kernelContext_20)->environment_map_sampler_0 = environment_map_sampler_1;

#line 735
    (&kernelContext_20)->env_table_texture_0 = env_table_texture_1;

#line 735
    (&kernelContext_20)->env_table_sampler_0 = env_table_sampler_1;

#line 735
    (&kernelContext_20)->positions_0 = positions_1;

#line 735
    (&kernelContext_20)->attributes_0 = attributes_1;

#line 735
    (&kernelContext_20)->textured_0 = textured_1;

#line 735
    (&kernelContext_20)->map0_texture_0 = map0_texture_1;

#line 735
    (&kernelContext_20)->map0_sampler_0 = map0_sampler_1;

#line 735
    (&kernelContext_20)->map1_texture_0 = map1_texture_1;

#line 735
    (&kernelContext_20)->map1_sampler_0 = map1_sampler_1;

#line 735
    (&kernelContext_20)->map2_texture_0 = map2_texture_1;

#line 735
    (&kernelContext_20)->map2_sampler_0 = map2_sampler_1;

#line 735
    (&kernelContext_20)->map3_texture_0 = map3_texture_1;

#line 735
    (&kernelContext_20)->map3_sampler_0 = map3_sampler_1;

#line 735
    (&kernelContext_20)->map4_texture_0 = map4_texture_1;

#line 735
    (&kernelContext_20)->map4_sampler_0 = map4_sampler_1;

#line 735
    (&kernelContext_20)->map5_texture_0 = map5_texture_1;

#line 735
    (&kernelContext_20)->map5_sampler_0 = map5_sampler_1;

#line 735
    (&kernelContext_20)->map6_texture_0 = map6_texture_1;

#line 735
    (&kernelContext_20)->map6_sampler_0 = map6_sampler_1;

#line 735
    (&kernelContext_20)->map7_texture_0 = map7_texture_1;

#line 735
    (&kernelContext_20)->map7_sampler_0 = map7_sampler_1;

#line 735
    (&kernelContext_20)->map8_texture_0 = map8_texture_1;

#line 735
    (&kernelContext_20)->map8_sampler_0 = map8_sampler_1;

#line 735
    (&kernelContext_20)->next_0 = next_1;

#line 735
    (&kernelContext_20)->prev_albedo_texture_0 = prev_albedo_texture_1;

#line 735
    (&kernelContext_20)->prev_albedo_sampler_0 = prev_albedo_sampler_1;

#line 735
    (&kernelContext_20)->prev_normal_texture_0 = prev_normal_texture_1;

#line 735
    (&kernelContext_20)->prev_normal_sampler_0 = prev_normal_sampler_1;

#line 735
    (&kernelContext_20)->guide_albedo_0 = guide_albedo_1;

#line 735
    (&kernelContext_20)->guide_normal_0 = guide_normal_1;

#line 735
    int2 _S123 = texture_size_0(prev_texture_1, prev_sampler_1);

    int _S124 = int(global_id_0.x);

#line 737
    int _S125 = int(global_id_0.y + Render_Uniforms_1->counts_0.y);

#line 737
    int2 px_0 = int2(_S124, _S125);
    int _S126 = _S123.x;

#line 738
    bool _S127;

#line 738
    if(_S124 >= _S126)
    {

#line 738
        _S127 = true;

#line 738
    }
    else
    {

#line 738
        _S127 = _S125 >= (_S123.y);

#line 738
    }

#line 738
    if(_S127)
    {

#line 738
        return;
    }

#line 739
    (&kernelContext_20)->rng_0 = uint(_S125 * _S126 + _S124) * 9781U + Render_Uniforms_1->counts_0.x * 6271U + 1U;

#line 739
    uint _S128 = pcg_next_0(&kernelContext_20);

    (&kernelContext_20)->rng_0 = ((&kernelContext_20)->rng_0) ^ (Render_Uniforms_1->counts_0.x * 2654435761U);

#line 741
    uint _S129 = pcg_next_0(&kernelContext_20);

#line 741
    float _S130 = rnd_0(&kernelContext_20);

#line 741
    float _S131 = rnd_0(&kernelContext_20);

#line 746
    float2 _S132 = float2(_S130, _S131);
    bool first_0 = (Render_Uniforms_1->counts_0.x) == 0U;

#line 747
    float2 jitter_0;
    if(first_0)
    {

#line 748
        jitter_0 = float2(0.5f) ;

#line 748
    }
    else
    {

#line 748
        jitter_0 = _S132;

#line 748
    }
    float2 uv_5 = (float2(px_0) + jitter_0) / float2(_S123);
    float2 ndc_0 = float2(uv_5.x * 2.0f - 1.0f, 1.0f - uv_5.y * 2.0f);
    float4 near_0 = ((((&kernelContext_20)->Render_Uniforms_0->inv_view_proj_0) * (float4(ndc_0, 0.0f, 1.0f))));
    float4 far_0 = ((((&kernelContext_20)->Render_Uniforms_0->inv_view_proj_0) * (float4(ndc_0, 1.0f, 1.0f))));
    float3 o_3 = near_0.xyz / float3(near_0.w) ;
    float3 d_8 = normalize(far_0.xyz / float3(far_0.w)  - o_3);


    float2 ndc_dx_0 = ndc_0 + float2(2.0f / float(_S126), 0.0f);
    float4 near_dx_0 = ((((&kernelContext_20)->Render_Uniforms_0->inv_view_proj_0) * (float4(ndc_dx_0, 0.0f, 1.0f))));
    float4 far_dx_0 = ((((&kernelContext_20)->Render_Uniforms_0->inv_view_proj_0) * (float4(ndc_dx_0, 1.0f, 1.0f))));
    float3 o_dx_0 = near_dx_0.xyz / float3(near_dx_0.w) ;
    float3 _S133 = normalize(far_dx_0.xyz / float3(far_dx_0.w)  - o_dx_0);

#line 767
    bool lens_0 = ((&kernelContext_20)->Render_Uniforms_0->lens_eye_0.w) > 0.0f;

#line 767
    float2 surf_0;

#line 767
    float covered_0;

#line 767
    float covered_1;

#line 767
    float3 o_4;

#line 767
    float3 d_9;
    if(lens_0)
    {

#line 768
        float _S134 = rnd_0(&kernelContext_20);

#line 768
        float _S135 = rnd_0(&kernelContext_20);
        float2 u_3 = float2(2.0f)  * float2(_S134, _S135) - float2(1.0f) ;
        float2 _S136 = float2(0.0f) ;
        if(any(u_3 != _S136))
        {

#line 772
            float _S137 = u_3.x;

#line 772
            float _S138 = u_3.y;

#line 772
            bool wide_0 = (abs(_S137)) > (abs(_S138));
            if(wide_0)
            {

#line 773
                covered_0 = _S137;

#line 773
            }
            else
            {

#line 773
                covered_0 = _S138;

#line 773
            }
            if(wide_0)
            {

#line 774
                covered_1 = 0.78539818525314331f * (_S138 / _S137);

#line 774
            }
            else
            {

#line 774
                covered_1 = 1.57079637050628662f - 0.78539818525314331f * (_S137 / _S138);

#line 774
            }

#line 774
            surf_0 = float2(covered_0)  * float2(cos(covered_1), sin(covered_1));

#line 771
        }
        else
        {

#line 771
            surf_0 = _S136;

#line 771
        }

#line 777
        float3 fwd_0 = (&kernelContext_20)->Render_Uniforms_0->lens_fwd_0.xyz;
        float along_0 = dot(d_8, fwd_0);
        float3 e_3 = o_3 + d_8 * float3((dot((&kernelContext_20)->Render_Uniforms_0->lens_eye_0.xyz - o_3, fwd_0) / along_0)) ;

        float3 from_0 = e_3 + float3((&kernelContext_20)->Render_Uniforms_0->lens_eye_0.w)  * (float3(surf_0.x)  * (&kernelContext_20)->Render_Uniforms_0->lens_right_0.xyz + float3(surf_0.y)  * (&kernelContext_20)->Render_Uniforms_0->lens_up_0.xyz);
        float3 dl_0 = normalize(e_3 + d_8 * float3(((&kernelContext_20)->Render_Uniforms_0->lens_right_0.w / along_0))  - from_0);

#line 782
        o_4 = from_0 + dl_0 * float3((dot(o_3 - from_0, fwd_0) / dot(dl_0, fwd_0))) ;

#line 782
        d_9 = dl_0;

#line 768
    }
    else
    {

#line 768
        o_4 = o_3;

#line 768
        d_9 = d_8;

#line 768
    }

#line 787
    float3 _S139 = float3(0.0f) ;

#line 787
    float3 _S140 = float3(1.0f) ;
    thread float pdf_bsdf_3 = 0.0f;
    float4 _S141 = float4(0.0f) ;
    int _S142 = int(Render_Uniforms_1->counts_0.z);

#line 790
    covered_0 = 0.0f;

#line 790
    float4 guide_a_0 = _S141;

#line 790
    float4 guide_n_0 = _S141;

#line 790
    int bounce_0 = int(0);

#line 790
    float3 weight_0 = _S140;

#line 790
    float3 radiance_6 = _S139;
    for(;;)
    {

#line 791
        if(bounce_0 <= _S142)
        {
        }
        else
        {

#line 791
            break;
        }

#line 792
        thread Hit_0 hit_1;

#line 792
        bool _S143 = trace_0(o_4, d_9, 3.00000000549775576e+38f, false, &hit_1, &kernelContext_20);


        bool _S144 = bounce_0 > int(0);

#line 795
        float3 radiance_7;

#line 795
        if(_S144)
        {

#line 795
            if(_S143)
            {

#line 795
                covered_1 = (&hit_1)->t_0;

#line 795
            }
            else
            {

#line 795
                covered_1 = 3.00000000549775576e+38f;

#line 795
            }

#line 795
            float3 _S145 = lights_met_0(o_4, d_9, covered_1, !_S143, pdf_bsdf_3, &kernelContext_20);

#line 795
            radiance_7 = radiance_6 + weight_0 * _S145;

#line 795
        }
        else
        {

#line 795
            radiance_7 = radiance_6;

#line 795
        }
        if(!_S143)
        {
            if(_S144)
            {

#line 798
                float3 _S146 = environment_0(d_9, &kernelContext_20);

#line 798
                float3 _S147 = weight_0 * _S146;

#line 798
                if(((&kernelContext_20)->Render_Uniforms_0->env_0.z) > 0.0f)
                {

#line 798
                    float _S148 = (&kernelContext_20)->Render_Uniforms_0->env_0.z;

#line 798
                    float _S149 = env_pdf_0(d_9, &kernelContext_20);

#line 798
                    covered_1 = power_weight_0(pdf_bsdf_3, _S148 * _S149);

#line 798
                }
                else
                {

#line 798
                    covered_1 = 1.0f;

#line 798
                }

#line 798
                radiance_6 = radiance_7 + _S147 * float3(covered_1) ;

#line 798
            }
            else
            {

#line 798
                radiance_6 = radiance_7;

#line 798
            }
            break;
        }
        bool _S150 = bounce_0 == int(0);

#line 801
        if(_S150)
        {

#line 801
            covered_1 = 1.0f;

#line 801
        }
        else
        {

#line 801
            covered_1 = covered_0;

#line 801
        }
        if(bounce_0 == _S142)
        {

#line 802
            covered_0 = covered_1;

#line 802
            radiance_6 = radiance_7;

#line 802
            break;
        }
        uint ib_1 = (&kernelContext_20)->indices_0[3U * (&hit_1)->tri_0 + 1U];

#line 804
        uint ic_1 = (&kernelContext_20)->indices_0[3U * (&hit_1)->tri_0 + 2U];
        uint base_0 = (uint4(((&kernelContext_20)->items_0+(&hit_1)->item_1)->offs_0) ).x;

#line 805
        uint flags_0 = (uint4(((&kernelContext_20)->items_0+(&hit_1)->item_1)->offs_0) ).y;

#line 805
        matrix<float,int(4),int(4)>  _S151 = matrix<float,int(4),int(4)> (((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(0)][int(0)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(0)][int(1)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(0)][int(2)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(0)][int(3)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(1)][int(0)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(1)][int(1)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(1)][int(2)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(1)][int(3)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(2)][int(0)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(2)][int(1)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(2)][int(2)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(2)][int(3)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(3)][int(0)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(3)][int(1)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(3)][int(2)], ((&kernelContext_20)->items_0+(&hit_1)->item_1)->model_0.data_0[int(3)][int(3)]);

        float w0_0 = 1.0f - (&hit_1)->uv_0.x - (&hit_1)->uv_0.y;
        uint _S152 = base_0 + (&kernelContext_20)->indices_0[3U * (&hit_1)->tri_0];

#line 808
        float3 _S153 = vertex_0(_S152, &kernelContext_20);

#line 808
        uint _S154 = base_0 + ib_1;

#line 808
        float3 _S155 = vertex_0(_S154, &kernelContext_20);

#line 808
        uint _S156 = base_0 + ic_1;

#line 808
        float3 _S157 = vertex_0(_S156, &kernelContext_20);

#line 808
        float3 _S158 = float3(w0_0) ;
        float3 p_3 = (((_S151) * (float4(_S153 * _S158 + _S155 * float3((&hit_1)->uv_0.x)  + _S157 * float3((&hit_1)->uv_0.y) , 1.0f)))).xyz;
        float3 _S159 = _S155 - _S153;

#line 810
        float3 _S160 = _S157 - _S153;

#line 810
        float3 _S161 = _S151[int(0)].xyz;

#line 810
        matrix<float,int(3),int(3)>  _S162 = matrix<float,int(3),int(3)> (_S161, _S151[int(1)].xyz, _S151[int(2)].xyz);

#line 810
        float3 _S163 = (((_S162) * (cross(_S159, _S160))));

#line 810
        float3 ng_1 = normalize(_S163);

#line 810
        float3 ng_2;
        if((dot(ng_1, d_9)) > 0.0f)
        {

#line 811
            ng_2 = - ng_1;

#line 811
        }
        else
        {

#line 811
            ng_2 = ng_1;

#line 811
        }

#line 811
        float3 _S164 = vertex_normal_0(_S152, &kernelContext_20);
        float3 _S165 = _S164 * _S158;

#line 812
        float3 _S166 = vertex_normal_0(_S154, &kernelContext_20);

#line 812
        float3 _S167 = _S165 + _S166 * float3((&hit_1)->uv_0.x) ;

#line 812
        float3 _S168 = vertex_normal_0(_S156, &kernelContext_20);

#line 812
        float3 n_6 = normalize((((_S162) * (_S167 + _S168 * float3((&hit_1)->uv_0.y) ))));

#line 812
        float3 n_7;
        if((dot(n_6, ng_2)) < 0.0f)
        {

#line 813
            n_7 = - n_6;

#line 813
        }
        else
        {

#line 813
            n_7 = n_6;

#line 813
        }
        float3 v_8 = - d_9;

#line 814
        float3 n_8;

        if((dot(n_7, v_8)) <= 0.0f)
        {

#line 816
            n_8 = ng_2;

#line 816
        }
        else
        {

#line 816
            n_8 = n_7;

#line 816
        }

        float3 _S169 = (float4(((&kernelContext_20)->items_0+(&hit_1)->item_1)->color_0) ).xyz;
        float2 _S170 = (float4(((&kernelContext_20)->items_0+(&hit_1)->item_1)->surface_0) ).xy;

#line 819
        float3 albedo_0;

#line 819
        float3 albedo_1;

#line 819
        float3 mapped_0;
        if((flags_0 & 7U) != 0U)
        {

#line 820
            uint2 _S171 = vertex_paint_0(_S152, &kernelContext_20);

            uint group_0 = (_S171.y) & 65535U;
            if((flags_0 & 4U) != 0U)
            {

#line 823
                surf_0 = _S170;

#line 823
                uint k_2 = 1U;

#line 823
                albedo_0 = _S169;
                for(;;)
                {

#line 824
                    if(k_2 < 16U)
                    {
                    }
                    else
                    {

#line 824
                        break;
                    }

#line 825
                    if(((uint4((&((&kernelContext_20)->items_0+(&hit_1)->item_1)->slot_group_0)->data_1[k_2 >> 2U]) )[k_2 & 3U]) == group_0)
                    {

#line 826
                        float3 _S172 = (float4((&((&kernelContext_20)->items_0+(&hit_1)->item_1)->slot_color_0)->data_2[k_2]) ).xyz;

#line 826
                        surf_0 = (float4((&((&kernelContext_20)->items_0+(&hit_1)->item_1)->slot_surface_0)->data_2[k_2]) ).xy;

#line 826
                        albedo_0 = _S172;

#line 825
                    }

#line 824
                    k_2 = k_2 + 1U;

#line 824
                }

#line 823
            }
            else
            {

#line 823
                surf_0 = _S170;

#line 823
                albedo_0 = _S169;

#line 823
            }

#line 831
            if((flags_0 & 1U) != 0U)
            {

#line 831
                uint2 _S173 = vertex_paint_0(_S152, &kernelContext_20);
                float4 c0_0 = unpack_unorm4x8_to_float(_S173.x);

#line 832
                uint2 _S174 = vertex_paint_0(_S154, &kernelContext_20);
                float4 c1_0 = unpack_unorm4x8_to_float(_S174.x);

#line 833
                uint2 _S175 = vertex_paint_0(_S156, &kernelContext_20);
                float4 c2_0 = unpack_unorm4x8_to_float(_S175.x);
                float4 paint_0 = float4(srgb_decode_0(c0_0.xyz), c0_0.w) * float4(w0_0)  + float4(srgb_decode_0(c1_0.xyz), c1_0.w) * float4((&hit_1)->uv_0.x)  + float4(srgb_decode_0(c2_0.xyz), c2_0.w) * float4((&hit_1)->uv_0.y) ;

#line 835
                albedo_1 = mix(albedo_0, paint_0.xyz, float3(paint_0.w) );

#line 831
            }
            else
            {

#line 831
                albedo_1 = albedo_0;

#line 831
            }

#line 838
            if((flags_0 & 2U) != 0U)
            {

#line 838
                mapped_0 = group_color_0(group_0);

#line 838
            }
            else
            {

#line 838
                mapped_0 = albedo_1;

#line 838
            }

#line 838
            albedo_0 = mapped_0;

#line 820
        }
        else
        {

#line 820
            surf_0 = _S170;

#line 820
            albedo_0 = _S169;

#line 820
        }

#line 820
        float2 surf_1;

#line 820
        float3 n_9;

#line 840
        if((flags_0 & 8U) != 0U)
        {

#line 840
            uint4 _S176 = uint4(((&kernelContext_20)->items_0+(&hit_1)->item_1)->tex_0) ;


            uint at_2 = _S176.y + 3U * ((&hit_1)->tri_0 - _S176.x);
            uint _S177 = _S176.z;

#line 844
            Tex_Vertex_0 _S178 = tex_vertex_0(_S177 + 8U * (&kernelContext_20)->textured_0[at_2], &kernelContext_20);

#line 844
            Tex_Vertex_0 _S179 = tex_vertex_0(_S177 + 8U * (&kernelContext_20)->textured_0[at_2 + 1U], &kernelContext_20);

#line 844
            Tex_Vertex_0 _S180 = tex_vertex_0(_S177 + 8U * (&kernelContext_20)->textured_0[at_2 + 2U], &kernelContext_20);

#line 850
            uint _S181 = _S176.w;

#line 850
            uint slot_1 = _S181 & 15U;

#line 850
            uint view_0 = (_S181 >> 4U) & 15U;

#line 850
            uint maps_0 = _S181 >> 8U;

            float2 uv_up_0 = _S178.uv_1 * float2(w0_0)  + _S179.uv_1 * float2((&hit_1)->uv_0.x)  + _S180.uv_1 * float2((&hit_1)->uv_0.y) ;
            float2 uv_6 = float2(uv_up_0.x, 1.0f - uv_up_0.y);

#line 853
            float lod_1;

#line 858
            if(_S150)
            {
                float2 u1_0 = _S179.uv_1 - _S178.uv_1;

#line 860
                float2 u2_0 = _S180.uv_1 - _S178.uv_1;

#line 860
                lod_1 = log2(max(length(o_dx_0 + _S133 * float3((&hit_1)->t_0)  - p_3) * sqrt(abs(u1_0.x * u2_0.y - u1_0.y * u2_0.x) / max(length(cross((((_S162) * (_S159))), (((_S162) * (_S160))))), 1.00000000317107685e-30f)), 9.999999960041972e-13f));

#line 858
            }
            else
            {

#line 858
                lod_1 = -6.0f;

#line 858
            }

#line 871
            matrix<float,int(3),int(3)>  turn_0 = _S162 / length(_S161);
            float3 nv_0 = (((turn_0) * (_S178.n_0 * _S158 + _S179.n_0 * float3((&hit_1)->uv_0.x)  + _S180.n_0 * float3((&hit_1)->uv_0.y) )));
            float4 tw_0 = _S178.t_4 * float4(w0_0)  + _S179.t_4 * float4((&hit_1)->uv_0.x)  + _S180.t_4 * float4((&hit_1)->uv_0.y) ;
            float3 tv_0 = (((turn_0) * (tw_0.xyz)));
            float3 _S182 = normalize(nv_0);
            bool _S183 = view_0 == 1U;

#line 876
            if(_S183)
            {

#line 876
                _S127 = true;

#line 876
            }
            else
            {

#line 876
                _S127 = view_0 == 2U;

#line 876
            }

#line 876
            bool _S184;

#line 876
            if(_S127)
            {

#line 876
                _S184 = (maps_0 & 4U) != 0U;

#line 876
            }
            else
            {

#line 876
                _S184 = false;

#line 876
            }

#line 876
            if(_S184)
            {

#line 876
                float4 _S185 = map_at_0(slot_1, 2U, uv_6, lod_1, &kernelContext_20);
                float3 tn_0 = _S185.xyz * float3(2.0f)  - float3(1.0f) ;

#line 877
                float _S186;
                if((tw_0.w) < 0.0f)
                {

#line 878
                    _S186 = -1.0f;

#line 878
                }
                else
                {

#line 878
                    _S186 = 1.0f;

#line 878
                }
                float3 m_0 = float3(tn_0.x)  * tv_0 + float3(tn_0.y)  * (float3(_S186)  * cross(nv_0, tv_0)) + float3(tn_0.z)  * nv_0;
                if((dot(m_0, m_0)) > 0.0f)
                {

#line 880
                    albedo_1 = normalize(m_0);

#line 880
                }
                else
                {

#line 880
                    albedo_1 = _S182;

#line 880
                }

#line 876
            }
            else
            {

#line 876
                albedo_1 = _S182;

#line 876
            }

#line 882
            if((dot(_S163, d_9)) > 0.0f)
            {

#line 882
                mapped_0 = - albedo_1;

#line 882
            }
            else
            {

#line 882
                mapped_0 = albedo_1;

#line 882
            }
            if((dot(mapped_0, v_8)) > 0.0f)
            {

#line 883
                n_9 = mapped_0;

#line 883
            }
            else
            {

#line 883
                n_9 = ng_2;

#line 883
            }

#line 889
            float3 r_4 = reflect(- v_8, n_9);
            float under_0 = dot(ng_2, r_4);

#line 890
            float3 n_10;
            if(under_0 < 0.0f)
            {

#line 891
                n_10 = normalize(v_8 + normalize(r_4 - ng_2 * float3((under_0 - 0.00100000004749745f)) ));

#line 891
            }
            else
            {

#line 891
                n_10 = n_9;

#line 891
            }

#line 891
            bool _S187;
            if(_S183)
            {

#line 892
                _S187 = (maps_0 & 1U) != 0U;

#line 892
            }
            else
            {

#line 892
                _S187 = false;

#line 892
            }

#line 892
            float3 albedo_2;

#line 892
            if(_S187)
            {

#line 892
                float3 _S188 = (float4(((&kernelContext_20)->items_0+(&hit_1)->item_1)->color_0) ).xyz;

#line 892
                float4 _S189 = map_at_0(slot_1, 0U, uv_6, lod_1, &kernelContext_20);

#line 892
                albedo_2 = _S188 * _S189.xyz;

#line 892
            }
            else
            {

#line 892
                albedo_2 = albedo_0;

#line 892
            }

#line 892
            bool _S190;
            if(_S183)
            {

#line 893
                _S190 = (maps_0 & 2U) != 0U;

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
                float4 _S191 = map_at_0(slot_1, 1U, uv_6, lod_1, &kernelContext_20);
                float3 orm_0 = _S191.xyz;

#line 894
                surf_1 = float2(orm_0.z, max(orm_0.y, 0.03999999910593033f));

#line 893
            }
            else
            {

#line 893
                surf_1 = surf_0;

#line 893
            }

#line 893
            float3 albedo_3;



            if(view_0 == 3U)
            {

#line 897
                albedo_3 = albedo_2 * uv_checker_0(uv_6);

#line 897
            }
            else
            {

#line 897
                albedo_3 = albedo_2;

#line 897
            }

#line 897
            n_9 = n_10;

#line 897
            albedo_1 = albedo_3;

#line 840
        }
        else
        {

#line 840
            n_9 = n_8;

#line 840
            surf_1 = surf_0;

#line 840
            albedo_1 = albedo_0;

#line 840
        }

#line 899
        if(_S150)
        {
            float4 _S192 = float4(n_9, (&hit_1)->t_0);

#line 901
            sum_1 = float4(albedo_1, 1.0f);

#line 901
            prev_a_0 = _S192;

#line 899
        }
        else
        {

#line 899
            sum_1 = guide_a_0;

#line 899
            prev_a_0 = guide_n_0;

#line 899
        }

#line 904
        float metallic_0 = clamp(surf_1.x, 0.0f, 1.0f);

#line 903
        thread Surface_0 s_11;

        (&s_11)->diffuse_0 = albedo_1 * float3((1.0f - metallic_0)) ;
        (&s_11)->f0_1 = mix(float3(0.03999999910593033f) , albedo_1, float3(metallic_0) );
        float _S193 = surf_1.y;

#line 907
        (&s_11)->a_4 = max(_S193 * _S193, 0.00100000004749745f);

#line 907
        thread Surface_0 _S194 = s_11;

#line 907
        float3 _S195 = direct_light_0(&_S194, p_3, ng_2, n_9, v_8, &kernelContext_20);

        float3 radiance_8 = radiance_7 + weight_0 * _S195;

#line 909
        thread Surface_0 _S196 = s_11;

        thread float3 l_5;

#line 911
        bool _S197 = bsdf_sample_0(&_S196, n_9, v_8, &l_5, &kernelContext_20);
        if(!_S197)
        {

#line 912
            _S127 = true;

#line 912
        }
        else
        {

#line 912
            _S127 = (dot(l_5, ng_2)) <= 0.0f;

#line 912
        }

#line 912
        if(_S127)
        {

#line 912
            covered_0 = covered_1;

#line 912
            guide_a_0 = sum_1;

#line 912
            guide_n_0 = prev_a_0;

#line 912
            radiance_6 = radiance_8;

#line 912
            break;
        }

#line 912
        thread Surface_0 _S198 = s_11;

#line 912
        float3 _S199 = bsdf_eval_0(&_S198, n_9, v_8, l_5, &pdf_bsdf_3);

        if(pdf_bsdf_3 <= 0.0f)
        {

#line 914
            covered_0 = covered_1;

#line 914
            guide_a_0 = sum_1;

#line 914
            guide_n_0 = prev_a_0;

#line 914
            radiance_6 = radiance_8;

#line 914
            break;
        }

#line 915
        float3 weight_1 = weight_0 * (_S199 / float3(pdf_bsdf_3) );
        float3 _S200 = offset_ray_0(p_3, ng_2);
        float3 _S201 = l_5;

        if(bounce_0 >= int(2))
        {

#line 920
            float q_1 = clamp(max(weight_1.x, max(weight_1.y, weight_1.z)), 0.05000000074505806f, 0.94999998807907104f);

#line 920
            float _S202 = rnd_0(&kernelContext_20);
            if(_S202 > q_1)
            {

#line 921
                covered_0 = covered_1;

#line 921
                guide_a_0 = sum_1;

#line 921
                guide_n_0 = prev_a_0;

#line 921
                radiance_6 = radiance_8;

#line 921
                break;
            }

#line 921
            weight_0 = weight_1 / float3(q_1) ;

#line 919
        }
        else
        {

#line 919
            weight_0 = weight_1;

#line 919
        }

#line 791
        int _S203 = bounce_0 + int(1);

#line 791
        o_4 = _S200;

#line 791
        d_9 = _S201;

#line 791
        covered_0 = covered_1;

#line 791
        guide_a_0 = sum_1;

#line 791
        guide_n_0 = prev_a_0;

#line 791
        bounce_0 = _S203;

#line 791
        radiance_6 = radiance_8;

#line 791
    }

#line 925
    float lum_0 = luminance_0(radiance_6);
    if(lum_0 > 16.0f)
    {

#line 926
        radiance_6 = radiance_6 * float3((16.0f / lum_0)) ;

#line 926
    }
    if(first_0)
    {

#line 927
        sum_1 = _S141;

#line 927
    }
    else
    {

#line 927
        sampler _S204 = (&kernelContext_20)->prev_sampler_0;

#line 927
        sum_1 = (((&kernelContext_20)->prev_texture_0).read(vec<uint,2>(((_S204)).xy), uint(((_S204)).z)));

#line 927
    }
    uint2 _S205 = uint2(px_0);

#line 928
    (&kernelContext_20)->next_0.write(sum_1 + float4(radiance_6, covered_0),_S205);
    if(lens_0)
    {

        if(first_0)
        {

#line 932
            prev_a_0 = _S141;

#line 932
        }
        else
        {

#line 932
            sampler _S206 = (&kernelContext_20)->prev_albedo_sampler_0;

#line 932
            prev_a_0 = (((&kernelContext_20)->prev_albedo_texture_0).read(vec<uint,2>(((_S206)).xy), uint(((_S206)).z)));

#line 932
        }

#line 932
        float4 prev_n_0;
        if(first_0)
        {

#line 933
            prev_n_0 = _S141;

#line 933
        }
        else
        {

#line 933
            sampler _S207 = (&kernelContext_20)->prev_normal_sampler_0;

#line 933
            prev_n_0 = (((&kernelContext_20)->prev_normal_texture_0).read(vec<uint,2>(((_S207)).xy), uint(((_S207)).z)));

#line 933
        }
        float done_0 = float(Render_Uniforms_1->counts_0.x);
        float hit_2 = guide_a_0.w;

#line 935
        float hits_before_0 = prev_a_0.w * done_0;
        float hits_0 = hits_before_0 + hit_2;
        if(hits_0 > 0.0f)
        {
            float4 _S208 = (prev_n_0 * float4(hits_before_0)  + guide_n_0 * float4(hit_2) ) / float4(hits_0) ;

#line 939
            guide_a_0 = float4((prev_a_0.xyz * float3(hits_before_0)  + guide_a_0.xyz * float3(hit_2) ) / float3(hits_0) , hits_0 / (done_0 + 1.0f));

#line 939
            guide_n_0 = _S208;

#line 937
        }



        (&kernelContext_20)->guide_albedo_0.write(guide_a_0,_S205);
        (&kernelContext_20)->guide_normal_0.write(guide_n_0,_S205);

#line 929
    }
    else
    {

#line 943
        if(first_0)
        {

#line 944
            (&kernelContext_20)->guide_albedo_0.write(guide_a_0,_S205);
            (&kernelContext_20)->guide_normal_0.write(guide_n_0,_S205);

#line 943
        }

#line 929
    }

#line 947
    return;
}

