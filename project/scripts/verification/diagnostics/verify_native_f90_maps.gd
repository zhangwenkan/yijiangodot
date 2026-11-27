extends "res://scripts/verification/diagnostics/verify_tlv_drift.gd"
## Two normal Vulkan maps. Reuse existing loading, captures, state checks and shutdown.
## The legacy comparison temporarily removes only this map's landscape define.
const NATIVE_DEFINE := "#define SOURCE_LF_NATIVE_F90\n"
const INCLUDE_LINE := "#include \"res://shaders/original_lightfunction_receiving.gdshaderinc\""

func capture_f90(label: String) -> Image:
	await settle()
	var image := root.get_texture().get_image()
	if image==null or image.is_empty():
		check(false,label+": empty viewport image")
		return Image.new()
	if image.get_size()!=Vector2i(960,540):
		check(false,label+": unexpected viewport image size")
		return image
	var path := out.path_join(label+".png")
	var saved := image.save_png(path)
	check(saved==OK,label+": save_png returned "+str(saved))
	check(FileAccess.file_exists(path),label+": screenshot file missing")
	if saved==OK and FileAccess.file_exists(path):
		report.captures.append({"name":label,"path":path,"size":image.get_size(),"sha256":FileAccess.get_sha256(path),
			"camera":str(scene.camera.global_transform),"time_scale":Engine.time_scale})
	return image

func check_shutdown(value: Variant, path: String="shutdown") -> void:
	if value is Dictionary:
		if value.has("errors"):
			var errors: Variant = value["errors"]
			check(errors is Array and errors.is_empty(),path+": nonempty or invalid errors "+str(errors))
		check(str(value.get("status","")) not in ["failed","error"],path+": failure status")
		if value.has("error"): check(str(value["error"]).is_empty(),path+": "+str(value["error"]))
		for key in value: check_shutdown(value[key],path+"/"+str(key))
	elif value is Array:
		for index in value.size(): check_shutdown(value[index],path+"/"+str(index))

