// Sun-only diagnostic. Input coefficients already include the producer's sun
// intensity/color / PI, real shadow, original LF, packing and volume filtering.
// Never multiply this decoded response by LIGHT_COLOR, ATTENUATION or LF again.
uniform sampler3D source_tlv_ambient_inner : filter_linear, repeat_disable;
uniform sampler3D source_tlv_ambient_outer : filter_linear, repeat_disable;
uniform sampler3D source_tlv_directional_inner : filter_linear, repeat_disable;
uniform sampler3D source_tlv_directional_outer : filter_linear, repeat_disable;
uniform vec3 source_tlv_min_inner_cm;
uniform vec3 source_tlv_min_outer_cm;
uniform vec3 source_tlv_inv_size_inner;
uniform vec3 source_tlv_inv_size_outer;
uniform int source_tlv_sun_mode = 1; // 0 original light path, 1 sun TLV, 2 suppress sun.
uniform bool source_tlv_nondirectional = false;
uniform float source_tlv_directional_intensity = 1.0;
// Explicit zero-offset diagnostic until source stable particle IDs are recovered.
uniform vec3 source_tlv_lighting_offset_ue_cm = vec3(0.0);
varying vec3 source_tlv_receiver_world;

vec3 source_tlv_sun_response(vec3 world_position_m, vec3 world_normal_godot) {
    vec3 p = world_position_m.xzy * 100.0 + source_tlv_lighting_offset_ue_cm;
    vec3 a = (p - source_tlv_min_inner_cm) * source_tlv_inv_size_inner;
    vec3 b = (p - source_tlv_min_outer_cm) * source_tlv_inv_size_outer;
    vec3 factors = clamp((vec3(0.5) - abs(a - vec3(0.5))) * 6.0, vec3(0.0), vec3(1.0));
    float inner_weight = factors.x * factors.y * factors.z;
    // repeat_disable preserves source clamp at the outer boundary.
    vec4 ambient = mix(textureLod(source_tlv_ambient_outer, b, 0.0),
                       textureLod(source_tlv_ambient_inner, a, 0.0), inner_weight);
    if (source_tlv_nondirectional) return ambient.rgb * 0.886228;
    vec3 directional = mix(textureLod(source_tlv_directional_outer, b, 0.0).rgb,
                           textureLod(source_tlv_directional_inner, a, 0.0).rgb, inner_weight);
    vec3 normal_ue = normalize(world_normal_godot).xzy;
    vec3 color = ambient.rgb / source_tlv_directional_intensity;
    vec3 normalized_color = color / (dot(color, vec3(0.3, 0.59, 0.11)) + 0.00001);
    vec3 transfer = vec3(-normal_ue.y, normal_ue.z, -normal_ue.x) * 1.023328;
    return max(vec3(0.0), color * 0.886228 + normalized_color *
               dot(directional * source_tlv_directional_intensity, transfer));
}
