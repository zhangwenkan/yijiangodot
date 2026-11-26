shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, ambient_light_disabled, specular_disabled, fog_disabled;
#include "res://shaders/original_lightfunction_compiled.gdshaderinc"

// A diagnostic producer, not a material lighting replacement. Each 64 by 64
// atlas tile is one UE XY slice. This preserves the LightFunction derivatives.
uniform vec3 volume_min_ue_cm;
uniform float voxel_cm;
uniform vec3 sun_world_direction;
uniform vec4 lf_local_y;
uniform vec4 lf_local_z;
uniform vec2 lf_scale;
uniform vec4 lf_tiling_power;
uniform vec4 lf_speeds;
uniform vec4 lf_spot_offsets;
uniform vec2 lf_spot_sizes;
uniform vec3 lf_sun_color;
uniform sampler2D lf_cloud1 : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D lf_cloud2 : source_color, repeat_enable, filter_linear_mipmap;
uniform bool lf_enabled = true;
varying float volume_light_function;

void vertex() { POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0); }

void fragment() {
    ivec2 pixel = ivec2(FRAGCOORD.xy);
    ivec3 cell = ivec3(pixel.x % 64, pixel.y % 64, (pixel.y / 64) * 8 + pixel.x / 64);
    // Source inject PS subtracts half a voxel on XY, but not on Z.
    vec3 ue_cm = volume_min_ue_cm + (vec3(cell) + vec3(0.0, 0.0, 0.5)) * voxel_cm;
    vec3 light_ue = sun_world_direction.xzy;
    // GetBoxPushout returns a scalar, added to all coordinates by the source.
    ue_cm += vec3(dot(abs(light_ue), vec3(voxel_cm * 0.5)));
    vec3 world_position = ue_cm.xzy * 0.01;
    LIGHT_VERTEX = (VIEW_MATRIX * vec4(world_position, 1.0)).xyz;
    NORMAL = normalize((VIEW_MATRIX * vec4(sun_world_direction, 0.0)).xyz);
    vec4 p = vec4(world_position, 1.0);
    vec2 uv = vec2(dot(lf_local_y, p), dot(lf_local_z, p)) / lf_scale;
    volume_light_function = lf_enabled ? source_lightfunction_cloud(uv, TIME,
        lf_cloud1, lf_cloud2, lf_cloud2, lf_tiling_power.xy,
        lf_speeds.xy, lf_speeds.zw, lf_tiling_power.z, lf_tiling_power.w,
        lf_spot_offsets.xy, lf_spot_offsets.zw, lf_spot_sizes.x,
        lf_spot_sizes.y, lf_sun_color) : 1.0;
    ALBEDO = vec3(1.0);
    ALPHA = 1.0;
    ROUGHNESS = 1.0;
}

void light() {
    if (LIGHT_IS_DIRECTIONAL) {
        DIFFUSE_LIGHT += vec3(ATTENUATION, volume_light_function, 1.0);
    }
}
