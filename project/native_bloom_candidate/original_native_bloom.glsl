#[compute]
#version 450

// Independent pre-Film HDR candidate. Threshold is from shipped BloomSetup DXBC;
// filtering/upsampling is a translation of the corroborating UE 4.26 pipeline.
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(set=0, binding=0) uniform sampler2D source_tex;
layout(set=0, binding=1) uniform sampler2D additive_tex;
layout(std430, set=0, binding=2) readonly buffer Kernels { vec4 taps[]; } kernels;
layout(rgba16f, set=0, binding=3) uniform image2D output_image;
layout(push_constant, std430) uniform Params {
    ivec2 output_size;
    ivec2 source_size;
    int operation;       // 0 downsample, 1 threshold, 2 horizontal, 3 vertical, 4 merge
    int kernel_base;
    int sample_count;
    int has_additive;
    float threshold;
    float intensity;
    float tint;
    float downsample_quality;
    vec4 reserved;
} p;

vec4 sample_clamped(vec2 uv) {
    vec2 half_texel = 0.5 / vec2(p.source_size);
    return textureLod(source_tex, clamp(uv, half_texel, vec2(1.0)-half_texel), 0.0);
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixel, p.output_size))) return;
    vec2 uv = (vec2(pixel) + 0.5) / vec2(p.output_size);
    vec3 result = vec3(0.0);
    if (p.operation == 0) {
        if (p.downsample_quality < 0.5) {
            result = sample_clamped(uv).rgb;
        } else {
            vec2 step_uv = 1.0 / vec2(p.source_size);
            result = 0.25 * (
                sample_clamped(uv + step_uv * vec2(-1,-1)).rgb +
                sample_clamped(uv + step_uv * vec2( 1,-1)).rgb +
                sample_clamped(uv + step_uv * vec2(-1, 1)).rgb +
                sample_clamped(uv + step_uv * vec2( 1, 1)).rgb);
            result = max(result, vec3(0.0));
        }
    } else if (p.operation == 1) {
        // Source exposure is fixed at 1; HDR entering here must be in native units.
        vec3 scene = min(sample_clamped(uv).rgb, vec3(65536.0));
        float luminance = dot(scene, vec3(0.3, 0.59, 0.11));
        float amount = clamp((luminance-p.threshold)*0.5, 0.0, 1.0);
        result = amount * scene;
    } else if (p.operation == 2 || p.operation == 3) {
        vec2 direction = p.operation == 2
            ? vec2(1.0/float(p.source_size.x),0.0)
            : vec2(0.0,1.0/float(p.source_size.y));
        for (int i=0; i<p.sample_count; ++i) {
            vec2 tap = kernels.taps[p.kernel_base+i].xy;
            result += textureLod(source_tex, uv+direction*tap.x, 0.0).rgb*tap.y;
        }
        if (p.operation == 3) {
            result *= p.tint;
            if (p.has_additive != 0) result += textureLod(additive_tex, uv, 0.0).rgb;
        }
    } else if (p.operation == 4) {
        // Each invocation reads/writes only its own full-resolution scene pixel.
        // Bloom is a separate texture; there is no cross-pixel storage-image race.
        vec4 scene = imageLoad(output_image, pixel);
        result = scene.rgb + textureLod(source_tex, uv, 0.0).rgb*p.intensity;
        imageStore(output_image, pixel, vec4(result, scene.a));
        return;
    }
    imageStore(output_image, pixel, vec4(result,0.0));
}
