shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D weights_1_4 : filter_linear, repeat_disable;
uniform sampler2D weights_5_8 : filter_linear, repeat_disable;
uniform sampler2D source_normal_xy : filter_linear, repeat_disable;
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
uniform vec2 layer_uv_0 = vec2(0.01, -0.01);
uniform vec2 layer_uv_1 = vec2(0.01, -0.01);
uniform vec2 layer_uv_2 = vec2(0.01, -0.01);
uniform vec2 layer_uv_3 = vec2(0.01, -0.01);
uniform vec2 layer_uv_4 = vec2(0.01, -0.01);
uniform vec2 layer_uv_5 = vec2(0.01, -0.01);
uniform vec2 layer_uv_6 = vec2(0.01, -0.01);
uniform vec2 layer_uv_7 = vec2(0.01, -0.01);
uniform vec4 layer_metallic_0 = vec4(0.0);
uniform vec4 layer_metallic_1 = vec4(0.0);
uniform vec4 layer_specular_0 = vec4(0.0);
uniform vec4 layer_specular_1 = vec4(0.0);
uniform vec4 layer_roughness_0 = vec4(0.0);
uniform vec4 layer_roughness_1 = vec4(0.0);
varying vec3 world_position;

// Original layer normal unpack, before complete XYZ blending.
vec3 decode_source_normal(vec2 encoded) {
	vec2 n = encoded * 2.0 - 1.0;
	return vec3(n, sqrt(max(1.0 - dot(n, n), 0.0)));
}
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec4 a = texture(weights_1_4, UV);
	vec4 b = texture(weights_5_8, UV);
	// DXBC uses UE absolute world Y,X in centimeters; the import maps UE to Godot X,Z,Y.
	vec2 source_world_yx_cm = world_position.zx * 100.0;
	vec2 uv0 = source_world_yx_cm * layer_uv_0;
	vec2 uv1 = source_world_yx_cm * layer_uv_1;
	vec2 uv2 = source_world_yx_cm * layer_uv_2;
	vec2 uv3 = source_world_yx_cm * layer_uv_3;
	vec2 uv4 = source_world_yx_cm * layer_uv_4;
	vec2 uv5 = source_world_yx_cm * layer_uv_5;
	vec2 uv6 = source_world_yx_cm * layer_uv_6;
	vec2 uv7 = source_world_yx_cm * layer_uv_7;
	vec3 color = vec3(0.0);
	vec3 layered_normal = vec3(0.0);
	color += texture(layer_0, uv0).rgb * a.r;
	layered_normal += decode_source_normal(texture(normal_0, uv0).rg) * a.r;
	color += texture(layer_1, uv1).rgb * a.g;
	layered_normal += decode_source_normal(texture(normal_1, uv1).rg) * a.g;
	color += texture(layer_2, uv2).rgb * a.b;
	layered_normal += decode_source_normal(texture(normal_2, uv2).rg) * a.b;
	color += texture(layer_3, uv3).rgb * a.a;
	layered_normal += decode_source_normal(texture(normal_3, uv3).rg) * a.a;
	color += texture(layer_4, uv4).rgb * b.r;
	layered_normal += decode_source_normal(texture(normal_4, uv4).rg) * b.r;
	color += texture(layer_5, uv5).rgb * b.g;
	layered_normal += decode_source_normal(texture(normal_5, uv5).rg) * b.g;
	color += texture(layer_6, uv6).rgb * b.b;
	layered_normal += decode_source_normal(texture(normal_6, uv6).rg) * b.b;
	color += texture(layer_7, uv7).rgb * b.a;
	layered_normal += decode_source_normal(texture(normal_7, uv7).rg) * b.a;
	// Source weights are deliberately not divided by their sum.
	ALBEDO = clamp(color, vec3(0.0), vec3(1.0));
	layered_normal = normalize(layered_normal);
	// The packed source heightmap BA are original landscape-local normal XY.
	vec3 normal_ue = decode_source_normal(texture(source_normal_xy, UV).rg);
	vec3 tangent_ue = normalize(vec3(normal_ue.z, 0.0, -normal_ue.x));
	vec3 binormal_ue = cross(normal_ue, tangent_ue);
	vec3 result_ue = normalize(tangent_ue * layered_normal.x + binormal_ue * layered_normal.y + normal_ue * layered_normal.z);
	NORMAL = normalize((VIEW_MATRIX * vec4(result_ue.xzy, 0.0)).xyz);
	METALLIC = clamp(dot(a, layer_metallic_0) + dot(b, layer_metallic_1), 0.0, 1.0);
	SPECULAR = clamp(dot(a, layer_specular_0) + dot(b, layer_specular_1), 0.0, 1.0);
	ROUGHNESS = clamp(dot(a, layer_roughness_0) + dot(b, layer_roughness_1), 0.0, 1.0);
}
