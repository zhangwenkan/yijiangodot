extends Node
## Native JHLevelSetting selection and real-time transition parameters recovered
## from the shipped executable. Only the original actor's material slot 0 fades.
## Terminal mask formula and noise recovered from the actual compiled MI variants.
## Source FXAA uses TemporalAAParams.x=0; raster/shadow-pass sampling remains adapted.

const CONFIG := "res://assets/environment/native-camera-foreground.json"
const MATERIAL_CONFIG := "res://assets/environment/native-foreground-materials.json"
const TICK_SECONDS := 0.2
var target: Node3D
var entries: Array[Dictionary] = []
var bound_count := 0
var report := {"map":"", "source_groups":0, "source_rules":0, "effective_actors":0,
	"bound_surfaces":0, "enabled_fade_surfaces":0, "compiled_out_actors":[], "overridden_rules":[], "missing_actors":[], "unsupported_materials":[]}
var _tick_elapsed := 0.0
var _patched_shaders: Dictionary = {}
var _material_config: Dictionary = {}
var _noise: Texture2D

func setup(slug: String, world: Node3D, _view_camera: Camera3D, player: Node3D) -> void:
	target = player
	entries.clear()
	_tick_elapsed = 0.0
	report.map = slug
	if not FileAccess.file_exists(CONFIG):
		return
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	_material_config = JSON.parse_string(FileAccess.get_file_as_string(MATERIAL_CONFIG))
	_noise = load(str(_material_config.noise.resource)) as Texture2D
	var bindings: Dictionary = {}
	for group in config.get("maps", {}).get(slug, {}).get("foreground_groups", []):
		report.source_groups += 1
		for source in group.entries:
			report.source_rules += 1
			if int(source.actor_export) <= 0:
				continue
			var actor := str(source.actor)
			if bindings.has(actor):
				report.overridden_rules.append({"actor":actor, "previous":bindings[actor].source,
					"effective":str(group.source_name)+"/"+str(source.source_field)+"/"+str(source.array_index)})
			var p: Array = source.root_location_ue_cm
			bindings[actor] = {"actor":actor, "source_component":int(source.root_component_export),
				"root_ue_cm":Vector3(float(p[0]), float(p[1]), float(p[2])),
				"mini_range_ue_cm":Vector2(float(group.mini_range_ue_cm[0]), float(group.mini_range_ue_cm[1])),
				"x_axis_ue_cm":float(source.x_axis_ue_cm), "seconds":float(group.transition_seconds),
				"source":str(group.source_name)+"/"+str(source.source_field)+"/"+str(source.array_index)}
	report.effective_actors = bindings.size()
	var found: Dictionary = {}
	for node in world.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var actor := _actor_name(str(mesh.get_meta("source_name", "")))
		if not bindings.has(actor) or mesh.mesh == null or mesh.mesh.get_surface_count() == 0:
			continue
		var binding: Dictionary = bindings[actor]
		if int(mesh.get_meta("source_component", -1)) != int(binding.source_component):
			continue
		# Source StaticMeshActor creates its dynamic instance on ElementIndex=0.
		# Preserve other material slots, source meshes, wind and surface formulas.
		var before_material := mesh.get_active_material(0)
		var untouched_slots: Dictionary = {}
		for slot in range(1, mesh.mesh.get_surface_count()):
			untouched_slots[slot] = mesh.get_active_material(slot)
		var source_material: Dictionary = _material_config.actors.get(actor,{})
		if source_material.is_empty():
			report.unsupported_materials.append(actor+": missing compiled material evidence")
			continue
		var fade_enabled := bool(source_material.enabled)
		var material := _adapt_slot_zero(before_material,fade_enabled)
		if material == null:
			report.unsupported_materials.append(actor)
			continue
		mesh.set_surface_override_material(0, material)
		var entry: Dictionary = binding.duplicate(true)
		entry.material = material
		entry.fade_enabled = fade_enabled
		entry.before_material = before_material
		entry.source_mesh = mesh.mesh
		entry.untouched_slots = untouched_slots
		entry.node = mesh
		entry.hidden = false
		entry.current_time_scale = 0.0
		entry.add_time_scale = 1.0
		entry.visibility = 1.0
		if fade_enabled:
			material.set_shader_parameter("source_foreground_noise",_noise)
			material.set_shader_parameter("source_foreground_grain",float(source_material.grain))
			material.set_shader_parameter("source_foreground_opacity",float(source_material.opacity))
			report.enabled_fade_surfaces += 1
		else:
			report.compiled_out_actors.append(actor)
		entries.append(entry)
		found[actor] = true
	for actor in bindings:
		if not found.has(actor):
			report.missing_actors.append(actor)
	bound_count = entries.size()
	report.bound_surfaces = bound_count
	print("ORIGINAL_FOREGROUND_BOUND ", JSON.stringify(report))

func _process(delta: float) -> void:
	if not is_instance_valid(target):
		return
	var now := Time.get_ticks_msec() * 0.001
	_tick_elapsed += delta
	if _tick_elapsed >= TICK_SECONDS:
		_tick_elapsed = fmod(_tick_elapsed, TICK_SECONDS)
		# UE Hero actor origin is the capsule center. Godot controller is foot-
		# origin; get_camera_anchor returns that same center, not camera position.
		var center: Vector3 = target.get_camera_anchor() if target.has_method("get_camera_anchor") else target.global_position
		sample_rules_at(Vector3(center.x, center.z, center.y) * 100.0, now)
	for entry in entries:
		entry.visibility = source_visibility(entry, now)
		var material: ShaderMaterial = entry.material
		if bool(entry.fade_enabled):
			material.set_shader_parameter("source_foreground_visibility", entry.visibility)
			# Cooked cb0[152].x is TemporalAAParams.x, not StateFrameIndexMod8.
			# Source FXAA keeps TemporalJitterSequenceLength=1 and JitterIndex=0.
			material.set_shader_parameter("source_foreground_phase",0.0)

