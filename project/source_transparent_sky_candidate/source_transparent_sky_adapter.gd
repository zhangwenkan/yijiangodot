extends Node
## Source sky diffuse only. Direct light, TLV, lightmaps and reflections are separate.
## Install after existing source surface/fog/local-cone adapters; restore before them.
var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _seen: Dictionary = {}
var _cache: Dictionary = {}
var _coefficients := PackedVector3Array()
var _gain := Vector3.ONE
var _library := ""
var _house: Node
var _skylight_enabled := true
var _mode := 1
var restore_on_exit_tree := true
const FAMILIES := ["Ocean", "Water", "Smoke1", "SmokeSubUV", "Splash"]

func install(world: Node, coefficient_file: String, options: Dictionary = {}) -> Dictionary:
	if not _saved.is_empty(): return {"error":"Already installed; restore first."}
	if not is_instance_valid(world): return {"error":"Missing world."}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(coefficient_file))
	if not parsed is Dictionary or parsed.get("schema", "") != "source_sh9_v1" or bool(parsed.get("gain_applied_to_coefficients", true)):
		return {"error":"Expected untinted source SH9 E/pi coefficients."}
	var entries: Array = parsed.get("e_over_pi_coefficients", [])
	var gain_array: Array = parsed.get("source_skylight_linear_gain", [])
	if entries.size() != 9 or gain_array.size() != 3: return {"error":"Incomplete SH9 policy."}
	_coefficients.clear()
	for entry: Array in entries:
		if entry.size() != 3: return {"error":"Invalid SH coefficient."}
		var coefficient := Vector3(float(entry[0]), float(entry[1]), float(entry[2]))
		if not coefficient.is_finite(): return {"error":"Non-finite SH coefficient."}
		_coefficients.append(coefficient)
	_gain = Vector3(float(gain_array[0]), float(gain_array[1]), float(gain_array[2]))
	if not _gain.is_finite(): return {"error":"Non-finite SH gain."}
	_library = FileAccess.get_file_as_string("res://sh9_candidate/source_sh9.gdshaderinc")
	if _library.is_empty(): return {"error":"Missing existing source SH9 library."}
	_mode = clampi(int(options.get("mode", 1)), 0, 4)
	_skylight_enabled = bool(options.get("skylight_enabled", true))
	_seen.clear()
	_cache.clear()
	report = {"status":"installing", "version":1, "bound":0, "materials":[], "unsupported":[], "skipped":[],
		"family_counts":{"Ocean":0,"Water":0,"Smoke1":0,"SmokeSubUV":0,"Splash":0},
		"coefficient_file":coefficient_file, "mode":_mode, "skylight_enabled":_skylight_enabled,
		"domain":"E/pi; existing source capture coefficients, linear sky tint/intensity once; IRRADIANCE replacement",
		"limits":["Source sky-enabled cooked permutations, not a captured runtime UE permutation or SH buffer.",
			"Existing cross-engine SH9 capture and CPU mip projection; not native UE sky capture.",
			"No TLV, ILC/lightmap, source bent-normal sky occlusion, transparent self-shadow or original BRDF restoration.",
			"Actual current normals are retained; original tangent/particle normal parity is not newly established.",
			"Modes 2 and 4 suppress bound-material emission/reflection; caller must mute scene direct lights for sky-only captures. Alpha/fog/postprocessing remain.",
			"Modes 0 and 4 recover baseline ambient; mode 3 zeros source diffuse sky, never fallback."]}
	_scan(world)
	report.status = "installed"
	print("SOURCE_TRANSPARENT_SKY_INSTALLED ", JSON.stringify(report))
	return report

func _scan(node: Node) -> void:
	if node == self: return
	if node is GeometryInstance3D:
		_bind(node.material_override, node)
		_bind(node.material_overlay, node)
	if node is MeshInstance3D and node.mesh != null and node.material_override == null:
		for index in node.mesh.get_surface_count(): _bind(node.get_active_material(index), node)
	elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null and node.material_override == null:
		for index in node.multimesh.mesh.get_surface_count(): _bind(node.multimesh.mesh.surface_get_material(index), node)
	for child in node.get_children(): _scan(child)

func _family(code: String) -> String:
	if code.contains("float source_fixed_depth(") and code.contains("uniform float fake_spec_intensity"): return "Ocean"
	if code.contains("uniform float source_metallic") and code.contains("uniform sampler2D waves_2_normal"): return "Water"
	if code.contains("vec3 source_blackbody(") and code.contains("uniform sampler2D source_dynamic_parameters"): return "Smoke1"
	if code.contains("uniform sampler2D source_tiled") and code.contains("vec3 source_base_color") and code.contains("source_contact_fade(150.0"): return "SmokeSubUV"
	if code.contains("uniform sampler2D splash_color_a") and code.contains("uniform sampler2D splash_color_b"): return "Splash"
	return ""

