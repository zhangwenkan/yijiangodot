shader_type spatial;
render_mode cull_disabled;
uniform bool half_mask = false;
uniform float wind_offset = 0.0;
uniform float dynamic_amplitude = 0.0;
void vertex() { VERTEX.x += wind_offset + sin(TIME) * dynamic_amplitude; }
void fragment() {
    if (half_mask && UV.x < 0.5) { discard; }
    ALBEDO = vec3(0.4);
}
