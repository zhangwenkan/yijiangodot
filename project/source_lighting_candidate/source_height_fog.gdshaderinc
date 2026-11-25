// UE4.26 HeightFogCommon analytic model with shipping-game component constants.
// Input positions are Godot metres; internal distances stay Unreal centimetres.
// Return vec4(premultiplied inscattering, source_hf_tmp_transmission), NOT Godot FOG convention.
uniform vec3 source_hf_layer0 = vec3(0.002000000095, 0.002000000095, 0.0);
uniform vec3 source_hf_layer1 = vec3(0.00005000000237, 0.0002000000095, 0.0);
uniform vec3 source_hf_color = vec3(0.6239609718,0.7011020184,1.0);
uniform float source_hf_max_opacity = 0.20000000298;
uniform float source_hf_start_cm = 5500.0;
uniform float source_hf_cutoff_cm = 0.0;
uniform float source_hf_max_observer_height_cm = 65536.0;
uniform bool source_hf_directional_enabled = true;
uniform vec3 source_hf_direction = vec3(-0.6946803316,0.5299192642,-0.4864204048);
uniform vec3 source_hf_directional_color = vec3(7.463677883,7.463677883,3.731838942);
uniform float source_hf_directional_exponent = 4.0;
uniform float source_hf_directional_start_cm = 10000.0;
uniform float source_hf_sun_scale = 1.0;

float source_hf_line_integral(float source_hf_tmp_falloff, float source_hf_tmp_dz, float source_hf_tmp_origin_density) {
    float source_hf_tmp_f = max(-127.0, source_hf_tmp_falloff * source_hf_tmp_dz);
    // Avoid evaluating the undefined 0/0 branch; source selects the same Taylor limit.
    float source_hf_tmp_integral = 0.6931471805599453 - 0.2402265069591007 * source_hf_tmp_f;
    if (abs(source_hf_tmp_f) > 0.01) { source_hf_tmp_integral = (1.0-exp2(-source_hf_tmp_f))/source_hf_tmp_f; }
    return source_hf_tmp_origin_density * source_hf_tmp_integral;
}

float source_hf_origin_density(vec3 source_hf_tmp_layer, float source_hf_tmp_height, bool source_hf_tmp_excluded) {
    float source_hf_tmp_exponent = -source_hf_tmp_layer.y * (source_hf_tmp_height-source_hf_tmp_layer.z);
    source_hf_tmp_exponent = source_hf_tmp_excluded ? min(127.0, source_hf_tmp_exponent) : clamp(source_hf_tmp_exponent,-125.0,126.0);
    return source_hf_tmp_layer.x * exp2(source_hf_tmp_exponent);
}

vec3 source_hf_directional(vec3 source_hf_tmp_ray_direction, float source_hf_tmp_optical_depth) {
    if (!source_hf_directional_enabled) { return vec3(0.0); }
    float source_hf_tmp_lobe = pow(clamp(dot(source_hf_tmp_ray_direction,source_hf_direction),0.0,1.0),
        clamp(source_hf_directional_exponent,0.000001,1000.0));
    return source_hf_directional_color * source_hf_sun_scale * source_hf_tmp_lobe
        * (1.0-clamp(exp2(-source_hf_tmp_optical_depth),0.0,1.0));
}

