extends Node3D
## Source-derived environment adapter. Native UE rendering remains the full-fidelity reference.
## No mesh geometry is created here. All surface effects bind to imported source meshes.

const CONFIG_PATH := "res://assets/environment/original-environment-config.json"
const WATER_SHADER := preload("res://shaders/original_water_approx.gdshader")
const OCEAN_SHADER := preload("res://shaders/original_ocean_approx.gdshader")
const FOG_SHADER := preload("res://shaders/original_fog_card_approx.gdshader")
const BEAM_SHADER := preload("res://shaders/original_light_beam_approx.gdshader")
const SOURCE_METADATA := preload("res://scripts/source_metadata.gd")
const COMPILED_CARDS := preload("res://scripts/original_compiled_cards.gd")
const SOURCE_SKY_SHADER := preload("res://shaders/original_source_sky.gdshader")

# Renderer calibration, kept separate from immutable source intensities.
@export var sun_energy_per_source_unit := 1.0 / 20.0
@export var local_energy_per_source_unit := 0.001
@export var ambient_energy_scale := 0.09
@export var enable_approximate_water := true
@export var enable_source_cards := true
@export var enable_butterfly_wings := false # original_animation.gd owns original path, body and wing timelines.

var coverage: Dictionary = {}
var _config: Dictionary = {}
var _data: Dictionary = {}
var _world: Node3D
var _generated: Node3D
var _sources: Dictionary = {}
var _butterflies: Array[Dictionary] = []
var _elapsed := 0.0
var _cubes: Dictionary = {}
var _camera: Camera3D
var _house_lighting_cache: Array[Dictionary] = []
var _house_focus_distance := -1.0
var _source_reflection_probe: ReflectionProbe

func setup(slug: String, world: Node3D, camera: Camera3D) -> void:
	if is_instance_valid(_generated):
		_generated.queue_free()
	_sources.clear()
	_butterflies.clear()
	_elapsed = 0.0
	_world = world
	_camera = camera
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not parsed is Dictionary:
		push_error("Original environment source configuration is missing or invalid.")
		return
	_config = parsed
	_data = _config.get("maps", {}).get(slug, {})
	coverage = _config.get("coverage", {}).duplicate(true)
	coverage["bound"] = {"lights": 0, "water_meshes": 0, "ocean_surfaces": 0, "fog_cards": 0, "light_beams": 0, "butterflies": 0}
	coverage["missing_bindings"] = []
	_generated = Node3D.new()
	_generated.name = "SourceEnvironment_" + slug
	world.add_child(_generated)
	if not world.has_meta("source_metadata_restored"):
		SOURCE_METADATA.restore(world, "res://assets/%s/world.glb" % slug)
		world.set_meta("source_metadata_restored", true)
	_index_sources(world)
	_setup_lighting(camera)
	coverage["bound"]["sky_cards"] = COMPILED_CARDS.bind_skies(world, load("res://assets/environment/textures/T_Sky_01.png"), 1.0)
	if enable_approximate_water:
		_setup_water()
		_setup_ocean()
	if enable_source_cards:
		_setup_cards("fog_sheets", false)
		_setup_cards("light_beams", true)
	if enable_butterfly_wings:
		_setup_butterflies()
	set_process(true)
	print("Original environment coverage ", slug, ": ", JSON.stringify(coverage["bound"]))

func _index_sources(node: Node) -> void:
	if node.has_meta("source_name"):
		_sources[str(node.get_meta("source_name"))] = node
	for child in node.get_children():
		_index_sources(child)

func _source_mesh(source: String) -> MeshInstance3D:
	var node = _sources.get(source)
	if not is_instance_valid(node):
		return null
	return _first_mesh(node)

func _first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var result := _first_mesh(child)
		if result != null:
			return result
	return null

func _ue_transform(m: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(m[0][0], m[2][0], m[1][0]), Vector3(m[0][2], m[2][2], m[1][2]), Vector3(m[0][1], m[2][1], m[1][1])), Vector3(m[0][3], m[2][3], m[1][3]) * 0.01)

