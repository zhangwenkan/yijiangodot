"""Analyze read-only staged HDR/depth and full UBO captures, preserving equality."""
from pathlib import Path
import argparse,json,hashlib
import numpy as np
from analyze_distortion_drift import stats,save_diff,changed

def read_json(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def ubo_diff(a,b):
    if len(a)!=len(b):return {'byte_exact':False,'size_mismatch':[len(a),len(b)]}
    aa=np.frombuffer(a,np.uint8);bb=np.frombuffer(b,np.uint8);offsets=np.flatnonzero(aa!=bb)
    slots=sorted(set(int(i//4*4) for i in offsets));rows=[]
    for offset in slots:
        av=a[offset:offset+4];bv=b[offset:offset+4]
        rows.append({'offset':offset,'first_u32':int(np.frombuffer(av,'<u4')[0]),'second_u32':int(np.frombuffer(bv,'<u4')[0]),
            'first_f32':float(np.frombuffer(av,'<f4')[0]),'second_f32':float(np.frombuffer(bv,'<f4')[0]),'first_hex':av.hex(),'second_hex':bv.hex()})
    return {'byte_exact':len(offsets)==0,'changed_byte_count':len(offsets),'changed_offsets':offsets.tolist(),'changed_fourbyte_slots':rows}

def main(run,out):
    out.mkdir(parents=True,exist_ok=True)
    folders=sorted(run.glob('before-probe-*'))+sorted(run.glob('after-probe-*'))
    captures=[];report={'captures':[],'pairs':[],'scope':'Only saved source pass input/output bytes. Exact equality; no numerical epsilon or pixel masks.'}
    names=['post-opaque','before-atmosphere','after-atmosphere']
    for folder in folders:
        meta=read_json(folder/'capture.json');h,w=meta['height'],meta['width'];fields={};blobs={};stage_meta={}
        for upstream in meta['upstream']:
            filename=upstream['rgba16f']['file'];name=filename.removesuffix('-rgba16f.bin')
            fields[name]=np.fromfile(folder/filename,'<f2').reshape(h,w,4)
            fields[name+'-depth']=np.fromfile(folder/upstream['depth_f32']['file'],'<f4').reshape(h,w)
            blobs[name]=(folder/upstream['scene_ubo']['file']).read_bytes()
            stage_meta[name]={k:upstream[k] for k in ('callback_serial','drawn_frame','token')}
        for field,dtype in [('before_rgba16f','<f2'),('accumulation_rgba8','u1'),('after_rgba16f','<f2')]:
            fields[field]=np.fromfile(folder/meta[field]['file'],dtype).reshape(h,w,4)
        row={'name':folder.name,'stage_metadata':stage_meta,
            'drawn_frame_consistent':len(set(m['drawn_frame'] for m in stage_meta.values()))==1,
            'token_consistent':len(set(m['token'] for m in stage_meta.values()))==1,
            'callback_serial_consistent':len(set(m['callback_serial'] for m in stage_meta.values()))==1,
            'scene_ubo_stage_equal':len(set(blobs.values()))==1,
            'scene_ubo_stage_sizes':{n:len(b) for n,b in blobs.items()},
            'same_capture_opaque_to_before_atmosphere':stats(fields['post-opaque'],fields['before-atmosphere']),
            'same_capture_depth_equal':all(not np.any(changed(fields[names[0]+'-depth'],fields[n+'-depth'])) for n in names)}
        captures.append({'name':folder.name,'fields':fields,'blobs':blobs});report['captures'].append(row)
    for index,first in enumerate(captures):
        for second in captures[index+1:]:
            row={'first':first['name'],'second':second['name'],'fields':{},'ubo':{}}
            for key,a in first['fields'].items():
                b=second['fields'][key];s=stats(a,b);s['exact_samples']=save_diff(a,b,out/(first['name']+'__'+second['name']+'__'+key+'.npz'));row['fields'][key]=s
            for key,a in first['blobs'].items():row['ubo'][key]=ubo_diff(a,second['blobs'][key])
            order=names+['before_rgba16f','accumulation_rgba8','after_rgba16f']
            row['earliest_recorded_change']=next((key for key in order if not row['fields'][key]['byte_exact']),None)
            report['pairs'].append(row)
    report['all_stage_frame_ids_consistent']=all(c['drawn_frame_consistent'] and c['token_consistent'] and c['callback_serial_consistent'] for c in report['captures'])
    report['all_depths_exact']=all(all(s['byte_exact'] for k,s in p['fields'].items() if k.endswith('-depth')) for p in report['pairs'])
    report['all_ubos_exact']=all(all(s['byte_exact'] for s in p['ubo'].values()) for p in report['pairs'])
    report['changed_ubo_fourbyte_offsets']=sorted(set(s['offset'] for p in report['pairs'] for d in p['ubo'].values() for s in d.get('changed_fourbyte_slots',[])))
    report['earliest_counts']={str(key):sum(p['earliest_recorded_change']==key for p in report['pairs']) for key in [None]+names+['before_rgba16f','accumulation_rgba8','after_rgba16f']}
    report['max_changed_pixels_by_field']={k:max(p['fields'][k]['changed_pixels'] for p in report['pairs']) for k in captures[0]['fields']}
    (out/'upstream-drift.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('captures','pairs')},indent=2))
    print(json.dumps({'first_pair':report['pairs'][0],'first_capture':report['captures'][0]},indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();main(a.run,a.out)
