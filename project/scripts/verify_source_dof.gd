extends SceneTree
var out := ""
var scene: Node3D
var report := {"maps":[],"failures":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dof-report-dir="): out=arg.trim_prefix("--dof-report-dir=")
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition: report.failures.append(scene.slug+": "+label)

func shot(label: String) -> void:
	for i in 15: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(scene.slug+"-"+label+".png"))

func validate_dof(inside: bool) -> Dictionary:
	var adapter: Node=scene.source_renderer.depth_of_field
	var attributes: CameraAttributesPractical=scene.camera.attributes
	var focus:=14.7 if inside else 32.2
	check(adapter.report.inside==inside,"house DOF state")
	check(is_equal_approx(attributes.dof_blur_near_distance,focus),"near source focus")
	check(is_equal_approx(attributes.dof_blur_far_distance,focus),"far source focus")
	check(attributes.dof_blur_near_transition==-1.0 and attributes.dof_blur_far_transition==-1.0,"physical CoC branch")
	check(is_equal_approx(attributes.dof_blur_amount,adapter.report.infinity_coc_radius_px/64.0),"source CoC scale")
	scene.environment_driver.update_focus(Vector3(100,200,300))
	check(is_equal_approx(attributes.dof_blur_near_distance,focus),"source focus protected from old follow rule")
	return adapter.report.duplicate(true)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		check(scene.source_rendering and scene.source_distortion and scene.source_atmosphere,"source stack is default")
		await shot("source-outside")
		var entry:={"map":slug,"outside":validate_dof(false)}
		var center: Vector3=scene.house_driver._boxes[0].transform.origin
		check(scene.player.place_at_source_actor_position(center+Vector3(-3.65,0,0)),"doorway support")
		scene.camera.reset_at(scene.player.get_camera_anchor())
		scene.player.set_review_motion(Vector2.UP)
		for i in 150:
			await physics_frame
			if scene.house_driver.is_in_house: break
		scene.player.set_review_motion(Vector2.ZERO)
		await shot("source-inside")
		check(scene.house_driver.is_in_house,"walk entered house")
		entry["inside"]=validate_dof(true)
		scene.player.set_review_motion(Vector2.DOWN)
		for i in 150:
			await physics_frame
			if not scene.house_driver.is_in_house: break
		scene.player.set_review_motion(Vector2.ZERO)
		await shot("source-exit")
		check(not scene.house_driver.is_in_house,"walk exited house")
		entry["exit"]=validate_dof(false)
		var old_scale:=root.scaling_3d_scale
		root.scaling_3d_scale=.75
		for i in 8: await process_frame
		entry["resized"]=validate_dof(false)
		check(is_equal_approx(float(entry.resized.internal_width),roundf(float(entry.outside.internal_width)*.75)),"render-width change handled")
		check(is_equal_approx(float(entry.resized.infinity_coc_radius_px),float(entry.outside.infinity_coc_radius_px)*.75),"CoC follows internal resolution")
		root.scaling_3d_scale=old_scale
		for i in 8: await process_frame
		report.maps.append(entry)
	var previous: CameraAttributes=scene.source_renderer.depth_of_field._previous
	scene.source_renderer.shutdown()
	check(scene.camera.attributes==previous,"shutdown restores camera attributes")
	check(not scene.camera.has_meta("source_dof_owner"),"shutdown removes DOF owner")
	FileAccess.open(out.path_join("dof-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_DOF_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
