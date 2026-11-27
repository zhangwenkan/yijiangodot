"""Run an explicit drift capture; frozen image equality remains a separate result.

Only a new output folder is written. No production shader or scene is changed.
The shared runner terminates only its own process tree on timeout/interruption.
"""
from pathlib import Path
import argparse, hashlib, importlib.util, json, math, re

FILES=(
 'project/scripts/verification/diagnostics/verify_tlv_drift.gd',
 'project/scripts/verification/diagnostics/stage_readback.gd',
 'project/scripts/verification/verify_source_tlv_receiver.gd',
 'tools/verification/run_source_tlv_drift.py',
 'tools/verification/run_source_separate_translucency.py',
)
def locate(explicit):
    if explicit is not None:
        root=explicit.resolve()
        if not (root/'project/project.godot').is_file():raise ValueError('--root has no project/project.godot')
        return root
    for root in Path(__file__).resolve().parents:
        if (root/'project/project.godot').is_file():return root
    raise ValueError('Cannot discover checkout; supply --root')
def write(path,data):path.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path)
    parser.add_argument('--out',type=Path,required=True,help='Fresh report folder; relative to checkout')
    parser.add_argument('--timeout',type=float,default=240)
    parser.add_argument('--godot',type=Path)
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--shadow-controls',action='store_true')
    modes.add_argument('--unshaded-controls',action='store_true')
    modes.add_argument('--lf-controls',action='store_true')
    modes.add_argument('--landscape-controls',action='store_true',help='Temporarily unshade only the uniquely identified Youxian landscape; diagnostic, not a fix')
    modes.add_argument('--landscape-specular-controls',action='store_true',help='Temporarily bypass only direct specular on the uniquely identified Youxian landscape; diagnostic, not a fix')
    parser.add_argument('--direct-youxian',action='store_true')
    args=parser.parse_args()
    try:
        root=locate(args.root)
        if not math.isfinite(args.timeout) or args.timeout<=0:raise ValueError('--timeout must be finite and positive')
        godot=(root/(args.godot or Path('tools/godot/Godot_v4.7.2-stable_win64_console.exe'))).resolve()
        for file in [godot]+[root/rel for rel in FILES]:
            if not file.is_file():raise ValueError('Missing required file: '+str(file))
        out=(root/args.out).resolve();out.mkdir(parents=True,exist_ok=False)
    except (ValueError,OSError) as error:parser.error(str(error))
    spec=importlib.util.spec_from_file_location('drift_owned_runner',root/FILES[-1])
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    command=[str(godot),'--path',str(root/'project'),'--resolution','960x540','--script',
        'res://scripts/verification/diagnostics/verify_tlv_drift.gd','--','--hide-ui','--tlv-out='+out.as_posix()]
    for active,flag in ((args.shadow_controls,'--drift-shadow-controls'),(args.unshaded_controls,'--drift-unshaded-controls'),(args.lf_controls,'--drift-lf-controls'),(args.landscape_controls,'--drift-landscape-controls'),(args.landscape_specular_controls,'--drift-landscape-specular-controls'),(args.direct_youxian,'--map=youxian')):
        if active:command.append(flag)
    source_paths={root/rel for rel in FILES}
    for directory in ('project/source_tlv_candidate','project/source_water_distortion_candidate','project/native_distortion_candidate','project/source_separate_translucency'):
        source_paths.update(p for p in (root/directory).glob('*') if p.is_file() and p.suffix!='.uid')
    source_paths.update(p for p in (root/'tools/verification/drift').glob('*.py'))
    if args.landscape_controls or args.landscape_specular_controls:
        source_paths.update(root/rel for rel in ('project/scripts/original_compiled_landscape.gd',
            'project/shaders/original_landscape_compiled.gdshader','project/scripts/original_source_renderer.gd',
            'project/shaders/original_lightfunction_receiving.gdshaderinc','project/shaders/original_lightfunction_compiled.gdshaderinc'))
    hashes={p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source_paths)}
    write(out/'input-sha256.json',hashes);write(out/'invocation.json',command)
    script=root/FILES[0]
    (out/'script.sha256').write_text(hashlib.sha256(script.read_bytes()).hexdigest(),encoding='utf-8')
    (out/'verifier.gd').write_bytes(script.read_bytes())
    for rel in FILES[:2]:(out/Path(rel).name).write_bytes((root/rel).read_bytes())
    print('Running explicit drift capture: '+str(out),flush=True)
    result=module.run_owned_tree(command,root,out/'engine.log',args.timeout)
    lines=(out/'engine.log').read_text(encoding='utf-8',errors='replace').splitlines()
    clean=[re.sub(r'\x1b\[[0-9;]*m','',line).strip() for line in lines]
    result['engine_errors']=[line for line in clean if 'ERROR:' in line or 'WARNING:' in line]
    report={}
    try:report=json.loads((out/'receiver.json').read_text(encoding='utf-8-sig'))
    except (ValueError,OSError) as error:result['report_error']=str(error)
    result['input_sources_unchanged']=all(hashlib.sha256((root/rel).read_bytes()).hexdigest()==digest for rel,digest in hashes.items())
    result['capture_passed']=bool(result['exit']==0 and not result['timed_out'] and not result['interrupted']
        and not result['runner_error'] and not result['engine_errors'] and result['input_sources_unchanged']
        and report.get('stage')=='complete' and not report.get('failures',['missing report']))
    result['scope']='Capture execution only; exact frozen equality is analyzed separately and may fail. No default-runtime activation.'
    write(out/'runner.json',result);print(json.dumps(result,ensure_ascii=False,indent=2),flush=True)
    return 0 if result['capture_passed'] else (130 if result['interrupted'] else 1)
if __name__=='__main__':raise SystemExit(main())
