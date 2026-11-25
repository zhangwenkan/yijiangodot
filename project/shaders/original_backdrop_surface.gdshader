// M_Bjb1 original opaque/default-lit PS @9286 and frozen uniforms.
// The graph has fixed texture references, not named texture parameters.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D backdrop_color : source_color, filter_nearest, repeat_enable;
uniform sampler2D backdrop_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

void fragment() {
	ALBEDO = clamp(texture(backdrop_color, UV).rgb, vec3(0.0), vec3(1.0));
	vec2 normal_xy = texture(backdrop_normal, UV).rg * 2.0 - 1.0;
	vec3 source_normal = normalize(vec3(normal_xy, sqrt(max(1.0 - dot(normal_xy, normal_xy), 0.0))));
	NORMAL_MAP = source_normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = 0.5;
}
