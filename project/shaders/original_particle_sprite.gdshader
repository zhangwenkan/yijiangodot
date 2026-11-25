shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D source_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D source_normal : hint_normal, filter_linear_mipmap, repeat_disable;
uniform bool has_texture = false;
uniform bool has_normal = false;
uniform bool radial = false;
uniform bool billboard = true;
uniform int source_alignment = 0; // 0 screen, 1 PSA_Velocity, 2 EPAL_ROTATE_Z.
uniform vec3 source_lock_axis = vec3(0.0, 1.0, 0.0);
uniform sampler2D source_direction_data : filter_nearest, repeat_disable;

uniform bool lock_vertical = false;
uniform bool opacity_from_rgb = false;
uniform bool masked_leaf = false;
uniform bool frame_blend = true;
uniform vec2 atlas = vec2(1.0);
uniform vec2 pivot = vec2(0.0);
uniform float emission_strength = 0.0;
uniform float soft_distance = 0.12;
uniform sampler2D screen_depth : hint_depth_texture, filter_nearest, repeat_disable;
varying float particle_frame;

vec3 source_safe_unit(vec3 value) {
    // Exact SpriteVF SafeNormalize floor; direction and camera deltas are in UE cm.
    return value * inversesqrt(max(dot(value,value), 0.00000001));
}

void vertex() {
	particle_frame = INSTANCE_CUSTOM.g;
	if (billboard) {
		vec3 right = INV_VIEW_MATRIX[0].xyz;
		vec3 up = INV_VIEW_MATRIX[1].xyz;
		vec3 front = INV_VIEW_MATRIX[2].xyz;
		if (lock_vertical) {
			up = vec3(0.0, 1.0, 0.0);
			right = normalize(cross(up, front));
			front = normalize(cross(right, up));
		}
		float angle = INSTANCE_CUSTOM.r;
		vec3 x = right * cos(angle) + up * sin(angle);
		vec3 y = up * cos(angle) - right * sin(angle);
		if (source_alignment != 0) {
			vec3 camera_direction = source_safe_unit((INV_VIEW_MATRIX[3].xyz - MODEL_MATRIX[3].xyz) * 100.0);
			if (source_alignment == 1) {
				ivec2 data_size = textureSize(source_direction_data, 0);
				vec3 delta_cm = textureLod(source_direction_data, vec2((float(INSTANCE_ID)+0.5)/float(data_size.x),0.5),0.0).rgb;
				vec3 direction = source_safe_unit(delta_cm);
				// P=(X,Z,Y) has determinant -1, so P(a cross b)=-(Pa cross Pb).
				x = -source_safe_unit(cross(camera_direction, direction));
				y = direction;
			} else {
				vec3 axis = source_lock_axis;
				vec3 source_down = source_safe_unit(cross(axis, camera_direction));
				float source_angle = -angle + 1.5707963705062866;
				x = sin(source_angle)*source_down + cos(source_angle)*axis;
				y = sin(source_angle)*axis - cos(source_angle)*source_down;
			}
			front = source_safe_unit(cross(x,y));
		}

		vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(x * scale.x, 0.0), vec4(y * scale.y, 0.0), vec4(front * scale.z, 0.0), MODEL_MATRIX[3]);
		MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
		// Cascade's texture V tangent points down; the imported quad's Y points up.
		VERTEX.xy += vec2(pivot.x, -pivot.y);
	}
}

vec2 atlas_uv(vec2 uv, float frame) {
	float f = clamp(floor(frame), 0.0, atlas.x * atlas.y - 1.0);
	return (uv + vec2(mod(f, atlas.x), floor(f / atlas.x))) / atlas;
}

void fragment() {
	vec4 texel = vec4(1.0);
	vec2 frame_uv = atlas_uv(UV, particle_frame);
	if (has_texture) {
		texel = texture(source_texture, frame_uv);
		if (frame_blend && atlas.x * atlas.y > 1.0) {
			texel = mix(texel, texture(source_texture, atlas_uv(UV, particle_frame + 1.0)), fract(particle_frame));
		}
	}
	if (radial) {
		// The source radial material functions are known; its compiled shader graph is unavailable.
		float r = length((UV - 0.5) * 2.0);
		texel.a = pow(max(0.0, 1.0 - r), 2.0);
	}
	if (opacity_from_rgb) {
		texel.a = texel.r;
		texel.rgb = vec3(0.84, 0.92, 0.94);
	}
	float alpha = texel.a * COLOR.a;
	if (!masked_leaf && soft_distance > 0.0) {
		float depth = texture(screen_depth, SCREEN_UV).r;
		vec4 world = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		float surface_distance = -world.z / world.w;
		alpha *= clamp((surface_distance + VERTEX.z) / soft_distance, 0.0, 1.0);
	}
	if (masked_leaf) {
		ALPHA_SCISSOR_THRESHOLD = 0.3333;
	}
	ALBEDO = texel.rgb * COLOR.rgb;
	EMISSION = texel.rgb * COLOR.rgb * emission_strength;
	ALPHA = clamp(alpha, 0.0, 1.0);
	ROUGHNESS = 0.85;
	SPECULAR = 0.08;
	if (has_normal) {
		// Original Circle_normal is one circular normal map, not the smoke atlas.
		NORMAL_MAP = texture(source_normal, UV).rgb;
		NORMAL_MAP_DEPTH = 0.5;
	}
}
