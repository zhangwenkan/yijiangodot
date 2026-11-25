extends Node
## Reversible source material restore for four existing original bagua surfaces.
## Install after original_surface and before light functions/source rendering.
const SHADER_PATH := "res://source_bagua_candidate/source_bagua.gdshader"
const TEXTURE_DIR := "res://assets/environment/bagua/"
const NAMES := ["S_6254_StaticMeshComponent0_0_0","S_6255_StaticMeshComponent0_0_0","S_6256_StaticMeshComponent0_0_0","S_6257_StaticMeshComponent0_0_0"]
const MATERIAL_NAME := "MAT_ae65b59bea11"
var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _material: ShaderMaterial

func install(world: Node, options: Dictionary = {}) -> Dictionary:
	if not _saved.is_empty(): return {"error":"Already installed; restore first."}
	if not is_instance_valid(world): return {"error":"Missing world."}
	var shader := load(SHADER_PATH) as Shader
	if shader==null: return {"error":"Missing recovered bagua shader."}
	_material=ShaderMaterial.new()
	_material.resource_name=MATERIAL_NAME
	_material.shader=shader
	for pair in [["source_small_normal","T_SmallWaves_N"],["source_large_normal","T_LargeWaves_N"],["source_large_height","T_LargeWaves_H"],["source_foam","T_Seafoam_01"]]:
		var texture := load(TEXTURE_DIR+pair[1]+"_native.dds") as Texture2D
		if texture==null: return {"error":"Missing original bagua texture "+pair[1]}
		_material.set_shader_parameter(pair[0],texture)
	_material.set_shader_parameter("source_time_override",float(options.get("time_override",-1.0)))
	_material.set_meta("source_material","/Game/JH/MapEditor/Environment/Ocean/Materials/M_OceanWater_1_Inst1.M_OceanWater_1_Inst1")
	_material.set_meta("source_surface_adapter",true)
	_material.set_meta("source_unshaded",false)
	_material.set_meta("source_bagua_compiled",true)
	_material.set_meta("source_surface_family","M_OceanWater_1")
	_material.set_meta("source_surface_formula","DXBC PS29196; original four-way waves/foam and opaque surface inputs")
	report={"bound_surfaces":0,"nodes":[],"unsupported":[],"geometry_unchanged":true,
		"opaque":true,"source_displacement_active":false,
		"limits":["Godot BRDF and existing source lighting adapters remain cross-engine approximations.",
			"Source glTF tangents are absent from imported GLB; shader uses UV derivative basis.",
			"Source visibility flags are restored; camera pixel visibility still depends on occlusion."]}
	for node in world.find_children("*","MeshInstance3D",true,false):
		if not NAMES.has(str(node.name)) or node.mesh==null: continue
		if node.material_override!=null:
			report.unsupported.append({"node":str(node.name),"reason":"Unexpected whole-mesh material override."})
			continue
		for surface in node.mesh.get_surface_count():
			var active: Material=node.get_active_material(surface)
			if active==null or active.resource_name!=MATERIAL_NAME: continue
			_saved.append({"node":node,"surface":surface,"previous":node.get_surface_override_material(surface),"mesh":node.mesh,"transform":node.transform})
			node.set_surface_override_material(surface,_material)
			report.nodes.append({"node":str(node.name),"surface":surface,
				"vertices":node.mesh.surface_get_array_len(surface),"indices":node.mesh.surface_get_array_index_len(surface)})
			report.bound_surfaces+=1
	report.status="installed" if report.bound_surfaces==4 else "partial_or_not_wuming"
	print("SOURCE_BAGUA_BOUND ",JSON.stringify(report))
	return report

func set_audit_time(value: float) -> void:
	if is_instance_valid(_material): _material.set_shader_parameter("source_time_override",value)
func set_audit_view(value: int) -> void:
	if is_instance_valid(_material): _material.set_shader_parameter("audit_view",value)
func restored_material() -> ShaderMaterial:
	return _material

func restore() -> Dictionary:
	var restored:=0
	var errors: Array[String]=[]
	for state in _saved:
		if not is_instance_valid(state.node): continue
		if state.node.mesh!=state.mesh or state.node.transform!=state.transform:
			errors.append("Unexpected geometry/transform change: "+str(state.node.name))
		if state.node.get_surface_override_material(state.surface)!=_material:
			errors.append("Another material owner replaced bagua; restore it first.")
			continue
		state.node.set_surface_override_material(state.surface,state.previous)
		restored+=1
	if errors.is_empty(): _saved.clear()
	return {"restored_surfaces":restored,"errors":errors}

func _exit_tree() -> void:
	restore()

