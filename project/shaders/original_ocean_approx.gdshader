// Material expressions recovered from original M_Ocean DXBC and UE4.27 preshaders.
// UE translucency lighting/tonemapping are still adapted by Godot.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, world_vertex_coords;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D foam_texture : source_color, repeat_enable;
uniform sampler2D edge_foam_texture : repeat_enable;
uniform sampler2D specular_texture : source_color, repeat_enable;
uniform samplerCube reflection_cube;
// Source material vectors are already linear.
uniform vec4 color_shallow = vec4(0.013702,0.132868,0.309469,1.0);
uniform vec4 color_deep = vec4(0.090842,0.496933,0.83077,1.0);
uniform vec3 wave_scales_cm = vec3(8192.0,2048.0,1024.0);
uniform vec3 wave_speeds = vec3(0.1,0.3,0.3);
uniform vec3 wave_intensities = vec3(2.0,1.0,0.5);
uniform float wave_master = 2.0;
uniform vec2 edge_speeds_x = vec2(0.02,0.02);
uniform vec2 edge_tilings = vec2(6.0);
uniform vec2 edge_depths_cm = vec2(0.243425,6.605124);
uniform vec2 edge_depth_scales_cm = vec2(21.457848,16.982763);
uniform vec2 edge_depth_powers = vec2(3.0);
uniform float edge_variance_cm = 7500.0;
uniform float edge_speed = 0.1;
uniform float edge_intensity = 1.5;
uniform vec2 foam_height_offsets_cm = vec2(667.073486,90.0);
uniform vec2 foam_height_scales_cm = vec2(126.689774,100.0);
uniform vec2 foam_depths_cm = vec2(0.0);
uniform vec2 foam_scales_cm = vec2(36.673286,63.218842);
uniform vec2 foam_powers = vec2(299.112885,2.177106);
uniform vec2 foam_speeds = vec2(0.1,0.15);
uniform vec2 foam_variances_cm = vec2(6000.0);
uniform vec2 foam_offsets = vec2(4.0,2.0);
uniform vec2 foam_tilings = vec2(12.0);
uniform float sea_foam_intensity = 0.665643;
uniform float foam_emission_intensity = 2.0;
uniform float reflection_intensity = 0.1;
uniform vec3 fake_spec_power = vec3(10.0,40.0,75.0);
uniform vec3 fake_spec_channel_intensity = vec3(512.0);
uniform float fake_spec_intensity = 0.5;
uniform float fake_spec_scale_cm = 1024.0;
uniform float fake_spec_speed = 0.5;
// Exact cooked MPC_Globals.Vector default. A native runtime writer has not yet
// been recovered; do not silently substitute the scene sun direction.
uniform vec3 source_light_ray = vec3(1.0,0.0,0.0);
uniform float depth_reference_cm = 0.0; // source parameter "01"
uniform float depth_scale_cm = 4260.267578; // "02"
uniform float depth_power = 10.178209; // "03"
uniform float adapter_layer_offset_m = 0.0;
varying vec3 world_pos;
float source_fixed_depth(float floor_y_cm,float reference_cm,float scale_cm,float power_value) {
    return min(pow(clamp((1.0+reference_cm-floor_y_cm)/max(scale_cm,0.00001),0.0,1000.0),power_value),1.0);
}
void vertex() {
    // Original M_Ocean vertex shaders do not displace the mesh. The waves below
    // move depth/foam contours, not geometry or an invented foam-derived normal.
    VERTEX.y += adapter_layer_offset_m;
    world_pos = VERTEX;
}
void fragment() {
    float raw_depth = textureLod(depth_texture,SCREEN_UV,0.0).r;
    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    vec3 ndc = vec3(SCREEN_UV,raw_depth)*2.0-1.0;
    #else
    vec3 ndc = vec3(SCREEN_UV*2.0-1.0,raw_depth);
    #endif
    vec4 scene = INV_PROJECTION_MATRIX*vec4(ndc,1.0);
    vec3 scene_view = scene.xyz/scene.w;
    vec3 floor_world = (INV_VIEW_MATRIX*vec4(scene_view,1.0)).xyz;
    float ray_gap_cm = max((-scene_view.z+VERTEX.z)*100.0,0.0);
    float contact = clamp(ray_gap_cm*0.04,0.0,1.0); // original DepthFade=25cm
    vec3 p = world_pos.xzy*100.0; // UE X/Y/Z centimeters
    float floor_cm = floor_world.y*100.0;
    // The third phase is uniform Constant(0)*speed03 in the cooked preshader.
    vec3 wave_phase = vec3(p.x/wave_scales_cm.x+TIME*wave_speeds.x,
                           p.x/wave_scales_cm.y+TIME*wave_speeds.y,
                           p.y/wave_scales_cm.z)*6.28318530718;
    float wave_height = dot(sin(wave_phase),wave_intensities)*wave_master;
    float motion = sin((p.x/edge_variance_cm+TIME*edge_speed)*6.28318530718);
    float positive_motion = max(motion,0.0);
    float edge_depth_1 = source_fixed_depth(floor_cm,wave_height+edge_depths_cm.x,edge_depth_scales_cm.x,edge_depth_powers.x);
    float edge_depth_2 = source_fixed_depth(floor_cm,wave_height+edge_depths_cm.y,edge_depth_scales_cm.y,edge_depth_powers.y);
    edge_depth_2 = pow(edge_depth_2,(motion+1.0)*0.675+0.65);
    vec4 edge1 = texture(edge_foam_texture,vec2((UV.x+TIME*edge_speeds_x.x)*edge_tilings.x,edge_depth_1));
    vec4 edge2 = texture(edge_foam_texture,vec2((UV.x+TIME*edge_speeds_x.y)*edge_tilings.y,edge_depth_2));
    float coverage_mask = max(edge1.a,edge2.b);
    float edge_foam = edge1.r+pow(edge2.g,1.0+3.0*positive_motion)*pow(1.0-positive_motion,4.0);
    float height_cm = (world_pos.y-NODE_POSITION_WORLD.y)*100.0;
    float foam1 = pow(clamp((height_cm-foam_height_offsets_cm.x)/foam_height_scales_cm.x,0.0,1.0),3.0)
        +1.0-source_fixed_depth(floor_cm,wave_height+foam_depths_cm.x,foam_scales_cm.x,foam_powers.x);
    float foam2 = clamp((height_cm-foam_height_offsets_cm.y)/foam_height_scales_cm.y,0.0,1.0)
        +1.0-source_fixed_depth(floor_cm,wave_height+foam_depths_cm.y,foam_scales_cm.y,foam_powers.y);
    vec2 foam_shift = sin((vec2(p.x)/foam_variances_cm+TIME*foam_speeds)*6.28318530718)*foam_offsets*0.1;
    foam1 *= texture(foam_texture,UV*foam_tilings.x+vec2(0.0,foam_shift.x)).g;
    foam2 *= texture(foam_texture,UV*foam_tilings.y+vec2(0.0,foam_shift.y)).r;
    float foam = (foam1+foam2)*sea_foam_intensity*coverage_mask+edge_foam*edge_intensity;
    vec3 view_world = normalize(CAMERA_POSITION_WORLD-world_pos);
    vec3 normal_world = normalize((INV_VIEW_MATRIX*vec4(NORMAL,0.0)).xyz);
    vec3 reflected = reflect(-view_world,normal_world);
    float facing = 1.0-max(dot(normal_world,view_world),0.0);
    float fresnel5 = 0.04+0.96*pow(facing,5.0);
    float fresnel12 = 0.04+0.96*pow(facing,12.0);
    vec3 reflection = texture(reflection_cube,reflected.xzy).rgb*reflection_intensity*fresnel12;
    vec2 spec_uv = p.xy/max(fake_spec_scale_cm,0.00001);
    float spec_motion = TIME*fake_spec_speed*0.01;
    vec3 sparkle = texture(specular_texture,spec_uv+vec2(spec_motion)).rgb
        *texture(specular_texture,spec_uv*1.5-vec2(spec_motion)).rgb;
    float sun_facing = clamp(dot(reflected,-normalize(source_light_ray)),0.0,1.0);
    vec3 spec_lobes = pow(vec3(sun_facing),fake_spec_power)*fake_spec_channel_intensity;
    float fake_spec = dot(spec_lobes,sparkle)*fake_spec_intensity;
    float depth_factor = source_fixed_depth(floor_cm,depth_reference_cm,depth_scale_cm,depth_power)*fresnel5;
    // In the original PS deep and shallow are intentionally ordered this way.
    ALBEDO = clamp(mix(color_shallow.rgb,color_deep.rgb,depth_factor),vec3(0.0),vec3(1.0));
    EMISSION = (reflection+vec3(foam*foam_emission_intensity+fake_spec))*contact;
    ROUGHNESS = 1.0;
    SPECULAR = 0.0; // original ocean uses explicit cubemap/fake spec, no extra GGX lobe
    ALPHA = clamp(contact*(contact*(0.6+0.9*depth_factor)*coverage_mask+clamp(foam,0.0,1.0)),0.0,1.0);
}