func _bind(material: Material, node: Node) -> void:
	if material == null or _seen.has(material.get_instance_id()): return
	_seen[material.get_instance_id()] = true
	_bind(material.next_pass, node)
	if not material is ShaderMaterial or material.shader == null: return
	var original: Shader = material.shader
	var code: String = original.code
	var clean := _without_comments(code)
	var family := _family(clean)
	if family.is_empty(): return
	var label := {"material":material.resource_name, "family":family, "first_node":str(node.get_path()),
		"source_material":str(material.get_meta("source_material", "")), "shader_sha256_before":code.sha256_text()}
	if _matches(clean, "\\bunshaded\\b") or bool(material.get_meta("source_unshaded", false)):
		label.reason = "unshaded"
		report.skipped.append(label)
		return
	if _matches(clean, "\\bIRRADIANCE\\b") or clean.contains("source_sh9_evaluate"):
		label.reason = "Already owns ambient/SH9; restore the other candidate first."
		report.unsupported.append(label)
		return
	var fragment := _function_bounds(clean, "fragment")
	var header := RegEx.new()
	header.compile("shader_type\\s+spatial\\s*;")
	var header_match := header.search(clean)
	if fragment.x < 0 or header_match == null or _matches(clean.substr(fragment.x, fragment.y-fragment.x), "\\breturn\\b"):
		label.reason = "Requires ordinary spatial fragment without early return."
		report.unsupported.append(label)
		return
	var parameters: Dictionary = {}
	for item in original.get_shader_uniform_list(): parameters[item.name] = material.get_shader_parameter(item.name)
	var uses_normal_map := _matches(clean, "\\bNORMAL_MAP\\b")
	if not _cache.has(original.get_instance_id()):
		var tail := "\n// Source transparent sky diffuse: replace old ambient using the final shading normal.\nvec3 source_transparent_sky_n = NORMAL;\n"
		if uses_normal_map:
			tail += "vec3 source_transparent_sky_nm = NORMAL_MAP;\nsource_transparent_sky_nm.xy = source_transparent_sky_nm.xy * 2.0 - 1.0;\nsource_transparent_sky_nm.z = sqrt(max(0.0, 1.0 - dot(source_transparent_sky_nm.xy, source_transparent_sky_nm.xy)));\nsource_transparent_sky_n = normalize(mix(NORMAL, TANGENT * source_transparent_sky_nm.x + BINORMAL * source_transparent_sky_nm.y + NORMAL * source_transparent_sky_nm.z, NORMAL_MAP_DEPTH));\n"
		else:
			tail += "source_transparent_sky_n = normalize(source_transparent_sky_n);\n"
		tail += "vec3 source_transparent_sky_world_n = normalize((INV_VIEW_MATRIX * vec4(source_transparent_sky_n, 0.0)).xyz);\nvec3 source_transparent_sky_value = source_sh9_enabled ? source_sh9_evaluate(source_transparent_sky_world_n) : vec3(0.0);\n"
		tail += "bool source_transparent_sky_baseline = source_transparent_sky_mode == 0 || source_transparent_sky_mode == 4;\nIRRADIANCE = vec4(source_transparent_sky_mode == 3 ? vec3(0.0) : source_transparent_sky_value, source_transparent_sky_baseline ? 0.0 : 1.0);\n"
		tail += "if (source_transparent_sky_mode == 2 || source_transparent_sky_mode == 4) { EMISSION = vec3(0.0); RADIANCE = vec4(0.0, 0.0, 0.0, 1.0); }\n"
		# Original vertex/fragment expressions and the entire light() are retained.
		# Actual lit particles have no custom light(); do not replace their built-in light path.
		var insertions: Array[Dictionary] = [
			{"offset":fragment.y,"text":tail},
			{"offset":_function_start(clean,"fragment"),"text":_library+"\n"},
			{"offset":header_match.get_end(),"text":"\nuniform int source_transparent_sky_mode = 1;\n"}]
		insertions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.offset) > int(b.offset))
		var injected := code
		for insertion in insertions: injected = injected.insert(insertion.offset, insertion.text)
		var replacement := Shader.new()
		replacement.code = injected
		_cache[original.get_instance_id()] = replacement
	var installed: Shader = _cache[original.get_instance_id()]
	_saved.append({"material":material, "shader":original, "installed":installed, "parameters":parameters, "family":family})
	material.shader = installed
	for name in parameters: material.set_shader_parameter(name, parameters[name])
	material.set_shader_parameter("source_sh9_coefficients", _coefficients)
	material.set_shader_parameter("source_sh9_linear_gain", _gain)
	material.set_shader_parameter("source_sh9_enabled", _skylight_enabled)
	material.set_shader_parameter("source_transparent_sky_mode", _mode)
	label["normal_mode"] = "NORMAL_MAP; existing unnormalized TBN; Forward+ decode" if uses_normal_map else "final NORMAL"
	label["shader_sha256_after"] = installed.code.sha256_text()
	label["vertex_preserved"] = _function_text(code,"vertex") == _function_text(installed.code,"vertex")
	label["fragment_preserved_as_prefix"] = _function_body(installed.code,"fragment").begins_with(_function_body(code,"fragment"))
	label["light_body_preserved"] = _function_text(installed.code,"light") == _function_text(code,"light")
	label["has_custom_light"] = not _function_text(code,"light").is_empty()
	label["alpha_expression_preserved"] = true # Tail never assigns ALPHA.
	report.materials.append(label)
	report.bound += 1
	report.family_counts[family] += 1

