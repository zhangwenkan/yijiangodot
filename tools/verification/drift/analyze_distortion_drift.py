"""Read-only analysis of same-callback native distortion diagnostic captures.

Exact repetition and zero-accumulation no-write checks are never relaxed.
The CPU bilinear reconstruction is descriptive, not a hardware sampler oracle.
"""
from pathlib import Path
import argparse,hashlib,json
import numpy as np


def read_json(path):return json.loads(path.read_text(encoding='utf-8-sig'))
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def bits(a):
    if a.dtype.itemsize==2:return a.view(np.uint16)
    if a.dtype.itemsize==4:return a.view(np.uint32)
    return a
def changed(a,b):
    m=bits(a)!=bits(b)
    return np.any(m,axis=-1) if m.ndim==3 else m
def stats(a,b,mask=None):
    if a.shape!=b.shape:raise ValueError('Shape mismatch')
    m=changed(a,b)
    if mask is None:mask=np.ones(m.shape,bool)
    d=b.astype(np.float64)-a.astype(np.float64)
    selected=d[mask];pixel=m&mask;yy,xx=np.nonzero(pixel)
    return {'byte_exact':bool(not np.any(pixel)),'changed_pixels':int(pixel.sum()),
        'numeric_changed_components':int(np.count_nonzero(selected)),
        'bit_changed_components':int(np.count_nonzero((bits(a)!=bits(b))[mask])),
        'max_abs':float(np.max(np.abs(selected))) if selected.size else 0.,
        'mean_abs':float(np.mean(np.abs(selected))) if selected.size else 0.,
        'bbox_xyxy':[int(xx.min()),int(yy.min()),int(xx.max()+1),int(yy.max()+1)] if len(xx) else None}


def path_for(folder,meta,key):
    item=meta.get(key)
    if isinstance(item,dict) and 'file' in item:return folder/item['file']
    if isinstance(item,str) and (folder/item).is_file():return folder/item
    path=folder/(key+'.bin')
    return path if path.is_file() else None


def load(folder):
    meta_path=next((folder/name for name in ('capture.json','stage.json','distortion.json') if (folder/name).is_file()),None)
    if meta_path is None:raise ValueError('Missing capture metadata: '+str(folder))
    meta=read_json(meta_path);w=int(meta['width']);h=int(meta['height']);fields={};paths={}
    specs={'before_rgba16f':('<f2',4),'accumulation_rgba8':('u1',4),'after_rgba16f':('<f2',4),'depth_r32f':('<f4',1)}
    for key,(dtype,n) in specs.items():
        path=path_for(folder,meta,key)
        if path is None:
            if key=='depth_r32f':continue
            raise ValueError('Missing '+key+' in '+str(folder))
        a=np.fromfile(path,dtype=dtype)
        if a.size!=w*h*n:raise ValueError('Unexpected byte count '+str(path))
        a=a.reshape((h,w,n) if n>1 else (h,w))
        if not np.isfinite(a).all():raise ValueError('Nonfinite '+str(path))
        fields[key]=a;paths[key]={'file':str(path),'bytes':path.stat().st_size,'sha256':sha(path)}
    blobs={}
    for key in ('frame_rgba32f','water_frame_rgba32f','instances_rgba32f','scene_time_ubo'):
        path=path_for(folder,meta,key)
        if path is not None:
            blobs[key]=path.read_bytes();paths[key]={'file':str(path),'bytes':len(blobs[key]),'sha256':sha(path)}
    return {'folder':folder,'name':folder.name,'meta':meta,'meta_path':meta_path,'fields':fields,'blobs':blobs,'files':paths}


