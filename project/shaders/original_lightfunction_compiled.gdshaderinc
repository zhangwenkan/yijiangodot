// Recovered from original UE4.27 M_YunYing1 / M_YunYing4 DXBC and preshaders.
// Caller supplies original light-function projected UV (including light Roll).
// Texture samplers must use source sRGB settings and repeat wrapping.
// These functions do NOT invent light projection scale, shadow fade, or weather.
vec2 source_cloud_rotated_uv(vec2 uv, vec2 tiling) {
    return vec2(
        dot(uv, vec2(0.927184, -0.374607)),
        dot(uv, vec2(0.374607, 0.927184))
    ) * tiling;
}
vec3 source_cloud_pair(vec2 uv, float time_seconds,
        sampler2D cloud1, sampler2D cloud2,
        vec2 tiling, vec2 speed1, vec2 speed2, float power1, float power2) {
    vec2 rotated = source_cloud_rotated_uv(uv, tiling);
    vec3 a = pow(max(texture(cloud1, rotated + time_seconds * speed1).rgb, vec3(0.0)), vec3(power1));
    vec3 b = pow(max(texture(cloud2, rotated + time_seconds * speed2).rgb, vec3(0.0)), vec3(power2));
    return a * b;
}
// M_YunYing1, main sun Map_xx_Inst3. Source texture 3 is fixed cloudshadow1.
float source_lightfunction_cloud(vec2 uv, float time_seconds,
        sampler2D cloud1, sampler2D cloud2, sampler2D fixed_cloudshadow1,
        vec2 tiling, vec2 speed1, vec2 speed2, float power1, float power2,
        vec2 offset_speed1, vec2 offset_speed2, float spot_size1, float spot_size2,
        vec3 source_tint) {
    vec3 clouds = source_cloud_pair(uv, time_seconds, cloud1, cloud2,
        tiling, speed1, speed2, power1, power2);
    vec3 spots = texture(fixed_cloudshadow1, uv * 0.2 + time_seconds * offset_speed1).rgb
        * texture(fixed_cloudshadow1, uv * 0.1 + time_seconds * offset_speed2).rgb;
    spots = vec3(1.0) - (vec3(1.0) - spots * spot_size1) * spot_size2;
    return dot(max(clouds * spots * source_tint, vec3(0.0)), vec3(0.3333));
}
// M_YunYing4, the 23 Youxian spotlights.
// Param_2 controls tree texture tiling; Param is sine frequency; Param_1 amplitude.
float source_lightfunction_tree(vec2 uv, float time_seconds,
        sampler2D tree_mask, sampler2D cloud1, sampler2D cloud2,
        vec2 tiling, vec2 speed1, vec2 speed2, float power1, float power2,
        float tree_tiling, float sway_frequency, float sway_amplitude) {
    float offset = sin(time_seconds * sway_frequency * 6.283185) * sway_amplitude;
    float tree = texture(tree_mask, uv * tree_tiling + vec2(offset)).r;
    vec3 clouds = source_cloud_pair(uv, time_seconds, cloud1, cloud2,
        tiling, speed1, speed2, power1, power2);
    return dot(max(clouds * tree, vec3(0.0)), vec3(0.3333));
}

