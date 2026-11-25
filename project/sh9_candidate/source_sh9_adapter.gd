extends Node
## Independent reversible candidate: ordinary source surfaces and landscape only.
## install(world, absolute_or_res_json, options) after source adapters/lightfunctions.
## No mesh geometry, textures, direct lights or Environment properties are changed.

var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _seen: Dictionary = {}
var _shader_cache: Dictionary = {}
var _coefficients := PackedVector3Array()
var _gain := Vector3.ONE
var _options: Dictionary = {}
var _library := ""
var _skylight_enabled := true
var _house_driver: Node
var restore_on_exit_tree := true

func install(world: Node, coefficient_file: String, options: Dictionary = {}) -> Dictionary:
	if not _saved.is_empty():
		return {"error":"Already installed; call restore() before reinstalling."}
	if not is_instance_valid(world):
		return {"error":"Missing world."}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(coefficient_file))
	if not parsed is Dictionary or parsed.get("schema", "") != "source_sh9_v1":
		return {"error":"Invalid coefficient JSON."}
	var entries: Array = parsed.get("e_over_pi_coefficients", [])
	if entries.size() != 9 or bool(parsed.get("gain_applied_to_coefficients", true)):
		return {"error":"Need nine untinted E/pi RGB coefficients."}
	_coefficients.clear()
	for entry: Array in entries:
		if entry.size() != 3:
			return {"error":"Coefficient must have three channels."}
		var coefficient := Vector3(float(entry[0]), float(entry[1]), float(entry[2]))
		if not coefficient.is_finite():
			return {"error":"Non-finite coefficient."}
		_coefficients.append(coefficient)
	var gain_array: Array = parsed.get("source_skylight_linear_gain", [])
	if gain_array.size() != 3:
		return {"error":"Missing source linear tint/intensity gain."}
	_gain = Vector3(float(gain_array[0]), float(gain_array[1]), float(gain_array[2]))
	if not _gain.is_finite():
		return {"error":"Non-finite source gain."}
	var script_path: String = get_script().resource_path
	_library = FileAccess.get_file_as_string(script_path.get_base_dir().path_join("source_sh9.gdshaderinc"))
	if _library.is_empty():
		return {"error":"Missing adjacent source_sh9.gdshaderinc."}
	_options = options
	_skylight_enabled = bool(options.get("skylight_enabled", true))
	_seen.clear()
	_shader_cache.clear()
	report = {"status":"installing", "version":3, "coefficient_file":coefficient_file,
		"domain":"E/pi, source sky tint and intensity applied once", "bound":0,
		"landscape_materials":0, "surface_materials":0, "wind_materials":0, "normal_map_materials":0,
		"skylight_enabled":_skylight_enabled, "include_wind":bool(options.get("include_wind", false)),
		"materials":[], "skipped":[], "unsupported":[],
		"limits":["Cross-engine capture and CPU per-face box mip, not original UE capture buffer.",
		"Shader compilation/GPU result must be checked by caller; grammar validation is insufficient.",
		"Wind is opt-in; water/ocean, particles and unshaded materials remain excluded.",
		"No distance-field sky visibility, bent normals, precomputed GI or exposure normalization is added.",
		"The caller must keep camera exposure at 1 and existing probes ambient-disabled for this diagnostic."]}
	_scan(world)
	report["status"] = "installed"
	print("SOURCE_SH9_INSTALLED ", JSON.stringify(report))
	return report

func _scan(node: Node) -> void:
	if node == self:
		return
	if node is GeometryInstance3D:
		_bind(node.material_override, node)
		_bind(node.material_overlay, node)
		if node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count():
				_bind(node.get_active_material(surface), node)
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			for surface in node.multimesh.mesh.get_surface_count():
				_bind(node.multimesh.mesh.surface_get_material(surface), node)
	for child in node.get_children():
		_scan(child)

