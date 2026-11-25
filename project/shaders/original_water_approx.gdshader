// Water_Material math recovered from original DXBC and cooked preshader layout.
// Both source maps have Rain Intensity/Normal Power/Scale=0; dry branch restored.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, world_vertex_coords;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D waves_2_normal : hint_normal, repeat_enable;
uniform sampler2D waves_1_normal : hint_normal, repeat_enable;
uniform sampler2D water_4_normal : hint_normal, repeat_enable;
uniform sampler2D water_3_normal : hint_normal, repeat_enable;
uniform sampler2D water_2_normal : hint_normal, repeat_enable;
uniform sampler2D water_1_normal : hint_normal, repeat_enable;
uniform sampler2D coral_mask : source_color, repeat_enable;
uniform sampler2D foam_1 : source_color, repeat_enable;
uniform sampler2D foam_2 : source_color, repeat_enable;
uniform sampler2D foam_3 : source_color, repeat_enable;
uniform sampler2D foam_4 : source_color, repeat_enable;
uniform sampler2D distortion_1 : source_color, repeat_enable;
uniform sampler2D distortion_2 : source_color, repeat_enable;
uniform sampler2D water_1 : source_color, repeat_enable;
uniform sampler2D water_2 : source_color, repeat_enable;
uniform sampler2D water_3 : source_color, repeat_enable;
uniform sampler2D water_4 : source_color, repeat_enable;
// Already-linear source material vectors. Do not mark these as source_color.
uniform vec4 color_shallow = vec4(0.16513219,1.0,0.9734453,1.0);
uniform vec4 color_deep = vec4(0.05951124,0.50888133,1.0,1.0);
uniform vec4 color_coral = vec4(0.046665,0.73791,0.62396,1.0);
uniform float overall_scale = 0.002229906;
uniform float wave_normal_scale = 8.0;
uniform float wave_normal_speed = 0.1;
uniform float wave_normal_strength = 0.25;
uniform float ocean_normal_scale = 15.0;
uniform float ocean_normal_speed = 0.01;
uniform float ocean_normal_strength = 1.5;
uniform float overall_normal_power = 1.8;
uniform float normal_fresnel_power = 0.2;
uniform float coral_scale = 1.11495;
uniform float coral_contrast = 50.0;
uniform float water_height_cm = 80.08059;
uniform float shore_depth_cm = 307.10745;
uniform float color_spread = 0.8;
uniform float color_smooth = 0.8;
uniform float foam_speed = 0.00125;
uniform float foam_scale = 0.014271398;
uniform float foam_height_cm = 1049.1261;
uniform float foam_blur_cm = 500.0;
uniform float shore_distortion_speed = 0.1125;
uniform float shore_distortion_scale = 0.1114953;
uniform float sea_foam_contrast = 0.5;
uniform float sea_foam_scale = 0.004459812;
uniform float sea_foam_intensity = 1.0;
uniform float source_metallic = 1.0;
uniform float deep_opacity = 2.552762;
uniform float shallow_opacity = 0.0;
uniform float shore_fade_cm = 34.92938;
uniform float surge_divisor = 80.0;
uniform float surge_speed = 0.32;
uniform float surge_height_cm = 0.32;
uniform float deep_ior = 1.1;
uniform float shallow_ior = 1.0;
uniform float refraction_depth_bias_cm = 0.0;
// Source IOR/normal-offset is known; Godot cannot sample already blended ocean
// from its normal screen copy. This optional screen-difference adapter must be
// validated by the integration owner, and is not called a native UE compositor.
uniform bool enable_refraction_adapter = false;
uniform float adapter_layer_offset_m = 0.0;
uniform int audit_view = 0; // 1=depth, 2=tangent normal, 3=alpha, 4=foam, 5=view normal, 6=basis lengths, 7=base color; 8..12=normal diagnostics
// Imported GLBs have UVs and normals but may have no tangent accessor. This
// fallback reconstructs the UV basis from derivatives without altering meshes.
uniform bool force_uv_derivative_basis = false;
varying vec3 world_pos;
vec2 source_uv(vec2 uv,float scale_value) {
    return (uv-vec2(0.5))/max(scale_value,0.000001)+vec2(0.5);
}
vec3 unpack_normal(vec2 raw) {
    vec2 xy = raw*2.0-1.0;
    return vec3(xy,sqrt(max(1.0-dot(xy,xy),0.0)));
}
vec3 depth_view(vec2 uv, mat4 inverse_projection) {
    float raw_depth = textureLod(depth_texture,uv,0.0).r;
    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    vec3 ndc = vec3(uv,raw_depth)*2.0-1.0;
    #else
    vec3 ndc = vec3(uv*2.0-1.0,raw_depth);
    #endif
    vec4 scene = inverse_projection*vec4(ndc,1.0);
    return scene.xyz/scene.w;
}
void vertex() {
    // Source VS: two positive sine components in UE centimeters. Original
    // displacement amplitude is only 0..0.64cm in these maps, not 10cm.
    vec2 phase = (VERTEX.xz*100.0/max(surge_divisor*overall_scale,0.000001)
        +vec2(TIME*surge_speed))*6.28318530718;
    float surge = dot(sin(phase)*0.5+vec2(0.5),vec2(1.0))*surge_height_cm*0.01;
    VERTEX.y += surge+adapter_layer_offset_m;
    world_pos = VERTEX;
}
void fragment() {
    vec2 wave_uv = source_uv(UV,wave_normal_scale*overall_scale);
    vec2 ocean_uv = source_uv(UV,ocean_normal_scale*overall_scale);
    vec2 u_w2 = wave_uv+TIME*wave_normal_speed*vec2(-0.5,0.8);
    vec2 u_w1 = wave_uv+TIME*wave_normal_speed*vec2(0.4,-0.6);
    vec2 u_o4 = ocean_uv+TIME*ocean_normal_speed*vec2(-0.5,1.2);
    vec2 u_o3 = ocean_uv+TIME*ocean_normal_speed*vec2(0.9,-0.6);
    vec2 u_o2 = ocean_uv+TIME*ocean_normal_speed*vec2(-1.2,0.2);
    vec2 u_o1 = ocean_uv+TIME*ocean_normal_speed*vec2(0.8,0.2);
    vec3 w2 = unpack_normal(texture(waves_2_normal,u_w2).rg);
    vec3 w1 = unpack_normal(texture(waves_1_normal,u_w1).rg);
    vec3 n4 = unpack_normal(texture(water_4_normal,u_o4).rg);
    vec3 n3 = unpack_normal(texture(water_3_normal,u_o3).rg);
    vec3 n2 = unpack_normal(texture(water_2_normal,u_o2).rg);
    vec3 n1 = unpack_normal(texture(water_1_normal,u_o1).rg);
    vec3 flat_normal = normalize(NORMAL);
    float facing = 1.0-max(dot(flat_normal,VIEW),0.0);
    float fresnel = 0.04+0.96*pow(facing,5.0);
    float normal_fade = pow(1.0-fresnel,2.0)*normal_fresnel_power;
    vec2 nxy = ((w1.xy+w2.xy)*wave_normal_strength
        +(n1.xy+n2.xy+n3.xy+n4.xy)*ocean_normal_strength)*overall_normal_power*normal_fade;
    vec3 tangent_normal = normalize(vec3(nxy,w1.z*w2.z*n1.z*n2.z*n3.z*n4.z));
    vec3 tangent_basis = TANGENT;
    vec3 binormal_basis = BINORMAL;
    vec2 imported_basis_lengths = vec2(length(tangent_basis),length(binormal_basis));
    if (force_uv_derivative_basis || min(imported_basis_lengths.x,imported_basis_lengths.y)<0.1) {
        vec3 dpdx = dFdx(VERTEX);
        vec3 dpdy = dFdy(VERTEX);
        vec2 dudx = dFdx(UV);
        vec2 dudy = dFdy(UV);
        float uv_determinant = dudx.x*dudy.y-dudx.y*dudy.x;
        if (abs(uv_determinant)>0.000000000001) {
            tangent_basis = normalize((dpdx*dudy.y-dpdy*dudx.y)/uv_determinant);
            binormal_basis = normalize((dpdy*dudx.x-dpdx*dudy.x)/uv_determinant);
        }
    }
    NORMAL = normalize(tangent_basis*tangent_normal.x+binormal_basis*tangent_normal.y+flat_normal*tangent_normal.z);
    vec3 scene_view = depth_view(SCREEN_UV, INV_PROJECTION_MATRIX);
    vec3 floor_world = (INV_VIEW_MATRIX*vec4(scene_view,1.0)).xyz;
    float floor_cm = floor_world.y*100.0;
    float ray_gap_cm = max((-scene_view.z+VERTEX.z)*100.0,0.0);
    float source_depth = (1.0+water_height_cm-floor_cm)/max(shore_depth_cm,0.00001);
    float depth01 = clamp(source_depth,0.0,1.0);
    float coral = texture(coral_mask,source_uv(UV,coral_scale)).r;
    coral = clamp(coral*(2.0*coral_contrast+1.0)-coral_contrast,0.0,1.0);
    vec3 deep_color = mix(color_deep.rgb,color_coral.rgb,coral);
    vec3 base_color = mix(color_shallow.rgb,deep_color,
        clamp((source_depth-color_spread)/max(color_smooth,0.00001),0.0,1.0));
    vec2 fbase = source_uv(UV,foam_scale);
    vec3 f1 = texture(foam_1,fbase+TIME*foam_speed/foam_scale*vec2(0.3,-0.7)).rgb;
    vec3 f2 = texture(foam_2,fbase+TIME*foam_speed/foam_scale*vec2(-0.3,0.5)).rgb;
    vec3 f3 = texture(foam_3,fbase+TIME*foam_speed/foam_scale*vec2(-0.6,-0.3)).rgb;
    vec3 f4 = texture(foam_4,fbase+TIME*foam_speed/foam_scale*vec2(0.5,0.3)).rgb;
    vec3 foam_color = clamp(f1*f2+f3*f4,vec3(0.0),vec3(1.0));
    vec2 dbase = source_uv(UV,shore_distortion_scale);
    vec3 d1 = texture(distortion_1,dbase+TIME*shore_distortion_speed*vec2(0.08,-0.12)).rgb;
    vec3 d2 = texture(distortion_2,dbase+TIME*shore_distortion_speed*vec2(-0.24,0.18)).rgb;
    vec3 shore = clamp(vec3((floor_cm-foam_height_cm)/max(foam_blur_cm,0.00001))+(d1+d2)*0.5-vec3(0.5),vec3(0.0),vec3(1.0));
    float ocean_mask = clamp(texture(water_1,u_o1).r*texture(water_2,u_o2).r
        +texture(water_3,u_o3).r*texture(water_4,u_o4).r,0.0,1.0);
    ocean_mask = clamp(ocean_mask*(2.0*sea_foam_contrast+1.0)-sea_foam_contrast,0.0,1.0);
    vec2 sea_uv = source_uv(UV,sea_foam_scale);
    vec3 sea1 = texture(distortion_1,sea_uv+TIME*foam_speed*2.5/sea_foam_scale*vec2(0.1,-0.2)).rgb;
    vec3 sea2 = texture(distortion_1,sea_uv+TIME*foam_speed*2.5/sea_foam_scale*vec2(-0.2,0.4)).rgb;
    vec3 foam_mask = shore+clamp(sea1*sea2,vec3(0.0),vec3(1.0))*ocean_mask*sea_foam_intensity;
    ALBEDO = clamp(mix(base_color,foam_color,foam_mask),vec3(0.0),vec3(1.0));
    METALLIC = clamp(source_metallic-foam_mask.r,0.0,1.0);
    // Water_Material PS43996 reads View.RoughnessOverrideParameter.x only:
    // ordinary game view (0,1) means original material roughness is zero.
    ROUGHNESS = 0.0;
    SPECULAR = 0.5;
    float raw_opacity = mix(shallow_opacity,deep_opacity,depth01);
    float shore_fade = clamp(ray_gap_cm/max(shore_fade_cm,0.00001),0.0,1.0);
    float surface_alpha = clamp(raw_opacity*shore_fade,0.0,1.0);
    ALPHA = surface_alpha;
    if (enable_refraction_adapter) {
        // Original distortion material: IOR from unsaturated opacity, faded to
        // 1 at contact, and perturbed-normal minus vertex-normal in view space.
        float ior = mix(1.0,mix(shallow_ior,deep_ior,raw_opacity),shore_fade);
        vec2 offset = (flat_normal.xy-NORMAL.xy)*(ior-1.0)*vec2(0.000230,-0.000230);
        vec2 target_uv = clamp(SCREEN_UV+offset,vec2(0.0),vec2(1.0));
        float target_gap_cm = max((-depth_view(target_uv, INV_PROJECTION_MATRIX).z+VERTEX.z)*100.0,0.0);
        float bias_scale = 1.0/clamp(abs(refraction_depth_bias_cm*0.5),1.0,50.0);
        offset *= clamp(target_gap_cm*bias_scale-refraction_depth_bias_cm,0.0,1.0);
        vec3 undistorted = textureLod(screen_texture,SCREEN_UV,0.0).rgb;
        vec3 refracted = textureLod(screen_texture,clamp(SCREEN_UV+offset,vec2(0.0),vec2(1.0)),0.0).rgb;
        EMISSION += (refracted-undistorted)*(1.0-surface_alpha)/max(surface_alpha,0.0001);
    }
    if (audit_view != 0) {
        vec3 value = vec3(depth01);
        if (audit_view == 2) { value = tangent_normal*0.5+vec3(0.5); }
        if (audit_view == 3) { value = vec3(surface_alpha); }
        if (audit_view == 4) { value = clamp(foam_mask,vec3(0.0),vec3(1.0)); }
        if (audit_view == 5) { value = NORMAL*0.5+vec3(0.5); }
        if (audit_view == 6) { value = vec3(imported_basis_lengths,0.0); }
        if (audit_view == 7) { value = ALBEDO; }
        if (audit_view == 8) { value = vec3(normal_fade/max(normal_fresnel_power,0.000001)); }
        if (audit_view == 9) { value = vec3(clamp(n1.xy*2.0+vec2(0.5),vec2(0.0),vec2(1.0)),0.5); }
        if (audit_view == 10) { value = vec3(clamp(tangent_normal.xy*5.0+vec2(0.5),vec2(0.0),vec2(1.0)),0.5); }
        if (audit_view == 11) { value = vec3(clamp(((w1.xy+w2.xy)*wave_normal_strength+(n1.xy+n2.xy+n3.xy+n4.xy)*ocean_normal_strength)*overall_normal_power+vec2(0.5),vec2(0.0),vec2(1.0)),0.5); }
        if (audit_view == 12) { value = vec3(max(dot(flat_normal,VIEW),0.0)); }
        ALBEDO = vec3(0.0); EMISSION = value; METALLIC = 0.0; SPECULAR = 0.0; ALPHA = 1.0;
    }
}
