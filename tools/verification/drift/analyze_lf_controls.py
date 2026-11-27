"""CPU-only exact, within-mode analysis of retained LF controls.

Never writes to source captures, launches Godot or changes production.
"""
from pathlib import Path
import argparse, hashlib, itertools, json, struct
import numpy as np
from analyze_shadow_controls import load, STAGES
from analyze_distortion_drift import stats, changed, save_diff
from analyze_upstream_drift import ubo_diff

MODES = ['original', 'sun-lf-off', 'all-lf-off', 'restored']

def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))

def digest(data):
    return hashlib.sha256(data).hexdigest()

def clock(blob):
    if len(blob) != 5696:
        raise ValueError('Only audited Godot 4.7.2 float 2848x2 layout supported')
    return {'current_time':struct.unpack_from('<f',blob,2816)[0],
            'current_taa_frame_count':struct.unpack_from('<f',blob,2820)[0],
            'current_taa_jitter':list(struct.unpack_from('<2f',blob,2824)),
            'previous_time':struct.unpack_from('<f',blob,5664)[0],
            'previous_taa_frame_count':struct.unpack_from('<f',blob,5668)[0],
            'previous_taa_jitter':list(struct.unpack_from('<2f',blob,5672)),
            'legacy_2832_emissive_exposure':struct.unpack_from('<f',blob,2832)[0]}

