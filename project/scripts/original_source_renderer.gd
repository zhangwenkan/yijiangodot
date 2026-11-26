extends Node
## Own the source-derived rendering stack and restore it before changing maps.
## Geometry is untouched. Remaining cross-engine differences are recorded by each adapter.

var report: Dictionary = {}
var film: CompositorEffect
var bloom: CompositorEffect
var distortion: CompositorEffect
var splash_binding: Node
var water_binding: Node
var sh: Node
var transparent_sky: Node
var reflection: Node
var height_fog: Node
var local_lights: RefCounted
var local_cones: RefCounted
var character: RefCounted
var ambient: RefCounted
var birds: RefCounted
var leaf: RefCounted
var atmosphere: Node
var depth_of_field: Node
var separate_translucency: Node
var _scene: Node
var _environment: Environment
var _sun: DirectionalLight3D
var _saved: Dictionary = {}
var _compositor: Compositor
var _viewport: Viewport

func setup(scene: Node, enable_distortion := false, enable_atmosphere := false) -> Dictionary:
	if not _saved.is_empty():
		return {"status":"failed", "reason":"Source renderer already installed; call shutdown before setup."}
	_scene = scene
	var environments: Array[Node] = scene.world.find_children("*", "WorldEnvironment", true, false)
	var suns: Array[Node] = scene.world.find_children("*", "DirectionalLight3D", true, false)
	if environments.is_empty() or suns.is_empty():
		return {"status":"failed", "reason":"Source environment or sun missing"}
	_environment = environments[0].environment
	_sun = suns[0]
	_viewport=scene.get_viewport()
	_saved = {"compositor":scene.camera.compositor, "tonemap":_environment.tonemap_mode,
		"exposure":_environment.tonemap_exposure, "glow":_environment.glow_enabled,
		"sun_energy":_sun.light_energy, "sun_unit":scene.environment_driver.sun_energy_per_source_unit,
		"msaa":_viewport.msaa_3d,"screen_aa":_viewport.screen_space_aa,"taa":_viewport.use_taa,"mipmap_bias":_viewport.texture_mipmap_bias}
	# Source DefaultEngine.ini selects FXAA. Keep effective mip bias unchanged:
	# Godot implicitly subtracts .25 for FXAA, and .5 for TAA.
	var effective_bias: float=_viewport.texture_mipmap_bias-(0.25 if _viewport.screen_space_aa==Viewport.SCREEN_SPACE_AA_FXAA else 0.0)-(0.5 if _viewport.use_taa else 0.0)
	_viewport.msaa_3d=Viewport.MSAA_DISABLED
	_viewport.use_taa=false
	_viewport.screen_space_aa=Viewport.SCREEN_SPACE_AA_FXAA
	_viewport.texture_mipmap_bias=effective_bias+0.25
	film = load("res://native_film_candidate/original_native_film.gd").new()
	bloom = load("res://native_bloom_candidate/original_native_bloom.gd").new()
	# Main-map IntoHouseTrigger6 does not override BloomIntensity. S5's .5 is unrelated.
	bloom.set_source_intensities(5.0, 5.0)
	bloom.set_source_postprocess_quality(3)
	_compositor = Compositor.new()
	_compositor.compositor_effects = [bloom, film]
	scene.camera.compositor = _compositor
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_environment.tonemap_exposure = 1.0
	_environment.glow_enabled = false
	scene.environment_driver.sun_energy_per_source_unit = 1.0 / PI
	var source_sun: Dictionary = _sun.get_meta("ue_properties", {})
	_sun.light_energy = float(source_sun.get("Intensity", 30.0)) / PI
	report = {"status":"installing", "map":scene.slug, "bloom_intensities":[5.0,5.0],
		"bloom_quality_assumption":3, "distortion_requested":enable_distortion}
	character = load("res://source_lighting_candidate/original_character_surface_adapter.gd").new()
	report["character"] = character.apply(scene.player.sprite, _find_lightfunction_material(scene.world))
	ambient = load("res://source_ambient_candidate/original_ambient_surface_adapter.gd").new()
	report["ambient"] = ambient.apply(scene, scene.slug, _find_lightfunction_material(scene.world))
	birds = load("res://source_bird_candidate/source_bird_material_adapter.gd").new()
	report["birds"] = birds.apply(scene, scene.slug, _find_lightfunction_material(scene.world))
	leaf = load("res://source_leaf_candidate/source_leaf_adapter.gd").new()
	report["leaf"] = leaf.install(scene.world, _find_lightfunction_material(scene.world))
	sh = load("res://sh9_candidate/source_sh9_adapter.gd").new()
	sh.restore_on_exit_tree = false # This owner unwinds cone/fog/SH in shutdown().
	add_child(sh)
	report["sh"] = sh.install(scene, "res://sh9_candidate/"+scene.slug+"-source-sh9.json", {"include_wind":true})
	sh.attach_house_driver(scene.house_driver)
	local_lights = load("res://source_lighting_candidate/original_local_light_calibration.gd").new()
	report["local_lights"] = local_lights.apply(scene.world, true, true)
	height_fog = load("res://source_lighting_candidate/source_height_fog_adapter.gd").new()
	add_child(height_fog)
	report["height_fog"] = height_fog.install(scene, _environment, "res://source_lighting_candidate/"+scene.slug+"-height-fog.json", {})
	height_fog.attach_house_driver(scene.house_driver)
	local_cones = load("res://source_lighting_candidate/original_local_cone_adapter.gd").new()
	report["local_cones"] = local_cones.apply(scene)
	transparent_sky = load("res://source_transparent_sky_candidate/source_transparent_sky_adapter.gd").new()
	transparent_sky.restore_on_exit_tree = false
	add_child(transparent_sky)
	report["transparent_sky"] = transparent_sky.install(scene, "res://sh9_candidate/"+scene.slug+"-source-sh9.json", {})
	transparent_sky.attach_house_driver(scene.house_driver)
	reflection = load("res://source_reflection_candidate/source_reflection_adapter.gd").new()
	reflection.restore_on_exit_tree = false
	add_child(reflection)
	report["reflection"] = reflection.install(scene, _environment,
		"res://source_reflection_candidate/"+scene.slug+"-source-scene-capture.res", "res://sh9_candidate/"+scene.slug+"-source-sh9.json")
	reflection.attach_house_driver(scene.house_driver)
	if enable_distortion:
		distortion = load("res://native_distortion_candidate/original_native_distortion.gd").new()
		splash_binding = load("res://native_distortion_candidate/source_splash_binding.gd").new()
		add_child(splash_binding)
		splash_binding.configure(scene.world, distortion)
		water_binding = load("res://source_water_distortion_candidate/source_water_binding.gd").new()
		add_child(water_binding)
		report["water_distortion"] = water_binding.configure(scene, distortion)
		_compositor.compositor_effects = [distortion, bloom, film]
	if enable_atmosphere:
		atmosphere = load("res://source_atmosphere_candidate/source_atmosphere_adapter.gd").new()
		add_child(atmosphere)
		report["atmosphere"] = atmosphere.install(scene.camera,
			"res://source_atmosphere_candidate/"+scene.slug+"-atmosphere.json",
			"res://source_lighting_candidate/"+scene.slug+"-height-fog.json",{})
		atmosphere.attach_house_driver(scene.house_driver)
	depth_of_field = load("res://source_hdr_dof_candidate/source_hdr_dof_adapter.gd").new()
	add_child(depth_of_field)
	report["depth_of_field"] = depth_of_field.install(scene.camera, "res://source_dof_candidate/source-dof.json")
	depth_of_field.attach_house_driver(scene.house_driver)
	separate_translucency = load("res://source_separate_translucency/separate_adapter.gd").new()
	add_child(separate_translucency)
	report["separate_translucency"] = separate_translucency.install(scene)
	scene.house_driver.house_state_changed.connect(_on_house_state)
	_on_house_state(scene.house_driver.is_in_house)
	report.status = "installed"
	print("SOURCE_RENDERER_READY ", JSON.stringify({"map":scene.slug,"sh_materials":report.sh.get("bound",0),"fog_materials":report.height_fog.get("bound",0),"cone_materials":report.local_cones.get("bound",0),"distortion":enable_distortion}))
	return report

