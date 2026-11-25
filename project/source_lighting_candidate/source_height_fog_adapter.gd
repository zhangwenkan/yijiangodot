extends Node
## Stage-only reversible diagnostic. Does not create or modify geometry.
## Install after source material/lightfunction/SH9 adapters; restore in reverse order.

var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _seen: Dictionary = {}
var _cache: Dictionary = {}
var _policy: Dictionary = {}
var _options: Dictionary = {}
var _library := ""
var _materials: Array[ShaderMaterial] = []
var _sun_scale := 1.0
var _house_driver: Node

func install(world: Node, environment: Environment, policy_file: String, options: Dictionary = {}) -> Dictionary:
	if not _saved.is_empty(): return {"error":"Already installed; restore first."}
	if not is_instance_valid(world) or environment == null: return {"error":"Missing world/environment."}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(policy_file))
	if not parsed is Dictionary or parsed.get("schema", "") != "source_height_fog_v1":
		return {"error":"Invalid source height-fog policy."}
	if parsed.get("layers", []).size() != 2 or bool(parsed.get("volumetric_enabled", true)):
		return {"error":"Candidate requires two layers and original volumetric fog disabled."}
	_policy = parsed
	_options = options
	_library = FileAccess.get_file_as_string(get_script().resource_path.get_base_dir().path_join("source_height_fog.gdshaderinc"))
	if _library.is_empty(): return {"error":"Missing adjacent source_height_fog.gdshaderinc."}
	_seen.clear()
	_cache.clear()
	_materials.clear()
	_sun_scale = 1.0
	report = {"version":1,"status":"installing","policy_file":policy_file,"map":_policy.map,
		"bound":0,"pixel_fog":0,"vertex_fog":0,"sky_bound":false,"materials":[],"unsupported":[],"skipped":[],
		"limits":["Cross-engine analytic fog candidate; shader GPU compilation and image validation pending.",
		"Source integral follows retained UE4.26 source; shipping fog component defaults/scaling are disassembled.",
		"Sky uses the infinite-ray analytic limit; original depth-zero epsilon and light-shaft mask are not reproduced.",
		"Old AtmosphericFog precomputed scattering remains a separate missing renderer path.",
		"Translucent fog sampling defaults follow UMaterial; unmatched materials are recorded, not silently certified.",
		"Restore this adapter before restoring SH9, source capture, or another shader-injection owner."]}
	_scan(world)
	if bool(options.get("include_sky", true)):
		_bind_sky(environment)
	_save_property(environment, &"fog_enabled", false)
	_save_property(environment, &"volumetric_fog_enabled", false)
	report.status = "installed"
	print("SOURCE_HEIGHT_FOG_INSTALLED ",JSON.stringify(report))
	return report

func _scan(node: Node) -> void:
	if node == self: return
	if node is GeometryInstance3D:
		_bind(node.material_override,node)
		_bind(node.material_overlay,node)
		if node.material_override != null:
			pass # The override replaces all mesh surfaces; their default materials are inactive.
		elif node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count(): _bind(node.get_active_material(surface),node)
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			for surface in node.multimesh.mesh.get_surface_count(): _bind(node.multimesh.mesh.surface_get_material(surface),node)
	for child in node.get_children(): _scan(child)

func _source_material_key(material: Material) -> String:
	var value: Variant = material.get_meta("source_material", material.get_meta("ue_source_material", ""))
	if value is Dictionary:
		return str(value.get("source_material_key", value.get("source_material", "")))
	return str(value)

