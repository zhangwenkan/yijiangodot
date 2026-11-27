"""Within-condition frozen drift and CPU world-position localization.

Never compares images between shadow-control conditions. Positions describe
the first opaque depth surface, not a mesh/material identity or illumination source.
"""
from pathlib import Path
import argparse,csv,hashlib,json,itertools
import numpy as np
from PIL import Image,ImageDraw
from analyze_distortion_drift import stats,save_diff,changed
from analyze_upstream_drift import ubo_diff

MODES=['original','sun-shadow-off','local-shadow-off','all-shadow-off','restored']
STAGES=['post-opaque','before-atmosphere','after-atmosphere']

def read_json(p):return json.loads(p.read_text(encoding='utf-8-sig'))

def load(folder):
    meta=read_json(folder/'capture.json');h,w=meta['height'],meta['width']
    fields={};blobs={};stage_meta={}
    for upstream in meta['upstream']:
        name=upstream['rgba16f']['file'].removesuffix('-rgba16f.bin')
        fields[name]=np.fromfile(folder/upstream['rgba16f']['file'],'<f2').reshape(h,w,4)
        fields[name+'-depth']=np.fromfile(folder/upstream['depth_f32']['file'],'<f4').reshape(h,w)
        blobs[name]=(folder/upstream['scene_ubo']['file']).read_bytes()
        stage_meta[name]={k:upstream[k] for k in ('callback_serial','drawn_frame','token')}
    for key,dtype in [('before_rgba16f','<f2'),('accumulation_rgba8','u1'),('after_rgba16f','<f2')]:
        fields[key]=np.fromfile(folder/meta[key]['file'],dtype).reshape(h,w,4)
    return {'name':folder.name,'folder':folder,'meta':meta,'fields':fields,'blobs':blobs,'stage_meta':stage_meta}

def matrices(blob):
    if len(blob)!=5696:raise ValueError('Only audited float-build 5696-byte UBO supported')
    f=np.frombuffer(blob,'<f4').astype(np.float64)
    projection=f[0:16].reshape(4,4).T
    inverse_projection=f[16:32].reshape(4,4).T
    inverse_view=np.eye(4);inverse_view[:3]=f[32:44].reshape(3,4)
    view=np.eye(4);view[:3]=f[44:56].reshape(3,4)
    return projection,inverse_projection,view,inverse_view

def unproject(xy,depth,blob,w,h):
    p,ip,v,iv=matrices(blob)
    ndc=np.column_stack(((xy[:,0]+.5)/w*2-1,(xy[:,1]+.5)/h*2-1,depth,np.ones(len(xy))))
    view_h=ndc@ip.T
    valid=np.isfinite(view_h).all(axis=1)&(np.abs(view_h[:,3])>1e-12)&(depth>0)
    views=view_h[:,:3]/view_h[:,3:4]
    world=np.column_stack((views,np.ones(len(xy))))@iv.T
    reproject=np.column_stack((world[:,:3],np.ones(len(xy))))@v.T@p.T
    reproject=reproject[:,:3]/reproject[:,3:4]
    rx=(reproject[:,0]+1)*w/2-.5;ry=(reproject[:,1]+1)*h/2-.5
    error=np.abs(np.column_stack((rx,ry))-xy)
    return {'world':world[:,:3],'view':views,'valid':valid,'error':error,
        'projection':p,'inverse_projection':ip,'view_matrix':v,'inverse_view_matrix':iv,
        'projection_inverse_error':float(np.max(np.abs(p@ip-np.eye(4)))),
        'view_inverse_error':float(np.max(np.abs(v@iv-np.eye(4))))}

def components_xy(xy,radius):
    """Connected components under pixel Chebyshev distance <= radius."""
    unseen=set(map(tuple,xy.tolist()));groups=[]
    while unseen:
        seed=min(unseen,key=lambda p:(p[1],p[0]));unseen.remove(seed);group=[seed];stack=[seed]
        while stack:
            x,y=stack.pop()
            near=[p for p in unseen if abs(p[0]-x)<=radius and abs(p[1]-y)<=radius]
            unseen.difference_update(near);group.extend(near);stack.extend(near)
        groups.append(group)
    return sorted(groups,key=lambda g:(-len(g),min(p[1] for p in g)))

