extends SceneTree
var out := ""
var scene: Node3D
var report := {"maps":[],"failures":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--atmosphere-report-dir="): out=arg.trim_prefix("--atmosphere-report-dir=")
	call_deferred("run")

func shot(name: String) -> void:
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(scene.slug+"-"+name+".png"))

func run() -> void:
	scene=load("res://worlds.tscn").instantiate()
	scene.source_rendering=true
	scene.source_atmosphere=true
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		scene.player.set_review_motion(Vector2.ZERO)
		var renderer: Node=scene.source_renderer
		var atmosphere=renderer.atmosphere.effect
		for i in 30: await process_frame
		var entry := {"map":slug,"install":renderer.report.atmosphere,"effect":atmosphere.report}
		if atmosphere.report.status!="ready": report.failures.append(slug+": atmosphere not ready")
		Engine.time_scale=0.0
		atmosphere.enabled=false
		await shot("atmosphere-disabled")
		atmosphere.enabled=true
		await shot("atmosphere-enabled")
		entry["request"] = atmosphere.request_diagnostic(out.path_join(slug).path_join("diagnostic"),4)
		var deadline:=Time.get_ticks_msec()+20000
		while atmosphere.last_diagnostic.is_empty() and Time.get_ticks_msec()<deadline: await process_frame
		entry["diagnostic"]=atmosphere.last_diagnostic
		if not entry.diagnostic.get("complete",false): report.failures.append(slug+": diagnostic readback failed")
		Engine.time_scale=1.0
		renderer.sh.set_skylight_enabled(false)
		var capture=load("res://sky_capture_candidate/capture_source_sky.gd").new()
		capture.source_atmosphere_slug=slug
		root.add_child(capture)
		var result: Dictionary=await capture.capture(scene,scene.world,renderer._environment,out.path_join(slug).path_join("capture"),128,Vector3.ZERO)
		entry["sky_capture"]=result.report
		if not result.error.is_empty(): report.failures.append(slug+": "+result.error)
		renderer.sh.set_skylight_enabled(true)
		capture.queue_free()
		report.maps.append(entry)
	FileAccess.open(out.path_join("atmosphere-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_ATMOSPHERE_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.source_renderer.shutdown()
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