func _bind(material: Material, node: Node) -> void:
	if material == null or _seen.has(material.get_instance_id()): return
	_seen[material.get_instance_id()] = true
	_bind(material.next_pass,node)
	var label := {"material":material.resource_name,"first_node":str(node.get_path()),
		"source_material":_source_material_key(material)}
	if not material is ShaderMaterial or material.shader == null:
		label.reason = "BaseMaterial3D/unknown Material is not converted by this candidate"
		report.unsupported.append(label)
		return
	var original: Shader = material.shader
	label.shader = original.resource_path
	var code := original.code
	var clean := _without_comments(code)
	if not _matches(clean,"shader_type\\s+spatial\\s*;") or _matches(clean,"\\bFOG\\b"):
		label.reason = "not spatial or already uses custom FOG"
		report.unsupported.append(label)
		return
	if _matches(clean,"\\bfog_disabled\\b"):
		label.reason = "existing fog_disabled render mode; retained"
		report.skipped.append(label)
		return
	var fragment := _span(clean,"fragment")
	if fragment.x < 0 or _matches(clean.substr(fragment.y,fragment.z-fragment.y),"\\breturn\\b"):
		label.reason = "missing fragment or early fragment return"
		report.unsupported.append(label)
		return
	var source_policy: Dictionary = _policy.get("material_policies",{}).get(label.source_material,{})
	var overrides: Dictionary = _options.get("material_overrides",{})
	if overrides.has(label.source_material): source_policy = overrides[label.source_material]
	elif overrides.has(material.resource_name): source_policy = overrides[material.resource_name]
	var inferred_translucent := _matches(clean,"\\bdepth_draw_never\\b|\\bblend_add\\b|\\bblend_mul\\b")
	var source_blend := str(source_policy.get("blend", "BLEND_Translucent" if inferred_translucent else "BLEND_Opaque"))
	var translucent := source_blend in ["BLEND_Translucent","BLEND_Additive","BLEND_Modulate","BLEND_AlphaComposite","BLEND_AlphaHoldout"]
	var apply_fog := bool(source_policy.get("apply_fog",true)) or not translucent
	var per_vertex := translucent and not bool(source_policy.get("per_pixel",false))
	if bool(_options.get("force_translucent_per_pixel",false)): per_vertex = false
	var attenuate_only := source_blend in ["BLEND_Additive","BLEND_Modulate"] or _matches(clean,"\\bblend_add\\b|\\bblend_mul\\b")
	if not apply_fog:
		label.reason = "source translucency disables fog"
		report.skipped.append(label)
		return
	if source_blend == "BLEND_Modulate" or _matches(clean,"\\bblend_mul\\b"):
		label.reason = "modulate blend needs native framebuffer blend verification"
		report.unsupported.append(label)
		return
	if _matches(clean,"\\bPOSITION\\s*=") or _matches(clean,"\\bVERTEX\\s*=",fragment.y):
		label.reason = "custom clip position or fragment vertex assignment needs ray audit"
		report.unsupported.append(label)
		return
	var vertex := _span(clean,"vertex")
	if per_vertex and vertex.x>=0 and _matches(clean.substr(vertex.y,vertex.z-vertex.y),"\\breturn\\b"):
		label.reason = "vertex early return cannot receive final fog varying"
		report.unsupported.append(label)
		return
	var cache_key := str(original.get_instance_id())+":"+str(per_vertex)+":"+str(attenuate_only)
	if not _cache.has(cache_key):
		var fragment_tail := "\nvec4 source_hf_result = "
		if per_vertex:
			fragment_tail += "source_hf_vertex_result;\n"
		else:
			fragment_tail += "source_height_fog(CAMERA_POSITION_WORLD, (INV_VIEW_MATRIX*vec4(VERTEX,1.0)).xyz);\n"
		fragment_tail += "FOG = source_height_fog_to_godot(source_hf_result,"+("true" if attenuate_only else "false")+");\n"
		var edited := code.insert(fragment.z,fragment_tail)
		var declaration := _library+"\n"
		if per_vertex:
			declaration += "varying vec4 source_hf_vertex_result;\n"
			var world_position := "(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz"
			if _matches(clean,"\\bskip_vertex_transform\\b"): world_position = "(INV_VIEW_MATRIX*vec4(VERTEX,1.0)).xyz"
			elif _matches(clean,"\\bworld_vertex_coords\\b"): world_position = "VERTEX"
			elif _matches(clean,"\\bMODELVIEW_MATRIX\\s*="): world_position = "(INV_VIEW_MATRIX*MODELVIEW_MATRIX*vec4(VERTEX,1.0)).xyz"
			var vertex_tail := "\nsource_hf_vertex_result = source_height_fog(CAMERA_POSITION_WORLD,"+world_position+");\n"
			# Recompute bounds after fragment insertion; source vertex WPO stays byte-for-byte.
			var edited_vertex := _span(_without_comments(edited),"vertex")
			if edited_vertex.x>=0: edited = edited.insert(edited_vertex.z,vertex_tail)
			else: edited += "\nvoid vertex() {"+vertex_tail+"}\n"
		# Insert before first shader entry point, so helpers are declared before use.
		var first_entry := _first_entry(_without_comments(edited))
		edited = edited.insert(first_entry,declaration)
		var replacement := Shader.new()
		replacement.code = edited
		_cache[cache_key] = replacement
	_save_shader(material)
	material.shader = _cache[cache_key]
	_restore_parameters(_saved[-1])
	_set_uniforms(material)
	_materials.append(material)
	label.source_blend = source_blend
	label.source_policy_matched = not source_policy.is_empty()
	label.sampling = "vertex" if per_vertex else "pixel"
	label.attenuate_only = attenuate_only
	label.original_vertex_sha256 = _function_text(code,"vertex").sha256_text()
	label.original_fragment_sha256 = _function_text(code,"fragment").sha256_text()
	label.original_vertex_body_preserved = _preserved_body(code,material.shader.code,"vertex")
	label.original_fragment_body_preserved = _preserved_body(code,material.shader.code,"fragment")
	if not label.original_vertex_body_preserved or not label.original_fragment_body_preserved:
		push_error("Height-fog injection changed an existing source function body.")
	report.materials.append(label)
	report.bound += 1
	if per_vertex: report.vertex_fog += 1
	else: report.pixel_fog += 1

