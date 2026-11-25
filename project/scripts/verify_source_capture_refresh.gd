extends SceneTree
## Rebuild captures from the current full renderer; no geometry changes.
## Repeat frozen raw faces and verify exact material/process restoration.
## An additional live-scene capture verifies an actual time_scale 1 -> 0 -> 1.
var out := ""
var scene: Node3D
var report := {"maps":[],"failures":[]}

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-refresh-out="): out=argument.trim_prefix("--capture-refresh-out=")
	call_deferred("run")

func settle(count: int=16) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func pixel_difference(a: Image,b: Image) -> Dictionary:
	if a.get_size()!=b.get_size(): return {"error":"Image size changed"}
	var av:=a.get_data()
	var bv:=b.get_data()
	var changed:=0
	var maximum:=0
	for i in av.size():
		var d:=absi(int(av[i])-int(bv[i]))
		if d>0: changed+=1
		maximum=maxi(maximum,d)
	return {"changed_channels":changed,"max_channel_delta":maximum}

func save() -> void:
	FileAccess.open(out.path_join("capture-refresh-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))

func check_capture(slug: String, result: Dictionary, expected_time: float, context: String) -> void:
	var label := slug+" "+context
	var capture_report: Dictionary = result.get("report",{})
	if not str(result.get("error","Missing capture result")).is_empty(): report.failures.append(label+": capture failed "+str(result.get("error","Missing capture result")))
	if not capture_report.get("restored_scene_state",false): report.failures.append(label+": material/property/process restoration failed")
	if not capture_report.get("time_scale_restored",false): report.failures.append(label+": time state restoration failed")
	if float(capture_report.get("time_scale_before_capture",-1.0))!=expected_time or float(capture_report.get("time_scale_during_capture",-1.0))!=0.0 or float(capture_report.get("time_scale_before_restore",-1.0))!=0.0 or float(capture_report.get("time_scale_after_capture",-1.0))!=expected_time or Engine.time_scale!=expected_time:
		report.failures.append(label+": time scale did not follow expected pause/restore sequence")
	if int(capture_report.get("sky_feedback_overrides",0))<1: report.failures.append(label+": no sky feedback overrides")
	var sh9_overrides := int(capture_report.get("sh9_feedback_overrides",0))
	var sh9_emission_overrides := int(capture_report.get("sh9_emission_feedback_overrides",0))
	if sh9_overrides<1: report.failures.append(label+": no SH feedback producer disabled")
	if sh9_emission_overrides!=(1 if slug=="youxian" else 0): report.failures.append(label+": unexpected leaf SH emission override count")
	if not capture_report.get("sh9_feedback_disable_errors",[]).is_empty(): report.failures.append(label+": SH feedback disable failed")
	if int(capture_report.get("restored_sh9_feedback_overrides",-1))!=sh9_overrides: report.failures.append(label+": SH feedback switch restoration incomplete")
	if int(capture_report.get("restored_sh9_emission_feedback_overrides",-1))!=sh9_emission_overrides: report.failures.append(label+": leaf SH emission switch restoration incomplete")
	if not capture_report.get("roughness_unhandled",[]).is_empty(): report.failures.append(label+": unhandled capture material")

func run() -> void:
	if out.is_empty(): quit(2); return
	root.size=Vector2i(1280,720)
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug: String in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		scene.player.set_review_motion(Vector2.ZERO)
		scene.house_driver.reset_outdoors()
		await settle(40)
		var old_time:=Engine.time_scale
		var old_process: int=scene.process_mode
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		await settle(48)
		var before:=root.get_texture().get_image()
		before.save_png(out.path_join(slug+"-before.png"))
		await settle()
		var baseline_repeat:=root.get_texture().get_image()
		var entry: Dictionary={"map":slug,"captures":[],"baseline_repeat":pixel_difference(before,baseline_repeat),
			"controller_time_scale_before_freeze":old_time,"controller_time_scale_during_freeze":Engine.time_scale,
			"controller_process_mode_before_freeze":old_process}
		for repeat in 2:
			var capture: Node=load("res://sky_capture_candidate/capture_source_sky.gd").new()
			capture.source_atmosphere_slug=slug
			root.add_child(capture)
			var folder:=out.path_join(slug).path_join("capture-"+str(repeat))
			var result: Dictionary=await capture.capture(scene,scene.world,scene.source_renderer._environment,folder,128,Vector3.ZERO)
			entry.captures.append(result.get("report",{}))
			check_capture(slug,result,0.0,"frozen-"+str(repeat))
			capture.queue_free()
			await settle(32)
		entry["raw_repeat"]={}
		for face: String in ["px","nx","py","ny","pz","nz"]:
			var basename: String="face_"+face+"_raw.rgba16f"
			var a: String=FileAccess.get_sha256(out.path_join(slug).path_join("capture-0").path_join(basename))
			var b: String=FileAccess.get_sha256(out.path_join(slug).path_join("capture-1").path_join(basename))
			entry.raw_repeat[face]={"first_sha256":a,"second_sha256":b,"same":a==b and not a.is_empty()}
			if a!=b or a.is_empty(): report.failures.append(slug+": frozen raw face differs "+face)
		var after:=root.get_texture().get_image()
		after.save_png(out.path_join(slug+"-after.png"))
		entry["before_after"]=pixel_difference(before,after)
		if entry.baseline_repeat.get("changed_channels",-1)!=0: report.failures.append(slug+": baseline image unstable")
		if entry.before_after.get("changed_channels",-1)!=0: report.failures.append(slug+": capture changed frozen main image")
		scene.process_mode=old_process
		Engine.time_scale=old_time
		entry["controller_time_scale_after_restore"]=Engine.time_scale
		entry["controller_process_mode_after_restore"]=scene.process_mode
		entry["controller_state_restored"]=Engine.time_scale==old_time and scene.process_mode==old_process
		if not entry.controller_state_restored: report.failures.append(slug+": verifier outer freeze did not restore")
		if slug=="wuming":
			# The exact image/raw comparisons above finish before normal time resumes.
			# This third capture exercises production pause/restore with scene processing active.
			var live_old_time := Engine.time_scale
			Engine.time_scale=1.0
			await settle(16)
			var live_processing_before := {"can_process":scene.can_process(),"process":scene.is_processing(),"physics_process":scene.is_physics_processing()}
			if not live_processing_before.can_process: report.failures.append(slug+": live capture started while scene processing was disabled")
			var live_capture: Node=load("res://sky_capture_candidate/capture_source_sky.gd").new()
			live_capture.source_atmosphere_slug=slug
			root.add_child(live_capture)
			var live_folder:=out.path_join(slug).path_join("capture-live-time")
			var live_result: Dictionary=await live_capture.capture(scene,scene.world,scene.source_renderer._environment,live_folder,128,Vector3.ZERO)
			entry["live_time_capture"]=live_result.get("report",{})
			entry["live_time_test"]={"outer_time_scale_before":live_old_time,"requested_time_scale":1.0,
				"observed_time_scale_after_capture":Engine.time_scale,"process_mode_after_capture":scene.process_mode,
				"image_equality_asserted":false,"process_mode_restored":scene.process_mode==old_process,
				"scene_processing_before":live_processing_before,
				"scene_processing_after":{"can_process":scene.can_process(),"process":scene.is_processing(),"physics_process":scene.is_physics_processing()}}
			check_capture(slug,live_result,1.0,"live-time")
			if not entry.live_time_test.process_mode_restored: report.failures.append(slug+": live capture changed scene process mode")
			if entry.live_time_test.scene_processing_after!=live_processing_before: report.failures.append(slug+": live capture changed scene processing flags")
			live_capture.queue_free()
			Engine.time_scale=live_old_time
			entry.live_time_test["outer_time_scale_after_restore"]=Engine.time_scale
			entry.live_time_test["outer_time_scale_restored"]=Engine.time_scale==live_old_time
			if not entry.live_time_test.outer_time_scale_restored: report.failures.append(slug+": live test outer time scale restoration failed")
			await settle(8)
		report.maps.append(entry)
		save()
		print("SOURCE_CAPTURE_REFRESH_MAP ",slug," ",report.failures)
	scene.source_renderer.shutdown()
	scene.queue_free()
	await settle(8)
	save()
	quit(0 if report.failures.is_empty() else 1)
