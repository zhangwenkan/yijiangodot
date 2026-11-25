shader_type sky;
// Linear HDR in Godot cube orientation. No second sRGB decode or axis swap.
uniform samplerCube source_scene_capture : filter_linear;
uniform samplerCube source_open_sky;
uniform vec3 source_skylight_linear_gain = vec3(1.1,0.77921337477,0.60029692052);
void sky() {
    vec3 ue_direction = vec3(EYEDIR.x,EYEDIR.z,EYEDIR.y);
    if (AT_CUBEMAP_PASS) {
        COLOR = texture(source_scene_capture,EYEDIR).rgb * source_skylight_linear_gain;
    } else {
        COLOR = texture(source_open_sky,ue_direction).rgb;
    }
}
