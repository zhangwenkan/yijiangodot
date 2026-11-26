"""CPU verification of the HDR textures emitted by source separate-translucency tests.

Checks numerical compositing and restoration. It does not prove native-frame equality,
source particle randomness, correct visual occlusion or complete UE DOF reconstruction.
"""
from pathlib import Path
import argparse
import hashlib
import json
import numpy as np


def ordered_half(values):
    bits = values.view(np.uint16)
    return np.where((bits & 0x8000) != 0, (~bits) & 0xffff, bits | 0x8000).astype(np.int32)


def analyze(folder):
    meta = json.loads((folder / 'capture.json').read_text(encoding='utf-8-sig'))
    w, h = int(meta['width']), int(meta['height'])
    arrays = {}
    files = {}
    checks = []
    for key in ('before_rgba16f', 'layer_rgba16f', 'after_rgba16f'):
        path = folder / meta[key]['file']
        payload = path.read_bytes()
        if len(payload) != w * h * 8:
            raise ValueError(f'{path}: expected {w*h*8} bytes, got {len(payload)}')
        values = np.frombuffer(payload, dtype='<f2').reshape(h, w, 4)
        arrays[key] = values
        files[key] = {'file': path.name, 'sha256': hashlib.sha256(payload).hexdigest(),
                      'nonfinite': int(np.count_nonzero(~np.isfinite(values))),
                      'min': float(np.nanmin(values)), 'max': float(np.nanmax(values))}
        checks.append({'check': key + '_finite', 'passed': files[key]['nonfinite'] == 0})
    before, layer, after = (arrays[k] for k in ('before_rgba16f', 'layer_rgba16f', 'after_rgba16f'))
    alpha = layer[:, :, 3]
    untouched = np.all(layer == 0, axis=2)
    active = ~untouched
    exact_unchanged = np.all(before.view(np.uint16) == after.view(np.uint16), axis=2)
    changed = ~exact_unchanged
    source_alpha_equal = np.array_equal(before[:, :, 3].view(np.uint16), after[:, :, 3].view(np.uint16))
    checks += [
        {'check': 'layer_alpha_0_to_1', 'passed': bool(np.all((alpha >= 0) & (alpha <= 1)))},
        {'check': 'scene_alpha_bit_exact', 'passed': bool(source_alpha_equal)},
        {'check': 'zero_layer_pixels_bit_exact', 'passed': bool(np.all(exact_unchanged[untouched]))},
    ]
    # Double arithmetic models the expression before RGBA16F quantization. A GPU's
    # float32 multiply/add or FMA may cross a half-float midpoint by one half ULP.
    # This limit is fixed here; no image matching tolerance is relaxed by this script.
    with np.errstate(over='ignore', invalid='ignore'):
        reference = (layer[:, :, :3].astype(np.float64) + before[:, :, :3].astype(np.float64)
                     * (1.0 - alpha.astype(np.float64)[:, :, None])).astype(np.float16)
    reference_finite = bool(np.all(np.isfinite(reference)))
    # Infinity is adjacent to the largest finite half in the bit ordering. Reject
    # an overflowing oracle independently instead of accepting saturation as 1 ULP.
    checks.append({'check': 'alpha_over_reference_finite', 'passed': reference_finite})
    ulp = np.abs(ordered_half(reference) - ordered_half(after[:, :, :3]))
    checks.append({'check': 'alpha_over_within_1_half_ulp', 'passed': reference_finite and bool(np.all(ulp <= 1))})
    return {'capture': str(folder), 'size': [w, h], 'particles': meta.get('particles'),
            'groups': meta.get('groups'), 'files': files, 'checks': checks,
            'passed': all(c['passed'] for c in checks),
            'layer_active_pixels': int(np.count_nonzero(active)),
            'layer_alpha_positive_pixels': int(np.count_nonzero(alpha > 0)),
            'alpha_zero_rgb_nonzero_pixels': int(np.count_nonzero((alpha == 0) & np.any(layer[:, :, :3] != 0, axis=2))),
            'changed_scene_pixels': int(np.count_nonzero(changed)),
            'changed_outside_layer': int(np.count_nonzero(changed & untouched)),
            'max_composite_error_half_ulp': int(ulp.max()),
            'max_composite_error_abs': float(np.max(np.abs(reference.astype(np.float64) - after[:, :, :3].astype(np.float64))))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    folder = args.directory.resolve()
    captures = sorted(folder.glob('*/capture.json'))
    rows, errors = [], []
    for capture in captures:
        try:
            rows.append(analyze(capture.parent))
        except Exception as exc:
            errors.append({'capture': str(capture.parent), 'error': str(exc)})
    validation = folder / 'separate-validation.json'
    runtime_failures = []
    if not validation.is_file():
        runtime_failures.append('Missing separate-validation.json')
    else:
        try:
            runtime = json.loads(validation.read_text(encoding='utf-8-sig'))
            if not isinstance(runtime, dict):
                runtime_failures.append('separate-validation.json must contain an object')
            else:
                if runtime.get('stage') != 'completed':
                    runtime_failures.append('Runtime validation did not reach stage completed')
                if not isinstance(runtime.get('failures'), list):
                    runtime_failures.append('Runtime validation requires a failures list')
                else:
                    runtime_failures.extend(runtime['failures'])
        except (OSError, ValueError) as exc:
            runtime_failures.append(f'Cannot read runtime validation: {exc}')
    result = {'scope': __doc__, 'captures': rows, 'errors': errors,
              'runtime_failures': runtime_failures,
              'passed': bool(rows) and not errors and all(r['passed'] for r in rows) and not runtime_failures,
              'visual_scope': 'Nonzero coverage and alpha-over arithmetic do not certify source occlusion/sorting; review matched views separately.'}
    (folder / 'readback-analysis.json').write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps({'captures': len(rows), 'passed': result['passed'], 'errors': errors,
                      'rows': [{k:r[k] for k in ('capture','passed','layer_active_pixels','changed_scene_pixels','max_composite_error_half_ulp')} for r in rows]}, indent=2, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
