extends Node
## Frozen diagnostic only. Bind AFTER the original renderer's final shader stack.
## Stop probe viewports, restore this owner, then unwind original material owners.
## No geometry, source files, visibility, shadow flags, fragment or mask edits.
const ENABLED := "source_tlv_caster_camera_enabled"
const CAMERA_WORLD := "source_tlv_caster_camera_world"
const CAMERA_RIGHT := "source_tlv_caster_camera_right"
const CAMERA_BACK := "source_tlv_caster_camera_back"
const NEW_UNIFORMS := [ENABLED, CAMERA_WORLD, CAMERA_RIGHT, CAMERA_BACK]
const WIND_EXPRESSION := "distance(original_world, CAMERA_POSITION_WORLD)"
const CAMERA_TOKENS := ["CAMERA_POSITION_WORLD", "MAIN_CAM_INV_VIEW_MATRIX", "INV_VIEW_MATRIX",
	"VIEW_MATRIX", "PROJECTION_MATRIX", "INV_PROJECTION_MATRIX", "MODELVIEW_MATRIX"]
const TEMPLATES := {
	"Wind":"res://shaders/original_vegetation_wind.gdshader",
	"CharacterFixedY":"res://source_lighting_candidate/original_character_surface.gdshader",
	"AmbientLitFixedY":"res://source_ambient_candidate/original_ambient_lit_surface.gdshader",
	"AmbientUnlitFixedY":"res://source_ambient_candidate/original_ambient_unlit_surface.gdshader"}
var restore_on_exit_tree := true
var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _pending: Array[Dictionary] = []
var _seen: Dictionary = {}
var _cache: Dictionary = {}
var _template_cache: Dictionary = {}
var _material_nodes: Dictionary = {}
var _camera: Camera3D
var _camera_transform := Transform3D.IDENTITY
var _mask := 0
var _enabled := true

func install(scene: Node3D, main_camera: Camera3D, caster_layers: int = 0xFFFFF,
        allow_partial_diagnostic: bool = false, enabled: bool = true) -> Dictionary:
	if not _saved.is_empty(): return {"status":"failed", "error":"Already installed; restore first."}
	if not is_instance_valid(scene) or not is_instance_valid(main_camera):
		return {"status":"failed", "error":"Scene and original camera required."}
	var pose: Transform3D = main_camera.global_transform
	if not pose.origin.is_finite() or not pose.basis.x.is_finite() or not pose.basis.y.is_finite() or not pose.basis.z.is_finite():
		return {"status":"failed", "error":"Camera transform must be finite."}
	if not pose.basis.is_equal_approx(pose.basis.orthonormalized()):
		return {"status":"failed", "error":"Camera basis must be orthonormal; scaled cameras need separate evaluation."}
	if Vector3.UP.cross(pose.basis.z).length_squared() < 0.000001 or pose.basis.x.cross(Vector3.UP).length_squared() < 0.000001:
		return {"status":"failed", "error":"Fixed-Y billboard basis is degenerate at this camera orientation."}
	_pending.clear(); _seen.clear(); _cache.clear(); _template_cache.clear(); _material_nodes.clear()
	_camera = main_camera
	_camera_transform = pose
	_mask = main_camera.cull_mask & caster_layers
	_enabled = enabled
	report = {"status":"inspecting", "version":2, "bound":0, "materials":[], "unsupported":[],
		"not_modified":[], "camera_transform":str(pose), "caster_mask":_mask,
		"family_counts":{"Wind":0,"CharacterFixedY":0,"AmbientLitFixedY":0,"AmbientUnlitFixedY":0},
		"potential_casters":0, "skipped_shadow_off":0, "skipped_visibility_or_layer":0,
		"enabled":_enabled, "full_scene_shadow_equivalence":false,
		"scope":"Freeze existing wind distance and fixed-Y billboard axes to the original visible camera.",
		"limits":["No source UE atlas parity; Godot cascade/rasterization and screen-space dither remain unchanged.",
			"Wind shadow shape intentionally changes from light-camera distance to original visible-camera distance.",
			"All fragment/discard code and existing parameters are preserved, including dither frame and source alpha.",
			"Known vertex templates are checked before edits; other reachable vertex camera uses reject strict mode.",
			"This inspects direct/function-call vertex dependencies, not a complete shader preprocessor or dataflow proof.",
			"Freeze camera, time, animation, state and material owners until probes stop and restore completes."]}
	_scan(scene)
	if not report.unsupported.is_empty() and not allow_partial_diagnostic:
		report.status = "rejected"
		report.error = "Unsupported potential casters found; no shader or parameter was changed."
		_pending.clear()
		return report
	if _pending.is_empty():
		report.status = "rejected"
		report.error = "No matching visible wind or fixed-Y casters; no material was changed."
		return report
	# No mutation until the entire scene (including player outside scene.world) is checked.
	for candidate in _pending:
		var material: ShaderMaterial = candidate.material
		var original: Shader = material.shader
		var parameters: Dictionary = {}
		for uniform in original.get_shader_uniform_list():
			parameters[uniform.name] = _snapshot_value(material.get_shader_parameter(uniform.name))
		var cache_key: String = candidate.code.sha256_text()
		if not _cache.has(cache_key):
			var replacement := Shader.new()
			replacement.code = candidate.code
			_cache[cache_key] = replacement
		var installed: Shader = _cache[cache_key]
		var state := {"material":material, "shader":original, "installed":installed,
			"parameters":parameters, "node":candidate.node, "family":candidate.family,
			"installed_sha256":installed.code.sha256_text(), "original_sha256":original.code.sha256_text(),
			"next_pass":material.next_pass, "render_priority":material.render_priority,
			"shader_restored":false}
		_saved.append(state)
		material.shader = installed
		for key in parameters: material.set_shader_parameter(key, parameters[key])
		material.set_shader_parameter(ENABLED,_enabled)
		material.set_shader_parameter(CAMERA_WORLD,pose.origin)
		material.set_shader_parameter(CAMERA_RIGHT,pose.basis.x)
		material.set_shader_parameter(CAMERA_BACK,pose.basis.z)
		var label: Dictionary = candidate.audit.duplicate(true)
		label.nodes = _material_nodes.get(material.get_instance_id(),[candidate.node])
		label.original_parameter_count = parameters.size()
		report.materials.append(label)
		report.family_counts[candidate.family] += 1
		report.bound += 1
	_pending.clear()
	report.status = "installed_partial" if not report.unsupported.is_empty() else "installed"
	report.allow_partial_diagnostic = allow_partial_diagnostic
	var integrity := verify_bound_state()
	if not integrity.is_empty():
		report.status = "failed"
		report.integrity_errors = integrity
		report.rollback = restore()
	return report