func _bind_sky(environment: Environment) -> void:
	if environment.sky == null or not environment.sky.sky_material is ShaderMaterial:
		report.unsupported.append({"reason":"missing ShaderMaterial sky"})
		return
	var material: ShaderMaterial = environment.sky.sky_material
	var code := material.shader.code
	var clean := _without_comments(code)
	var span := _span(clean,"sky")
	if span.x<0 or _matches(clean.substr(span.y,span.z-span.y),"\\breturn\\b") or _matches(clean,"source_height_fog|\\bFOG\\b"):
		report.unsupported.append({"reason":"sky has early return or existing custom fog"})
		return
	# Visible background is re-evaluated at each actual viewport camera, including
	# six source capture faces. Already-captured IBL cubemap branch is NOT fogged twice.
	var tail := "\nif (!AT_CUBEMAP_PASS) {\nvec4 source_hf_sky_result = source_height_fog_sky(POSITION,EYEDIR);\nFOG = source_height_fog_to_godot(source_hf_sky_result,false);\n}\n"
	var edited := code.insert(span.z,tail).insert(span.x,_library+"\n")
	_save_shader(material)
	var replacement := Shader.new()
	replacement.code = edited
	material.shader = replacement
	_restore_parameters(_saved[-1])
	_set_uniforms(material)
	_materials.append(material)
	report.sky_bound = true
	report.sky_strategy = "analytic infinite ray; POSITION camera origin; visible/capture camera only; AT_CUBEMAP_PASS unchanged"

func _set_uniforms(material: ShaderMaterial) -> void:
	for i in 2:
		var layer: Dictionary = _policy.layers[i]
		material.set_shader_parameter("source_hf_layer"+str(i),Vector3(float(layer.density_per_cm),float(layer.falloff_per_cm),float(layer.height_cm)))
	material.set_shader_parameter("source_hf_color",_vector(_policy.color_linear))
	material.set_shader_parameter("source_hf_direction",_vector(_policy.direction_godot).normalized())
	material.set_shader_parameter("source_hf_directional_color",_vector(_policy.directional_color_linear))
	for item in ["max_opacity","start_cm","cutoff_cm","max_observer_height_cm","directional_exponent","directional_start_cm"]:
		material.set_shader_parameter("source_hf_"+item,float(_policy[item]))
	material.set_shader_parameter("source_hf_directional_enabled",bool(_policy.directional_enabled))
	material.set_shader_parameter("source_hf_sun_scale",_sun_scale)

func set_source_sun_intensity(source_intensity: float) -> void:
	_sun_scale = maxf(source_intensity,0.0)/maxf(float(_policy.get("sun_intensity",30.0)),0.000001)
	for material in _materials:
		if is_instance_valid(material): material.set_shader_parameter("source_hf_sun_scale",_sun_scale)
	report["sun_scale"] = _sun_scale

