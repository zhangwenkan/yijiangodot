shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;
uniform sampler2D source_ambient_atlas : source_color, filter_nearest, repeat_disable;
uniform bool source_ambient_fixed_y = false;
void vertex() {
    if (source_ambient_fixed_y) {
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
    }
}
void fragment() {
    // Paper2D DefaultSpriteMaterial cooked PS78674: sprite*vertex color,
    // masked alpha .3333, unlit emission, no JH EmissiveStr multiplier.
    vec4 sample_color=texture(source_ambient_atlas,UV)*COLOR;
    if (sample_color.a-0.33329999446868896<0.0) discard;
    // Godot MODE_UNSHADED returns ALBEDO; EMISSION alone is ignored.
    ALBEDO=max(sample_color.rgb,vec3(0.0));
}
