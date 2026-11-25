// Original mask and random phase retained; exact cooked material graph is not available.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform sampler2D mask_texture : repeat_disable;
uniform sampler2D noise_texture : repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec4 beam_color : source_color = vec4(1.0);
uniform float brightness = 1.0;
uniform float phase = 0.0;
uniform float depth_fade = 20.48;
uniform vec3 source_size_scale = vec3(1.0);
void vertex() { VERTEX *= source_size_scale; }
void fragment() {
    float mask = texture(mask_texture, UV).r;
    float noise = texture(noise_texture, UV + vec2(TIME * 0.01 + phase, 0.0)).r;
    float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    vec3 ndc = vec3(SCREEN_UV, raw_depth) * 2.0 - 1.0;
    #else
    vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
    #endif
    vec4 scene = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
    // Use the recovered fade-distance parameter for soft scene contact.
    // This is an adapter, not a reconstruction of the missing UE graph.
    float contact = clamp((-scene.z / scene.w + VERTEX.z) / max(depth_fade, 0.01), 0.0, 1.0);
    ALBEDO = beam_color.rgb * brightness;
    ALPHA = mask * mix(0.65, 1.0, noise) * contact;
}
