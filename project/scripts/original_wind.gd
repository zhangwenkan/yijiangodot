extends Node
## Binds only source materials whose explicit UE switch "风吹效果" is enabled.
## Original painted vertex color is used as a movement mask, never as albedo.
## No mesh arrays or topology are modified here.

const SOURCE_PATH := "res://assets/environment/source-wind-materials.json"
const SHADER_PATH := "res://shaders/original_vegetation_wind.gdshader"
var report := {"mesh_surfaces": 0, "multimesh_surfaces": 0, "source_weight_surfaces": 0, "height_adapted_surfaces": 0, "instances": 0}
var _source: Dictionary = {}
var _materials: Dictionary = {}
var _shaders: Dictionary = {}

func setup(world: Node3D) -> Dictionary:
	_source = JSON.parse_string(FileAccess.get_file_as_string(SOURCE_PATH))
	for node in world.find_children("*", "GeometryInstance3D", true, false):
		if node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count():
				var material = node.get_active_material(surface)
				var adapted := _adapt(material, node.mesh, surface)
				if adapted != null:
					node.set_surface_override_material(surface, adapted)
					node.extra_cull_margin = maxf(node.extra_cull_margin, 0.20)
					report.mesh_surfaces += 1
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			var mesh: Mesh = node.multimesh.mesh
			for surface in mesh.get_surface_count():
				var adapted := _adapt(mesh.surface_get_material(surface), mesh, surface)
				if adapted != null:
					# The library meshes are source assets shared by identical instances.
					# Rebinding a material changes rendering only; geometry is untouched.
					mesh.surface_set_material(surface, adapted)
					node.extra_cull_margin = maxf(node.extra_cull_margin, 0.20)
					report.multimesh_surfaces += 1
					report.instances += node.multimesh.instance_count
	print("ORIGINAL_WIND_BOUND ", JSON.stringify(report))
	return report

func _adapt(material: Material, mesh: Mesh, surface: int) -> ShaderMaterial:
	if material is ShaderMaterial and material.has_meta("source_wind_adapter"):
		return material
	if not material is StandardMaterial3D or not _source.has(material.resource_name):
		return null
	var key := "%s:%d:%d" % [material.resource_name, mesh.get_instance_id(), surface]
	if _materials.has(key):
		return _materials[key]
	var base := material as StandardMaterial3D
	var source: Dictionary = _source[base.resource_name]
	var scalar: Dictionary = source.get("scalars", {})
	var weighted := bool(mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR)
	var bounds := mesh.get_aabb()
	var mat := ShaderMaterial.new()
	mat.resource_name = base.resource_name
	mat.shader = _shader(base.cull_mode, base.texture_filter)
	mat.set_shader_parameter("albedo_texture", base.albedo_texture)
	mat.set_shader_parameter("albedo_texture_enabled", base.albedo_texture != null)
	mat.set_shader_parameter("uv_scale", Vector2(base.uv1_scale.x, base.uv1_scale.y))
	mat.set_shader_parameter("uv_offset", Vector2(base.uv1_offset.x, base.uv1_offset.y))
	mat.set_shader_parameter("albedo_color", base.albedo_color)
	mat.set_shader_parameter("normal_texture", base.normal_texture)
	mat.set_shader_parameter("normal_enabled", base.normal_enabled)
	mat.set_shader_parameter("normal_scale", base.normal_scale)
	mat.set_shader_parameter("roughness_value", base.roughness)
	mat.set_shader_parameter("metallic_value", base.metallic)
	mat.set_shader_parameter("specular_value", base.metallic_specular)
	mat.set_shader_parameter("masked", base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)
	mat.set_shader_parameter("alpha_clip", base.alpha_scissor_threshold)
	mat.set_shader_parameter("source_vertex_weights", weighted)
	mat.set_shader_parameter("root_height", bounds.position.y)
	mat.set_shader_parameter("canopy_height", bounds.end.y)
	mat.set_shader_parameter("wind_intensity", float(scalar.get("WindIntensity", 0.1)))
	mat.set_shader_parameter("wind_speed", float(scalar.get("WindSpeed", 0.4)))
	mat.set_shader_parameter("vertex_color_power", float(scalar.get("VertexColorPow", 1.0)))
	mat.set_shader_parameter("wind_distance_limit", float(scalar.get("WindDistanceLimit", 5000.0)) * 0.01)
	mat.set_meta("source_material", source.source_material_key)
	mat.set_meta("source_wind_adapter", true)
	mat.set_meta("fidelity", "source wind switch, intensity/speed/power and painted weights; adapted waveform; unpainted grass uses height anchoring")
	_materials[key] = mat
	if weighted:
		report.source_weight_surfaces += 1
	else:
		report.height_adapted_surfaces += 1
	return mat

func _shader(cull: int, filtering: int) -> Shader:
	var key := "%d:%d" % [cull, filtering]
	if _shaders.has(key):
		return _shaders[key]
	var shader := Shader.new()
	var code := FileAccess.get_file_as_string(SHADER_PATH)
	if cull == BaseMaterial3D.CULL_BACK:
		code = code.replace("cull_disabled", "cull_back")
	elif cull == BaseMaterial3D.CULL_FRONT:
		code = code.replace("cull_disabled", "cull_front")
	if filtering in [BaseMaterial3D.TEXTURE_FILTER_NEAREST, BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS, BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC]:
		code = code.replace("filter_linear_mipmap_anisotropic", "filter_nearest_mipmap_anisotropic")
	shader.code = code
	_shaders[key] = shader
	return shader
