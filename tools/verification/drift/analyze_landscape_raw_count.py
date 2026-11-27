"""CPU-only strict raw local-light count analysis of three conditions; never runs Godot.

Reads a completed capture tree and writes a fresh separate output directory.
Exact drift is preserved separately from evidence/material-restore validity.
"""
from pathlib import Path
import argparse
from collections import Counter
import csv
import hashlib
import itertools
import json
import re
import struct
import sys
import numpy as np
from PIL import Image

STAGES = ('post-opaque', 'before-atmosphere', 'after-atmosphere')


def digest(blob):
    return hashlib.sha256(blob).hexdigest()


def read_json(path):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('Duplicate JSON key: ' + key)
            value[key] = item
        return value
    return json.loads(path.read_text(encoding='utf-8-sig'), object_pairs_hook=unique)


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


def need(value, message):
    if not value:
        raise ValueError(message)


def reference(folder, item, expected_bytes=None):
    path = (folder / item['file']).resolve()
    need(path.is_relative_to(folder.resolve()), 'Reference escaped capture folder')
    blob = path.read_bytes()
    if expected_bytes is not None:
        need(len(blob) == expected_bytes, 'Wrong raw byte count: ' + str(path))
    if 'bytes' in item:
        need(item['bytes'] == len(blob), 'Metadata byte count mismatch: ' + str(path))
    if 'sha256' in item:
        need(item['sha256'] == digest(blob), 'Metadata hash mismatch: ' + str(path))
    return blob


def clock(blob):
    need(len(blob) == 5696, 'Unsupported scene UBO size')
    values = struct.unpack_from('<4f', blob, 2816) + struct.unpack_from('<4f', blob, 5664)
    need(all(np.isfinite(value) for value in values), 'Nonfinite UBO time/TAA/jitter')
    return {'time': values[0], 'taa': values[1], 'jitter': list(values[2:4]),
            'previous_time': values[4], 'previous_taa': values[5], 'previous_jitter': list(values[6:8])}


def load_capture(folder, expected_token):
    meta = read_json(folder / 'capture.json')
    need(meta.get('label') == folder.name, 'Capture label mismatch')
    h, w = int(meta['height']), int(meta['width'])
    need(h > 0 and w > 0, 'Invalid capture size')
    fields, blobs, stages = {}, {}, {}
    upstream = meta['upstream']
    need(isinstance(upstream, list) and len(upstream) == 3, 'Expected three upstream stages')
    for stage in upstream:
        name = stage['rgba16f']['file'].removesuffix('-rgba16f.bin')
        need(name in STAGES and name not in stages, 'Missing/duplicate/unexpected upstream stage')
        need(stage['width'] == w and stage['height'] == h, 'Upstream dimensions mismatch')
        fields[name] = np.frombuffer(reference(folder, stage['rgba16f'], h*w*8), '<f2').reshape(h, w, 4)
        fields[name+'-depth'] = np.frombuffer(reference(folder, stage['depth_f32'], h*w*4), '<f4').reshape(h, w)
        blobs[name] = reference(folder, stage['scene_ubo'], 5696)
        stages[name] = {key: stage[key] for key in ('drawn_frame', 'token', 'callback_serial')}
        need(stage['token'] == expected_token, 'Unexpected stage request token')
    need(set(stages) == set(STAGES), 'Incomplete upstream stage set')
    for key in ('drawn_frame', 'token', 'callback_serial'):
        need(len({stage[key] for stage in stages.values()}) == 1, 'Upstream stage identity mismatch: '+key)
    for key, dtype, size in (('before_rgba16f', '<f2', 8), ('after_rgba16f', '<f2', 8), ('accumulation_rgba8', 'u1', 4)):
        fields[key] = np.frombuffer(reference(folder, meta[key], h*w*size), dtype).reshape(h, w, 4)
    for key, data in fields.items():
        need(np.isfinite(data).all(), 'Nonfinite image/depth: ' + key)
    full = reference(folder, meta['scene_ubo_full'], 5696)
    slice_ = reference(folder, meta['scene_time_ubo'], 16)
    need(meta.get('scene_ubo_size') == 5696 and meta.get('scene_time_offset') == 2816
         and meta.get('scene_ubo_layout') == 'godot-4.7.2-float-2848x2', 'Distortion clock layout metadata missing')
    need(slice_ == full[2816:2832], 'Distortion time slice differs from full UBO')
    blobs['distortion'] = full
    clocks = {key: clock(blob) for key, blob in blobs.items()}
    need(meta.get('time_scale') == 0 and meta.get('process_mode') == 4, 'Scene not recorded as frozen/disabled')
    need(meta.get('audit_mode') == 0, 'Unexpected distortion audit mode')
    fields['final_png_rgba8'] = np.asarray(Image.open(folder / 'final.png').convert('RGBA'))
    need(fields['final_png_rgba8'].shape == (h, w, 4), 'Final PNG dimensions differ from raw captures')
    zero = ~np.any(fields['accumulation_rgba8'], axis=2)
    need(np.array_equal(fields['before_rgba16f'].view('<u2')[zero], fields['after_rgba16f'].view('<u2')[zero]),
         'Zero-accumulation region changed raw bits')
    return {'name': folder.name, 'meta': meta, 'fields': fields, 'blobs': blobs, 'clocks': clocks,
            'stage_metadata': stages, 'height': h, 'width': w}


