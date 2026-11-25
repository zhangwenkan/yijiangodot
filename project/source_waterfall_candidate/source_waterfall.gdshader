// Original M_Waterfall / MI_Waterfall2, source DXBC PS63033 VS124491 DS61684.
// Material expressions and original texture payloads; Godot lighting/compositor remain adapters.
// Existing vertex animation only. No PN subdivision or new mesh geometry is produced here.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, world_vertex_coords;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D source_water_d : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D source_water_n : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
// Source linear vector, not sRGB UI color.
uniform vec3 source_waterfall_color = vec3(0.23787300288677216, 0.7249230146408081, 1.0);
uniform float color_opacity = 8.203047752380371;
uniform float fade_distance_color_cm = 13.0;
uniform float depth_contribution = 0.05000000074505806;
uniform float foam_distance_cm = 400.0;
uniform float foam_scalar = 2.5;
uniform float fade_distance_cm = 30.0;
uniform float normal_size = 2.0;
uniform float foam_speed = 4.0;
uniform float scale_uvs = 0.30000001192092896;
uniform float displacement_power_cm = 15.0;
uniform bool source_displacement_enabled = true;
// Negative uses engine TIME. Nonnegative is solely a reproducible audit clock.
uniform float source_time_override = -1.0;
uniform int audit_view = 0; // 1=base color 2=alpha 3=tangent normal 4=foam texture 5=ray gap
varying vec2 source_normal_uv_a;
varying vec2 source_flow_uv;
varying float source_vertex_alpha;

float source_clock(float engine_time) {
    return source_time_override < 0.0 ? engine_time : source_time_override;
}
vec3 source_unpack_normal(vec2 raw) {
    vec2 xy = raw * 2.0 - vec2(1.0);
    return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
}
vec3 source_depth_view(vec2 uv, mat4 inverse_projection) {
    float raw_depth = textureLod(depth_texture, uv, 0.0).r;
    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    vec3 ndc = vec3(uv, raw_depth) * 2.0 - 1.0;
    #else
    vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
    #endif
    vec4 point = inverse_projection * vec4(ndc, 1.0);
    return point.xyz / point.w;
}
void vertex() {
    float t = source_clock(TIME);
    source_normal_uv_a = UV * (2.0 * normal_size) + t * vec2(0.017699, -0.204646);
    source_flow_uv = UV * (2.0 * scale_uvs) + vec2(0.0, t * foam_speed * -0.03);
    source_vertex_alpha = COLOR.a;
    if (source_displacement_enabled) {
        // DS61684 samples T_Water_D alpha at LOD -1 (clamped to original mip0).
        // Source WorldDisplacement is a scalar splat to XYZ, NOT along the normal.
        // UE(X,Y,Z) -> Godot(X,Z,Y) preserves that equal-axis direction.
        float d = textureLod(source_water_d, source_flow_uv * vec2(2.0, 1.0), 0.0).a;
        VERTEX += vec3(d * displacement_power_cm * 0.01);
    }
}
void fragment() {
    vec3 a = source_unpack_normal(texture(source_water_n, source_normal_uv_a).rg);
    vec3 b = source_unpack_normal(texture(source_water_n, source_flow_uv).rg);
    vec3 tangent_normal = normalize(a + b);
    // Godot cull_disabled already flips NORMAL before user fragment code,
    // but leaves tangent/binormal unchanged. Undo that before the UE full-TBN sign.
    float face_sign = FRONT_FACING ? 1.0 : -1.0;
    vec3 flat_normal = normalize(NORMAL) * face_sign;
    vec3 tangent_basis = TANGENT;
    vec3 binormal_basis = BINORMAL;
    // The source glTF has tangents but the current Blender GLB omitted them.
    // Recover the original UV directions locally; no mesh attributes are rewritten.
    if (min(length(tangent_basis), length(binormal_basis)) < 0.1) {
        vec3 dpdx = dFdx(VERTEX);
        vec3 dpdy = dFdy(VERTEX);
        vec2 dudx = dFdx(UV);
        vec2 dudy = dFdy(UV);
        float determinant = dudx.x * dudy.y - dudx.y * dudy.x;
        if (abs(determinant) > 0.000000000001) {
            tangent_basis = normalize((dpdx * dudy.y - dpdy * dudx.y) / determinant);
            binormal_basis = normalize((dpdy * dudx.x - dpdx * dudy.x) / determinant);
        }
    }
    vec3 mapped_normal = normalize(tangent_basis * tangent_normal.x + binormal_basis * tangent_normal.y + flat_normal * tangent_normal.z);
    NORMAL = mapped_normal * face_sign;
    vec3 scene_view = source_depth_view(SCREEN_UV, INV_PROJECTION_MATRIX);
    float ray_gap_cm = max((-scene_view.z + VERTEX.z) * 100.0, 0.0);
    float color_fade = clamp(ray_gap_cm / max(fade_distance_color_cm, 0.00001), 0.0, 1.0) * color_opacity;
    vec3 tint = source_waterfall_color * mix(color_fade, 1.0, depth_contribution);
    vec3 original_foam = texture(source_water_d, source_flow_uv * vec2(2.0, 1.0)).rgb;
    vec3 foam = original_foam * clamp(ray_gap_cm / max(foam_distance_cm, 0.00001), 0.0, 1.0) * foam_scalar;
    ALBEDO = clamp(tint * foam, vec3(0.0), vec3(1.0));
    METALLIC = 0.0;
    ROUGHNESS = 0.0;
    SPECULAR = 0.5;
    ALPHA = clamp(clamp(ray_gap_cm / max(fade_distance_cm, 0.00001), 0.0, 1.0) * source_vertex_alpha * 0.9, 0.0, 1.0);
    EMISSION = vec3(0.0); // Native SelectionColor.rgb * SelectionColor.a = zero in game.
    if (audit_view != 0) {
        vec3 value = ALBEDO;
        if (audit_view == 2) { value = vec3(ALPHA); }
        if (audit_view == 3) { value = tangent_normal * 0.5 + vec3(0.5); }
        if (audit_view == 4) { value = original_foam; }
        if (audit_view == 5) { value = vec3(clamp(ray_gap_cm / 400.0, 0.0, 1.0)); }
        ALBEDO = vec3(0.0);
        EMISSION = value;
    }
}

