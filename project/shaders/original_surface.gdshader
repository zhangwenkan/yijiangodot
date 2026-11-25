shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Portable source geometry only. Surface formulas recovered from cooked DXBC.
// Alpha/render/filter variants are compiled by original_surface.gd.
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
uniform sampler2D source_diffuse_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_cutout_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 source_diffuse_tint = vec3(1.0);
uniform float source_tick_time = 0.0;
uniform float source_sprite_emission = 1.0;
uniform float source_mask_y_offset = 1.0;

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
    if (source_surface_mode == 4) {
        // M_Simple_Cutout: native sRGB diffuse * linear tint, independent sRGB opacity R.
        color = clamp(texture(source_diffuse_texture, surface_uv).rgb * source_diffuse_tint, vec3(0.0), vec3(1.0));
        surface.a = texture(source_cutout_texture, surface_uv).r;
    } else if (source_surface_mode == 5) {
        // MI_JHMaskUnlitSprite_Inst is assigned to a StaticMesh, so DummySpriteTexture is real.
        vec4 sprite = texture(source_diffuse_texture, UV) * COLOR;
        float blink = (1.0 + sin((source_tick_time + 0.75) * 6.2831854820251465)) * 0.5;
        color = mix(sprite.rgb, sprite.rgb * source_diffuse_tint * 0.2, blink) * source_sprite_emission;
        float mask_y = max(UV.y + source_mask_y_offset, 0.0);
        float mask_y4 = mask_y * mask_y * mask_y * mask_y;
        surface.a = sprite.a * mix(mask_y4, 1.0, floor(clamp(source_mask_y_offset, 0.0, 1.0)));
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
    if (source_surface_mode == 4) {
        EMISSION = vec3(0.0); // SelectionColor is zero in the native game, not an ambient term.
    } else if (source_surface_mode == 5) {
        ALBEDO = vec3(0.0);
        EMISSION = max(color, vec3(0.0));
    }
    // SOURCE_ALPHA_OUTPUT
}
