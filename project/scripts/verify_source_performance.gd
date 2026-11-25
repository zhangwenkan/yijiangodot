extends SceneTree
var out := ""
var default_only := false
var scene: Node3D
var report:={"samples":[],"capture":"real wall-clock frames; no screenshot or readback in measured interval"}
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--performance-report-dir="): out=arg.trim_prefix("--performance-report-dir=")
		if arg=="--performance-default-only": default_only=true
	call_deferred("run")

func sample(label: String) -> void:
	for i in 15: await process_frame
	var times: Array[float]=[]
	var process_times: Array[float]=[]
	var physics_times: Array[float]=[]
	var start:=Time.get_ticks_usec()
	var prev:=start
	while Time.get_ticks_usec()-start<4000000:
		await process_frame
		var now:=Time.get_ticks_usec()
		times.append(float(now-prev)/1000.0)
		process_times.append(Performance.get_monitor(Performance.TIME_PROCESS)*1000.0)
		physics_times.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0)
		prev=now
	times.sort()
	process_times.sort()
	physics_times.sort()
	var row:={"map":scene.slug,"mode":label,"frames":times.size(),"seconds":float(prev-start)/1000000.0,
		"median_ms":times[times.size()/2],"p95_ms":times[min(times.size()-1,int(times.size()*.95))],
		"fps":float(times.size())/(float(prev-start)/1000000.0),
		"process_median_ms":process_times[process_times.size()/2],
		"physics_median_ms":physics_times[physics_times.size()/2],
		"physics_p95_ms":physics_times[min(physics_times.size()-1,int(physics_times.size()*.95))]}
	report.samples.append(row)
	print("SOURCE_PERFORMANCE_SAMPLE ",JSON.stringify(row))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	root.content_scale_size=Vector2i(1280,720)
	root.size=Vector2i(1280,720)
	scene=load("res://worlds.tscn").instantiate()
	scene.source_rendering=true
	scene.source_distortion=true
	scene.source_atmosphere=true
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	report["render_size"]=root.get_texture().get_size()
	report["default_only"]=default_only
	report["active_source_quality"]="FXAA; HDR circle DOF before Bloom/Film; source animals, human NPCs and original ambient materials"
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug:
			scene.source_rendering=true
			await scene._load_world(slug)
		scene.tour_finished=true
		scene.player.set_review_motion(Vector2.ZERO)
		var renderer: Node=scene.source_renderer
		await sample("all-source")
		if default_only: continue
		var animal_controller: Node=null
		for node in scene.world.get_children():
			if node.get_script()!=null and node.get_script().resource_path.ends_with("/source_animal_behavior.gd"):
				animal_controller=node
		if animal_controller!=null:
			animal_controller.disabled=true
			await sample("animal-behavior-paused-diagnostic")
			animal_controller.disabled=false
		renderer.distortion.enabled=false
		await sample("no-distortion")
		renderer.atmosphere.effect.enabled=false
		await sample("no-distortion-or-atmosphere")
		renderer.bloom.enabled=false
		await sample("HDR-DOF-and-film")
		renderer.film.enabled=false
		await sample("HDR-DOF-only-post")
		renderer.depth_of_field.effect.enabled=false
		await sample("no-source-post")
		scene.source_rendering=false
		await scene._load_world(slug)
		scene.tour_finished=true
		await sample("legacy-lighting")
	FileAccess.open(out.path_join("performance.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	scene.queue_free()
	for i in 5: await process_frame
	quit()