func _scan(node: Node) -> void:
	if node == self: return
	if node is GeometryInstance3D:
		var geometry: GeometryInstance3D = node
		if geometry.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			report.skipped_shadow_off += 1
		elif not geometry.is_visible_in_tree() or (geometry.layers & _mask) == 0:
			report.skipped_visibility_or_layer += 1
		elif node is MultiMeshInstance3D and (node.multimesh == null or node.multimesh.instance_count == 0 or node.multimesh.visible_instance_count == 0):
			report.skipped_visibility_or_layer += 1
		else:
			report.potential_casters += 1
			_bind(geometry.material_override,geometry)
			_bind(geometry.material_overlay,geometry)
			if geometry.material_override == null:
				if node is MeshInstance3D and node.mesh != null:
					for surface in node.mesh.get_surface_count(): _bind(node.get_active_material(surface),geometry)
				elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
					for surface in node.multimesh.mesh.get_surface_count(): _bind(node.multimesh.mesh.surface_get_material(surface),geometry)
				elif node is SpriteBase3D and node.billboard != BaseMaterial3D.BILLBOARD_DISABLED:
					_unsupported(geometry,null,"Built-in billboard material has no audited source shader; install source renderer first.")
	for child in node.get_children(): _scan(child)

func _bind(material: Material, node: GeometryInstance3D) -> void:
	if material == null: return
	var id := material.get_instance_id()
	var path := str(node.get_path())
	if not _material_nodes.has(id): _material_nodes[id] = []
	if not _material_nodes[id].has(path): _material_nodes[id].append(path)
	if _seen.has(id): return
	_seen[id] = true
	_bind(material.next_pass,node)
	if material is BaseMaterial3D:
		if material.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
			_unsupported(node,material,"BaseMaterial3D billboard requires its source ShaderMaterial adapter.")
		return
	if not material is ShaderMaterial or material.shader == null: return
	var code: String = material.shader.code
	var clean := _without_comments(code)
	var family := _family(material,clean)
	if not family.is_empty():
		var built := build_candidate(code,family)
		if built.has("error"):
			_unsupported(node,material,built.error)
			return
		if family.begins_with("Ambient"):
			var fixed_y: Variant = material.get_shader_parameter("source_ambient_fixed_y")
			if fixed_y != true:
				if fixed_y != false:
					_unsupported(node,material,"Ambient fixed-Y uniform is not an explicit bool.")
				else:
					report.not_modified.append({"node":path,"material":material.resource_name,"reason":"Source ambient fixed-Y is disabled; existing geometry orientation is camera independent."})
				return
		_pending.append({"material":material,"node":path,"code":built.code,"family":family,
			"audit":{"family":family,"material":material.resource_name,"source_material":str(material.get_meta("source_material","")),
				"source_shader_sha256":code.sha256_text(),"bound_shader_sha256":str(built.code).sha256_text(),
				"template_sha256":built.template_sha256,"fragment_exact":built.fragment_exact,
				"inverse_edit_exact":built.inverse_edit_exact,"replacements":built.replacements}})
		return
	var risk := _reachable_vertex_risk(clean)
	if not risk.is_empty(): _unsupported(node,material,"Unrecognized camera-dependent caster: " + risk)