def coordinates(a):
    h,w,_=a.shape;yy,xx=np.indices((h,w),dtype=np.float32)
    size=np.array([w,h],np.float32)
    uv=(np.stack([xx,yy],axis=-1)+np.float32(.5))/size
    unorm=a.astype(np.float32)/np.float32(255)
    offset=(unorm[:,:,:2]-unorm[:,:,2:])*np.float32(.25)
    sample_uv=uv+offset;lo=np.float32(.5)/size;hi=np.float32(1)-lo
    oob=np.any((sample_uv<lo)|(sample_uv>hi),axis=-1)
    sample_uv=np.where(oob[:,:,None],uv,sample_uv)
    q=sample_uv*size-np.float32(.5);q0=np.floor(q).astype(np.int32);weight=(q-q0.astype(np.float32)).astype(np.float32)
    x0=np.clip(q0[:,:,0],0,w-1);y0=np.clip(q0[:,:,1],0,h-1)
    x1=np.clip(q0[:,:,0]+1,0,w-1);y1=np.clip(q0[:,:,1]+1,0,h-1)
    nonzero=np.any(a!=0,axis=-1);netzero=np.all(a[:,:,:2]==a[:,:,2:],axis=-1)
    return {'x0':x0,'x1':x1,'y0':y0,'y1':y1,'weight':weight,'uv':sample_uv,
        'masks':{'untouched_zero':~nonzero,'encoded_nonzero':nonzero,'nonzero_net_zero':nonzero&netzero,
            'nonzero_offset':nonzero&~netzero,'out_of_bounds_fallback':nonzero&oob,
            'displaced_in_bounds':nonzero&~netzero&~oob}}


def bilinear(before,coord):
    a=before.astype(np.float32);wx=coord['weight'][:,:,0:1];wy=coord['weight'][:,:,1:2]
    top=a[coord['y0'],coord['x0']]*(1-wx)+a[coord['y0'],coord['x1']]*wx
    bottom=a[coord['y1'],coord['x0']]*(1-wx)+a[coord['y1'],coord['x1']]*wx
    sampled=(top*(1-wy)+bottom*wy).astype(np.float16)
    return np.where(coord['masks']['encoded_nonzero'][:,:,None],sampled,before)


def samples_changed(mask,coord):
    return mask[coord['y0'],coord['x0']]|mask[coord['y0'],coord['x1']]|mask[coord['y1'],coord['x0']]|mask[coord['y1'],coord['x1']]


def save_diff(a,b,path):
    mask=changed(a,b)
    if not mask.any():return None
    np.savez_compressed(path,yx=np.argwhere(mask),first=a[mask],second=b[mask],delta=b[mask].astype(np.float32)-a[mask].astype(np.float32))
    return str(path)