def main(run,out):
    out.mkdir(parents=True,exist_ok=True)
    report={'run':str(run),'scope':'Only six within-condition frame pairs per mode; no cross-condition image equality or subtraction.',
        'world_position_scope':'First opaque depth surface reconstructed from exact same-callback UBO/depth. No object ID. Float32 source matrices are evaluated in float64; displayed coordinates are diagnostic, not collision-precise.',
        'modes':[]}
    control=read_json(run/'receiver.json')
    modes=[]
    for mode in MODES:
        captures=[load(p) for p in sorted(run.glob(mode+'-[0-9][0-9]'))]
        if len(captures)!=4:raise ValueError('Expected 4 captures '+mode)
        folder=out/mode;folder.mkdir(exist_ok=True)
        row={'mode':mode,'captures':[],'pairs':[]}
        controls=[v for v in control.get('shadow_controls',[]) if v['mode']==mode]
        row['light_count']=len(controls);row['enabled_shadow_count']=sum(bool(v['shadow']) for v in controls)
        row['light_energy_sum']=sum(float(v['energy']) for v in controls)
        for cap in captures:
            sm=cap['stage_meta'];row['captures'].append({'name':cap['name'],'stage_metadata':sm,
                'same_stage_frame_ids':len(set(v['drawn_frame'] for v in sm.values()))==1,
                'same_stage_tokens':len(set(v['token'] for v in sm.values()))==1,
                'same_stage_callback_serial':len(set(v['callback_serial'] for v in sm.values()))==1,
                'opaque_equals_before_atmosphere':stats(cap['fields']['post-opaque'],cap['fields']['before-atmosphere']),
                'scene_ubo_sizes':{k:len(v) for k,v in cap['blobs'].items()},
                'ubo_stage_equal':len(set(cap['blobs'].values()))==1,
                'postopaque_sha256':hashlib.sha256(cap['fields']['post-opaque'].tobytes()).hexdigest()})
        h,w=captures[0]['fields']['post-opaque'].shape[:2];union=np.zeros((h,w),bool);max_delta=np.zeros((h,w),np.float64)
        for first,second in itertools.combinations(captures,2):
            pair={'first':first['name'],'second':second['name'],'fields':{},'ubo':{}}
            for key,a in first['fields'].items():
                b=second['fields'][key];s=stats(a,b)
                if key=='post-opaque':
                    s['exact_samples']=save_diff(a,b,folder/(first['name']+'__'+second['name']+'__post-opaque.npz'))
                    union|=changed(a,b);max_delta=np.maximum(max_delta,np.abs(a.astype(np.float64)-b.astype(np.float64)).max(axis=-1))
                pair['fields'][key]=s
            for key,a in first['blobs'].items():pair['ubo'][key]=ubo_diff(a,second['blobs'][key])
            order=STAGES+['before_rgba16f','accumulation_rgba8','after_rgba16f']
            pair['earliest_recorded_change']=next((key for key in order if not pair['fields'][key]['byte_exact']),None)
            row['pairs'].append(pair)
        row['all_depths_byte_exact']=all(all(v['byte_exact'] for k,v in p['fields'].items() if k.endswith('-depth')) for p in row['pairs'])
        row['all_ubos_byte_exact']=all(all(v['byte_exact'] for v in p['ubo'].values()) for p in row['pairs'])
        row['all_accumulations_byte_exact']=all(p['fields']['accumulation_rgba8']['byte_exact'] for p in row['pairs'])
        row['postopaque_unique_hashes']=len(set(c['postopaque_sha256'] for c in row['captures']))
        row['changed_pairs']=sum(not p['fields']['post-opaque']['byte_exact'] for p in row['pairs'])
        row['postopaque_changed_pixel_range']=[min(p['fields']['post-opaque']['changed_pixels'] for p in row['pairs']),max(p['fields']['post-opaque']['changed_pixels'] for p in row['pairs'])]
        row['postopaque_max_abs']=float(max_delta.max());row['postopaque_union_pixels']=int(union.sum())
        yy,xx=np.nonzero(union);xy=np.column_stack((xx,yy));row['postopaque_union_bbox_xyxy']=[int(xx.min()),int(yy.min()),int(xx.max()+1),int(yy.max()+1)] if len(xx) else None
        cap=captures[0];depth=cap['fields']['post-opaque-depth'][union]
        points=unproject(xy,depth,cap['blobs']['post-opaque'],w,h)
        row['world_reconstruction']={k:v.tolist() if isinstance(v,np.ndarray) else v for k,v in points.items() if k not in ('world','view','valid','error')}
        row['world_reconstruction'].update({'valid_pixels':int(points['valid'].sum()),'zero_depth_pixels':int((depth==0).sum()),
            'max_reprojection_error_pixels':float(points['error'].max()) if len(xx) else 0,
            'camera_string_for_independent_rounded_check':cap['meta']['camera']})
        samples=[]
        for i,(x,y) in enumerate(xy):
            samples.append({'xy':[int(x),int(y)],'depth':float(depth[i]),'world_xyz':points['world'][i].tolist(),
                'view_xyz':points['view'][i].tolist(),'max_abs_delta':float(max_delta[y,x]),'world_valid':bool(points['valid'][i]),
                'rgba':[c['fields']['post-opaque'][y,x].tolist() for c in captures]})
        row['samples']=sorted(samples,key=lambda s:(-s['max_abs_delta'],s['xy'][1],s['xy'][0]))
        samples_by_xy={tuple(s['xy']):s for s in samples}
        spatial=[]
        for index,group in enumerate(components_xy(xy,12)):
            coords=np.array(group);gs=[samples_by_xy[p] for p in group];world=np.array([s['world_xyz'] for s in gs]);peak=max(gs,key=lambda s:s['max_abs_delta'])
            spatial.append({'index':index,'grouping':'12-pixel Chebyshev connectivity of changed pixels; not object segmentation',
                'pixels':len(group),'bbox_xyxy':[int(coords[:,0].min()),int(coords[:,1].min()),int(coords[:,0].max()+1),int(coords[:,1].max()+1)],
                'world_min':world.min(axis=0).tolist(),'world_max':world.max(axis=0).tolist(),'peak':peak})
        row['regions']=spatial
        csv_path=folder/'postopaque-world-samples.csv'
        with csv_path.open('w',newline='',encoding='utf-8') as f:
            writer=csv.writer(f);writer.writerow(['x','y','depth','world_x','world_y','world_z','max_abs_delta','world_valid','rgba_00','rgba_01','rgba_02','rgba_03'])
            for s in row['samples']:writer.writerow(s['xy']+[s['depth']]+s['world_xyz']+[s['max_abs_delta'],s['world_valid']]+[json.dumps(v) for v in s['rgba']])
        rgb=np.maximum(cap['fields']['post-opaque'][:,:,:3].astype(np.float64),0);rgb=np.power(rgb/(1+rgb),1/2.2)
        im=Image.fromarray(np.clip(np.rint(rgb*255),0,255).astype(np.uint8));draw=ImageDraw.Draw(im)
        for region in spatial:
            x0,y0,x1,y1=region['bbox_xyxy'];draw.rectangle((max(x0-3,0),max(y0-3,0),min(x1+3,w-1),min(y1+3,h-1)),outline=(255,70,70),width=1)
            draw.text((max(x0-3,0),max(y0-14,0)),str(region['index']),fill=(255,255,0))
        im.save(folder/'postopaque-union-regions.png')
        row['files']={'world_csv':str(csv_path),'marked_hdr_preview':str(folder/'postopaque-union-regions.png')}
        report['modes'].append(row)
        modes.append({'mode':mode,'light_count':row['light_count'],'enabled_shadow_count':row['enabled_shadow_count'],
            'changed_pairs':row['changed_pairs'],'unique_hashes':row['postopaque_unique_hashes'],'pixels_range':row['postopaque_changed_pixel_range'],
            'union_pixels':row['postopaque_union_pixels'],'max_abs':row['postopaque_max_abs'],
            'depth_exact':row['all_depths_byte_exact'],'ubo_exact':row['all_ubos_byte_exact'],'accumulation_exact':row['all_accumulations_byte_exact'],
            'world_valid':row['world_reconstruction']['valid_pixels'],'reprojection_error':row['world_reconstruction']['max_reprojection_error_pixels'],
            'top_regions':row['regions'][:5]})
    report['summary']=modes
    (out/'shadow-controls-analysis.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    (out/'summary.json').write_text(json.dumps(modes,indent=2),encoding='utf-8')
    print(json.dumps(modes,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();main(a.run,a.out)
