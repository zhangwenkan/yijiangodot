extends SceneTree
var out := ""
var scene: Node3D
var report := {"failures":[], "samples":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--distortion-report-dir="): out=arg.trim_prefix("--distortion-report-dir=")
	call_deferred("run")

func shot(name: String) -> Image:
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image()
	result.save_png(out.path_join(name+".png"))
	return result

func run() -> void:
	scene=load("res://worlds.tscn").instantiate()
	scene.source_rendering=true
	scene.source_distortion=true
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	scene.tour_finished=true
	scene.set_process(false)
	scene.player.set_physics_process(false)
	scene.house_driver.set_physics_process(false)
	scene.camera.follow_target=null
	scene.camera.source_bounds.clear()
	scene.camera.attributes.dof_blur_near_enabled=false
	scene.camera.attributes.dof_blur_far_enabled=false
	var driver: Node
	for node in scene.world.get_children():
		if node.get_script()!=null and node.get_script().resource_path.ends_with("/original_particles.gd"): driver=node
	var splash
	for emitter in driver._emitters:
		if emitter.splash:
			splash=emitter
			break
	assert(splash != null)
	scene.camera.reset_at(splash.transform.origin+Vector3(0,.6,0))
	scene.camera.zoom=.35
	scene.camera._apply_pose()
	for i in 180: await process_frame
	driver.set_process(false)
	Engine.time_scale=0.0
	var renderer: Node=scene.source_renderer
	var effect: CompositorEffect=renderer.distortion
	report["binding"]=renderer.splash_binding.audit.duplicate(true)
	if report.binding.source_emitters != 9: report.failures.append("Expected9 splash emitters")
	if not report.binding.mesh_copied: report.failures.append("Source draw mesh was not copied")
	if report.binding.active_particles <= 0: report.failures.append("No active source particles")
	effect.enabled=false
	await shot("splash-disabled")
	effect.enabled=true
	await shot("splash-enabled")
	if effect.has_method("request_validation_capture"):
		effect.request_validation_capture()
		for i in 20: await process_frame
		var readback: Dictionary=effect.take_validation_capture()
		report["readback"]={}
		for key in readback:
			if readback[key] is PackedByteArray:
				FileAccess.open(out.path_join(key+".bin"),FileAccess.WRITE).store_buffer(readback[key])
				report.readback[key]=readback[key].size()
			else: report.readback[key]=readback[key]
		if readback.is_empty(): report.failures.append("Requested RD readback not returned")
	renderer.bloom.enabled=false
	renderer.film.enabled=false
	effect.set_audit_mode(1)
	await shot("splash-accumulation")
	effect.set_audit_mode(0)
	renderer.bloom.enabled=true
	renderer.film.enabled=true
	Engine.time_scale=1.0
	driver.set_process(true)
	for i in 24:
		for j in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join("motion-%03d.png"%i))
		report.samples.append(renderer.splash_binding.audit.duplicate(true))
	scene.house_driver.set_physics_process(true)
	scene.set_process(true)
	await scene._load_world("youxian")
	scene.tour_finished=true
	for i in 30: await process_frame
	report["youxian_binding"]=scene.source_renderer.splash_binding.audit.duplicate(true)
	if report.youxian_binding.source_emitters !=0: report.failures.append("Youxian has no source splash emitters")
	await shot("youxian-no-splash")
	FileAccess.open(out.path_join("distortion-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_DISTORTION_VERIFIED ",JSON.stringify(report))
	scene.source_renderer.shutdown()
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