func _color(value, fallback := Color.WHITE, byte_color := false) -> Color:
	if value is Dictionary:
		if value.has("R"):
			return Color(float(value.get("R", 0)), float(value.get("G", 0)), float(value.get("B", 0)), float(value.get("A", 1)))
		if value.size() == 1:
			return _color(value.values()[0], fallback, byte_color)
	if value is String:
		var channels: PackedStringArray = value.split(",")
		if channels.size() >= 3:
			var divisor := 255.0 if byte_color else 1.0
			return Color(float(channels[0]) / divisor, float(channels[1]) / divisor, float(channels[2]) / divisor)
	return fallback

func _linear_uniform(value) -> Vector4:
	# Native material FLinearColor is already linear. Passing a Godot Color
	# automatically decodes sRGB in 3D even without a source_color hint.
	# Vector4 preserves all four source values, including HDR values above 1.
	var c := _color(value)
	return Vector4(c.r, c.g, c.b, c.a)

func _setup_lighting(camera: Camera3D) -> void:
	var environment := Environment.new()
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = SOURCE_SKY_SHADER
	sky_mat.set_shader_parameter("source_capture", _cubemap("source_sky"))
	sky_mat.set_shader_parameter("source_open_sky", _cubemap("source_ocean"))
	var sky := Sky.new()
	sky.sky_material = sky_mat
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.glow_enabled = true
	environment.glow_intensity = 0.22
	environment.glow_hdr_threshold = 1.0
	environment.glow_bloom = 0.0
	# Source DefaultFeature.AmbientOcclusion is false; map overrides do not enable it.
	environment.ssao_enabled = false
	# UE's per-channel grading, auto exposure and bloom kernels are not numerically interchangeable.
	# Preserve all source values in metadata; do not misapply UE gamma directly as a global Godot gamma.
	var world_environment := WorldEnvironment.new()
	world_environment.name = "OriginalSourceLighting_Adapted"
	world_environment.environment = environment
	world_environment.set_meta("ue_postprocess", _data.get("postprocess", []))
	world_environment.set_meta("fidelity", "cross-engine lighting adaptation; native UE is reference")
	_generated.add_child(world_environment)
	for item in _data.get("light_components", []):
		var p: Dictionary = item["properties"]
		var source_class: String = item["class"]
		if source_class.ends_with("SkyLightComponent"):
			environment.ambient_light_color = _color(p.get("LightColor"), Color.WHITE, true)
			environment.ambient_light_energy = float(p.get("Intensity", 1.0)) * ambient_energy_scale
			world_environment.set_meta("ue_skylight", p)
			continue
		if source_class.contains("Fog"):
			world_environment.set_meta("ue_" + source_class.get_slice(".", 1), p)
			if source_class.ends_with("ExponentialHeightFogComponent"):
				environment.fog_enabled = true
				environment.fog_mode = Environment.FOG_MODE_DEPTH
				# Source field is FLinearColor; Godot's fog property is decoded
				# from sRGB by the renderer. Preserve the original linear value.
				environment.fog_light_color = _color(p.get("FogInscatteringColor"), Color(0.624,0.701,1.0)).linear_to_srgb()
				environment.fog_depth_begin = float(p.get("StartDistance",5500.0)) * 0.01
				environment.fog_depth_end = 260.0
				environment.fog_depth_curve = 1.7
				environment.fog_density = float(p.get("FogMaxOpacity",0.2))
			continue
		if p.get("bVisible", true) == false or p.get("bHiddenInGame", false):
			continue
		var light: Light3D
		if source_class.ends_with("DirectionalLightComponent"):
			light = DirectionalLight3D.new()
			light.light_energy = float(p.get("Intensity", 0.0)) * sun_energy_per_source_unit
			light.directional_shadow_max_distance = float(p.get("DynamicShadowDistanceMovableLight", 20000.0)) * 0.01
			light.shadow_enabled = true
		elif source_class.ends_with("SpotLightComponent"):
			light = SpotLight3D.new()
			# Native UPointLightComponent constructor defaults Intensity to 5000;
			# an omitted cooked property inherits it (Youxian SpotLight2_2).
			light.light_energy = float(p.get("Intensity", 5000.0)) * local_energy_per_source_unit
			light.spot_range = float(p.get("AttenuationRadius", 1000.0)) * 0.01
			light.spot_angle = float(p.get("OuterConeAngle", 44.0))
			light.spot_attenuation = 1.0
		elif source_class.ends_with("PointLightComponent"):
			light = OmniLight3D.new()
			light.light_energy = float(p.get("Intensity", 5000.0)) * local_energy_per_source_unit
			light.omni_range = float(p.get("AttenuationRadius", 1000.0)) * 0.01
		else:
			continue
		light.name = "SourceLight_" + str(item["source_component"])
		light.light_color = _color(p.get("LightColor"), Color.WHITE, true)
		light.set_meta("source_name", item["name"])
		light.set_meta("ue_properties", p)
		_generated.add_child(light)
		var source_transform := _ue_transform(item["matrix_ue"])
		light.position = source_transform.origin
		var direction := source_transform.basis.x.normalized()
		if absf(direction.dot(Vector3.UP)) > 0.999:
			light.look_at(light.global_position + direction, Vector3.FORWARD)
		else:
			light.look_at(light.global_position + direction, Vector3.UP)
		coverage["bound"]["lights"] += 1
	if camera != null:
		camera.set_meta("ue_camera_source", _config.get("camera_source", {}))
		var attributes := CameraAttributesPractical.new()
		attributes.dof_blur_near_enabled = true
		attributes.dof_blur_far_enabled = true
		attributes.dof_blur_near_distance = 25.2
		attributes.dof_blur_near_transition = 9.0
		attributes.dof_blur_far_distance = 36.2
		attributes.dof_blur_far_transition = 14.0
		attributes.dof_blur_amount = 0.11
		camera.attributes = attributes
		camera.set_meta("dof_adaptation", "source focal distance 32.2m; Godot blur thresholds calibrated separately from UE fstop .08")

