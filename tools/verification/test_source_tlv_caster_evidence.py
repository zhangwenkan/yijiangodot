"""CPU-only observer-evidence rejection checks; no Godot or checkout writes."""
from pathlib import Path
import copy
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import numpy as np


def main():
    analyzer = Path(__file__).resolve().with_name('analyze_source_tlv_caster.py')
    results = []
    with tempfile.TemporaryDirectory(prefix='source-tlv-caster-evidence-') as temporary:
        root = Path(temporary)
        run = root / 'captures'
        run.mkdir()
        modes = ['disabled', 'enabled', 'enabled-repeat', 'enabled-repeat2', 'enabled-repeat3']
        labels = [f'cascade{c}-{mode}' for c in range(2) for mode in modes]
        hdr = np.zeros((512, 512, 4), dtype='<f2')
        hdr[:, :, 2] = 1
        for label in labels:
            hdr.tofile(run / (label + '.rgba16f'))
        raw = bytearray(5696)
        struct.pack_into('<4f', raw, 2816, 42.0, 0.0, 0.0, 0.0)
        struct.pack_into('<4f', raw, 5664, 42.0, 0.0, 0.0, 0.0)
        (run / 'scene.bin').write_bytes(raw)
        reference = {'file': 'scene.bin', 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
        data = {'size': len(raw), 'scene_ubo': reference, 'time': 1.0, 'taa_frame_count': 1.0}
        base = {'stage': 'complete', 'failures': [], 'enabled_captures_per_cascade': 4,
                'probe_captures': [{'label': label, 'view_ubo': {name: copy.deepcopy(data) for name in
                    ('main-before', 'main-after', 'probe-before', 'probe-after')}} for label in labels]}
        cases = [('valid-legacy-metadata', None, None),
                 ('missing-capture', 'missing-capture', 'Expected one observer capture'),
                 ('missing-stage', 'missing-stage', 'Missing observer stage'),
                 ('duplicate-capture', 'duplicate-capture', 'Expected one observer capture'),
                 ('unexpected-capture', 'unexpected-capture', 'Unexpected observer capture'),
                 ('unexpected-stage', 'unexpected-stage', 'Unexpected observer stage'),
                 ('duplicate-stage-key', 'duplicate-stage-key', 'Duplicate JSON evidence key'),
                 ('nan-current-jitter', 2828, 'Nonfinite view UBO clock/jitter'),
                 ('nan-previous-jitter', 5672, 'Nonfinite view UBO clock/jitter'),
                 ('legacy-no-observers', 'legacy', 'Unsupported legacy caster evidence'),
                 ('wrong-repeat-count', 'repeat-count', 'Unsupported caster evidence')]
        for name, mutation, expected_failure in cases:
            source = copy.deepcopy(base)
            captures = source['probe_captures']
            if mutation == 'missing-capture':
                captures.pop()
            elif mutation == 'missing-stage':
                del captures[0]['view_ubo']['main-before']
            elif mutation == 'duplicate-capture':
                captures.append(copy.deepcopy(captures[0]))
            elif mutation == 'unexpected-capture':
                extra = copy.deepcopy(captures[0]); extra['label'] = 'unexpected'
                captures.append(extra)
            elif mutation == 'unexpected-stage':
                captures[0]['view_ubo']['extra'] = copy.deepcopy(data)
            elif isinstance(mutation, int):
                invalid_raw = bytearray(raw)
                struct.pack_into('<f', invalid_raw, mutation, float('nan'))
                (run / 'nonfinite.bin').write_bytes(invalid_raw)
                captures[0]['view_ubo']['main-before']['scene_ubo'] = {
                    'file': 'nonfinite.bin', 'bytes': len(invalid_raw),
                    'sha256': hashlib.sha256(invalid_raw).hexdigest()}
            elif mutation == 'legacy':
                del source['probe_captures']
            elif mutation == 'repeat-count':
                source['enabled_captures_per_cascade'] = 2
            text = json.dumps(source)
            if mutation == 'duplicate-stage-key':
                text = text.replace('"main-before": ', '"main-before": {}, "main-before": ', 1)
            (run / 'caster-camera.json').write_text(text, encoding='utf-8')
            output = root / (name + '.json')
            process = subprocess.run([sys.executable, '-B', '-X', 'utf8', str(analyzer), str(run),
                                      '--analysis-output', str(output)], capture_output=True, text=True,
                                     encoding='utf-8', timeout=60)
            assert output.is_file(), (name, process.returncode, process.stderr)
            result = json.loads(output.read_text(encoding='utf-8'))
            if expected_failure is None:
                assert process.returncode == 0 and result['status'] == 'passed', (name, result['failures'])
                assert len(result['view_ubo']) == 40 and len(result['ubo_metadata_corrections']) == 40
                assert all(row['time'] == 42.0 for row in result['view_ubo'])
            else:
                assert process.returncode == 1 and result['status'] == 'failed', (name, result['failures'])
                assert any(expected_failure in failure for failure in result['failures']), (name, result['failures'])
            results.append({'case': name, 'exit': process.returncode, 'status': result['status'],
                            'ubo_rows': len(result['view_ubo']), 'failures': result['failures']})
    print(json.dumps({'passed': True, 'cases': results}, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