func sample_rules_at(hero_root_ue_cm: Vector3, real_time_seconds: float) -> void:
	for entry in entries:
		var hidden := source_should_hide(entry, hero_root_ue_cm)
		if hidden == bool(entry.hidden):
			continue
		entry.hidden = hidden
		var reciprocal := 1.0 / maxf(float(entry.seconds), 0.000001)
		entry.current_time_scale = -reciprocal if hidden else reciprocal
		entry.add_time_scale = 1.0 + real_time_seconds * reciprocal if hidden else -real_time_seconds * reciprocal

static func source_should_hide(entry: Dictionary, hero_root_ue_cm: Vector3) -> bool:
	var delta: Vector3 = entry.root_ue_cm - hero_root_ue_cm
	var range_ue: Vector2 = entry.mini_range_ue_cm
	return delta.x < -float(entry.x_axis_ue_cm) and absf(delta.x) < range_ue.x and absf(delta.y) < range_ue.y

static func source_visibility(entry: Dictionary, real_time_seconds: float) -> float:
	return clampf(real_time_seconds * float(entry.current_time_scale) + float(entry.add_time_scale), 0.0, 1.0)

func _adapt_slot_zero(base: Material, fade_enabled: bool = true) -> ShaderMaterial:
	if not base is ShaderMaterial or base.shader == null:
		# setup belongs after original_surface.setup; never replace an unknown
		# material with a simplified flat-color or whole-mesh transparency hack.
		return null
	var key: int = base.shader.get_instance_id()
	if fade_enabled and not _patched_shaders.has(key):
		var code: String = base.shader.code
		var start := code.find("void fragment()")
		if start < 0:
			return null
		var opening := code.find("{", start)
		var closing := opening + 1
		var depth := 1
		while closing < code.length() and depth > 0:
			if code[closing] == "{": depth += 1
			elif code[closing] == "}": depth -= 1
			closing += 1
		if depth != 0:
			return null
		# Direct port of actual MI_ItemAll_YCCZ1 and HD_Dashu012 DXBC mask.
		# Alpha is the sampled albedo alpha, not whole-mesh opacity. Original
		# modulo-five pattern and its original 64x64 noise texture are retained.
		var addition := "\nvec2 fade_pixel = SCREEN_UV * VIEWPORT_SIZE;\n"
		addition += "uvec2 fade_integer = uvec2(fade_pixel + vec2(source_foreground_phase));\n"
		addition += "float fade_pattern = float((fade_integer.x + 2u * fade_integer.y) % 5u);\n"
		addition += "float fade_noise = texture(source_foreground_noise,fade_pixel / 64.0).r;\n"
		addition += "float fade_mask = texel.a * source_foreground_visibility + (fade_pattern + fade_noise * source_foreground_grain) * 0.16666667 - 0.5;\n"
		addition += "if (fade_mask * source_foreground_opacity - 0.3333 < 0.0) { discard; }\n"
		addition += "ALPHA = 1.0; ALPHA_SCISSOR_THRESHOLD = 0.0;\n"
		code = code.insert(closing-1, addition)
		code = code.replace("shader_type spatial;", "shader_type spatial;\nuniform float source_foreground_visibility = 1.0;\nuniform float source_foreground_phase = 0.0;\nuniform float source_foreground_grain = 1.0;\nuniform float source_foreground_opacity = 1.0;\nuniform sampler2D source_foreground_noise : filter_linear_mipmap, repeat_enable;\n")
		var shader := Shader.new()
		shader.code = code
		_patched_shaders[key] = shader
	var parameter_baseline: Dictionary = {}
	for uniform in base.shader.get_shader_uniform_list():
		parameter_baseline[str(uniform.name)] = base.get_shader_parameter(str(uniform.name))
	var material := base.duplicate(false) as ShaderMaterial
	if fade_enabled:
		material.shader = _patched_shaders[key]
		material.set_shader_parameter("source_foreground_visibility", 1.0)
		material.set_shader_parameter("source_foreground_phase", 0.0)
	material.set_meta("source_foreground_parameter_baseline", parameter_baseline)
	material.set_meta("source_foreground_before_wind", bool(base.get_meta("source_wind_adapter", false)))
	material.set_meta("source_foreground_before_surface", bool(base.get_meta("source_surface_adapter", false)) or base.has_meta("source_surface_formula"))
	material.set_meta("source_foreground_native", "JHLevelSetting 0x140f7eab0; slot 0, hero root, strict range, real time")
	material.set_meta("source_foreground_compiled_enabled",fade_enabled)
	material.set_meta("source_foreground_render_adaptation", "compiled original modulo5/noise opacity expression; source FXAA phase zero; raster alignment and shadow-pass sampling adapted")
	return material

static func _actor_name(source_name: String) -> String:
	if not source_name.contains(".PersistentLevel."):
		return ""
	return source_name.get_slice(".PersistentLevel.",0)+".PersistentLevel."+source_name.get_slice(".PersistentLevel.",1).get_slice(".",0)
