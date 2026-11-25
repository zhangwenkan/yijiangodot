// M_Background_Base PS @6247, exact uniform slots resolved from frozen preshaders.
// Visible original sky cards, separate from SkyLight scene-capture cubemaps.
shader_type spatial;
render_mode unshaded, shadows_disabled;
uniform sampler2D base_color_texture : source_color, repeat_enable, filter_linear_mipmap;
uniform vec4 tint = vec4(1.0);
uniform vec2 scroll_velocity = vec2(-0.005, 0.0);
uniform float color_power = 1.8;
uniform float brightness = 15.0;
// Renderer exposure calibration is explicitly separate from original parameters.
uniform float renderer_exposure_scale = 1.0;
void fragment() {
    vec3 color = texture(base_color_texture, UV + TIME * scroll_velocity).rgb * tint.rgb;
    color = pow(max(color, vec3(0.0)), vec3(color_power)) * brightness;
    ALBEDO = max(color, vec3(0.0)) * renderer_exposure_scale;
}

