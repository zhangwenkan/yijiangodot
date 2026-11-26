"""Check every HDR capture and bounded, naturally advancing visible samples.

Empty observation candidates are retained and checked. Selected samples must be
nonempty. Passing does not assert visible particles on every frame or UE parity.
"""
from pathlib import Path
import argparse
import json
import numpy as np
from source_separate_readback import analyze

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path)
args = parser.parse_args()
folder = args.directory.resolve()
runtime = json.loads((folder/'integration-validation.json').read_text(encoding='utf-8-sig'))
run_path = folder/'run-result.json'
run = json.loads(run_path.read_text(encoding='utf-8-sig')) if run_path.exists() else {}
numeric, metadata, errors = [], {}, []
for path in sorted(folder.glob('*/capture.json')):
    try:
        metadata[path.parent.name] = json.loads(path.read_text(encoding='utf-8-sig'))
        numeric.append(analyze(path.parent))
    except Exception as exc:
        errors.append({'capture': path.parent.name, 'error': str(exc)})
by_name = {Path(row['capture']).name: row for row in numeric}
sampling = runtime.get('visibility_sampling')
observations = runtime.get('visibility_observations', {})
bounded = sampling is not None


def selected(label):
    return observations.get(label, {}).get('selected_capture', '') if bounded else label


def coverage(name):
    return by_name.get(name, {}).get('layer_active_pixels', 0)


def valid_source_snapshot(items, expected):
    names = [item.get('source') for item in items]
    return len(items) == expected and all(isinstance(name, str) and name for name in names) and len(set(names)) == expected


observation_results = []
for label, observation in observations.items():
    failures = []
    attempts = observation.get('attempts', [])
    names = [attempt.get('capture') for attempt in attempts]
    if not 1 <= len(attempts) <= int((sampling or {}).get('max_attempts', 0)):
        failures.append('candidate count outside declared bound')
    if observation.get('status') != 'visible' or not names or selected(label) != names[-1]:
        failures.append('no final selected visible candidate')
    previous = None
    for index, attempt in enumerate(attempts):
        name = attempt.get('capture', '')
        meta, row = metadata.get(name, {}), by_name.get(name, {})
        if name != f'{label}-candidate-{index+1:02d}' or attempt.get('attempt') != index+1:
            failures.append(f'{name}: incomplete candidate sequence')
        if not meta or not row:
            failures.append(f'{name}: missing HDR candidate')
            continue
        measured = row['layer_active_pixels']
        if attempt.get('coverage') != measured or meta.get('observed_layer_active_pixels') != measured:
            failures.append(f'{name}: runtime coverage differs from CPU')
        if meta.get('camera_transform') != observation.get('camera_transform'):
            failures.append(f'{name}: camera changed during observation')
        expected_emitters = 1 if '-youxian-' in name else 2
        if not all(valid_source_snapshot(meta.get(key, []), expected_emitters)
                   for key in ('request_source_simulation', 'readback_source_simulation')):
            failures.append(f'{name}: source snapshots missing, empty or not unique')
        if attempt.get('readback_process_frame') != meta.get('readback_process_frame'):
            failures.append(f'{name}: inconsistent frame record')
        if previous is not None and meta.get('request_process_frame', -1)-previous.get('readback_process_frame', 0) < int(sampling['retry_frames']):
            failures.append(f'{name}: retry interval too short')
        if index < len(attempts)-1 and measured != 0:
            failures.append(f'{name}: skipped already visible candidate')
        previous = meta
    if coverage(selected(label)) <= 0:
        failures.append('selected candidate has no source coverage')
    observation_results.append({'label': label, 'selected_capture': selected(label), 'attempts': attempts,
                                'elapsed_ms': observation.get('elapsed_ms'), 'errors': failures, 'passed': not failures})

dynamic, hidden, restored, expected_observations = [], [], [], set()
for entry in runtime.get('maps', []):
    prefix = f"{entry['index']}-{entry['map']}"
    names = [selected(prefix+'-'+phase) for phase in ('dynamic-first', 'dynamic-second')]
    pair, pair_errors = [], []
    for name in names:
        try:
            meta = metadata[name]
            pair.append(np.fromfile(folder/name/'layer_rgba16f.bin', dtype='<f2').reshape(meta['height'], meta['width'], 4))
        except Exception as exc:
            pair_errors.append(str(exc))
    changed = 0
    if len(pair) == 2:
        if pair[0].shape != pair[1].shape:
            pair_errors.append('dynamic dimensions differ')
        else:
            changed = int(np.any(pair[0] != pair[1], axis=2).sum())
    first, second = (metadata.get(name, {}) for name in names)
    times1 = {item['source']: item['time'] for item in first.get('readback_source_simulation', [])}
    times2 = {item['source']: item['time'] for item in second.get('readback_source_simulation', [])}
    advanced = bool(times1) and times1.keys() == times2.keys() and all(times2[k] > v for k, v in times1.items())
    dynamic.append({'map': entry['map'], 'index': entry['index'], 'first_capture': names[0], 'second_capture': names[1],
                    'changed_layer_pixels': changed, 'source_buffer_changed': entry.get('dynamic_buffers_changed', False),
                    'first_coverage': coverage(names[0]), 'second_coverage': coverage(names[1]),
                    'camera_unchanged': bool(first) and first.get('camera_transform') == second.get('camera_transform'),
                    'frame_gap': second.get('request_process_frame', -1)-first.get('readback_process_frame', 0),
                    'source_time_advanced': advanced, 'errors': pair_errors})
    hidden.append(by_name.get(prefix+'-source-parent-hidden', {}))
    restored.append(by_name.get(selected(prefix+'-source-parent-restored'), {}))
    expected_observations.update(prefix+'-'+phase for phase in ('dynamic-first', 'dynamic-second', 'source-parent-restored', 'dof-disabled', 'dof-reenabled'))

