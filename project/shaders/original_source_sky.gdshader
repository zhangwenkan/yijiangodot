shader_type sky;
uniform samplerCube source_capture;
uniform samplerCube source_open_sky;
uniform float capture_energy = 0.10;
uniform vec3 capture_tint = vec3(1.0,0.82,0.68);
void sky() {
    // UE cubemap axes are X/Y ground, Z up; Godot is X/Z ground, Y up.
    vec3 ue_direction = vec3(EYEDIR.x,EYEDIR.z,EYEDIR.y);
    if (AT_CUBEMAP_PASS) {
        // The original Skylight capture includes terrain: use it for illumination,
        // never paste that unrelated captured terrain into the visible background.
		COLOR = texture(source_capture,ue_direction).rgb * capture_energy * capture_tint;
    } else {
        COLOR = texture(source_open_sky,ue_direction).rgb;
    }
}
