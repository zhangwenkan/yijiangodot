extends "res://scripts/verification/verify_source_tlv_receiver.gd"
## Read-only scene diagnostic. Each distortion triplet is captured in one callback.
var stage_effects: Array[CompositorEffect] = []
var stage_names := ["post-opaque","before-atmosphere","after-atmosphere"]

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
	if "--drift-lf-controls" in OS.get_cmdline_user_args():
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
