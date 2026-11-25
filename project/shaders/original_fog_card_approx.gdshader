// M_FogSheet_Master: recovered cooked PS 10107 / UE4.27 material uniform preshaders.
// Authored mesh, placement and UVs remain unchanged. No WPO in the source VS.
// Renderer adapters: Godot depth reconstruction, texture derivatives and atmospheric fog.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Original PF_DXT1 data includes ten native mips; the ray projection explicitly samples mip 4.
uniform sampler2D noise_texture : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
// This is already-linear FLinearColor, including the Blueprint brightness multiplier.
uniform vec4 fog_color = vec4(1.0);
uniform float max_opacity = 0.5;
uniform float noise_size_cm = 2048.0;
uniform float projection_distance_cm = 2048.0;
uniform float depth_fade_cm = 1024.0;
uniform float fade_distance_min_cm = 256.0;
uniform float fade_distance_cm = 1024.0;
uniform float panning_speed = 0.01;
uniform vec2 direction = vec2(-1.0, 0.0);
// UE's global texture mip bias is a renderer setting, not an authored FogSheet parameter.
uniform float texture_mip_bias = 0.0;
uniform int audit_view = 0;

varying vec3 source_world_cm;
varying vec3 source_vertex_normal;

vec2 source_normal_masked_uv(vec3 point_cm, vec3 abs_normal) {
    vec3 inv_normal = vec3(1.0) - abs_normal;
    vec3 scaled = point_cm / max(noise_size_cm, 0.00001) * inv_normal;
    return vec2(scaled.x + scaled.y * inv_normal.z,
                scaled.z + scaled.y * abs_normal.z);
}

void vertex() {
    // Import basis: UE (X,Y,Z) cm -> Godot (X,Z,Y) meters.
    source_world_cm = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xzy * 100.0;
    source_vertex_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL).xzy;
}

void fragment() {
    vec3 camera_cm = INV_VIEW_MATRIX[3].xzy * 100.0;
    vec3 to_camera = normalize(camera_cm - source_world_cm);
    vec3 unflipped_normal = normalize(source_vertex_normal);
    vec3 abs_normal = abs(unflipped_normal);

    // ML_Raycast uses a coarse sample to offset the projection away from the camera.
    float coarse_noise = textureLod(noise_texture,
        source_normal_masked_uv(source_world_cm, abs_normal), 4.0 + texture_mip_bias).r;
    float ray_offset_cm = -0.25 * mix(projection_distance_cm * 0.5,
                                     projection_distance_cm, 1.0 - coarse_noise);
    vec3 projected_cm = source_world_cm + ray_offset_cm * to_camera;
    vec2 moving_uv = source_normal_masked_uv(projected_cm, abs_normal)
                   + TIME * panning_speed * direction;
    float moving_noise = texture(noise_texture, moving_uv, texture_mip_bias).r;

    // Original RadialGradient is linear in radius, with noise modulating its exponent.
    float radial = max(1.0 - 2.0 * length(UV - vec2(0.5)), 0.0);
    float outline = pow(radial, 1.0 + 7.0 * moving_noise);
    float pixel_depth_cm = max(-VERTEX.z * 100.0, 0.0);
    float distance_after_min = min(max(pixel_depth_cm - fade_distance_min_cm, 0.0), pixel_depth_cm);
    float near_fade = 1.0 - clamp((1.0 - abs(distance_after_min)
        / max(fade_distance_cm, 0.00001)) * 1.111111, 0.0, 1.0);
    vec3 facing_normal = FRONT_FACING ? unflipped_normal : -unflipped_normal;
    float facing = min(max(dot(facing_normal, to_camera), 0.0), 0.9999);

    float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    vec3 ndc = vec3(SCREEN_UV, raw_depth) * 2.0 - 1.0;
    #else
    vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
    #endif
    vec4 scene = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
    float ray_gap_cm = (-scene.z / scene.w + VERTEX.z) * 100.0;
    float varying_contact_cm = max(mix(depth_fade_cm * 0.5, depth_fade_cm, moving_noise), 0.00001);
    float contact = clamp(ray_gap_cm / varying_contact_cm, 0.0, 1.0);
    float opacity = clamp(near_fade * outline * max_opacity * facing * contact, 0.0, 1.0);

    ALBEDO = max(fog_color.rgb, vec3(0.0));
    ALPHA = opacity;
    if (audit_view == 1) { ALBEDO = vec3(moving_noise); ALPHA = 1.0; }
    if (audit_view == 2) { ALBEDO = vec3(outline, near_fade, contact); ALPHA = 1.0; }
    if (audit_view == 3) { ALBEDO = vec3(facing); ALPHA = 1.0; }
}