func update_focus(world_position: Vector3) -> void:
	if _camera == null or not _camera.attributes is CameraAttributesPractical:
		return
	if _camera.has_meta("source_dof_owner") and is_instance_valid(_camera.get_meta("source_dof_owner")):
		return
	var focus_distance := _house_focus_distance if _house_focus_distance > 0.0 else -(_camera.global_transform.affine_inverse() * world_position).z
	_camera.attributes.dof_blur_near_distance = maxf(focus_distance - 7.0, 0.1)
	_camera.attributes.dof_blur_far_distance = focus_distance + 4.0

func setup_source_scene_reflection() -> void:
	# JHEnvironment::BeginPlay selects CapturedScene on the default PC branch.
	# Godot's probe is a renderer adaptation: convolution/BRDF and the original
	# SkyDistanceThreshold are not identical. It replaces the unrelated prefab
	# cubemap only for reflections; diffuse ambient calibration remains separate.
	for item in _data.get("light_components", []):
		if not str(item["class"]).ends_with("SkyLightComponent"):
			continue
		_source_reflection_probe = ReflectionProbe.new()
		_source_reflection_probe.name = "OriginalSceneReflection_Adapted"
		_source_reflection_probe.size = Vector3(1400, 1400, 1400)
		_source_reflection_probe.max_distance = 700.0
		_source_reflection_probe.box_projection = false
		_source_reflection_probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
		_source_reflection_probe.update_mode = ReflectionProbe.UPDATE_ONCE
		_source_reflection_probe.intensity = float(item.properties.get("Intensity", 1.0))
		_source_reflection_probe.enable_shadows = true
		_source_reflection_probe.set_meta("source_skylight", item.properties)
		_source_reflection_probe.set_meta("fidelity", "native default PC CapturedScene branch; Godot reflection capture/BRDF adaptation, diffuse SH and SkyDistanceThreshold not equivalent")
		_generated.add_child(_source_reflection_probe)
		_source_reflection_probe.global_transform = _ue_transform(item.matrix_ue)
		print("ORIGINAL_SCENE_REFLECTION_READY origin=", _source_reflection_probe.global_position, " intensity=", _source_reflection_probe.intensity)
		break

func _cubemap(folder: String) -> Cubemap:
	if _cubes.has(folder):
		return _cubes[folder]
	var faces: Array[Image] = []
	for i in range(6):
		var path := "res://assets/environment/%s/Side_%d.hdr" % [folder,i]
		var source: Texture2D = load(path)
		var face := source.get_image() if source != null else null
		if face == null:
			return null
		faces.append(face)
	var cube := Cubemap.new()
	if cube.create_from_images(faces) != OK:
		return null
	_cubes[folder] = cube
	return cube