DIFFUSE_ORIGINAL = 'DIFFUSE_LIGHT += radiance * (nl / PI);'
DIFFUSE_REPLACEMENT = 'if (!LIGHT_IS_DIRECTIONAL) { DIFFUSE_LIGHT += vec3(1.0) / 16.0; }'
SPECULAR_ORIGINAL = (
    'SPECULAR_LIGHT += radiance*leaf_wrap*leaf_scatter*source_leaf_subsurface;',
    'SPECULAR_LIGHT += radiance * distribution * visibility * fresnel * nl * SPECULAR_AMOUNT;',
)
FRAGMENT_TAIL = 'FOG = source_height_fog_to_godot(source_hf_result,false);\n}\r\n'
OUTPUT_OVERRIDE = 'ALBEDO = vec3(1.0);\nMETALLIC = 0.0;\nSPECULAR = 0.0;\nEMISSION = vec3(0.0);\nIRRADIANCE = vec4(0.0,0.0,0.0,1.0);\nRADIANCE = vec4(0.0,0.0,0.0,1.0);\n'


def expected_raw_shader(source):
    modes = list(re.finditer(r'(?m)^render_mode\s+[^;]+;', source))
    need(len(modes) == 1 and not re.search(r'\b(?:unshaded|fog_disabled|ambient_light_disabled)\b', modes[0][0]), 'Unexpected original render_mode')
    original_mode = modes[0][0]
    installed_mode = original_mode[:-1]+', fog_disabled, ambient_light_disabled;'
    need(source.count('void fragment() {') == 1 and source.count(FRAGMENT_TAIL) == 1 and source.endswith(FRAGMENT_TAIL), 'Fragment does not end at the unique audited FOG tail')
    need(len(re.findall(r'\b(?:DIFFUSE_LIGHT|SPECULAR_LIGHT)\s*\+=',source)) == 3, 'Unexpected light accumulation count')
    need(all(source.count(line) == 1 for line in (DIFFUSE_ORIGINAL,*SPECULAR_ORIGINAL)), 'Expected exactly three unique audited accumulations')
    installed_tail = FRAGMENT_TAIL[:-3]+OUTPUT_OVERRIDE+'}\r\n'
    expected = source.replace(original_mode,installed_mode).replace(FRAGMENT_TAIL,installed_tail).replace(DIFFUSE_ORIGINAL,DIFFUSE_REPLACEMENT)
    for addition in SPECULAR_ORIGINAL: expected = expected.replace(addition,'if (false) { '+addition+' }')
    return expected,original_mode,installed_mode,installed_tail


