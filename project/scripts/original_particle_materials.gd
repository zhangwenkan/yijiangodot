extends Node
## Source material correction only. OriginalCascade emitter timing, transforms and draws are retained.
const POLICY := "res://assets/environment/particles/native_transparent/policies.json"
const EMISSIVE := preload("res://shaders/original_particle_emissive.gdshader")
const SMOKE := preload("res://shaders/original_particle_smoke_tiled.gdshader")
var coverage: Dictionary = {}
var _materials: Array[ShaderMaterial] = []
var _additive_shader: Shader

func setup(particle_driver: Node) -> Dictionary:
	coverage = {"bound_emitters": 0, "families": {}, "unmatched_source_materials": [], "lighting_limit": "Smoke1_Mat, M_smoke_subUV and M_water_splash directional TLV remain adapted"}
	_materials.clear()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(POLICY))
	if not parsed is Dictionary:
		push_error("Original particle material policy is missing.")
		return coverage
	var policies: Dictionary = parsed["materials"]
	var emitters: Array = particle_driver.get("_emitters")
	for emitter in emitters:
		var key := str(emitter.data["material"])
		if not policies.has(key):
			continue
		var policy: Dictionary = policies[key]
		var old: ShaderMaterial = emitter.draw.material_override
		if old == null:
			coverage["unmatched_source_materials"].append(key)
			continue
		var material := ShaderMaterial.new()
		if int(policy["mode"]) == 4:
			material.shader = SMOKE
		elif bool(policy.get("additive", false)):
			if _additive_shader == null:
				_additive_shader = Shader.new()
				_additive_shader.code = EMISSIVE.code.replace("blend_mix", "blend_add")
			material.shader = _additive_shader
		else:
			material.shader = EMISSIVE
		for uniform_name in ["atlas", "pivot", "billboard", "lock_vertical", "source_alignment", "source_lock_axis", "source_direction_data"]:
			var value = old.get_shader_parameter(uniform_name)
			if value != null:
				material.set_shader_parameter(uniform_name, value)
		material.set_shader_parameter("material_mode", int(policy["mode"]))
		material.set_shader_parameter("source_depth_fade_cm", float(policy.get("depth_fade_cm", 100.0)))
		material.set_shader_parameter("source_emission", float(policy.get("emission", 1.0)))
		for uniform_name in ["source_texture", "source_tiled"]:
			if policy.has(uniform_name):
				material.set_shader_parameter(uniform_name, load(str(policy[uniform_name])))
		material.set_meta("source_material", key)
		material.set_meta("source_family", str(policy["family"]))
		material.set_meta("source_particle_native_material", true)
		material.set_meta("source_translucency_lighting", "TLM_VolumetricDirectional adapted" if int(policy["mode"]) == 4 else "source main-view unlit/emission")
		emitter.draw.material_override = material
		_materials.append(material)
		coverage["bound_emitters"] += 1
		var family := str(policy["family"])
		coverage["families"][family] = int(coverage["families"].get(family, 0)) + 1
	print("Original particle material correction: ", JSON.stringify(coverage))
	return coverage

func set_audit_mode(mode: int) -> void:
	for material in _materials:
		material.set_shader_parameter("audit_mode", mode)