func _texture(name: String) -> Texture2D:
	var native_path := "res://assets/environment/textures/%s_native.dds" % name
	if ResourceLoader.exists(native_path):
		return load(native_path) as Texture2D
	var path: String = _config.get("textures", {}).get(name, "")
	if not path.is_empty() and ResourceLoader.exists(path):
		return load(path) as Texture2D
	if not path.is_empty() and FileAccess.file_exists(path):
		return ImageTexture.create_from_image(Image.load_from_file(path))
	return null

func _dynamic(source: String) -> Dictionary:
	for item in _data.get("dynamic_materials", []):
		if str(item["name"]).begins_with(source + "."):
			return item["parameters"]
	return {}

func _setup_water() -> void:
	for item in _data.get("dynamic_materials", []):
		if not str(item["name"]).contains("Water_Blueprint"):
			continue
		var source := str(item["name"]).rsplit(".", true, 1)[0]
		var mesh := _source_mesh(source)
		if mesh == null:
			coverage["missing_bindings"].append(source)
			continue
		var values: Dictionary = item["parameters"]
		var s: Dictionary = values.get("Scalar", {})
		var v: Dictionary = values.get("Vector", {})
		var mat := ShaderMaterial.new()
		mat.shader = WATER_SHADER
		# Source Water_Blueprint has no TranslucencySortPriority override (default 0).
		# An extra priority here draws seawater over smoke and splash in front of it.
		mat.render_priority = 0
		_bind_recovered_water_material(mat, s, v)
		mesh.material_override = mat
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.set_meta("source_water_parameters", values)
		mesh.set_meta("fidelity", mat.get_meta("fidelity"))
		coverage["bound"]["water_meshes"] += 1

func _setup_ocean() -> void:
	var policies: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/material-policy.json"))
	var ocean_materials: Dictionary = {}
	for material_name in policies:
		var source: Dictionary = policies[material_name]
		if source.get("source_name", "") not in ["M_Ocean", "M_Ocean_Inst"]:
			continue
		var s: Dictionary = source.get("scalars", {})
		var v: Dictionary = source.get("vectors", {})
		var mat := ShaderMaterial.new()
		mat.shader = OCEAN_SHADER
		mat.render_priority = 0
		_bind_recovered_ocean_material(mat, s, v)
		mat.set_meta("ue_source_material", source)
		ocean_materials[material_name] = mat
	for mesh in _world.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var material: Material = mesh.mesh.surface_get_material(surface)
			if material != null and ocean_materials.has(material.resource_name):
				mesh.set_surface_override_material(surface, ocean_materials[material.resource_name])
				mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				coverage["bound"]["ocean_surfaces"] += 1

func _setup_cards(category: String, beam: bool) -> void:
	for actor in _data.get(category, []):
		for component in actor.get("components", []):
			if not str(component["class"]).ends_with("StaticMeshComponent"):
				continue
			var mesh := _source_mesh(component["name"])
			if mesh == null:
				coverage["missing_bindings"].append(component["name"])
				continue
			var values := _dynamic(component["name"])
			var s: Dictionary = values.get("Scalar", {})
			var v: Dictionary = values.get("Vector", {})
			var mat := ShaderMaterial.new()
			if beam:
				mat = COMPILED_CARDS.bind_beam(mesh, values, _texture("T_GodRay_Mask01"), _texture("T_TilingNoise02_M"), true)
				coverage["bound"]["light_beams"] += 1
			else:
				mat.shader = FOG_SHADER
				_bind_recovered_fog_material(mat, s, v)
				coverage["bound"]["fog_cards"] += 1
			mesh.material_override = mat
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mesh.set_meta("ue_material_parameters", values)
			mesh.set_meta("fidelity", "original mesh and recovered cooked material expressions; cross-engine rendering remains under visual validation")

