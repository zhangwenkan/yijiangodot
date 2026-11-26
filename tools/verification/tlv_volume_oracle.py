"""Stage-only TLV pack/filter oracle; no source-light/shadow input is invented.

Input volume layout: [z,y,x,rgba], float32 resolved RGB+sunAlpha; direction UE XYZ.
Half writes happen after each light and once after the complete 8-tap filter.
Filter interpolation below is ideal real arithmetic with one final half write.
It does not claim native GPU sampler/FP32 instruction-order bit equivalence.
"""
from __future__ import annotations
import numpy as np


def inject_resolved(resolved, directions, ambient=None, directional=None):
    r = np.asarray(resolved, dtype=np.float32)
    d = np.asarray(directions, dtype=np.float32)
    if r.ndim != 4 or r.shape[-1] != 4 or len(set(r.shape[:3])) != 1:
        raise ValueError('Expected cubic resolved volume [z,y,x,4]')
    if d.shape != r.shape or not np.isfinite(r).all() or not np.isfinite(d).all():
        raise ValueError('Missing, malformed, or nonfinite resolved input')
    length_sq = np.sum(d[..., :3] * d[..., :3], axis=-1, keepdims=True, dtype=np.float32)
    if np.any(length_sq <= 1e-12):
        raise ValueError('Unresolved light direction')
    direction = d[..., :3] / np.sqrt(length_sq)
    a = np.empty_like(r)
    a[..., :3] = r[..., :3] * np.float32(.282095)
    a[..., 3] = r[..., 3]
    b = np.zeros_like(r)
    basis = np.stack((-direction[..., 1], direction[..., 2], -direction[..., 0]), axis=-1) * np.float32(.488603)
    luma = np.array([.3, .59, .11], dtype=np.float32)
    for component in range(3):
        b[..., component] = np.sum(r[..., :3] * basis[..., component, None] * luma, axis=-1, dtype=np.float32)
    if (ambient is None) != (directional is None):
        raise ValueError('Both previous half volumes are required together')
    if ambient is not None:
        for prior in (ambient, directional):
            if np.asarray(prior).shape != r.shape or np.asarray(prior).dtype != np.float16:
                raise ValueError('Previous volumes must be matching RGBA16F arrays')
        a += np.asarray(ambient, dtype=np.float32)
        b += np.asarray(directional, dtype=np.float32)
    if not np.isfinite(a).all() or not np.isfinite(b).all() or np.any(np.abs(a)>65504) or np.any(np.abs(b)>65504):
        raise ValueError('Invalid/overflow half accumulation')
    return a.astype(np.float16), b.astype(np.float16)


def filter_volume(volume):
    v = np.asarray(volume)
    if v.dtype != np.float16 or v.ndim != 4 or v.shape[-1] != 4 or len(set(v.shape[:3])) != 1 or not np.isfinite(v).all():
        raise ValueError('Expected finite cubic RGBA16F source volume')
    # Each source tap is trilinear at +/- half a texel. Averaging eight taps
    # equals [1/4,1/2,1/4]^3 with clamped border, WITHOUT intermediate half writes.
    result = v.astype(np.float64)
    for axis in (0, 1, 2):
        indices = np.arange(v.shape[axis])
        before = np.take(result, np.maximum(indices-1, 0), axis=axis)
        after = np.take(result, np.minimum(indices+1, v.shape[axis]-1), axis=axis)
        result = before*.25 + result*.5 + after*.25
    return result.astype(np.float16)


def self_test():
    r = np.zeros((4,4,4,4), np.float32)
    r[..., :3] = [1.,2.,3.]
    r[..., 3] = .7
    d = np.zeros_like(r)
    d[..., 2] = 1
    a,b = inject_resolved(r,d)
    assert np.array_equal(a[..., :3], np.broadcast_to(np.array([1,2,3])*.282095, (4,4,4,3)).astype(np.float16))
    assert np.all(b[...,0] == 0) and np.all(b[...,2:] == 0) and np.all(b[...,1] > 0)
    assert np.array_equal(filter_volume(a), a)
    a2,b2 = inject_resolved(r,d,a,b)
    assert np.array_equal(a2,(a.astype(np.float32)+r*np.array([.282095,.282095,.282095,1],np.float32)).astype(np.float16))
    impulse = np.zeros((5,5,5,4),np.float16)
    impulse[2,2,2,0] = 1
    filtered = filter_volume(impulse)
    assert filtered[2,2,2,0] == .125 and filtered[...,0].sum() == 1
    invalid = d.copy(); invalid[0,0,0,:] = 0
    try: inject_resolved(r,invalid)
    except ValueError: pass
    else: raise AssertionError('Missing direction did not fail')
    invalid = r.copy(); invalid[0,0,0,0] = np.nan
    try: inject_resolved(invalid,d)
    except ValueError: pass
    else: raise AssertionError('Invalid resolved input did not fail')
    return {'passed': 7, 'gpu_executed': False}


if __name__ == '__main__':
    import json
    print(json.dumps(self_test()))
