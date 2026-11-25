shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Portable source geometry only. Surface formulas recovered from cooked DXBC.
// Wind vertex animation retained from the existing adapter; surface formula recovered from DXBC.
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool albedo_texture_enabled = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform bool vertex_color_albedo = false;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool normal_enabled = false;
uniform float normal_scale = 1.0;
uniform float normal_flatten = 0.0;
uniform float roughness_value = 1.0;
uniform float metallic_value = 0.0;
uniform float specular_value = 0.5;
uniform int source_surface_mode = 0;
uniform float color_saturation = 1.0;
uniform float color_power = 1.0;
uniform float source_opacity = 1.0;
uniform sampler2D source_roughness_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_metallic_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_arm_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_emission_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool source_emission_enabled = false;
uniform vec3 source_emission_color = vec3(1.0);
uniform float source_emission_strength = 0.0;
uniform sampler2D emission_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool emission_texture_enabled = false;
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy = 1.0;
uniform bool emission_multiply = false;
uniform float alpha_clip = 0.3333;
uniform bool source_unshaded = false;

uniform bool masked = true;
uniform bool source_vertex_weights = false;
uniform float root_height = 0.0;
uniform float canopy_height = 1.0;
uniform float wind_intensity = 0.1;
uniform float wind_speed = 0.4;
uniform float vertex_color_power = 1.0;
uniform float wind_distance_limit = 50.0;
uniform float amplitude_adaptation = 0.55;

void vertex() {
	vec3 original_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float height_weight = clamp((VERTEX.y - root_height) / max(0.01, canopy_height - root_height), 0.0, 1.0);
	float weight = pow(source_vertex_weights ? COLOR.r : height_weight, max(0.01, vertex_color_power));
	float distance_fade = 1.0 - smoothstep(wind_distance_limit * 0.80, wind_distance_limit, distance(original_world, CAMERA_POSITION_WORLD));
	float phase = dot(original_world.xz, vec2(0.27, 0.18));
	float time = TIME * wind_speed * 6.2831853;
	float primary = sin(time + phase);
	float secondary = sin(time * 1.71 + phase * 1.9 + VERTEX.y * 0.48);
	float envelope = 0.65 + 0.35 * sin(TIME * 0.23 + phase * 0.19);
	float movement = (primary * 0.75 + secondary * 0.25) * envelope * wind_intensity * amplitude_adaptation * weight * distance_fade;
	vec3 world_motion = vec3(movement, abs(movement) * -0.12, movement * 0.47);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * world_motion;
}


void fragment() {
    vec2 surface_uv = UV * uv_scale + uv_offset;
    vec4 texel = albedo_texture_enabled ? texture(albedo_texture, surface_uv) : vec4(1.0);
    vec4 surface = texel * albedo_color;
    if (vertex_color_albedo) { surface *= COLOR; }
    vec3 color = surface.rgb;
    if (source_surface_mode == 1 || source_surface_mode == 3) {
        float luminance = dot(color, vec3(0.3, 0.59, 0.11));
        color = mix(vec3(luminance), color, color_saturation);
        color = clamp(pow(max(color, vec3(0.0)), vec3(color_power)), vec3(0.0), vec3(1.0));
    }
    ALBEDO = color;
    ROUGHNESS = clamp(roughness_value, 0.0, 1.0);
    METALLIC = clamp(metallic_value, 0.0, 1.0);
    SPECULAR = clamp(specular_value, 0.0, 1.0);
    if (source_surface_mode == 2) {
        // MI_Wujian001 adds offsets to independent R channels. It is not ORM.
        ROUGHNESS = clamp(texture(source_roughness_texture, surface_uv).r + roughness_value, 0.0, 1.0);
        METALLIC = clamp(texture(source_metallic_texture, surface_uv).r + metallic_value, 0.0, 1.0);
    } else if (source_surface_mode == 3) {
        // SM_DM_TFK_Fotou_M uses ARM.G only, as metallic multiplied by B.
        METALLIC = clamp(texture(source_arm_texture, surface_uv).g * metallic_value, 0.0, 1.0);
    }
    if (normal_enabled) {
        vec3 source_normal = texture(normal_texture, surface_uv).rgb;
        if (source_surface_mode != 0) {
            vec2 xy = source_normal.rg * 2.0 - 1.0;
            vec3 n = vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy))));
            n = normalize(mix(n, vec3(0.0, 0.0, 1.0), normal_flatten));
            source_normal = n * 0.5 + 0.5;
        }
        NORMAL_MAP = source_normal;
        NORMAL_MAP_DEPTH = normal_scale;
    }
    vec3 emission_sample = emission_texture_enabled ? texture(emission_texture, surface_uv).rgb : vec3(1.0);
    EMISSION = emission_multiply ? emission_color * emission_sample * emission_energy :
        (emission_color + (emission_texture_enabled ? emission_sample : vec3(0.0))) * emission_energy;
    if (source_emission_enabled) {
        // Verified in MI_jiangnan001_GG2, including albedo alpha mask.
        EMISSION = texture(source_emission_texture, surface_uv).r * texel.a * source_emission_color * source_emission_strength;
    }
    ALPHA = masked ? surface.a * source_opacity : 1.0;
    ALPHA_SCISSOR_THRESHOLD = masked ? alpha_clip : 0.0;
}
