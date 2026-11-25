extends Node
## Reversible global reflection diagnostic. No model or material shader changes.
## Source capture near plane and black lower hemisphere are already baked in.
## Godot's radiance convolution/BRDF remain an explicit cross-engine difference.
const SKY_SHADER = preload("source_reflection_sky.gdshader")
var report: Dictionary = {}
var restore_on_exit_tree := true
var _environment: Environment
var _candidate_sky: Sky
var _saved: Dictionary = {}
var _probes: Array[Dictionary] = []
var _house: Node
var _inside := false
var _mode := 2

func install(scene: Node, environment: Environment, capture_file: String, coefficient_file: String) -> Dictionary:
	if not _saved.is_empty(): return {"error":"Already installed; restore first."}
	if not is_instance_valid(scene) or environment == null or environment.sky == null:
		return {"error":"Missing scene/environment/visible sky."}
	var old_material: Material = environment.sky.sky_material
	if not old_material is ShaderMaterial or old_material.shader == null:
		return {"error":"Expected the existing source visible sky shader."}
	var code: String = old_material.shader.code
	if not code.contains("vec3 ue_direction = vec3(EYEDIR.x,EYEDIR.z,EYEDIR.y);") or not code.contains("COLOR = texture(source_open_sky,ue_direction).rgb;"):
		return {"error":"Visible-sky signature changed; refusing to substitute it."}
	var visible_cube: Variant = old_material.get_shader_parameter("source_open_sky")
	var capture: Variant = load(capture_file)
	if not visible_cube is Cubemap or not capture is Cubemap:
		return {"error":"Expected source visible cube and already oriented HDR Cubemap."}
	if capture.get_width() != 128 or capture.get_layers() != 6 or capture.get_format() != Image.FORMAT_RGBAH:
		return {"error":"Expected 128x128x6 RGBA16F source capture."}
	var coefficients: Variant = JSON.parse_string(FileAccess.get_file_as_string(coefficient_file))
	if not coefficients is Dictionary or coefficients.get("schema", "") != "source_sh9_v1" or bool(coefficients.get("gain_applied_to_coefficients", true)):
		return {"error":"Expected untinted source SH9 metadata for the shared capture."}
	var gain: Array = coefficients.get("source_skylight_linear_gain", [])
	if gain.size() != 3: return {"error":"Missing source linear sky gain."}
	var linear_gain := Vector3(float(gain[0]),float(gain[1]),float(gain[2]))
	if not linear_gain.is_finite(): return {"error":"Non-finite sky gain."}
	_probes.clear()
	for node: Node in scene.find_children("*", "ReflectionProbe", true, false):
		if str(node.name) == "OriginalSceneReflection_Adapted" and node.has_meta("source_skylight"):
			_probes.append({"probe":node,"visible":node.visible})
	if _probes.size() != 1: return {"error":"Expected exactly one old source SkyLight adaptation probe.","found":_probes.size()}
	_environment = environment
	_saved = {"sky":environment.sky,"energy":environment.ambient_light_energy,"reflection_source":environment.reflected_light_source}
	var material := ShaderMaterial.new()
	material.shader = SKY_SHADER
	material.set_shader_parameter("source_scene_capture",capture)
	material.set_shader_parameter("source_open_sky",visible_cube)
	# Vector3 avoids the automatic Color conversion; HDR input is not source_color.
	material.set_shader_parameter("source_skylight_linear_gain",linear_gain)
	_candidate_sky = Sky.new()
	_candidate_sky.sky_material = material
	_candidate_sky.process_mode = Sky.PROCESS_MODE_QUALITY
	_candidate_sky.radiance_size = Sky.RADIANCE_SIZE_128
	report = {"status":"installed","map":str(scene.get("slug")),"capture_file":capture_file,
		"coefficient_file":coefficient_file,"shared_capture_manifest_sha256":coefficients.get("capture_manifest_sha256", ""),
		"capture_format":"RGBA16F linear, Godot faces, lower hemisphere already black",
		"source_gain":gain,"gain_applications":1,"source_near_m":20.0,"source_origin_m":[0,0,0],
		"hidden_adaptation_probes":_probes.size(),"radiance_size":128,"sky_process":"QUALITY",
		"original_environment_energy":_saved.energy,"candidate_environment_energy":1.0,
		"visible_cube_preserved":material.get_shader_parameter("source_open_sky") == visible_cube,
		"material_shaders_mutated":0,"sh_coefficients_mutated":0,"mode":2,
		"limits":["All materials receiving environment/probe reflections are affected, not only Water.",
			"Current SH9 IRRADIANCE remains unchanged. Materials without SH9 may receive changed fallback diffuse from the new sky.",
			"Godot QUALITY convolution and BRDF are used. Original UE mip0 also has a small GGX prefilter; this is not bit-exact.",
			"The cube was captured from the reconstructed scene, not extracted as a native runtime UE GPU capture.",
			"Capture predates later material refinements; do not call the stored scene radiance a live recapture.",
			"Only the identified incorrect adaptation probe is hidden; unrelated probes, if later added, are not removed."]}
	set_mode(2)
	return report

