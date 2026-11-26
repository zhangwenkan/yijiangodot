extends Node
## Sun-only diagnostic receiver; no geometry or volume production.
## Install after source renderer adapters; restore before those owners.
var report: Dictionary = {}
var restore_on_exit_tree := true
var _saved: Array[Dictionary] = []
var _seen: Dictionary = {}
var _cache: Dictionary = {}
var _library := ""
var _bounds: Array[Dictionary] = []
var _textures: Array[Dictionary] = []
var _mode := 1

const FAMILIES := ["Ocean", "Water", "Waterfall", "Smoke1", "SmokeSubUV", "Splash"]
const PARTICLE_FAMILIES := ["Smoke1", "SmokeSubUV", "Splash"]
const PARTICLE_LIGHT := "\n    // Same diffuse_lambert/specular_disabled local path as the current particle shader.\n    DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (max(dot(NORMAL, LIGHT), 0.0) / PI);\n"

func install(scene: Node, bounds: Array[Dictionary], textures: Array[Dictionary]) -> Dictionary:
	if not _saved.is_empty(): return {"status":"failed", "error":"Already installed; restore first."}
	if not is_instance_valid(scene): return {"status":"failed", "error":"Missing scene."}
	var world: Variant = scene.get("world")
	if not world is Node: return {"status":"failed", "error":"Expected scene.world."}
	var suns: Array[Node] = world.find_children("*", "DirectionalLight3D", true, false)
	if suns.size() != 1: return {"status":"failed", "error":"Sun-only receiver requires exactly one directional light."}
	# Builtin Lambert includes finite-light angular broadening. The diagnostic's
	# explicit particle Lambert is equivalent only for the existing zero-size lights.
	# Reject a changed scene rather than silently altering its local light response.
	for light in world.find_children("*", "Light3D", true, false):
		if not is_zero_approx(light.get_param(Light3D.PARAM_SIZE)):
			return {"status":"failed", "error":"Particle Lambert preservation requires zero light_size/angular_distance: " + str(light.get_path())}
	var error := _validate_volumes(bounds, textures)
	if not error.is_empty(): return {"status":"failed", "error":error}
	var path: String = get_script().resource_path.get_base_dir().path_join("source_tlv_sun_receiver.gdshaderinc")
	_library = FileAccess.get_file_as_string(path)
	if _library.is_empty(): return {"status":"failed", "error":"Receiver shader library missing."}
	_bounds = bounds.duplicate(true)
	_textures = textures.duplicate(false)
	_mode = 1
	report = {"status":"installing", "version":1, "bound":0, "materials":[], "unsupported":[],
		"family_counts":{"Ocean":0,"Water":0,"Waterfall":0,"Smoke1":0,"SmokeSubUV":0,"Splash":0},
		"mode":_mode,"volume_updates":1,
		"scope":"Sun-only TLV diagnostic; original local direct path and sky SH9 remain separate.",
		"limits":["Not full TLV: local lights remain the current per-fragment path.",
			"Particle LightingPositionOffset is explicitly zero; stable source particle IDs/hash are not recovered.",
			"Uses current shading normals and existing geometry; original particle normal parity is not newly established.",
			"Source shadow atlas, native volume dump and exact UE runtime parity are not asserted.",
			"Particle local Lambert mathematical expression is retained; builtin half versus custom shader precision may differ.",
			"Caller must keep Godot light_size/angular_distance zero while this receiver is installed.",
			"Caller must submit matching volume bounds/textures as one snapshot and track producer frame freshness.",
			"House changes are caller-owned: source indoor sun remains active with LF/shadow disabled; update volumes for that same state."]}
	_scan(world)
	if not report.unsupported.is_empty() or int(report.bound) == 0:
		var reason: String = "Unsupported matching receiver(s)" if not report.unsupported.is_empty() else "No receivers found"
		var rollback := restore()
		report.status = "failed"
		report.error = reason
		report.rollback = rollback
		return report
	report.status = "installed"
	return report

func _validate_volumes(bounds: Array[Dictionary], textures: Array[Dictionary]) -> String:
	if bounds.size() != 2 or textures.size() != 2: return "Expected exactly near and far volume pairs."
	for cascade in range(2):
		var b: Dictionary = bounds[cascade]
		if not b.get("min_ue_cm") is Vector3: return "Volume minimum must be UE-centimetre Vector3."
		var minimum: Vector3 = b.min_ue_cm
		var voxel := float(b.get("voxel_cm", 0.0))
		var dimension := int(b.get("dimension", 0))
		if not minimum.is_finite() or not is_finite(voxel) or voxel <= 0.0 or dimension != 64:
			return "Expected finite positive voxel size and dimension 64."
		for key in ["ambient", "directional"]:
			var texture: Variant = textures[cascade].get(key)
			if not texture is Texture3D: return "Missing Texture3D " + key
			if texture.get_width() != dimension or texture.get_height() != dimension or texture.get_depth() != dimension:
				return "Texture3D dimensions disagree with bounds."
			if texture.get_format() != Image.FORMAT_RGBAH: return "Expected linear RGBA16F (FORMAT_RGBAH)."
	return ""

