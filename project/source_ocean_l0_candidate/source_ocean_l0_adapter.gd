extends Node
## Diagnostic at actual fragments: source nondirectional L0 response using real Godot lights/shadows.
## This is NOT a TLV producer; no voxel filtering, pushout or cascade outer-edge fade.
var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _seen: Dictionary = {}
var _cache: Dictionary = {}
var _coefficients := PackedVector3Array()
var _gain := Vector3.ONE
var _sky_library := ""
var _house: Node
var _inside := false
var _mode := 1
var _source_sky := false
const DIFFUSE_LINE := "DIFFUSE_LIGHT += radiance * (nl / PI);"

func install(world: Node, coefficient_file: String, options: Dictionary = {}) -> Dictionary:
	if not _saved.is_empty(): return {"error":"Already installed; restore first."}
	if not is_instance_valid(world): return {"error":"Missing world."}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(coefficient_file))
	if not parsed is Dictionary or parsed.get("schema","")!="source_sh9_v1" or bool(parsed.get("gain_applied_to_coefficients",true)):
		return {"error":"Expected untinted source SH9 E/pi coefficients."}
	var entries: Array=parsed.get("e_over_pi_coefficients",[])
	var gain_array: Array=parsed.get("source_skylight_linear_gain",[])
	if entries.size()!=9 or gain_array.size()!=3: return {"error":"Incomplete SH9 policy."}
	_coefficients.clear()
	for entry: Array in entries:
		if entry.size()!=3: return {"error":"Invalid SH coefficient."}
		var coefficient := Vector3(float(entry[0]),float(entry[1]),float(entry[2]))
		if not coefficient.is_finite(): return {"error":"Non-finite SH coefficient."}
		_coefficients.append(coefficient)
	_gain=Vector3(float(gain_array[0]),float(gain_array[1]),float(gain_array[2]))
	if not _gain.is_finite(): return {"error":"Non-finite SH gain."}
	_sky_library=FileAccess.get_file_as_string("res://sh9_candidate/source_sh9.gdshaderinc")
	if _sky_library.is_empty(): return {"error":"Missing existing source SH9 library."}
	_mode=clampi(int(options.get("mode",1)),0,4)
	_source_sky=bool(options.get("replace_sky",false))
	report={"status":"installing","bound":0,"materials":[],"unsupported":[],"mode":_mode,"replace_sky":_source_sky,
		"limits":["Real per-fragment Godot attenuation/shadows and original light function/cone inputs.",
			"Not a TLV producer: no voxel filtering, half-voxel pushout, volume clamping or outer-edge shadow fade.",
			"Optional source SH9 replaces existing ambient; it is never added to direct L0.",
			"Base color, foam, reflection cubemap, fake specular, vertex and alpha expressions are preserved.",
			"Godot semantics and GPU validation remain parent work."]}
	_scan(world)
	report.status="installed"
	return report

func _scan(node: Node) -> void:
	if node is GeometryInstance3D:
		_bind(node.material_override,node)
		_bind(node.material_overlay,node)
	if node is MeshInstance3D and node.mesh!=null:
		for index in node.mesh.get_surface_count(): _bind(node.get_active_material(index),node)
	elif node is MultiMeshInstance3D and node.multimesh!=null and node.multimesh.mesh!=null:
		for index in node.multimesh.mesh.get_surface_count(): _bind(node.multimesh.mesh.surface_get_material(index),node)
	for child in node.get_children(): _scan(child)

