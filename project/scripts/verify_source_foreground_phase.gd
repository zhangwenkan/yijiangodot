extends SceneTree
var out:=""
var scene: Node3D
var report:={"maps":[],"failures":[],"scope":"source FXAA phase during still/walk/return, original fade values retained"}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--foreground-phase-report-dir="): out=arg.trim_prefix("--foreground-phase-report-dir=")
	call_deferred("run")

func check(ok: bool,label: String) -> void:
	if not ok and not report.failures.has(label): report.failures.append(label)

func sample(label: String) -> Dictionary:
	var row:={"label":label,"frame":Engine.get_frames_drawn(),"active":0,"fading":0,"hidden":0,"values":[]}
	for entry in scene.foreground_driver.entries:
		if not bool(entry.fade_enabled): continue
		var material: ShaderMaterial=entry.material
		var phase: Variant=material.get_shader_parameter("source_foreground_phase")
		var visibility: Variant=material.get_shader_parameter("source_foreground_visibility")
		check(phase is float and is_zero_approx(phase),scene.slug+": FXAA phase remains zero: "+str(entry.actor))
		check(visibility is float and is_equal_approx(visibility,float(entry.visibility)),scene.slug+": shader keeps native computed visibility: "+str(entry.actor))
		check(float(entry.visibility)>=0.0 and float(entry.visibility)<=1.0,scene.slug+": visibility clamps to source range")
		row.active+=1
		row.fading+=int(float(entry.visibility)>0.0 and float(entry.visibility)<1.0)
		row.hidden+=int(bool(entry.hidden))
		row.values.append({"actor":entry.actor,"phase":phase,"visibility":visibility,"time_scale":entry.current_time_scale,"add_time_scale":entry.add_time_scale})
	return row

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	root.size=Vector2i(1280,720)
	root.content_scale_size=Vector2i(1280,720)
	root.scaling_3d_scale=1.0
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		Engine.time_scale=1.0
		scene.process_mode=Node.PROCESS_MODE_INHERIT
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		check(root.screen_space_aa==Viewport.SCREEN_SPACE_AA_FXAA and not root.use_taa,slug+": source FXAA active")
		var entry:={"map":slug,"samples":[],"foreground":scene.foreground_driver.report.duplicate(true)}
		for phase in [{"name":"still","motion":Vector2.ZERO,"frames":30},{"name":"walk","motion":Vector2(1,0),"frames":60},{"name":"stop","motion":Vector2.ZERO,"frames":30},{"name":"return","motion":Vector2(-1,0),"frames":60}]:
			scene.player.set_review_motion(phase.motion)
			for tick in int(phase.frames):
				await process_frame
				var row: Dictionary=sample(str(phase.name))
				if tick%15==0: entry.samples.append(row)
		scene.player.set_review_motion(Vector2.ZERO)
		for i in 15: await process_frame
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		await RenderingServer.frame_post_draw
		var first: Image=root.get_texture().get_image()
		first.save_png(out.path_join(slug+"-phase-zero.png"))
		for i in 20: await process_frame
		await RenderingServer.frame_post_draw
		var repeated: Image=root.get_texture().get_image()
		repeated.save_png(out.path_join(slug+"-phase-zero-repeat.png"))
		var a: PackedByteArray=first.get_data()
		var b: PackedByteArray=repeated.get_data()
		var changed:=0
		var peak:=0
		for i in a.size():
			var difference:=absi(int(a[i])-int(b[i]))
			changed+=int(difference>0)
			peak=maxi(peak,difference)
		entry["frozen_repeat"]={"changed_channels":changed,"max_channel_delta":peak,"note":"Descriptive whole-frame control; source phase is independently asserted on every live frame."}
		report.maps.append(entry)
	Engine.time_scale=1.0
	FileAccess.open(out.path_join("foreground-phase-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_FOREGROUND_PHASE_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	for i in 3: await process_frame
	quit(0 if report.failures.is_empty() else 1)
