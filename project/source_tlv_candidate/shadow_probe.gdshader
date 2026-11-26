shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, ambient_light_disabled, specular_disabled, fog_disabled;

// Diagnostic only. The draw quad was authored in Blender; no mesh is generated.
// Camera frustum must contain every queried point and keep original caster layers.
uniform int dimension = 64;
uniform int atlas_width = 512;
uniform vec3 volume_min = vec3(-4.0);
uniform float voxel_size = 0.125;
uniform vec3 sun_world_direction = vec3(0.0, 0.0, 1.0);
uniform bool query_local = false;

void vertex() {
    POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

void fragment() {
    ivec2 pixel = ivec2(FRAGCOORD.xy);
    int index = pixel.y * atlas_width + pixel.x;
    ivec3 cell = ivec3(index % dimension, (index / dimension) % dimension, index / (dimension * dimension));
    vec3 world_position = volume_min + (vec3(cell) + 0.5) * voxel_size;
    LIGHT_VERTEX = (VIEW_MATRIX * vec4(world_position, 1.0)).xyz;
    NORMAL = normalize((VIEW_MATRIX * vec4(sun_world_direction, 0.0)).xyz);
    ALBEDO = vec3(1.0);
    ALPHA = 1.0;
    ROUGHNESS = 1.0;
}

void light() {
    if (LIGHT_IS_DIRECTIONAL != query_local) {
        DIFFUSE_LIGHT += vec3(ATTENUATION, 1.0, 0.0);
    }
}
