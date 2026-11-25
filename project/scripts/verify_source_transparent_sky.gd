extends SceneTree
## GPU verifier owned/run by the parent task. No geometry creation.
var scene: Node3D
var out := ""
var extra_views := false
var report := {"maps":[],"failures":[],"scope":"Frozen source sky diffuse contribution; not native TLV or complete map fidelity."}

func _set_direct_lights(saved_lights: Array, muted: bool) -> void:
	for state: Dictionary in saved_lights:
		if is_instance_valid(state.light): state.light.light_energy = 0.0 if muted else state.energy

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--transparent-sky-report-dir="): out = arg.trim_prefix("--transparent-sky-report-dir=")
		if arg == "--transparent-sky-extra-views": extra_views = true
	call_deferred("run")

func settle(count: int = 10) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func _uniform_state(adapter: Node) -> Array:
	var rows: Array = []
	var saved: Array = adapter.get("_saved")
	for state: Dictionary in saved:
		var material: ShaderMaterial = state.material
		var mismatches: Array[String] = []
		for key in state.parameters:
			if material.get_shader_parameter(key) != state.parameters[key]: mismatches.append(key)
		rows.append({"family":state.family,"material":material.resource_name,
			"enabled":material.get_shader_parameter("source_sh9_enabled"),
			"mode":material.get_shader_parameter("source_transparent_sky_mode"),
			"coefficient_count":material.get_shader_parameter("source_sh9_coefficients").size(),
			"gain":material.get_shader_parameter("source_sh9_linear_gain"),
			"original_parameter_mismatches":mismatches})
	return rows

func _image_difference(a: Image, b: Image) -> Dictionary:
	if a.get_size() != b.get_size(): return {"error":"Image size changed."}
	var av := a.get_data()
	var bv := b.get_data()
	var maximum := 0
	var sum_absolute := 0.0
	var changed := 0
	for index in av.size():
		var delta := absi(int(av[index])-int(bv[index]))
		maximum = maxi(maximum,delta)
		sum_absolute += delta
		if delta > 0: changed += 1
	return {"max_channel_delta":maximum,"mean_channel_delta":sum_absolute/float(av.size()),"changed_channels":changed,"scope":"Whole image bytes; not water ROI."}