func _bind(material: Material,node: Node) -> void:
	if material==null or _seen.has(material.get_instance_id()): return
	_seen[material.get_instance_id()]=true
	_bind(material.next_pass,node)
	if not material is ShaderMaterial or material.shader==null: return
	var original: Shader=material.shader
	var code: String=original.code
	# Identify actual recovered Ocean family, independent of dynamically changed shader path.
	if not code.contains("float source_fixed_depth(") or not code.contains("uniform float fake_spec_intensity"): return
	var label := {"material":material.resource_name,"node":str(node.get_path())}
	if code.count(DIFFUSE_LINE)!=1 or not code.contains("void light() {"):
		label.reason="Install after source local-cone adapter has expanded the original light function include."
		report.unsupported.append(label)
		return
	if code.contains("source_sh9_evaluate") or code.contains("IRRADIANCE ="):
		label.reason="Ocean already has an irradiance owner; refuse double injection."
		report.unsupported.append(label)
		return
	var span := _fragment_bounds(code)
	if span.x<0:
		label.reason="Fragment boundaries unavailable."
		report.unsupported.append(label)
		return
	var parameters: Dictionary={}
	for entry in original.get_shader_uniform_list(): parameters[entry.name]=material.get_shader_parameter(entry.name)
	if not _cache.has(original.get_instance_id()):
		var addition := "\n// source L0 diagnostic: substitute, never add to the existing Lambert.\n"
		addition += "if (source_ocean_l0_mode > 0 && source_ocean_l0_mode != 4) { DIFFUSE_LIGHT += radiance * ((0.282095 * 0.886228) / PI); }\n"
		addition += "else if (source_ocean_l0_mode == 0) { "+DIFFUSE_LINE+" }\n"
		var edited: String=code.replace(DIFFUSE_LINE,addition)
		# Original Ocean has explicit reflection/fake spec in emission, no default GGX.
		edited=edited.replace("if (nl > 0.0 && ROUGHNESS > 0.0)","if (source_ocean_l0_mode == 0 && nl > 0.0 && ROUGHNESS > 0.0)")
		span=_fragment_bounds(edited)
		var tail := "\nif (source_ocean_replace_sky) {\nvec3 source_ocean_sky_n=normalize((INV_VIEW_MATRIX*vec4(NORMAL,0.0)).xyz);\nIRRADIANCE=vec4(source_sh9_enabled ? source_sh9_evaluate(source_ocean_sky_n) : vec3(0.0),1.0);\n}\n"
		tail += "if (source_ocean_l0_mode == 2) { EMISSION=vec3(0.0); }\n"
		tail += "if (source_ocean_l0_mode == 3 || source_ocean_l0_mode == 4) { IRRADIANCE=vec4(0.0,0.0,0.0,1.0); RADIANCE=vec4(0.0,0.0,0.0,1.0); }\n"
		tail += "if (source_ocean_l0_mode == 3) { EMISSION=vec3(0.0); }\n"
		edited=edited.insert(span.y,tail)
		var uniforms := "\nuniform int source_ocean_l0_mode=1; // 0 baseline, 1 L0 all, 2 L0 no emission, 3 L0 direct only, 4 emission only.\nuniform bool source_ocean_replace_sky=false;\n"
		edited=edited.replace("shader_type spatial;","shader_type spatial;\n"+_sky_library+uniforms)
		var shader := Shader.new()
		shader.code=edited
		_cache[original.get_instance_id()]=shader
	_saved.append({"material":material,"shader":original,"parameters":parameters,"installed":_cache[original.get_instance_id()]})
	material.shader=_cache[original.get_instance_id()]
	for name in parameters: material.set_shader_parameter(name,parameters[name])
	material.set_shader_parameter("source_sh9_coefficients",_coefficients)
	material.set_shader_parameter("source_sh9_linear_gain",_gain)
	material.set_shader_parameter("source_sh9_enabled",not _inside)
	material.set_shader_parameter("source_ocean_l0_mode",_mode)
	material.set_shader_parameter("source_ocean_replace_sky",_source_sky)
	label["vertex_preserved"]=_function_text(code,"vertex")==_function_text(material.shader.code,"vertex")
	label["original_shader_sha256"]=code.sha256_text()
	label["candidate_shader_sha256"]=material.shader.code.sha256_text()
	report.materials.append(label)
	report.bound+=1

func _function_text(code: String,name: String) -> String:
	var start: int=code.find("void "+name+"()")
	if start<0: return ""
	var open: int=code.find("{",start)
	var cursor: int=open+1
	var nesting := 1
	while cursor<code.length() and nesting>0:
		if code[cursor]=="{": nesting+=1
		elif code[cursor]=="}": nesting-=1
		cursor+=1
	return code.substr(start,cursor-start) if nesting==0 else ""

func _fragment_bounds(code: String) -> Vector2i:
	var start: int=code.find("void fragment()")
	if start<0: return Vector2i(-1,-1)
	var open: int=code.find("{",start)
	var cursor: int=open+1
	var nesting := 1
	while cursor<code.length() and nesting>0:
		if code[cursor]=="{": nesting+=1
		elif code[cursor]=="}": nesting-=1
		cursor+=1
	return Vector2i(open+1,cursor-1) if nesting==0 else Vector2i(-1,-1)

func set_mode(mode: int,replace_sky: bool = false) -> void:
	_mode=clampi(mode,0,4)
	_source_sky=replace_sky
	for state in _saved:
		if is_instance_valid(state.material):
			state.material.set_shader_parameter("source_ocean_l0_mode",_mode)
			state.material.set_shader_parameter("source_ocean_replace_sky",_source_sky)
	report.mode=_mode
	report.replace_sky=_source_sky

func attach_house_driver(driver: Node) -> Dictionary:
	_detach_house()
	if not is_instance_valid(driver) or not driver.has_signal("house_state_changed"): return {"error":"Missing house signal."}
	_house=driver
	driver.connect("house_state_changed",Callable(self,"set_house_state"))
	var inside: Variant=driver.get("is_in_house")
	set_house_state(inside is bool and inside)
	return {"attached":true}

func set_house_state(inside: bool) -> void:
	_inside=inside
	for state in _saved:
		if is_instance_valid(state.material): state.material.set_shader_parameter("source_sh9_enabled",not inside)

func _detach_house() -> void:
	if is_instance_valid(_house) and _house.is_connected("house_state_changed",Callable(self,"set_house_state")):
		_house.disconnect("house_state_changed",Callable(self,"set_house_state"))
	_house=null

func restore() -> Dictionary:
	_detach_house()
	var restored := 0
	var errors: Array[String]=[]
	for state in _saved:
		if not is_instance_valid(state.material): continue
		var material: ShaderMaterial=state.material
		if material.shader!=state.installed:
			errors.append("Another owner changed "+material.resource_name+"; restore it first.")
			continue
		material.shader=state.shader
		for name in state.parameters: material.set_shader_parameter(name,state.parameters[name])
		restored+=1
	if errors.is_empty():
		_saved.clear()
		_cache.clear()
		_seen.clear()
	return {"restored_materials":restored,"errors":errors}

func _exit_tree() -> void:
	restore()
