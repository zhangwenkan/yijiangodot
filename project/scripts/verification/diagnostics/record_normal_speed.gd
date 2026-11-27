extends "res://scripts/verification/diagnostics/verify_camera_follow_backend.gd"
## External DDA/window recording entry. No image readback or TLV installation.
## --output=<fresh directory> --go-file=<new file> [--case=wuming_house|youxian_house|wuming_dock|youxian_dock]

var go_file := ""
var launch_usec := 0
var ready_usec := 0
var started_usec := 0
var end_hold_seconds := 3.0

class RecordingDriver extends FollowDriver:
	# Keep the original _physics_process and complete route algorithm inherited.
	# Remove render/post logging and retain only small physics rows for the route.
	func state(delta: float) -> Dictionary:
		return {"physics_tick":tick,"simulation_seconds":sim,"wall_seconds":wall_seconds(),"delta":delta,
			"phase":phase,"waypoint":waypoint,"feet":v3(scene.player.global_position),
			"inside":scene.house_driver.is_in_house,"camera":v3(scene.camera.global_position),
			"time_scale":Engine.time_scale}

	func begin() -> void:
		process_physics_priority=50
		process_priority=100
		started_usec=Time.get_ticks_usec()
		previous=scene.player.global_position
		inside=scene.house_driver.is_in_house
		physics_file=FileAccess.open(directory.path_join("physics.jsonl"),FileAccess.WRITE)
		row={"name":definition.name,"map":definition.map,"definition":definition,
			"initial_placements":1,"mid_case_teleports":0,"travelled_m":0.0,"initial_feet":v3(previous),
			"house_transitions":[],"min_gap":INF,"max_gap":-INF,"support_missing_ticks":0,
			"below_support_ticks":0,"edge_blocked_ticks":0,"source_components":{},"capture_png":false,
			"capture_note":"External recording only. No viewport readback or render/post file logging."}

	func _process(_delta: float) -> void: pass
	func _on_frame_post_draw() -> void: pass
	func finish() -> void:
		scene.player.set_review_motion(Vector2.ZERO)
		physics_file.flush()
		physics_file=null

func _initialize() -> void:
	launch_usec=Time.get_ticks_usec()
	selected_case="wuming_house"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output=arg.trim_prefix("--output=")
		elif arg.begins_with("--case="): selected_case=arg.trim_prefix("--case=")
		elif arg.begins_with("--go-file="): go_file=arg.trim_prefix("--go-file=")
	call_deferred("run")

func stamp() -> Dictionary:
	return {"ticks_usec":Time.get_ticks_usec(),"unix_seconds":Time.get_unix_time_from_system(),
		"wall_since_launch":float(Time.get_ticks_usec()-launch_usec)/1000000.0,"time_scale":Engine.time_scale,
		"drawn_frames":Engine.get_frames_drawn(),"physics_frames":Engine.get_physics_frames()}

func feet() -> Array:
	var value: Vector3=scene.player.global_position
	return [value.x,value.y,value.z]

func write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null: return false
	file.store_string(JSON.stringify(value,"\t"))
	file.flush()
	return file.get_error()==OK

func reject(message: String) -> void:
	report.failures.append(message)
	report.status="failed"
	report.ended=stamp()
	if not output.is_empty(): write_json(output.path_join("recording-report.json"),report)
	push_error(message)
	quit(2)

func normal_speed_options() -> bool:
	for arg: String in OS.get_cmdline_args():
		if arg in ["--headless","--fixed-fps","--write-movie","--disable-render-loop"] or arg.begins_with("--fixed-fps=") or arg.begins_with("--write-movie="):
			report.failures.append("Normal-speed recording rejects engine option: "+arg)
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--capture") or arg.begins_with("--motion-frames") or arg.begins_with("--tour") or arg.begins_with("--camera-script") or arg in ["--inspect","--lighting-review","--legacy-lighting"] or arg.begins_with("--tlv"):
			report.failures.append("Recording must keep default scene effects/camera: "+arg)
	if Engine.time_scale!=1.0: report.failures.append("Expected unchanged Engine.time_scale == 1.0")
	return report.failures.is_empty()

