"""Analyze the bounded caster diagnostic only after the parent runs it on GPU."""
from pathlib import Path
from collections import Counter
import argparse
import hashlib
import json
import struct
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
parser.add_argument('--analysis-output', type=Path, help='Write analysis separately without modifying captured run')
args = parser.parse_args()
folder = args.output
duplicate_json_keys = []
def unique_json_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            duplicate_json_keys.append(key)
        value[key] = item
    return value

source = json.loads((folder / 'caster-camera.json').read_text(encoding='utf-8-sig'),
                    object_pairs_hook=unique_json_object)
failures = list(source.get('failures', []))
failures.extend('Duplicate JSON evidence key: ' + key for key in duplicate_json_keys)
if source.get('stage') != 'complete':
    failures.append('Engine diagnostic reported failed or incomplete')
repeat_count = 4
if source.get('enabled_captures_per_cascade') != repeat_count:
    failures.append('Unsupported caster evidence: expected four enabled captures per cascade')
modes = ['disabled', 'enabled', 'enabled-repeat'] + [f'enabled-repeat{i}' for i in range(2, repeat_count)]
expected = [f'cascade{c}-{mode}' for c in range(2) for mode in modes]
expected_views = {'main-before', 'main-after', 'probe-before', 'probe-after'}
probe_captures = source.get('probe_captures')
if not isinstance(probe_captures, list) or not probe_captures:
    failures.append('Unsupported legacy caster evidence: complete observer UBO records are required')
    probe_captures = []
valid_captures = []
for capture in probe_captures:
    if not isinstance(capture, dict) or not isinstance(capture.get('label'), str):
        failures.append('Invalid probe UBO capture record')
        continue
    valid_captures.append(capture)
counts = Counter(capture['label'] for capture in valid_captures)
for label in expected:
    if counts[label] != 1:
        failures.append(f'Expected one observer capture {label}, found {counts[label]}')
for label in sorted(set(counts) - set(expected)):
    failures.append('Unexpected observer capture: ' + label)
for capture in valid_captures:
    views = capture.get('view_ubo')
    if not isinstance(views, dict):
        failures.append('Missing observer stages: ' + capture['label'])
        continue
    for name in sorted(expected_views - set(views)):
        failures.append(f'Missing observer stage {capture["label"]} {name}')
    for name in sorted(set(views) - expected_views):
        failures.append(f'Unexpected observer stage {capture["label"]} {name}')
entries = {}
arrays = {}
for label in expected:
    file = folder / (label + '.rgba16f')
    if not file.exists():
        failures.append(f'Missing probe capture {label}')
        continue
    raw = np.fromfile(file, dtype='<f2')
    if raw.size != 512 * 512 * 4:
        failures.append(f'Invalid probe length {label}')
        continue
    data = raw.reshape(512, 512, 4).astype(np.float32)
    arrays[label] = data
    finite = bool(np.isfinite(data).all())
    light_present = int(np.count_nonzero(data[:, :, 2] > 0))
    if not finite:
        failures.append(f'Nonfinite HDR {label}')
    if light_present != 512 * 512:
        failures.append(f'Probe light-present channel missing at {label}')
    entries[label] = {'finite': finite, 'light_present_pixels': light_present,
                      'rgb_min': np.min(data[:, :, :3], axis=(0, 1)).tolist(),
                      'rgb_max': np.max(data[:, :, :3], axis=(0, 1)).tolist()}
comparisons = []
for cascade in range(2):
    labels = [f'cascade{cascade}-{mode}' for mode in ['disabled', 'enabled', 'enabled-repeat']]
    if any(label not in arrays for label in labels):
        continue
    disabled, enabled, repeat = [arrays[label] for label in labels]
    repeat_exact = bool(np.array_equal(enabled, repeat))
    if not repeat_exact:
        failures.append(f'Bound probe repeat differs at cascade {cascade}')
    delta = np.abs(enabled - disabled)
    comparisons.append({'cascade': cascade, 'enabled_repeat_exact': repeat_exact,
                        'disabled_enabled_max_by_channel': np.max(delta, axis=(0, 1)).tolist(),
                        'changed_shadow_samples': int(np.count_nonzero(delta[:, :, 0])),
                        'changed_light_function_samples': int(np.count_nonzero(delta[:, :, 1]))})
