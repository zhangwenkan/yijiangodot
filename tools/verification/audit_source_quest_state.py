"""Read-only audit of the inspected Shipping binary and isolated viewer saves.

Does not launch the game, rewrite saves, or implement gameplay. Native addresses
are valid only for the exact SHA below. Only empty QuestProgracessData arrays are
supported, as found in these viewer saves; unknown layouts fail explicitly.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import zlib

EXE_SHA = '8c3928aea470b45aff2050ffe1034306122f2ed221a43875f20ef1e61b274df8'
STEP_NAMES = {0: 'None', 1: 'Requested', 2: 'Faild', 3: 'UnRequest', 4: 'Finished'}
NATIVE_CHAIN = {
    'PreQuest_branch': '0x140f7e4b0',
    'CheckRequirement': '0x140f7d5b0',
    'HasQuest_branch': '0x140f7d663',
    'HasQuest': '0x141257780',
    'QuestManager_accessor': '0x140f89b20',
    'QuestManager_class': '0x14136ce00',
    'GetQuestStep_reflection_thunk': '0x1413702d0',
    'GetQuestStep': '0x141252500',
    'FindQuestSpec': '0x1412523f0',
    'QuestSpec_struct_ops': '0x1444b9888',
    'QuestSpec_serialize_thunk': '0x141373c30',
    'QuestSpec_serializer': '0x141225d90',
    'QuestProgracessData_array_serializer': '0x1411fc940',
    'VisibleComponent_apply_thunk': '0x1413892c0',
    'VisibleComponent_apply': '0x140f9fa70',
    'VisibleComponent_visibility_action': '0x140fc4a70',
    'SetActorHiddenInGame_reflection_thunk': '0x143555930',
    'SetActorEnableCollision_reflection_thunk': '0x1435558a0',
    'SetActorEnableCollision': '0x142d25010',
}


def fstring(data, pos):
    count = struct.unpack_from('<i', data, pos)[0]
    assert 0 < abs(count) < 1_000_000
    end = pos + 4 + abs(count) * (2 if count < 0 else 1)
    assert end <= len(data)
    return data[pos + 4:end].decode('utf-16-le' if count < 0 else 'utf-8').rstrip('\0'), end


def native_evidence(path):
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == EXE_SHA, 'Unsupported Shipping executable; addresses must be re-audited.'
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe + 4] == b'PE\0\0'
    count = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    base = struct.unpack_from('<Q', data, pe + 48)[0]
    sections = [struct.unpack_from('<IIII', data, pe + 24 + optional_size + i * 40 + 8)
                for i in range(count)]

    def offset(address):
        target = address - base
        for _, rva, size, raw in sections:
            if rva <= target < rva + size:
                return raw + target - rva
        raise ValueError(hex(address))

    def string(address):
        at = offset(address)
        return data[at:data.index(b'\0', at)].decode('ascii')

    enum = {}
    for i in range(5):
        pointer, value = struct.unpack_from('<QQ', data, offset(0x1444b97b0 + 16 * i))
        enum[value] = string(pointer)
    assert enum == {key: 'EQuestStep::' + name for key, name in STEP_NAMES.items()}, enum
    pointer, value = struct.unpack_from('<QQ', data, offset(0x1444b9a00))
    assert string(pointer) == 'ERequirementType::PreQuest' and value == 4
    # UE reflected property offsets substantiate compact archive field order.
    fields = {}
    for descriptor in [0x1444b7dd8, 0x1444b7e30, 0x1444b7e90, 0x1444b7ef0, 0x1444b7f18]:
        at = offset(descriptor)
        name = string(struct.unpack_from('<Q', data, at)[0])
        fields[name] = struct.unpack_from('<I', data, at + 36)[0]
    assert fields == {'QuestId': 0, 'Step': 4, 'QuestProgracessData': 8, 'RequestTime': 32, 'FinishTime': 36}, fields
    return {'exe_sha256': EXE_SHA, 'EQuestStep': enum, 'PreQuest_enum_value': value,
            'QuestSpec_native_field_offsets': fields, 'static_disassembly_chain': NATIVE_CHAIN,
            'basis': 'Reviewed static disassembly of the exact executable; this tool verifies identity and reflected metadata.'}


def quest_payload(path):
    packed = path.read_bytes()
    version, raw_size, zipped_size = struct.unpack_from('<III', packed)
    assert version in (12, 14) and zipped_size == len(packed) - 12
    raw = zlib.decompress(packed[12:])
    assert len(raw) == raw_size and raw[:4] == b'GVAS'
    _, pos = fstring(raw, 22)
    _, custom_count = struct.unpack_from('<ii', raw, pos)
    _, pos = fstring(raw, pos + 8 + custom_count * 20)
    if struct.unpack_from('<I', raw, pos)[0] == 0:
        pos += 4
    found = None
    while True:
        name, pos = fstring(raw, pos)
        if name == 'None':
            break
        kind, pos = fstring(raw, pos)
        size, _ = struct.unpack_from('<ii', raw, pos)
        pos += 8
        inner = None
        if kind == 'StructProperty':
            _, pos = fstring(raw, pos)
            pos += 16
        elif kind in ('ArrayProperty', 'SetProperty', 'EnumProperty', 'ByteProperty'):
            inner, pos = fstring(raw, pos)
        elif kind == 'MapProperty':
            _, pos = fstring(raw, pos)
            _, pos = fstring(raw, pos)
        elif kind == 'BoolProperty':
            pos += 1
        has_guid = raw[pos]
        assert has_guid in (0, 1)
        pos += 1 + 16 * has_guid
        assert pos + size <= len(raw)
        if name == 'Quests':
            assert found is None and kind == 'ArrayProperty' and inner == 'StructProperty'
            found = raw[pos:pos + size]
        pos += size
    assert found is not None
    return packed, found


def parse_quests(payload):
    count = struct.unpack_from('<i', payload)[0]
    name, pos = fstring(payload, 4)
    kind, pos = fstring(payload, pos)
    size, index = struct.unpack_from('<ii', payload, pos)
    struct_name, pos = fstring(payload, pos + 8)
    assert name == 'Quests' and kind == 'StructProperty' and struct_name == 'QuestSpec' and index == 0
    assert payload[pos:pos + 17] == bytes(17)
    pos += 17
    assert len(payload) - pos == size and size == count * 17
    entries = []
    for _ in range(count):
        quest_id, step, progress_count, request_time, finish_time = struct.unpack_from('<iBiii', payload, pos)
        assert progress_count == 0, 'Nested quest progress is outside this viewer-save audit.'
        assert step in STEP_NAMES
        entries.append({'QuestId': quest_id, 'Step': step, 'StepName': STEP_NAMES[step],
                        'QuestProgracessData_count': progress_count,
                        'RequestTime': request_time, 'FinishTime': finish_time})
        pos += 17
    assert pos == len(payload) and len({entry['QuestId'] for entry in entries}) == count
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--save', type=Path, nargs='+', required=True)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    result = {'native': native_evidence(args.exe), 'saves': []}
    for path in args.save:
        packed, payload = quest_payload(path)
        entries = parse_quests(payload)
        steps = {row['QuestId']: row['Step'] for row in entries}
        result['saves'].append({'label': path.parent.parent.name, 'sha256': hashlib.sha256(packed).hexdigest(),
            'count': len(entries), 'quests': entries,
            'dock_requirements': {str(q): {'stored': q in steps, 'GetQuestStep': steps.get(q, 0),
                'PreQuest_Num4': steps.get(q, 0) == 4} for q in (28967, 28968)}})
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