func _family(material: ShaderMaterial, clean: String) -> String:
	if bool(material.get_meta("source_wind_adapter",false)) and clean.contains("uniform float wind_distance_limit"):
		return "Wind"
	if not bool(material.get_meta("source_surface_adapter",false)): return ""
	if clean.contains("uniform sampler2D source_character_atlas") and clean.contains("uniform float source_character_mask_y_offset"):
		return "CharacterFixedY"
	if clean.contains("uniform sampler2D source_ambient_atlas") and clean.contains("uniform bool source_ambient_fixed_y"):
		return "AmbientLitFixedY" if clean.contains("uniform float source_ambient_mask_y_offset") else "AmbientUnlitFixedY"
	return ""

func build_candidate(code: String, family: String) -> Dictionary:
	if not TEMPLATES.has(family): return {"error":"Unknown supported family."}
	if not _template_cache.has(family):
		var source := FileAccess.get_file_as_string(TEMPLATES[family])
		if source.is_empty(): return {"error":"Missing source vertex contract: " + TEMPLATES[family]}
		_template_cache[family] = source
	var source: String = _template_cache[family]
	var clean := _without_comments(code)
	for name in NEW_UNIFORMS:
		if clean.contains(name): return {"error":"Existing candidate camera uniform: " + name}
	var vertex := _function_bounds(clean,"vertex")
	if vertex.x < 0: return {"error":"Missing vertex function."}
	var body := clean.substr(vertex.x,vertex.y-vertex.x)
	var expected := _function_body(_without_comments(source),"vertex")
	if _canonical(_without_lighting_assignments(body)) != _canonical(_without_lighting_assignments(expected)):
		return {"error":"Final vertex differs from the audited source template beyond known lighting/fog varyings."}
	var edits: Array[Dictionary] = []
	if family == "Wind":
		if body.count(WIND_EXPRESSION) != 1:
			return {"error":"Wind source distance expression must occur exactly once in vertex."}
		var at := clean.find(WIND_EXPRESSION,vertex.x)
		edits.append({"at":at,"before":WIND_EXPRESSION,"after":"distance(original_world, " + ENABLED + " ? " + CAMERA_WORLD + " : CAMERA_POSITION_WORLD)"})
	else:
		# Replace only two geometry-axis reads, leaving camera[3] lighting distance alone.
		for item in [["MAIN_CAM_INV_VIEW_MATRIX[0].xyz",CAMERA_RIGHT],["MAIN_CAM_INV_VIEW_MATRIX[2].xyz",CAMERA_BACK]]:
			if body.count(item[0]) != 1:
				return {"error":"Expected exactly one fixed-Y source geometry-axis read: " + item[0]}
			edits.append({"at":clean.find(item[0],vertex.x),"before":item[0],"after":"("+ENABLED+" ? "+item[1]+" : "+item[0]+")"})
	var header := RegEx.new()
	header.compile("shader_type\\s+spatial\\s*;")
	var match_header := header.search(clean)
	if match_header == null: return {"error":"Missing spatial header."}
	var declaration := "\nuniform bool "+ENABLED+" = false;\nuniform vec3 "+CAMERA_WORLD+";\nuniform vec3 "+CAMERA_RIGHT+";\nuniform vec3 "+CAMERA_BACK+";\n"
	edits.append({"at":match_header.get_end(),"before":"","after":declaration})
	edits.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return int(a.at)>int(b.at))
	var edited := code
	for edit in edits:
		edited = edited.substr(0,edit.at)+edit.after+edited.substr(int(edit.at)+str(edit.before).length())
	var inverse := edited
	# Undo lowest original offset first: later original offsets then become valid again.
	for index in range(edits.size()-1,-1,-1):
		var edit: Dictionary = edits[index]
		if inverse.substr(edit.at,str(edit.after).length()) != edit.after:
			return {"error":"Inverse edit offset validation failed."}
		inverse = inverse.substr(0,edit.at)+edit.before+inverse.substr(int(edit.at)+str(edit.after).length())
	if inverse != code: return {"error":"Edit changed more than declared source camera reads."}
	var original_fragment := _function_text(code,"fragment")
	var candidate_fragment := _function_text(edited,"fragment")
	if original_fragment != candidate_fragment: return {"error":"Fragment or mask/discard text changed."}
	return {"code":edited,"fragment_exact":true,"inverse_edit_exact":true,
		"template_sha256":source.sha256_text(),"replacements":edits.size()-1}

