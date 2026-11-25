shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
// Opaque M_BetterCrystal_8Samples. Original volume ray affects internal noise only.
uniform vec4 source_constants[39];
uniform float source_mip_bias = 0.0;
uniform sampler2D source_t6 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t7 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t8 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t9 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t10 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t11 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t12 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t13 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t14 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D source_t15 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
varying vec3 source_world_cm;
varying vec4 source_tangent_ue;
varying vec4 source_normal_ue;
void vertex() {
    mat3 axis = mat3(vec3(1.0,0.0,0.0),vec3(0.0,0.0,1.0),vec3(0.0,1.0,0.0));
    mat3 source_basis = axis * mat3(MODEL_MATRIX) * axis;
    mat3 native_rotation = mat3(normalize(source_basis[0]),normalize(source_basis[1]),normalize(source_basis[2]));
    float original_hand = sign(dot(cross(NORMAL,TANGENT),BINORMAL));
    source_tangent_ue = vec4(native_rotation * (axis*TANGENT),0.0);
    source_normal_ue = vec4(native_rotation * (axis*NORMAL),original_hand*sign(determinant(source_basis)));
    source_world_cm = ((MODEL_MATRIX*vec4(VERTEX,1.0)).xyz).xzy*100.0;
}
void fragment() {
    mat3 axis = mat3(vec3(1.0,0.0,0.0),vec3(0.0,0.0,1.0),vec3(0.0,1.0,0.0));
    mat3 source_basis = axis * mat3(MODEL_MATRIX) * axis;
    mat3 source_inverse = inverse(source_basis);
    vec3 source_translation_cm = MODEL_MATRIX[3].xyz.xzy*100.0;
    vec3 source_camera_cm = CAMERA_POSITION_WORLD.xzy*100.0;
    vec4 source_primitive[10];
    source_primitive[0] = vec4(source_basis[0],0.0);
    source_primitive[1] = vec4(source_basis[1],0.0);
    source_primitive[2] = vec4(source_basis[2],0.0);
    source_primitive[6] = vec4(source_inverse[0],0.0);
    source_primitive[7] = vec4(source_inverse[1],0.0);
    source_primitive[8] = vec4(source_inverse[2],0.0);
    source_primitive[9] = vec4(-(source_inverse*source_translation_cm),0.0);
    vec4 v0 = source_tangent_ue;
    vec4 v1 = source_normal_ue;
    vec4 v2 = COLOR;
    vec4 v3 = vec4(UV,0.0,0.0);
    vec4 v5 = vec4(0.0);
    vec4 r0 = vec4(0.0);
    vec4 r1 = vec4(0.0);
    vec4 r2 = vec4(0.0);
    vec4 r3 = vec4(0.0);
    vec4 r4 = vec4(0.0);
    vec4 r5 = vec4(0.0);
    vec4 r6 = vec4(0.0);
    vec4 r7 = vec4(0.0);
    vec4 r8 = vec4(0.0);
    vec4 r9 = vec4(0.0);
    vec4 r10 = vec4(0.0);
    vec4 r11 = vec4(0.0);
    vec4 r12 = vec4(0.0);
    vec4 r13 = vec4(0.0);
    vec4 r14 = vec4(0.0);
    vec4 r15 = vec4(0.0);
    // DXBC mul r0.xyz, v0.zxyz, v1.xyzx
    r0.xyz = (((v0).zxyz*(v1).xyzx)).xyz;
    // DXBC mad r0.xyz, v1.zxyz, v0.xyzx, -r0.xyzx
    r0.xyz = (((v1).zxyz*(v0).xyzx+(-(r0).xyzx))).xyz;
    // DXBC mul r0.xyz, r0.xyzx, v1.wwww
    r0.xyz = (((r0).xyzx*(v1).wwww)).xyz;
    r3 = vec4(source_world_cm,1.0);
    r2 = vec4(normalize(source_camera_cm-source_world_cm),0.0);
    // DXBC mul r4.xy, v3.xyxx, cb1[2].xyxx
    r4.xy = (((v3).xyxx*(source_constants[2]).xyxx)).xy;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r4.zw, r4.xyxx, t6.zwxy, s2, cb0[143].y
    r4.zw = (texture(source_t6, ((r4).xyxx).xy, source_mip_bias).zwxy).zw;
    // DXBC mad r4.zw, r4.zzzw, l(0x00000000, 0x00000000, 0x40000000, 0x40000000), l(0x00000000, 0x00000000, 0xbf800000, 0xbf800000)
    r4.zw = (((r4).zzzw*vec4(0.0,0.0,2.0,2.0)+vec4(0.0,0.0,-1.0,-1.0))).zw;
    // DXBC dp2 r0.w, r4.zwzz, r4.zwzz
    r0.w = (vec4(dot(((r4).zwzz).xy,((r4).zwzz).xy))).w;
    // DXBC add r0.w, -r0.w, l(0x3f800000)
    r0.w = (((-vec4((r0).w))+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC max r0.w, r0.w, l(0x00000000)
    r0.w = (max(vec4((r0).w),vec4(0.0,0.0,0.0,0.0))).w;
    // DXBC sqrt r5.z, r0.w
    r5.z = (sqrt(vec4((r0).w))).z;
    // DXBC mul r5.xy, r4.zwzz, cb1[20].zzzz
    r5.xy = (((r4).zwzz*(source_constants[20]).zzzz)).xy;
    // DXBC add r0.w, -|v1.x|, |v1.y|
    r0.w = (((-abs(vec4((v1).x)))+abs(vec4((v1).y)))).w;
    // DXBC div r4.zw, r0.wwww, cb1[21].xxxw
    r4.zw = (((r0).wwww/(source_constants[21]).xxxw)).zw;
    // DXBC add r4.zw, r4.zzzw, l(0x00000000, 0x00000000, 0x3f800000, 0x3f800000)
    r4.zw = (((r4).zzzw+vec4(0.0,0.0,1.0,1.0))).zw;
    // DXBC mul_sat r4.zw, r4.zzzw, l(0x00000000, 0x00000000, 0x3f000000, 0x3f000000)
    r4.zw = (clamp(((r4).zzzw*vec4(0.0,0.0,0.5,0.5)),vec4(0.0),vec4(1.0))).zw;
    // DXBC mad r6.xyz, r4.zzzz, l(0xbf800000, 0x3f800000, 0x00000000, 0x00000000), l(0x3f800000, 0x00000000, 0x00000000, 0x00000000)
    r6.xyz = (((r4).zzzz*vec4(-1.0,1.0,0.0,0.0)+vec4(1.0,0.0,0.0,0.0))).xyz;
    // DXBC max r0.w, |v1.y|, |v1.x|
    r0.w = (max(abs(vec4((v1).y)),abs(vec4((v1).x)))).w;
    // DXBC add r0.w, -r0.w, |v1.z|
    r0.w = (((-vec4((r0).w))+abs(vec4((v1).z)))).w;
    // DXBC div r7.xy, r0.wwww, cb1[21].xwxx
    r7.xy = (((r0).wwww/(source_constants[21]).xwxx)).xy;
    // DXBC add r7.xy, r7.xyxx, l(0x3f800000, 0x3f800000, 0x00000000, 0x00000000)
    r7.xy = (((r7).xyxx+vec4(1.0,1.0,0.0,0.0))).xy;
    // DXBC mul_sat r7.xy, r7.xyxx, l(0x3f000000, 0x3f000000, 0x00000000, 0x00000000)
    r7.xy = (clamp(((r7).xyxx*vec4(0.5,0.5,0.0,0.0)),vec4(0.0),vec4(1.0))).xy;
    // DXBC add r8.xyz, -r6.xyzx, l(0x00000000, 0x00000000, 0x3f800000, 0x00000000)
    r8.xyz = (((-(r6).xyzx)+vec4(0.0,0.0,1.0,0.0))).xyz;
    // DXBC mad r6.xyz, r7.xxxx, r8.xyzx, r6.xyzx
    r6.xyz = (((r7).xxxx*(r8).xyzx+(r6).xyzx)).xyz;
    // DXBC add r7.xzw, r3.xxyz, cb1[4].xxyz
    r7.xzw = (((r3).xxyz+(source_constants[4]).xxyz)).xzw;
    // DXBC mul r7.xzw, r7.xxzw, cb1[21].zzzz
    r7.xzw = (((r7).xxzw*(source_constants[21]).zzzz)).xzw;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r8.xy, r7.zwzz, t7.xyzw, s3, cb0[143].y
    r8.xy = (texture(source_t7, ((r7).zwzz).xy, source_mip_bias).xyzw).xy;
    // DXBC mad r8.xy, r8.xyxx, l(0x40000000, 0x40000000, 0x00000000, 0x00000000), l(0xbf800000, 0xbf800000, 0x00000000, 0x00000000)
    r8.xy = (((r8).xyxx*vec4(2.0,2.0,0.0,0.0)+vec4(-1.0,-1.0,0.0,0.0))).xy;
    // DXBC dp2 r0.w, r8.xyxx, r8.xyxx
    r0.w = (vec4(dot(((r8).xyxx).xy,((r8).xyxx).xy))).w;
    // DXBC add r0.w, -r0.w, l(0x3f800000)
    r0.w = (((-vec4((r0).w))+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC max r0.w, r0.w, l(0x00000000)
    r0.w = (max(vec4((r0).w),vec4(0.0,0.0,0.0,0.0))).w;
    // DXBC sqrt r8.z, r0.w
    r8.z = (sqrt(vec4((r0).w))).z;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r9.xy, r7.xwxx, t7.xyzw, s3, cb0[143].y
    r9.xy = (texture(source_t7, ((r7).xwxx).xy, source_mip_bias).xyzw).xy;
    // DXBC mad r9.xy, r9.xyxx, l(0x40000000, 0x40000000, 0x00000000, 0x00000000), l(0xbf800000, 0xbf800000, 0x00000000, 0x00000000)
    r9.xy = (((r9).xyxx*vec4(2.0,2.0,0.0,0.0)+vec4(-1.0,-1.0,0.0,0.0))).xy;
    // DXBC dp2 r0.w, r9.xyxx, r9.xyxx
    r0.w = (vec4(dot(((r9).xyxx).xy,((r9).xyxx).xy))).w;
    // DXBC add r0.w, -r0.w, l(0x3f800000)
    r0.w = (((-vec4((r0).w))+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC max r0.w, r0.w, l(0x00000000)
    r0.w = (max(vec4((r0).w),vec4(0.0,0.0,0.0,0.0))).w;
    // DXBC sqrt r9.z, r0.w
    r9.z = (sqrt(vec4((r0).w))).z;
    // DXBC mul r9.xyz, r6.yyyy, r9.xyzx
    r9.xyz = (((r6).yyyy*(r9).xyzx)).xyz;
    // DXBC mad r8.xyz, r6.xxxx, r8.xyzx, r9.xyzx
    r8.xyz = (((r6).xxxx*(r8).xyzx+(r9).xyzx)).xyz;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r9.xy, r7.xzxx, t7.xyzw, s3, cb0[143].y
    r9.xy = (texture(source_t7, ((r7).xzxx).xy, source_mip_bias).xyzw).xy;
    // DXBC mad r9.xy, r9.xyxx, l(0x40000000, 0x40000000, 0x00000000, 0x00000000), l(0xbf800000, 0xbf800000, 0x00000000, 0x00000000)
    r9.xy = (((r9).xyxx*vec4(2.0,2.0,0.0,0.0)+vec4(-1.0,-1.0,0.0,0.0))).xy;
    // DXBC dp2 r0.w, r9.xyxx, r9.xyxx
    r0.w = (vec4(dot(((r9).xyxx).xy,((r9).xyxx).xy))).w;
    // DXBC add r0.w, -r0.w, l(0x3f800000)
    r0.w = (((-vec4((r0).w))+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC max r0.w, r0.w, l(0x00000000)
    r0.w = (max(vec4((r0).w),vec4(0.0,0.0,0.0,0.0))).w;
    // DXBC sqrt r9.z, r0.w
    r9.z = (sqrt(vec4((r0).w))).z;
    // DXBC mad r8.xyz, r6.zzzz, r9.xyzx, r8.xyzx
    r8.xyz = (((r6).zzzz*(r9).xyzx+(r8).xyzx)).xyz;
    // DXBC add r0.w, -v2.x, l(0x3f800000)
    r0.w = (((-vec4((v2).x))+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC mad r9.xyz, r4.wwww, l(0xbf800000, 0x3f800000, 0x00000000, 0x00000000), l(0x3f800000, 0x00000000, 0x00000000, 0x00000000)
    r9.xyz = (((r4).wwww*vec4(-1.0,1.0,0.0,0.0)+vec4(1.0,0.0,0.0,0.0))).xyz;
    // DXBC add r10.xyz, -r9.xyzx, l(0x00000000, 0x00000000, 0x3f800000, 0x00000000)
    r10.xyz = (((-(r9).xyzx)+vec4(0.0,0.0,1.0,0.0))).xyz;
    // DXBC mad r9.xyz, r7.yyyy, r10.xyzx, r9.xyzx
    r9.xyz = (((r7).yyyy*(r10).xyzx+(r9).xyzx)).xyz;
    // DXBC mul r10.xyz, r3.xyzx, cb1[22].xxxx
    r10.xyz = (((r3).xyzx*(source_constants[22]).xxxx)).xyz;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r1.w, r10.yzyy, t8.yzwx, s4, cb0[143].y
    r1.w = (texture(source_t8, ((r10).yzyy).xy, source_mip_bias).yzwx).w;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r2.w, r10.xzxx, t8.yzwx, s4, cb0[143].y
    r2.w = (texture(source_t8, ((r10).xzxx).xy, source_mip_bias).yzwx).w;
    // DXBC mul r2.w, r2.w, r9.y
    r2.w = ((vec4((r2).w)*vec4((r9).y))).w;
    // DXBC mad r1.w, r9.x, r1.w, r2.w
    r1.w = ((vec4((r9).x)*vec4((r1).w)+vec4((r2).w))).w;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r2.w, r10.xyxx, t8.yzwx, s4, cb0[143].y
    r2.w = (texture(source_t8, ((r10).xyxx).xy, source_mip_bias).yzwx).w;
    // DXBC mad r1.w, r9.z, r2.w, r1.w
    r1.w = ((vec4((r9).z)*vec4((r2).w)+vec4((r1).w))).w;
    // DXBC mul r1.w, r0.w, r1.w
    r1.w = ((vec4((r0).w)*vec4((r1).w))).w;
    // DXBC mad_sat r0.w, r1.w, cb1[22].y, r0.w
    r0.w = (clamp((vec4((r1).w)*vec4((source_constants[22]).y)+vec4((r0).w)),vec4(0.0),vec4(1.0))).w;
    // DXBC ge r1.w, l(0x00000000), r0.w
    r1.w = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),vec4((r0).w)))).w;
    // DXBC log r0.w, r0.w
    r0.w = (log2(vec4((r0).w))).w;
    // DXBC mul r0.w, r0.w, cb1[22].z
    r0.w = ((vec4((r0).w)*vec4((source_constants[22]).z))).w;
    // DXBC exp r0.w, r0.w
    r0.w = (exp2(vec4((r0).w))).w;
    // DXBC movc r0.w, r1.w, l(0x00000000), r0.w
    r0.w = (mix(vec4((r0).w),vec4(0.0,0.0,0.0,0.0),notEqual(vec4((r1).w),vec4(0.0)))).w;
    // DXBC add r8.xyz, -r5.xyzx, r8.xyzx
    r8.xyz = (((-(r5).xyzx)+(r8).xyzx)).xyz;
    // DXBC mad r5.xyz, r0.wwww, r8.xyzx, r5.xyzx
    r5.xyz = (((r0).wwww*(r8).xyzx+(r5).xyzx)).xyz;
    // DXBC mad r5.xyz, r5.xyzx, cb0[138].wwww, cb0[138].xyzx
    r5.xyz = (((r5).xyzx*(vec4(0.0,0.0,0.0,1.0)).wwww+(vec4(0.0,0.0,0.0,1.0)).xyzx)).xyz;
    // DXBC dp3 r1.w, r5.xyzx, r5.xyzx
    r1.w = (vec4(dot(((r5).xyzx).xyz,((r5).xyzx).xyz))).w;
    // DXBC rsq r1.w, r1.w
    r1.w = (inversesqrt(vec4((r1).w))).w;
    // DXBC mul r5.xyz, r1.wwww, r5.xyzx
    r5.xyz = (((r1).wwww*(r5).xyzx)).xyz;
    // DXBC mul r0.xyz, r0.xyzx, r5.yyyy
    r0.xyz = (((r0).xyzx*(r5).yyyy)).xyz;
    // DXBC mad r0.xyz, r5.xxxx, v0.yzxy, r0.xyzx
    r0.xyz = (((r5).xxxx*(v0).yzxy+(r0).xyzx)).xyz;
    // DXBC mad r0.xyz, r5.zzzz, v1.yzxy, r0.xyzx
    r0.xyz = (((r5).zzzz*(v1).yzxy+(r0).xyzx)).xyz;
    // DXBC dp3 r1.w, r0.xyzx, r0.xyzx
    r1.w = (vec4(dot(((r0).xyzx).xyz,((r0).xyzx).xyz))).w;
    // DXBC rsq r1.w, r1.w
    r1.w = (inversesqrt(vec4((r1).w))).w;
    // DXBC mul r0.xyz, r0.xyzx, r1.wwww
    r0.xyz = (((r0).xyzx*(r1).wwww)).xyz;
    // DXBC imul null, r1.w, v5.x, l(0x00000024)
    r1.w = ((vec4((v5).x) * vec4(36.0,36.0,36.0,36.0))).w;
    // DXBC ld_structured_indexable(structured_buffer, stride=16)(mixed,mixed,mixed,mixed) r5.xyz, r1.w, l(0x00000000), t0.xyzx
    r5.xyz = (source_primitive[int((vec4((r1).w)).x)].xyzx).xyz;
    // DXBC dp3 r1.w, -r5.xyzx, -r5.xyzx
    r1.w = (vec4(dot(((-(r5).xyzx)).xyz,((-(r5).xyzx)).xyz))).w;
    // DXBC sqrt r1.w, r1.w
    r1.w = (sqrt(vec4((r1).w))).w;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r8.xyz, r4.xyxx, t9.xyzw, s5, cb0[143].y
    r8.xyz = (texture(source_t9, ((r4).xyxx).xy, source_mip_bias).xyzw).xyz;
    // DXBC add r2.w, -r8.y, l(0x3f800000)
    r2.w = (((-vec4((r8).y))+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC add r4.z, -r8.y, r2.w
    r4.z = (((-vec4((r8).y))+vec4((r2).w))).z;
    // DXBC mad r4.z, cb1[23].w, r4.z, r8.y
    r4.z = ((vec4((source_constants[23]).w)*vec4((r4).z)+vec4((r8).y))).z;
    // DXBC add r4.w, -r8.x, r8.z
    r4.w = (((-vec4((r8).x))+vec4((r8).z))).w;
    // DXBC mad r4.w, cb1[23].w, r4.w, r8.x
    r4.w = ((vec4((source_constants[23]).w)*vec4((r4).w)+vec4((r8).x))).w;
    // DXBC lt r8.xz, l(0x3727c5ac, 0x00000000, 0x3727c5ac, 0x00000000), |cb1[24].xxwx|
    r8.xz = (vec4(lessThan(vec4(9.999999747378752e-06,0.0,9.999999747378752e-06,0.0),abs((source_constants[24]).xxwx)))).xz;
    // DXBC ge r9.xy, cb1[24].xwxx, l(0x00000000, 0x00000000, 0x00000000, 0x00000000)
    r9.xy = (vec4(greaterThanEqual((source_constants[24]).xwxx,vec4(0.0,0.0,0.0,0.0)))).xy;
    // DXBC movc r4.z, r9.x, r4.z, r4.w
    r4.z = (mix(vec4((r4).w),vec4((r4).z),notEqual(vec4((r9).x),vec4(0.0)))).z;
    // DXBC movc r4.z, r8.x, r4.z, r4.w
    r4.z = (mix(vec4((r4).w),vec4((r4).z),notEqual(vec4((r8).x),vec4(0.0)))).z;
    // DXBC mul r4.z, r4.z, cb1[24].y
    r4.z = ((vec4((r4).z)*vec4((source_constants[24]).y))).z;
    // DXBC add r9.xzw, -r3.xxyz, cb0[67].xxyz
    r9.xzw = (((-(r3).xxyz)+(vec4(source_camera_cm,0.0)).xxyz)).xzw;
    // DXBC dp3 r4.w, r9.xzwx, r9.xzwx
    r4.w = (vec4(dot(((r9).xzwx).xyz,((r9).xzwx).xyz))).w;
    // DXBC sqrt r4.w, r4.w
    r4.w = (sqrt(vec4((r4).w))).w;
    // DXBC div r9.xzw, r9.xxzw, r4.wwww
    r9.xzw = (((r9).xxzw/(r4).wwww)).xzw;
    // DXBC imad r10.xyzw, v5.xxxx, l(0x00000024, 0x00000024, 0x00000024, 0x00000024), l(0x00000006, 0x00000007, 0x00000008, 0x00000009)
    r10.xyzw = (((v5).xxxx*vec4(36.0,36.0,36.0,36.0)+vec4(6.0,7.0,8.0,9.0))).xyzw;
    // DXBC ld_structured_indexable(structured_buffer, stride=16)(mixed,mixed,mixed,mixed) r11.xyz, r10.x, l(0x00000000), t0.xyzx
    r11.xyz = (source_primitive[int((vec4((r10).x)).x)].xyzx).xyz;
    // DXBC ld_structured_indexable(structured_buffer, stride=16)(mixed,mixed,mixed,mixed) r12.xyz, r10.y, l(0x00000000), t0.xyzx
    r12.xyz = (source_primitive[int((vec4((r10).y)).x)].xyzx).xyz;
    // DXBC ld_structured_indexable(structured_buffer, stride=16)(mixed,mixed,mixed,mixed) r13.xyz, r10.z, l(0x00000000), t0.xyzx
    r13.xyz = (source_primitive[int((vec4((r10).z)).x)].xyzx).xyz;
    // DXBC mov r14.x, r11.x
    r14.x = (vec4((r11).x)).x;
    // DXBC mov r14.y, r12.x
    r14.y = (vec4((r12).x)).y;
    // DXBC mov r14.z, r13.x
    r14.z = (vec4((r13).x)).z;
    // DXBC dp3 r10.x, r9.xzwx, r14.xyzx
    r10.x = (vec4(dot(((r9).xzwx).xyz,((r14).xyzx).xyz))).x;
    // DXBC mov r15.x, r11.y
    r15.x = (vec4((r11).y)).x;
    // DXBC mov r15.y, r12.y
    r15.y = (vec4((r12).y)).y;
    // DXBC mov r15.z, r13.y
    r15.z = (vec4((r13).y)).z;
    // DXBC dp3 r10.y, r9.xzwx, r15.xyzx
    r10.y = (vec4(dot(((r9).xzwx).xyz,((r15).xyzx).xyz))).y;
    // DXBC mov r13.x, r11.z
    r13.x = (vec4((r11).z)).x;
    // DXBC mov r13.y, r12.z
    r13.y = (vec4((r12).z)).y;
    // DXBC dp3 r10.z, r9.xzwx, r13.xyzx
    r10.z = (vec4(dot(((r9).xzwx).xyz,((r13).xyzx).xyz))).z;
    // DXBC movc r10.xyz, r9.yyyy, -r10.xyzx, -r9.xzwx
    r10.xyz = (mix((-(r9).xzwx),(-(r10).xyzx),notEqual((r9).yyyy,vec4(0.0)))).xyz;
    // DXBC movc r9.xzw, r8.zzzz, r10.xxyz, -r9.xxzw
    r9.xzw = (mix((-(r9).xxzw),(r10).xxyz,notEqual((r8).zzzz,vec4(0.0)))).xzw;
    // DXBC ld_structured_indexable(structured_buffer, stride=16)(mixed,mixed,mixed,mixed) r10.xyz, r10.w, l(0x00000000), t0.xyzx
    r10.xyz = (source_primitive[int((vec4((r10).w)).x)].xyzx).xyz;
    // DXBC mov r3.w, l(0x3f800000)
    r3.w = (vec4(1.0,1.0,1.0,1.0)).w;
    // DXBC mov r14.w, r10.x
    r14.w = (vec4((r10).x)).w;
    // DXBC dp4 r11.x, r3.xyzw, r14.xyzw
    r11.x = (vec4(dot(((r3).xyzw).xyzw,((r14).xyzw).xyzw))).x;
    // DXBC mov r15.w, r10.y
    r15.w = (vec4((r10).y)).w;
    // DXBC dp4 r11.y, r3.xyzw, r15.xyzw
    r11.y = (vec4(dot(((r3).xyzw).xyzw,((r15).xyzw).xyzw))).y;
    // DXBC mov r13.w, r10.z
    r13.w = (vec4((r10).z)).w;
    // DXBC dp4 r11.z, r3.xyzw, r13.xyzw
    r11.z = (vec4(dot(((r3).xyzw).xyzw,((r13).xyzw).xyzw))).z;
    // DXBC add r10.xyz, r11.xyzx, cb1[8].xyzx
    r10.xyz = (((r11).xyzx+(source_constants[8]).xyzx)).xyz;
    // DXBC mul r12.xyz, r1.wwww, r10.xyzx
    r12.xyz = (((r1).wwww*(r10).xyzx)).xyz;
    // DXBC lt r1.w, l(0x3727c5ac), |cb1[23].z|
    r1.w = (vec4(lessThan(vec4(9.999999747378752e-06,9.999999747378752e-06,9.999999747378752e-06,9.999999747378752e-06),abs(vec4((source_constants[23]).z))))).w;
    // DXBC ge r3.w, cb1[23].z, l(0x00000000)
    r3.w = (vec4(greaterThanEqual(vec4((source_constants[23]).z),vec4(0.0,0.0,0.0,0.0)))).w;
    // DXBC movc r10.xyz, r3.wwww, r10.xyzx, r12.xyzx
    r10.xyz = (mix((r12).xyzx,(r10).xyzx,notEqual((r3).wwww,vec4(0.0)))).xyz;
    // DXBC movc r10.xyz, r1.wwww, r10.xyzx, r12.xyzx
    r10.xyz = (mix((r12).xyzx,(r10).xyzx,notEqual((r1).wwww,vec4(0.0)))).xyz;
    // DXBC add r12.xyz, r3.xyzx, cb1[8].xyzx
    r12.xyz = (((r3).xyzx+(source_constants[8]).xyzx)).xyz;
    // DXBC movc r10.xyz, r9.yyyy, r10.xyzx, r12.xyzx
    r10.xyz = (mix((r12).xyzx,(r10).xyzx,notEqual((r9).yyyy,vec4(0.0)))).xyz;
    // DXBC movc r10.xyz, r8.zzzz, r10.xyzx, r12.xyzx
    r10.xyz = (mix((r12).xyzx,(r10).xyzx,notEqual((r8).zzzz,vec4(0.0)))).xyz;
    // DXBC dp3 r12.x, r0.zxyz, r14.xyzx
    r12.x = (vec4(dot(((r0).zxyz).xyz,((r14).xyzx).xyz))).x;
    // DXBC dp3 r12.y, r0.zxyz, r15.xyzx
    r12.y = (vec4(dot(((r0).zxyz).xyz,((r15).xyzx).xyz))).y;
    // DXBC dp3 r12.z, r0.zxyz, r13.xyzx
    r12.z = (vec4(dot(((r0).zxyz).xyz,((r13).xyzx).xyz))).z;
    // DXBC dp3 r1.w, r12.xyzx, r12.xyzx
    r1.w = (vec4(dot(((r12).xyzx).xyz,((r12).xyzx).xyz))).w;
    // DXBC sqrt r1.w, r1.w
    r1.w = (sqrt(vec4((r1).w))).w;
    // DXBC div r12.xyz, r12.xyzx, r1.wwww
    r12.xyz = (((r12).xyzx/(r1).wwww)).xyz;
    // DXBC movc r12.xyz, r9.yyyy, r12.xyzx, r0.zxyz
    r12.xyz = (mix((r0).zxyz,(r12).xyzx,notEqual((r9).yyyy,vec4(0.0)))).xyz;
    // DXBC movc r8.xzw, r8.zzzz, r12.xxyz, r0.zzxy
    r8.xzw = (mix((r0).zzxy,(r12).xxyz,notEqual((r8).zzzz,vec4(0.0)))).xzw;
    // DXBC mul r12.xy, v3.xyxx, cb1[26].yyyy
    r12.xy = (((v3).xyxx*(source_constants[26]).yyyy)).xy;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r1.w, r12.xyxx, t10.yzwx, s6, cb0[143].y
    r1.w = (texture(source_t10, ((r12).xyxx).xy, source_mip_bias).yzwx).w;
    // DXBC add_sat r1.w, r1.w, cb1[26].z
    r1.w = (clamp((vec4((r1).w)+vec4((source_constants[26]).z)),vec4(0.0),vec4(1.0))).w;
    // DXBC lt r3.w, l(0x3727c5ac), |cb1[26].w|
    r3.w = (vec4(lessThan(vec4(9.999999747378752e-06,9.999999747378752e-06,9.999999747378752e-06,9.999999747378752e-06),abs(vec4((source_constants[26]).w))))).w;
    // DXBC ge r4.w, cb1[26].w, l(0x00000000)
    r4.w = (vec4(greaterThanEqual(vec4((source_constants[26]).w),vec4(0.0,0.0,0.0,0.0)))).w;
    // DXBC movc r1.w, r4.w, r1.w, l(0x3f800000)
    r1.w = (mix(vec4(1.0,1.0,1.0,1.0),vec4((r1).w),notEqual(vec4((r4).w),vec4(0.0)))).w;
    // DXBC movc r1.w, r3.w, r1.w, l(0x3f800000)
    r1.w = (mix(vec4(1.0,1.0,1.0,1.0),vec4((r1).w),notEqual(vec4((r3).w),vec4(0.0)))).w;
    // DXBC dp3 r3.w, r9.xzwx, r9.xzwx
    r3.w = (vec4(dot(((r9).xzwx).xyz,((r9).xzwx).xyz))).w;
    // DXBC rsq r3.w, r3.w
    r3.w = (inversesqrt(vec4((r3).w))).w;
    // DXBC mul r9.xyz, r3.wwww, r9.xzwx
    r9.xyz = (((r3).wwww*(r9).xzwx)).xyz;
    // DXBC div r3.w, l(0x3f800000, 0x3f800000, 0x3f800000, 0x3f800000), cb1[28].w
    r3.w = ((vec4(1.0,1.0,1.0,1.0)/vec4((source_constants[28]).w))).w;
    // DXBC mad_sat r1.w, -r3.w, r1.w, l(0x3f800000)
    r1.w = (clamp(((-vec4((r3).w))*vec4((r1).w)+vec4(1.0,1.0,1.0,1.0)),vec4(0.0),vec4(1.0))).w;
    // DXBC dp3 r3.w, r9.xyzx, r8.xzwx
    r3.w = (vec4(dot(((r9).xyzx).xyz,((r8).xzwx).xyz))).w;
    // DXBC mul r4.w, r1.w, r1.w
    r4.w = ((vec4((r1).w)*vec4((r1).w))).w;
    // DXBC mad r5.w, -r3.w, r3.w, l(0x3f800000)
    r5.w = (((-vec4((r3).w))*vec4((r3).w)+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC mad r4.w, -r4.w, r5.w, l(0x3f800000)
    r4.w = (((-vec4((r4).w))*vec4((r5).w)+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC sqrt r5.w, r4.w
    r5.w = (sqrt(vec4((r4).w))).w;
    // DXBC mad r3.w, r1.w, r3.w, r5.w
    r3.w = ((vec4((r1).w)*vec4((r3).w)+vec4((r5).w))).w;
    // DXBC ge r4.w, r4.w, l(0x00000000)
    r4.w = (vec4(greaterThanEqual(vec4((r4).w),vec4(0.0,0.0,0.0,0.0)))).w;
    // DXBC mul r8.xzw, r8.xxzw, r3.wwww
    r8.xzw = (((r8).xxzw*(r3).wwww)).xzw;
    // DXBC mad r8.xzw, r1.wwww, r9.xxyz, -r8.xxzw
    r8.xzw = (((r1).wwww*(r9).xxyz+(-(r8).xxzw))).xzw;
    // DXBC and r8.xzw, r4.wwww, r8.xxzw
    r8.xzw = (mix(vec4(0.0),(r8).xxzw,notEqual((r4).wwww,vec4(0.0)))).xzw;
    // DXBC mul r1.w, cb1[30].x, l(0x3f733333)
    r1.w = ((vec4((source_constants[30]).x)*vec4(0.949999988079071,0.949999988079071,0.949999988079071,0.949999988079071))).w;
    // DXBC mov r9.xyz, l(0x00000000,0x00000000,0x00000000,0x00000000)
    r9.xyz = (vec4(0.0,0.0,0.0,0.0)).xyz;
    // DXBC mov r3.w, l(0x00000000)
    r3.w = (vec4(0.0,0.0,0.0,0.0)).w;
    // DXBC loop
    for(int source_step=0; source_step<8; source_step++) {
    // DXBC ige r4.w, r3.w, l(0x00000008)
    r4.w = (vec4(greaterThanEqual(vec4((r3).w),vec4(8.0,8.0,8.0,8.0)))).w;
    // DXBC breakc_nz r4.w
    if ((vec4((r4).w)).x != 0.0) { break; }
    // DXBC mad r12.xyz, r8.xzwx, r9.zzzz, r10.xyzx
    r12.xyz = (((r8).xzwx*(r9).zzzz+(r10).xyzx)).xyz;
    // DXBC mul r13.xy, r12.xyxx, cb1[29].yyyy
    r13.xy = (((r12).xyxx*(source_constants[29]).yyyy)).xy;
    // DXBC sample_indexable(texture2d)(float,float,float,float) r13.xy, r13.xyxx, t11.xyzw, s7
    r13.xy = (texture(source_t11, ((r13).xyxx).xy).xyzw).xy;
    // DXBC mad r13.zw, r12.zzzy, cb1[29].yyyy, l(0x00000000, 0x00000000, 0x43103ae1, 0x45aa20f6)
    r13.zw = (((r12).zzzy*(source_constants[29]).yyyy+vec4(0.0,0.0,144.22999572753906,5444.1201171875))).zw;
    // DXBC sample_indexable(texture2d)(float,float,float,float) r13.zw, r13.zwzz, t11.zwxy, s7
    r13.zw = (texture(source_t11, ((r13).zwzz).xy).zwxy).zw;
    // DXBC mul r13.xy, r13.zwzz, r13.xyxx
    r13.xy = (((r13).zwzz*(r13).xyxx)).xy;
    // DXBC mad r13.zw, r12.xxxz, cb1[29].yyyy, l(0x00000000, 0x00000000, 0x454371c3, 0x44be43d7)
    r13.zw = (((r12).xxxz*(source_constants[29]).yyyy+vec4(0.0,0.0,3127.110107421875,1522.1199951171875))).zw;
    // DXBC sample_indexable(texture2d)(float,float,float,float) r13.zw, r13.zwzz, t11.zwxy, s7
    r13.zw = (texture(source_t11, ((r13).zwzz).xy).zwxy).zw;
    // DXBC mul r13.xy, r13.zwzz, r13.xyxx
    r13.xy = (((r13).zwzz*(r13).xyxx)).xy;
    // DXBC add r12.xyz, r12.xyzx, -cb1[16].xyzx
    r12.xyz = (((r12).xyzx+(-(source_constants[16]).xyzx))).xyz;
    // DXBC dp3 r4.w, r12.xyzx, cb1[15].xyzx
    r4.w = (vec4(dot(((r12).xyzx).xyz,((source_constants[15]).xyzx).xyz))).w;
    // DXBC add r4.w, r4.w, cb1[31].y
    r4.w = ((vec4((r4).w)+vec4((source_constants[31]).y))).w;
    // DXBC mul_sat r4.w, r4.w, cb1[30].w
    r4.w = (clamp((vec4((r4).w)*vec4((source_constants[30]).w)),vec4(0.0),vec4(1.0))).w;
    // DXBC add_sat r4.w, r4.w, cb1[31].x
    r4.w = (clamp((vec4((r4).w)+vec4((source_constants[31]).x)),vec4(0.0),vec4(1.0))).w;
    // DXBC log r12.xy, r13.xyxx
    r12.xy = (log2((r13).xyxx)).xy;
    // DXBC mul r5.w, r12.x, cb1[29].w
    r5.w = ((vec4((r12).x)*vec4((source_constants[29]).w))).w;
    // DXBC exp r5.w, r5.w
    r5.w = (exp2(vec4((r5).w))).w;
    // DXBC mul r5.w, r5.w, cb1[29].z
    r5.w = ((vec4((r5).w)*vec4((source_constants[29]).z))).w;
    // DXBC mul_sat r5.w, r5.w, l(0x3fb9999a)
    r5.w = (clamp((vec4((r5).w)*vec4(1.4500000476837158,1.4500000476837158,1.4500000476837158,1.4500000476837158)),vec4(0.0),vec4(1.0))).w;
    // DXBC log r5.w, r5.w
    r5.w = (log2(vec4((r5).w))).w;
    // DXBC mul r5.w, r5.w, l(0x3fa00000)
    r5.w = ((vec4((r5).w)*vec4(1.25,1.25,1.25,1.25))).w;
    // DXBC exp r5.w, r5.w
    r5.w = (exp2(vec4((r5).w))).w;
    // DXBC itof r6.w, r3.w
    r6.w = (vec4((r3).w)).w;
    // DXBC mad r6.w, -r6.w, l(0x3d4ccccd), l(0x3f800000)
    r6.w = (((-vec4((r6).w))*vec4(0.05000000074505806,0.05000000074505806,0.05000000074505806,0.05000000074505806)+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC mul r5.w, r5.w, r6.w
    r5.w = ((vec4((r5).w)*vec4((r6).w))).w;
    // DXBC mad r9.x, r5.w, r4.w, r9.x
    r9.x = ((vec4((r5).w)*vec4((r4).w)+vec4((r9).x))).x;
    // DXBC mul r5.w, r1.w, r12.y
    r5.w = ((vec4((r1).w)*vec4((r12).y))).w;
    // DXBC exp r5.w, r5.w
    r5.w = (exp2(vec4((r5).w))).w;
    // DXBC mul r5.w, r5.w, cb1[30].z
    r5.w = ((vec4((r5).w)*vec4((source_constants[30]).z))).w;
    // DXBC dp2 r4.w, r5.wwww, r4.wwww
    r4.w = (vec4(dot(((r5).wwww).xy,((r4).wwww).xy))).w;
    // DXBC add r9.y, r4.w, r9.y
    r9.y = ((vec4((r4).w)+vec4((r9).y))).y;
    // DXBC mad r9.z, cb1[29].x, l(0x3e000000), r9.z
    r9.z = ((vec4((source_constants[29]).x)*vec4(0.125,0.125,0.125,0.125)+vec4((r9).z))).z;
    // DXBC iadd r3.w, r3.w, l(0x00000001)
    r3.w = ((vec4((r3).w)+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC endloop
    }
    // DXBC add_sat r1.w, r9.x, cb1[31].w
    r1.w = (clamp((vec4((r9).x)+vec4((source_constants[31]).w)),vec4(0.0),vec4(1.0))).w;
    // DXBC mad r1.w, r9.y, r1.w, r9.x
    r1.w = ((vec4((r9).y)*vec4((r1).w)+vec4((r9).x))).w;
    // DXBC mov_sat r3.w, r1.w
    r3.w = (clamp(vec4((r1).w),vec4(0.0),vec4(1.0))).w;
    // DXBC mad r3.w, r4.z, r3.w, -r4.z
    r3.w = ((vec4((r4).z)*vec4((r3).w)+(-vec4((r4).z)))).w;
    // DXBC mad r3.w, cb1[32].x, r3.w, r4.z
    r3.w = ((vec4((source_constants[32]).x)*vec4((r3).w)+vec4((r4).z))).w;
    // DXBC lt r4.z, l(0x3727c5ac), |cb1[32].z|
    r4.z = (vec4(lessThan(vec4(9.999999747378752e-06,9.999999747378752e-06,9.999999747378752e-06,9.999999747378752e-06),abs(vec4((source_constants[32]).z))))).z;
    // DXBC ge r4.w, cb1[32].z, l(0x00000000)
    r4.w = (vec4(greaterThanEqual(vec4((source_constants[32]).z),vec4(0.0,0.0,0.0,0.0)))).w;
    // DXBC movc r2.w, r4.w, r2.w, r8.y
    r2.w = (mix(vec4((r8).y),vec4((r2).w),notEqual(vec4((r4).w),vec4(0.0)))).w;
    // DXBC movc r2.w, r4.z, r2.w, r8.y
    r2.w = (mix(vec4((r8).y),vec4((r2).w),notEqual(vec4((r4).z),vec4(0.0)))).w;
    // DXBC ge r4.z, l(0x00000000), r2.w
    r4.z = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),vec4((r2).w)))).z;
    // DXBC log r2.w, r2.w
    r2.w = (log2(vec4((r2).w))).w;
    // DXBC mul r2.w, r2.w, cb1[32].w
    r2.w = ((vec4((r2).w)*vec4((source_constants[32]).w))).w;
    // DXBC exp r2.w, r2.w
    r2.w = (exp2(vec4((r2).w))).w;
    // DXBC add r2.w, -r2.w, l(0x3f800000)
    r2.w = (((-vec4((r2).w))+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC movc r2.w, r4.z, l(0x3f800000), r2.w
    r2.w = (mix(vec4((r2).w),vec4(1.0,1.0,1.0,1.0),notEqual(vec4((r4).z),vec4(0.0)))).w;
    // DXBC ge r4.z, l(0x00000000), r2.w
    r4.z = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),vec4((r2).w)))).z;
    // DXBC log r2.w, r2.w
    r2.w = (log2(vec4((r2).w))).w;
    // DXBC mul r2.w, r2.w, cb1[33].x
    r2.w = ((vec4((r2).w)*vec4((source_constants[33]).x))).w;
    // DXBC exp r2.w, r2.w
    r2.w = (exp2(vec4((r2).w))).w;
    // DXBC movc r2.w, r4.z, l(0x80000000), -r2.w
    r2.w = (mix((-vec4((r2).w)),vec4(-0.0,-0.0,-0.0,-0.0),notEqual(vec4((r4).z),vec4(0.0)))).w;
    // DXBC add r2.w, r2.w, cb1[33].y
    r2.w = ((vec4((r2).w)+vec4((source_constants[33]).y))).w;
    // DXBC add r2.w, r2.w, l(0x3f800000)
    r2.w = ((vec4((r2).w)+vec4(1.0,1.0,1.0,1.0))).w;
    // DXBC dp3 r4.z, r11.xyzx, r11.xyzx
    r4.z = (vec4(dot(((r11).xyzx).xyz,((r11).xyzx).xyz))).z;
    // DXBC sqrt r4.z, r4.z
    r4.z = (sqrt(vec4((r4).z))).z;
    // DXBC div r8.xyz, r11.xyzx, r4.zzzz
    r8.xyz = (((r11).xyzx/(r4).zzzz)).xyz;
    // DXBC imad r4.z, v5.x, l(0x00000024), l(0x00000001)
    r4.z = ((vec4((v5).x)*vec4(36.0,36.0,36.0,36.0)+vec4(1.0,1.0,1.0,1.0))).z;
    // DXBC ld_structured_indexable(structured_buffer, stride=16)(mixed,mixed,mixed,mixed) r9.xyz, r4.z, l(0x00000000), t0.xyzx
    r9.xyz = (source_primitive[int((vec4((r4).z)).x)].xyzx).xyz;
    // DXBC imad r4.z, v5.x, l(0x00000024), l(0x00000002)
    r4.z = ((vec4((v5).x)*vec4(36.0,36.0,36.0,36.0)+vec4(2.0,2.0,2.0,2.0))).z;
    // DXBC ld_structured_indexable(structured_buffer, stride=16)(mixed,mixed,mixed,mixed) r10.xyz, r4.z, l(0x00000000), t0.xyzx
    r10.xyz = (source_primitive[int((vec4((r4).z)).x)].xyzx).xyz;
    // DXBC mov r11.x, r5.x
    r11.x = (vec4((r5).x)).x;
    // DXBC mov r11.y, r9.x
    r11.y = (vec4((r9).x)).y;
    // DXBC mov r11.z, r10.x
    r11.z = (vec4((r10).x)).z;
    // DXBC dp3 r11.x, r8.xyzx, r11.xyzx
    r11.x = (vec4(dot(((r8).xyzx).xyz,((r11).xyzx).xyz))).x;
    // DXBC mov r12.x, r5.y
    r12.x = (vec4((r5).y)).x;
    // DXBC mov r12.y, r9.y
    r12.y = (vec4((r9).y)).y;
    // DXBC mov r12.z, r10.y
    r12.z = (vec4((r10).y)).z;
    // DXBC dp3 r11.y, r8.xyzx, r12.xyzx
    r11.y = (vec4(dot(((r8).xyzx).xyz,((r12).xyzx).xyz))).y;
    // DXBC mov r10.x, r5.z
    r10.x = (vec4((r5).z)).x;
    // DXBC mov r10.y, r9.z
    r10.y = (vec4((r9).z)).y;
    // DXBC dp3 r11.z, r8.xyzx, r10.xyzx
    r11.z = (vec4(dot(((r8).xyzx).xyz,((r10).xyzx).xyz))).z;
    // DXBC dp3 r4.z, r11.xyzx, r11.xyzx
    r4.z = (vec4(dot(((r11).xyzx).xyz,((r11).xyzx).xyz))).z;
    // DXBC sqrt r4.z, r4.z
    r4.z = (sqrt(vec4((r4).z))).z;
    // DXBC div r5.xyz, r11.xyzx, r4.zzzz
    r5.xyz = (((r11).xyzx/(r4).zzzz)).xyz;
    // DXBC add r5.xyz, r5.xyzx, -v1.xyzx
    r5.xyz = (((r5).xyzx+(-(v1).xyzx))).xyz;
    // DXBC mad r5.xyz, cb1[33].zzzz, r5.xyzx, v1.xyzx
    r5.xyz = (((source_constants[33]).zzzz*(r5).xyzx+(v1).xyzx)).xyz;
    // DXBC dp3 r2.x, r5.xyzx, r2.xyzx
    r2.x = (vec4(dot(((r5).xyzx).xyz,((r2).xyzx).xyz))).x;
    // DXBC max r2.x, r2.x, l(0x00000000)
    r2.x = (max(vec4((r2).x),vec4(0.0,0.0,0.0,0.0))).x;
    // DXBC add r2.x, -r2.x, l(0x3f800000)
    r2.x = (((-vec4((r2).x))+vec4(1.0,1.0,1.0,1.0))).x;
    // DXBC max r2.x, |r2.x|, l(0x38d1b717)
    r2.x = (max(abs(vec4((r2).x)),vec4(9.999999747378752e-05,9.999999747378752e-05,9.999999747378752e-05,9.999999747378752e-05))).x;
    // DXBC add r2.y, -r2.x, l(0x3f800000)
    r2.y = (((-vec4((r2).x))+vec4(1.0,1.0,1.0,1.0))).y;
    // DXBC mad_sat r2.y, r2.y, cb1[33].w, r2.w
    r2.y = (clamp((vec4((r2).y)*vec4((source_constants[33]).w)+vec4((r2).w)),vec4(0.0),vec4(1.0))).y;
    // DXBC mad_sat r1.w, r1.w, r2.y, r3.w
    r1.w = (clamp((vec4((r1).w)*vec4((r2).y)+vec4((r3).w)),vec4(0.0),vec4(1.0))).w;
    // DXBC ge r2.y, l(0x00000000), r1.w
    r2.y = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),vec4((r1).w)))).y;
    // DXBC log r1.w, r1.w
    r1.w = (log2(vec4((r1).w))).w;
    // DXBC mul r2.z, r1.w, cb1[34].x
    r2.z = ((vec4((r1).w)*vec4((source_constants[34]).x))).z;
    // DXBC exp r2.z, r2.z
    r2.z = (exp2(vec4((r2).z))).z;
    // DXBC add r2.z, -r2.z, l(0x3f800000)
    r2.z = (((-vec4((r2).z))+vec4(1.0,1.0,1.0,1.0))).z;
    // DXBC movc r2.z, r2.y, l(0x3f800000), r2.z
    r2.z = (mix(vec4((r2).z),vec4(1.0,1.0,1.0,1.0),notEqual(vec4((r2).y),vec4(0.0)))).z;
    // DXBC ge r2.w, l(0x00000000), r2.z
    r2.w = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),vec4((r2).z)))).w;
    // DXBC log r2.z, r2.z
    r2.z = (log2(vec4((r2).z))).z;
    // DXBC mul r2.z, r2.z, cb1[34].y
    r2.z = ((vec4((r2).z)*vec4((source_constants[34]).y))).z;
    // DXBC exp r2.z, r2.z
    r2.z = (exp2(vec4((r2).z))).z;
    // DXBC add r2.z, -r2.z, l(0x3f800000)
    r2.z = (((-vec4((r2).z))+vec4(1.0,1.0,1.0,1.0))).z;
    // DXBC movc r2.z, r2.w, l(0x3f800000), r2.z
    r2.z = (mix(vec4((r2).z),vec4(1.0,1.0,1.0,1.0),notEqual(vec4((r2).w),vec4(0.0)))).z;
    // DXBC log r2.x, r2.x
    r2.x = (log2(vec4((r2).x))).x;
    // DXBC mul r2.x, r2.x, cb1[34].z
    r2.x = ((vec4((r2).x)*vec4((source_constants[34]).z))).x;
    // DXBC exp r2.x, r2.x
    r2.x = (exp2(vec4((r2).x))).x;
    // DXBC add r2.x, -r2.x, l(0x3f800000)
    r2.x = (((-vec4((r2).x))+vec4(1.0,1.0,1.0,1.0))).x;
    // DXBC ge r2.w, l(0x00000000), r2.x
    r2.w = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),vec4((r2).x)))).w;
    // DXBC log r2.x, r2.x
    r2.x = (log2(vec4((r2).x))).x;
    // DXBC mul r2.x, r2.x, cb1[34].w
    r2.x = ((vec4((r2).x)*vec4((source_constants[34]).w))).x;
    // DXBC exp r2.x, r2.x
    r2.x = (exp2(vec4((r2).x))).x;
    // DXBC movc r2.x, r2.w, l(0x00000000), r2.x
    r2.x = (mix(vec4((r2).x),vec4(0.0,0.0,0.0,0.0),notEqual(vec4((r2).w),vec4(0.0)))).x;
    // DXBC add_sat r2.x, r2.x, cb1[35].x
    r2.x = (clamp((vec4((r2).x)+vec4((source_constants[35]).x)),vec4(0.0),vec4(1.0))).x;
    // DXBC mul r2.x, r2.x, r2.z
    r2.x = ((vec4((r2).x)*vec4((r2).z))).x;
    // DXBC max r5.x, r2.x, l(0x00000000)
    r5.x = (max(vec4((r2).x),vec4(0.0,0.0,0.0,0.0))).x;
    // DXBC mov r5.y, l(0x00000000)
    r5.y = (vec4(0.0,0.0,0.0,0.0)).y;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r2.xzw, r5.xyxx, t12.xwyz, s8, cb0[143].y
    r2.xzw = (texture(source_t12, ((r5).xyxx).xy, source_mip_bias).xwyz).xzw;
    // DXBC add r5.xyzw, r2.xxzz, l(0x3d6147ae, 0xbd25aee6, 0x3d6147ae, 0xbd25aee6)
    r5.xyzw = (((r2).xxzz+vec4(0.054999999701976776,-0.040449999272823334,0.054999999701976776,-0.040449999272823334))).xyzw;
    // DXBC mul r4.zw, r5.xxxz, l(0x00000000, 0x00000000, 0x3f72a769, 0x3f72a769)
    r4.zw = (((r5).xxxz*vec4(0.0,0.0,0.9478669762611389,0.9478669762611389))).zw;
    // DXBC ge r5.xz, l(0x00000000, 0x00000000, 0x00000000, 0x00000000), r5.xxzx
    r5.xz = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),(r5).xxzx))).xz;
    // DXBC log r4.zw, r4.zzzw
    r4.zw = (log2((r4).zzzw)).zw;
    // DXBC mul r4.zw, r4.zzzw, l(0x00000000, 0x00000000, 0x4019999a, 0x4019999a)
    r4.zw = (((r4).zzzw*vec4(0.0,0.0,2.4000000953674316,2.4000000953674316))).zw;
    // DXBC exp r4.zw, r4.zzzw
    r4.zw = (exp2((r4).zzzw)).zw;
    // DXBC movc r4.zw, r5.xxxz, l(0x00000000,0x00000000,0x00000000,0x00000000), r4.zzzw
    r4.zw = (mix((r4).zzzw,vec4(0.0,0.0,0.0,0.0),notEqual((r5).xxxz,vec4(0.0)))).zw;
    // DXBC mul r8.xyz, r2.xzwx, l(0x3d9e835e, 0x3d9e835e, 0x3d9e835e, 0x00000000)
    r8.xyz = (((r2).xzwx*vec4(0.07739900052547455,0.07739900052547455,0.07739900052547455,0.0))).xyz;
    // DXBC lt r5.xy, l(0x3727c5ac, 0x3727c5ac, 0x00000000, 0x00000000), |r5.ywyy|
    r5.xy = (vec4(lessThan(vec4(9.999999747378752e-06,9.999999747378752e-06,0.0,0.0),abs((r5).ywyy)))).xy;
    // DXBC ge r9.xyz, r2.xzwx, l(0x3d25aee6, 0x3d25aee6, 0x3d25aee6, 0x00000000)
    r9.xyz = (vec4(greaterThanEqual((r2).xzwx,vec4(0.040449999272823334,0.040449999272823334,0.040449999272823334,0.0)))).xyz;
    // DXBC movc r2.xz, r9.xxyx, r4.zzwz, r8.xxyx
    r2.xz = (mix((r8).xxyx,(r4).zzwz,notEqual((r9).xxyx,vec4(0.0)))).xz;
    // DXBC movc r5.xy, r5.xyxx, r2.xzxx, r8.xyxx
    r5.xy = (mix((r8).xyxx,(r2).xzxx,notEqual((r5).xyxx,vec4(0.0)))).xy;
    // DXBC add r2.xz, r2.wwww, l(0x3d6147ae, 0x00000000, 0xbd25aee6, 0x00000000)
    r2.xz = (((r2).wwww+vec4(0.054999999701976776,0.0,-0.040449999272823334,0.0))).xz;
    // DXBC mul r2.w, r2.x, l(0x3f72a769)
    r2.w = ((vec4((r2).x)*vec4(0.9478669762611389,0.9478669762611389,0.9478669762611389,0.9478669762611389))).w;
    // DXBC ge r2.x, l(0x00000000), r2.x
    r2.x = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),vec4((r2).x)))).x;
    // DXBC log r2.w, r2.w
    r2.w = (log2(vec4((r2).w))).w;
    // DXBC mul r2.w, r2.w, l(0x4019999a)
    r2.w = ((vec4((r2).w)*vec4(2.4000000953674316,2.4000000953674316,2.4000000953674316,2.4000000953674316))).w;
    // DXBC exp r2.w, r2.w
    r2.w = (exp2(vec4((r2).w))).w;
    // DXBC movc r2.x, r2.x, l(0x00000000), r2.w
    r2.x = (mix(vec4((r2).w),vec4(0.0,0.0,0.0,0.0),notEqual(vec4((r2).x),vec4(0.0)))).x;
    // DXBC lt r2.z, l(0x3727c5ac), |r2.z|
    r2.z = (vec4(lessThan(vec4(9.999999747378752e-06,9.999999747378752e-06,9.999999747378752e-06,9.999999747378752e-06),abs(vec4((r2).z))))).z;
    // DXBC movc r2.x, r9.z, r2.x, r8.z
    r2.x = (mix(vec4((r8).z),vec4((r2).x),notEqual(vec4((r9).z),vec4(0.0)))).x;
    // DXBC movc r5.z, r2.z, r2.x, r8.z
    r5.z = (mix(vec4((r8).z),vec4((r2).x),notEqual(vec4((r2).z),vec4(0.0)))).z;
    // DXBC mul r1.w, r1.w, cb1[35].y
    r1.w = ((vec4((r1).w)*vec4((source_constants[35]).y))).w;
    // DXBC exp r1.w, r1.w
    r1.w = (exp2(vec4((r1).w))).w;
    // DXBC movc r1.w, r2.y, l(0x00000000), r1.w
    r1.w = (mix(vec4((r1).w),vec4(0.0,0.0,0.0,0.0),notEqual(vec4((r2).y),vec4(0.0)))).w;
    // DXBC mul r2.xyz, r1.wwww, r5.xyzx
    r2.xyz = (((r1).wwww*(r5).xyzx)).xyz;
    // DXBC mul r2.xyz, r2.xyzx, cb1[18].xyzx
    r2.xyz = (((r2).xyzx*(source_constants[18]).xyzx)).xyz;
    // DXBC mul r2.xyz, r2.xyzx, cb1[35].zzzz
    r2.xyz = (((r2).xyzx*(source_constants[35]).zzzz)).xyz;
    // DXBC mad r2.xyz, r0.wwww, -r2.xyzx, r2.xyzx
    r2.xyz = (((r0).wwww*(-(r2).xyzx)+(r2).xyzx)).xyz;
    // DXBC add r5.xyz, -r2.xyzx, cb1[19].xyzx
    r5.xyz = (((-(r2).xyzx)+(source_constants[19]).xyzx)).xyz;
    // DXBC mad r2.xyz, cb1[35].wwww, r5.xyzx, r2.xyzx
    r2.xyz = (((source_constants[35]).wwww*(r5).xyzx+(r2).xyzx)).xyz;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r5.xyz, r7.zwzz, t13.xyzw, s9, cb0[143].y
    r5.xyz = (texture(source_t13, ((r7).zwzz).xy, source_mip_bias).xyzw).xyz;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r8.xyz, r7.xwxx, t13.xyzw, s9, cb0[143].y
    r8.xyz = (texture(source_t13, ((r7).xwxx).xy, source_mip_bias).xyzw).xyz;
    // DXBC mul r8.xyz, r6.yyyy, r8.xyzx
    r8.xyz = (((r6).yyyy*(r8).xyzx)).xyz;
    // DXBC mad r5.xyz, r6.xxxx, r5.xyzx, r8.xyzx
    r5.xyz = (((r6).xxxx*(r5).xyzx+(r8).xyzx)).xyz;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r8.xyz, r7.xzxx, t13.xyzw, s9, cb0[143].y
    r8.xyz = (texture(source_t13, ((r7).xzxx).xy, source_mip_bias).xyzw).xyz;
    // DXBC mad r5.xyz, r6.zzzz, r8.xyzx, r5.xyzx
    r5.xyz = (((r6).zzzz*(r8).xyzx+(r5).xyzx)).xyz;
    // DXBC mul r5.xyz, r0.wwww, r5.xyzx
    r5.xyz = (((r0).wwww*(r5).xyzx)).xyz;
    // DXBC ge r8.xyz, l(0x00000000, 0x00000000, 0x00000000, 0x00000000), r5.xyzx
    r8.xyz = (vec4(greaterThanEqual(vec4(0.0,0.0,0.0,0.0),(r5).xyzx))).xyz;
    // DXBC mul r5.xyz, r5.xyzx, r5.xyzx
    r5.xyz = (((r5).xyzx*(r5).xyzx)).xyz;
    // DXBC movc r5.xyz, r8.xyzx, l(0x00000000,0x00000000,0x00000000,0x00000000), r5.xyzx
    r5.xyz = (mix((r5).xyzx,vec4(0.0,0.0,0.0,0.0),notEqual((r8).xyzx,vec4(0.0)))).xyz;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r4.xy, r4.xyxx, t14.xwyz, s10, cb0[143].y
    r4.xy = (texture(source_t14, ((r4).xyxx).xy, source_mip_bias).xwyz).xy;
    // DXBC mul r4.zw, r4.xxxy, cb1[36].xxxy
    r4.zw = (((r4).xxxy*(source_constants[36]).xxxy)).zw;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r8.xy, r7.zwzz, t15.xwyz, s11, cb0[143].y
    r8.xy = (texture(source_t15, ((r7).zwzz).xy, source_mip_bias).xwyz).xy;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r7.yw, r7.xwxx, t15.yxzw, s11, cb0[143].y
    r7.yw = (texture(source_t15, ((r7).xwxx).xy, source_mip_bias).yxzw).yw;
    // DXBC mul r6.yw, r6.yyyy, r7.yyyw
    r6.yw = (((r6).yyyy*(r7).yyyw)).yw;
    // DXBC mad r6.xy, r6.xxxx, r8.xyxx, r6.ywyy
    r6.xy = (((r6).xxxx*(r8).xyxx+(r6).ywyy)).xy;
    // DXBC sample_b_indexable(texture2d)(float,float,float,float) r7.xy, r7.xzxx, t15.xwyz, s11, cb0[143].y
    r7.xy = (texture(source_t15, ((r7).xzxx).xy, source_mip_bias).xwyz).xy;
    // DXBC mad r6.xy, r6.zzzz, r7.xyxx, r6.xyxx
    r6.xy = (((r6).zzzz*(r7).xyxx+(r6).xyxx)).xy;
    // DXBC mad r4.xy, -cb1[36].xyxx, r4.xyxx, r6.xyxx
    r4.xy = (((-(source_constants[36]).xyxx)*(r4).xyxx+(r6).xyxx)).xy;
    // DXBC mad r4.xy, r0.wwww, r4.xyxx, r4.zwzz
    r4.xy = (((r0).wwww*(r4).xyxx+(r4).zwzz)).xy;
    // DXBC add_sat r0.w, -r4.y, l(0x3f800000)
    r0.w = (clamp(((-vec4((r4).y))+vec4(1.0,1.0,1.0,1.0)),vec4(0.0),vec4(1.0))).w;
    // DXBC min r5.xyz, r5.xyzx, l(0x3f800000, 0x3f800000, 0x3f800000, 0x00000000)
    r5.xyz = (min((r5).xyzx,vec4(1.0,1.0,1.0,0.0))).xyz;
    // DXBC mov_sat r4.x, r4.x
    r4.x = (clamp(vec4((r4).x),vec4(0.0),vec4(1.0))).x;
    // DXBC mad r4.z, r0.w, cb0[139].y, cb0[139].x
    r4.z = ((vec4((r0).w)*vec4((vec4(0.0,1.0,0.0,0.0)).y)+vec4((vec4(0.0,1.0,0.0,0.0)).x))).z;
    ALBEDO = r5.xyz;
    EMISSION = r2.xyz;
    METALLIC = r4.x;
    ROUGHNESS = r4.z;
    SPECULAR = 0.7071067811865476; // UE Specular=1 => F0=.08; Godot F0=.16*SPECULAR^2.
    NORMAL = normalize(mat3(VIEW_MATRIX)*(axis*r0.zxy));
}
