shader_type spatial;
render_mode depth_draw_opaque, cull_disabled, diffuse_lambert, specular_schlick_ggx;
#define SOURCE_TWO_SIDED_FOLIAGE
varying vec3 source_leaf_subsurface;
#include "res://shaders/original_lightfunction_receiving.gdshaderinc"

uniform sampler2D source_leaf_base : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D source_leaf_normal : filter_linear_mipmap, repeat_enable;
uniform sampler2D source_leaf_roughness : filter_linear_mipmap, repeat_enable;
uniform sampler2D source_leaf_ao : filter_linear_mipmap, repeat_enable;
uniform sampler2D source_leaf_metallic : filter_linear_mipmap, repeat_enable;
uniform int audit_view = 0;

void fragment() {
    // MI_Leaf_5 cooked PS81322: the instance inherits neutral HUE/contrast/
    // blend/saturation/brightness, but AO is an overlay before shading.
    // The material does not read MeshParticle COLOR or instance alpha.
    vec4 base = texture(source_leaf_base,UV);
    if (base.a < 0.33329999446868896) discard;
    vec3 occlusion = texture(source_leaf_ao,UV).rgb;
    vec3 darker = 2.0 * base.rgb * occlusion;
    vec3 lighter = 1.0 - 2.0 * (1.0-base.rgb) * (1.0-occlusion);
    ALBEDO = clamp(mix(darker,lighter,step(vec3(0.5),base.rgb)),vec3(0.0),vec3(1.0));
    AO = min(occlusion.r,1.0);
    // DXBC destination r0.w with source .yzwx selects texture red (.w swizzle).
    ROUGHNESS = clamp(texture(source_leaf_roughness,UV).r,0.0,1.0);
    METALLIC = clamp(texture(source_leaf_metallic,UV).r,0.0,1.0);
    SPECULAR = 0.5;
    source_leaf_subsurface = clamp(ALBEDO * 1.5,vec3(0.0),vec3(1.0));
    // Decode BC5 positive Z and original NormalIntensity=1. The current GLB
    // lacks source TANGENT; reconstruct its UV differential basis without
    // changing mesh arrays. This remains a documented source-tangent gap.
    vec2 nxy = texture(source_leaf_normal,UV).rg * 2.0 - 1.0;
    vec3 tangent_normal = normalize(vec3(nxy,sqrt(max(0.0,1.0-dot(nxy,nxy)))));
    vec3 dp1=dFdx(VERTEX), dp2=dFdy(VERTEX);
    vec2 duv1=dFdx(UV), duv2=dFdy(UV);
    float determinant=duv1.x*duv2.y-duv1.y*duv2.x;
    float face_sign=FRONT_FACING ? 1.0 : -1.0;
    // Godot cull_disabled already flips NORMAL; undo this before source TBN.
    vec3 n=normalize(NORMAL)*face_sign;
    vec3 t=TANGENT;
    vec3 b=BINORMAL;
    if (min(length(t),length(b)) < 0.1 && abs(determinant)>0.000000000001) {
        t=normalize((dp1*duv2.y-dp2*duv1.y)/determinant);
        b=normalize((dp2*duv1.x-dp1*duv2.x)/determinant);
    }
    NORMAL=normalize(t*tangent_normal.x+b*tangent_normal.y+n*tangent_normal.z);
    NORMAL*=face_sign;
    EMISSION=vec3(0.0);
    source_lf_fragment_world=(INV_VIEW_MATRIX*vec4(VERTEX,1.0)).xyz;
    source_lf_camera_distance=length(VERTEX);
    source_lf_f0=mix(vec3(0.04),ALBEDO,METALLIC);
    if (audit_view>0) {
        vec3 display=ALBEDO;
        if (audit_view==2) display=vec3(ROUGHNESS);
        if (audit_view==3) display=vec3(AO);
        if (audit_view==4) display=NORMAL*0.5+0.5;
        if (audit_view==5) display=source_leaf_subsurface;
        ALBEDO=vec3(0.0); EMISSION=display; SPECULAR=0.0;
        source_lf_f0=vec3(0.0); source_leaf_subsurface=vec3(0.0);
    }
}