func set_mode(mode: int) -> void:
	_mode = clampi(mode,0,2)
	if _saved.is_empty(): return
	# 0 = original probe + original fallback; 1 = probe off only; 2 = captured sky.
	_environment.sky = _candidate_sky if _mode == 2 else _saved.sky
	if not _inside:
		_environment.ambient_light_energy = 1.0 if _mode == 2 else float(_saved.energy)
		_environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY if _mode == 2 else int(_saved.reflection_source)
	else:
		_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	for state: Dictionary in _probes:
		if is_instance_valid(state.probe): state.probe.visible = bool(state.visible) and _mode == 0 and not _inside
	report["mode"] = _mode
	report["inside"] = _inside

func attach_house_driver(driver: Node) -> Dictionary:
	if not is_instance_valid(driver) or not driver.has_signal("house_state_changed"):
		return {"error":"Missing source house state signal."}
	if is_instance_valid(_house) and _house.house_state_changed.is_connected(_on_house_state):
		_house.house_state_changed.disconnect(_on_house_state)
	_house = driver
	_house.house_state_changed.connect(_on_house_state)
	_on_house_state(bool(_house.get("is_in_house")))
	return {"attached":true,"inside":_inside}

func _on_house_state(inside: bool) -> void:
	_inside = inside
	set_mode(_mode)

func restore() -> Dictionary:
	if _saved.is_empty(): return {"status":"already_restored","errors":[]}
	# The renderer owner must flush the source house cache before restoring this
	# global state, just as it already does before unwinding the source stack.
	if _inside: return {"status":"deferred","errors":["Reset the house driver outdoors before restoring the reflection adapter."]}
	if _environment.sky != _candidate_sky and _environment.sky != _saved.sky:
		return {"status":"conflict","errors":["Another owner replaced the environment sky; saved state retained."]}
	if is_instance_valid(_house) and _house.house_state_changed.is_connected(_on_house_state):
		_house.house_state_changed.disconnect(_on_house_state)
	_environment.sky = _saved.sky
	_environment.ambient_light_energy = _saved.energy
	_environment.reflected_light_source = _saved.reflection_source
	var errors: Array[String] = []
	for state: Dictionary in _probes:
		if is_instance_valid(state.probe): state.probe.visible = state.visible
		else: errors.append("Saved adaptation probe disappeared.")
	if _environment.sky != _saved.sky or _environment.ambient_light_energy != _saved.energy or _environment.reflected_light_source != _saved.reflection_source:
		errors.append("Environment state did not restore exactly.")
	var result := {"status":"restored" if errors.is_empty() else "failed","errors":errors,"restored_probes":_probes.size()}
	_saved.clear()
	_probes.clear()
	_candidate_sky = null
	_environment = null
	_house = null
	return result

func _exit_tree() -> void:
	if restore_on_exit_tree and not _saved.is_empty(): restore()
