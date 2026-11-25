extends SceneTree

func hash_bytes(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish().hex_encode()
## GPU/semantic entry point for the parent after source-waterfall installation.
## No geometry is created; only temporary camera/material audit settings change.
var scene: Node3D
var out := ""
var report := {"failures":[], "frames":[], "nodes":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--waterfall-report-dir="): out = arg.trim_prefix("--waterfall-report-dir=")
	call_deferred("run")

func settle(count: int = 12) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func _geometry_digest(node: MeshInstance3D) -> String:
	var digests: Array[String] = []
	for i in node.mesh.get_surface_count():
		var arrays: Array = node.mesh.surface_get_arrays(i)
		for value in arrays:
			if value != null: digests.append(hash_bytes(var_to_bytes(value)))
	return str(node.transform) + "|" + "|".join(digests)

func _capture(label: String) -> void:
	await settle()
	var image: Image = root.get_texture().get_image()
	image.save_png(out.path_join(label + ".png"))
	report.frames.append({"name":label,"width":image.get_width(),"height":image.get_height(),
		"sha256":hash_bytes(image.get_data()),"camera":str(scene.camera.global_transform)})

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	if scene.slug != "wuming": await scene._load_world("wuming")
	scene.tour_finished = true
	await settle(30)
	var adapter: Node
	for node in scene.world.find_children("*", "Node", true, false):
		var script: Script = node.get_script()
		if script != null and script.resource_path.ends_with("source_waterfall_adapter.gd"):
			adapter = node
			break
	if adapter == null:
		report.failures.append("Install source_waterfall_adapter in worlds before LF/source renderer.")
	else:
		report["install"] = adapter.report.duplicate(true)
		if adapter.report.get("bound_surfaces",0) != 2: report.failures.append("Expected two waterfall surfaces.")
		var nodes: Array[MeshInstance3D] = []
		var baseline: Dictionary = {}
		for node in scene.world.find_children("*", "MeshInstance3D", true, false):
			if not str(node.name).begins_with("S_7334_") and not str(node.name).begins_with("S_7335_"): continue
			nodes.append(node)
			baseline[str(node.name)] = _geometry_digest(node)
			var mat: Material = node.get_active_material(0)
			if not mat is ShaderMaterial or not bool(mat.get_meta("source_waterfall_compiled",false)):
				report.failures.append("Missing source material on "+str(node.name))
				continue
			var code: String = mat.shader.code
			report.nodes.append({"node":str(node.name),"vertices":node.mesh.surface_get_array_len(0),
				"indices":node.mesh.surface_get_array_index_len(0),"visible":node.is_visible_in_tree(),
				"light_function":code.contains("source_lf_at"),"cone":code.contains("source_local_cone_correction"),
				"source_sky":code.contains("source_sh9_evaluate"),"depth_fade":code.contains("ray_gap_cm"),
				"source_displacement":code.contains("displacement_power_cm"),
				"shader_sha256":code.sha256_text()})
		var old_process: int = scene.process_mode
		var old_time: float = Engine.time_scale
		var old_camera: Transform3D = scene.camera.global_transform
		scene.process_mode = Node.PROCESS_MODE_DISABLED
		Engine.time_scale = 0.0
		if not nodes.is_empty():
			# Keep original fixed orientation/FOV. Translate to inspect waterfall upper lip.
			var target := Vector3.ZERO
			for node in nodes: target += node.global_position
			target /= float(nodes.size())
			target.y -= 4.0
			scene.camera.global_position = target + scene.camera.global_basis.z * 35.0
			for t in [0.0,0.5,1.0,2.0]:
				adapter.set_audit_time(t)
				await _capture("waterfall-t"+str(t).replace(".","_"))
			adapter.set_audit_time(1.0)
			adapter.set_displacement_enabled(false)
			await _capture("waterfall-t1-no-displacement")
			adapter.set_displacement_enabled(true)
			for item in [{"label":"base-color","mode":1},{"label":"alpha","mode":2},{"label":"tangent-normal","mode":3},{"label":"foam","mode":4}]:
				adapter.set_audit_view(item.mode)
				await _capture("waterfall-audit-"+item.label)
			adapter.set_audit_view(0)
			adapter.set_audit_time(-1.0)
		for node in nodes:
			if baseline[str(node.name)] != _geometry_digest(node): report.failures.append("Geometry changed "+str(node.name))
		scene.camera.global_transform = old_camera
		scene.process_mode = old_process
		Engine.time_scale = old_time
	FileAccess.open(out.path_join("waterfall-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_WATERFALL_VALIDATION ",JSON.stringify({"failures":report.failures,"frames":report.frames.size()}))
	scene.queue_free()
	await settle(4)
	quit(0 if report.failures.is_empty() else 1)

