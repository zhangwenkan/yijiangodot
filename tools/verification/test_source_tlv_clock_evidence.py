"""Synthetic CPU-only boundary checks; no F: writes or engine execution."""
from pathlib import Path
import json, struct, sys, tempfile
import numpy as np
from PIL import Image

temp=tempfile.TemporaryDirectory(prefix='source-tlv-clock-')
BASE=Path(temp.name)
sys.path.insert(0,str(Path(__file__).resolve().parent))
from analyze_source_tlv_receiver import stage_drift

names=['baseline','baseline-repeat','receiver-bypass','restored']
results=[]
for scenario in ['verified','legacy','unsupported','wrong-slice','nan-time']:
    run=BASE/scenario
    for name in names:
        folder=run/('youxian-default-'+name+'-diagnostic')
        (folder/'dof').mkdir(parents=True,exist_ok=True)
        np.zeros((1,1,3,4),dtype='<f4').tofile(folder/'dof/samples.rgba32f')
        (folder/'dof/capture.json').write_text(json.dumps({'complete':True,'record_shape':[1,1,3,4],'parameters_f32':[]}),encoding='utf-8')
        stage={'width':1,'height':1}
        for key in ['before_rgba16f','layer_rgba16f','after_rgba16f']:
            np.zeros((1,1,4),dtype='<f2').tofile(folder/(key+'.bin'))
            stage[key]={'file':key+'.bin'}
        full=bytearray(5696 if scenario!='unsupported' else 5728)
        struct.pack_into('<f',full,2816,float('nan') if scenario=='nan-time' else 42.0)
        struct.pack_into('<f',full,2832,1.0)
        clock=full[2832:2848] if scenario in ['legacy','wrong-slice'] else full[2816:2832]
        (folder/'clock.bin').write_bytes(clock)
        stage['scene_time_ubo']={'file':'clock.bin'}
        stage['scene_shader_time']=struct.unpack_from('<f',clock)[0]
        if scenario!='legacy':
            (folder/'full.bin').write_bytes(full)
            stage.update(scene_ubo_full={'file':'full.bin'},scene_time_offset=2816,scene_ubo_layout='godot-4.7.2-float-2848x2' if scenario!='unsupported' else 'unsupported')
        (folder/'stage.json').write_text(json.dumps(stage),encoding='utf-8')
        Image.new('RGBA',(1,1)).save(run/('youxian-default-'+name+'.png'))
    result=stage_drift(run,run/'analysis')
    results.append({'case':scenario,'scene_clock_frozen':result['scene_clock_frozen'],'verified':result['metadata']['baseline']['scene_clock_layout_verified'],'time':result['metadata']['baseline']['scene_shader_time_verified']})
assert results[0]['verified'] is True and results[0]['scene_clock_frozen'] is True
assert all(r['verified'] is False and r['scene_clock_frozen'] is None and r['time'] is None for r in results[1:])
print(json.dumps(results,indent=2,allow_nan=False))
temp.cleanup()
