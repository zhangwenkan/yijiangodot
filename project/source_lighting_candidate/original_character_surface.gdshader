shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_lambert, specular_schlick_ggx;
#include "res://shaders/original_lightfunction_receiving.gdshaderinc"

uniform sampler2D source_character_atlas : source_color, filter_nearest, repeat_disable;
uniform float source_character_metallic = 0.699999988079071;
uniform float source_character_roughness = 1.0;
uniform float source_character_tick_time = 0.0;
uniform vec4 source_character_blend_color = vec4(1.0);
uniform vec4 source_character_selection_color = vec4(0.0);
uniform float source_character_mask_y_offset = 1.0;
uniform int source_character_temporal_frame = 0;

void vertex() {
    // Same fixed-Y billboard and keep-scale transform as Godot SpriteBase3D's
    // generated material. Existing Sprite geometry, UVs, pivot and frames stay.
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
        vec4(normalize(cross(vec3(0.0,1.0,0.0),MAIN_CAM_INV_VIEW_MATRIX[2].xyz)),0.0),
        vec4(0.0,1.0,0.0,0.0),
        vec4(normalize(cross(MAIN_CAM_INV_VIEW_MATRIX[0].xyz,vec3(0.0,1.0,0.0))),0.0),
        MODEL_MATRIX[3]);
    MODELVIEW_MATRIX *= mat4(
        vec4(length(MODEL_MATRIX[0].xyz),0.0,0.0,0.0),
        vec4(0.0,length(MODEL_MATRIX[1].xyz),0.0,0.0),
        vec4(0.0,0.0,length(MODEL_MATRIX[2].xyz),0.0),
        vec4(0.0,0.0,0.0,1.0));
    MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
    source_lf_fragment_world = (INV_VIEW_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
    source_lf_camera_distance = distance(source_lf_fragment_world,MAIN_CAM_INV_VIEW_MATRIX[3].xyz);
}

void fragment() {
    vec4 sample_color = texture(source_character_atlas,UV) * COLOR;
    float blend_amount = (1.0 + sin((source_character_tick_time + 0.75) * 6.2831854820251465)) * 0.5;
    ALBEDO = clamp(mix(sample_color.rgb,sample_color.rgb * source_character_blend_color.rgb * 0.2,blend_amount),vec3(0.0),vec3(1.0));
    METALLIC = clamp(source_character_metallic,0.0,1.0);
    ROUGHNESS = clamp(source_character_roughness,0.0,1.0);
    SPECULAR = 0.5;
    source_lf_f0 = mix(vec3(0.04),ALBEDO,METALLIC);
    EMISSION = max(source_character_selection_color.rgb * source_character_selection_color.a,vec3(0.0));
    // Source samples a flat placeholder normal map unless a sprite supplies an
    // additional texture; current original hero has no additional texture.
    if (!FRONT_FACING) NORMAL = -NORMAL;
    // Cooked shader uses v3.y for both atlas sampling and the fade. Preserve
    // the atlas-global Y coordinate instead of remapping to a frame-local UV.
    float raised_y = max(UV.y+source_character_mask_y_offset,0.0);
    float mask = mix(pow(raised_y,4.0)*sample_color.a,sample_color.a,floor(clamp(source_character_mask_y_offset,0.0,1.0)));
    // Original DitherTemporalAA five-value pattern. With binary source atlas
    // alpha and MaskYOffset=1, this is identical to the source silhouette.
    uvec2 pixel = uvec2(FRAGCOORD.xy + float(source_character_temporal_frame));
    float dither = float((pixel.x + 2u*pixel.y) % 5u) * 0.16666667;
    if (mask + dither - 0.8333 < 0.0) discard;
}
