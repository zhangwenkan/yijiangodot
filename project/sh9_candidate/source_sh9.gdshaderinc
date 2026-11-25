// Source UE three-band real SH convention. Input coefficient domain is E/pi.
// Vector3 uniforms intentionally avoid Godot Color Variant's automatic decode.
uniform vec3 source_sh9_coefficients[9];
uniform vec3 source_sh9_linear_gain = vec3(1.0);
uniform bool source_sh9_enabled = true;

vec3 source_sh9_evaluate(vec3 normal_godot_world) {
    vec3 n = normalize(normal_godot_world).xzy;
    vec3 result = source_sh9_coefficients[0] * 0.282095;
    result += source_sh9_coefficients[1] * (-0.488603 * n.y);
    result += source_sh9_coefficients[2] * (0.488603 * n.z);
    result += source_sh9_coefficients[3] * (-0.488603 * n.x);
    result += source_sh9_coefficients[4] * (1.092548 * n.x * n.y);
    result += source_sh9_coefficients[5] * (-1.092548 * n.y * n.z);
    result += source_sh9_coefficients[6] * (0.315392 * (3.0 * n.z * n.z - 1.0));
    result += source_sh9_coefficients[7] * (-1.092548 * n.x * n.z);
    result += source_sh9_coefficients[8] * (0.546274 * (n.x * n.x - n.y * n.y));
    return max(result, vec3(0.0)) * source_sh9_linear_gain;
}
