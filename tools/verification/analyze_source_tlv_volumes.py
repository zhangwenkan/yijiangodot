"""Compare GPU pack/filter against CPU, preserve all exact difference arrays.

Acceptance for this source-sun (one light, no cancellation) dataset is <=1
adjacent binary16 ULP for pack and <=1 ULP for FILTER ISOLATED from pack input.
All half interpolation coordinates are dyadic (.5 voxel), so weights are exact;
at most 64 nonnegative same-sign contributions give float32 gamma_64 < 4e-6,
well below half spacing 2^-11. One ULP allows a rounding-boundary crossing.
The filter test uses GPU raw as input so injection error is never counted twice.
End-to-end differences are always retained separately, without an inflated gate.
This numerical gate is not a source-shadow or live-scene equality claim.
"""
from pathlib import Path
import argparse, hashlib, json, sys
import numpy as np
from tlv_volume_oracle import inject_resolved, filter_volume


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read_volume(path,dtype):
    expected=64**3*4*np.dtype(dtype).itemsize
    if path.stat().st_size!=expected: raise ValueError('Unexpected byte count '+str(path))
    a=np.fromfile(path,dtype=dtype).reshape(64,64,64,4)
    if not np.isfinite(a).all(): raise ValueError('Nonfinite '+str(path))
    return a


def half_order(value):
    # Numerical adjacent-half ordering, with +0 and -0 mapped to the same point.
    bits=np.asarray(value,dtype=np.float16).view(np.uint16).astype(np.int32)
    return np.where((bits&0x8000)!=0,0x8000-(bits&0x7fff),0x8000+bits)


def difference(actual,expected,dest,gate=True):
    delta=actual.astype(np.float32)-expected.astype(np.float32)
    distance=np.abs(half_order(actual)-half_order(expected))
    np.savez_compressed(dest,delta=delta,half_ulp_distance=distance.astype(np.uint16),expected=expected)
    worst=np.unravel_index(np.argmax(np.abs(delta)),delta.shape)
    result={'exact_equal':bool(np.all(delta==0)),'different_components':int(np.count_nonzero(delta)),
        'max_abs_difference':float(np.max(np.abs(delta))),'mean_abs_difference':float(np.mean(np.abs(delta))),
        'max_half_ulp_distance':int(distance.max()),'components_over_one_ulp':int(np.count_nonzero(distance>1)),
        'per_channel_max_abs':np.max(np.abs(delta),axis=(0,1,2)).tolist(),
        'worst_zyxc':list(map(int,worst)),'worst_actual':float(actual[worst]),'worst_expected':float(expected[worst]),
        'exact_differences':str(dest),'differences_sha256':sha(dest)}
    if gate: result['passed']=bool(np.all(distance<=1))
    return result


def analyze(manifest_path,gpu_root,out):
    manifest=json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    out.mkdir(parents=True,exist_ok=True)
    reports=[]; failures=[]
    for case in manifest['cases']:
        name=case['name']; dest=out/name; dest.mkdir(exist_ok=True)
        report={'name':name,'checks':{},'files':{}}
        try:
            if len(case['lights'])!=1: raise ValueError('This bounded scene-sun oracle requires one light; multi-light cancellation needs a separate bound')
            light=case['lights'][0]
            r=read_volume(manifest_path.parent/light['resolved'],'<f4')
            d=read_volume(manifest_path.parent/light['direction'],'<f4')
            expected_a,expected_b=inject_resolved(r,d)
            actual={}
            for label in ('ambient','directional','filtered-ambient','filtered-directional'):
                path=gpu_root/'cases'/name/(label+'.rgba16f')
                actual[label]=read_volume(path,'<f2')
                report['files'][label]={'path':str(path),'sha256':sha(path)}
            for label,expected in [('ambient',expected_a),('directional',expected_b)]:
                report['checks'][label]=difference(actual[label],expected,dest/(label+'-difference.npz'))
                filtered='filtered-'+label
                report['checks'][filtered+'-isolated']=difference(actual[filtered],filter_volume(actual[label]),dest/(filtered+'-isolated-difference.npz'))
                report['checks'][filtered+'-end-to-end']=difference(actual[filtered],filter_volume(expected),dest/(filtered+'-end-to-end-difference.npz'),False)
            report['passed']=all(v.get('passed',True) for v in report['checks'].values())
        except Exception as exc:
            report['passed']=False; report['error']=str(exc)
        if not report['passed']: failures.append(name)
        reports.append(report)
    result={'passed':not failures,'failures':failures,'cases':reports,
        'manifest_sha256':sha(manifest_path),'threshold_fixed_before_gpu_readback':True,
        'gate':'Raw pack and filter isolated from GPU raw each <=1 adjacent RGBA16F ULP; exact arrays retained; no end-to-end threshold inflation.',
        'scope':'One source-sun light, no SH cancellation; not native UE injection/shadow equivalence; not arbitrary lights or scene acceptance.'}
    (out/'gpu-validation.json').write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--manifest',type=Path,required=True);p.add_argument('--gpu',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();result=analyze(a.manifest,a.gpu,a.out);print(json.dumps({'passed':result['passed'],'failures':result['failures'],'cases':len(result['cases'])}));sys.exit(0 if result['passed'] else 1)
