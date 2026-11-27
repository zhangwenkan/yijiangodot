extends "res://scripts/verification/verify_source_tlv_receiver.gd"
## Temporary scene controls only; never write production source or assets.
## Each distortion triplet is captured in one callback.
var stage_effects: Array[CompositorEffect] = []
var stage_names := ["post-opaque","before-atmosphere","after-atmosphere"]

var renderdoc_gate_directory := ""
var renderdoc_gate_run_id := ""

func configure_renderdoc_gate() -> bool:
	var gate_values: Array[String] = []
	var run_values: Array[String] = []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--drift-renderdoc-gate="): gate_values.append(arg.trim_prefix("--drift-renderdoc-gate="))
		elif arg.begins_with("--drift-renderdoc-run-id="): run_values.append(arg.trim_prefix("--drift-renderdoc-run-id="))
		elif arg=="--drift-renderdoc-gate" or arg=="--drift-renderdoc-run-id":
			check(false,"RenderDoc gate options require explicit =values"); return false
	if gate_values.is_empty() and run_values.is_empty(): return true
	if gate_values.size()!=1 or run_values.size()!=1:
		check(false,"RenderDoc gate requires exactly one directory and run ID"); return false
	if not "--drift-landscape-raw-count-controls" in OS.get_cmdline_user_args():
		check(false,"RenderDoc gate is only permitted with explicit raw-count control"); return false
	var run_pattern := RegEx.new()
	run_pattern.compile("^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
	if run_pattern.search(run_values[0])==null:
		check(false,"RenderDoc run ID must be 1-96 ASCII letters/digits/._- starting with a letter or digit"); return false
	var directory: String = gate_values[0].replace("\\","/").simplify_path().trim_suffix("/")
	if not directory.is_absolute_path() or directory.begins_with("res:") or directory.begins_with("user:") or not DirAccess.dir_exists_absolute(directory):
		check(false,"RenderDoc gate directory must be an existing absolute filesystem directory"); return false
	for name in ["ready.json","ready.json.tmp","capture-complete.json","installed-shader.gdshader"]:
		if FileAccess.file_exists(directory.path_join(name)):
			check(false,"RenderDoc gate refuses pre-existing file: "+name); return false
	renderdoc_gate_directory = directory
	renderdoc_gate_run_id = run_values[0]
	report["renderdoc_gate"] = {"enabled":true,"schema_version":1,"run_id":renderdoc_gate_run_id,"directory":directory,
		"status":"configured","max_wait_wallclock_ms":90000,"boundary":"Two external RenderDoc captures during the frozen raw-count hold. Their frames are not claimed to match the later live compositor readbacks. No replay is requested by this diagnostic."}
	return true

func validate_renderdoc_completion(value: Variant, deadline: int) -> String:
	if not value is Dictionary: return "completion is not a JSON object"
	if value.get("schema_version",0)!=1 or value.get("status","")!="captured_not_replayed": return "completion schema/status mismatch"
	if value.get("run_id","")!=renderdoc_gate_run_id or value.get("target_pid",0)!=OS.get_process_id(): return "completion run ID/PID mismatch"
	var captures: Variant = value.get("captures",null)
	if not captures is Array or captures.size()!=2: return "completion requires exactly two captures"
	var hash_pattern := RegEx.new()
	hash_pattern.compile("^[0-9a-f]{64}$")
	var seen_paths: Dictionary = {}
	for index in 2:
		var capture: Variant = captures[index]
		if not capture is Dictionary or capture.get("index",-1)!=index: return "capture index/order mismatch"
		var path: String = str(capture.get("path","")).replace("\\","/").simplify_path()
		if not path.is_absolute_path() or not path.to_lower().begins_with(renderdoc_gate_directory.to_lower()+"/") or path.get_extension().to_lower()!="rdc": return "capture path is not an RDC inside the gate directory"
		if seen_paths.has(path.to_lower()): return "duplicate capture path"
		seen_paths[path.to_lower()] = true
		var expected_size: Variant = capture.get("bytes",0)
		if not (expected_size is int or expected_size is float) or expected_size<=0 or float(expected_size)!=floor(float(expected_size)): return "capture size must be a positive integer"
		var expected_hash: String = str(capture.get("sha256",""))
		if hash_pattern.search(expected_hash)==null: return "capture SHA-256 metadata invalid"
		var file := FileAccess.open(path,FileAccess.READ)
		if file==null: return "capture file is missing/unreadable"
		var actual_size := file.get_length()
		if actual_size!=int(expected_size):
			file.close()
			return "capture size differs from completion metadata"
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		var remaining := actual_size
		while remaining>0:
			if Time.get_ticks_msec()>=deadline:
				file.close()
				return "90-second wall-clock deadline reached while validating capture files"
			var chunk := file.get_buffer(mini(8*1024*1024,remaining))
			if chunk.is_empty():
				file.close()
				return "capture file ended during SHA-256 validation"
			context.update(chunk)
			remaining -= chunk.size()
			await process_frame
		var size_after_hash := file.get_length()
		file.close()
		if Time.get_ticks_msec()>=deadline: return "90-second wall-clock deadline reached after capture validation yield"
		if size_after_hash!=actual_size: return "capture size changed during SHA-256 validation"
		if context.finish().hex_encode()!=expected_hash: return "capture SHA-256 differs from completion metadata"
	return ""

func wait_for_renderdoc_capture_gate(installed: Shader) -> void:
	if renderdoc_gate_directory.is_empty(): return
	var gate: Dictionary = report.renderdoc_gate
	var ready_path := renderdoc_gate_directory.path_join("ready.json")
	var temporary_path := renderdoc_gate_directory.path_join("ready.json.tmp")
	var completion_path := renderdoc_gate_directory.path_join("capture-complete.json")
	var shader_path := renderdoc_gate_directory.path_join("installed-shader.gdshader")
	if FileAccess.file_exists(ready_path) or FileAccess.file_exists(temporary_path) or FileAccess.file_exists(completion_path) or FileAccess.file_exists(shader_path):
		gate.status = "rejected_stale_files"
		check(false,"RenderDoc gate files appeared before READY; continuing to raw readback and shader restore")
		return
	var frozen: bool = scene.process_mode==Node.PROCESS_MODE_DISABLED and Engine.time_scale==0.0
	if not frozen:
		gate.status = "rejected_not_frozen"
		check(false,"RenderDoc gate requires frozen scene; continuing to raw readback and shader restore")
		return
	var shader_file := FileAccess.open(shader_path,FileAccess.WRITE)
	if shader_file==null:
		gate.status = "shader_source_write_failed"
		check(false,"RenderDoc gate could not save installed shader source; continuing to raw readback and shader restore")
		return
	shader_file.store_string(installed.code)
	shader_file.close()
	if FileAccess.get_sha256(shader_path)!=installed.code.sha256_text():
		gate.status = "shader_source_write_mismatch"
		check(false,"RenderDoc gate installed shader source hash differs; continuing to raw readback and shader restore")
		return
	var ready := {"schema_version":1,"state":"ready","run_id":renderdoc_gate_run_id,"pid":OS.get_process_id(),
		"phase":"landscape-raw-count","shader_sha256":installed.code.sha256_text(),"shader_source_path":shader_path,"frozen":true,"drawn_frame":Engine.get_frames_drawn()}
	var handle := FileAccess.open(temporary_path,FileAccess.WRITE)
	if handle==null:
		gate.status = "ready_write_failed"
		check(false,"RenderDoc gate could not write READY; continuing to raw readback and shader restore")
		return
	handle.store_string(JSON.stringify(ready,"\t"))
	handle.close()
	if DirAccess.rename_absolute(temporary_path,ready_path)!=OK:
		gate.status = "ready_publish_failed"
		check(false,"RenderDoc gate could not publish READY; continuing to raw readback and shader restore")
		return
	gate.status = "ready"
	gate["ready"] = ready
	gate["live_readback_captures_before_hold"] = report.captures.size()
	var started := Time.get_ticks_msec()
	progress("renderdoc raw-count ready")
	while Time.get_ticks_msec()-started<90000:
		if FileAccess.file_exists(completion_path):
			var completion_text := FileAccess.get_file_as_string(completion_path)
			var completion: Variant = JSON.parse_string(completion_text)
			var error := await validate_renderdoc_completion(completion,started+90000)
			gate["completion_file_sha256"] = completion_text.sha256_text()
			gate["elapsed_wallclock_ms"] = Time.get_ticks_msec()-started
			gate["release_drawn_frame"] = Engine.get_frames_drawn()
			if not error.is_empty():
				gate.status = "invalid_completion"
				gate["error"] = error
				if completion is Dictionary and completion.get("run_id","")==renderdoc_gate_run_id and completion.get("target_pid",0)==OS.get_process_id(): gate["completion"] = completion
				check(false,"RenderDoc gate completion rejected: "+error+"; continuing to raw readback and shader restore")
			else:
				gate.status = "captured_not_replayed"
				gate["completion"] = completion
			progress("renderdoc gate released")
			return
		await process_frame
	gate.status = "timeout"
	gate["elapsed_wallclock_ms"] = Time.get_ticks_msec()-started
	gate["release_drawn_frame"] = Engine.get_frames_drawn()
	check(false,"RenderDoc gate timed out after 90 wall-clock seconds; continuing to raw readback and shader restore")
	progress("renderdoc gate timeout")


func landscape_value_snapshot(value: Variant) -> Variant:
	return value.duplicate(true) if value is Array or value is Dictionary else value

func landscape_value_record(value: Variant) -> Dictionary:
	if value is Resource:
		return {"variant_type":type_string(typeof(value)),"resource_class":value.get_class(),
			"resource_path":value.resource_path,"instance_id":value.get_instance_id()}
	return {"variant_type":type_string(typeof(value)),"value":var_to_str(value)}

func landscape_collect_material(material: Material, node_path: String, slot: String, states: Dictionary) -> void:
	if material == null: return
	var id: int = material.get_instance_id()
	var use := {"node":node_path,"slot":slot}
	if states.has(id):
		if not states[id].uses.has(use): states[id].uses.append(use)
		return
	var state := {"material":material,"uses":[use],"next_pass":material.next_pass,
		"render_priority":material.render_priority,"resource_name":material.resource_name,
		"resource_path":material.resource_path,"shader":null,"shader_sha256":"","parameters":{},"properties":{}}
	if material is ShaderMaterial and material.shader != null:
		state.shader = material.shader
		state.shader_sha256 = material.shader.code.sha256_text()
		for uniform in material.shader.get_shader_uniform_list():
			state.parameters[uniform.name] = landscape_value_snapshot(material.get_shader_parameter(uniform.name))
	else:
		# Retain other material classes too; all exposed stored properties stay unchanged.
		for property in material.get_property_list():
			if (int(property.usage) & PROPERTY_USAGE_STORAGE)!=0:
				state.properties[property.name] = landscape_value_snapshot(material.get(property.name))
	states[id] = state
	landscape_collect_material(material.next_pass,node_path,slot+"/next_pass",states)

func landscape_snapshot_materials() -> Dictionary:
	var states: Dictionary = {}
	for node in scene.find_children("*","GeometryInstance3D",true,false):
		var path := str(node.get_path())
		landscape_collect_material(node.material_override,path,"override",states)
		landscape_collect_material(node.material_overlay,path,"overlay",states)
		if node is MeshInstance3D and node.mesh != null:
			for i in node.mesh.get_surface_count():
				landscape_collect_material(node.get_surface_override_material(i),path,"surface_override/%d" % i,states)
				landscape_collect_material(node.mesh.surface_get_material(i),path,"mesh_surface/%d" % i,states)
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			for i in node.multimesh.mesh.get_surface_count():
				landscape_collect_material(node.multimesh.mesh.surface_get_material(i),path,"multimesh_surface/%d" % i,states)
	return states

func landscape_material_records(states: Dictionary) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for id in states:
		var state: Dictionary = states[id]
		var parameters: Dictionary = {}
		var properties: Dictionary = {}
		for key in state.parameters: parameters[key] = landscape_value_record(state.parameters[key])
		for key in state.properties: properties[key] = landscape_value_record(state.properties[key])
		records.append({"material_id":id,"class":state.material.get_class(),"resource_name":state.resource_name,
			"resource_path":state.resource_path,"uses":state.uses,"shader_sha256":state.shader_sha256,
			"shader_instance_id":state.shader.get_instance_id() if state.shader != null else 0,
			"shader_resource_path":state.shader.resource_path if state.shader != null else "",
			"next_pass":landscape_value_record(state.next_pass),"render_priority":state.render_priority,
			"parameters":parameters,"stored_properties":properties})
	return records

func landscape_verify_materials(states: Dictionary, target_id: int, installed: Shader, label: String) -> bool:
	var start: int = report.failures.size()
	var current := landscape_snapshot_materials()
	check(current.size()==states.size(),label+": referenced material count changed")
	for id in states:
		var state: Dictionary = states[id]
		if not current.has(id): check(false,label+": material no longer referenced "+str(id)); continue
		var material: Material = state.material
		check(current[id].uses==state.uses,label+": geometry material references changed "+str(id))
		check(material.next_pass==state.next_pass and material.render_priority==state.render_priority,label+": material pass/priority changed "+str(id))
		check(material.resource_name==state.resource_name and material.resource_path==state.resource_path,label+": material identity changed "+str(id))
		if material is ShaderMaterial:
			var expected: Shader = installed if id==target_id and installed!=null else state.shader
			check(material.shader==expected,label+": shader owner changed "+str(id))
			var expected_hash: String = report.landscape_control.installed_shader_sha256 if id==target_id and installed!=null else state.shader_sha256
			check((material.shader.code.sha256_text() if material.shader!=null else "")==expected_hash,label+": shader source changed "+str(id))
			check(current[id].parameters.size()==state.parameters.size(),label+": uniform count changed "+str(id))
			for key in state.parameters:
				check(material.get_shader_parameter(key)==state.parameters[key],label+": uniform changed "+str(id)+" / "+str(key))
		else:
			for key in state.properties:
				check(material.get(key)==state.properties[key],label+": stored material property changed "+str(id)+" / "+str(key))
	var passed: bool = report.failures.size()==start
	report.landscape_control.state_checks.append({"label":label,"passed":passed,"material_count":states.size(),"target_material_id":target_id,
		"target_control_active":installed!=null,"target_unshaded":installed!=null and report.landscape_control.control_variant=="unshaded","scope":"CPU-visible scene geometry references, material shaders/parameters and stored non-ShaderMaterial properties; not GPU uniform readback."})
	return passed

func run_landscape_controls(variant: String="unshaded") -> void:
	if variant not in ["unshaded","no-direct-specular","no-local-cone","direct-series","local-input-series","raw-count"]:
		check(false,"Unsupported landscape control variant"); return
	var condition := "landscape-"+variant
	report.landscape_control = {"scope":"One original Youxian landscape receives a temporary shader control; diagnosis, not a rendering fix or source UE equivalence.",
		"control_variant":variant,
		"expected_node":"OriginalLandscape_youxian","expected_material":"OriginalLandscape_Compiled_youxian",
		"state_checks":[],"identification":[],"source_shader_preserved_except_render_mode":false}
	var candidates: Array[MeshInstance3D] = []
	for node in scene.world.find_children("*","MeshInstance3D",true,false):
		if str(node.name)!="OriginalLandscape_youxian": continue
		var material: Material = node.material_override
		var matches: bool = node.get_meta("original_landscape",false)==true and str(node.get_meta("map_slug",""))=="youxian"
		matches = matches and material is ShaderMaterial and material.shader!=null
		if matches:
			matches = material.resource_name=="OriginalLandscape_Compiled_youxian" and material.get_meta("source_landscape_compiled",false)==true and str(material.get_meta("source_surface_family",""))=="M_TFK_Dipi01"
		report.landscape_control.identification.append({"node":str(node.get_path()),"node_id":node.get_instance_id(),
			"original_landscape":node.get_meta("original_landscape",false),"map_slug":node.get_meta("map_slug",""),
			"source_component_count":node.get_meta("source_component_count",-1),"matched":matches,
			"material_id":material.get_instance_id() if material!=null else 0,"material_resource_name":material.resource_name if material!=null else ""})
		if matches: candidates.append(node)
	check(scene.slug=="youxian" and candidates.size()==1,"Landscape control requires exactly one identified original Youxian landscape")
	if scene.slug!="youxian" or candidates.size()!=1: return
	var target: ShaderMaterial = candidates[0].material_override
	var target_id: int = target.get_instance_id()
	var states := landscape_snapshot_materials()
	if not states.has(target_id): check(false,"Identified landscape material missing from snapshot"); return
	var target_state: Dictionary = states[target_id]
	var single_override: bool = target_state.uses.size()==1 and target_state.uses[0].node==str(candidates[0].get_path()) and target_state.uses[0].slot=="override"
	check(single_override,"Landscape material is shared outside its single original override")
	if not single_override: return
	var code: String = target_state.shader.code
	var render_mode := RegEx.new()
	render_mode.compile("(?m)^render_mode\\s+[^;]+;")
	var render_matches := render_mode.search_all(code)
	check(render_matches.size()==1,"Landscape runtime shader must have exactly one render_mode declaration")
	if render_matches.size()!=1: return
	var unshaded := RegEx.new()
	unshaded.compile("\\bunshaded\\b")
	if unshaded.search(render_matches[0].get_string())!=null: check(false,"Landscape was already unshaded before control"); return
	if variant=="raw-count":
		await run_landscape_raw_count(target,states,target_state,code)
		return
	if variant=="local-input-series":
		await run_landscape_local_input_series(target,states,target_state,code)
		return
	if variant=="direct-series":
		await run_landscape_direct_series(target,states,target_state,code)
		return
	var at: int = render_matches[0].get_end()-1
	var installed := Shader.new()
	if variant=="no-direct-specular":
		# The source renderer expands the receiving include before this snapshot.
		# Reject any unexpected shader instead of editing a shared source/include.
		var guard := "if (nl > 0.0 && ROUGHNESS > 0.0) {"
		var disabled_guard := "if (false && nl > 0.0 && ROUGHNESS > 0.0) {"
		var addition := "SPECULAR_LIGHT += radiance * distribution * visibility * fresnel * nl * SPECULAR_AMOUNT;"
		check(code.count(guard)==1 and code.count(addition)==1,"Landscape direct-specular guard/addition must occur exactly once in expanded runtime shader")
		if code.count(guard)!=1 or code.count(addition)!=1: return
		installed.code = code.replace(guard,disabled_guard)
		report.landscape_control.source_shader_preserved_except_specular_guard = installed.code.replace(disabled_guard,guard)==code
		report.landscape_control.specular_guard_original = guard
		report.landscape_control.specular_guard_installed = disabled_guard
	elif variant=="no-local-cone":
		# The cone adapter has already expanded its library in this material only.
		# Force the existing correction guard to return one; keep all light inputs.
		var guard := "if (found < 0 || source_local_cone_position_kind[found].w < 0.5) return 1.0;"
		var disabled_guard := "if (true || found < 0 || source_local_cone_position_kind[found].w < 0.5) return 1.0;"
		var declaration := "float source_local_cone_correction(vec3 fragment_world, vec3 world_light_ray) {"
		var call_site := "source_local_cone_correction(source_lf_fragment_world, normalize((INV_VIEW_MATRIX * vec4(LIGHT,0.0)).xyz))"
		check(code.count(guard)==1 and code.count(declaration)==1 and code.count(call_site)==1,"Landscape cone guard/function/call must occur exactly once in expanded runtime shader")
		if code.count(guard)!=1 or code.count(declaration)!=1 or code.count(call_site)!=1: return
		check(states.size()==370 and target_state.parameters.size()==70,"Cone control requires the audited 370 materials and 70 target uniforms")
		if states.size()!=370 or target_state.parameters.size()!=70: return
		check(int(target_state.parameters.get("source_local_cone_count",0))>0,"Cone control requires an active source local-cone binding")
		if int(target_state.parameters.get("source_local_cone_count",0))<=0: return
		installed.code = code.replace(guard,disabled_guard)
		report.landscape_control.source_shader_preserved_except_cone_guard = installed.code.replace(disabled_guard,guard)==code
		report.landscape_control.cone_guard_original = guard
		report.landscape_control.cone_guard_installed = disabled_guard
		report.landscape_control.source_local_cone_count = int(target_state.parameters.source_local_cone_count)
	else:
		installed.code = code.insert(at,", unshaded")
		report.landscape_control.source_shader_preserved_except_render_mode = installed.code.substr(0,at)+installed.code.substr(at+", unshaded".length())==code
	report.landscape_control.original_shader_sha256 = code.sha256_text()
	report.landscape_control.installed_shader_sha256 = installed.code.sha256_text()
	report.landscape_control.target_material_id = target_id
	report.landscape_control.material_count = states.size()
	report.landscape_control.other_material_count = states.size()-1
	FileAccess.open(out.path_join("landscape-materials-before.json"),FileAccess.WRITE).store_string(JSON.stringify(landscape_material_records(states),"\t"))
	FileAccess.open(out.path_join("landscape-runtime-original.gdshader"),FileAccess.WRITE).store_string(code)
	FileAccess.open(out.path_join("landscape-runtime-"+str(report.landscape_control.control_variant)+".gdshader"),FileAccess.WRITE).store_string(installed.code)
	for i in 4: await save_distortion("original-%02d" % i)
	if not landscape_verify_materials(states,target_id,null,"after-original"): return
	target.shader = installed
	for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
	await settle(20)
	landscape_verify_materials(states,target_id,installed,"before-"+condition)
	for i in 4: await save_distortion(condition+"-%02d" % i)
	landscape_verify_materials(states,target_id,installed,"after-"+condition)
	# Never overwrite a competing shader owner during diagnostic cleanup.
	if target.shader!=installed or target_state.shader.code.sha256_text()!=code.sha256_text():
		check(false,"Landscape shader owner/source changed before restore"); return
	target.shader = target_state.shader
	for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
	await settle(20)
	landscape_verify_materials(states,target_id,null,"before-restored")
	for i in 4: await save_distortion("restored-%02d" % i)
	landscape_verify_materials(states,target_id,null,"after-restored")
	FileAccess.open(out.path_join("landscape-materials-restored.json"),FileAccess.WRITE).store_string(JSON.stringify(landscape_material_records(landscape_snapshot_materials()),"\t"))

func run_landscape_direct_series(target: ShaderMaterial, states: Dictionary, target_state: Dictionary, code: String) -> void:
	var target_id: int = target.get_instance_id()
	check(states.size()==370 and target_state.parameters.size()==70,"Direct-light control requires 370 materials and 70 target uniforms")
	if states.size()!=370 or target_state.parameters.size()!=70: return
	var additions: Array[String] = [
		"SPECULAR_LIGHT += radiance*leaf_wrap*leaf_scatter*source_leaf_subsurface;",
		"DIFFUSE_LIGHT += radiance * (nl / PI);",
		"SPECULAR_LIGHT += radiance * distribution * visibility * fresnel * nl * SPECULAR_AMOUNT;"]
	var accumulation := RegEx.new()
	accumulation.compile("\\b(?:DIFFUSE_LIGHT|SPECULAR_LIGHT)\\s*\\+=")
	check(accumulation.search_all(code).size()==3,"Direct-light control requires exactly the three audited light accumulations")
	if accumulation.search_all(code).size()!=3: return
	for addition in additions:
		check(code.count(addition)==1,"Expected unique original direct-light accumulation: "+addition)
		if code.count(addition)!=1: return
	var variants: Array[Dictionary] = [
		{"name":"directional-only","guard":"LIGHT_IS_DIRECTIONAL"},
		{"name":"local-only","guard":"!LIGHT_IS_DIRECTIONAL"},
		{"name":"no-direct","guard":"false"}]
	report.landscape_control["direct_variants"] = []
	report.landscape_control["direct_accumulations"] = additions
	report.landscape_control["original_shader_sha256"] = code.sha256_text()
	report.landscape_control["target_material_id"] = target_id
	report.landscape_control["material_count"] = states.size()
	report.landscape_control["other_material_count"] = states.size()-1
	report.landscape_control["source_evaluation_boundary"] = "Only the three accumulation statements are guarded. All source sampling/normal/LF/cone/IRRADIANCE code remains byte-identical. Static branch compilation may eliminate unused evaluation; identical GPU instruction execution is not asserted."
	for variant in variants:
		var installed_code := code
		for addition in additions:
			installed_code = installed_code.replace(addition,"if ("+str(variant.guard)+") { "+addition+" }")
		var inverse := installed_code
		for addition in additions:
			inverse = inverse.replace("if ("+str(variant.guard)+") { "+addition+" }",addition)
		check(inverse==code,"Direct-light control changed code outside three guards")
		if inverse!=code: return
		var shader := Shader.new()
		shader.code = installed_code
		variant["shader"] = shader
		var filename := "landscape-runtime-"+str(variant.name)+".gdshader"
		FileAccess.open(out.path_join(filename),FileAccess.WRITE).store_string(installed_code)
		report.landscape_control.direct_variants.append({"name":variant.name,"guard":variant.guard,
			"shader_file":filename,"shader_sha256":installed_code.sha256_text(),"source_preserved_except_accumulation_guards":inverse==code})
	FileAccess.open(out.path_join("landscape-materials-before.json"),FileAccess.WRITE).store_string(JSON.stringify(landscape_material_records(states),"\t"))
	FileAccess.open(out.path_join("landscape-runtime-original.gdshader"),FileAccess.WRITE).store_string(code)
	for i in 4: await save_distortion("original-%02d" % i)
	if not landscape_verify_materials(states,target_id,null,"after-original"): return
	var previous: Shader = target_state.shader
	for variant in variants:
		if target.shader!=previous or target_state.shader.code.sha256_text()!=code.sha256_text():
			check(false,"Direct-light control shader owner/source changed before next variant"); return
		var shader: Shader = variant.shader
		report.landscape_control.installed_shader_sha256 = shader.code.sha256_text()
		target.shader = shader
		for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
		await settle(20)
		var condition := "landscape-"+str(variant.name)
		landscape_verify_materials(states,target_id,shader,"before-"+condition)
		for i in 4: await save_distortion(condition+"-%02d" % i)
		landscape_verify_materials(states,target_id,shader,"after-"+condition)
		previous = shader
	if target.shader!=previous or target_state.shader.code.sha256_text()!=code.sha256_text():
		check(false,"Direct-light control shader owner/source changed before restore"); return
	target.shader = target_state.shader
	for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
	await settle(20)
	landscape_verify_materials(states,target_id,null,"before-restored")
	for i in 4: await save_distortion("restored-%02d" % i)
	landscape_verify_materials(states,target_id,null,"after-restored")
	FileAccess.open(out.path_join("landscape-materials-restored.json"),FileAccess.WRITE).store_string(JSON.stringify(landscape_material_records(landscape_snapshot_materials()),"\t"))


func run_landscape_local_input_series(target: ShaderMaterial, states: Dictionary, target_state: Dictionary, code: String) -> void:
	var target_id: int = target.get_instance_id()
	check(states.size()==370 and target_state.parameters.size()==70,"Local-input control requires 370 materials and 70 target uniforms")
	if states.size()!=370 or target_state.parameters.size()!=70: return
	var diffuse := "DIFFUSE_LIGHT += radiance * (nl / PI);"
	var specular: Array[String] = [
		"SPECULAR_LIGHT += radiance*leaf_wrap*leaf_scatter*source_leaf_subsurface;",
		"SPECULAR_LIGHT += radiance * distribution * visibility * fresnel * nl * SPECULAR_AMOUNT;"]
	var accumulation := RegEx.new()
	accumulation.compile("\\b(?:DIFFUSE_LIGHT|SPECULAR_LIGHT)\\s*\\+=")
	check(accumulation.search_all(code).size()==3,"Local-input control requires exactly the three audited light accumulations")
	if accumulation.search_all(code).size()!=3: return
	check(code.count(diffuse)==1,"Expected unique original diffuse accumulation")
	if code.count(diffuse)!=1: return
	for addition in specular:
		check(code.count(addition)==1,"Expected unique original specular accumulation: "+addition)
		if code.count(addition)!=1: return
	var variants: Array[Dictionary] = [
		{"name":"local-count","expression":"vec3(1.0) / 16.0"},
		{"name":"local-color","expression":"LIGHT_COLOR / PI"},
		{"name":"local-attenuation","expression":"LIGHT_COLOR * ATTENUATION / PI"},
		{"name":"local-lambert","expression":"LIGHT_COLOR * ATTENUATION * (nl / PI)"}]
	report.landscape_control["local_input_variants"] = []
	report.landscape_control["local_input_diffuse_original"] = diffuse
	report.landscape_control["local_input_specular_original"] = specular
	report.landscape_control["original_shader_sha256"] = code.sha256_text()
	report.landscape_control["target_material_id"] = target_id
	report.landscape_control["material_count"] = states.size()
	report.landscape_control["other_material_count"] = states.size()-1
	report.landscape_control["source_evaluation_boundary"] = "Only the three accumulation statements are replaced. Source sampling/normal/LF/cone/IRRADIANCE code and all uniforms remain unchanged. Static branches and unconsumed values may be optimized away; identical GPU instruction execution is not asserted."
	for variant in variants:
		var replacement := "if (!LIGHT_IS_DIRECTIONAL) { DIFFUSE_LIGHT += "+str(variant.expression)+"; }"
		var installed_code := code.replace(diffuse,replacement)
		for addition in specular: installed_code = installed_code.replace(addition,"if (false) { "+addition+" }")
		var inverse := installed_code.replace(replacement,diffuse)
		for addition in specular: inverse = inverse.replace("if (false) { "+addition+" }",addition)
		check(inverse==code,"Local-input control changed code outside three accumulation statements")
		if inverse!=code: return
		var shader := Shader.new()
		shader.code = installed_code
		variant["shader"] = shader
		var filename := "landscape-runtime-"+str(variant.name)+".gdshader"
		FileAccess.open(out.path_join(filename),FileAccess.WRITE).store_string(installed_code)
		report.landscape_control.local_input_variants.append({"name":variant.name,"diffuse_guard":"!LIGHT_IS_DIRECTIONAL",
			"diffuse_expression":variant.expression,"diffuse_replacement":replacement,"specular_guard":"false",
			"shader_file":filename,"shader_sha256":installed_code.sha256_text(),"source_preserved_except_accumulations":inverse==code})
	FileAccess.open(out.path_join("landscape-materials-before.json"),FileAccess.WRITE).store_string(JSON.stringify(landscape_material_records(states),"\t"))
	FileAccess.open(out.path_join("landscape-runtime-original.gdshader"),FileAccess.WRITE).store_string(code)
	for i in 4: await save_distortion("original-%02d" % i)
	if not landscape_verify_materials(states,target_id,null,"after-original"): return
	var previous: Shader = target_state.shader
	for variant in variants:
		if target.shader!=previous or target_state.shader.code.sha256_text()!=code.sha256_text():
			check(false,"Local-input control shader owner/source changed before next variant"); return
		var shader: Shader = variant.shader
		report.landscape_control.installed_shader_sha256 = shader.code.sha256_text()
		target.shader = shader
		for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
		await settle(20)
		var condition := "landscape-"+str(variant.name)
		landscape_verify_materials(states,target_id,shader,"before-"+condition)
		for i in 4: await save_distortion(condition+"-%02d" % i)
		landscape_verify_materials(states,target_id,shader,"after-"+condition)
		previous = shader
	if target.shader!=previous or target_state.shader.code.sha256_text()!=code.sha256_text():
		check(false,"Local-input control shader owner/source changed before restore"); return
	target.shader = target_state.shader
	for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
	await settle(20)
	landscape_verify_materials(states,target_id,null,"before-restored")
	for i in 4: await save_distortion("restored-%02d" % i)
	landscape_verify_materials(states,target_id,null,"after-restored")
	FileAccess.open(out.path_join("landscape-materials-restored.json"),FileAccess.WRITE).store_string(JSON.stringify(landscape_material_records(landscape_snapshot_materials()),"\t"))


func run_landscape_raw_count(target: ShaderMaterial, states: Dictionary, target_state: Dictionary, code: String) -> void:
	var target_id: int = target.get_instance_id()
	check(states.size()==370 and target_state.parameters.size()==70,"Raw-count control requires 370 materials and 70 target uniforms")
	if states.size()!=370 or target_state.parameters.size()!=70: return
	var diffuse := "DIFFUSE_LIGHT += radiance * (nl / PI);"
	var replacement := "if (!LIGHT_IS_DIRECTIONAL) { DIFFUSE_LIGHT += vec3(1.0) / 16.0; }"
	var specular: Array[String] = [
		"SPECULAR_LIGHT += radiance*leaf_wrap*leaf_scatter*source_leaf_subsurface;",
		"SPECULAR_LIGHT += radiance * distribution * visibility * fresnel * nl * SPECULAR_AMOUNT;"]
	var tail := "FOG = source_height_fog_to_godot(source_hf_result,false);\n}\r\n"
	var output_override := "ALBEDO = vec3(1.0);\nMETALLIC = 0.0;\nSPECULAR = 0.0;\nEMISSION = vec3(0.0);\nIRRADIANCE = vec4(0.0,0.0,0.0,1.0);\nRADIANCE = vec4(0.0,0.0,0.0,1.0);\n"
	var injected_tail := tail.substr(0,tail.length()-3)+output_override+"}\r\n"
	var accumulation := RegEx.new()
	accumulation.compile("\\b(?:DIFFUSE_LIGHT|SPECULAR_LIGHT)\\s*\\+=")
	check(accumulation.search_all(code).size()==3 and code.count(diffuse)==1,"Raw-count control requires exactly three audited accumulations")
	if accumulation.search_all(code).size()!=3 or code.count(diffuse)!=1: return
	check(code.count("void fragment() {")==1 and code.count(tail)==1 and code.ends_with(tail),"Raw-count fragment must end at the unique audited FOG tail")
	if code.count("void fragment() {")!=1 or code.count(tail)!=1 or not code.ends_with(tail): return
	for addition in specular:
		check(code.count(addition)==1,"Expected unique raw-count specular accumulation")
		if code.count(addition)!=1: return
	var render_mode := RegEx.new()
	render_mode.compile("(?m)^render_mode\\s+[^;]+;")
	var declarations := render_mode.search_all(code)
	check(declarations.size()==1 and not "fog_disabled" in declarations[0].get_string() and not "ambient_light_disabled" in declarations[0].get_string(),"Raw-count requires one original fog/ambient-enabled render_mode")
	if declarations.size()!=1 or "fog_disabled" in declarations[0].get_string() or "ambient_light_disabled" in declarations[0].get_string(): return
	var original_mode: String = declarations[0].get_string()
	var installed_mode := original_mode.substr(0,original_mode.length()-1)+", fog_disabled, ambient_light_disabled;"
	var installed_code := code.replace(original_mode,installed_mode).replace(tail,injected_tail).replace(diffuse,replacement)
	for addition in specular: installed_code = installed_code.replace(addition,"if (false) { "+addition+" }")
	var inverse := installed_code.replace(installed_mode,original_mode).replace(injected_tail,tail).replace(replacement,diffuse)
	for addition in specular: inverse = inverse.replace("if (false) { "+addition+" }",addition)
	check(inverse==code,"Raw-count changed source beyond audited render_mode, fragment outputs and accumulations")
	if inverse!=code: return
	var installed := Shader.new()
	installed.code = installed_code
	report.landscape_control["raw_count"] = {"diffuse_original":diffuse,"diffuse_replacement":replacement,"specular_original":specular,
		"fragment_tail_original":tail,"fragment_tail_installed":injected_tail,"output_override":output_override,
		"render_mode_original":original_mode,"render_mode_installed":installed_mode,"inverse_source_exact":inverse==code,
		"count_scale":16,"count_min":0,"count_max":31,"scope":"Candidate local-light invocation count; unchanged other materials are not count data. Exact RGB/integer validation must succeed on captured post-opaque HDR before interpreting counts."}
	report.landscape_control["original_shader_sha256"] = code.sha256_text()
	report.landscape_control["installed_shader_sha256"] = installed_code.sha256_text()
	report.landscape_control["target_material_id"] = target_id
	report.landscape_control["material_count"] = states.size()
	report.landscape_control["other_material_count"] = states.size()-1
	report.landscape_control["source_evaluation_boundary"] = "All normal, roughness, source LF/cone and texture evaluation source remains unchanged. Constant output overrides and static guards may remove unused compiled evaluation; identical GPU instruction execution is not asserted."
	FileAccess.open(out.path_join("landscape-materials-before.json"),FileAccess.WRITE).store_string(JSON.stringify(landscape_material_records(states),"\t"))
	FileAccess.open(out.path_join("landscape-runtime-original.gdshader"),FileAccess.WRITE).store_string(code)
	FileAccess.open(out.path_join("landscape-runtime-raw-count.gdshader"),FileAccess.WRITE).store_string(installed_code)
	for i in 4: await save_distortion("original-%02d" % i)
	if not landscape_verify_materials(states,target_id,null,"after-original"): return
	target.shader = installed
	for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
	await settle(20)
	landscape_verify_materials(states,target_id,installed,"before-landscape-raw-count")
	# A failed optional external capture gate must still reach the existing restore below.
	await wait_for_renderdoc_capture_gate(installed)
	for i in 4: await save_distortion("landscape-raw-count-%02d" % i)
	landscape_verify_materials(states,target_id,installed,"after-landscape-raw-count")
	if target.shader!=installed or target_state.shader.code.sha256_text()!=code.sha256_text():
		check(false,"Raw-count shader owner/source changed before restore"); return
	target.shader = target_state.shader
	for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
	await settle(20)
	landscape_verify_materials(states,target_id,null,"before-restored")
	for i in 4: await save_distortion("restored-%02d" % i)
	landscape_verify_materials(states,target_id,null,"after-restored")
	FileAccess.open(out.path_join("landscape-materials-restored.json"),FileAccess.WRITE).store_string(JSON.stringify(landscape_material_records(landscape_snapshot_materials()),"\t"))


func snapshot_light_function_uniforms() -> Array[Dictionary]:
	var saved: Array[Dictionary] = []
	var seen: Dictionary = {}
	for node in scene.find_children("*","GeometryInstance3D",true,false):
		var materials: Array[Material] = []
		if node.material_override != null: materials.append(node.material_override)
		elif node is MeshInstance3D and node.mesh != null:
			for i in node.mesh.get_surface_count(): materials.append(node.get_active_material(i))
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			for i in node.multimesh.mesh.get_surface_count(): materials.append(node.multimesh.mesh.surface_get_material(i))
		for material in materials:
			if not material is ShaderMaterial or material.shader == null or seen.has(material.get_instance_id()): continue
			seen[material.get_instance_id()] = true
			var count: Variant = material.get_shader_parameter("source_lf_count")
			if count == null: continue
			saved.append({"material":material,"count":count,"sun":material.get_shader_parameter("source_lf_sun_enabled")})
	return saved

func diagnostic_unshaded() -> Array[Dictionary]:
	var saved: Array[Dictionary] = []
	var seen: Dictionary = {}
	var cache: Dictionary = {}
	for node in scene.find_children("*","GeometryInstance3D",true,false):
		var materials: Array[Material] = []
		if node.material_override != null: materials.append(node.material_override)
		elif node is MeshInstance3D and node.mesh != null:
			for i in node.mesh.get_surface_count(): materials.append(node.get_active_material(i))
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			for i in node.multimesh.mesh.get_surface_count(): materials.append(node.multimesh.mesh.surface_get_material(i))
		for material in materials:
			if not material is ShaderMaterial or material.shader == null or seen.has(material.get_instance_id()): continue
			seen[material.get_instance_id()] = true
			var original: Shader = material.shader
			var code: String = original.code
			var start := code.find("render_mode")
			if start < 0: check(false,"Cannot diagnose shader without render_mode"); continue
			var end := code.find(";",start)
			if "unshaded" in code.substr(start,end-start): continue
			var parameters: Dictionary = {}
			for uniform in original.get_shader_uniform_list(): parameters[uniform.name] = material.get_shader_parameter(uniform.name)
			var key := code.sha256_text()
			if not cache.has(key):
				var shader := Shader.new()
				shader.code = code.insert(end,", unshaded")
				cache[key] = shader
			material.shader = cache[key]
			for parameter in parameters: material.set_shader_parameter(parameter,parameters[parameter])
			saved.append({"material":material,"original":original,"installed":cache[key],"parameters":parameters})
	return saved

func save_distortion(label: String) -> void:
	await settle(10)
	var effect: CompositorEffect = scene.source_renderer.distortion
	var requested_frame := Engine.get_frames_drawn()
	for item in stage_effects: item.request(report.captures.size())
	effect.request_validation_capture()
	var data: Dictionary = {}
	var stages: Array[Dictionary] = [{},{},{}]
	for i in 90:
		await process_frame
		if data.is_empty(): data = effect.take_validation_capture()
		for j in stage_effects.size():
			if stages[j].is_empty(): stages[j] = stage_effects[j].take()
		if not data.is_empty() and stages.all(func(d): return not d.is_empty()): break
	check(not data.is_empty(),label+": missing distortion readback")
	check(stages.all(func(d): return not d.is_empty()),label+": missing upstream readback")
	if data.is_empty(): return
	if ("--drift-landscape-controls" in OS.get_cmdline_user_args() or "--drift-landscape-specular-controls" in OS.get_cmdline_user_args() or "--drift-landscape-cone-controls" in OS.get_cmdline_user_args() or "--drift-landscape-direct-controls" in OS.get_cmdline_user_args() or "--drift-landscape-local-input-controls" in OS.get_cmdline_user_args() or "--drift-landscape-raw-count-controls" in OS.get_cmdline_user_args()) and stages.all(func(d): return not d.is_empty()):
		for stage in stages:
			check(stage.get("token",-1)==report.captures.size(),label+": upstream token mismatch")
			check(stage.get("drawn_frame",-1)==stages[0].get("drawn_frame",-2),label+": upstream stages differ in drawn frame")
			check(stage.get("callback_serial",-1)==stages[0].get("callback_serial",-2),label+": upstream stages differ in callback serial")
	var folder := out.path_join(label)
	DirAccess.make_dir_recursive_absolute(folder)
	for j in stages.size():
		for key in stages[j].keys():
			if stages[j][key] is PackedByteArray:
				var filename: String = stage_names[j]+"-"+str(key)+".bin"
				FileAccess.open(folder.path_join(filename),FileAccess.WRITE).store_buffer(stages[j][key])
				stages[j][key] = {"file":filename}
	data["upstream"] = stages
	var hashes: Dictionary = {}
	for key in data.keys():
		if data[key] is PackedByteArray:
			var bytes: PackedByteArray = data[key]
			FileAccess.open(folder.path_join(str(key)+".bin"),FileAccess.WRITE).store_buffer(bytes)
			var context := HashingContext.new()
			context.start(HashingContext.HASH_SHA256)
			if not bytes.is_empty(): context.update(bytes)
			hashes[key] = context.finish().hex_encode()
			data[key] = {"file":str(key)+".bin","bytes":bytes.size(),"sha256":hashes[key]}
	data["label"] = label
	data["request_drawn_frame"] = requested_frame
	data["received_drawn_frame"] = Engine.get_frames_drawn()
	data["same_callback_triplet"] = true
	data["camera"] = str(scene.camera.global_transform)
	data["process_mode"] = scene.process_mode
	data["time_scale"] = Engine.time_scale
	FileAccess.open(folder.path_join("capture.json"),FileAccess.WRITE).store_string(JSON.stringify(data,"\t"))
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder.path_join("final.png"))
	report.captures.append({"label":label,"hashes":hashes})
	progress(label)

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	report = {"maps":[],"captures":[],"failures":[],"scope":"Youxian default frozen distortion stage localization; no production changes; final PNG is a later frame than the same-callback HDR triplet."}
	var control_count := 0
	for flag in ["--drift-lf-controls","--drift-unshaded-controls","--drift-shadow-controls","--drift-landscape-controls","--drift-landscape-specular-controls","--drift-landscape-cone-controls","--drift-landscape-direct-controls","--drift-landscape-local-input-controls","--drift-landscape-raw-count-controls"]:
		if flag in OS.get_cmdline_user_args(): control_count += 1
	if control_count>1:
		check(false,"Drift control modes are mutually exclusive")
		progress("rejected")
		quit(2)
		return
	if not configure_renderdoc_gate():
		progress("renderdoc gate rejected")
		quit(2)
		return
	root.size = Vector2i(960,540)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading: await process_frame
	scene.tour_finished = true
	progress("initial world loaded")
	await settle(40)
	progress("initial world settled")
	if scene.slug != "youxian": await scene._load_world("youxian")
	progress("youxian loaded")
	await settle(40)
	progress("youxian settled")
	var old_mode: int = scene.process_mode
	var old_time := Engine.time_scale
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	Engine.time_scale = 0.0
	synchronize_frozen_light_function()
	report.camera = str(scene.camera.global_transform)
	report.environment = {"msaa":root.msaa_3d,"taa":root.use_taa,"screen_aa":root.screen_space_aa}
	var original_compositor: Compositor = scene.camera.compositor
	for kind in [CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE,CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT,CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT]:
		var item: CompositorEffect = load(get_script().resource_path.get_base_dir().path_join("stage_readback.gd")).new()
		item.effect_callback_type = kind
		stage_effects.append(item)
	var diagnostic_compositor := Compositor.new()
	var effects: Array[CompositorEffect] = [stage_effects[0],stage_effects[1]]
	effects.append_array(original_compositor.compositor_effects)
	effects.append(stage_effects[2])
	diagnostic_compositor.compositor_effects = effects
	scene.camera.compositor = diagnostic_compositor
	if "--drift-landscape-controls" in OS.get_cmdline_user_args():
		await run_landscape_controls("unshaded")
	elif "--drift-landscape-specular-controls" in OS.get_cmdline_user_args():
		await run_landscape_controls("no-direct-specular")
	elif "--drift-landscape-cone-controls" in OS.get_cmdline_user_args():
		await run_landscape_controls("no-local-cone")
	elif "--drift-landscape-direct-controls" in OS.get_cmdline_user_args():
		await run_landscape_controls("direct-series")
	elif "--drift-landscape-local-input-controls" in OS.get_cmdline_user_args():
		await run_landscape_controls("local-input-series")
	elif "--drift-landscape-raw-count-controls" in OS.get_cmdline_user_args():
		await run_landscape_controls("raw-count")
	elif "--drift-lf-controls" in OS.get_cmdline_user_args():
		var materials := snapshot_light_function_uniforms()
		report.lf_materials = materials.size()
		for mode in ["original","sun-lf-off","all-lf-off","restored"]:
			for state in materials:
				state.material.set_shader_parameter("source_lf_count",0 if mode == "all-lf-off" else state.count)
				if state.sun != null: state.material.set_shader_parameter("source_lf_sun_enabled",false if mode == "sun-lf-off" else state.sun)
			await settle(20)
			for i in 4: await save_distortion(mode+"-%02d" % i)
		for state in materials:
			check(state.material.get_shader_parameter("source_lf_count") == state.count,"LightFunction count not restored")
			check(state.material.get_shader_parameter("source_lf_sun_enabled") == state.sun,"LightFunction sun flag not restored")
	elif "--drift-unshaded-controls" in OS.get_cmdline_user_args():
		for i in 4: await save_distortion("original-%02d" % i)
		var materials := diagnostic_unshaded()
		report.unshaded_materials = materials.size()
		await settle(20)
		for i in 4: await save_distortion("unshaded-%02d" % i)
		for state in materials:
			check(state.material.shader == state.installed,"Diagnostic shader ownership changed")
			state.material.shader = state.original
			for key in state.parameters: state.material.set_shader_parameter(key,state.parameters[key])
		await settle(20)
		for i in 4: await save_distortion("restored-%02d" % i)
	elif "--drift-shadow-controls" in OS.get_cmdline_user_args():
		var lights: Array[Dictionary] = []
		for node in scene.find_children("*","Light3D",true,false):
			lights.append({"node":node,"shadow":node.shadow_enabled,"energy":node.light_energy,"visible":node.visible})
		report.shadow_controls = []
		for mode in ["original","sun-shadow-off","local-shadow-off","all-shadow-off","restored"]:
			var active_shadows := 0
			for state in lights:
				state.node.shadow_enabled = state.shadow
				if mode == "all-shadow-off" or (mode == "sun-shadow-off" and state.node is DirectionalLight3D) or (mode == "local-shadow-off" and not state.node is DirectionalLight3D):
					state.node.shadow_enabled = false
				if state.node.shadow_enabled: active_shadows += 1
				report.shadow_controls.append({"mode":mode,"node":str(state.node.get_path()),"shadow":state.node.shadow_enabled,"energy":state.node.light_energy})
			await settle(20)
			for i in 4: await save_distortion(mode+"-%02d" % i)
		for state in lights:
			check(state.node.shadow_enabled == state.shadow and state.node.light_energy == state.energy and state.node.visible == state.visible,"Shadow control did not restore original light")
	else:
		for i in 4: await save_distortion("before-probe-%02d" % i)
		progress("sun probe snapshot")
		var folder := out.path_join("sun-snapshot")
		DirAccess.make_dir_recursive_absolute(folder)
		var bounds: Array[Dictionary] = preload("res://source_tlv_candidate/volume_bounds.gd").from_camera(scene.camera,16.0/9.0)
		var baked := await snapshot(bounds,folder)
		check(not baked.has("error"),"Sun snapshot failed: "+str(baked.get("error","")))
		baked.erase("textures")
		report.snapshot = baked
		for i in 8: await save_distortion("after-probe-%02d" % i)
	scene.camera.compositor = original_compositor
	diagnostic_compositor.compositor_effects = []
	effects.clear()
	stage_effects.clear()
	scene.process_mode = old_mode
	Engine.time_scale = old_time
	scene.queue_free()
	await settle(5)
	progress("complete")
	quit(0 if report.failures.is_empty() else 1)