func _bind(material: Material, node: Node) -> void:
	if material == null or _seen.has(material.get_instance_id()):
		return
	_seen[material.get_instance_id()] = true
	_bind(material.next_pass, node)
	if not material is ShaderMaterial or material.shader == null:
		return
	var label := {"material":material.resource_name, "shader":material.shader.resource_path,
		"first_node":str(node.get_path()), "source_material":str(material.get_meta("source_material", ""))}
	var landscape := bool(material.get_meta("source_landscape_compiled", false))
	var surface := bool(material.get_meta("source_surface_adapter", false))
	var wind := bool(material.get_meta("source_wind_adapter", false))
	if not landscape and not surface and not wind:
		return
	if wind and not bool(_options.get("include_wind", false)):
		label["reason"] = "wind not opted in"
		report.skipped.append(label)
		return
	if bool(material.get_meta("source_unshaded", false)):
		label["reason"] = "unshaded"
		report.skipped.append(label)
		return
	if (landscape and not bool(_options.get("include_landscape", true))) or (not landscape and not wind and not bool(_options.get("include_surface", true))):
		return
	var filter_names: Array = _options.get("material_names", [])
	if not filter_names.is_empty() and not filter_names.has(material.resource_name):
		return
	var original: Shader = material.shader
	var code := original.code
	var clean := _without_comments(code)
	var source_unshaded_value: Variant = material.get_shader_parameter("source_unshaded")
	var parameter_unshaded: bool = source_unshaded_value is bool and source_unshaded_value
	if _matches(clean, "\\bunshaded\\b") or parameter_unshaded:
		label["reason"] = "unshaded shader/parameter"
		report.skipped.append(label)
		return
	if not _matches(clean, "shader_type\\s+spatial\\s*;") or _matches(clean, "\\bIRRADIANCE\\b"):
		label["reason"] = "not spatial or already writes/reads IRRADIANCE"
		report.unsupported.append(label)
		return
	var bounds := _fragment_bounds(clean)
	if bounds.x < 0 or _matches(clean.substr(bounds.x, bounds.y-bounds.x), "\\breturn\\b"):
		label["reason"] = "missing fragment or fragment early return"
		report.unsupported.append(label)
		return
	var parameters: Dictionary = {}
	for item in original.get_shader_uniform_list():
		parameters[item.name] = material.get_shader_parameter(item.name)
	var uses_normal_map := _matches(clean, "\\bNORMAL_MAP\\b")
	if not _shader_cache.has(original.get_instance_id()):
		var fragment_tail := "\n// source SH9 ambient replacement: evaluate the same final shading normal.\nvec3 source_sh9_n = NORMAL;\n"
		if uses_normal_map:
			# Match Forward+ NORMAL_MAP handling; keep unnormalized TBN (MikkTSpace).
			fragment_tail += "vec3 source_sh9_nm = NORMAL_MAP;\nsource_sh9_nm.xy = source_sh9_nm.xy * 2.0 - 1.0;\nsource_sh9_nm.z = sqrt(max(0.0, 1.0 - dot(source_sh9_nm.xy, source_sh9_nm.xy)));\nsource_sh9_n = normalize(mix(NORMAL, TANGENT * source_sh9_nm.x + BINORMAL * source_sh9_nm.y + NORMAL * source_sh9_nm.z, NORMAL_MAP_DEPTH));\n"
		else:
			fragment_tail += "source_sh9_n = normalize(source_sh9_n);\n"
		fragment_tail += "vec3 source_sh9_world_normal = normalize((INV_VIEW_MATRIX * vec4(source_sh9_n, 0.0)).xyz);\nIRRADIANCE = vec4(source_sh9_enabled ? source_sh9_evaluate(source_sh9_world_normal) : vec3(0.0), 1.0);\n"

		if bool(material.get_meta("source_two_sided_foliage", false)):
			# Cooked basepass also evaluates sky SH for the opposite normal.
			# Scalar AO here retains the existing adapter's documented AO limit.
			fragment_tail += "EMISSION += source_sh9_enabled ? source_leaf_subsurface * source_sh9_evaluate(-source_sh9_world_normal) * AO : vec3(0.0);\n"
		var replacement := Shader.new()
		# Append functions and uniforms before the existing fragment. Existing light()
		# and includes remain byte-for-byte except for these two insertion points.
		var injected := code.insert(bounds.y, fragment_tail)
		var fragment_pattern := RegEx.new()
		fragment_pattern.compile("void\\s+fragment\\s*\\(\\s*\\)\\s*\\{")
		var declaration := fragment_pattern.search(clean)
		injected = injected.insert(declaration.get_start(), _library + "\n")
		replacement.code = injected
		_shader_cache[original.get_instance_id()] = replacement
	_saved.append({"object":material, "shader":original, "parameters":parameters})
	material.shader = _shader_cache[original.get_instance_id()]
	for parameter in parameters:
		material.set_shader_parameter(parameter, parameters[parameter])
	material.set_shader_parameter("source_sh9_coefficients", _coefficients)
	material.set_shader_parameter("source_sh9_linear_gain", _gain)
	material.set_shader_parameter("source_sh9_enabled", _skylight_enabled)
	label["normal_mode"] = "NORMAL_MAP with original unnormalized TBN" if uses_normal_map else "final NORMAL"
	label["family"] = "landscape" if landscape else ("wind" if wind else "surface")
	if wind:
		var original_vertex := _vertex_function(code)
		var injected_vertex := _vertex_function(material.shader.code)
		label["vertex_sha256_before"] = original_vertex.sha256_text()
		label["vertex_sha256_after"] = injected_vertex.sha256_text()
		label["vertex_preserved"] = not original_vertex.is_empty() and original_vertex == injected_vertex
		if not label["vertex_preserved"]:
			push_error("Source SH9 wind vertex preservation check failed.")
	report.materials.append(label)
	report.bound += 1
	if landscape: report.landscape_materials += 1
	elif wind: report.wind_materials += 1
	else: report.surface_materials += 1
	if uses_normal_map: report.normal_map_materials += 1

