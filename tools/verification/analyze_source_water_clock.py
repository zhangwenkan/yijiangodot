"""Independent CPU review of saved water-clock captures; no GPU or source edits.

Requires numpy and Pillow. --run is read-only; --out must be a fresh directory.
Preserves the previous distortion verifier's three UV arithmetic variants and
unchanged 8-bit subtexel plus half-ULP bound, including every edge failure.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import numpy as np
from PIL import Image


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def referenced_bytes(folder, metadata, key):
    reference = metadata[key]
    path = (folder / reference['file']).resolve()
    if not path.is_relative_to(folder.resolve()):
        raise ValueError('Capture reference escaped its folder: ' + key)
    data = path.read_bytes()
    if len(data) != reference['bytes']:
        raise ValueError('Capture byte count differs from metadata: ' + key)
    return data


def f32_metadata_exact(value, expected):
    try:
        return struct.pack('<f', value) == struct.pack('<f', expected)
    except (OverflowError, TypeError, struct.error):
        return False


def apply_oracle(before, accumulation, after, mode, output):
    """Equations/bound match the retained verify_readback.py without widening."""
    h, w = before.shape[:2]
    y, x = np.mgrid[:h, :w]
    if mode == 'float64':
        dx = (accumulation[:, :, 0].astype(float) - accumulation[:, :, 2]) / 255 * .25
        dy = (accumulation[:, :, 1].astype(float) - accumulation[:, :, 3]) / 255 * .25
        sx, sy = x + dx * w, y + dy * h
        valid = (sx >= 0) & (sx <= w - 1) & (sy >= 0) & (sy <= h - 1)
        sx, sy = np.where(valid, sx, x), np.where(valid, sy, y)
    else:
        f = np.float32
        size = np.array([w, h], dtype='f4')
        inv = f(1) / size
        pixel = np.stack([x, y], axis=-1).astype('f4')
        uv = (pixel + f(.5)) * inv if mode == 'float32-recip' else (pixel + f(.5)) / size
        aq = accumulation.astype('f4') * f(1 / 255)
        off = (aq[:, :, :2] - aq[:, :, 2:]) * f(.25)
        sample = uv + off
        lower, upper = f(.5) * inv, f(1) - f(.5) * inv
        valid = np.all((sample >= lower) & (sample <= upper), axis=2)
        sample = np.where(valid[..., None], sample, uv)
        coords = sample * size - f(.5)
        sx = np.clip(coords[:, :, 0], 0, w - 1).astype(float)
        sy = np.clip(coords[:, :, 1], 0, h - 1).astype(float)
    x0, y0 = np.floor(sx).astype(int), np.floor(sy).astype(int)
    x1, y1 = np.minimum(x0 + 1, w - 1), np.minimum(y0 + 1, h - 1)
    fx, fy = (sx - x0)[..., None], (sy - y0)[..., None]
    a, b, c, d = before[y0, x0], before[y0, x1], before[y1, x0], before[y1, x1]
    ideal = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    expected = ideal.astype(np.float16).astype(float)
    mask = np.any(accumulation != 0, axis=2)
    expected[~mask] = before[~mask]
    error = np.abs(after - expected)
    du = np.maximum(np.abs(a - b), np.abs(c - d))
    dv = np.maximum(np.abs(a - c), np.abs(b - d))
    half = expected.astype(np.float16)
    ulp = np.abs(np.nextafter(half, np.float16(np.inf)).astype(float) - expected)
    bound = (du + dv) / 256 + ulp + 2e-6
    exceed = error > bound
    border = (x == 0) | (x == w - 1) | (y == 0) | (y == h - 1)
    coordinates = np.argwhere(exceed)
    if len(coordinates):
        np.savez_compressed(output, yxc=coordinates, gpu=after[exceed], expected=expected[exceed],
                            original=before[exceed], error=error[exceed], bound=bound[exceed],
                            accumulation=accumulation[coordinates[:, 0], coordinates[:, 1]],
                            border=border[coordinates[:, 0], coordinates[:, 1]])
    outside_exact = bool(np.array_equal(before[~mask], after[~mask]))
    finite = bool(np.isfinite(before).all() and np.isfinite(after).all())
    report = {'uv_math': mode, 'accumulator_nonzero_pixels': int(mask.sum()),
              'actual_changed_pixels': int(np.any(before != after, axis=2).sum()),
              'oob_restored_pixels': int((mask & ~valid).sum()), 'outside_accumulator_exact': outside_exact,
              'max_error_ideal_bilinear': float(error.max()), 'p99_error_ideal_bilinear': float(np.quantile(error, .99)),
              'component_errors_beyond_8bit_subtexel_bound': int(exceed.sum()),
              'interior_component_errors_beyond_same_bound': int((exceed & ~border[..., None]).sum()),
              'border_component_errors_beyond_same_bound': int((exceed & border[..., None]).sum()),
              'all_finite': finite, 'passed': finite and outside_exact and not bool(exceed.any()),
              'failures_npz': output.name if len(coordinates) else None,
              'border_failures': [
                  {'x': int(xx), 'y': int(yy), 'channel': int(channel),
                   'accumulator_rgba8': accumulation[yy, xx].tolist(), 'gpu': float(after[yy, xx, channel]),
                   'ideal': float(expected[yy, xx, channel]), 'original': float(before[yy, xx, channel]),
                   'gpu_restored_original': bool(after[yy, xx, channel] == before[yy, xx, channel]),
                   'same_numeric_bound': float(bound[yy, xx, channel])}
                  for yy, xx, channel in np.argwhere(exceed & border[..., None])]}
    return report


def analyze_capture(folder, output, metadata_row):
    metadata = read_json(folder / 'capture.json')
    h, w = metadata['height'], metadata['width']
    raw = {key: referenced_bytes(folder, metadata, key) for key in
           ('scene_ubo_full', 'scene_time_ubo', 'water_frame_rgba32f', 'before_rgba16f',
            'after_rgba16f', 'accumulation_rgba8', 'instances_rgba32f')}
    if len(raw['scene_ubo_full']) != 5696:
        raise ValueError('Unsupported full scene UBO layout')
    full = raw['scene_ubo_full']
    clock = struct.unpack_from('<4f', full, 2816)
    water_frame = np.frombuffer(raw['water_frame_rgba32f'], dtype='<f4')
    if len(raw['before_rgba16f']) != h * w * 8 or len(raw['after_rgba16f']) != h * w * 8 or len(raw['accumulation_rgba8']) != h * w * 4:
        raise ValueError('Image raw length mismatch')
    before = np.frombuffer(raw['before_rgba16f'], dtype='<f2').reshape(h, w, 4).astype(np.float64)
    after = np.frombuffer(raw['after_rgba16f'], dtype='<f2').reshape(h, w, 4).astype(np.float64)
    accumulation = np.frombuffer(raw['accumulation_rgba8'], dtype=np.uint8).reshape(h, w, 4)
    mask = np.any(accumulation != 0, axis=2)
    checks = {
        'metadata_layout_and_offset': metadata.get('scene_ubo_layout') == 'godot-4.7.2-float-2848x2' and metadata.get('scene_time_offset') == 2816 and metadata.get('scene_ubo_size') == 5696,
        'clock_slice_exact': raw['scene_time_ubo'] == full[2816:2832],
        'time_metadata_f32_exact': f32_metadata_exact(metadata.get('scene_shader_time'), clock[0]),
        'taa_metadata_f32_exact': f32_metadata_exact(metadata.get('scene_taa_frame_count'), clock[1]),
        'report_time_f32_exact': f32_metadata_exact(metadata_row.get('scene_shader_time'), clock[0]),
        'clock_finite': all(math.isfinite(value) for value in clock),
        'water_active': metadata.get('water_active') is True,
        'water_uniform_set_valid': metadata.get('water_uniform_set_valid') is True,
        'water_frame_432_bytes': len(raw['water_frame_rgba32f']) == 432,
        'water_frame_finite': bool(np.isfinite(water_frame).all()),
        'reported_water_frame_sha_exact': metadata_row.get('water_frame_sha256') == sha(raw['water_frame_rgba32f']),
        'hdr_finite': bool(np.isfinite(before).all() and np.isfinite(after).all()),
        'zero_accumulator_raw_exact': bool(np.array_equal(np.frombuffer(raw['before_rgba16f'], dtype='<u2').reshape(h, w, 4)[~mask], np.frombuffer(raw['after_rgba16f'], dtype='<u2').reshape(h, w, 4)[~mask])),
        'reported_nonzero_pixels_exact': metadata.get('nonzero_accumulation_pixels') == int(mask.sum()),
        'audit_mode_normal': metadata.get('audit_mode') == 0,
    }
    if 'water-only' in folder.name:
        checks['water_only_particles_zero'] = metadata.get('particle_count') == 0 and not raw['instances_rgba32f']
    result = {'capture': folder.name, 'width': w, 'height': h, 'checks': checks,
              'raw_evidence_passed': all(checks.values()), 'time': clock[0], 'taa_frame_count': clock[1], 'taa_jitter': list(clock[2:]),
              'exposure_at_old_time_offset': struct.unpack_from('<f', full, 2832)[0],
              'particle_count': metadata.get('particle_count'), 'water_active': metadata.get('water_active'),
              'water_frame_sha256': sha(raw['water_frame_rgba32f']),
              'input_sha256': {key: sha(value) for key, value in raw.items()},
              'accumulator_nonzero_pixels': int(mask.sum()), 'actual_changed_pixels': int(np.any(before != after, axis=2).sum()),
              'oracle_variants': []}
    for mode in ('float64', 'float32-div', 'float32-recip'):
        result['oracle_variants'].append(apply_oracle(before, accumulation, after, mode, output / (folder.name + '-' + mode + '-failures.npz')))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    run, output = args.run.resolve(), args.out.resolve()
    if output == run or output.is_relative_to(run):
        parser.error('--out must be outside the read-only run directory')
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error(str(error))
    source = read_json(run / 'water-distortion-validation.json')
    result = {'schema': 1, 'run': str(run), 'source_report_sha256': sha((run / 'water-distortion-validation.json').read_bytes()),
              'source_runtime_failures': source.get('failures', ['Missing runtime failure list']),
              'captures': [], 'maps': [], 'failures': [],
              'numeric_method': {'origin': 'particles-dynamic/distortion-candidate/verify_readback.py',
                                 'bound': '(du+dv)/256 + neighboring positive half-float ULP + 2e-6',
                                 'threshold_changed': False,
                                 'uv_modes': ['float64', 'float32-div', 'float32-recip'],
                                 'scope': 'Native RGBA8 offset decode and bilinear apply. float32-recip is a possible compiler lowering, not exact GPU reciprocal emulation; every failure remains listed.'}}
    map_rows = {row['map']: row for row in source.get('maps', [])}
    for slug in ('wuming', 'youxian'):
        if slug not in map_rows:
            result['failures'].append('Missing map ' + slug)
            continue
        row = map_rows[slug]
        for suffix, key in (('combined', 'combined'), ('water-only', 'water_only'), ('water-only-later', 'water_only_later')):
            label = slug + '-' + suffix
            try:
                capture = analyze_capture(run / label, output, row.get(key, {}))
                result['captures'].append(capture)
                write_json(output / (label + '-analysis.json'), capture)
                if not capture['raw_evidence_passed']:
                    result['failures'].append('Raw metadata/clock mismatch: ' + label)
            except (ValueError, KeyError, OSError) as error:
                result['failures'].append(label + ': ' + str(error))
        first_folder, later_folder = run / (slug + '-water-only'), run / (slug + '-water-only-later')
        first = next((c for c in result['captures'] if c['capture'] == first_folder.name), None)
        later = next((c for c in result['captures'] if c['capture'] == later_folder.name), None)
        if first is None or later is None:
            continue
        first_acc = np.fromfile(first_folder / 'accumulation_rgba8.bin', dtype=np.uint8).reshape(first['height'], first['width'], 4)
        later_acc = np.fromfile(later_folder / 'accumulation_rgba8.bin', dtype=np.uint8).reshape(later['height'], later['width'], 4)
        changed = first_acc != later_acc
        baseline = np.asarray(Image.open(run / (slug + '-baseline-splash-only.png')).convert('RGBA'))
        restored = np.asarray(Image.open(run / (slug + '-restore-splash-only.png')).convert('RGBA'))
        frame_exact = (first_folder / 'water_frame_rgba32f.bin').read_bytes() == (later_folder / 'water_frame_rgba32f.bin').read_bytes()
        checks = {'time_increased': later['time'] > first['time'], 'water_frame_raw_exact': frame_exact,
                  'water_only_particles_zero': first['particle_count'] == later['particle_count'] == 0,
                  'both_water_active': first['water_active'] and later['water_active'],
                  'accumulation_changed': bool(changed.any()),
                  'reported_changed_bytes_exact': int(changed.sum()) == row.get('water_dynamic', {}).get('accumulation_changed_bytes'),
                  'frozen_restore_pixels_exact': bool(np.array_equal(baseline, restored))}
        result['maps'].append({'map': slug, 'checks': checks, 'raw_dynamic_passed': all(checks.values()),
                               'first_time': first['time'], 'later_time': later['time'], 'elapsed_scene_time': later['time'] - first['time'],
                               'accumulation_changed_bytes': int(changed.sum()), 'accumulation_changed_pixels': int(np.any(changed, axis=2).sum()),
                               'baseline_restore_png_sha256': [sha((run / (slug + suffix)).read_bytes()) for suffix in ('-baseline-splash-only.png', '-restore-splash-only.png')]})
        if not all(checks.values()):
            result['failures'].append('Dynamic or frozen-restoration raw checks failed: ' + slug)
    result['raw_clock_dynamic_passed'] = not result['failures'] and len(result['captures']) == 6 and len(result['maps']) == 2
    result['numeric_variants'] = {mode: {'passed': all(next(v for v in c['oracle_variants'] if v['uv_math'] == mode)['passed'] for c in result['captures']) and len(result['captures']) == 6,
                                      'beyond_bound_components': sum(next(v for v in c['oracle_variants'] if v['uv_math'] == mode)['component_errors_beyond_8bit_subtexel_bound'] for c in result['captures'])}
                                  for mode in ('float64', 'float32-div', 'float32-recip')}
    result['all_numeric_variants_passed'] = all(v['passed'] for v in result['numeric_variants'].values())
    result['overall_passed'] = result['raw_clock_dynamic_passed'] and result['all_numeric_variants_passed'] and not result['source_runtime_failures']
    result['boundary'] = ('This run can verify corrected real clock input, a dynamic response and restoration only within its captured scope. '
                          'Advancing TIME may also change opaque shader-driven depth. No causality isolation or original UE parity is asserted. '
                          'Prior Youxian frozen failures remain separate retained evidence; no thresholds or masks are relaxed.')
    write_json(output / 'water-clock-cpu-analysis.json', result)
    print(json.dumps({key: result[key] for key in ('raw_clock_dynamic_passed', 'numeric_variants', 'all_numeric_variants_passed', 'overall_passed', 'failures', 'maps')}, ensure_ascii=False, indent=2))
    return 0 if result['overall_passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
