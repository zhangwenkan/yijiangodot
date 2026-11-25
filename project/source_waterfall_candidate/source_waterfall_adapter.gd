extends Node
## Restore MI_Waterfall2 on the two original Wuming components; no mesh mutation.
## Install after ordinary surface material binding and before light functions/source renderer.
const SHADER_PATH := "res://source_waterfall_candidate/source_waterfall.gdshader"
const TEXTURE_DIR := "res://assets/environment/waterfall/"
const NAMES := ["S_7334_StaticMeshComponent0_0_0", "S_7335_StaticMeshComponent0_0_0"]
const MATERIAL_NAME := "MAT_788050a6abf1"
var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _material: ShaderMaterial

func install(world: Node, options: Dictionary = {}) -> Dictionary:
	if not _saved.is_empty(): return {"error":"Already installed; restore first."}
	if not is_instance_valid(world): return {"error":"Missing world."}
	var shader := load(SHADER_PATH) as Shader
	var diffuse := load(TEXTURE_DIR + "T_Water_D_native.dds") as Texture2D
	var normal := load(TEXTURE_DIR + "T_Water_N_native.dds") as Texture2D
	if shader == null or diffuse == null or normal == null: return {"error":"Missing recovered waterfall resources."}
	_material = ShaderMaterial.new()
	_material.resource_name = MATERIAL_NAME
	_material.shader = shader
	_material.set_shader_parameter("source_water_d", diffuse)
	_material.set_shader_parameter("source_water_n", normal)
	_material.set_shader_parameter("source_time_override", float(options.get("time_override", -1.0)))
	_material.set_shader_parameter("source_displacement_enabled", bool(options.get("displacement_enabled", true)))
	_material.set_meta("source_material", "/Game/JH/MapEditor/Environment/Ocean/Materials/MI_Waterfall2.MI_Waterfall2")
	_material.set_meta("source_surface_adapter", true)
	_material.set_meta("source_unshaded", false)
	_material.set_meta("source_waterfall_compiled", true)
	_material.set_meta("source_surface_family", "M_Waterfall")
	_material.set_meta("source_surface_formula", "DXBC PS63033 VS124491 DS61684 and frozen MI_Waterfall2 uniforms")
	report = {"bound_surfaces":0, "nodes":[], "unsupported":[], "geometry_unchanged":true,
		"vertex_animation":bool(options.get("displacement_enabled",true)),
		"native_pn_tessellation":false,
		"limits":["Existing imported vertices only; native PN triangle subdivision is not generated.",
			"Lighting uses existing Godot light function/cone, source SH9 and fog adapters; native Surface TLV is not restored.",
			"Source glTF and current GLB omit vertex colors; normal default white vertex alpha is used.",
			"Current GLB lacks source tangent accessor; shader recovers UV basis from derivatives.",
			"Native responsive TAA flag and original engine translucency compositor are not reproduced."]}
	for node in world.find_children("*", "MeshInstance3D", true, false):
		if not NAMES.has(str(node.name)) or node.mesh == null: continue
		if node.material_override != null:
			report.unsupported.append({"node":str(node.name),"reason":"Unexpected whole-mesh material_override."})
			continue
		for surface in node.mesh.get_surface_count():
			var active: Material = node.get_active_material(surface)
			if active == null or active.resource_name != MATERIAL_NAME: continue
			var previous: Material = node.get_surface_override_material(surface)
			_saved.append({"node":node,"surface":surface,"previous":previous,"mesh":node.mesh,"transform":node.transform})
			node.set_surface_override_material(surface, _material)
			report.nodes.append({"node":str(node.name),"surface":surface,
				"vertices":node.mesh.surface_get_array_len(surface),
				"indices":node.mesh.surface_get_array_index_len(surface),
				"geometry_resource_id":node.mesh.get_instance_id(),
				"old_material":active.resource_name})
			report.bound_surfaces += 1
	report.status = "installed" if report.bound_surfaces == 2 else "partial_or_not_wuming"
	print("SOURCE_WATERFALL_BOUND ",JSON.stringify(report))
	return report

func set_audit_time(value: float) -> void:
	if is_instance_valid(_material): _material.set_shader_parameter("source_time_override", value)

func set_audit_view(value: int) -> void:
	if is_instance_valid(_material): _material.set_shader_parameter("audit_view", value)

func set_displacement_enabled(value: bool) -> void:
	if is_instance_valid(_material): _material.set_shader_parameter("source_displacement_enabled",value)

func restored_material() -> ShaderMaterial:
	return _material

func restore() -> Dictionary:
	var restored := 0
	var errors: Array[String] = []
	for state in _saved:
		if not is_instance_valid(state.node): continue
		if state.node.mesh != state.mesh or state.node.transform != state.transform:
			errors.append("Unexpected geometry/transform change: " + str(state.node.name))
		if state.node.get_surface_override_material(state.surface) != _material:
			errors.append("Another material owner replaced waterfall; restore it first.")
			continue
		state.node.set_surface_override_material(state.surface, state.previous)
		restored += 1
	if errors.is_empty(): _saved.clear()
	return {"restored_surfaces":restored,"errors":errors}

func _exit_tree() -> void:
	restore()

