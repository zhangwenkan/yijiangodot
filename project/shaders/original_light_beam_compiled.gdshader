// Recovered from M_GodRay_Animated: VS @8520, main additive PS @22237.
// Exact material operations; engine fog/exposure remain renderer adaptations.
// Applies original SplineThicken WPO to the imported four-vertex source strip.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, skip_vertex_transform;

uniform sampler2D mask_texture : source_color, repeat_disable, filter_linear_mipmap;
uniform sampler2D noise_texture : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec4 beam_color = vec4(1.0);
uniform float brightness = 1.0;
uniform float phase = 0.0;
uniform float fade_distance_m = 20.48;
uniform float width_m = 2.598937;
uniform float length_m = 13.097233;
uniform bool animated = true;
// SM_GodRay_Plane UV.v increases along local +X in the recovered GLB.
// This is the converted original spline axis, not a newly created mesh.
uniform vec3 source_axis_local = vec3(1.0, 0.0, 0.0);
varying vec3 source_fade_axis_view;

void vertex() {
    vec3 base_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 axis_world = normalize((MODEL_MATRIX * vec4(source_axis_local, 0.0)).xyz);
    vec3 to_camera = CAMERA_POSITION_WORLD - base_world;
    // UE->Godot swaps Y/Z (handedness reversal), hence this cross order.
    vec3 across_world = cross(axis_world, to_camera);
    float across_length = length(across_world);
    if (across_length > 0.000001) {
        across_world /= across_length;
    } else {
        across_world = normalize((MODEL_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
    }
    // UE's original WPO adds to the source strip; Width/Length are world units.
    vec3 displaced = base_world
        + axis_world * length_m * UV.y
        + across_world * width_m * (UV.x - 0.5);
    // Original PS cross(TangentZ,TangentX)*handedness is the strip's
    // bitangent, parallel to its length. It does not use the strip face normal.
    // Its sign disappears inside abs(dot(...)), so source_axis_local is sufficient.
    source_fade_axis_view = normalize(mat3(VIEW_MATRIX) * axis_world);
    VERTEX = (VIEW_MATRIX * vec4(displaced, 1.0)).xyz;
    NORMAL = normalize(mat3(VIEW_MATRIX) * normalize(MODEL_NORMAL_MATRIX * NORMAL));
}
void fragment() {
    float pixel_depth = -VERTEX.z;
    float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    vec3 ndc = vec3(SCREEN_UV, raw_depth) * 2.0 - 1.0;
    #else
    vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
    #endif
    vec4 scene = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
    float scene_depth = -scene.z / scene.w;
    // PS source .0025 per centimeter = one quarter per meter.
    float contact = clamp((scene_depth - pixel_depth) * 0.25, 0.0, 1.0);
    float facing = clamp(abs(dot(normalize(source_fade_axis_view), normalize(-VERTEX))), 0.0, 1.0);
    float angular_fade = pow(max(1.0 - pow(facing, 10.0), 0.0), 8.0);
    // Original fades near the camera, not at distant geometry contacts.
    float camera_fade = 1.0 - clamp(
        (1.0 - abs(pixel_depth) / max(fade_distance_m, 0.0000001)) * 1.333333,
        0.0, 1.0);
    float mask = texture(mask_texture, UV).r;
    float noise = 1.0;
    if (animated) {
        noise = texture(noise_texture, vec2(UV.x, UV.y * 0.01 + (TIME + phase) * 0.1)).r;
    }
    ALBEDO = max(beam_color.rgb * brightness, vec3(0.0));
    ALPHA = clamp(contact * angular_fade * camera_fade * mask * noise, 0.0, 1.0);
}

