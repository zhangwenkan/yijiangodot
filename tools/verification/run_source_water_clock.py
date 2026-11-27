"""Bounded water-clock regression; preserve dynamic and overall outcomes separately.

Finds an installed checkout from this file's parents, or accepts --root for a
reviewed stage copy. Writes only a fresh report directory and runs the existing
verifier. It never deploys or edits production source, and reuses run_owned_tree.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding='utf-8')


def checkout_root(explicit):
    if explicit is not None:
        candidate = explicit.resolve()
        if not (candidate / 'project/project.godot').is_file():
            raise ValueError('Explicit --root has no project/project.godot')
        return candidate
    for candidate in Path(__file__).resolve().parents:
        if (candidate / 'project/project.godot').is_file():
            return candidate
    raise ValueError('Cannot find checkout from __file__; supply --root')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--out', type=Path, required=True, help='New output directory, relative to checkout if not absolute')
    parser.add_argument('--timeout', type=float, default=420)
    parser.add_argument('--godot', type=Path)
    args = parser.parse_args(argv)
    try:
        root = checkout_root(args.root)
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise ValueError('--timeout must be finite and positive')
        godot = (root / (args.godot or Path('tools/godot/Godot_v4.7.2-stable_win64_console.exe'))).resolve()
        owned = root / 'tools/verification/run_source_separate_translucency.py'
        verifier = root / 'project/scripts/verify_source_water_distortion.gd'
        for path in (godot, owned, verifier):
            if not path.is_file():
                raise ValueError(f'Missing required file: {path}')
        output = (root / args.out).resolve()
        if output.exists():
            raise ValueError(f'Refusing to reuse existing output: {output}')
        output.mkdir(parents=True, exist_ok=False)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    spec = importlib.util.spec_from_file_location('water_clock_owned_runner', owned)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source_paths = [verifier, owned, Path(__file__).resolve(),
                    root / 'project/native_distortion_candidate/original_native_distortion.gd',
                    root / 'project/source_separate_translucency/separate_effect.gd',
                    root / 'project/shaders/original_water_approx.gdshader']
    source_paths += sorted((root / 'project/source_water_distortion_candidate').glob('*'))
    source_hashes = {str(p.relative_to(root) if p.is_relative_to(root) else p): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in source_paths if p.is_file() and p.suffix != '.uid'}
    write_json(output / 'input-sha256.json', source_hashes)
    command = [str(godot), '--path', str(root / 'project'), '--resolution', '1280x720',
               '--script', 'res://scripts/verify_source_water_distortion.gd',
               '--log-file', str(output / 'engine.log'), '--',
               '--water-distortion-report-dir=' + output.as_posix()]
    write_json(output / 'invocation.json', {'command': command, 'root': str(root),
                                          'started_utc': datetime.now(timezone.utc).isoformat()})
    print('Running water clock validation: ' + str(output), flush=True)
    result = module.run_owned_tree(command, root, output / 'stdout.log', args.timeout)
    lines = (output / 'stdout.log').read_text(encoding='utf-8', errors='replace').splitlines()
    clean = [re.sub(r'\x1b\[[0-9;]*m', '', line).strip() for line in lines]
    result['errors'] = [line for line in clean if re.match(r'^(?:SCRIPT |SHADER )?ERROR:', line)]
    result['warnings'] = [line for line in clean if line.startswith('WARNING:')]
    report_path = output / 'water-distortion-validation.json'
    result['report_present'] = report_path.is_file()
    result['runtime_failures'] = []
    result['maps'] = []
    if report_path.is_file():
        try:
            report = json.loads(report_path.read_text(encoding='utf-8-sig'))
            result['runtime_failures'] = report.get('failures', ['Missing runtime failures list'])
            for row in report.get('maps', []):
                result['maps'].append({'map': row.get('map'), 'water_dynamic': row.get('water_dynamic'),
                                       'source_unchanged': row.get('source_unchanged'),
                                       'restored_pixels_equal': row.get('restored_pixels_equal')})
        except (OSError, ValueError) as error:
            result['runtime_failures'] = ['Invalid final report: ' + str(error)]
    else:
        result['runtime_failures'] = ['Missing final water-distortion-validation.json']
    execution_complete = (result['exit'] in (0, 1) and not result['timed_out'] and not result['interrupted']
                          and not result['runner_error'] and not result['errors'] and result['report_present'])
    maps = result['maps']
    result['water_dynamic_passed'] = bool(execution_complete and len(maps) == 2
        and {row['map'] for row in maps} == {'wuming', 'youxian'}
        and all(row['water_dynamic'] is not None and row['water_dynamic'].get('passed') is True for row in maps))
    result['overall_passed'] = bool(result['water_dynamic_passed'] and result['exit'] == 0
                                    and not result['runtime_failures'])
    result['boundary'] = ('Water dynamic success is separate from the strict frozen restoration outcome. '
                         'All runtime failures and engine warnings/errors are retained; no tolerance is widened. '
                         'No independent UE image parity or full scene completion is asserted.')
    write_json(output / 'runner.json', result)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result['overall_passed'] else (130 if result['interrupted'] else 1)


if __name__ == '__main__':
    raise SystemExit(main())