vec4 source_height_fog(vec3 source_hf_tmp_camera_world_m, vec3 source_hf_tmp_receiver_world_m) {
    float source_hf_tmp_observer_height = min(source_hf_tmp_camera_world_m.y*100.0,source_hf_max_observer_height_cm);
    vec3 source_hf_tmp_ray_cm = (source_hf_tmp_receiver_world_m-source_hf_tmp_camera_world_m)*100.0;
    source_hf_tmp_ray_cm.y += source_hf_tmp_camera_world_m.y*100.0-source_hf_tmp_observer_height;
    float source_hf_tmp_original_length = length(source_hf_tmp_ray_cm);
    if (source_hf_tmp_original_length <= max(source_hf_start_cm,0.000001)
        || (source_hf_cutoff_cm > 0.0 && source_hf_tmp_original_length > source_hf_cutoff_cm)) {
        return vec4(0.0,0.0,0.0,1.0);
    }
    vec3 source_hf_tmp_direction = source_hf_tmp_ray_cm / source_hf_tmp_original_length;
    float source_hf_tmp_ray_length = source_hf_tmp_original_length;
    float source_hf_tmp_dz = source_hf_tmp_ray_cm.y;
    bool source_hf_tmp_excluded = source_hf_start_cm > 0.0;
    if (source_hf_tmp_excluded) {
        float source_hf_tmp_exclusion_t = source_hf_start_cm/source_hf_tmp_original_length;
        source_hf_tmp_observer_height += source_hf_tmp_exclusion_t*source_hf_tmp_ray_cm.y;
        source_hf_tmp_ray_length = (1.0-source_hf_tmp_exclusion_t)*source_hf_tmp_original_length;
        source_hf_tmp_dz = (1.0-source_hf_tmp_exclusion_t)*source_hf_tmp_ray_cm.y;
    }
    float source_hf_tmp_shared = source_hf_line_integral(source_hf_layer0.y,source_hf_tmp_dz,
        source_hf_origin_density(source_hf_layer0,source_hf_tmp_observer_height,source_hf_tmp_excluded));
    source_hf_tmp_shared += source_hf_line_integral(source_hf_layer1.y,source_hf_tmp_dz,
        source_hf_origin_density(source_hf_layer1,source_hf_tmp_observer_height,source_hf_tmp_excluded));
    float source_hf_tmp_transmission = max(clamp(exp2(-source_hf_tmp_shared*source_hf_tmp_ray_length),0.0,1.0),1.0-source_hf_max_opacity);
    float source_hf_tmp_directional_depth = source_hf_tmp_shared*max(source_hf_tmp_ray_length-max(source_hf_directional_start_cm,0.0),0.0);
    vec3 source_hf_tmp_rgb = source_hf_color*(1.0-source_hf_tmp_transmission)+source_hf_directional(source_hf_tmp_direction,source_hf_tmp_directional_depth);
    return vec4(source_hf_tmp_rgb,source_hf_tmp_transmission);
}

float source_hf_sky_depth(vec3 source_hf_tmp_layer, float source_hf_tmp_height, float source_hf_tmp_direction_y) {
    if (source_hf_tmp_layer.x <= 0.0) { return 0.0; }
    // Analytic infinite ray, avoiding arbitrary scene-far clipping or density*infinity NaNs.
    if (source_hf_tmp_layer.y*source_hf_tmp_direction_y <= 0.0) { return 1.0e30; }
    return source_hf_origin_density(source_hf_tmp_layer,source_hf_tmp_height,source_hf_start_cm>0.0)/(source_hf_tmp_layer.y*source_hf_tmp_direction_y);
}

vec4 source_height_fog_sky(vec3 source_hf_tmp_camera_world_m, vec3 source_hf_tmp_sky_direction) {
    if (source_hf_cutoff_cm > 0.0) { return vec4(0.0,0.0,0.0,1.0); }
    vec3 source_hf_tmp_direction = normalize(source_hf_tmp_sky_direction);
    float source_hf_tmp_h = min(source_hf_tmp_camera_world_m.y*100.0,source_hf_max_observer_height_cm)
        + max(source_hf_start_cm,0.0)*source_hf_tmp_direction.y;
    float source_hf_tmp_optical_depth = source_hf_sky_depth(source_hf_layer0,source_hf_tmp_h,source_hf_tmp_direction.y)
        + source_hf_sky_depth(source_hf_layer1,source_hf_tmp_h,source_hf_tmp_direction.y);
    float source_hf_tmp_transmission = max(clamp(exp2(-source_hf_tmp_optical_depth),0.0,1.0),1.0-source_hf_max_opacity);
    return vec4(source_hf_color*(1.0-source_hf_tmp_transmission)+source_hf_directional(source_hf_tmp_direction,source_hf_tmp_optical_depth),source_hf_tmp_transmission);
}

vec4 source_height_fog_to_godot(vec4 source_hf_tmp_source_fog, bool source_hf_tmp_attenuate_only) {
    float source_hf_tmp_opacity = clamp(1.0-source_hf_tmp_source_fog.a,0.0,1.0);
    // Godot multiplies FOG.rgb by FOG.a internally. Preserve directional HDR separately
    // from the source_hf_tmp_opacity cap by dividing the entire source premultiplied RGB by source_hf_tmp_opacity.
    return vec4((source_hf_tmp_attenuate_only || source_hf_tmp_opacity<=0.0) ? vec3(0.0) : source_hf_tmp_source_fog.rgb/source_hf_tmp_opacity,source_hf_tmp_opacity);
}
