#include "res://shaders/original_lightfunction_compiled.gdshaderinc"
// UE LightFunctionCommon: perpendicular coordinates are local Z,Y;
// spot projection divides by local X*tan(outer angle). Distances are metres.
uniform int source_lf_count = 0;
uniform bool source_lf_sun_enabled = true;
uniform vec4 source_lf_local_x[24];
uniform vec4 source_lf_local_y[24];
uniform vec4 source_lf_local_z[24];
uniform vec4 source_lf_position_angle[24];
uniform vec4 source_lf_scale_fade[24];
uniform vec4 source_lf_tiling_power[24];
uniform vec4 source_lf_speeds[24];
uniform vec4 source_lf_tree[24];
uniform vec4 source_lf_spot_offsets = vec4(.005,.005,-.005,.005);
uniform vec2 source_lf_spot_sizes = vec2(1.5,1.2);
uniform vec3 source_lf_sun_color = vec3(1.0);
uniform sampler2D source_lf_cloud1 : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D source_lf_cloud2 : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D source_lf_tree2 : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D source_lf_tree3 : source_color, repeat_enable, filter_linear_mipmap;
varying vec3 source_lf_fragment_world;
varying vec3 source_lf_f0;
varying float source_lf_camera_distance;

float source_lf_at(int index) {
    vec4 point = vec4(source_lf_fragment_world,1.0);
    vec3 local = vec3(dot(source_lf_local_x[index],point),dot(source_lf_local_y[index],point),dot(source_lf_local_z[index],point));
    vec2 uv = local.yz / source_lf_scale_fade[index].xy;
    if (index > 0) {
        float along = local.x / source_lf_scale_fade[index].z;
        uv = uv / max(along * source_lf_position_angle[index].w, .00001) * .5 + .5;
    }
    vec4 a = source_lf_tiling_power[index];
    vec4 b = source_lf_speeds[index];
    float value;
    if (index == 0) {
        value = source_lightfunction_cloud(uv, TIME, source_lf_cloud1, source_lf_cloud2,
            source_lf_cloud2, a.xy, b.xy, b.zw, a.z, a.w,
            source_lf_spot_offsets.xy, source_lf_spot_offsets.zw,
            source_lf_spot_sizes.x, source_lf_spot_sizes.y, source_lf_sun_color);
    } else {
        vec4 tree = source_lf_tree[index];
        if (tree.w < 2.5) {
            value = source_lightfunction_tree(uv,TIME,source_lf_tree2,source_lf_cloud1,
                source_lf_cloud2,a.xy,b.xy,b.zw,a.z,a.w,tree.x,tree.y,tree.z);
        } else {
            value = source_lightfunction_tree(uv,TIME,source_lf_tree3,source_lf_cloud1,
                source_lf_cloud2,a.xy,b.xy,b.zw,a.z,a.w,tree.x,tree.y,tree.z);
        }
    }
    float distance_to_camera = source_lf_camera_distance;
    float fade = source_lf_scale_fade[index].w;
    value = mix(.5,value,clamp((fade-distance_to_camera)/max(fade*.2,.00001),0.0,1.0));
    // UE stores the light attenuation in a normalized render target.
    return clamp(value,0.0,1.0);
}

void light() {
    float light_function = 1.0;
    if (source_lf_count > 0) {
        if (LIGHT_IS_DIRECTIONAL) {
            if (source_lf_sun_enabled) { light_function = source_lf_at(0); }
        } else if (ATTENUATION > .00001) {
            // Godot exposes per-light direction, but no light ID to light().
            // Identify the original light using its unique world-space ray.
            vec3 ray = normalize((INV_VIEW_MATRIX * vec4(LIGHT,0.0)).xyz);
            float closest_error = .000001;
            int found = -1;
            for (int i=1; i<source_lf_count; i++) {
                vec3 expected = normalize(source_lf_position_angle[i].xyz-source_lf_fragment_world);
                float error = dot(expected-ray,expected-ray);
                if (error < closest_error) { closest_error=error; found=i; }
            }
            if (found >= 0) { light_function=source_lf_at(found); }
        }
    }
    float nl=max(dot(NORMAL,LIGHT),0.0);
    vec3 radiance=LIGHT_COLOR*ATTENUATION*light_function;

    #ifdef SOURCE_TWO_SIDED_FOLIAGE
    // Native TwoSidedBxDF: Wrap=.5, D_GGX(.6*.6, saturate(-VdotL)).
    // Add as uncolored radiance, since Godot multiplies DIFFUSE_LIGHT by albedo.
    float leaf_wrap=clamp((-dot(NORMAL,LIGHT)+0.5)/2.25,0.0,1.0);
    float leaf_cos=clamp(-dot(VIEW,LIGHT),0.0,1.0);
    float leaf_denominator=leaf_cos*leaf_cos*(0.36-1.0)+1.0;
    float leaf_scatter=0.36/(PI*leaf_denominator*leaf_denominator);
    SPECULAR_LIGHT += radiance*leaf_wrap*leaf_scatter*source_leaf_subsurface;
    #endif
    // UE DefaultLit diffuse is Lambert. Godot applies albedo/(1-metallic)
    // after this light function. Environment and material emission stay separate.
    DIFFUSE_LIGHT += radiance * (nl / PI);
    if (nl > 0.0 && ROUGHNESS > 0.0) {
        vec3 half_direction=normalize(LIGHT+VIEW);
        float nv=max(dot(NORMAL,VIEW),.0001);
        float nh=max(dot(NORMAL,half_direction),0.0);
        float vh=max(dot(VIEW,half_direction),0.0);
        float a=max(ROUGHNESS*ROUGHNESS,.002);
        float a2=a*a;
        float denominator=nh*nh*(a2-1.0)+1.0;
        float distribution=a2/max(PI*denominator*denominator,.000001);
        float visibility=.5/max(nl*sqrt(nv*nv*(1.0-a2)+a2)+nv*sqrt(nl*nl*(1.0-a2)+a2),.0001);
        vec3 fresnel=source_lf_f0+(vec3(1.0)-source_lf_f0)*pow(1.0-vh,5.0);
        SPECULAR_LIGHT += radiance * distribution * visibility * fresnel * nl * SPECULAR_AMOUNT;
    }
}