expected_error = 'ERROR: Source HDR DOF: intentional integration diagnostic'
unexpected_errors = [line for line in run.get('errors', []) if line.strip() != expected_error]
expected_errors = [line for line in run.get('errors', []) if line.strip() == expected_error]
checks = {
    'runtime_complete_without_failures': runtime.get('stage') == 'completed' and runtime.get('failures') == [],
    'process_exit_zero': run.get('exit') == 0,
    'no_unexpected_engine_errors': not unexpected_errors,
    'expected_dof_failure_was_exercised': len(expected_errors) == 1,
    'three_map_visits': [(r['map'], r['index']) for r in dynamic] == [('wuming', 0), ('youxian', 1), ('wuming', 2)],
    'all_hdr_numeric_checks': bool(numeric) and not errors and all(r['passed'] for r in numeric),
    'every_capture_registered_and_analyzed': len(runtime.get('captures', [])) == len(by_name) and set(runtime.get('captures', [])) == set(by_name),
    'source_particle_animation_advanced': bool(dynamic) and all(not r['errors'] and r['source_buffer_changed'] and r['changed_layer_pixels'] > 0 for r in dynamic),
    'all_dynamic_views_have_source_coverage': bool(dynamic) and all(r['first_coverage'] > 0 and r['second_coverage'] > 0 for r in dynamic),
    'hidden_source_parents_have_no_layer_pixels': len(hidden) == 3 and all(r.get('layer_active_pixels') == 0 and r.get('groups') == 0 for r in hidden),
    'restored_source_parents_have_layer_pixels': len(restored) == 3 and all(r.get('layer_active_pixels', 0) > 0 and r.get('groups', 0) > 0 for r in restored),
}
if bounded:
    checks['bounded_observation_contract'] = (sampling.get('max_attempts') == 6 and sampling.get('retry_frames') == 30
                                              and sampling.get('dynamic_gap_frames') == 45 and set(observations) == expected_observations
                                              and all(row['passed'] for row in observation_results))
    checks['dynamic_camera_and_simulation_interval'] = all(r['camera_unchanged'] and r['frame_gap'] >= 45 and r['source_time_advanced'] for r in dynamic)
    checks['temporary_dof_disable_preserved_ownership'] = len(runtime.get('maps', [])) == 3 and all(
        entry.get('temporary_dof_toggle', {}).get('passed') is True for entry in runtime.get('maps', []))
    checks['explicit_dof_restore_and_reinstall'] = len(runtime.get('maps', [])) == 3 and runtime['maps'][2].get('explicit_dof_restore', {}).get('passed') is True
loaded_shaders = {f"{entry['index']}-{entry['map']}": entry.get('effect', {}).get('shader_source_sha256', {}) for entry in runtime.get('maps', [])}
checks['loaded_glsl_matches_run_start_hashes'] = bool(loaded_shaders) and all(
    len(hashes) == 3 and all(value == runtime.get('input_sha256', {}).get(name) for name, value in hashes.items()) for hashes in loaded_shaders.values())
result = {'scope': __doc__, 'checks': checks, 'passed': all(checks.values()), 'dynamic': dynamic,
          'visibility_sampling': sampling, 'observations': observation_results, 'analysis_errors': errors,
          'runtime_failures': runtime.get('failures', []), 'unexpected_engine_errors': unexpected_errors,
          'expected_engine_errors': expected_errors, 'engine_warnings': run.get('warnings', []),
          'loaded_shaders': loaded_shaders, 'numeric': numeric,
          'limits': ['Conditional visible samples after bounded observation; not visible particles on every frame.',
                     'Default reconstructed scenes; no original UE frame-equivalence claim.',
                     'Failure checks attributes/metadata/compositor/node state; no server visibility getter exists.',
                     'RGB composite preserves base alpha; original UE alpha semantics remain outside scope.',
                     'Source order supported by cooked assets and UE4.26 comparison; live original GPU order uncaptured.']}
(folder/'integration-analysis.json').write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
print(json.dumps({'passed': result['passed'], 'checks': checks, 'dynamic': dynamic,
                  'observation_errors': [row for row in observation_results if not row['passed']],
                  'analysis_errors': errors, 'unexpected_engine_errors': unexpected_errors}, indent=2, ensure_ascii=False))
raise SystemExit(0 if result['passed'] else 1)
