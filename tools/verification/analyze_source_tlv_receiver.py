"""Independent CPU audit of saved TLV receiver runs. Never changes thresholds.

Requires sibling tlv_volume_oracle.py and analyze_source_tlv_volumes.py. All GPU
inputs/readbacks and PNGs are read-only. Outputs contain per-stage numerical
checks, exact failing differences, upload records, image equality and known
diagnostic stage drift. A runtime failure remains a failure even if numerics pass.
"""
from pathlib import Path
import argparse,hashlib,json,math,sys
import numpy as np
from PIL import Image
from tlv_volume_oracle import inject_resolved,filter_volume
from analyze_source_tlv_volumes import difference,read_volume


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read_json(path): return json.loads(path.read_text(encoding='utf-8-sig'))


def stats(a,b):
    if a.shape!=b.shape: raise ValueError('Mismatched array shape')
    if not np.isfinite(a).all() or not np.isfinite(b).all(): raise ValueError('Nonfinite diagnostic')
    delta=b.astype(np.float64)-a.astype(np.float64)
    mask=np.any(delta!=0,axis=-1) if delta.ndim==3 else delta!=0
    yy,xx=np.nonzero(mask)
    return {'exact_equal':bool(not mask.any()),'changed_components':int(np.count_nonzero(delta)),
        'changed_pixels':int(mask.sum()),'max_abs':float(np.max(np.abs(delta))),
        'mean_abs':float(np.mean(np.abs(delta))),
        'bbox_xyxy':[int(xx.min()),int(yy.min()),int(xx.max()+1),int(yy.max()+1)] if len(xx) else None}