repeat_pairs = []
for cascade in range(2):
    ordered = [f'cascade{cascade}-{mode}' for mode in modes[1:]]
    for index in range(1, len(ordered)):
        for prior in sorted(set([0, index-1])):
            left, right = ordered[prior], ordered[index]
            if left not in arrays or right not in arrays:
                continue
            delta = np.abs(arrays[right]-arrays[left])
            exact = bool(np.array_equal(arrays[right], arrays[left]))
            repeat_pairs.append({'left': left, 'right': right, 'exact': exact,
                                 'changed_by_channel': [int(np.count_nonzero(delta[:, :, c])) for c in range(4)],
                                 'maximum_by_channel': np.max(delta, axis=(0, 1)).tolist()})
            if prior == 0 and not exact and index > 1:
                failures.append(f'Bound probe repeat {index} differs at cascade {cascade}')
clock_rows = []
metadata_corrections = []
for capture in valid_captures:
    views = capture.get('view_ubo')
    if not isinstance(views, dict):
        continue
    for name, data in views.items():
        if not isinstance(data, dict):
            failures.append(f'Invalid observer stage {capture["label"]} {name}')
            continue
        reference = data.get('scene_ubo', {})
        row = {'capture': capture['label'], 'view_stage': name,
               'recorded_time': data.get('time'), 'recorded_taa_frame_count': data.get('taa_frame_count'),
               'drawn_frame': data.get('drawn_frame'), 'size': data.get('size'),
               'sha256': reference.get('sha256')}
        filename = reference.get('file')
        raw_path = folder / filename if filename else None
        if raw_path is None or not raw_path.is_file():
            failures.append(f'Missing raw view UBO {capture["label"]} {name}')
            continue
        raw_ubo = raw_path.read_bytes()
        if len(raw_ubo) != 5696 or data.get('size') != 5696:
            failures.append(f'Unsupported view UBO layout {capture["label"]} {name}: {len(raw_ubo)} bytes')
            continue
        if hashlib.sha256(raw_ubo).hexdigest() != reference.get('sha256'):
            failures.append(f'View UBO hash mismatch {capture["label"]} {name}')
        row.update({'layout': 'godot-4.7.2-float-2848x2', 'time_offset': 2816, 'taa_frame_count_offset': 2820,
                    'time': struct.unpack_from('<f', raw_ubo, 2816)[0],
                    'taa_frame_count': struct.unpack_from('<f', raw_ubo, 2820)[0],
                    'taa_jitter': list(struct.unpack_from('<2f', raw_ubo, 2824)),
                    'previous_time': struct.unpack_from('<f', raw_ubo, 5664)[0],
                    'previous_taa_frame_count': struct.unpack_from('<f', raw_ubo, 5668)[0],
                    'previous_taa_jitter': list(struct.unpack_from('<2f', raw_ubo, 5672))})
        if row['recorded_time'] != row['time'] or row['recorded_taa_frame_count'] != row['taa_frame_count']:
            metadata_corrections.append({'capture': capture['label'], 'view_stage': name,
                                         'reason': 'Raw UBO decoded at verified offsets supersedes recorded clock metadata',
                                         'recorded_time': row['recorded_time'], 'corrected_time': row['time'],
                                         'recorded_taa_frame_count': row['recorded_taa_frame_count'],
                                         'corrected_taa_frame_count': row['taa_frame_count']})
        clock_values = [row[key] for key in ['time', 'taa_frame_count', 'previous_time', 'previous_taa_frame_count']]
        clock_values += row['taa_jitter'] + row['previous_taa_jitter']
        if not all(np.isfinite(value) for value in clock_values):
            failures.append(f'Nonfinite view UBO clock/jitter {capture["label"]} {name}')
        clock_rows.append(row)
for view in ['main', 'probe']:
    rows = [row for row in clock_rows if row['view_stage'].startswith(view+'-')]
    if rows:
        if len({row['time'] for row in rows}) != 1 or len({row['taa_frame_count'] for row in rows}) != 1:
            failures.append(f'Frozen time/taa changed in {view} UBO captures')
result = {'status': 'passed' if not failures else 'failed', 'failures': failures,
          'captures': entries, 'comparisons': comparisons, 'repeat_pairs': repeat_pairs, 'view_ubo': clock_rows,
          'ubo_metadata_corrections': metadata_corrections,
          'meaning': 'Finite source-scene probe with sun present; disabled vs enabled delta is observational. Zero delta does not disprove binding, and nonzero delta does not establish UE shadow parity.'}
destination = args.analysis_output or (folder / 'caster-camera-analysis.json')
destination.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2))
raise SystemExit(0 if not failures else 1)