func _on_house_state(inside: bool) -> void:
	film.set_source_indoor(inside)
	bloom.set_source_indoor(inside)
	if character != null and character.material != null:
		character.material.set_shader_parameter("source_lf_sun_enabled", not inside)
	if ambient != null: ambient.set_sun_enabled(not inside)
	if birds != null: birds.set_sun_enabled(not inside)
	if leaf != null: leaf.set_sun_enabled(not inside)

func _find_lightfunction_material(node: Node) -> ShaderMaterial:
	var materials: Array[Material] = []
	if node is GeometryInstance3D and node.material_override != null:
		materials.append(node.material_override)
	elif node is MeshInstance3D and node.mesh != null:
		for i in node.mesh.get_surface_count(): materials.append(node.get_active_material(i))
	elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
		for i in node.multimesh.mesh.get_surface_count(): materials.append(node.multimesh.mesh.surface_get_material(i))
	for material in materials:
		if material is ShaderMaterial:
			var count: Variant = material.get_shader_parameter("source_lf_count")
			if count is int and count > 0: return material
	for child in node.get_children():
		var found := _find_lightfunction_material(child)
		if found != null: return found
	return null

func shutdown() -> Dictionary:
	if _saved.is_empty(): return {"status":"already_stopped"}
	# Flush the house's cached exterior state before restoring the renderer baseline.
	if is_instance_valid(_scene) and is_instance_valid(_scene.house_driver):
		_scene.house_driver.reset_outdoors()
		if _scene.house_driver.house_state_changed.is_connected(_on_house_state):
			_scene.house_driver.house_state_changed.disconnect(_on_house_state)
	var restored := {"status":"restored"}
	if is_instance_valid(separate_translucency): restored["separate_translucency"] = separate_translucency.restore()
	if is_instance_valid(depth_of_field): restored["depth_of_field"] = depth_of_field.restore()
	if is_instance_valid(atmosphere): restored["atmosphere"] = atmosphere.restore()
	if is_instance_valid(reflection): restored["reflection"] = reflection.restore()
	if is_instance_valid(transparent_sky): restored["transparent_sky"] = transparent_sky.restore()
	if local_cones != null: restored["local_cones"] = local_cones.restore()
	if is_instance_valid(height_fog): restored["height_fog"] = height_fog.restore()
	if local_lights != null: local_lights.restore()
	if is_instance_valid(sh): restored["sh"] = sh.restore()
	if leaf != null: restored["leaf"] = leaf.restore()
	if birds != null: restored["birds"] = birds.restore()
	if ambient != null: restored["ambient"] = ambient.restore()
	if character != null: character.restore()
	if is_instance_valid(_scene) and is_instance_valid(_scene.camera):
		_scene.camera.compositor = _saved.compositor
	if is_instance_valid(_scene) and is_instance_valid(_scene.environment_driver):
		_scene.environment_driver.sun_energy_per_source_unit = _saved.sun_unit
	if is_instance_valid(_sun): _sun.light_energy = _saved.sun_energy
	if is_instance_valid(_viewport):
		_viewport.msaa_3d=_saved.msaa
		_viewport.screen_space_aa=_saved.screen_aa
		_viewport.use_taa=_saved.taa
		_viewport.texture_mipmap_bias=_saved.mipmap_bias
	if _environment != null:
		_environment.tonemap_mode = _saved.tonemap
		_environment.tonemap_exposure = _saved.exposure
		_environment.glow_enabled = _saved.glow
	if is_instance_valid(water_binding):
		water_binding.shutdown()
	if is_instance_valid(splash_binding):
		splash_binding.set_process(false)
		splash_binding.effect = null
	_compositor = null
	distortion = null
	bloom = null
	film = null
	separate_translucency = null
	reflection = null
	transparent_sky = null
	local_cones = null
	local_lights = null
	character = null
	ambient = null
	birds = null
	leaf = null
	_saved.clear()
	return restored

func _exit_tree() -> void:
	shutdown()
