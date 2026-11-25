// M_OceanWater_1_Inst1 cooked PS29196. Opaque bagua decorations, not ocean planes.
// Original world-XY four-way samples; no vertex displacement exists in source VS.
shader_type spatial;
render_mode cull_back;
uniform sampler2D source_small_normal : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D source_large_normal : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D source_large_height : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D source_foam : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec3 source_water_color = vec3(0.0,0.01633399911224842,0.019999999552965164);
uniform vec3 source_fresnel_color = vec3(0.003261999925598502,0.07291699945926666,0.0);
uniform float source_time_override = -1.0;
uniform int audit_view = 0;
vec3 unpack_wave(vec2 raw) {
    vec2 xy = raw*2.0-1.0;
    return vec3(xy,sqrt(max(1.0-dot(xy,xy),0.0)));
}
vec2 motion_uv(vec2 uv,float tick,int sample_index) {
    if(sample_index==0) { return uv+tick*vec2(0.1,0.1); }
    if(sample_index==1) { return uv+tick*vec2(-0.1,-0.1)+vec2(0.4181,0.3548); }
    if(sample_index==2) { return uv+tick*vec2(-0.1,0.1)+vec2(0.864861,0.148384); }
    return uv+tick*vec2(0.1,-0.1)+vec2(0.65134,0.751638);
}
void fragment() {
    float tick = source_time_override < 0.0 ? TIME : source_time_override;
    vec3 world_position = (INV_VIEW_MATRIX*vec4(VERTEX,1.0)).xyz;
    vec2 ue_xy_cm = world_position.xz*100.0;
    vec2 small_uv = ue_xy_cm/335.48883056640625;
    vec2 large_uv = ue_xy_cm/2800.0-vec2(0.5);
    large_uv = vec2(dot(vec2(0.944263,-0.329192),large_uv),
                    dot(vec2(0.329192,0.944263),large_uv))+vec2(0.5);
    float small_time = tick*0.6451320201158524;
    float large_time = tick*0.30000000447034836;
    vec3 small_sum = vec3(0.0);
    vec3 large_sum = vec3(0.0);
    float height_sum = 0.0;
    for(int i=0;i<4;i++) {
        small_sum += unpack_wave(texture(source_small_normal,motion_uv(small_uv,small_time,i)).rg);
        vec2 luv = motion_uv(large_uv,large_time,i);
        large_sum += unpack_wave(texture(source_large_normal,luv).rg);
        height_sum += texture(source_large_height,luv).r;
    }
    vec3 tangent_normal = normalize(small_sum*0.12999999523162842*vec3(0.25,0.25,0.05)
                         + large_sum*vec3(0.25,0.25,(3.0-2.9*0.800000011920929)*0.25));
    vec3 tangent_basis = TANGENT;
    vec3 binormal_basis = BINORMAL;
    if(min(length(tangent_basis),length(binormal_basis))<0.1) {
        vec3 dx = dFdx(VERTEX);
        vec3 dy = dFdy(VERTEX);
        vec2 ux = dFdx(UV);
        vec2 uy = dFdy(UV);
        float determinant = ux.x*uy.y-ux.y*uy.x;
        if(abs(determinant)>0.000000000001) {
            tangent_basis = normalize((dx*uy.y-dy*ux.y)/determinant);
            binormal_basis = normalize((dy*ux.x-dx*uy.x)/determinant);
        }
    }
    vec3 mapped_normal = normalize(tangent_basis*tangent_normal.x+binormal_basis*tangent_normal.y+normalize(NORMAL)*tangent_normal.z);
    float facing = max(1.0-max(abs(1.0-max(dot(mapped_normal,VIEW),0.0)),0.0001),0.0);
    vec3 tint = mix(source_water_color,source_fresnel_color,facing);
    vec2 foam_uv = ue_xy_cm/1024.0+(vec2(1.0)-large_sum.xy*0.25)*0.20000000298023224;
    vec3 foam_sum = vec3(0.0);
    for(int i=0;i<4;i++) {
        foam_sum += texture(source_foam,motion_uv(foam_uv,tick*0.15000000223517418,i)).rgb;
    }
    vec3 foam_mean = foam_sum*0.25;
    float height_mean = height_sum*0.25;
    float height_mask = clamp(pow(max(height_mean*height_mean,0.0),7.5)*2400.0,0.0,1.0);
    ALBEDO = clamp(tint+(foam_mean-tint)*foam_mean.g*height_mask,vec3(0.0),vec3(1.0));
    NORMAL = mapped_normal;
    METALLIC = 0.07999999821186066;
    // UE F0=0.08*MaxSpecular; Godot F0=0.16*SPECULAR^2.
    SPECULAR = 0.7071067811865476;
    ROUGHNESS = 0.01;
    EMISSION = vec3(0.0);
    if(audit_view!=0) {
        vec3 value = ALBEDO;
        if(audit_view==2) { value=tangent_normal*0.5+0.5; }
        if(audit_view==3) { value=vec3(height_mask); }
        if(audit_view==4) { value=foam_mean; }
        ALBEDO=vec3(0.0);
        EMISSION=value;
    }
}