def main(run, out):
    out.mkdir(parents=True,exist_ok=True)
    control=read_json(run/'receiver.json'); runner=read_json(run/'runner.json')
    script=(run/'verifier.gd').read_text(encoding='utf-8-sig')
    expected=[
        'state.material.set_shader_parameter("source_lf_count",0 if mode == "all-lf-off" else state.count)',
        'state.material.set_shader_parameter("source_lf_sun_enabled",false if mode == "sun-lf-off" else state.sun)',
        'check(state.material.get_shader_parameter("source_lf_count") == state.count,"LightFunction count not restored")',
        'check(state.material.get_shader_parameter("source_lf_sun_enabled") == state.sun,"LightFunction sun flag not restored")']
    if not all(token in script for token in expected):
        raise ValueError('Saved LF-control implementation differs from audited contract')
    report={'run':str(run),'scope':'Only six within-condition frame pairs per mode; no cross-condition image equality/subtraction or relaxed thresholds.',
        'runner':runner,'uniform_controls':{
            'captured_material_count':control.get('lf_materials'),
            'applied_source_contract_verified':True,
            'original':'Saved source_lf_count and source_lf_sun_enabled.',
            'sun-lf-off':'Saved count; source_lf_sun_enabled=false where present.',
            'all-lf-off':'source_lf_count=0; sun flag restored. The receiving include gates both sun/local functions under count>0.',
            'restored':'Both original saved values reapplied before four captures; final get_shader_parameter checks passed if failures empty.',
            'final_cpu_uniform_restore_checks_passed':not control.get('failures',['missing failures']),
            'limit':'This run did not serialize individual applied per-material values or GPU uniform buffers; shutdown proof is saved setter code plus completed run, not independent GPU-buffer readback.'},
        'modes':[],'full_ubo_captures':[]}
    all_blobs=[]; all_depths=[]; all_accumulations=[]
    for mode in MODES:
        captures=[load(p) for p in sorted(run.glob(mode+'-[0-9][0-9]'))]
        if len(captures)!=4: raise ValueError('Expected 4 captures for '+mode)
        folder=out/mode;folder.mkdir(exist_ok=True)
        row={'mode':mode,'captures':[],'pairs':[]}
        h,w=captures[0]['fields']['post-opaque'].shape[:2]
        union=np.zeros((h,w),bool); max_delta=0.
        for cap in captures:
            sm=cap['stage_meta']; meta=cap['meta']
            item={'name':cap['name'],'stage_frame_consistent':len(set(v['drawn_frame'] for v in sm.values()))==1,
                  'stage_token_consistent':len(set(v['token'] for v in sm.values()))==1,
                  'stage_callback_serial_consistent':len(set(v['callback_serial'] for v in sm.values()))==1,
                  'process_mode':meta.get('process_mode'),'time_scale':meta.get('time_scale'),
                  'postopaque_sha256':digest(cap['fields']['post-opaque'].tobytes()),
                  'opaque_equals_before_atmosphere':stats(cap['fields']['post-opaque'],cap['fields']['before-atmosphere'])['byte_exact'],
                  'full_ubos_equal_across_stages':len(set(cap['blobs'].values()))==1}
            row['captures'].append(item)
            for name,blob in cap['blobs'].items():
                all_blobs.append(blob)
                report['full_ubo_captures'].append({'capture':cap['name'],'stage':name,'size':len(blob),'sha256':digest(blob),'clock':clock(blob)})
            all_depths.extend(cap['fields'][n+'-depth'].tobytes() for n in STAGES)
            all_accumulations.append(cap['fields']['accumulation_rgba8'].tobytes())
        for first,second in itertools.combinations(captures,2):
            pair={'first':first['name'],'second':second['name'],'fields':{},'ubo':{}}
            for key,a in first['fields'].items():
                b=second['fields'][key]; result=stats(a,b)
                if key=='post-opaque':
                    union|=changed(a,b);max_delta=max(max_delta,result['max_abs'])
                    result['exact_samples']=save_diff(a,b,folder/(first['name']+'__'+second['name']+'__post-opaque.npz'))
                pair['fields'][key]=result
            for key,blob in first['blobs'].items():pair['ubo'][key]=ubo_diff(blob,second['blobs'][key])
            order=STAGES+['before_rgba16f','accumulation_rgba8','after_rgba16f']
            pair['earliest_recorded_change']=next((k for k in order if not pair['fields'][k]['byte_exact']),None)
            row['pairs'].append(pair)
        yy,xx=np.nonzero(union)
        row['summary']={'mode':mode,'changed_postopaque_pairs':sum(not p['fields']['post-opaque']['byte_exact'] for p in row['pairs']),
            'postopaque_unique_hashes':len(set(c['postopaque_sha256'] for c in row['captures'])),
            'postopaque_changed_pixel_range':[min(p['fields']['post-opaque']['changed_pixels'] for p in row['pairs']),max(p['fields']['post-opaque']['changed_pixels'] for p in row['pairs'])],
            'postopaque_union_pixels':int(union.sum()),'postopaque_max_abs':max_delta,
            'postopaque_union_bbox_xyxy':[int(xx.min()),int(yy.min()),int(xx.max()+1),int(yy.max()+1)] if len(xx) else None,
            'all_depths_exact':all(v['byte_exact'] for p in row['pairs'] for k,v in p['fields'].items() if k.endswith('-depth')),
            'all_ubos_exact':all(v['byte_exact'] for p in row['pairs'] for v in p['ubo'].values()),
            'all_accumulations_exact':all(p['fields']['accumulation_rgba8']['byte_exact'] for p in row['pairs']),
            'earliest_counts':{str(k):sum(p['earliest_recorded_change']==k for p in row['pairs']) for k in [None]+order}}
        report['modes'].append(row)
    report['all_48_full_ubos_exact']=len(all_blobs)==48 and len(set(all_blobs))==1
    report['all_48_depths_exact']=len(all_depths)==48 and len(set(all_depths))==1
    report['all_16_accumulations_exact']=len(all_accumulations)==16 and len(set(all_accumulations))==1
    report['all_stage_capture_ids_consistent']=all(c['stage_frame_consistent'] and c['stage_token_consistent'] and c['stage_callback_serial_consistent'] for m in report['modes'] for c in m['captures'])
    report['summary']=[r['summary'] for r in report['modes']]
    (out/'lf-controls-analysis.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    summary={k:v for k,v in report.items() if k not in ('modes','full_ubo_captures')}
    summary['verified_clock']=clock(all_blobs[0])
    (out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(summary,ensure_ascii=False,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--run',type=Path,required=True);parser.add_argument('--out',type=Path,required=True)
    a=parser.parse_args();main(a.run,a.out)
