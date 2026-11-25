shader_type sky;
// RGBA16F capture is already linear and already in Godot cube coordinates.
uniform samplerCube source_scene_capture : filter_linear;
// This pre-existing visible background is still an Unreal-axis cubemap.
uniform samplerCube source_open_sky : filter_linear;
// Supply FColor(255,219,195).srgb_to_linear() * original Intensity(1.1).
// No source_color annotation: this vector has already been decoded once.
uniform vec3 source_skylight_linear_gain = vec3(1.1,0.779213358,0.600296908);
void sky() {
    if (AT_CUBEMAP_PASS) {
        COLOR = texture(source_scene_capture,EYEDIR).rgb * source_skylight_linear_gain;
    } else {
        vec3 ue_direction=vec3(EYEDIR.x,EYEDIR.z,EYEDIR.y);
        COLOR = texture(source_open_sky,ue_direction).rgb;
    }
}
