shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, diffuse_lambert, specular_disabled;

// M_水花 CPU sprite material expressions, recovered from cooked DXBC.
// UE TLM_VolumetricDirectional lighting is adapted by Godot, not reproduced.
// The native separate distortion pass is deliberately not emulated here.
uniform sampler2D splash_color_a : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D splash_color_b : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D splash_normal_a : filter_linear_mipmap, repeat_enable;
uniform sampler2D splash_normal_b : filter_linear_mipmap, repeat_enable;
uniform sampler2D splash_noise : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D screen_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform float source_speed_cm_s = 700.0;
uniform float source_brightness = 4.0;
uniform vec2 pivot = vec2(0.0);
uniform int audit_mode = 0; // 1: dynamic B; 2: speed blend; 3: depth fade; 4: distortion source factor
varying float dynamic_refract_amount;
varying float particle_speed_cm_s;

void vertex() {
	dynamic_refract_amount = INSTANCE_CUSTOM.b;
	particle_speed_cm_s = INSTANCE_CUSTOM.a;
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

vec3 unpack_bc5(vec2 rg) {
	vec2 xy = rg * 2.0 - 1.0;
	return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
}

void fragment() {
	float speed_blend = clamp(particle_speed_cm_s / source_speed_cm_s, 0.0, 1.0);
	vec3 source_rgb = mix(texture(splash_color_a, UV).rgb, texture(splash_color_b, UV).rgb, speed_blend);
	vec3 normal_a = unpack_bc5(texture(splash_normal_a, UV).rg);
	vec3 normal_b = unpack_bc5(texture(splash_normal_b, UV).rg);
	vec3 source_normal = normalize(mix(normal_a, normal_b, speed_blend));
	float noise_r = texture(splash_noise, UV + vec2(TIME * 0.5, 0.0)).r;
	float fade_m = max((noise_r * 100.0 + 150.0) * 0.01, 0.0000001);
	float depth = texture(screen_depth, SCREEN_UV).r;
	vec4 view_position = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float surface_distance_m = -view_position.z / view_position.w;
	float contact_fade = clamp((surface_distance_m + VERTEX.z) / fade_m, 0.0, 1.0);
	// Original alpha uses texture RED, not its opaque alpha channel, before brightness.
	float source_opacity = source_rgb.r * COLOR.a;
	ALBEDO = clamp(source_rgb * COLOR.rgb * source_brightness, vec3(0.0), vec3(1.0));
	ALPHA = clamp(contact_fade * source_opacity, 0.0, 1.0);
	NORMAL_MAP = source_normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	// CPU distortion PS @50198 uses (Dynamic.B - 1) * source_opacity * viewNormal.xy.
	// It does not use the soft-contact fade above. Final UE screen multipliers and
	// transparent-scene accumulation are unresolved; audit mode exposes only this factor.
	if (audit_mode > 0) {
		float value = dynamic_refract_amount;
		if (audit_mode == 2) { value = speed_blend; }
		if (audit_mode == 3) { value = contact_fade; }
		if (audit_mode == 4) { value = abs((dynamic_refract_amount - 1.0) * source_opacity); }
		ALBEDO = vec3(0.0);
		EMISSION = vec3(value);
		ALPHA = 1.0;
	}
}
