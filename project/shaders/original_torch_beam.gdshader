shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, unshaded;

// Seq_Disort_Mat_test CPU Beam2 base pass, PS151428 / VS157567.
// Source BaseColor is 0: ordinary-view TLV contribution is exactly 0.
// Reflection-capture lighting and engine debug overrides are outside this adapter.
uniform sampler2D source_flame : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D source_noise : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D source_gradient : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D screen_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec4 source_cb[16];
uniform vec4 source_particle_color = vec4(50.0, 35.0, 0.0, 1.0);
uniform float source_time_override = -1.0;
uniform float source_mip_bias = 0.0;
uniform int audit_mode = 0; // 1 UV, 2 flame UV, 3 gradient, 4 alpha, 5 emission / 50.

void vertex() {
	// The imported Blender mesh supplies the 22 source vertices and their UVs.
	// UE source direction is -Z and Up=Right cross(Location-ViewOrigin).
	// The UE->Godot (X,Z,Y) reflection reverses the cross product sign.
	vec3 beam_axis = normalize(MODEL_MATRIX[1].xyz);
	vec3 to_receiver = MODEL_MATRIX[3].xyz - CAMERA_POSITION_WORLD;
	vec3 width_direction = cross(beam_axis, to_receiver);
	if (length(width_direction) > 0.000001) {
		width_direction = normalize(width_direction);
	} else {
		width_direction = INV_VIEW_MATRIX[1].xyz;
	}
	vec3 front = normalize(cross(width_direction, beam_axis));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(width_direction, 0.0), vec4(beam_axis, 0.0), vec4(front, 0.0), MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

vec2 source_rotate(vec2 source_uv) {
	vec2 centered = source_uv - vec2(0.5);
	return vec2(dot(centered, source_cb[2].xy), dot(centered, source_cb[3].xy)) + vec2(0.5);
}

void fragment() {
	float source_time = source_time_override >= 0.0 ? source_time_override : TIME;
	vec2 main_uv = UV * source_cb[10].x;
	float bottom_mask = clamp((source_cb[10].y - UV.y) + 1.0, 0.0, 1.0);
	vec2 noise_uv = source_rotate(UV) * source_cb[4].xy + source_time * source_cb[11].xy;
	// DXBC t4.zwxy into destination .zw means sampled R,G, not B,A.
	vec2 noise_rg = clamp(texture(source_noise, noise_uv).rg, vec2(0.0), vec2(1.0));
	vec2 distortion = clamp(bottom_mask * noise_rg + source_cb[6].xy, vec2(-1.0), vec2(1.0));
	vec2 distorted_uv = main_uv + source_cb[13].z * (distortion * source_cb[13].y - main_uv);
	vec2 flame_uv = source_rotate(distorted_uv);
	float sequence_phase = fract(source_time * source_cb[14].z);
	flame_uv = (flame_uv + floor(sequence_phase * source_cb[8].xy)) / source_cb[7].xy;
	vec4 flame = texture(source_flame, flame_uv, source_mip_bias) * source_particle_color;
	// DXBC t6.xywz into destination .w selects the gradient's BLUE channel.
	float gradient = texture(source_gradient, UV).b;
	vec4 multiplied = gradient * flame;
	vec3 source_emission = max(multiplied.rgb + source_cb[14].w * (source_cb[9].rgb - multiplied.rgb), vec3(0.0));
	float depth = texture(screen_depth, SCREEN_UV).r;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_distance = -scene_view.z / scene_view.w;
	float contact_fade = clamp((scene_distance + VERTEX.z) * 100.0 / source_cb[15].y, 0.0, 1.0);
	float source_alpha = clamp(multiplied.a * contact_fade, 0.0, 1.0);
	ALBEDO = vec3(0.0);
	EMISSION = source_emission;
	ALPHA = source_alpha;
	if (audit_mode == 1) { EMISSION = vec3(UV, 0.0); ALPHA = 1.0; }
	if (audit_mode == 2) { EMISSION = vec3(fract(flame_uv), 0.0); ALPHA = 1.0; }
	if (audit_mode == 3) { EMISSION = vec3(gradient); ALPHA = 1.0; }
	if (audit_mode == 4) { EMISSION = vec3(source_alpha); ALPHA = 1.0; }
	if (audit_mode == 5) { EMISSION = source_emission / 50.0; ALPHA = 1.0; }
	// Godot's unshaded path returns ALBEDO and ignores EMISSION.
	// Keep the original HDR radiance without adding engine diffuse light.
	ALBEDO = EMISSION;
	EMISSION = vec3(0.0);
}
