"""Build resolved source-sun inputs from the actual shadow/LF probe, CPU only."""
from pathlib import Path
import argparse, hashlib, json, math, re
import numpy as np


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def write_json(path, value): path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def unpack_atlas(data):
    if data.shape != (512,512,4): raise ValueError('Expected 512x512 RGBA input')
    # atlas [tileY, y, tileX, x, rgba] -> [tileY, tileX, y, x, rgba]
    return data.reshape(8,64,8,64,4).transpose(0,2,1,3,4).reshape(64,64,64,4).copy()


def srgb_to_linear(color):
    c=np.asarray(color,dtype=np.float64)/255.
    return np.where(c<=.04045,c/12.92,((c+.055)/1.055)**2.4)


def outer_edge():
    t=(np.arange(64,dtype=np.float32)+np.float32(.5))/np.float32(64)
    fade=t*(np.float32(1)+np.float32(4/64))-np.float32(2/64)
    factor=np.clip((np.float32(.5)-np.abs(fade-np.float32(.5)))*np.float32(10),0,1)
    return factor[:,None,None]*factor[None,:,None]*factor[None,None,:]


def build(source, out):
    out.mkdir(parents=True,exist_ok=True)
    meta_path=source/'scene-probe.json'
    meta=json.loads(meta_path.read_text(encoding='utf-8-sig'))
    if meta.get('failures') or meta.get('stage')!='complete': raise ValueError('Probe did not complete cleanly')
    edge=outer_edge()
    cases=[]
    for capture in meta['captures']:
        name=capture['label']
        if not re.fullmatch(r'(wuming|youxian)-cascade[01]-(shadow|unshadowed-control|live)',name): raise ValueError(name)
        path=source/(name+'.rgba16f')
        if path.stat().st_size!=512*512*4*2: raise ValueError('Incomplete capture: '+name)
        vox=unpack_atlas(np.fromfile(path,dtype='<f2').reshape(512,512,4)).astype(np.float32)
        if not np.isfinite(vox).all() or not np.all(vox[...,2]==1): raise ValueError('Missing sun/invalid capture: '+name)
        if np.any(vox[...,0]<0) or np.any(vox[...,0]>1) or np.any(vox[...,1]<0): raise ValueError('Invalid shadow/LF range')
        prop=capture['source_properties']
        color8=[int(x.strip()) for x in prop['LightColor']['LightColor'].split(',')]
        if len(color8)!=3 or not all(0<=c<=255 for c in color8): raise ValueError('Invalid source FColor')
        linear=srgb_to_linear(color8).astype(np.float32)
        rgb_scale=np.float32(float(prop['Intensity'])/math.pi)*linear
        shadow_lf=vox[...,0]*vox[...,1]
        # Source applies LF BEFORE the outer shadow blend. LF can exceed one.
        factor=(np.float32(1)+(shadow_lf-np.float32(1))*edge) if capture['cascade']==1 else shadow_lf
        resolved=np.empty((64,64,64,4),dtype='<f4')
        resolved[...,:3]=factor[...,None]*rgb_scale
        resolved[...,3]=factor
        direction=np.zeros_like(resolved)
        direction[...,:3]=np.asarray(capture['sun_direction_ue'],dtype=np.float32)
        if np.linalg.norm(direction[0,0,0,:3])<.999 or not np.isfinite(resolved).all(): raise ValueError('Bad resolved input')
        dest=out/'inputs'/name
        dest.mkdir(parents=True,exist_ok=True)
        rp=dest/'resolved.rgba32f'; dp=dest/'direction.rgba32f'
        resolved.tofile(rp); direction.tofile(dp)
        cases.append({'name':name,'lights':[{'resolved':rp.relative_to(out).as_posix(),'direction':dp.relative_to(out).as_posix()}],
            'source_capture':str(path),'source_capture_sha256':sha(path),
            'resolved_sha256':sha(rp),'direction_sha256':sha(dp),'cascade':capture['cascade'],
            'min_ue_cm':capture['min_ue_cm'],'voxel_cm':capture['bounds']['voxel_cm'],
            'source_intensity':prop['Intensity'],'source_fcolor_srgb8':color8,'source_color_linear':linear.tolist(),
            'sun_direction_ue':capture['sun_direction_ue'],'source_lightfunction':prop.get('LightFunctionMaterial'),
            'factor_range':[float(factor.min()),float(factor.max())],
            'sun_present_all_voxels':True,'shadow_disabled_control':not capture['shadow']})
    manifest={'version':1,'dimension':64,'layout':'z,y,x,RGBA; x fastest; UE axes; little-endian float32',
        'source_manifest':str(meta_path),'source_manifest_sha256':sha(meta_path),'cases':cases,
        'scope':'Actual Godot sun-shadow probe and recovered LF; not native UE shadow parity, no local lights or source CSM clip planes.',
        'resolved_contract':'RGB=Intensity/pi*sRGBToLinear(FColor)*(inner:shadow*LF; outer:mix(1,shadow*LF,edge)); A=same factor. No clamping LF/alpha to one.',
        'assumptions':['Directional attenuation=1. Source atmosphere transmission=1 for selected source maps.',
            'Source CSM split clipping/masking not captured; probe already supplies one resolved Godot sun shadow. No claim of native split-injection equivalence.',
            'Temperature is not applied: source bUseTemperature is not enabled in captured properties.',
            'Capture half precision and Godot shadow precision are retained as producer limits, not hidden by oracle tolerance.']}
    write_json(out/'manifest.json',manifest)
    write_json(out/'build-validation.json',{'passed':True,'cases':len(cases),'bytes_per_input':64**3*4*4,
        'source_captures_reused_without_modification':True,'source_outer_edge_range':[float(edge.min()),float(edge.max())],
        'source_blue_linear':float(srgb_to_linear([255,255,250])[2]),'gpu_executed':False})
    return manifest


if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--source',type=Path,required=True); p.add_argument('--out',type=Path,required=True)
    a=p.parse_args(); manifest=build(a.source,a.out); print(json.dumps({'manifest':str(a.out/'manifest.json'),'cases':len(manifest['cases'])}))