func _matches(value: String, expression: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile(expression)
	return pattern.search(value) != null

func _function_start(clean: String, function: String) -> int:
	var pattern := RegEx.new()
	pattern.compile("void\\s+"+function+"\\s*\\(\\s*\\)\\s*\\{")
	var found := pattern.search(clean)
	return found.get_start() if found != null else -1

func _function_bounds(clean: String, function: String) -> Vector2i:
	var start := _function_start(clean, function)
	if start < 0: return Vector2i(-1,-1)
	var opening := clean.find("{", start)
	var cursor := opening+1
	var depth := 1
	while cursor < clean.length() and depth > 0:
		if clean[cursor] == "{": depth += 1
		elif clean[cursor] == "}": depth -= 1
		cursor += 1
	return Vector2i(opening+1,cursor-1) if depth == 0 else Vector2i(-1,-1)

func _function_text(code: String, function: String) -> String:
	var clean := _without_comments(code)
	var start := _function_start(clean, function)
	var bounds := _function_bounds(clean, function)
	return code.substr(start,bounds.y+1-start) if bounds.x >= 0 else ""

func _function_body(code: String, function: String) -> String:
	var bounds := _function_bounds(_without_comments(code), function)
	return code.substr(bounds.x,bounds.y-bounds.x) if bounds.x >= 0 else ""

func _without_comments(code: String) -> String:
	var pattern := RegEx.new()
	pattern.compile("(?s)/\\*.*?\\*/|//[^\\n]*")
	var clean := code
	var matches := pattern.search_all(code)
	for i in range(matches.size()-1,-1,-1):
		var found: RegExMatch = matches[i]
		var blank := ""
		for character in found.get_string(): blank += "\n" if character == "\n" else " "
		clean = clean.substr(0,found.get_start()) + blank + clean.substr(found.get_end())
	return clean

func set_mode(mode: int) -> void:
	# Modes 2/4 need caller-controlled light muting for a true sky-only capture.
	_mode = clampi(mode,0,4)
	for state in _saved:
		if is_instance_valid(state.material): state.material.set_shader_parameter("source_transparent_sky_mode",_mode)
	report.mode = _mode

func set_skylight_enabled(enabled: bool) -> void:
	_skylight_enabled = enabled
	for state in _saved:
		if is_instance_valid(state.material): state.material.set_shader_parameter("source_sh9_enabled",enabled)
	report.skylight_enabled = enabled

func attach_house_driver(driver: Node) -> Dictionary:
	_detach_house()
	if not is_instance_valid(driver) or not driver.has_signal("house_state_changed"): return {"error":"Missing house signal."}
	_house = driver
	driver.connect("house_state_changed",Callable(self,"_on_house_state"))
	var inside: Variant = driver.get("is_in_house")
	_on_house_state(inside is bool and inside)
	return {"attached":true,"skylight_enabled":_skylight_enabled}

func _on_house_state(inside: bool) -> void:
	set_skylight_enabled(not inside)

func _detach_house() -> void:
	if is_instance_valid(_house) and _house.is_connected("house_state_changed",Callable(self,"_on_house_state")):
		_house.disconnect("house_state_changed",Callable(self,"_on_house_state"))
	_house = null

func restore() -> Dictionary:
	_detach_house()
	var restored := 0
	var errors: Array[String] = []
	var remaining: Array[Dictionary] = []
	for state in _saved:
		if not is_instance_valid(state.material): continue
		var material: ShaderMaterial = state.material
		if material.shader != state.installed:
			errors.append("Another owner changed "+material.resource_name+"; restore it first.")
			remaining.append(state)
			continue
		material.shader = state.shader
		for name in state.parameters:
			material.set_shader_parameter(name,state.parameters[name])
			if material.get_shader_parameter(name) != state.parameters[name]: errors.append("Failed to restore "+str(name))
		restored += 1
	_saved = remaining
	if remaining.is_empty():
		_cache.clear()
		_seen.clear()
	var result := {"restored_materials":restored,"errors":errors}
	report["restoration"] = result
	report.status = "restored" if errors.is_empty() else "restore_failed"
	return result

func _exit_tree() -> void:
	if restore_on_exit_tree and not _saved.is_empty(): restore()
