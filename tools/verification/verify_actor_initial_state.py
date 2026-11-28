"""CPU-only regression for imported Actor flags; temporary project, no asset writes.

Default fixtures need only the tracked manifest/scripts. --source-assets also
checks every existing GLB source node and real house groups without loading meshes.
"""
from pathlib import Path
import argparse
import json
import shutil
import struct
import subprocess
import tempfile


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def glb_nodes(path):
    with path.open('rb') as source:
        magic, version, _ = struct.unpack('<III', source.read(12))
        size, kind = struct.unpack('<II', source.read(8))
        assert magic == 0x46546C67 and version == 2 and kind == 0x4E4F534A
        data = json.loads(source.read(size))
    return [dict(name=node.get('name', ''), source_name=node['extras']['source_name'],
                 source_map=node['extras'].get('source_map', ''),
                 source_visible=node['extras'].get('source_visible', True))
            for node in data['nodes'] if node.get('extras', {}).get('source_name')]


def minimal_fixture(manifest):
    fixtures = {}
    for slug, actors in manifest['maps'].items():
        fixtures[slug] = {'visual': [], 'collision': []}
        for actor in actors:
            for component in actor['components']:
                visible = (component['component_visibility'].get('bVisible', True)
                           and not component['component_visibility'].get('bHiddenInGame', False))
                for kind, names in [('visual', 'visual_node_names'), ('collision', 'collision_node_names')]:
                    for name in component[names]:
                        fixtures[slug][kind].append(dict(name=name, source_name=component['source_name'],
                                                        source_map=actor['source_map'], source_visible=visible))
        # Unrelated nodes exercise non-target preservation for both maps.
        for kind in ['visual', 'collision']:
            fixtures[slug][kind].append(dict(name='Unrelated', source_name='Unrelated.Component',
                                            source_map='Unrelated.umap', source_visible=True))
    return fixtures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--godot', type=Path)
    parser.add_argument('--source-assets', action='store_true')
    parser.add_argument('--out', type=Path, help='Optional JSON result; generated fixtures are not retained.')
    args = parser.parse_args()
    root = args.root.resolve()
    godot = args.godot or root / 'tools/godot/Godot_v4.7.2-stable_win64_console.exe'
    assert godot.is_file(), godot
    manifest = read_json(root / 'project/scripts/data/original-actor-initial-state.json')
    fixtures = minimal_fixture(manifest)
    if args.source_assets:
        for slug in fixtures:
            for kind, file in [('visual', 'world.glb'), ('collision', 'collision.glb')]:
                fixtures[slug][kind] = glb_nodes(root / f'project/assets/{slug}/{file}')
    with tempfile.TemporaryDirectory(prefix='actor-initial-cpu-') as temporary:
        project = Path(temporary)
        (project / 'project.godot').write_text(
            'config_version=5\n[application]\nconfig/name="ActorInitialStateCPU"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding='utf-8')
        for relative in ['scripts/original_actor_initial_state.gd',
                         'scripts/data/original-actor-initial-state.json', 'scripts/original_house.gd']:
            destination = project / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / 'project' / relative, destination)
        house_path = project / 'assets/environment/original-houses.json'
        house_path.parent.mkdir(parents=True, exist_ok=True)
        if args.source_assets:
            shutil.copy2(root / 'project/assets/environment/original-houses.json', house_path)
        else:
            house_path.write_text(json.dumps({'maps': {slug: {'inside_actors': [], 'outside_actors': []}
                                                     for slug in fixtures}}), encoding='utf-8')
        (project / 'fixtures.json').write_text(json.dumps(fixtures, ensure_ascii=False), encoding='utf-8')
        shutil.copy2(Path(__file__).with_suffix('.gd'), project / 'verify.gd')
        completed = subprocess.run([str(godot), '--headless', '--path', str(project),
                                    '--script', 'res://verify.gd'], capture_output=True, text=True,
                                   encoding='utf-8', errors='replace', timeout=90)
        result_path = project / 'result.json'
        if not result_path.exists():
            raise RuntimeError(completed.stdout + completed.stderr)
        result = read_json(result_path)
        result['fixture'] = 'all-local-source-nodes' if args.source_assets else 'minimal-tracked-metadata'
        result['gpu_test'] = False
        if args.out:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(result, ensure_ascii=False, indent=2))
        assert completed.returncode == 0 and result['passed'], completed.stderr


if __name__ == '__main__':
    main()
