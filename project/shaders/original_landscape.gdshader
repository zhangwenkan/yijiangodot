shader_type spatial;
render_mode cull_back, diffuse_burley, specular_disabled;

uniform sampler2D weights_1_4 : filter_linear, repeat_disable;
uniform sampler2D weights_5_8 : filter_linear, repeat_disable;
uniform sampler2D layer_0 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_1 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_2 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_3 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_4 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_5 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_6 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_7 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_0 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_1 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_2 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_3 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_4 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_5 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_6 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_7 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// Source layer weights and colour textures are exact. The cooked material graph
// does not preserve its input-coordinate formula; this scale is a review setting.
uniform vec2 review_tile_scale = vec2(1.0, -1.0);
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 a = texture(weights_1_4, UV);
	vec4 b = texture(weights_5_8, UV);
	float total = max(dot(a, vec4(1.0)) + dot(b, vec4(1.0)), 0.001);
	vec2 tile_uv = world_position.xz * review_tile_scale;
	vec3 color = texture(layer_0, tile_uv).rgb * a.r;
	color += texture(layer_1, tile_uv).rgb * a.g;
	color += texture(layer_2, tile_uv).rgb * a.b;
	color += texture(layer_3, tile_uv).rgb * a.a;
	color += texture(layer_4, tile_uv).rgb * b.r;
	color += texture(layer_5, tile_uv).rgb * b.g;
	color += texture(layer_6, tile_uv).rgb * b.b;
	color += texture(layer_7, tile_uv).rgb * b.a;
	ALBEDO = color / total;
	vec2 n = (texture(normal_0,tile_uv).rg*2.0-1.0)*a.r;
	n += (texture(normal_1,tile_uv).rg*2.0-1.0)*a.g;
	n += (texture(normal_2,tile_uv).rg*2.0-1.0)*a.b;
	n += (texture(normal_3,tile_uv).rg*2.0-1.0)*a.a;
	n += (texture(normal_4,tile_uv).rg*2.0-1.0)*b.r;
	n += (texture(normal_5,tile_uv).rg*2.0-1.0)*b.g;
	n += (texture(normal_6,tile_uv).rg*2.0-1.0)*b.b;
	n += (texture(normal_7,tile_uv).rg*2.0-1.0)*b.a;
	n /= total;
	// Original texture axes follow world X/-Z. Reproject onto the actual
	// landscape normal instead of using the weight-atlas UV tangent frame.
	vec3 base_normal = normalize(NORMAL);
	vec3 axis_x = normalize((VIEW_MATRIX*vec4(1.0,0.0,0.0,0.0)).xyz);
	vec3 tangent = normalize(axis_x-base_normal*dot(axis_x,base_normal));
	vec3 binormal = normalize(cross(base_normal,tangent));
	NORMAL = normalize(tangent*n.x + binormal*n.y + base_normal*sqrt(max(1.0-dot(n,n),0.01)));
	ROUGHNESS = 0.88;
}