def material_review(run, control, variant='raw-count'):
    need(variant == 'raw-count', 'Expected explicit raw-count variant')
    landscape=control['landscape_control']
    need(landscape.get('control_variant') == variant, 'Explicit control differs from GPU diagnostic')
    labels=['after-original','before-landscape-raw-count','after-landscape-raw-count','before-restored','after-restored']
    matches=[item for item in landscape['identification'] if item.get('matched') is True]
    need(len(matches) == 1 and matches[0]['material_id'] == landscape['target_material_id'], 'Expected one matching landscape')
    checks=landscape['state_checks']
    need([row['label'] for row in checks] == labels, 'Missing/duplicate/reordered material state checks')
    need(all(row.get('passed') is True and row['material_count'] == 370 and row['target_material_id'] == landscape['target_material_id']
             and row['target_unshaded'] is False and row.get('target_control_active') == ('landscape-raw-count' in row['label']) for row in checks), 'Runtime material state metadata failed')
    before_path,restored_path=run/'landscape-materials-before.json',run/'landscape-materials-restored.json'
    before,restored=read_json(before_path),read_json(restored_path)
    need(isinstance(before,list) and len(before) == 370 and len({row['material_id'] for row in before}) == 370, 'Expected 370 unique materials')
    need(before == restored and before_path.read_bytes() == restored_path.read_bytes(), 'Before/restored material snapshots differ')
    need(landscape['material_count'] == 370 and landscape['other_material_count'] == 369, 'Material count metadata differs')
    target=[row for row in before if row['material_id'] == landscape['target_material_id']]
    need(len(target) == 1 and target[0]['resource_name'] == 'OriginalLandscape_Compiled_youxian' and len(target[0]['parameters']) == 70, 'Wrong target material/uniform count')
    original=(run/'landscape-runtime-original.gdshader').read_bytes()
    installed=(run/'landscape-runtime-raw-count.gdshader').read_bytes()
    expected,original_mode,installed_mode,installed_tail=expected_raw_shader(original.decode('utf-8'))
    need(expected.encode('utf-8') == installed, 'Shader changed beyond audited raw-count edits')
    meta=landscape['raw_count']
    need(meta['diffuse_original'] == DIFFUSE_ORIGINAL and meta['diffuse_replacement'] == DIFFUSE_REPLACEMENT and tuple(meta['specular_original']) == SPECULAR_ORIGINAL, 'Accumulation metadata mismatch')
    need(meta['fragment_tail_original'] == FRAGMENT_TAIL and meta['fragment_tail_installed'] == installed_tail and meta['output_override'] == OUTPUT_OVERRIDE, 'Fragment override metadata mismatch')
    need(meta['render_mode_original'] == original_mode and meta['render_mode_installed'] == installed_mode and meta.get('inverse_source_exact') is True, 'Render mode/inverse metadata mismatch')
    need((meta['count_scale'],meta['count_min'],meta['count_max']) == (16,0,31), 'Count encoding metadata mismatch')
    need(digest(original) == landscape['original_shader_sha256'] == target[0]['shader_sha256'] and digest(installed) == landscape['installed_shader_sha256'], 'Shader hash mismatch')
    return {'passed':True,'material_count':370,'other_material_count':369,'target':matches[0],'target_uniform_count':70,
            'all_material_snapshot_bytes_exact':True,'all_material_snapshot_values_exact':True,'snapshot_sha256':digest(before_path.read_bytes()),
            'state_checks':checks,'original_shader_sha256':digest(original),'installed_shader_sha256':digest(installed),
            'scope':'CPU material state and exact shader edits. Other materials are unchanged; no GPU instruction equivalence is claimed.'}


def count_mask(rgb):
    values=rgb.astype(np.float64)
    scaled=values*16.0
    valid=np.isfinite(values).all(axis=-1)
    valid &= (values[...,0] == values[...,1]) & (values[...,1] == values[...,2])
    valid &= ((scaled >= 0.0) & (scaled <= 31.0) & (scaled == np.floor(scaled))).all(axis=-1)
    return valid,scaled[...,0]


