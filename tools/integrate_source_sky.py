"""CPU-only UE-convention three-band SH from the verified raw HDR capture.

No GPU process or geometry generation. Raw files are viewport-order RGBA16F;
they are flipped vertically once, then the source black lower hemisphere is set.
The 32px source-mip approximation uses per-face box filtering. Projection uses
the source texel-center Jacobian and 4*pi normalization, not equal pixel weights.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import numpy as np

FACES = ("px", "nx", "py", "ny", "pz", "nz")
BANDS = np.array([math.pi] + [2 * math.pi / 3] * 3 + [math.pi / 4] * 5)


def basis(ue):
    x, y, z = np.moveaxis(ue, -1, 0)
    return np.stack([np.full_like(x, .282095), -.488603*y, .488603*z,
                     -.488603*x, 1.092548*x*y, -1.092548*y*z,
                     .315392*(3*z*z-1), -1.092548*x*z,
                     .546274*(x*x-y*y)], axis=-1)


def directions(size):
    uv = (np.arange(size, dtype=np.float64)+.5)/size*2-1
    u, v = np.meshgrid(uv, uv)
    one = np.ones_like(u)
    # Standard Godot Cubemap faces after the capture driver's vertical flip.
    gd = np.stack([np.stack(x, axis=-1) for x in
                   [(one,-v,-u),(-one,-v,u),(u,one,v),
                    (u,-one,-v),(u,-v,one),(-u,-v,-one)]])
    gd /= np.linalg.norm(gd, axis=-1, keepdims=True)
    weight = 4.0 / np.power(1+u*u+v*v, 1.5)
    weight = np.broadcast_to(weight, (6,size,size))
    weight = weight * (4*math.pi/weight.sum())
    return gd, weight


def project(rgb):
    gd, weight = directions(rgb.shape[1])
    ue = gd[..., [0,2,1]]
    radiance = np.einsum('fhwc,fhwk,fhw->kc', rgb, basis(ue), weight)
    return radiance


def evaluate(coeff, normals_godot):
    ns = np.asarray(normals_godot, dtype=np.float64)
    ns /= np.linalg.norm(ns, axis=-1, keepdims=True)
    return basis(ns[..., [0,2,1]]) @ coeff


def downsample(rgb, target):
    n = rgb.shape[1]
    if n % target:
        raise ValueError('Capture size must be divisible by projection size')
    f = n // target
    return rgb.reshape(6,target,f,target,f,3).mean(axis=(2,4))


def validate_cpu(size=32):
    gd, _ = directions(size)
    full = np.ones((6,size,size,3),dtype=np.float64)
    normals = [[0,1,0],[1,0,0],[0,-1,0],[0,0,1]]
    full_eval = evaluate(project(full)*BANDS[:,None]/math.pi, normals)
    hemisphere = full.copy()
    hemisphere[gd[...,1]<0] = 0
    hemi_eval = evaluate(project(hemisphere)*BANDS[:,None]/math.pi,normals)
    # SH3 hemispheric cosine fit has slight truncation/ringing. Test expected
    # up=1, horizon=.5, down=0 with a tolerance for center quadrature.
    expected = np.array([[1],[.5],[0],[.5]])
    constant_error = float(np.max(np.abs(full_eval-1)))
    hemi_error = float(np.max(np.abs(hemi_eval-expected)))
    # Three independent directional ramps catch sign/axis mistakes that the
    # symmetric constant/hemisphere probes cannot expose. Analytically, the
    # Lambert E/pi of L(d)=1+0.6*d.xyz is 1+0.4*n.xyz.
    ramp = 1 + .6*gd
    ramp_normals = np.array([[1,2,3],[-2,1,-3],[3,-2,1]],dtype=np.float64)
    ramp_normals /= np.linalg.norm(ramp_normals,axis=-1,keepdims=True)
    ramp_eval = evaluate(project(ramp)*BANDS[:,None]/math.pi,ramp_normals)
    ramp_expected = 1 + .4*ramp_normals
    ramp_error = float(np.max(np.abs(ramp_eval-ramp_expected)))
    result = {'constant_sphere_max_abs_error':constant_error,
              'black_lower_hemisphere_max_abs_error':hemi_error,
              'hemisphere_samples_order':['up','right','down','back'],
              'hemisphere_e_over_pi_unclamped':hemi_eval.tolist(),
              'solid_angle_sum':float(directions(size)[1].sum()),
              'directional_rgb_ramp_max_abs_error':ramp_error,
              'directional_rgb_ramp_pass':ramp_error<1e-4,
              'constant_pass':constant_error<1e-4,'hemisphere_pass':hemi_error<.002}
    if not all(result[x] for x in ['constant_pass','hemisphere_pass','directional_rgb_ramp_pass']):
        raise AssertionError(result)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--projection-size',type=int,default=32)
    args=ap.parse_args()
    manifest=json.loads((args.input/'capture-manifest.json').read_text(encoding='utf8'))
    if manifest.get('status')!='captured':
        raise ValueError('Input capture must have completed successfully')
    if not manifest.get('restored_scene_state', False) or manifest.get('roughness_unhandled'):
        raise ValueError('Capture must restore scene state and handle every material')
    if not manifest.get('time_scale_restored', False):
        raise ValueError('Capture must restore the shader and scene clock')
    if (manifest.get('sh9_feedback_disable_errors') or
            manifest.get('restored_sh9_feedback_overrides', -1) != manifest.get('sh9_feedback_overrides', 0) or
            manifest.get('restored_sh9_emission_feedback_overrides', -1) != manifest.get('sh9_emission_feedback_overrides', 0)):
        raise ValueError('Capture must suppress and restore all SH feedback producers')
    size=int(manifest['resolution'])
    frames=[]; hashes={}
    for name in FACES:
        raw=(args.input/f'face_{name}_raw.rgba16f').read_bytes()
        if len(raw)!=size*size*8: raise ValueError((name,len(raw)))
        hashes[name]=hashlib.sha256(raw).hexdigest()
        data=np.frombuffer(raw,dtype='<f2').reshape(size,size,4).astype(np.float64)
        if not np.isfinite(data).all(): raise ValueError(f'Nonfinite raw face {name}')
        frames.append(np.flip(data[:,:,:3],axis=0).copy())
    rgb=np.stack(frames)
    gd,_=directions(size)
    rgb[gd[...,1]<0]=0
    low=downsample(rgb,args.projection_size)
    l32=project(low); l_full=project(rgb)
    e=l32*BANDS[:,None]; epi=e/math.pi
    epi_full=l_full*BANDS[:,None]/math.pi
    fcolor=np.array([255,219,195],dtype=np.float64)/255
    linear=np.where(fcolor<=.04045,fcolor/12.92,((fcolor+.055)/1.055)**2.4)
    gain=linear*1.100000023841858
    normals={'up':[0,1,0],'down':[0,-1,0],'right':[1,0,0],
             'left':[-1,0,0],'back':[0,0,1],'forward':[0,0,-1]}
    # Uniform sphere sampling provides an evaluation-space mip error metric.
    i=np.arange(4096); z=1-2*(i+.5)/4096; phi=i*math.pi*(3-math.sqrt(5))
    ns=np.stack([np.sqrt(1-z*z)*np.cos(phi),z,np.sqrt(1-z*z)*np.sin(phi)],axis=-1)
    difference=evaluate(epi,ns)-evaluate(epi_full,ns)
    report={'schema':'source_sh9_v1','input':str(args.input.resolve()),
        'capture_manifest_sha256':hashlib.sha256((args.input/'capture-manifest.json').read_bytes()).hexdigest(),
        'raw_sha256':hashes,'capture_resolution':size,'projection_resolution':args.projection_size,
        'capture_time_policy':manifest.get('time_policy', 'Legacy capture: shader TIME was not frozen.'),
        'capture_sky_feedback_overrides':manifest.get('sky_feedback_overrides', 0),
        'capture_sh9_feedback_overrides':manifest.get('sh9_feedback_overrides', 0),
        'capture_sh9_emission_feedback_overrides':manifest.get('sh9_emission_feedback_overrides', 0),
        'source_mip_method':'per-face linear box mean; source cross-face GPU mip generation and FP16 reduction not bit-exact',
        'coordinate_system':'basis takes UE xyz = Godot xzy; capture faces are Godot +X,-X,+Y,-Y,+Z,-Z',
        'basis_order':['0.282095','-0.488603*y','0.488603*z','-0.488603*x',
                       '1.092548*x*y','-1.092548*y*z','0.315392*(3*z*z-1)',
                       '-1.092548*x*z','0.546274*(x*x-y*y)'],
        'radiance_coefficients':l32.tolist(),'lambert_irradiance_coefficients':e.tolist(),
        'e_over_pi_coefficients':epi.tolist(),'source_skylight_linear_gain':gain.tolist(),
        'gain_applied_to_coefficients':False,
        'output_domain':'E/pi, before sky FColor decode*intensity gain and surface albedo',
        'directional_e_over_pi_unclamped':{n:evaluate(epi,[v])[0].tolist() for n,v in normals.items()},
        'directional_e_over_pi_tinted_clamped':{n:(np.maximum(evaluate(epi,[v])[0],0)*gain).tolist() for n,v in normals.items()},
        'full_resolution_e_over_pi_coefficients':epi_full.tolist(),
        '32_vs_full_evaluation_error':{'max_abs_rgb':np.max(np.abs(difference),axis=0).tolist(),
                                      'rms_rgb':np.sqrt(np.mean(difference**2,axis=0)).tolist()},
        'cpu_validation':validate_cpu(args.projection_size),
        'limits':['Input is a cross-engine scene capture, not the original UE capture buffer.',
                  manifest.get('time_policy', 'Six legacy capture faces use successive frames; shader TIME is not frozen.'),
                  'Source public shader mirror predates exact shipping 4.27; native postfactor verification is tracked separately.',
                  'No spatial sky occlusion, bent normal, contact AO or precomputed GI is introduced.']}
    args.output.mkdir(parents=True,exist_ok=True)
    out=args.output/'source-sh9.json'
    out.write_text(json.dumps(report,indent=2),encoding='utf8')
    print(json.dumps({'output':str(out),'validation':report['cpu_validation'],
                      'mip_error':report['32_vs_full_evaluation_error'],
                      'samples':report['directional_e_over_pi_tinted_clamped']},indent=2))


if __name__=='__main__': main()