func verify_map_f90() -> Dictionary:
	var entry := {"map":scene.slug,"material_checks":[],"scope":"Landscape F90 source/restore validation; image differences are descriptive, not a frozen drift acceptance test."}
	var states := landscape_snapshot_materials()
	var targets: Array[int] = []
	var nonlandscape_count := 0
	for id in states:
		var material: Material = states[id].material
		if not material is ShaderMaterial or material.shader==null: continue
		if bool(material.get_meta("source_landscape_compiled",false)):
			targets.append(id)
		else:
			nonlandscape_count += 1
			check(not material.shader.code.contains(NATIVE_DEFINE),scene.slug+": nonlandscape contains new define: "+material.resource_name)
	entry.nonlandscape_shader_materials = nonlandscape_count
	check(targets.size()==1,scene.slug+": expected exactly one compiled landscape material")
	var owners: Array[Node] = []
	for node in scene.find_children("*","Node",true,false):
		var script: Script = node.get_script()
		if script!=null and script.resource_path=="res://scripts/original_lightfunctions.gd": owners.append(node)
	check(owners.size()==1,scene.slug+": expected one LF owner")
	var native_cached := 0
	if owners.size()==1:
		var cache: Dictionary = owners[0].get("_shaders")
		for key in cache:
			var shader: Shader = cache[key]
			var flagged := str(key).ends_with(":1")
			check(shader.code.contains(NATIVE_DEFINE)==flagged,scene.slug+": LF cache key and native define disagree")
			if flagged:
				native_cached += 1
				check(shader.code.count(NATIVE_DEFINE)==1 and shader.code.find(INCLUDE_LINE)>shader.code.find(NATIVE_DEFINE),scene.slug+": native define does not precede include")
		entry.lf_cache_entries = cache.size()
	entry.native_lf_cached_shaders = native_cached
	check(native_cached==1,scene.slug+": expected exactly one LF cache native shader")
	if targets.size()!=1: return entry
	var target_id: int = targets[0]
	var state: Dictionary = states[target_id]
	var target: ShaderMaterial = state.material
	var candidate: Shader = state.shader
	check(candidate.code.count(NATIVE_DEFINE)==1,scene.slug+": final landscape source lacks unique native define")
	check(state.parameters.size()==70,scene.slug+": expected 70 landscape uniforms")
	entry.landscape_material = target.resource_name
	entry.uniform_count = state.parameters.size()
	entry.candidate_shader_sha256 = candidate.code.sha256_text()
	var uniform_records: Dictionary = {}
	for key in state.parameters: uniform_records[key] = landscape_value_record(state.parameters[key])
	entry.uniforms_before = uniform_records
	FileAccess.open(out.path_join(scene.slug+"-native-f90-runtime.gdshader"),FileAccess.WRITE).store_string(candidate.code)
	var legacy := Shader.new()
	legacy.code = candidate.code.replace(NATIVE_DEFINE,"")
	entry.legacy_shader_sha256 = legacy.code.sha256_text()
	FileAccess.open(out.path_join(scene.slug+"-legacy-f90-runtime.gdshader"),FileAccess.WRITE).store_string(legacy.code)
	report.landscape_control = {"control_variant":"native-f90-legacy-comparison","state_checks":[],"installed_shader_sha256":legacy.code.sha256_text()}
	landscape_verify_materials(states,target_id,null,scene.slug+": candidate-before")
	var before := await capture_f90(scene.slug+"-f90-candidate")
	target.shader = legacy
	for key in state.parameters: target.set_shader_parameter(key,state.parameters[key])
	await settle(20)
	landscape_verify_materials(states,target_id,legacy,scene.slug+": legacy-temporary")
	var baseline := await capture_f90(scene.slug+"-f90-legacy")
	target.shader = candidate
	for key in state.parameters: target.set_shader_parameter(key,state.parameters[key])
	await settle(20)
	landscape_verify_materials(states,target_id,null,scene.slug+": candidate-restored")
	var restored := await capture_f90(scene.slug+"-f90-restored")
	landscape_verify_materials(states,target_id,null,scene.slug+": after-restored-capture")
	entry.material_checks = report.landscape_control.state_checks.duplicate(true)
	entry.legacy_vs_candidate = difference(baseline,before)
	entry.candidate_repeat = difference(before,restored)
	entry.uniforms_restored_exact = true
	for key in state.parameters:
		if target.get_shader_parameter(key)!=state.parameters[key]: entry.uniforms_restored_exact = false
	check(entry.uniforms_restored_exact,scene.slug+": landscape uniform restoration differs")
	return entry

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	report = {"maps":[],"captures":[],"failures":[],"scope":"Normal two-map landscape-only native F90 candidate. No RenderDoc, no raw-count controls, no drift-fix or UE pixel-parity claim."}
	root.size = Vector2i(960,540)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading: await process_frame
	scene.tour_finished = true
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		await settle(40)
		progress(slug+": loaded")
		var old_mode: int = scene.process_mode
		var old_time := Engine.time_scale
		scene.process_mode = Node.PROCESS_MODE_DISABLED
		Engine.time_scale = 0.0
		synchronize_frozen_light_function()
		var entry := await verify_map_f90()
		scene.process_mode = old_mode
		Engine.time_scale = old_time
		report.maps.append(entry)
		progress(slug+": verified and restored")
	# Existing source renderer owns its normal stack teardown.
	if is_instance_valid(scene.source_renderer):
		report.shutdown = scene.source_renderer.shutdown()
		check_shutdown(report.shutdown)
	else:
		check(false,"Source renderer missing at shutdown")
	scene.queue_free()
	await settle(5)
	report.erase("landscape_control")
	check(report.maps.size()==2,"Expected exactly two completed map records")
	var map_names: Array = []
	for entry in report.maps: map_names.append(entry.map)
	check(map_names==["wuming","youxian"],"Completed map order differs")
	var capture_names: Array = []
	for item in report.captures: capture_names.append(item.name)
	check(capture_names==["wuming-f90-candidate","wuming-f90-legacy","wuming-f90-restored",
		"youxian-f90-candidate","youxian-f90-legacy","youxian-f90-restored"],"Expected exactly six verified screenshots in map order")
	report.status = "passed" if report.failures.is_empty() else "failed"
	progress("complete")
	var summary := FileAccess.open(out.path_join("summary.json"),FileAccess.WRITE)
	if summary==null:
		check(false,"Cannot save final summary")
	else:
		summary.store_string(JSON.stringify(report,"\t"))
		check(summary.get_error()==OK,"Final summary write failed")
		summary.close()
	report.status = "passed" if report.failures.is_empty() else "failed"
	print("NATIVE_F90_MAPS_FINAL ",JSON.stringify({"status":report.status,"maps":report.maps.size(),"captures":report.captures.size(),"failures":report.failures}))
	quit(0 if report.failures.is_empty() else 1)