def raw_count_review(captures, prior_samples_path, out):
    need(len(captures) == 4, 'Expected four raw-count frames')
    samples=read_json(prior_samples_path)
    need(isinstance(samples,list) and len(samples) == 906, 'Expected all 906 prior local-count drift pixels')
    xy=np.asarray([row['xy'] for row in samples])
    need(xy.shape == (906,2) and np.issubdtype(xy.dtype,np.integer), 'Prior sample coordinates must be integer pairs')
    need(len(set(map(tuple,xy.tolist()))) == 906, 'Duplicate prior count coordinates')
    need(all(row.get('world_valid') is True for row in samples), 'Prior sample includes invalid reconstructed world position')
    h,w=captures[0]['height'],captures[0]['width']
    need(((xy[:,0] >= 0) & (xy[:,0] < w) & (xy[:,1] >= 0) & (xy[:,1] < h)).all(), 'Prior coordinates outside capture')
    x,y=xy.T
    prior_depth=np.asarray([row['depth'] for row in samples],dtype='<f4')
    need(np.isfinite(prior_depth).all(), 'Nonfinite prior depth')
    validity=[];rgbs=[];counts=[];depth_checks=[];frames=[]
    for cap in captures:
        rgb=cap['fields']['post-opaque'][...,:3]
        mask,scaled=count_mask(rgb)
        depth_exact=cap['fields']['post-opaque-depth'][y,x].view('<u4') == prior_depth.view('<u4')
        validity.append(mask[y,x]);rgbs.append(rgb[y,x].astype(float));counts.append(scaled[y,x]);depth_checks.append(depth_exact)
        encoded=np.full((h,w),255,dtype=np.uint8)
        encoded[mask]=scaled[mask].astype(np.uint8)
        np.savez_compressed(out/(cap['name']+'-candidate-counts.npz'),candidate_mask=mask,count_or_255=encoded)
        Image.fromarray(mask.astype(np.uint8)*255).save(out/(cap['name']+'-candidate-mask.png'))
        frames.append({'name':cap['name'],'numeric_candidate_pixels':int(mask.sum()),'prior_sample_valid_count':int(mask[y,x].sum()),'prior_depth_exact_count':int(depth_exact.sum())})
    valid=np.asarray(validity);depths=np.asarray(depth_checks)
    all_valid=valid.all(axis=0);all_depth=depths.all(axis=0)
    details=[{'xy':xy[i].tolist(),'prior_depth':float(prior_depth[i]),'rgb_by_frame':[rgb[i].tolist() for rgb in rgbs],
              'numeric_count_by_frame':[int(count[i]) if valid[j,i] else None for j,count in enumerate(counts)],
              'numeric_valid_by_frame':valid[:,i].tolist(),'prior_depth_exact_by_frame':depths[:,i].tolist(),
              'passed':bool(all_valid[i] and all_depth[i])} for i in range(906)]
    write_json(out/'raw-count-prior-pixel-review.json',details)
    passed=bool(all_valid.all() and all_depth.all())
    result={'passed':passed,'prior_samples_file':str(prior_samples_path),'prior_samples_sha256':digest(prior_samples_path.read_bytes()),
            'prior_sample_count':906,'valid_in_all_four_frames':int(all_valid.sum()),'depth_exact_in_all_four_frames':int(all_depth.sum()),
            'invalid_numeric_coordinates':xy[~all_valid].tolist(),'depth_mismatch_coordinates':xy[~all_depth].tolist(),'frames':frames,
            'criterion':'post-opaque raw HDR RGB exactly equal; each RGB channel times 16 exactly an integer in 0..31; no tolerance or rounding acceptance.',
            'scope':'Numeric candidate mask only. Other 369 materials are unchanged and can coincidentally satisfy this test. Prior world samples/depth are not runtime material IDs; independent source-ray coverage is still needed for conservative landscape attribution.',
            'pipeline_boundary':'Failure rejects count interpretation, including possible residual FOG or renderer multiplication. No tolerance is added to hide pipeline contamination.'}
    write_json(out/'raw-count-validation.json',result)
    return result


