extends Node
## Bind recovered surface expressions after effect/wind drivers and before light functions.
## No mesh arrays, normals, UVs, positions or topology are modified.

const SOURCE_PATH := "res://assets/environment/source-surface-materials.json"
const SHADER_PATH := "res://shaders/original_surface.gdshader"
var report := {"converted": 0, "source_formulas": 0, "wind_repaired": 0, "existing_shaders": 0, "unresolved_materials": 0}
var _source: Dictionary = {}
var _materials: Dictionary = {}
var _shaders: Dictionary = {}
var _textures: Dictionary = {}
var _patched_wind: Dictionary = {}

func setup(world: Node3D) -> Dictionary:
	_source = JSON.parse_string(FileAccess.get_file_as_string(SOURCE_PATH))
	for node in world.find_children("*", "GeometryInstance3D", true, false):
		if node.material_override != null:
			var override_material := _adapt(node.material_override)
			if override_material != null:
				node.material_override = override_material
			continue
		if node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count():
				var adapted := _adapt(node.get_active_material(surface))
				if adapted != null:
					node.set_surface_override_material(surface, adapted)
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			var mesh: Mesh = node.multimesh.mesh
			for surface in mesh.get_surface_count():
				var adapted := _adapt(mesh.surface_get_material(surface))
				if adapted != null:
					mesh.surface_set_material(surface, adapted)
	print("ORIGINAL_SURFACE_BOUND ", JSON.stringify(report))
	return report

func _adapt(material: Material) -> ShaderMaterial:
	if material is ShaderMaterial:
		if material.has_meta("source_wind_adapter"):
			_repair_wind(material)
		else:
			report.existing_shaders += 1
		return null
	if not material is StandardMaterial3D:
		return null
	var key := material.get_instance_id()
	if _materials.has(key):
		return _materials[key]
	var base := material as StandardMaterial3D
	var source: Dictionary = _source.get(base.resource_name, {})
	if int(source.get("mode", 0)) == 6:
		var crystal := _crystal_material(base, source)
		_materials[key] = crystal
		report.converted += 1
		report.source_formulas += 1
		return crystal
	var mat := ShaderMaterial.new()
	mat.resource_name = base.resource_name
	mat.render_priority = base.render_priority
	mat.next_pass = base.next_pass
	mat.shader = _shader(base, source)
	for meta_key in base.get_meta_list():
		mat.set_meta(meta_key, base.get_meta(meta_key))
	mat.set_shader_parameter("albedo_texture", base.albedo_texture)
	mat.set_shader_parameter("albedo_texture_enabled", base.albedo_texture != null)
	mat.set_shader_parameter("albedo_color", base.albedo_color)
	mat.set_shader_parameter("uv_scale", Vector2(base.uv1_scale.x, base.uv1_scale.y))
	mat.set_shader_parameter("uv_offset", Vector2(base.uv1_offset.x, base.uv1_offset.y))
	mat.set_shader_parameter("vertex_color_albedo", base.vertex_color_use_as_albedo)
	mat.set_shader_parameter("normal_texture", base.normal_texture)
	mat.set_shader_parameter("normal_enabled", base.normal_enabled)
	mat.set_shader_parameter("normal_scale", base.normal_scale)
	mat.set_shader_parameter("roughness_value", base.roughness)
	mat.set_shader_parameter("metallic_value", base.metallic)
	mat.set_shader_parameter("specular_value", base.metallic_specular)
	mat.set_shader_parameter("alpha_clip", base.alpha_scissor_threshold)
	if base.emission_enabled:
		mat.set_shader_parameter("emission_color", base.emission)
		mat.set_shader_parameter("emission_texture", base.emission_texture)
		mat.set_shader_parameter("emission_texture_enabled", base.emission_texture != null)
		mat.set_shader_parameter("emission_energy", base.emission_energy_multiplier)
		mat.set_shader_parameter("emission_multiply", base.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY)
	mat.set_meta("source_unshaded", base.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED)
	mat.set_meta("source_surface_adapter", true)
	if not source.is_empty():
		_apply_source(mat, source)
		report.source_formulas += 1
	else:
		# Other families retain the imported surface; no guessed source parameters.
		report.unresolved_materials += 1
	_materials[key] = mat
	report.converted += 1
	return mat