def stage_drift(run,out):
    names=['baseline','baseline-repeat','receiver-bypass','restored']
    folders={name:run/('youxian-default-'+name+'-diagnostic') for name in names}
    if not all(p.exists() for p in folders.values()): return {'available':False}
    out.mkdir(parents=True,exist_ok=True)
    fields={};meta={};timebytes={};parameters={}
    for name,folder in folders.items():
        stage=read_json(folder/'stage.json');dof=read_json(folder/'dof/capture.json')
        if not dof.get('complete') or dof.get('error'): raise ValueError('Incomplete DOF '+name)
        data=np.fromfile(folder/'dof/samples.rgba32f',dtype='<f4').reshape(dof['record_shape'])
        w,h=stage['width'],stage['height']
        fields[name]={'pre_dof':data[:,:,0,:],'post_dof_unrounded':data[:,:,1,:],
            'linear_depth':data[:,:,2,0],'center_coc':data[:,:,2,1],'bokeh_coc':data[:,:,2,2],'recombine_mix':data[:,:,2,3]}
        for key in ('before_rgba16f','layer_rgba16f','after_rgba16f'):
            fields[name]['separate_'+key]=np.fromfile(folder/stage[key]['file'],dtype='<f2').reshape(h,w,4)
        fields[name]['final_png']=np.asarray(Image.open(run/('youxian-default-'+name+'.png')).convert('RGBA'))
        clock=(folder/stage['scene_time_ubo']['file']).read_bytes()
        timebytes[name]=clock
        parameters[name]=dof['parameters_f32']
        meta[name]={'scene_shader_time_reported':stage.get('scene_shader_time'),
            'scene_ubo_f32':np.frombuffer(clock,dtype='<f4').tolist(),'scene_ubo_hex':clock.hex(),
            'particles':stage.get('particles'),'groups':stage.get('groups'),'dof_frame':dof.get('frame'),
            'dof_capture_sha256':sha(folder/'dof/samples.rgba32f')}
    pairs=[]
    for i,first in enumerate(names):
        for second in names[i+1:]:
            row={'first':first,'second':second,'fields':{}}
            for field,a in fields[first].items():
                b=fields[second][field]
                s=stats(a,b);row['fields'][field]=s
                if not s['exact_equal']:
                    delta=b.astype(np.float32)-a.astype(np.float32)
                    mask=np.any(delta!=0,axis=-1) if delta.ndim==3 else delta!=0
                    coordinates=np.argwhere(mask)
                    npz=out/(first+'__'+second+'__'+field+'.npz')
                    np.savez_compressed(npz,yx=coordinates,first=a[mask],second=b[mask],delta=delta[mask])
                    s['exact_changed_samples']=str(npz)
            order=['pre_dof','post_dof_unrounded','separate_before_rgba16f','separate_layer_rgba16f','separate_after_rgba16f','final_png']
            row['earliest_recorded_change']=next((p for p in order if not row['fields'][p]['exact_equal']),None)
            pairs.append(row)
    result={'available':True,'metadata':meta,'pairs':pairs,
        'scene_ubo_exact_across_stages':len(set(timebytes.values()))==1,
        'dof_parameters_exact_across_stages':all(parameters[n]==parameters[names[0]] for n in names),
        'same_render_frame_correlation_proven':False,
        'correlation_limit':'DOF async and separate capture requests are queued together but saved data lacks a shared frame ID; final PNG is taken after async completion. Compare same-stage snapshots, not cross-stage bytes as if one frame.',
        'threshold':'Exact equality; no masked pixels and no epsilon'}
    (out/'stage-drift.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    return result


def analyze(run,out,diagnostic_only=False):
    out.mkdir(parents=True,exist_ok=True)
    if diagnostic_only:
        result=stage_drift(run,out/'stage-drift')
        print(json.dumps({'available':result.get('available'),'time_frozen':result.get('scene_ubo_exact_across_stages'),
            'pairs':[{'first':p['first'],'second':p['second'],'earliest':p['earliest_recorded_change'],
                'changed':{k:v['changed_components'] for k,v in p['fields'].items()}} for p in result.get('pairs',[])]},indent=2))
        return result
    source=read_json(run/'receiver.json')
    failures=[{'kind':'runtime','message':v} for v in source.get('failures',[])]
    views=[];full_count=0
    if source.get('stage')!='complete':failures.append({'kind':'runtime','message':'Incomplete receiver run'})
    for map_data in source['maps']:
        for view in map_data['views']:
            name=map_data['map']+'-'+view['name'];folder=run/name;destination=out/name;destination.mkdir(exist_ok=True)
            item={'name':name,'target_family':view.get('target_family'),'cascades':[],
                'source_energy_over_pi':view.get('bake',{}).get('source_energy_over_pi'),
                'sun_light_function_disabled':view.get('bake',{}).get('sun_light_function_disabled'),
                'sun_shadow_enabled':view.get('bake',{}).get('sun_shadow_enabled')}
            try:
                uploads=view['bake']['uploads'];expected={(c,v) for c in (0,1) for v in ('ambient','directional')}
                item['upload_records_passed']=(len(uploads)==4 and {(u['cascade'],u['volume']) for u in uploads}==expected and all(u['byte_exact'] and u['slices']==64 for u in uploads))
                item['upload_records']=uploads
                if not item['upload_records_passed']:failures.append({'kind':'upload','view':name})
                for cascade in (0,1):
                    prefix='cascade'+str(cascade)
                    r=read_volume(folder/(prefix+'-resolved.f32'),'<f4');d=read_volume(folder/(prefix+'-directions.f32'),'<f4')
                    a,b=inject_resolved(r,d);row={'cascade':cascade,'checks':{},'inputs_sha256':{
                        'resolved':sha(folder/(prefix+'-resolved.f32')),'directions':sha(folder/(prefix+'-directions.f32'))}}
                    for label,ref in [('ambient',a),('directional',b)]:
                        raw=read_volume(folder/(prefix+'-raw-'+label+'.rgba16f'),'<f2')
                        filtered=read_volume(folder/(prefix+'-filtered-'+label+'.rgba16f'),'<f2')
                        row['checks']['raw-'+label]=difference(raw,ref,destination/(prefix+'-raw-'+label+'-diff.npz'))
                        row['checks']['filtered-'+label+'-isolated']=difference(filtered,filter_volume(raw),destination/(prefix+'-filtered-'+label+'-isolated-diff.npz'))
                        row['checks']['filtered-'+label+'-end-to-end']=difference(filtered,filter_volume(ref),destination/(prefix+'-filtered-'+label+'-end-to-end-diff.npz'),False)
                    row['passed']=all(c.get('passed',True) for c in row['checks'].values())
                    if not row['passed']:failures.append({'kind':'numeric','view':name,'cascade':cascade})
                    item['cascades'].append(row);full_count+=1
                item['images']={}
                image_pairs=[('baseline-repeat','baseline','baseline-repeat',True),('bypass','baseline','receiver-bypass',True),
                    ('restore','baseline','restored',True),('sun-contribution','sun-suppressed','sun-tlv',False)]
                if view.get('target_family'):image_pairs.append(('target-contribution','target-suppressed','target-tlv',False))
                for key,first,second,exact in image_pairs:
                    p1=run/(name+'-'+first+'.png');p2=run/(name+'-'+second+'.png')
                    s=stats(np.asarray(Image.open(p1).convert('RGBA')),np.asarray(Image.open(p2).convert('RGBA')))
                    s['source_sha256']=[sha(p1),sha(p2)]
                    s['passed']=s['exact_equal'] if exact else s['changed_components']>0
                    s['criterion']='exact image equality' if exact else 'nonzero recorded contribution; not a perceptual-quality threshold'
                    item['images'][key]=s
                    if not s['passed']:failures.append({'kind':'image','view':name,'check':key})
                if view['name']=='inside-state':
                    item['inside_state_passed']=bool(item['sun_light_function_disabled'] and not item['sun_shadow_enabled'] and abs(item['source_energy_over_pi']-3/math.pi)<1e-6)
                    if not item['inside_state_passed']:failures.append({'kind':'inside-state','view':name})
                item['restore_errors']=view.get('restore',{}).get('errors',['Missing restore result'])
                if item['restore_errors']:failures.append({'kind':'restore','view':name,'errors':item['restore_errors']})
            except Exception as exc:
                item['error']=str(exc);failures.append({'kind':'input','view':name,'message':str(exc)})
            views.append(item)
    try:drift=stage_drift(run,out/'stage-drift')
    except Exception as exc:drift={'error':str(exc)};failures.append({'kind':'stage-diagnostic','message':str(exc)})
    result={'passed':not failures,'failures':failures,'views':views,'baker_cascades_checked':full_count,
        'stage_drift':drift,'source_manifest_sha256':sha(run/'receiver.json'),
        'numeric_gate':'raw pack and isolated filter <=1 adjacent binary16 ULP; end-to-end differences retained separately',
        'freeze_gate':'exact full PNG equality; runtime failures never erased',
        'scope':'Frozen sun-only receiver diagnostic, not full TLV or source GPU shadow parity. Upload checks are recorded runtime roundtrip assertions.'}
    (out/'receiver-cpu-validation.json').write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps({'passed':result['passed'],'failures':failures,'views':len(views),'baker_cascades':full_count},ensure_ascii=False))
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--diagnostic-only',action='store_true')
    args=p.parse_args();r=analyze(args.run,args.out,args.diagnostic_only)
    sys.exit(0 if args.diagnostic_only or r['passed'] else 1)