def current_run_numeric_review(captures, out):
    """Audit this run's own changed raw pixels; never substitutes for prior-sample checks."""
    need(len(captures) == 4, 'Expected four raw-count frames for current-run review')
    frames=[cap['fields']['post-opaque'] for cap in captures]
    need(all(frame.ndim == 3 and frame.shape[-1] == 4 and frame.dtype == np.dtype('<f2')
             and frame.shape == frames[0].shape for frame in frames), 'Current count requires equal RGBA16F frame shapes')
    union=np.zeros(frames[0].shape[:2],dtype=bool)
    for first,second in itertools.combinations(frames,2):
        union |= np.any(first.view('<u2') != second.view('<u2'),axis=-1)
    yy,xx=np.nonzero(union)
    xy=np.column_stack((xx,yy))
    rgb=np.stack([frame[yy,xx,:3].astype(np.float64) for frame in frames])
    finite=np.isfinite(rgb).all(axis=-1)
    rgb_equal=(rgb[...,0] == rgb[...,1]) & (rgb[...,1] == rgb[...,2])
    scaled=rgb*16.0
    integer=(scaled == np.floor(scaled)).all(axis=-1) & finite
    in_range=((scaled >= 0.0) & (scaled <= 31.0)).all(axis=-1)
    valid=finite & rgb_equal & integer & in_range
    valid_all=valid.all(axis=0)
    has_changes=len(xy)>0
    all_valid=bool(valid_all.all()) if has_changes else None
    accepted=scaled[:,valid_all,0].T
    histogram=Counter(tuple(map(int,values)) for values in accepted)
    max_change=int(np.ptp(accepted,axis=1).max()) if len(accepted) else None
    variation=bool(max_change>0) if has_changes and all_valid else (False if not has_changes else None)
    def finite_list(values):
        return [float(value) if np.isfinite(value) else None for value in values]
    details=[{'xy':xy[i].tolist(),'rgb_by_frame':[finite_list(rgb[frame,i]) for frame in range(4)],
              'exact_integer_counts_by_frame':[int(value) for value in scaled[:,i,0]] if valid_all[i] else None,
              'valid_by_frame':valid[:,i].tolist(),'finite_by_frame':finite[:,i].tolist(),
              'rgb_equal_by_frame':rgb_equal[:,i].tolist(),'integer_by_frame':integer[:,i].tolist(),
              'range_by_frame':in_range[:,i].tolist()} for i in range(len(xy))]
    write_json(out/'raw-count-current-pixel-review.json',details)
    np.savez_compressed(out/'raw-count-current-union.npz',mask=union,xy=xy,valid_by_frame=valid)
    result={'status':'no_changed_pixels' if not has_changes else ('numeric_candidates_valid' if all_valid else 'numeric_candidates_rejected'),
            'current_drift_union_pixels':len(xy),'valid_changed_pixels_all_four_frames':int(valid_all.sum()),
            'all_changed_pixels_numeric_valid':all_valid,'invalid_changed_coordinates':xy[~valid_all].tolist(),
            'count_temporal_variation':variation,'accepted_numeric_candidates_have_temporal_variation':bool(max_change>0) if max_change is not None else False,
            'max_accepted_count_change':max_change,'accepted_count_min':int(accepted.min()) if len(accepted) else None,
            'accepted_count_max':int(accepted.max()) if len(accepted) else None,'distinct_accepted_sequences':len(histogram),
            'accepted_sequence_histogram':[{'counts':list(counts),'pixels':pixels} for counts,pixels in histogram.most_common()],
            'per_frame_valid_changed_pixels':[int(row.sum()) for row in valid],
            'pixel_review_file':'raw-count-current-pixel-review.json','union_file':'raw-count-current-union.npz',
            'criterion':'This run raw post-opaque changed pixels; finite RGB exactly equal and every channel times 16 exactly an integer in 0..31. No epsilon, rounding acceptance or excluded changed pixels.',
            'identity_proven':False,
            'scope':'Independent current-run numeric candidates only; unchanged other materials may coincidentally encode integers. No runtime material or cluster identity is inferred.',
            'boundary':'This field never changes prior-sample validation or evidence_passed. Empty union means no count temporal variation was observed, not proof of landscape ownership or successful count encoding.'}
    write_json(out/'raw-count-current-validation.json',result)
    return result