func run() -> void:
	report={"schema":1,"case":selected_case,"status":"starting","failures":[],
		"scope":"Normal-speed visible gameplay for external DDA recording; no original-engine parity claim.",
		"capture":"External recorder; no Godot image readback, fixed FPS, time-scale changes or TLV installation.",
		"source_sha256":_backend_sources(),"launched":stamp()}
	report.source_sha256["res://scripts/verification/diagnostics/verify_camera_follow_backend.gd"]=FileAccess.get_sha256("res://scripts/verification/diagnostics/verify_camera_follow_backend.gd")
	if output.is_empty() or go_file.is_empty(): reject("Required --output and --go-file."); return
	DirAccess.make_dir_recursive_absolute(output)
	if not normal_speed_options(): reject("Unsupported recording options."); return
	if FileAccess.file_exists(go_file): reject("Go file already exists; use a new per-run go path."); return
	var definitions: Dictionary={
		"wuming_house":{"name":"wuming_house","map":"wuming","start":[-79.8,3.5,38.231],"path":[point(-75.6,4.4,38.231,3.0),point(-79.8,3.5,38.231,3.0)]},
		"youxian_house":{"name":"youxian_house","map":"youxian","start":[-54.99952,3.3729863,44.87575],"path":[point(-51.34952,3.920986,44.87575,3.0),point(-54.99952,3.3729863,44.87575,3.0)]},
		"wuming_dock":{"name":"wuming_dock","map":"wuming","path":[],"stationary_wall_seconds":20.0},
		"youxian_dock":{"name":"youxian_dock","map":"youxian","path":[],"stationary_wall_seconds":20.0}}
	if not definitions.has(selected_case): reject("Unknown recording case: "+selected_case); return
	var definition: Dictionary=definitions[selected_case]
	scene=load("res://worlds.tscn").instantiate()
	scene.slug=definition.map
	scene.hide_ui=true
	root.add_child(scene)
	while scene.loading or not is_instance_valid(scene.house_driver): await process_frame
	if scene.slug!=definition.map: reject("Loaded map differs from selected case; do not pass --map."); return
	scene.tour_finished=true
	scene.player.input_enabled=false
	scene.player.set_review_motion(Vector2.ZERO)
	if definition.has("start"):
		scene.house_driver.reset_outdoors()
		var start: Array=definition.start
		if not scene.player.place_at_source_actor_position(Vector3(start[0],start[1],start[2])):
			reject("Source house start is unsupported."); return
		scene.camera.reset_at(scene.player.get_camera_anchor())
	# The dock uses the unmodified production spawn; house uses one pre-record placement.
	for i in 30: await process_frame
	if Engine.time_scale!=1.0 or not scene.source_rendering or not scene.source_distortion or not scene.source_atmosphere:
		reject("Default effects or normal time scale changed at startup."); return
	report.definition=definition
	report.initial_feet=feet()
	report.initial_placements=1 if definition.has("start") else 0
	report.mid_route_teleports=0
	report.camera_script=scene.camera.get_script().resource_path
	report.default_effects={"source_rendering":scene.source_rendering,"source_distortion":scene.source_distortion,"source_atmosphere":scene.source_atmosphere,"tlv_installed":false}
	report.backend={"driver":RenderingServer.get_current_rendering_driver_name(),"method":RenderingServer.get_current_rendering_method(),"window_size":[root.size.x,root.size.y]}
	ready_usec=Time.get_ticks_usec()
	report.ready=stamp()
	report.status="ready_waiting_for_go"
	report.go_file=go_file
	if not write_json(output.path_join("ready.json"),report): reject("Could not write ready marker."); return
	print("NORMAL_SPEED_RECORDING_READY ",JSON.stringify({"case":selected_case,"go_file":go_file,"ready":report.ready,"feet":feet()}))
	while not FileAccess.file_exists(go_file): await process_frame
	started_usec=Time.get_ticks_usec()
	report.started=stamp()
	report.wait_for_go_wall_seconds=float(started_usec-ready_usec)/1000000.0
	report.start_feet=feet()
	report.status="recording"
	write_json(output.path_join("started.json"),report)
	print("NORMAL_SPEED_RECORDING_STARTED ",JSON.stringify(report.started))
	if definition.has("stationary_wall_seconds"):
		while float(Time.get_ticks_usec()-started_usec)/1000000.0<float(definition.stationary_wall_seconds):
			if Engine.time_scale!=1.0: reject("Time scale changed during stationary capture."); return
			await process_frame
		report.route={"status":"complete","kind":"default_spawn_stationary","target_wall_seconds":20.0}
	else:
		driver=RecordingDriver.new()
		driver.scene=scene
		driver.definition=definition
		driver.directory=output
		driver.begin()
		if driver.physics_file==null: reject("Could not create route physics file."); return
		root.add_child(driver)
		while not driver.finished:
			if Engine.time_scale!=1.0: reject("Time scale changed during route."); return
			await process_frame
		driver.finish()
		report.route=driver.row
		if driver.row.status!="complete": report.failures.append("Original route timed out.")
		if driver.row.house_transitions.size()!=2: report.failures.append("Expected two actual house transitions.")
		elif not bool(driver.row.house_transitions[0].inside) or bool(driver.row.house_transitions[1].inside): report.failures.append("Expected enter then exit.")
		if driver.row.support_missing_ticks>0 or driver.row.below_support_ticks>0: report.failures.append("Original route support violation.")
	scene.player.set_review_motion(Vector2.ZERO)
	report.route_ended=stamp()
	report.route_wall_seconds=float(Time.get_ticks_usec()-started_usec)/1000000.0
	report.final_feet=feet()
	report.final_inside=scene.house_driver.is_in_house
	report.end_hold_seconds=end_hold_seconds
	var end_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec()-end_usec)/1000000.0<end_hold_seconds: await process_frame
	report.ended=stamp()
	report.source_after=_backend_sources()
	report.source_after["res://scripts/verification/diagnostics/verify_camera_follow_backend.gd"]=FileAccess.get_sha256("res://scripts/verification/diagnostics/verify_camera_follow_backend.gd")
	if Engine.time_scale!=1.0: report.failures.append("Time scale changed during final hold.")
	if report.source_after!=report.source_sha256: report.failures.append("Gameplay source changed during recording.")
	report.status="complete" if report.failures.is_empty() else "failed"
	write_json(output.path_join("recording-report.json"),report)
	print("NORMAL_SPEED_RECORDING_COMPLETE ",JSON.stringify({"case":selected_case,"status":report.status,"wall_seconds":report.route_wall_seconds,"feet":report.final_feet}))
	quit(0 if report.failures.is_empty() else 1)
