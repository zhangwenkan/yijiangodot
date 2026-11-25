shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, unshaded;
uniform sampler2D source_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D source_tiled : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D screen_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform bool billboard = true;
uniform int source_alignment = 0; // 0 screen, 1 PSA_Velocity, 2 EPAL_ROTATE_Z.
uniform vec3 source_lock_axis = vec3(0.0, 1.0, 0.0);
uniform sampler2D source_direction_data : filter_nearest, repeat_disable;

uniform bool lock_vertical = false;
uniform vec2 atlas = vec2(1.0);
uniform vec2 pivot = vec2(0.0);
uniform float source_mip_bias = 0.0;
uniform int material_mode = 0; // 0 Sequence, 1 Basic_Emi, 2 HuoXing, 3 Fireflies.
uniform float source_depth_fade_cm = 100.0;
uniform float source_emission = 1.0;
uniform int audit_mode = 0; // 1 source frame UV, 2 alpha, 3 emission / 50.
varying float particle_frame;
varying flat vec4 source_particle_color;
vec3 source_safe_unit(vec3 value) {
    // Exact SpriteVF SafeNormalize floor; direction and camera deltas are in UE cm.
    return value * inversesqrt(max(dot(value,value), 0.00000001));
}

void vertex() {
	particle_frame = INSTANCE_CUSTOM.g;
	source_particle_color = COLOR;
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

vec2 source_frame_uv(vec2 uv, float frame) {
    float index = floor(frame);
    return (uv + vec2(mod(index, atlas.x), floor(index / atlas.x))) / atlas;
}
float source_contact_fade(float distance_cm, vec2 screen_uv, float receiver_view_z, mat4 inverse_projection) {
    float depth = texture(screen_depth, screen_uv).r;
    vec4 scene_view = inverse_projection * vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
    return clamp((-scene_view.z / scene_view.w + receiver_view_z) * 100.0 / distance_cm, 0.0, 1.0);
}
float source_radial(vec2 uv) {
    float radial = 1.0 - 2.0 * length(uv - vec2(0.5));
    float exponent = radial * 2.3329999446868896;
    exponent = exponent * exponent;
    float power = exp2(exponent * 1.442695140838623);
    float mask = 1.0 - 1.0 / power;
    return radial >= 0.0 && abs(radial) > 9.999999747378752e-6 ? mask : 0.0;
}

void fragment() {
    vec2 source_uv = source_frame_uv(UV, particle_frame);
    vec3 emission;
    float alpha;
    if (material_mode <= 1) {
        // These source materials sample UV0 once. They do not use ParticleSubUV interpolation.
        vec4 texel = texture(source_texture, source_uv, source_mip_bias);
        emission = max(texel.rgb * source_particle_color.rgb, vec3(0.0));
        alpha = clamp((material_mode == 0 ? clamp(texel.a,0.0,1.0) : texel.a) * source_particle_color.a, 0.0, 1.0);
        if (material_mode == 0) alpha *= source_contact_fade(source_depth_fade_cm, SCREEN_UV, VERTEX.z, INV_PROJECTION_MATRIX);
    } else {
        float mask = source_radial(source_uv);
        emission = max(source_particle_color.rgb * source_emission, vec3(0.0));
        if (material_mode == 3) emission *= mask;
        alpha = clamp(mask * source_particle_color.a, 0.0, 1.0);
    }
    ALBEDO = vec3(0.0);
    EMISSION = emission;
    ALPHA = alpha;
    if (audit_mode == 1) { EMISSION=vec3(fract(source_uv),0.0); ALPHA=1.0; }
    if (audit_mode == 2) { EMISSION=vec3(alpha); ALPHA=1.0; }
    if (audit_mode == 3) { EMISSION=emission/50.0; ALPHA=1.0; }
    // Forward+ MODE_UNSHADED writes albedo directly and omits the emission term.
    ALBEDO = EMISSION;
    EMISSION = vec3(0.0);
}