def main(folders,out,focus_path):
    out.mkdir(parents=True,exist_ok=True);captures=[load(folder) for folder in folders]
    result={'captures':[],'pairs':[],'scope':'Saved same-callback distortion inputs/output. Exact equality is required for repeated snapshots; CPU sampler reconstruction is descriptive only.',
        'cpu_sampler_limit':'Float32 GLSL-style UV math plus ideal bilinear reconstruction; hardware subtexel precision, FMA and final float16 rounding can differ. Not a new numeric acceptance gate.'}
    focus=[]
    if focus_path:
        loc=read_json(focus_path)
        focus=[s['xy'] for group in loc['groups'] for s in group['samples']]
    for cap in captures:
        fields=cap['fields'];a=fields['before_rgba16f'];b=fields['after_rgba16f'];acc=fields['accumulation_rgba8'];coord=coordinates(acc);cap['coord']=coord
        row={'name':cap['name'],'metadata_file':str(cap['meta_path']),'files':cap['files'],'audit_mode':cap['meta'].get('audit_mode'),
            'frame_identity':{k:v for k,v in cap['meta'].items() if ('frame' in k and not isinstance(v,dict)) or k=='same_callback_triplet'},
            'regions':{},'focus_pixels':[]}
        for key,mask in coord['masks'].items():
            row['regions'][key]={'pixels':int(mask.sum()),'before_after':stats(a,b,mask)}
        row['untouched_zero_passed']=row['regions']['untouched_zero']['before_after']['byte_exact'] if cap['meta'].get('audit_mode',0)==0 else None
        row['ideal_bilinear_vs_actual_descriptive']=stats(bilinear(a,coord),b)
        row['before_after_exact_samples']=save_diff(a,b,out/(cap['name']+'-before-after.npz'))
        for x,y in focus:
            if not (0<=y<a.shape[0] and 0<=x<a.shape[1]):continue
            row['focus_pixels'].append({'xy':[x,y],'before':a[y,x].tolist(),'accumulation':acc[y,x].tolist(),'after':b[y,x].tolist(),
                'regions':[key for key,mask in coord['masks'].items() if mask[y,x]],'sample_uv':coord['uv'][y,x].tolist(),
                'source_sample_xy':[[int(coord['x0'][y,x]),int(coord['y0'][y,x])],[int(coord['x1'][y,x]),int(coord['y0'][y,x])],
                    [int(coord['x0'][y,x]),int(coord['y1'][y,x])],[int(coord['x1'][y,x]),int(coord['y1'][y,x])]]})
        if 'scene_time_ubo' in cap['blobs']:
            clock=cap['blobs']['scene_time_ubo'];row['captured_scene_slice_f32_unverified']=np.frombuffer(clock,dtype='<f4').tolist();row['captured_scene_slice_hex']=clock.hex();row['clock_evidence_limit']='Legacy captures used byte2832 (exposure), not TIME. Slice equality alone cannot verify scene time; use correctly tagged full 5696-byte UBO data.'
        result['captures'].append(row)
    for index,first in enumerate(captures):
        for second in captures[index+1:]:
            row={'first':first['name'],'second':second['name'],'fields':{},'blobs':{}}
            for key,a in first['fields'].items():
                if key not in second['fields']:continue
                b=second['fields'][key];row['fields'][key]=stats(a,b)
                row['fields'][key]['exact_samples']=save_diff(a,b,out/(first['name']+'__'+second['name']+'__'+key+'.npz'))
            for key,a in first['blobs'].items():
                if key in second['blobs']:
                    b=second['blobs'][key];row['blobs'][key]={'byte_exact':a==b,'first_bytes':len(a),'second_bytes':len(b)}
            order=['before_rgba16f','accumulation_rgba8','after_rgba16f']
            row['earliest_recorded_change']=next((key for key in order if not row['fields'][key]['byte_exact']),None)
            before_diff=changed(first['fields']['before_rgba16f'],second['fields']['before_rgba16f'])
            accum_diff=changed(first['fields']['accumulation_rgba8'],second['fields']['accumulation_rgba8'])
            after_diff=changed(first['fields']['after_rgba16f'],second['fields']['after_rgba16f'])
            support=samples_changed(before_diff,first['coord'])|samples_changed(before_diff,second['coord'])
            row['output_change_accounting']={'after_changed_pixels':int(after_diff.sum()),
                'after_changes_with_accum_change':int((after_diff&accum_diff).sum()),
                'after_changes_with_before_sample_neighborhood_change':int((after_diff&support).sum()),
                'after_changes_without_recorded_input_or_sample_neighborhood_change':int((after_diff&~accum_diff&~support).sum())}
            result['pairs'].append(row)
    result['zero_region_passed']=all(c['untouched_zero_passed'] is not False for c in result['captures'])
    result['all_repeats_byte_exact']=all(all(s['byte_exact'] for s in p['fields'].values()) and all(s['byte_exact'] for s in p['blobs'].values()) for p in result['pairs'])
    (out/'distortion-drift.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({'captures':len(captures),'zero_region_passed':result['zero_region_passed'],'all_repeats_byte_exact':result['all_repeats_byte_exact'],
        'pairs':[{'first':p['first'],'second':p['second'],'earliest':p['earliest_recorded_change'],'counts':{k:v['changed_pixels'] for k,v in p['fields'].items()},
            'accounting':p['output_change_accounting']} for p in result['pairs'] if p['first']==captures[0]['name']]},indent=2))
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--capture',type=Path,action='append',required=True)
    parser.add_argument('--out',type=Path,required=True);parser.add_argument('--focus',type=Path)
    args=parser.parse_args();main(args.capture,args.out,args.focus)