func _repair_wind(mat: ShaderMaterial) -> void:
	var id := mat.get_instance_id()
	if _patched_wind.has(id):
		return
	_patched_wind[id] = true
	var material_name := mat.resource_name.trim_prefix("SourceWind_")
	mat.resource_name = material_name
	if _source.has(material_name):
		_apply_source(mat, _source[material_name])
		report.wind_repaired += 1

func _apply_source(mat: ShaderMaterial, source: Dictionary) -> void:
	mat.set_shader_parameter("source_surface_mode", int(source.mode))
	for parameter in ["roughness_value", "metallic_value", "specular_value", "color_saturation", "color_power", "source_opacity", "normal_flatten"]:
		mat.set_shader_parameter(parameter, float(source.get(parameter, 0.0)))
	for parameter in source.get("textures", {}):
		mat.set_shader_parameter(parameter, _texture(str(source.textures[parameter].path)))
	mat.set_shader_parameter("source_emission_enabled", bool(source.get("emission_enabled", false)))
	if source.get("emission_enabled", false):
		var color: Array = source.source_emission_color
		mat.set_shader_parameter("source_emission_color", Vector3(float(color[0]), float(color[1]), float(color[2])))
		mat.set_shader_parameter("source_emission_strength", float(source.source_emission_strength))
	if int(source.mode) >= 4:
		# Native small surfaces: linear vector parameters, independent original mip chains.
		var tint: Array = source.source_diffuse_tint
		mat.set_shader_parameter("source_diffuse_tint", Vector3(float(tint[0]), float(tint[1]), float(tint[2])))
		mat.set_shader_parameter("alpha_clip", float(source.source_alpha_clip))
		mat.set_shader_parameter("normal_enabled", false)
		if int(source.mode) == 4:
			var scale_uv: Array = source.source_uv_scale
			mat.set_shader_parameter("uv_scale", Vector2(float(scale_uv[0]), float(scale_uv[1])))
			# uv_offset already contains the Blueprint wing variant selected by original_animation.
		else:
			for parameter in ["source_tick_time", "source_sprite_emission", "source_mask_y_offset"]:
				mat.set_shader_parameter(parameter, float(source[parameter]))
			mat.set_meta("source_unshaded", true)
	mat.set_meta("source_material", source.source_material_key)
	mat.set_meta("source_surface_family", source.family)
	mat.set_meta("source_surface_formula", "compiled DXBC and frozen uniform expressions")

func _texture(path: String) -> Texture2D:
	if not _textures.has(path):
		_textures[path] = load(path) as Texture2D
	return _textures[path]

