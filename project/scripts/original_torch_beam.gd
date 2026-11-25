extends Node3D
## One source Beam2 emitter; all mesh geometry is imported from Blender MCP.
const CONFIG := "res://assets/environment/particles/torch_beam/source.json"
const DRAW := "res://assets/environment/particles/torch_beam/original_torch_beam.glb"
const SHADER := preload("res://shaders/original_torch_beam.gdshader")
var coverage: Dictionary = {}
var _generated: Node3D
var _materials: Array[ShaderMaterial] = []

func setup(slug: String, world: Node3D) -> Dictionary:
	shutdown()
	coverage = {"map": slug, "source_beam_components": 0, "bound_beam_emitters": 0, "source_geometry": "Blender MCP: 22 vertices / 20 triangles", "material": "cooked PS151428 source emission, alpha, flipbook and UV distortion", "screen_distortion": false, "native_reflection_capture_tlv": "not_reproduced"}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	if not parsed is Dictionary:
		push_error("Original TorchFire Beam2 source data is missing.")
		return coverage
	var components: Array = parsed.get("maps", {}).get(slug, [])
	coverage["source_beam_components"] = components.size()
	if components.is_empty():
		return coverage
	var packed: PackedScene = load(DRAW)
	if packed == null:
		push_error("Original TorchFire Beam2 Blender mesh is missing.")
		return coverage
	_generated = Node3D.new()
	_generated.name = "OriginalTorchBeam_" + slug
	world.add_child(_generated)
	var cb := PackedVector4Array()
	for row in parsed["material_cb"]:
		cb.append(Vector4(float(row[0]), float(row[1]), float(row[2]), float(row[3])))
	for component in components:
		var instance: Node3D = packed.instantiate()
		instance.name = "TorchFire_Beam_PS_HuoBa_12"
		instance.position = Vector3(component["origin_m"][0], component["origin_m"][1], component["origin_m"][2])
		instance.set_meta("source_component", component["source"])
		instance.set_meta("source_emitter", "PS_HuoBa.ParticleSpriteEmitter_10")
		_generated.add_child(instance)
		var material := ShaderMaterial.new()
		material.shader = SHADER
		material.set_shader_parameter("source_cb", cb)
		material.set_shader_parameter("source_flame", load("res://assets/environment/particles/torch_beam/Torchfire_D_native.dds"))
		material.set_shader_parameter("source_noise", load("res://assets/environment/particles/torch_beam/disort_test_native.dds"))
		material.set_shader_parameter("source_gradient", load("res://assets/environment/particles/torch_beam/Gradient_Tex_native.dds"))
		material.set_meta("source_material", "/Game/JH/Particles/Fire/Materials/TorchFire_S_Inst.TorchFire_S_Inst")
		material.set_meta("source_family", "Seq_Disort_Mat_test")
		for node in instance.find_children("*", "MeshInstance3D", true, false):
			node.material_override = material
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			node.extra_cull_margin = 0.3
		_materials.append(material)
		coverage["bound_beam_emitters"] += 1
	print("Original Beam2 adapter: ", JSON.stringify(coverage))
	return coverage

func set_audit_mode(mode: int, source_time := -1.0) -> void:
	for material in _materials:
		material.set_shader_parameter("audit_mode", mode)
		material.set_shader_parameter("source_time_override", source_time)

func shutdown() -> void:
	_materials.clear()
	if is_instance_valid(_generated):
		_generated.queue_free()
	_generated = null