func _setup_butterflies() -> void:
	for actor in _data.get("butterflies", []):
		var props: Dictionary = actor["properties"]
		var by_name: Dictionary = {}
		for component in actor.get("components", []):
			by_name[component["name"]] = component
		var parts: Array[Dictionary] = []
		for key in ["ButterflyBody", "ButterflyWing_L", "ButterflyWing_R"]:
			var source: String = props.get(key, "")
			var mesh := _source_mesh(source)
			if mesh != null and by_name.has(source):
				var component: Dictionary = by_name[source]
				parts.append({"node": mesh, "rest": mesh.global_transform, "part": key})
		if parts.size() == 3 and by_name.has(props.get("Butterfly", "")):
			var body_transform := _ue_transform(by_name[props["Butterfly"]]["matrix_ue"])
			var parent_transform := _ue_transform(by_name[props["Butterfly_Root"]]["matrix_ue"])
			_butterflies.append({"parts": parts, "pivot": body_transform.origin, "basis": body_transform.basis, "parent_basis": parent_transform.basis})
			coverage["bound"]["butterflies"] += 1
		else:
			coverage["missing_bindings"].append(actor["name"] + ": butterfly meshes")

func _curve(suffix: String, time: float) -> float:
	for key in _config.get("curves", {}):
		if str(key).ends_with(suffix):
			return _rich_curve(_config["curves"][key], time)
	return 0.0

func _rich_curve(keys: Array, time: float) -> float:
	if keys.is_empty():
		return 0.0
	for i in range(keys.size() - 1):
		var left: Dictionary = keys[i]
		var right: Dictionary = keys[i + 1]
		var t0 := float(left["Time"])
		var t1 := float(right["Time"])
		if time > t1:
			continue
		var span := maxf(t1 - t0, 0.000001)
		var u := clampf((time - t0) / span, 0.0, 1.0)
		var a := float(left["Value"])
		var b := float(right["Value"])
		if left.get("InterpMode") == "RCIM_Constant":
			return a
		if left.get("InterpMode") == "RCIM_Linear":
			return lerpf(a, b, u)
		var u2 := u * u
		var u3 := u2 * u
		return (2.0*u3-3.0*u2+1.0)*a + (u3-2.0*u2+u)*float(left.get("LeaveTangent",0.0))*span + (-2.0*u3+3.0*u2)*b + (u3-u2)*float(right.get("ArriveTangent",0.0))*span
	return float(keys.back()["Value"])

func _process(delta: float) -> void:
	_elapsed += delta
	var time := fposmod(_elapsed, 1.0)
	var body := _curve("BP_Butterfly_C.CurveFloat_0", time)
	var wings := _curve("BP_Butterfly_C.CurveFloat_1", time)
	for butterfly in _butterflies:
		var basis: Basis = butterfly["basis"]
		var pivot: Vector3 = butterfly["pivot"]
		# Original timeline: body -5..+5 cm; opposite wing pitch +60..-60 degrees.
		# Skeletal path motion is intentionally not invented in place of the missing clip.
		var parent_basis: Basis = butterfly["parent_basis"]
		var displacement := parent_basis * Vector3(0, lerpf(-0.05, 0.05, body), 0)
		for part in butterfly["parts"]:
			var node: MeshInstance3D = part["node"]
			if not is_instance_valid(node):
				continue
			var rest: Transform3D = part["rest"]
			var angle := 0.0
			if part["part"] == "ButterflyWing_L":
				angle = deg_to_rad(lerpf(60.0, -60.0, wings))
			elif part["part"] == "ButterflyWing_R":
				angle = deg_to_rad(lerpf(-60.0, 60.0, wings))
			var rotation := Basis(basis.z.normalized(), -angle)
			node.global_transform = Transform3D(rotation * rest.basis, pivot + rotation * (rest.origin-pivot) + displacement)