func _reachable_vertex_risk(clean: String) -> String:
	var functions := _function_map(clean)
	if not functions.has("vertex"): return ""
	var pending: Array[String] = ["vertex"]
	var seen: Dictionary = {}
	var calls := RegEx.new()
	calls.compile("\\b([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	while not pending.is_empty():
		var name: String = pending.pop_back()
		if seen.has(name): continue
		seen[name] = true
		var body := _without_lighting_assignments(str(functions[name]))
		for token in CAMERA_TOKENS:
			if body.contains(token): return name+" -> "+token
		for call in calls.search_all(body):
			var callee: String = call.get_string(1)
			if functions.has(callee) and not seen.has(callee): pending.append(callee)
	return ""

func _without_lighting_assignments(body: String) -> String:
	# Current final adapters append only these outputs; source template equality
	# rejects unknown geometry code. Fragment/discard remains byte-for-byte intact.
	var pattern := RegEx.new()
	pattern.compile("\\b(source_lf_fragment_world|source_lf_camera_distance|source_hf_vertex_result)\\s*=[^;]*;")
	return pattern.sub(body,"",true)

func _canonical(text: String) -> String:
	var whitespace := RegEx.new()
	whitespace.compile("\\s+")
	return whitespace.sub(text,"",true)

func set_enabled(enabled: bool) -> Array[String]:
	var errors := verify_bound_state()
	if not errors.is_empty(): return errors
	_enabled = enabled
	for state in _saved: state.material.set_shader_parameter(ENABLED,enabled)
	report.enabled = enabled
	return []

func verify_bound_state() -> Array[String]:
	var errors: Array[String] = []
	if not is_instance_valid(_camera) or _camera.global_transform != _camera_transform:
		errors.append("Original camera changed or disappeared during the frozen binding.")
	for state in _saved:
		if not is_instance_valid(state.material):
			errors.append("Material disappeared: "+state.node)
			continue
		var material: ShaderMaterial = state.material
		if material.shader != state.installed or material.shader.code.sha256_text() != state.installed_sha256:
			errors.append("Shader owner or code changed: "+state.node)
			continue
		if material.next_pass != state.next_pass or material.render_priority != state.render_priority:
			errors.append("Material pass/priority owner changed: "+state.node)
		for key in state.parameters:
			if material.get_shader_parameter(key) != state.parameters[key]: errors.append("Original uniform changed: "+state.node+" / "+str(key))
		for pair in [[ENABLED,_enabled],[CAMERA_WORLD,_camera_transform.origin],[CAMERA_RIGHT,_camera_transform.basis.x],[CAMERA_BACK,_camera_transform.basis.z]]:
			if material.get_shader_parameter(pair[0]) != pair[1]: errors.append("Candidate camera uniform changed: "+state.node+" / "+str(pair[0]))
	return errors

func restore() -> Dictionary:
	var restored := 0
	var errors: Array[String] = []
	var remaining: Array[Dictionary] = []
	for state in _saved:
		if not is_instance_valid(state.material): continue
		var material: ShaderMaterial = state.material
		var expected: Shader = state.shader if state.shader_restored else state.installed
		if material.shader != expected:
			errors.append("Another shader owner changed "+state.node+"; unwind that owner first.")
			remaining.append(state)
			continue
		if not state.shader_restored and material.shader.code.sha256_text() != state.installed_sha256:
			errors.append("Installed shader source changed "+state.node+"; restore its source owner first.")
			remaining.append(state)
			continue
		if material.next_pass != state.next_pass or material.render_priority != state.render_priority:
			errors.append("Another material pass/priority owner changed "+state.node+"; unwind that owner first.")
			remaining.append(state)
			continue
		if state.shader.code.sha256_text() != state.original_sha256:
			errors.append("Original shader resource changed "+state.node+"; restore its source owner first.")
			remaining.append(state)
			continue
		if not state.shader_restored:
			for name in NEW_UNIFORMS: material.set_shader_parameter(name,null)
			material.shader = state.shader
			state.shader_restored = true
		for key in state.parameters: material.set_shader_parameter(key,state.parameters[key])
		var valid: bool = material.shader == state.shader and material.shader.code.sha256_text() == state.original_sha256
		for key in state.parameters:
			if material.get_shader_parameter(key) != state.parameters[key]: valid = false
		if valid:
			restored += 1
		else:
			errors.append("Shader/parameter restore verification failed: "+state.node)
			remaining.append(state)
	_saved = remaining
	if _saved.is_empty():
		_seen.clear(); _cache.clear(); _pending.clear(); _template_cache.clear(); _material_nodes.clear()
		_camera = null
	var result := {"restored_materials":restored,"remaining":_saved.size(),"errors":errors}
	report.restore = result
	return result

func _snapshot_value(value: Variant) -> Variant:
	return value.duplicate(true) if value is Array or value is Dictionary else value

func _unsupported(node: Node, material: Material, reason: String) -> void:
	report.unsupported.append({"node":str(node.get_path()),"material":material.resource_name if material != null else "built-in sprite","reason":reason})

func _function_bounds(clean: String, function: String) -> Vector2i:
	var pattern := RegEx.new()
	pattern.compile("void\\s+"+function+"\\s*\\(\\s*\\)\\s*\\{")
	var found := pattern.search(clean)
	if found == null: return Vector2i(-1,-1)
	var cursor := found.get_end()
	var start := cursor
	var depth := 1
	while cursor < clean.length() and depth > 0:
		if clean[cursor] == "{": depth += 1
		elif clean[cursor] == "}": depth -= 1
		cursor += 1
	return Vector2i(start,cursor-1) if depth == 0 else Vector2i(-1,-1)

func _function_body(clean: String, function: String) -> String:
	var span := _function_bounds(clean,function)
	return clean.substr(span.x,span.y-span.x) if span.x >= 0 else ""

func _function_text(code: String, function: String) -> String:
	var clean := _without_comments(code)
	var span := _function_bounds(clean,function)
	return code.substr(span.x,span.y-span.x) if span.x >= 0 else ""

func _function_map(clean: String) -> Dictionary:
	var pattern := RegEx.new()
	pattern.compile("\\b(?:void|bool|int|uint|float|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\([^;{}]*\\)\\s*\\{")
	var result: Dictionary = {}
	for found in pattern.search_all(clean):
		var cursor := found.get_end()
		var start := cursor
		var depth := 1
		while cursor < clean.length() and depth > 0:
			if clean[cursor] == "{": depth += 1
			elif clean[cursor] == "}": depth -= 1
			cursor += 1
		if depth == 0: result[found.get_string(1)] = clean.substr(start,cursor-start-1)
	return result

func _without_comments(code: String) -> String:
	var pattern := RegEx.new()
	pattern.compile("(?s)/\\*.*?\\*/|//[^\\n]*")
	var clean := code
	var matches := pattern.search_all(code)
	for i in range(matches.size()-1,-1,-1):
		var found: RegExMatch = matches[i]
		var blank := ""
		for character in found.get_string(): blank += "\n" if character == "\n" else " "
		clean = clean.substr(0,found.get_start())+blank+clean.substr(found.get_end())
	return clean

func _exit_tree() -> void:
	if restore_on_exit_tree: restore()