func _camera_views(adapter: Node) -> Array:
	var views: Array = [{"name":"default","transform":scene.camera.global_transform}]
	if not extra_views: return views
	for family in ["Smoke1","Splash"]:
		for item: Dictionary in adapter.report.materials:
			if item.family != family: continue
			var node: Node = root.get_node_or_null(NodePath(item.first_node))
			if not node is MultiMeshInstance3D or node.multimesh == null or node.multimesh.instance_count == 0: continue
			var draw_count: int = node.multimesh.visible_instance_count
			if draw_count == 0: continue
			var anchor: Vector3 = node.global_transform * node.multimesh.get_instance_transform(0).origin
			var camera_transform: Transform3D = scene.camera.global_transform
			# Keep the anchor on the original 32.2m focal plane; the earlier12m
			# diagnostic was out of focus and cannot validate sprite detail.
			camera_transform.origin = anchor + camera_transform.basis.z.normalized()*32.2
			views.append({"name":family.to_lower(),"transform":camera_transform,"anchor":anchor,"source_node":item.first_node,"camera_distance_m":32.2,"dof_policy":"original source DOF retained; anchor at source focal plane"})
			break
	return views

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280,720)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug != slug: await scene._load_world(slug)
		scene.tour_finished = true
		await settle(30)
		# If already integrated, remove only this topmost adapter before diagnostics.
		var current: Variant = scene.source_renderer.get("transparent_sky")
		var prior_restore: Dictionary = {}
		if current is Node and is_instance_valid(current): prior_restore = current.restore()
		var old_process: int = scene.process_mode
		var old_time: float = Engine.time_scale
		var old_camera: Transform3D = scene.camera.global_transform
		scene.process_mode = Node.PROCESS_MODE_DISABLED
		Engine.time_scale = 0.0
		await settle()
		var before: Image = root.get_texture().get_image()
		before.save_png(out.path_join(slug+"-default-preinstall.png"))
		await settle()
		var before_repeat: Image = root.get_texture().get_image()
		before_repeat.save_png(out.path_join(slug+"-default-preinstall-repeat.png"))
		var adapter: Node = load("res://source_transparent_sky_candidate/source_transparent_sky_adapter.gd").new()
		scene.source_renderer.add_child(adapter)
		var entry := {"map":slug,"prior_owner_restore":prior_restore,"views":[]}
		entry["preinstall_repeat"] = _image_difference(before,before_repeat)
		entry["install"] = adapter.install(scene,"res://sh9_candidate/"+slug+"-source-sh9.json",{})
		entry["house_attachment"] = adapter.attach_house_driver(scene.house_driver)
		var expected := {"Ocean":1,"Water":1,"Smoke1":11 if slug=="wuming" else 0,"SmokeSubUV":5 if slug=="wuming" else 0,"Splash":9 if slug=="wuming" else 0}
		entry["expected_material_counts"] = expected
		for family in expected:
			if int(adapter.report.family_counts.get(family,0)) != expected[family]: report.failures.append(slug+": binding count for "+family)
		if not adapter.report.unsupported.is_empty(): report.failures.append(slug+": unsupported material")
		for material: Dictionary in adapter.report.materials:
			if not material.vertex_preserved or not material.fragment_preserved_as_prefix or not material.light_body_preserved:
				report.failures.append(slug+": original code changed for "+material.family)
		entry["installed_uniforms"] = _uniform_state(adapter)
		for item: Dictionary in entry.installed_uniforms:
			if item.coefficient_count != 9 or not item.original_parameter_mismatches.is_empty(): report.failures.append(slug+": original parameters changed")
		adapter.set_skylight_enabled(false)
		entry["indoor_switch_uniforms"] = _uniform_state(adapter)
		for item: Dictionary in entry.indoor_switch_uniforms:
			if item.enabled != false: report.failures.append(slug+": sky-off uniform not propagated")
		adapter.set_skylight_enabled(true)
		var lights: Array = []
		for light in scene.world.find_children("*","Light3D",true,false): lights.append({"light":light,"energy":light.light_energy})
		entry["sky_only_scope"] = "Scene direct Light3D energy temporarily zero; emission/reflection disabled only on bound transparent families. Other scene materials/fog remain."
		var baseline: Image
		for view: Dictionary in _camera_views(adapter):
			scene.camera.global_transform = view.transform
			var view_report := {"name":view.name,"camera":view.transform,"variants":[]}
			for variant in [{"label":"baseline","mode":0},{"label":"source-sky","mode":1},{"label":"source-sky-only","mode":2},{"label":"sky-off","mode":3},{"label":"baseline-sky-only","mode":4}]:
				_set_direct_lights(lights,variant.mode==2 or variant.mode==4)
				adapter.set_mode(variant.mode)
				await settle()
				var captured: Image = root.get_texture().get_image()
				captured.save_png(out.path_join(slug+"-"+view.name+"-"+variant.label+".png"))
				if view.name == "default" and variant.mode == 0:
					baseline = captured
					entry["preinstall_vs_baseline"] = _image_difference(before,captured)
				view_report.variants.append(variant)
			entry.views.append(view_report)
		_set_direct_lights(lights,false)
		entry["restore"] = adapter.restore()
		if not entry.restore.errors.is_empty(): report.failures.append(slug+": restore failed")
		scene.camera.global_transform = old_camera
		await settle()
		var restored: Image = root.get_texture().get_image()
		restored.save_png(out.path_join(slug+"-default-restored.png"))
		entry["baseline_vs_restore"] = _image_difference(baseline,restored)
		entry["preinstall_vs_restore"] = _image_difference(before,restored)
		await settle()
		var restored_repeat: Image = root.get_texture().get_image()
		restored_repeat.save_png(out.path_join(slug+"-default-restored-repeat.png"))
		entry["restore_repeat"] = _image_difference(restored,restored_repeat)
		if int(entry.preinstall_vs_baseline.get("max_channel_delta",255)) > 0: report.failures.append(slug+": baseline mode differs from preinstall")
		if int(entry.baseline_vs_restore.get("max_channel_delta",255)) > 0: report.failures.append(slug+": restored image differs from frozen baseline")
		if int(entry.preinstall_repeat.get("max_channel_delta",255)) > 0: report.failures.append(slug+": preinstall repeat is unstable")
		if int(entry.preinstall_vs_restore.get("max_channel_delta",255)) > 0: report.failures.append(slug+": preinstall vs restore differs")
		if int(entry.restore_repeat.get("max_channel_delta",255)) > 0: report.failures.append(slug+": restore repeat is unstable")
		scene.process_mode = old_process
		Engine.time_scale = old_time
		adapter.queue_free()
		report.maps.append(entry)
	FileAccess.open(out.path_join("transparent-sky-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_TRANSPARENT_SKY_VALIDATED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	await settle(5)
	quit(0 if report.failures.is_empty() else 1)