func set_source_house_lighting(inside: bool, source: Dictionary) -> void:
	if inside:
		if not _house_lighting_cache.is_empty():
			return
		if is_instance_valid(_source_reflection_probe):
			_house_lighting_cache.append({"kind":"reflection", "node":_source_reflection_probe, "visible":_source_reflection_probe.visible})
			_source_reflection_probe.visible = false
		for node in _generated.find_children("*", "DirectionalLight3D", true, false):
			_house_lighting_cache.append({"kind": "sun", "node": node, "energy": node.light_energy, "shadows": node.shadow_enabled, "distance": node.directional_shadow_max_distance})
			node.light_energy = float(source.sun_intensity) * sun_energy_per_source_unit
			node.shadow_enabled = false
			node.directional_shadow_max_distance = float(source.sun_shadow_distance_cm) * 0.01
			node.set_meta("source_house_light_function_disabled", true)
		for node in _generated.find_children("*", "WorldEnvironment", true, false):
			var env: Environment = node.environment
			_house_lighting_cache.append({"kind": "sky", "node": env, "energy": env.ambient_light_energy, "ambient_source": env.ambient_light_source, "reflection_source": env.reflected_light_source})
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_energy = 0.0
			env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
			node.set_meta("ue_house_postprocess", source.postprocess)
		if _camera != null and _camera.attributes is CameraAttributesPractical and not (_camera.has_meta("source_dof_owner") and is_instance_valid(_camera.get_meta("source_dof_owner"))):
			var attributes: CameraAttributesPractical = _camera.attributes
			_house_lighting_cache.append({"kind": "dof", "node": attributes, "near": attributes.dof_blur_near_distance, "far": attributes.dof_blur_far_distance})
		_house_focus_distance = float(source.postprocess.DepthOfFieldFocalDistance_cm) * 0.01
		update_focus(Vector3.ZERO)
	else:
		for state in _house_lighting_cache:
			if not is_instance_valid(state.node):
				continue
			match state.kind:
				"reflection":
					state.node.visible = state.visible
				"sun":
					state.node.light_energy = state.energy
					state.node.shadow_enabled = state.shadows
					state.node.directional_shadow_max_distance = state.distance
					state.node.set_meta("source_house_light_function_disabled", false)
				"sky":
					state.node.ambient_light_source = state.ambient_source
					state.node.ambient_light_energy = state.energy
					state.node.reflected_light_source = state.reflection_source
				"dof":
					if not (_camera.has_meta("source_dof_owner") and is_instance_valid(_camera.get_meta("source_dof_owner"))):
						state.node.dof_blur_near_distance = state.near
						state.node.dof_blur_far_distance = state.far
		_house_lighting_cache.clear()
		_house_focus_distance = -1.0
	set_meta("source_house_interior", inside)

func _recovered_water_texture(texture_name: String) -> Texture2D:
	# Preserve source BC5 blocks and the entire cooked mip chain. PNG extraction
	# had retained only level zero; no change to normal strength or color space.
	var native_path := "res://assets/environment/textures/%s_native.dds" % texture_name
	if ResourceLoader.exists(native_path):
		return load(native_path) as Texture2D
	var existing := _texture(texture_name)
	if existing != null:
		return existing
	var resource_path := "res://assets/environment/textures/%s.png" % texture_name
	if ResourceLoader.exists(resource_path):
		return load(resource_path) as Texture2D
	push_error("Missing recovered source water texture: " + texture_name)
	return null

