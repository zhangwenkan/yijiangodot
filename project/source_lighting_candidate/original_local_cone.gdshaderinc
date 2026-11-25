// Source native SpotAttenuation: saturate((cos(theta)-cosOuter)*invCosDiff)^2.
// Godot has already multiplied its own angular attenuation into ATTENUATION.
// Correct only that factor; keep engine shadowing, radial decay and source LF.
uniform int source_local_cone_count = 0;
uniform vec4 source_local_cone_position_kind[64];
uniform vec4 source_local_cone_direction_outer[64];
uniform vec4 source_local_cone_parameters[64];

float source_local_cone_correction(vec3 fragment_world, vec3 world_light_ray) {
    int found = -1;
    float error_limit = 0.000001;
    for (int i = 0; i < source_local_cone_count; i++) {
        vec3 delta = source_local_cone_position_kind[i].xyz - fragment_world;
        float length_squared = dot(delta, delta);
        if (length_squared > 0.00000001) {
            vec3 expected = delta * inversesqrt(length_squared);
            vec3 error = expected - world_light_ray;
            float error_squared = dot(error, error);
            if (error_squared < error_limit) {
                found = i;
                error_limit = error_squared;
            }
        }
    }
    // Point lights participate in identification to avoid matching a distant Spot.
    if (found < 0 || source_local_cone_position_kind[found].w < 0.5) return 1.0;
    vec3 light_to_fragment = normalize(fragment_world - source_local_cone_position_kind[found].xyz);
    float cone_cosine = dot(light_to_fragment, source_local_cone_direction_outer[found].xyz);
    float source_cos_outer = source_local_cone_direction_outer[found].w;
    vec4 parameters = source_local_cone_parameters[found];
    float source_angular = clamp((cone_cosine - source_cos_outer) * parameters.x, 0.0, 1.0);
    source_angular *= source_angular;
    float target_rim = max(0.0001, (1.0 - max(cone_cosine, parameters.y)) / (1.0 - parameters.y));
    float target_angular = 1.0 - pow(target_rim, parameters.z);
    // Source is also zero at the cone boundary. Avoid a 0/0 there.
    return target_angular > 0.0000001 ? source_angular / target_angular : 0.0;
}
