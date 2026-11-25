extends SceneTree
## Parent-owned GPU verification. No new geometry, no native-original fidelity claim.
var out := ""
var scene: Node3D
var report := {"maps":[],"failures":[],"scope":"Global reflection source replacement; current SH9 material state preserved."}
var _material_states: Array[Dictionary] = []
var _seen: Dictionary = {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--reflection-report-dir="): out = arg.trim_prefix("--reflection-report-dir=")
	call_deferred("run")

func settle(count: int = 24) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func _remember_material(material: Material) -> void:
	if material == null or _seen.has(material.get_instance_id()): return
	_seen[material.get_instance_id()] = true
	_remember_material(material.next_pass)
	if not material is ShaderMaterial or material.shader == null: return
	var parameters: Dictionary = {}
	for item: Dictionary in material.shader.get_shader_uniform_list():
		parameters[item.name] = material.get_shader_parameter(item.name)
	_material_states.append({"material":material,"shader":material.shader,"parameters":parameters})

func _remember_scene(node: Node) -> void:
	if node is GeometryInstance3D:
		_remember_material(node.material_override)
		_remember_material(node.material_overlay)
		if node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count(): _remember_material(node.get_active_material(surface))
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			for surface in node.multimesh.mesh.get_surface_count(): _remember_material(node.multimesh.mesh.surface_get_material(surface))
	for child in node.get_children(): _remember_scene(child)

func _check_materials() -> Dictionary:
	var errors: Array[String] = []
	var sh_count := 0
	for state: Dictionary in _material_states:
		if not is_instance_valid(state.material): errors.append("Material disappeared."); continue
		if state.material.shader != state.shader: errors.append("Material shader changed: "+state.material.resource_name)
		for parameter in state.parameters:
			if state.material.get_shader_parameter(parameter) != state.parameters[parameter]: errors.append("Material parameter changed: "+str(parameter))
		if state.parameters.has("source_sh9_coefficients"): sh_count += 1
	return {"shader_materials":_material_states.size(),"sh9_materials":sh_count,"errors":errors}

func _difference(a: Image, b: Image) -> Dictionary:
	if a.get_size() != b.get_size(): return {"error":"Image size changed."}
	var av := a.get_data()
	var bv := b.get_data()
	var maximum := 0
	var total := 0.0
	var changed := 0
	for i in av.size():
		var difference := absi(int(av[i])-int(bv[i]))
		maximum = maxi(maximum,difference)
		total += difference
		if difference > 0: changed += 1
	return {"max_channel_delta":maximum,"mean_channel_delta":total/float(av.size()),"changed_channels":changed,"scope":"whole image bytes; not water-only ROI"}

func _views() -> Array:
	# The second camera moves only its origin: same viewing basis, no role movement.
	# It provides a fixed close water view without inventing navigation or geometry.
	var result: Array = [{"name":"default","transform":scene.camera.global_transform}]
	var waters: Array[Node] = scene.world.find_children("*", "MeshInstance3D",true,false)
	for node: Node in waters:
		if node.mesh == null: continue
		var is_water := false
		for surface in node.mesh.get_surface_count():
			var material: Material = node.get_active_material(surface)
			if material is ShaderMaterial and material.shader != null and material.shader.code.contains("waves_2_normal") and material.shader.code.contains("source_metallic"):
				is_water = true
		if not is_water: continue
		var bounds: AABB = node.get_aabb()
		var anchor: Vector3 = node.global_transform * bounds.get_center()
		var transform: Transform3D = scene.camera.global_transform
		transform.origin = anchor + transform.basis.z.normalized()*35.0
		result.append({"name":"water-center","transform":transform,"anchor":anchor,"water_node":str(node.get_path())})
		break
	return result

func run() -> void:
	if out.is_empty(): quit(2); return
	root.size = Vector2i(1280,720)
	DirAccess.make_dir_recursive_absolute(out)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug != slug: await scene._load_world(slug)
		scene.tour_finished = true
		scene.house_driver.reset_outdoors()
		await settle(30)
		var prefreeze: Image = root.get_texture().get_image()
		prefreeze.save_png(out.path_join(slug+"-default-prefreeze.png"))
		var old_time := Engine.time_scale
		var old_process: int = scene.process_mode
		var old_camera: Transform3D = scene.camera.global_transform
		scene.process_mode = Node.PROCESS_MODE_DISABLED
		Engine.time_scale = 0.0
		_material_states.clear()
		_seen.clear()
		_remember_scene(scene)
		await settle()
		var frozen_unwarmed: Image = root.get_texture().get_image()
		frozen_unwarmed.save_png(out.path_join(slug+"-default-frozen-before-probe-warmup.png"))
		# Visibility unpairs/re-adds a Godot probe, marking it dirty and forcing a
		# capture. Warm it at the frozen time before all comparison baselines.
		var warm_probes: Array[Dictionary] = []
		for probe: Node in scene.find_children("*", "ReflectionProbe", true, false):
			if str(probe.name) == "OriginalSceneReflection_Adapted" and probe.has_meta("source_skylight"):
				warm_probes.append({"probe":probe,"visible":probe.visible})
				probe.visible = false
		await settle(8)
		for state: Dictionary in warm_probes: state.probe.visible = state.visible
		await settle(72)
		var preinstall: Image = root.get_texture().get_image()
		preinstall.save_png(out.path_join(slug+"-default-preinstall.png"))
		await settle(24)
		var preinstall_repeat: Image = root.get_texture().get_image()
		preinstall_repeat.save_png(out.path_join(slug+"-default-preinstall-repeat.png"))
		var adapter: Node = load("res://source_reflection_candidate/source_reflection_adapter.gd").new()
		scene.source_renderer.add_child(adapter)
		var entry := {"map":slug,"views":[],"probe_warmup_count":warm_probes.size(),
			"prefreeze_to_frozen_unwarmed":_difference(prefreeze,frozen_unwarmed),
			"frozen_unwarmed_to_warmed":_difference(frozen_unwarmed,preinstall),
			"preinstall_repeat":_difference(preinstall,preinstall_repeat)}
		if entry.preinstall_repeat.get("max_channel_delta",255) != 0: report.failures.append(slug+": warmed baseline is not stable")
		entry["install"] = adapter.install(scene,scene.source_renderer._environment,
			"res://source_reflection_candidate/"+slug+"-source-scene-capture.res","res://sh9_candidate/"+slug+"-source-sh9.json")
		if entry.install.has("error"):
			report.failures.append(slug+": "+str(entry.install.error))
			report.maps.append(entry)
			scene.process_mode = old_process
			Engine.time_scale = old_time
			adapter.queue_free()
			continue
		entry["house_attachment"] = adapter.attach_house_driver(scene.house_driver)
		var baseline: Image
		for view: Dictionary in _views():
			scene.camera.global_transform = view.transform
			var variants: Dictionary = {}
			for variant in [{"name":"baseline","mode":0},{"name":"probe-off","mode":1},{"name":"captured-reflection","mode":2}]:
				adapter.set_mode(variant.mode)
				await settle(48)
				var captured: Image = root.get_texture().get_image()
				captured.save_png(out.path_join(slug+"-"+view.name+"-"+variant.name+".png"))
				variants[variant.name] = captured
				if view.name == "default" and variant.mode == 0: baseline = captured
			var view_result := {"name":view.name,"camera":view.transform,
				"baseline_to_probe_off":_difference(variants.baseline,variants["probe-off"]),
				"probe_off_to_source_capture":_difference(variants["probe-off"],variants["captured-reflection"]),
				"baseline_to_source_capture":_difference(variants.baseline,variants["captured-reflection"])}
			entry.views.append(view_result)
		entry["materials_after_variants"] = _check_materials()
		if not entry.materials_after_variants.errors.is_empty(): report.failures.append(slug+": source material or SH state changed")
		adapter._on_house_state(true)
		entry["indoor_reflection_disabled"] = scene.source_renderer._environment.reflected_light_source == Environment.REFLECTION_SOURCE_DISABLED
		adapter._on_house_state(false)
		if not entry.indoor_reflection_disabled: report.failures.append(slug+": indoor reflection did not disable")
		entry["restore"] = adapter.restore()
		if not entry.restore.errors.is_empty(): report.failures.append(slug+": restore failed")
		scene.camera.global_transform = old_camera
		await settle(48)
		var restored: Image = root.get_texture().get_image()
		restored.save_png(out.path_join(slug+"-default-restored.png"))
		await settle(24)
		var restored_repeat: Image = root.get_texture().get_image()
		restored_repeat.save_png(out.path_join(slug+"-default-restored-repeat.png"))
		entry["preinstall_to_baseline"] = _difference(preinstall,baseline)
		entry["baseline_to_restore"] = _difference(baseline,restored)
		entry["preinstall_to_restore"] = _difference(preinstall,restored)
		entry["restore_repeat"] = _difference(restored,restored_repeat)
		entry["materials_after_restore"] = _check_materials()
		if not entry.materials_after_restore.errors.is_empty(): report.failures.append(slug+": material state changed after restore")
		if entry.preinstall_to_baseline.get("max_channel_delta",255) != 0: report.failures.append(slug+": baseline mode differs from preinstall")
		if entry.baseline_to_restore.get("max_channel_delta",255) != 0: report.failures.append(slug+": frozen restore image mismatch")
		if entry.preinstall_to_restore.get("max_channel_delta",255) != 0: report.failures.append(slug+": preinstall vs restore image mismatch")
		if entry.restore_repeat.get("max_channel_delta",255) != 0: report.failures.append(slug+": restored image is not stable")
		scene.process_mode = old_process
		Engine.time_scale = old_time
		adapter.queue_free()
		report.maps.append(entry)
	_material_states.clear()
	_seen.clear()
	FileAccess.open(out.path_join("reflection-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_REFLECTION_VALIDATED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	await settle(5)
	quit(0 if report.failures.is_empty() else 1)