def analyze(run, out, helpers, prior_samples, variant='raw-count'):
    need(variant == 'raw-count', 'Expected explicit raw-count mode')
    modes = ('original', 'landscape-raw-count', 'restored')
    sys.path.insert(0, str(helpers))
    from analyze_distortion_drift import stats, changed, save_diff
    from analyze_shadow_controls import unproject
    from analyze_upstream_drift import ubo_diff
    control, runner = read_json(run/'receiver.json'), read_json(run/'runner.json')
    need(runner.get('capture_passed') is True and runner.get('exit') == 0, 'GPU capture runner did not complete successfully')
    need(control.get('stage') == 'complete' and control.get('failures') == [], 'GPU diagnostic incomplete/failed')
    labels = [f'{mode}-{index:02d}' for mode in modes for index in range(4)]
    need(Counter(row['label'] for row in control['captures']) == Counter(labels), 'Missing/duplicate/unexpected capture report labels')
    need([row['label'] for row in control['captures']] == labels, 'Raw-count capture order differs')
    actual = [path.name for path in run.iterdir() if path.is_dir() and re.search(r'-\d\d$', path.name)]
    need(Counter(actual) == Counter(labels), 'Missing/extra capture directories')
    report = {'run': str(run), 'evidence_passed': False, 'failures': [], 'control_variant': variant, 'material_restore': material_review(run, control, variant),
              'scope': 'Exactly six within-condition comparisons in each of '+', '.join(modes)+'. No cross-condition image equality requirement.',
              'world_scope': 'First opaque depth surface from its same-frame UBO; reconstructed positions are not runtime object/material IDs.',
              'modes': [], 'helper_sha256': {name: digest((helpers/name).read_bytes()) for name in
                  ('analyze_distortion_drift.py', 'analyze_shadow_controls.py', 'analyze_upstream_drift.py')}}
    all_ubos, all_depths, all_accumulations = [], [], []
    for mode_index, mode in enumerate(modes):
        folder = out/mode; folder.mkdir()
        captures = [load_capture(run/f'{mode}-{i:02d}', mode_index*4+i) for i in range(4)]
        h, w = captures[0]['height'], captures[0]['width']
        need(all(cap['height'] == h and cap['width'] == w for cap in captures), 'Capture dimensions changed')
        union = np.zeros((h, w), bool); peak = np.zeros((h, w), np.float64)
        row = {'mode': mode, 'captures': [], 'pairs': []}
        for cap in captures:
            all_ubos.extend(cap['blobs'].values())
            all_depths.extend(cap['fields'][stage+'-depth'].tobytes() for stage in STAGES)
            all_accumulations.append(cap['fields']['accumulation_rgba8'].tobytes())
            row['captures'].append({'name': cap['name'], 'clocks': cap['clocks'], 'stage_metadata': cap['stage_metadata'],
                'ubo_sha256': {key: digest(blob) for key, blob in cap['blobs'].items()},
                'all_stage_ubo_equal': len(set(cap['blobs'][key] for key in STAGES)) == 1,
                'distortion_ubo_equals_upstream': cap['blobs']['distortion'] == cap['blobs']['post-opaque'],
                'png_later_frame': True})
        if mode == 'landscape-raw-count':
            report['raw_count_validation'] = raw_count_review(captures, prior_samples, out)
            report['current_run_count_candidates'] = current_run_numeric_review(captures, out)
        for first, second in itertools.combinations(captures, 2):
            pair = {'first': first['name'], 'second': second['name'], 'fields': {}, 'ubo': {}}
            for key, data in first['fields'].items():
                other = second['fields'][key]; result = stats(data, other)
                if key == 'post-opaque':
                    result['samples_npz'] = save_diff(data, other, folder/(first['name']+'__'+second['name']+'.npz'))
                    union |= changed(data, other)
                    peak = np.maximum(peak, np.abs(other.astype(float)-data.astype(float)).max(axis=-1))
                pair['fields'][key] = result
            pair['ubo'] = {key: ubo_diff(blob, second['blobs'][key]) for key, blob in first['blobs'].items()}
            order = list(STAGES)+['before_rgba16f', 'accumulation_rgba8', 'after_rgba16f', 'final_png_rgba8']
            pair['earliest_recorded_change'] = next((key for key in order if not pair['fields'][key]['byte_exact']), None)
            row['pairs'].append(pair)
        yy, xx = np.nonzero(union); xy = np.column_stack((xx, yy)); cap = captures[0]
        points = unproject(xy, cap['fields']['post-opaque-depth'][union], cap['blobs']['post-opaque'], w, h)
        samples = [{'xy': [int(x), int(y)], 'world_xyz': points['world'][i].tolist(), 'view_xyz': points['view'][i].tolist(),
                    'world_valid': bool(points['valid'][i]), 'depth': float(cap['fields']['post-opaque-depth'][y, x]),
                    'max_abs_delta': float(peak[y, x]), 'reprojection_error_pixels': points['error'][i].tolist(),
                    'rgba': [c['fields']['post-opaque'][y, x].tolist() for c in captures]} for i, (x, y) in enumerate(xy)]
        write_json(folder/'postopaque-world-samples.json', samples)
        with (folder/'postopaque-world-samples.csv').open('w', newline='', encoding='utf-8') as handle:
            writer = csv.writer(handle); writer.writerow(['x','y','depth','world_x','world_y','world_z','max_abs_delta','world_valid'])
            for sample in samples:
                writer.writerow(sample['xy']+[sample['depth']]+sample['world_xyz']+[sample['max_abs_delta'],sample['world_valid']])
        row['summary'] = {'mode': mode, 'pair_count': len(row['pairs']),
            'changed_pairs_by_field': {key: sum(not pair['fields'][key]['byte_exact'] for pair in row['pairs']) for key in cap['fields']},
            'changed_pixel_range_by_field': {key: [min(pair['fields'][key]['changed_pixels'] for pair in row['pairs']),
                max(pair['fields'][key]['changed_pixels'] for pair in row['pairs'])] for key in cap['fields']},
            'postopaque_union_pixels': int(union.sum()), 'postopaque_max_abs': float(peak.max()),
            'all_ubos_exact': all(item['byte_exact'] for pair in row['pairs'] for item in pair['ubo'].values()),
            'all_depths_exact': all(item['byte_exact'] for pair in row['pairs'] for key, item in pair['fields'].items() if key.endswith('-depth')),
            'accumulation_exact': all(pair['fields']['accumulation_rgba8']['byte_exact'] for pair in row['pairs']),
            'all_fields_exact': all(item['byte_exact'] for pair in row['pairs'] for item in pair['fields'].values()),
            'world_valid': int(points['valid'].sum()), 'world_reprojection_error_max': float(points['error'].max()) if len(xy) else 0,
            'earliest_counts': dict(Counter(str(pair['earliest_recorded_change']) for pair in row['pairs']))}
        report['modes'].append(row)
    need(len(report['modes']) == 3 and all(len(row['captures']) == 4 and len(row['pairs']) == 6 for row in report['modes']), 'Expected 12 captures with six pairs per condition')
    need(len(all_ubos) == 48 and len(all_depths) == 36 and len(all_accumulations) == 12, 'Expected 48 UBOs, 36 depths and 12 accumulations')
    report['evidence_passed'] = report['raw_count_validation']['passed']
    if not report['evidence_passed']:
        report['failures'].append('Raw-count interpretation rejected: prior drift pixels failed exact RGB/integer/range/depth validation')
    report['all_48_full_ubos_exact_across_conditions'] = len(all_ubos) == 48 and len(set(all_ubos)) == 1
    upstream_ubos = [row['ubo_sha256'][stage] for mode in report['modes'] for row in mode['captures'] for stage in STAGES]
    distortion_ubos = [row['ubo_sha256']['distortion'] for mode in report['modes'] for row in mode['captures']]
    need(len(upstream_ubos) == 36 and len(distortion_ubos) == 12, 'Expected 36 upstream and 12 distortion UBOs')
    report['all_36_upstream_ubos_exact_across_conditions'] = len(upstream_ubos) == 36 and len(set(upstream_ubos)) == 1
    report['all_12_distortion_ubos_exact_across_conditions'] = len(distortion_ubos) == 12 and len(set(distortion_ubos)) == 1
    report['ubo_stage_scope'] = 'Upstream and distortion UBOs are separate stage inputs. Their individual stability does not imply that all 48 buffers are equal to one another.'
    report['all_36_depths_exact_across_conditions'] = len(all_depths) == 36 and len(set(all_depths)) == 1
    report['all_12_accumulations_exact_across_conditions'] = len(all_accumulations) == 12 and len(set(all_accumulations)) == 1
    report['all_conditions_frozen_exact'] = all(row['summary']['all_fields_exact'] and row['summary']['all_ubos_exact'] for row in report['modes'])
    report['overall_passed'] = report['evidence_passed'] and report['all_conditions_frozen_exact']
    report['boundary'] = 'Evidence completion is distinct from frozen equality. A stable temporary shader control only localizes the changed path; it is not a production fix or UE fidelity proof. Final PNGs occur later than raw same-frame stages.'
    write_json(out/'landscape-raw-count-analysis.json', report)
    summary = {key: value for key, value in report.items() if key != 'modes'}
    summary['modes'] = [row['summary'] for row in report['modes']]
    write_json(out/'summary.json', summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 2 if not report['evidence_passed'] else (0 if report['overall_passed'] else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--helpers', type=Path, required=True, help='Checkout tools/verification/drift directory')
    parser.add_argument('--control', choices=('raw-count',), required=True)
    parser.add_argument('--prior-count-samples', type=Path, required=True, help='All 906 prior local-count postopaque-world-samples.json coordinates; exact checks, no tolerance')
    args = parser.parse_args()
    run, out, helpers = args.run.resolve(), args.out.resolve(), args.helpers.resolve()
    need(out != run and not out.is_relative_to(run), 'Output must be outside read-only source run')
    out.mkdir(parents=True, exist_ok=False)
    try:
        return analyze(run, out, helpers, args.prior_count_samples.resolve(), args.control)
    except (ValueError, KeyError, TypeError, OSError) as error:
        result = {'evidence_passed': False, 'overall_passed': False, 'failures': [str(error)], 'run': str(run)}
        write_json(out/'analysis-failure.json', result)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