func attach_house_driver(driver: Node) -> Dictionary:
	_detach_house_driver()
	if not is_instance_valid(driver) or not driver.has_signal("house_state_changed"):
		return {"error":"Expected house_state_changed(inside)."}
	_house_driver = driver
	driver.connect("house_state_changed",Callable(self,"_on_house_state_changed"))
	var inside: Variant = driver.get("is_in_house")
	_on_house_state_changed(inside is bool and inside)
	return {"attached":true}

func _on_house_state_changed(inside: bool) -> void:
	set_source_sun_intensity(float(_options.get("interior_sun_intensity",3.0)) if inside else float(_policy.sun_intensity))

func _detach_house_driver() -> void:
	if is_instance_valid(_house_driver) and _house_driver.is_connected("house_state_changed",Callable(self,"_on_house_state_changed")):
		_house_driver.disconnect("house_state_changed",Callable(self,"_on_house_state_changed"))
	_house_driver = null

func restore() -> Dictionary:
	_detach_house_driver()
	var restored := 0
	for index in range(_saved.size()-1,-1,-1):
		var state: Dictionary = _saved[index]
		if not is_instance_valid(state.object): continue
		if state.has("shader"):
			state.object.shader = state.shader
			_restore_parameters(state)
		else: state.object.set(state.property,state.value)
		restored += 1
	_saved.clear()
	_seen.clear()
	_cache.clear()
	_materials.clear()
	return {"restored":restored}

func _save_shader(material: ShaderMaterial) -> void:
	var parameters: Dictionary = {}
	for uniform in material.shader.get_shader_uniform_list():
		parameters[uniform.name] = material.get_shader_parameter(uniform.name)
	_saved.append({"object":material,"shader":material.shader,"parameters":parameters})

func _restore_parameters(state: Dictionary) -> void:
	for key in state.parameters: state.object.set_shader_parameter(key,state.parameters[key])

func _save_property(object: Object, property: StringName, value: Variant) -> void:
	_saved.append({"object":object,"property":property,"value":object.get(property)})
	object.set(property,value)

func _vector(values: Array) -> Vector3:
	return Vector3(float(values[0]),float(values[1]),float(values[2]))

func _matches(value: String, expression: String, start: int = 0) -> bool:
	var regex := RegEx.new()
	regex.compile(expression)
	return regex.search(value,start) != null

func _span(clean: String, name: String) -> Vector3i:
	var regex := RegEx.new()
	regex.compile("void\\s+"+name+"\\s*\\(\\s*\\)\\s*\\{")
	var found := regex.search(clean)
	if found == null: return Vector3i(-1,-1,-1)
	var cursor := found.get_end()
	var depth := 1
	while cursor<clean.length() and depth>0:
		if clean[cursor]=="{": depth += 1
		elif clean[cursor]=="}": depth -= 1
		cursor += 1
	return Vector3i(found.get_start(),found.get_end(),cursor-1) if depth==0 else Vector3i(-1,-1,-1)

func _first_entry(clean: String) -> int:
	var first := clean.length()
	for name in ["vertex","fragment","light","sky"]:
		var span := _span(clean,name)
		if span.x>=0: first = mini(first,span.x)
	return first

func _function_text(code: String, name: String) -> String:
	var span := _span(_without_comments(code),name)
	return code.substr(span.x,span.z-span.x+1) if span.x>=0 else ""

func _preserved_body(before: String, after: String, name: String) -> bool:
	var a := _span(_without_comments(before),name)
	var b := _span(_without_comments(after),name)
	if a.x<0: return true
	if b.x<0: return false
	return after.substr(b.y,a.z-a.y)==before.substr(a.y,a.z-a.y)

func _without_comments(code: String) -> String:
	# Keep every character offset (including newlines) for safe source insertion.
	var result := code
	var regex := RegEx.new()
	regex.compile("/\\*[\\s\\S]*?\\*/|//[^\\r\\n]*")
	for found in regex.search_all(code):
		var value := found.get_string()
		var spaces := ""
		for c in value: spaces += c if c=="\n" or c=="\r" else " "
		result = result.substr(0,found.get_start())+spaces+result.substr(found.get_end())
	return result