func _matches(value: String, expression: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile(expression)
	return pattern.search(value) != null

func _fragment_bounds(clean: String) -> Vector2i:
	var pattern := RegEx.new()
	pattern.compile("void\\s+fragment\\s*\\(\\s*\\)\\s*\\{")
	var found := pattern.search(clean)
	if found == null: return Vector2i(-1,-1)
	var start := found.get_end()
	var cursor := start
	var depth := 1
	while cursor < clean.length() and depth > 0:
		if clean[cursor] == "{": depth += 1
		elif clean[cursor] == "}": depth -= 1
		cursor += 1
	return Vector2i(start,cursor-1) if depth == 0 else Vector2i(-1,-1)

func _vertex_function(code: String) -> String:
	var clean := _without_comments(code)
	var pattern := RegEx.new()
	pattern.compile("void\\s+vertex\\s*\\(\\s*\\)\\s*\\{")
	var found := pattern.search(clean)
	if found == null: return ""
	var cursor := found.get_end()
	var depth := 1
	while cursor < clean.length() and depth > 0:
		if clean[cursor] == "{": depth += 1
		elif clean[cursor] == "}": depth -= 1
		cursor += 1
	return code.substr(found.get_start(), cursor-found.get_start()) if depth == 0 else ""

func set_skylight_enabled(enabled: bool) -> void:
	# False means zero source sky diffuse, not fallback to Environment ambient.
	# Use restore() to remove this candidate and recover the original sky path.
	_skylight_enabled = enabled
	for state in _saved:
		var material: ShaderMaterial = state.object
		if is_instance_valid(material):
			material.set_shader_parameter("source_sh9_enabled", enabled)
	report["skylight_enabled"] = enabled

func attach_house_driver(driver: Node) -> Dictionary:
	_detach_house_driver()
	if not is_instance_valid(driver) or not driver.has_signal("house_state_changed"):
		return {"error":"House driver must have house_state_changed(inside)."}
	_house_driver = driver
	driver.connect("house_state_changed", Callable(self, "_on_house_state_changed"))
	var inside_value: Variant = driver.get("is_in_house")
	var inside: bool = inside_value is bool and inside_value
	_on_house_state_changed(inside)
	return {"attached":true, "inside":inside}

func _on_house_state_changed(inside: bool) -> void:
	set_skylight_enabled(not inside)

func _detach_house_driver() -> void:
	if is_instance_valid(_house_driver):
		var callback := Callable(self, "_on_house_state_changed")
		if _house_driver.is_connected("house_state_changed", callback):
			_house_driver.disconnect("house_state_changed", callback)
	_house_driver = null

func _without_comments(code: String) -> String:
	# Preserve character offsets for insertion and ignore comment braces/keywords.
	var pattern := RegEx.new()
	pattern.compile("(?s)/\\*.*?\\*/|//[^\\n]*")
	var clean := code
	var matches := pattern.search_all(code)
	for i in range(matches.size()-1,-1,-1):
		var found: RegExMatch = matches[i]
		var value := found.get_string()
		var blank := ""
		for character in value:
			blank += "\n" if character == "\n" else " "
		clean = clean.substr(0,found.get_start()) + blank + clean.substr(found.get_end())
	return clean

func restore() -> Dictionary:
	_detach_house_driver()
	var errors: Array[String] = []
	var restored := 0
	for i in range(_saved.size()-1,-1,-1):
		var state := _saved[i]
		var material: ShaderMaterial = state.object
		if not is_instance_valid(material):
			errors.append("Installed material no longer exists.")
			continue
		material.shader = state.shader
		for parameter in state.parameters:
			material.set_shader_parameter(parameter, state.parameters[parameter])
			if material.get_shader_parameter(parameter) != state.parameters[parameter]:
				errors.append("Failed to restore parameter: " + str(parameter))
		if material.shader != state.shader:
			errors.append("Failed to restore shader.")
		restored += 1
	_saved.clear()
	_shader_cache.clear()
	_seen.clear()
	var result := {"restored_materials":restored, "errors":errors}
	report["restoration"] = result
	report["status"] = "restored" if errors.is_empty() else "restore_failed"
	print("SOURCE_SH9_RESTORED ", JSON.stringify(result))
	return result

func _exit_tree() -> void:
	if restore_on_exit_tree and not _saved.is_empty(): restore()