func _bind_recovered_water_material(mat: ShaderMaterial, s: Dictionary, v: Dictionary) -> void:
	var texture_names := {
		"waves_2_normal": "Waves_2_Normal", "waves_1_normal": "Waves_1_Normal",
		"water_4_normal": "Water_4_Normal", "water_3_normal": "Water_3_Normal",
		"water_2_normal": "Water_2_Normal", "water_1_normal": "Water_1_Normal",
		"coral_mask": "Coral_Reef_1_Texture",
		"foam_1": "Foam_1_Texture", "foam_2": "Foam_2_Texture",
		"foam_3": "Foam_3_Texture", "foam_4": "Foam_4_Texture",
		"distortion_1": "Distortion_1_Texture", "distortion_2": "Distortion_2_Texture",
		"water_1": "Water_1_Texture", "water_2": "Water_2_Texture",
		"water_3": "Water_3_Texture", "water_4": "Water_4_Texture"
	}
	for parameter in texture_names:
		mat.set_shader_parameter(parameter, _recovered_water_texture(str(texture_names[parameter])))
	var scalar_names := {
		"overall_scale": "Overall Scale", "wave_normal_scale": "Wave Normal Scale",
		"wave_normal_speed": "Wave Normal Speed", "wave_normal_strength": "Wave Normal Strength",
		"ocean_normal_scale": "Ocean Normal Scale", "ocean_normal_speed": "Ocean Normal Speed",
		"ocean_normal_strength": "Ocean Normal Strength", "overall_normal_power": "Overall Normal Power",
		"normal_fresnel_power": "Normal Fresnel Power", "coral_scale": "Coral Reef Scale",
		"coral_contrast": "Coral Reef Contrast", "water_height_cm": "Water Height",
		"shore_depth_cm": "Shore Depth", "color_spread": "Color Spread", "color_smooth": "Color Smooth",
		"foam_speed": "Foam Speed", "foam_scale": "Foam Scale", "foam_height_cm": "Foam Height",
		"foam_blur_cm": "Foam Blur", "shore_distortion_speed": "Shore Distortion Speed",
		"shore_distortion_scale": "Shore Distortion Scale", "sea_foam_contrast": "Sea Foam Contrast",
		"sea_foam_scale": "Sea Foam Scale", "sea_foam_intensity": "Sea Foam Intensity",
		"source_metallic": "Metallic", "deep_opacity": "Deep Opacity", "shallow_opacity": "Shallow Opacity",
		"shore_fade_cm": "Shore Fade", "surge_divisor": "Surge Divisor", "surge_speed": "Surge Speed",
		"surge_height_cm": "Surge Wave Height", "deep_ior": "Deep IQR", "shallow_ior": "Shallow IQR",
		"refraction_depth_bias_cm": "RefractionDepthBias"
	}
	for parameter in scalar_names:
		var source_key: String = scalar_names[parameter]
		if s.has(source_key):
			mat.set_shader_parameter(parameter, float(s[source_key]))
	for pair in [["color_shallow", "Color Shallow"], ["color_deep", "Color Deep"], ["color_coral", "Color Coral Reef"]]:
		if v.has(pair[1]):
			mat.set_shader_parameter(pair[0], _linear_uniform(v[pair[1]]))
	mat.set_meta("fidelity", "DXBC/preshader-derived dry Water_Material expressions; Godot lighting; native distortion compositor is not reproduced")
	mat.set_meta("refraction_adapter", "source IOR and normal-difference math recovered; optional Godot screen-copy adaptation is disabled pending GPU validation")
	mat.set_meta("source_rain_values", [s.get("Rain Intensity", 0.0), s.get("Rain Normal Power", 0.0), s.get("Rain Scale", 0.0)])

