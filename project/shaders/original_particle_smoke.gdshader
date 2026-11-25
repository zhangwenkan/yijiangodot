shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, diffuse_lambert, specular_disabled;

// Smoke1_Mat CPU main-pass expressions, using the 1_6_smoke2_vg2_Inst overrides.
// The exact binary32 BlackBody constants come from cooked DXBC hex literals.
// UE TLM_VolumetricDirectional illumination is still adapted by Godot.
uniform sampler2D source_smoke : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D source_normal : filter_linear_mipmap, repeat_enable;
uniform sampler2D source_dynamic_parameters : filter_nearest, repeat_disable;
uniform sampler2D screen_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec2 atlas = vec2(8.0);
uniform vec2 pivot = vec2(0.0);
uniform float flatten_normal = 0.5;
uniform float fade_distance_cm = 300.0;
uniform int audit_mode = 0; // 1: T/1500; 2: intensity/50; 3: ori_blend; 4: emissive before lighting
varying float particle_frame;
varying flat vec3 source_dynamic;

void vertex() {
	particle_frame = INSTANCE_CUSTOM.g;
	source_dynamic = texelFetch(source_dynamic_parameters, ivec2(INSTANCE_ID, 0), 0).rgb;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 front = INV_VIEW_MATRIX[2].xyz;
	float angle = INSTANCE_CUSTOM.r;
	vec3 x = right * cos(angle) + up * sin(angle);
	vec3 y = up * cos(angle) - right * sin(angle);
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(x * scale.x, 0.0), vec4(y * scale.y, 0.0), vec4(front * scale.z, 0.0), MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	VERTEX.xy += vec2(pivot.x, -pivot.y);
}

vec2 frame_uv(vec2 uv, float frame) {
	// The source SubUVMovie loops, including the 63 -> 0 interpolation.
	float index = mod(floor(frame), atlas.x * atlas.y);
	return (uv + vec2(mod(index, atlas.x), floor(index / atlas.x))) / atlas;
}

vec3 source_blackbody(float temperature) {
	float t2 = temperature * temperature;
	vec3 rational = temperature * vec3(0.00015411825734190643, 0.0008424202096648514, 0.00004228062607580796) + vec3(0.8601177334785461, 1.0, 0.31739872694015503);
	rational = t2 * vec3(0.00000012864121856637212, 0.0000007081451371959702, 0.00000004204816761443908) + rational;
	float u = rational.x / rational.y;
	float v = rational.z / (t2 * 0.00000016145605741257896 + (1.0 - temperature * 0.000028974181986995973));
	float denominator = 2.0 * u - 8.0 * v + 4.0;
	float x = 3.0 * u / denominator;
	float y = 2.0 * v / denominator;
	float inverse_y = 1.0 / y;
	vec3 xyz = vec3(x * inverse_y, 1.0, (1.0 - x - y) * inverse_y);
	vec3 rgb = vec3(dot(vec3(3.2404541969299316, -1.5371384620666504, -0.49853140115737915), xyz), dot(vec3(-0.9692659974098206, 1.876010775566101, 0.04155600070953369), xyz), dot(vec3(0.05564339831471443, -0.20402589440345764, 1.057225227355957), xyz));
	float intensity = temperature * 0.00039999998989515007;
	intensity *= intensity;
	intensity *= intensity;
	return rgb * intensity;
}

void fragment() {
	vec4 smoke = mix(texture(source_smoke, frame_uv(UV, particle_frame)), texture(source_smoke, frame_uv(UV, particle_frame + 1.0)), fract(particle_frame)) * COLOR;
	vec2 normal_xy = texture(source_normal, UV).rg * 2.0 - 1.0;
	vec3 normal_vector = vec3(normal_xy, sqrt(max(1.0 - dot(normal_xy, normal_xy), 0.0)));
	normal_vector = normalize(mix(normal_vector, vec3(0.0, 0.0, 1.0), flatten_normal));
	vec3 hot_color = source_blackbody(source_dynamic.r) * source_dynamic.g;
	// Native B has a small negative tail: do not saturate the lerp factor.
	vec3 emissive = max(mix(smoke.rgb, hot_color, source_dynamic.b), vec3(0.0));
	float depth = texture(screen_depth, SCREEN_UV).r;
	vec4 view_position = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float surface_distance_m = -view_position.z / view_position.w;
	float contact = clamp((surface_distance_m + VERTEX.z) * 100.0 / max(fade_distance_cm, 0.00001), 0.0, 1.0);
	ALBEDO = clamp(smoke.rgb, vec3(0.0), vec3(1.0));
	EMISSION = emissive;
	ALPHA = clamp(smoke.a * contact, 0.0, 1.0);
	NORMAL_MAP = normal_vector * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	if (audit_mode > 0) {
		ALBEDO = vec3(0.0);
		if (audit_mode == 1) { EMISSION = vec3(source_dynamic.r / 1500.0); }
		if (audit_mode == 2) { EMISSION = vec3(source_dynamic.g / 50.0); }
		if (audit_mode == 3) { EMISSION = vec3(source_dynamic.b); }
		ALPHA = 1.0;
	}
}
