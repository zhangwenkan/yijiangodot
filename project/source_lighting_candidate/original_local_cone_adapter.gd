extends RefCounted
## Install AFTER other material adapters; restore BEFORE them (reverse order).
## Only materials using original_lightfunction_receiving.gdshaderinc are touched.

const RECEIVING := "res://shaders/original_lightfunction_receiving.gdshaderinc"
const INCLUDE_LINE := '#include "res://shaders/original_lightfunction_receiving.gdshaderinc"'
const OLD_RADIANCE := "vec3 radiance=LIGHT_COLOR*ATTENUATION*light_function;"

var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _seen: Dictionary = {}
var _cache: Dictionary = {}
var _positions := PackedVector4Array()
var _directions := PackedVector4Array()
var _parameters := PackedVector4Array()
var _receiving := ""

func apply(world: Node) -> Dictionary:
	restore()
	report = {"bound": 0, "lights": [], "unsupported": [], "limits": [
		"Godot light() exposes no light ID; original lights are identified by world ray.",
		"Positions/directions must remain static after binding; house visibility changes are supported.",
		"Point radius, capsule shape, near-field integration and shadow filtering remain separate."]}
	_positions.resize(64)
	_directions.resize(64)
	_parameters.resize(64)
	var count := 0
	for light in world.find_children("*", "Light3D", true, false):
		if not (light is OmniLight3D or light is SpotLight3D) or not light.has_meta("ue_properties"):
			continue
		if count >= 64:
			report.unsupported.append("More than64 local lights; capacity exceeded.")
			return report
		var properties: Dictionary = light.get_meta("ue_properties")
		var is_spot: bool = light is SpotLight3D
		var position: Vector3 = light.global_position
		_positions[count] = Vector4(position.x, position.y, position.z, 1.0 if is_spot else 0.0)
		if is_spot:
			var inner := deg_to_rad(clampf(float(properties.get("InnerConeAngle", 0.0)), 0.0, 89.0))
			var outer := clampf(deg_to_rad(float(properties.get("OuterConeAngle", 44.0))), inner + 0.001, 1.5543431043624878)
			var direction: Vector3 = -light.global_basis.z.normalized()
			_directions[count] = Vector4(direction.x, direction.y, direction.z, cos(outer))
			_parameters[count] = Vector4(1.0 / (cos(inner) - cos(outer)), cos(deg_to_rad(light.spot_angle)), light.spot_angle_attenuation, 0.0)
			if absf(rad_to_deg(outer) - light.spot_angle) > 0.001:
				report.unsupported.append({"name":str(light.name), "reason":"Source and target outer angles differ; target culling may remove source contributions."})
		report.lights.append({"name":str(light.get_meta("source_name", light.name)), "spot":is_spot, "position":position})
		count += 1
	report["local_count"] = count
	var library_path: String = get_script().resource_path.get_base_dir().path_join("original_local_cone.gdshaderinc")
	var library := FileAccess.get_file_as_string(library_path)
	_receiving = FileAccess.get_file_as_string(RECEIVING)
	if library.is_empty() or not _receiving.contains(OLD_RADIANCE) or not _receiving.contains("void light() {"):
		report.unsupported.append("Source receiving/library layout missing; no material modified.")
		return report
	_receiving = _receiving.replace("void light() {", library + "\nvoid light() {")
	_receiving = _receiving.replace(OLD_RADIANCE,
		"float source_cone_factor = LIGHT_IS_DIRECTIONAL ? 1.0 : source_local_cone_correction(source_lf_fragment_world, normalize((INV_VIEW_MATRIX * vec4(LIGHT,0.0)).xyz));\n    vec3 radiance=LIGHT_COLOR*ATTENUATION*light_function*source_cone_factor;")
	_visit(world)
	return report

func _visit(node: Node) -> void:
	if node is GeometryInstance3D:
		_bind(node.material_override)
		_bind(node.material_overlay)
	if node is MeshInstance3D and node.mesh != null and node.material_override == null:
		for surface in node.mesh.get_surface_count():
			_bind(node.get_active_material(surface))
	if node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null and node.material_override == null:
		for surface in node.multimesh.mesh.get_surface_count():
			_bind(node.multimesh.mesh.surface_get_material(surface))
	for child in node.get_children():
		_visit(child)

func _bind(material: Material) -> void:
	if material == null or _seen.has(material.get_instance_id()):
		return
	_seen[material.get_instance_id()] = true
	_bind(material.next_pass)
	if not material is ShaderMaterial or material.shader == null:
		return
	var original: Shader = material.shader
	if not original.code.contains(INCLUDE_LINE):
		return
	var parameters: Dictionary = {}
	for item in original.get_shader_uniform_list():
		parameters[item.name] = material.get_shader_parameter(item.name)
	if not _cache.has(original.get_instance_id()):
		var shader := Shader.new()
		shader.code = original.code.replace(INCLUDE_LINE, _receiving)
		_cache[original.get_instance_id()] = shader
	_saved.append({"object":material, "shader":original, "parameters":parameters})
	material.shader = _cache[original.get_instance_id()]
	for name in parameters:
		material.set_shader_parameter(name, parameters[name])
	material.set_shader_parameter("source_local_cone_count", int(report.local_count))
	material.set_shader_parameter("source_local_cone_position_kind", _positions)
	material.set_shader_parameter("source_local_cone_direction_outer", _directions)
	material.set_shader_parameter("source_local_cone_parameters", _parameters)
	report.bound += 1

func restore() -> Dictionary:
	var restored := 0
	var errors: Array[String] = []
	for state in _saved:
		if not is_instance_valid(state.object):
			continue
		var material: ShaderMaterial = state.object
		material.shader = state.shader
		for name in state.parameters:
			material.set_shader_parameter(name, state.parameters[name])
			if material.get_shader_parameter(name) != state.parameters[name]:
				errors.append("Parameter restore mismatch: " + str(name))
		restored += 1
	_saved.clear()
	_seen.clear()
	_cache.clear()
	return {"restored_materials":restored, "errors":errors}