func _bind_recovered_ocean_material(mat: ShaderMaterial, s: Dictionary, v: Dictionary) -> void:
	mat.set_shader_parameter("reflection_cube", _cubemap("source_ocean"))
	mat.set_shader_parameter("specular_texture", _recovered_water_texture("T_SpecularHighlights"))
	mat.set_shader_parameter("foam_texture", _recovered_water_texture("T_Ocean_Foam"))
	mat.set_shader_parameter("edge_foam_texture", _recovered_water_texture("T_Ocean_EdgeFoam"))
	for pair in [["color_shallow", "海水浅色"], ["color_deep", "海水深色"]]:
		if v.has(pair[1]):
			mat.set_shader_parameter(pair[0], _linear_uniform(v[pair[1]]))
	var scalar_names := {
		"wave_master": "masterIntensity", "edge_variance_cm": "varience", "edge_speed": "edgeFoamSpeed",
		"edge_intensity": "edgeFoamIntensity", "sea_foam_intensity": "seaFoamIntensity",
		"foam_emission_intensity": "foamIntensity", "reflection_intensity": "cubemapIntensity",
		"fake_spec_intensity": "FakeSpec_Intensity", "fake_spec_scale_cm": "FakeSpec_UVScale",
		"fake_spec_speed": "FakeSpec_Speed", "depth_reference_cm": "01", "depth_scale_cm": "02", "depth_power": "03"
	}
	for parameter in scalar_names:
		var source_key: String = scalar_names[parameter]
		if s.has(source_key):
			mat.set_shader_parameter(parameter, float(s[source_key]))
	var pairs := {
		"edge_speeds_x": ["edgefoam01_speedX", "edgefoam02_speedX", 0.02, 0.02],
		"edge_tilings": ["edgeFoam01_tiling", "edgeFoam02_tiling", 6.0, 6.0],
		"edge_depths_cm": ["edgeFoam01_depth", "edgeFoam02_depth", 0.0, 0.0],
		"edge_depth_scales_cm": ["edgeFoam01_depthScale", "edgeFoam02_depthScale", 20.0, 16.0],
		"edge_depth_powers": ["edgeFoam01_depthPower", "edgeFoam02_depthPower", 3.0, 3.0],
		"foam_height_offsets_cm": ["foam01_heightOffset", "foam02_heightOffset", 100.0, 90.0],
		"foam_height_scales_cm": ["foam01_heightScale", "foam02_heightScale", 125.0, 100.0],
		"foam_depths_cm": ["foam01_depth", "foam02_depth", 0.0, 0.0],
		"foam_scales_cm": ["foam01_scale", "foam02_scale", 30.0, 25.0],
		"foam_powers": ["foam01_power", "foam02_power", 2.0, 2.0],
		"foam_speeds": ["foam01Speed", "foam02Speed", 0.1, 0.15],
		"foam_variances_cm": ["foam01Varience", "foam02Varience", 6000.0, 6000.0],
		"foam_offsets": ["foam01Offset", "foam02Offset", 4.0, 2.0],
		"foam_tilings": ["foam01Tiling", "foam02Tiling", 12.0, 12.0]
	}
	for parameter in pairs:
		var pair: Array = pairs[parameter]
		mat.set_shader_parameter(parameter, Vector2(float(s.get(pair[0], pair[2])), float(s.get(pair[1], pair[3]))))
	mat.set_shader_parameter("wave_scales_cm", Vector3(float(s.get("wave01Scale",8192)),float(s.get("wave02Scale",2048)),float(s.get("wave03Scale",1024))))
	mat.set_shader_parameter("wave_speeds", Vector3(float(s.get("speed01",0.06)),float(s.get("speed02",0.15)),float(s.get("speed03",0.3))))
	mat.set_shader_parameter("wave_intensities", Vector3(float(s.get("intensity01",2)),float(s.get("intensity02",1)),float(s.get("intensity03",0.5))))
	mat.set_shader_parameter("fake_spec_power", Vector3(float(s.get("FakeSpec_Power1",10)),float(s.get("FakeSpec_Power2",40)),float(s.get("FakeSpec_Power3",75))))
	mat.set_shader_parameter("fake_spec_channel_intensity", Vector3(float(s.get("FakeSpec_Intensity1",512)),float(s.get("FakeSpec_Intensity2",512)),float(s.get("FakeSpec_Intensity3",512))))
	mat.set_shader_parameter("source_light_ray", Vector3(1.0,0.0,0.0)) # exact MPC_Globals.Vector cooked default
	mat.set_meta("fidelity", "DXBC/preshader-derived M_Ocean material expressions; Godot translucency lighting; MPC runtime writes remain unverified")

func _bind_recovered_fog_material(mat: ShaderMaterial, s: Dictionary, v: Dictionary) -> void:
	mat.set_shader_parameter("noise_texture", load("res://assets/environment/textures/T_TilingNoise03_M_native.dds"))
	mat.set_shader_parameter("fog_color", _linear_uniform(v.get("Color")))
	mat.set_shader_parameter("max_opacity", float(s.get("MaxOpacity", 0.5)))
	mat.set_shader_parameter("noise_size_cm", float(s.get("NoiseSize", 2048.0)))
	mat.set_shader_parameter("projection_distance_cm", float(s.get("TilingMaskProjectionDistance", 2048.0)))
	mat.set_shader_parameter("depth_fade_cm", float(s.get("DepthFadeDistance", 1024.0)))
	mat.set_shader_parameter("fade_distance_min_cm", float(s.get("FadeDistanceMin", 256.0)))
	mat.set_shader_parameter("fade_distance_cm", float(s.get("FadeDistance", 1024.0)))
	mat.set_shader_parameter("panning_speed", float(s.get("PanningSpeed", 0.01)))
	mat.set_shader_parameter("direction", Vector2(float(s.get("XSpeed", -1.0)), float(s.get("YSpeed", 0.0))))

