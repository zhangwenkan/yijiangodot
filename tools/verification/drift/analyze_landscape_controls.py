"""CPU-only strict analysis of three landscape-control conditions; never runs Godot.

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


def material_review(run, control, variant='unshaded'):
    landscape = control['landscape_control']
    need(landscape.get('control_variant', 'unshaded') == variant, 'Explicit control variant differs from GPU diagnostic')
    condition = 'landscape-'+variant
    state_checks = ('after-original', 'before-'+condition, 'after-'+condition, 'before-restored', 'after-restored')
    matches = [item for item in landscape['identification'] if item.get('matched') is True]
    need(len(matches) == 1, 'Expected one identified landscape')
    need(matches[0]['material_id'] == landscape['target_material_id'], 'Landscape target ID mismatch')
    checks = landscape['state_checks']
    need(Counter(item['label'] for item in checks) == Counter(state_checks), 'Incomplete/duplicate material state checks')
    need(all(item.get('passed') is True for item in checks), 'Runtime material state check failed')
    before_path, restored_path = run/'landscape-materials-before.json', run/'landscape-materials-restored.json'
    before, restored = read_json(before_path), read_json(restored_path)
    need(isinstance(before, list) and before, 'Missing material records')
    need(len({row['material_id'] for row in before}) == len(before), 'Duplicate material records')
    need(before == restored, 'Before/restored material snapshots differ semantically')
    need(before_path.read_bytes() == restored_path.read_bytes(), 'Before/restored material JSON bytes differ')
    need(len(before) == landscape['material_count'] and len(before)-1 == landscape['other_material_count'], 'Material count mismatch')
    need(all(item['material_count'] == len(before) and item['target_material_id'] == landscape['target_material_id']
             and item['target_unshaded'] == (variant == 'unshaded' and condition in item['label'])
             and (variant == 'unshaded' or item.get('target_control_active') == (condition in item['label']))
             for item in checks), 'Runtime material check metadata mismatch')
    target = [row for row in before if row['material_id'] == landscape['target_material_id']]
    need(len(target) == 1, 'Target material missing from snapshots')
    need(target[0]['resource_name'] == 'OriginalLandscape_Compiled_youxian', 'Wrong target material name')
    original = (run/'landscape-runtime-original.gdshader').read_bytes()
    installed = (run/('landscape-runtime-'+variant+'.gdshader')).read_bytes()
    source = original.decode('utf-8')
    declarations = list(re.finditer(r'(?m)^render_mode\s+[^;]+;', source))
    need(len(declarations) == 1 and not re.search(r'\bunshaded\b', declarations[0][0]), 'Unexpected original render_mode')
    if variant == 'unshaded':
        offset = declarations[0].end()-1
        expected = source[:offset]+', unshaded'+source[offset:]
        need(landscape.get('source_shader_preserved_except_render_mode') is True, 'Runtime inverse render_mode edit validation absent')
    else:
        guard = 'if (nl > 0.0 && ROUGHNESS > 0.0) {'
        disabled = 'if (false && nl > 0.0 && ROUGHNESS > 0.0) {'
        addition = 'SPECULAR_LIGHT += radiance * distribution * visibility * fresnel * nl * SPECULAR_AMOUNT;'
        need(source.count(guard) == 1 and source.count(addition) == 1, 'Expected exactly one expanded direct-specular guard/addition')
        need(landscape.get('specular_guard_original') == guard and landscape.get('specular_guard_installed') == disabled, 'Specular guard metadata mismatch')
        need(landscape.get('source_shader_preserved_except_specular_guard') is True, 'Runtime inverse specular edit validation absent')
        expected = source.replace(guard, disabled)
    need(expected.encode('utf-8') == installed, 'Shader changed beyond the single permitted control edit')
    need(digest(original) == landscape['original_shader_sha256'] == target[0]['shader_sha256'], 'Original shader hash mismatch')
    need(digest(installed) == landscape['installed_shader_sha256'], 'Installed shader hash mismatch')
    return {'passed': True, 'material_count': len(before), 'other_material_count': len(before)-1,
            'target': matches[0], 'target_uniform_count': len(target[0]['parameters']),
            'all_material_snapshot_bytes_exact': True, 'all_material_snapshot_values_exact': True,
            'snapshot_sha256': digest(before_path.read_bytes()), 'state_checks': checks,
            'original_shader_sha256': digest(original), 'installed_shader_sha256': digest(installed),
            'scope': 'CPU-visible geometry references, material shader/parameters and stored properties; not hidden RenderingServer/GPU uniform state.'}


def analyze(run, out, helpers, variant='unshaded'):
    modes = ('original', 'landscape-'+variant, 'restored')
    sys.path.insert(0, str(helpers))
    from analyze_distortion_drift import stats, changed, save_diff
    from analyze_shadow_controls import unproject
    from analyze_upstream_drift import ubo_diff
    control, runner = read_json(run/'receiver.json'), read_json(run/'runner.json')
    need(runner.get('capture_passed') is True and runner.get('exit') == 0, 'GPU capture runner did not complete successfully')
    need(control.get('stage') == 'complete' and control.get('failures') == [], 'GPU diagnostic incomplete/failed')
    labels = [f'{mode}-{index:02d}' for mode in modes for index in range(4)]
    need(Counter(row['label'] for row in control['captures']) == Counter(labels), 'Missing/duplicate/unexpected capture report labels')
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
    report['evidence_passed'] = True
    report['all_48_full_ubos_exact_across_conditions'] = len(all_ubos) == 48 and len(set(all_ubos)) == 1
    upstream_ubos = [row['ubo_sha256'][stage] for mode in report['modes'] for row in mode['captures'] for stage in STAGES]
    distortion_ubos = [row['ubo_sha256']['distortion'] for mode in report['modes'] for row in mode['captures']]
    report['all_36_upstream_ubos_exact_across_conditions'] = len(upstream_ubos) == 36 and len(set(upstream_ubos)) == 1
    report['all_12_distortion_ubos_exact_across_conditions'] = len(distortion_ubos) == 12 and len(set(distortion_ubos)) == 1
    report['ubo_stage_scope'] = 'Upstream and distortion UBOs are separate stage inputs. Their individual stability does not imply that all 48 buffers are equal to one another.'
    report['all_36_depths_exact_across_conditions'] = len(all_depths) == 36 and len(set(all_depths)) == 1
    report['all_12_accumulations_exact_across_conditions'] = len(all_accumulations) == 12 and len(set(all_accumulations)) == 1
    report['all_conditions_frozen_exact'] = all(row['summary']['all_fields_exact'] and row['summary']['all_ubos_exact'] for row in report['modes'])
    report['overall_passed'] = report['evidence_passed'] and report['all_conditions_frozen_exact']
    report['boundary'] = 'Evidence completion is distinct from frozen equality. A stable temporary shader control only localizes the changed path; it is not a production fix or UE fidelity proof. Final PNGs occur later than raw same-frame stages.'
    write_json(out/'landscape-controls-analysis.json', report)
    summary = {key: value for key, value in report.items() if key != 'modes'}
    summary['modes'] = [row['summary'] for row in report['modes']]
    write_json(out/'summary.json', summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if report['overall_passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--helpers', type=Path, required=True, help='Checkout tools/verification/drift directory')
    parser.add_argument('--control', choices=('unshaded', 'no-direct-specular'), default='unshaded', help='Explicit expected GPU control; default preserves historical unshaded analysis')
    args = parser.parse_args()
    run, out, helpers = args.run.resolve(), args.out.resolve(), args.helpers.resolve()
    need(out != run and not out.is_relative_to(run), 'Output must be outside read-only source run')
    out.mkdir(parents=True, exist_ok=False)
    try:
        return analyze(run, out, helpers, args.control)
    except (ValueError, KeyError, TypeError, OSError) as error:
        result = {'evidence_passed': False, 'overall_passed': False, 'failures': [str(error)], 'run': str(run)}
        write_json(out/'analysis-failure.json', result)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