func update_volumes(bounds: Array[Dictionary], textures: Array[Dictionary]) -> Dictionary:
	var error := _validate_volumes(bounds, textures)
	if not error.is_empty(): return {"updated":false,"error":error}
	if _saved.is_empty(): return {"updated":false,"error":"Receiver is not installed."}
	# Validate the entire snapshot before rebinding any receiver.
	_bounds = bounds.duplicate(true)
	_textures = textures.duplicate(false)
	for state in _saved:
		if is_instance_valid(state.material): _set_parameters(state.material, str(state.family))
	report.volume_updates = int(report.get("volume_updates", 0)) + 1
	return {"updated":true,"materials":_saved.size()}

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
	if code.contains("uniform vec3 source_waterfall_color") and code.contains("uniform float displacement_power_cm"): return "Waterfall"
	if code.contains("vec3 source_blackbody(") and code.contains("uniform sampler2D source_dynamic_parameters"): return "Smoke1"
	if code.contains("uniform sampler2D source_tiled") and code.contains("source_contact_fade(150.0"): return "SmokeSubUV"
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
	var label := {"family":family,"material":material.resource_name,"first_node":str(node.get_path()),
		"shader_sha256_before":code.sha256_text(),"source_material":str(material.get_meta("source_material", ""))}
	var built := build_candidate(code, family, _library)
	if built.has("error"):
		label.reason = built.error
		report.unsupported.append(label)
		return
	var parameters: Dictionary = {}
	for uniform in original.get_shader_uniform_list(): parameters[uniform.name] = material.get_shader_parameter(uniform.name)
	if not _cache.has(original.get_instance_id()):
		var shader := Shader.new()
		shader.code = built.code
		_cache[original.get_instance_id()] = shader
	var installed: Shader = _cache[original.get_instance_id()]
	_saved.append({"material":material,"shader":original,"installed":installed,"parameters":parameters,"family":family})
	material.shader = installed
	for name in parameters: material.set_shader_parameter(name, parameters[name])
	_set_parameters(material, family)
	label.shader_sha256_after = installed.code.sha256_text()
	label.vertex_preserved = _function_text(code, "vertex") == _function_text(installed.code, "vertex")
	label.fragment_preserved_as_prefix = _function_body(installed.code, "fragment").begins_with(_function_body(code, "fragment"))
	label.alpha_expression_preserved = true
	label.existing_sky_code_preserved = true
	label.local_path = "original custom light body verbatim" if not PARTICLE_FAMILIES.has(family) else "existing diffuse_lambert/specular_disabled formula; no new LF/cone/shadows"
	label.decode = "L0" if family == "Ocean" else ("Surface SH2" if family in ["Water","Waterfall"] else "VolumetricDirectional SH2, zero offset diagnostic")
	report.materials.append(label)
	report.family_counts[family] += 1
	report.bound += 1

func _set_parameters(material: ShaderMaterial, family: String) -> void:
	for cascade in range(2):
		var suffix := "inner" if cascade == 0 else "outer"
		material.set_shader_parameter("source_tlv_ambient_"+suffix, _textures[cascade].ambient)
		material.set_shader_parameter("source_tlv_directional_"+suffix, _textures[cascade].directional)
		material.set_shader_parameter("source_tlv_min_"+suffix+"_cm", _bounds[cascade].min_ue_cm)
		var extent: float = float(_bounds[cascade].voxel_cm) * int(_bounds[cascade].dimension)
		material.set_shader_parameter("source_tlv_inv_size_"+suffix, Vector3.ONE / extent)
	material.set_shader_parameter("source_tlv_sun_mode", _mode)
	material.set_shader_parameter("source_tlv_nondirectional", family == "Ocean")
	material.set_shader_parameter("source_tlv_directional_intensity", 1.0)
	material.set_shader_parameter("source_tlv_lighting_offset_ue_cm", Vector3.ZERO)

