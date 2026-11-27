"""Run one frozen caster diagnostic from a checkout, with owned-process cleanup.

Uses installed res:// verification/binding paths. Default production rendering
is never activated by this runner. Previous runs are preserved in fresh outputs.
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
import sys


INSTALLED_FILES = (
    'project/source_tlv_candidate/source_tlv_caster_camera_binding.gd',
    'project/scripts/verification/verify_caster_camera.gd',
    'project/scripts/verification/caster_ubo_readback.gd',
    'tools/verification/analyze_source_tlv_caster.py',
    'tools/verification/run_source_tlv_caster.py',
)


def checkout_root(explicit):
    if explicit is not None:
        root = explicit.resolve()
        if not (root / 'project/project.godot').is_file():
            raise ValueError('Explicit --root has no project/project.godot')
        return root
    for root in Path(__file__).resolve().parents:
        if (root / 'project/project.godot').is_file():
            return root
    raise ValueError('Cannot discover checkout from __file__; supply --root')


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--out', type=Path, required=True, help='Fresh output directory; relative paths resolve from checkout')
    parser.add_argument('--map', choices=('wuming', 'youxian'), default='wuming')
    parser.add_argument('--timeout', type=float, default=300)
    parser.add_argument('--godot', type=Path)
    args = parser.parse_args(argv)
    try:
        root = checkout_root(args.root)
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise ValueError('--timeout must be finite and positive')
        godot = (root / (args.godot or Path('tools/godot/Godot_v4.7.2-stable_win64_console.exe'))).resolve()
        owned = root / 'tools/verification/run_source_separate_translucency.py'
        analyzer = root / 'tools/verification/analyze_source_tlv_caster.py'
        for path in (godot, owned, *(root / rel for rel in INSTALLED_FILES)):
            if not path.is_file():
                raise ValueError(f'Missing required installed file: {path}')
        if importlib.util.find_spec('numpy') is None:
            raise ValueError('This Python requires numpy for the analyzer')
        output = (root / args.out).resolve()
        output.mkdir(parents=True, exist_ok=False)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    spec = importlib.util.spec_from_file_location('caster_owned_runner', owned)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sources = {root / rel for rel in INSTALLED_FILES}
    sources.update(path for path in (root / 'project/source_tlv_candidate').glob('*') if path.is_file() and path.suffix != '.uid')
    sources.update((owned, root / 'project/scripts/original_source_renderer.gd', root / 'project/scripts/worlds.gd',
                    root / 'project/project.godot', root / 'project/worlds.tscn'))
    input_hashes = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in sorted(sources) if path.is_file()}
    write_json(output / 'input-sha256.json', input_hashes)
    # Snapshot only the five candidate inputs; preserve all earlier run evidence.
    for rel in INSTALLED_FILES:
        destination = output / 'inputs' / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((root / rel).read_bytes())
    command = [str(godot), '--path', str(root / 'project'), '--resolution', '960x540',
               '--script', 'res://scripts/verification/verify_caster_camera.gd', '--', '--hide-ui',
               '--tlv-out=' + output.as_posix(),
               '--caster-binding=res://source_tlv_candidate/source_tlv_caster_camera_binding.gd',
               '--caster-map=' + args.map]
    write_json(output / 'invocation.json', {'command': command, 'root': str(root), 'map': args.map,
                                          'started_utc': datetime.now(timezone.utc).isoformat()})
    print('Running frozen caster validation: ' + str(output), flush=True)
    result = module.run_owned_tree(command, root, output / 'engine.log', args.timeout)
    lines = (output / 'engine.log').read_text(encoding='utf-8', errors='replace').splitlines()
    clean = [re.sub(r'\x1b\[[0-9;]*m', '', line).strip() for line in lines]
    result['engine_errors'] = [line for line in clean if 'ERROR:' in line or 'WARNING:' in line]
    report_path = output / 'caster-camera.json'
    result['report_present'] = report_path.is_file()
    report = {}
    if report_path.is_file():
        try:
            report = json.loads(report_path.read_text(encoding='utf-8-sig'))
        except (OSError, ValueError) as error:
            result['report_error'] = str(error)
    result['runtime_failures'] = report.get('failures', ['Missing final report or failure list'])
    result['engine_passed'] = bool(result['exit'] == 0 and not result['timed_out'] and not result['interrupted']
                                  and not result['runner_error'] and not result['engine_errors']
                                  and report.get('stage') == 'complete' and not result['runtime_failures'])
    result['cpu_passed'] = False
    if report and result['exit'] in (0, 1) and not result['timed_out'] and not result['interrupted']:
        analysis = module.run_owned_tree([sys.executable, '-B', '-X', 'utf8', str(analyzer), str(output)],
                                          root, output / 'cpu.log', 120)
        result['cpu'] = analysis
        result['cpu_passed'] = bool(analysis['exit'] == 0 and not analysis['timed_out']
                                    and not analysis['interrupted'] and not analysis['runner_error'])
    current_hashes = {rel: hashlib.sha256((root / rel).read_bytes()).hexdigest() for rel in input_hashes}
    result['input_sources_unchanged'] = current_hashes == input_hashes
    result['passed'] = bool(result['engine_passed'] and result['cpu_passed'] and result['input_sources_unchanged'])
    result['scope'] = ('One frozen map diagnostic with four enabled captures per cascade and strict baseline/restore. '
                       'No production activation, no UE shadow parity claim, and no change to historical V2/V3 findings.')
    write_json(output / 'runner.json', result)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['passed'] else (130 if result['interrupted'] else 1)


if __name__ == '__main__':
    raise SystemExit(main())