func _shader(base: StandardMaterial3D, source: Dictionary) -> Shader:
	var key := "%d:%d:%d:%d:%d:%d:%s" % [base.cull_mode, base.texture_filter, base.transparency, base.shading_mode, base.blend_mode, base.depth_draw_mode, str(source.get("textures", {}))]
	if _shaders.has(key):
		return _shaders[key]
	var shader := Shader.new()
	var code := FileAccess.get_file_as_string(SHADER_PATH)
	if base.cull_mode == BaseMaterial3D.CULL_BACK:
		code = code.replace("cull_disabled", "cull_back")
	elif base.cull_mode == BaseMaterial3D.CULL_FRONT:
		code = code.replace("cull_disabled", "cull_front")
	var filtering := "filter_linear_mipmap_anisotropic"
	match base.texture_filter:
		BaseMaterial3D.TEXTURE_FILTER_NEAREST: filtering = "filter_nearest"
		BaseMaterial3D.TEXTURE_FILTER_LINEAR: filtering = "filter_linear"
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS: filtering = "filter_nearest_mipmap"
		BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS: filtering = "filter_linear_mipmap"
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC: filtering = "filter_nearest_mipmap_anisotropic"
	code = code.replace("filter_linear_mipmap_anisotropic", filtering)
	if not base.texture_repeat:
		code = code.replace("repeat_enable", "repeat_disable")
	for parameter in source.get("textures", {}):
		if not bool(source.textures[parameter].get("srgb", true)):
			code = code.replace("uniform sampler2D %s : source_color, " % parameter, "uniform sampler2D %s : " % parameter)
	if base.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED or int(source.get("mode", 0)) == 5:
		code = code.replace("render_mode ", "render_mode unshaded, ")
	var alpha_output := ""
	match base.transparency:
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			alpha_output = "ALPHA = surface.a * source_opacity; ALPHA_SCISSOR_THRESHOLD = alpha_clip;"
		BaseMaterial3D.TRANSPARENCY_ALPHA_HASH:
			alpha_output = "ALPHA = surface.a * source_opacity; ALPHA_HASH_SCALE = 1.0;"
		BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
			alpha_output = "ALPHA = surface.a * source_opacity;"
			if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				code = code.replace("render_mode ", "render_mode depth_prepass_alpha, ")
	code = code.replace("// SOURCE_ALPHA_OUTPUT", alpha_output)
	match base.blend_mode:
		BaseMaterial3D.BLEND_MODE_ADD: code = code.replace("render_mode ", "render_mode blend_add, ")
		BaseMaterial3D.BLEND_MODE_SUB: code = code.replace("render_mode ", "render_mode blend_sub, ")
		BaseMaterial3D.BLEND_MODE_MUL: code = code.replace("render_mode ", "render_mode blend_mul, ")
		BaseMaterial3D.BLEND_MODE_PREMULT_ALPHA: code = code.replace("render_mode ", "render_mode blend_premul_alpha, ")
	match base.depth_draw_mode:
		BaseMaterial3D.DEPTH_DRAW_ALWAYS: code = code.replace("render_mode ", "render_mode depth_draw_always, ")
		BaseMaterial3D.DEPTH_DRAW_DISABLED: code = code.replace("render_mode ", "render_mode depth_draw_never, ")
	shader.code = code
	_shaders[key] = shader
	return shader


func _crystal_material(base: StandardMaterial3D, source: Dictionary) -> ShaderMaterial:
	# The cooked source is opaque: refraction bends its internal noise ray, not the scene.
	var shader_key := "crystal:%s" % str(source.source_desaturation)
	for parameter in source.textures:
		shader_key += ":%s:%s:%s" % [parameter, str(source.textures[parameter].srgb), str(source.textures[parameter].repeat)]
	if not _shaders.has(shader_key):
		var path := "res://shaders/original_crystal_desaturation.gdshader" if bool(source.source_desaturation) else "res://shaders/original_crystal.gdshader"
		var code := FileAccess.get_file_as_string(path)
		for parameter in source.textures:
			var config: Dictionary = source.textures[parameter]
			var original_line := "uniform sampler2D %s : source_color, filter_linear_mipmap_anisotropic, repeat_enable;" % parameter
			var line := original_line
			if not bool(config.srgb):
				line = line.replace("source_color, ", "")
			if not bool(config.repeat):
				line = line.replace("repeat_enable", "repeat_disable")
			code = code.replace(original_line, line)
		var shader := Shader.new()
		shader.code = code
		_shaders[shader_key] = shader
	var mat := ShaderMaterial.new()
	mat.resource_name = base.resource_name
	mat.shader = _shaders[shader_key]
	for key in base.get_meta_list():
		mat.set_meta(key, base.get_meta(key))
	var constants := PackedVector4Array()
	for value in source.source_constants:
		constants.append(Vector4(float(value[0]), float(value[1]), float(value[2]), float(value[3])))
	mat.set_shader_parameter("source_constants", constants)
	for parameter in source.textures:
		mat.set_shader_parameter(parameter, _texture(str(source.textures[parameter].path)))
	mat.set_meta("source_unshaded", false)
	mat.set_meta("source_surface_adapter", true)
	mat.set_meta("source_material", source.source_material_key)
	mat.set_meta("source_surface_family", source.family)
	mat.set_meta("source_surface_formula", "cooked DXBC material block and frozen uniform expressions; opaque eight-sample crystal")
	return mat