func build_candidate(code: String, family: String, library: String) -> Dictionary:
	# Pure text operation; usable by a parent CPU audit without loading any scene.
	var clean := _without_comments(code)
	if not FAMILIES.has(family): return {"error":"Unsupported family."}
	if clean.contains("source_tlv_sun_mode"): return {"error":"TLV receiver already present."}
	if _matches(clean, "\\bunshaded\\b"): return {"error":"Matching material is unshaded."}
	var fragment := _function_bounds(clean, "fragment")
	if fragment.x < 0 or _matches(clean.substr(fragment.x, fragment.y-fragment.x), "\\breturn\\b"):
		return {"error":"Requires ordinary fragment without early return."}
	var particle := PARTICLE_FAMILIES.has(family)
	var light := _function_bounds(clean, "light")
	var previous_light := ""
	if particle:
		if light.x >= 0: return {"error":"Particle has unexpected custom light; preserve owner before adapting."}
		if not _matches(clean, "\\bdiffuse_lambert\\b") or not _matches(clean, "\\bspecular_disabled\\b"):
			return {"error":"Particle is not the audited Lambert/specular-disabled shader."}
		previous_light = PARTICLE_LIGHT
	else:
		if light.x < 0 or clean.count("DIFFUSE_LIGHT += radiance * (nl / PI);") != 1:
			return {"error":"Install after existing LF/cone include expansion; unknown light body."}
		previous_light = code.substr(light.x, light.y-light.x)
	var body := "\n    if (source_tlv_sun_mode != 0 && LIGHT_IS_DIRECTIONAL) {\n"
	body += "        if (source_tlv_sun_mode == 1) {\n"
	body += "            vec3 source_tlv_world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);\n"
	body += "            DIFFUSE_LIGHT += source_tlv_sun_response(source_tlv_receiver_world, source_tlv_world_normal);\n"
	body += "        }\n    } else {\n" + previous_light + "\n    }\n"
	var edited := code
	if particle:
		edited += "\nvoid light() {" + body + "}\n"
	else:
		edited = edited.substr(0, light.x) + body + edited.substr(light.y)
	# Fragment VERTEX is actual view-space interpolated geometry after existing
	# world displacement or billboard. No vertex code or NORMAL_MAP is rewritten.
	fragment = _function_bounds(_without_comments(edited), "fragment")
	edited = edited.insert(fragment.y, "\n    source_tlv_receiver_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;\n")
	var header := RegEx.new()
	header.compile("shader_type\\s+spatial\\s*;")
	var found := header.search(_without_comments(edited))
	if found == null: return {"error":"Spatial shader header missing."}
	edited = edited.insert(found.get_end(), "\n" + library + "\n")
	return {"code":edited,"family":family,"particle":particle}

func set_mode(mode: int) -> void:
	_mode = clampi(mode, 0, 2)
	for state in _saved:
		if is_instance_valid(state.material): state.material.set_shader_parameter("source_tlv_sun_mode", _mode)
	report.mode = _mode

func restore() -> Dictionary:
	var restored := 0
	var errors: Array[String] = []
	var remaining: Array[Dictionary] = []
	for state in _saved:
		if not is_instance_valid(state.material): continue
		var material: ShaderMaterial = state.material
		if material.shader != state.installed:
			errors.append("Another owner changed " + material.resource_name + "; restore it first.")
			remaining.append(state)
			continue
		material.shader = state.shader
		for name in state.parameters: material.set_shader_parameter(name, state.parameters[name])
		restored += 1
	_saved = remaining
	if errors.is_empty():
		_seen.clear()
		_cache.clear()
		_bounds.clear()
		_textures.clear()
	return {"restored_materials":restored,"errors":errors}

func _matches(value: String, expression: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile(expression)
	return pattern.search(value) != null

func _function_start(clean: String, function: String) -> int:
	var pattern := RegEx.new()
	pattern.compile("void\\s+" + function + "\\s*\\(\\s*\\)\\s*\\{")
	var found := pattern.search(clean)
	return found.get_start() if found != null else -1

func _function_bounds(clean: String, function: String) -> Vector2i:
	var start := _function_start(clean, function)
	if start < 0: return Vector2i(-1, -1)
	var opening := clean.find("{", start)
	var cursor := opening + 1
	var depth := 1
	while cursor < clean.length() and depth > 0:
		if clean[cursor] == "{": depth += 1
		elif clean[cursor] == "}": depth -= 1
		cursor += 1
	return Vector2i(opening+1, cursor-1) if depth == 0 else Vector2i(-1, -1)

func _function_text(code: String, function: String) -> String:
	var clean := _without_comments(code)
	var start := _function_start(clean, function)
	var bounds := _function_bounds(clean, function)
	return code.substr(start, bounds.y+1-start) if bounds.x >= 0 else ""

func _function_body(code: String, function: String) -> String:
	var bounds := _function_bounds(_without_comments(code), function)
	return code.substr(bounds.x, bounds.y-bounds.x) if bounds.x >= 0 else ""

func _without_comments(code: String) -> String:
	var pattern := RegEx.new()
	pattern.compile("(?s)/\\*.*?\\*/|//[^\\n]*")
	var clean := code
	var matches := pattern.search_all(code)
	for i in range(matches.size()-1, -1, -1):
		var found: RegExMatch = matches[i]
		var blank := ""
		for character in found.get_string(): blank += "\n" if character == "\n" else " "
		clean = clean.substr(0, found.get_start()) + blank + clean.substr(found.get_end())
	return clean

func _exit_tree() -> void:
	if restore_on_exit_tree: restore()
