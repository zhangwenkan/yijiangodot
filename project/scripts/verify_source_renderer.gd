extends SceneTree
var out := ""
var scene: Node3D
var report := {"maps":[], "failures":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--renderer-report-dir="): out = arg.trim_prefix("--renderer-report-dir=")
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition: report.failures.append(scene.slug+": "+label)

func state() -> Dictionary:
	var renderer: Node = scene.source_renderer
	return {"inside":scene.house_driver.is_in_house,"film":renderer.film._inside,
		"bloom":renderer.bloom._inside,"sky":renderer.sh.report.skylight_enabled,
		"sun":renderer._sun.light_energy,"feet":scene.player.position}

func shot(label: String) -> void:
	for i in 20: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(scene.slug+"-"+label+".png"))

func run() -> void:
	scene = load("res://worlds.tscn").instantiate()
	scene.source_rendering = true
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian","wuming"]:
		if scene.slug != slug: await scene._load_world(slug)
		scene.tour_finished = true
		var renderer: Node = scene.source_renderer
		check(renderer != null and renderer.report.status == "installed", "integrated renderer installed")
		var entry := {"map":slug,"renderer":renderer.report,"states":[]}
		await shot("integrated-port")
		entry.states.append(state())
		check(renderer.report.local_cones.unsupported.is_empty(),"source cone bindings supported")
		check(renderer.report.height_fog.unsupported.is_empty(),"source height fog bindings supported")
		check(renderer.report.local_lights.applied.size() == (18 if slug=="wuming" else 31),"all source local lights")
		check(renderer.report.local_cones.bound > 0,"source cone materials")
		var center: Vector3 = scene.house_driver._boxes[0].transform.origin
		scene.house_driver.reset_outdoors()
		check(scene.player.place_at_source_actor_position(center+Vector3(-3.65,0,0)),"supported doorway")
		scene.camera.reset_at(scene.player.get_camera_anchor())
		scene.player.set_review_motion(Vector2.UP)
		for i in 150:
			await physics_frame
			if scene.house_driver.is_in_house: break
		check(scene.house_driver.is_in_house,"walk entered house")
		for i in 12: await physics_frame
		scene.player.set_review_motion(Vector2.ZERO)
		await shot("integrated-inside")
		entry.states.append(state())
		check(renderer.film._inside and renderer.bloom._inside and not renderer.sh.report.skylight_enabled,"indoor renderer synchronized")
		check(is_equal_approx(renderer._sun.light_energy,3.0/PI),"indoor source sun")
		scene.player.set_review_motion(Vector2.DOWN)
		for i in 150:
			await physics_frame
			if not scene.house_driver.is_in_house: break
		scene.player.set_review_motion(Vector2.ZERO)
		await shot("integrated-exit")
		entry.states.append(state())
		check(not scene.house_driver.is_in_house and not renderer.film._inside and renderer.sh.report.skylight_enabled,"walk exited and renderer restored")
		check(is_equal_approx(renderer._sun.light_energy,30.0/PI),"outdoor source sun")
		report.maps.append(entry)
	FileAccess.open(out.path_join("source-renderer.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_RENDERER_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.source_renderer.shutdown()
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
