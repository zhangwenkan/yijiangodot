extends SceneTree
## Observer only: original full renderer, player, house, camera, collisions and effects.
## One initial placement per case, followed only by continuous review input.
## --output=<dir> [--case=<name>] [--capture-png]
## Frame readback slows the run; recorded timestamps must be used for playback.

var output: String=""
var selected_case: String=""
var capture_png: bool=false
var camera_script: String=""
var scene: Node3D
var driver: FollowDriver
var report: Dictionary={"scope":"Continuous full-effect camera diagnostics; no claim of original parity or visual acceptance.","cases":[],"failures":[],"capture_note":"Optional every-rendered-frame PNG readback affects wall timing; not a performance benchmark."}

class FollowDriver extends Node:
	var scene: Node3D
	var definition: Dictionary
	var directory: String
	var capture_png: bool=false
	var finished: bool=false
	var phase: String="initial_hold"
	var tick: int=0
	var render_frame: int=0
	var waypoint: int=0
	var sim: float=0.0
	var hold_until: float=2.0
	var started_usec: int=0
	var last_draw_usec: int=0
	var previous: Vector3=Vector3.ZERO
	var inside: bool=false
	var physics_file: FileAccess
	var frame_file: FileAccess
	var draw_file: FileAccess
	var last_render_state: Dictionary={}
	var fixed_references: Array[Vector3]=[]
	var row: Dictionary={}

	func v3(value: Vector3) -> Array: return [value.x,value.y,value.z]
	func v2(value: Vector2) -> Array: return [value.x,value.y]
	func xz(a: Vector3,b: Vector3) -> float: return Vector2(a.x-b.x,a.z-b.z).length()
	func wall_seconds() -> float: return float(Time.get_ticks_usec()-started_usec)/1000000.0
	func state(delta: float) -> Dictionary:
		var player: CharacterBody3D=scene.player
		var camera: Camera3D=scene.camera
		var anchor: Vector3=player.get_camera_anchor()
		var target: Vector3=camera._locked_anchor(anchor)
		var capsule: CollisionShape3D=player.get_node("MovementCapsule")
		var projections: Array=[]
		for point: Vector3 in fixed_references:
			projections.append({"world":v3(point),"screen":v2(camera.unproject_position(point)),"behind":camera.is_position_behind(point)})
		var active_bounds: Array=[]
		for bound: Dictionary in camera.source_bounds:
			if bool(bound.overlapping): active_bounds.append({"name":bound.get("actor",bound.get("name","")),"direction":bound.direction})
		return {"physics_tick":tick,"render_frame":render_frame,"simulation_seconds":sim,"wall_seconds":wall_seconds(),"delta":delta,"phase":phase,"waypoint":waypoint,"feet":v3(player.global_position),"velocity":v3(player.velocity),"anchor":v3(anchor),"locked_target":v3(target),"tracked":v3(camera.tracked),"source_offset":v3(camera.source_offset),"zoom":camera.zoom,"camera":v3(camera.global_position),"rotation":v3(camera.global_rotation),"inside":scene.house_driver.is_in_house,"source_house_scale":player.source_house_scale,"capsule_center":v3(capsule.global_position),"capsule_radius":capsule.shape.radius,"capsule_height":capsule.shape.height,"source_axis_locked":camera.source_axis_locked.duplicate(),"source_axis_values":v3(camera.source_axis_values),"bounds_events":camera.source_bounds_report.duplicate(),"active_bounds":active_bounds,"feet_screen":v2(camera.unproject_position(player.global_position)),"anchor_screen":v2(camera.unproject_position(anchor)),"fixed_projections":projections,"inspection":camera.inspection,"tracking_speed":camera.tracking_speed,"height_speed":camera.height_speed,"on_floor":player.is_on_floor(),"floor_normal":v3(player.get_floor_normal()),"edge_blocked":player.blocked_at_edge,"drawn_frames":Engine.get_frames_drawn(),"process_frames":Engine.get_process_frames(),"physics_frames":Engine.get_physics_frames()}
	func begin() -> void:
		process_physics_priority=50 # after original player(0) and original house(10)
		process_priority=100 # after worlds._process camera.advance
		started_usec=Time.get_ticks_usec()
		previous=scene.player.global_position
		inside=scene.house_driver.is_in_house
		fixed_references=[previous,previous+Vector3(3,0,0),previous+Vector3(0,0,3),previous+Vector3(0,3,0)]
		DirAccess.make_dir_recursive_absolute(directory)
		if capture_png: DirAccess.make_dir_recursive_absolute(directory.path_join("frames"))
		physics_file=FileAccess.open(directory.path_join("physics.jsonl"),FileAccess.WRITE)
		frame_file=FileAccess.open(directory.path_join("render.jsonl"),FileAccess.WRITE)
		draw_file=FileAccess.open(directory.path_join("draw.jsonl"),FileAccess.WRITE)
		row={"name":definition.name,"map":definition.map,"definition":definition,"initial_placements":1,"mid_case_teleports":0,"travelled_m":0.0,"initial_feet":v3(previous),"house_transitions":[],"min_gap":INF,"max_gap":-INF,"support_missing_ticks":0,"below_support_ticks":0,"edge_blocked_ticks":0,"capture_png":capture_png,"captured_frames":0,"capture_failures":0,"source_components":{},"renderer_flags":{"source_rendering":scene.source_rendering,"source_distortion":scene.source_distortion,"source_atmosphere":scene.source_atmosphere,"time_scale":Engine.time_scale},"process_priorities":{"physics_observer":50,"render_observer":100}}
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw)

	func _physics_process(delta: float) -> void:
		if finished: return
		sim+=delta
		var player: CharacterBody3D=scene.player
		var pos: Vector3=player.global_position
		row.travelled_m+=xz(pos,previous)
		previous=pos
		var now: Dictionary=state(delta)
		var support: Dictionary=player._support_at(pos,player.MAX_STEP_HEIGHT+.07,player.MAX_STEP_HEIGHT+.15)
		if support.is_empty():
			row.support_missing_ticks+=1
			now.support={}
		else:
			var gap: float=pos.y-float(support.position.y)
			var component: String=str(int(support.collider.get_meta("source_component",-1)))
			now.support={"position":v3(support.position),"normal":v3(support.normal),"gap":gap,"source":str(support.collider.get_meta("source_name","unknown")),"component":component}
			row.source_components[component]=int(row.source_components.get(component,0))+1
			row.min_gap=minf(row.min_gap,gap)
			row.max_gap=maxf(row.max_gap,gap)
			if gap<-.03: row.below_support_ticks+=1
		if player.blocked_at_edge: row.edge_blocked_ticks+=1
		if scene.house_driver.is_in_house!=inside:
			inside=scene.house_driver.is_in_house
			row.house_transitions.append(now.duplicate(true))
		physics_file.store_line(JSON.stringify(now))
		var motion: Vector2=Vector2.ZERO
		if sim>=hold_until:
			if waypoint>=definition.path.size():
				phase="complete"
				finished=true
			else:
				phase="move_%d"%waypoint
				var point: Dictionary=definition.path[waypoint]
				var target: Vector3=Vector3(point.position[0],point.position[1],point.position[2])
				if xz(pos,target)<float(definition.get("tolerance",.08)):
					phase="hold_%d"%waypoint
					hold_until=sim+float(point.get("hold",1.5))
					waypoint+=1
				else:
					var heading: Vector3=target-pos
					heading.y=0.0
					heading=heading.normalized()*minf(1.0,heading.length()/maxf(player.move_speed*delta,.001))
					var right: Vector3=scene.camera.global_basis.x
					right.y=0.0; right=right.normalized()
					var forward: Vector3=-scene.camera.global_basis.z
					forward.y=0.0; forward=forward.normalized()
					motion=Vector2(heading.dot(right),-heading.dot(forward))
		if sim>float(definition.get("time_limit",35.0)) or wall_seconds()>150.0:
			phase="timeout"
			finished=true
		player.set_review_motion(Vector2.ZERO if finished else motion)
		if finished:
			row.status=phase
			row.final_state=now
			row.physics_ticks=tick+1
			row.simulation_seconds=sim
			row.wall_seconds=wall_seconds()
		tick+=1

	func _process(delta: float) -> void:
		if finished: return
		last_render_state=state(delta)
		frame_file.store_line(JSON.stringify(last_render_state))
		render_frame+=1

	func _on_frame_post_draw() -> void:
		if finished or last_render_state.is_empty(): return
		var stamp_usec: int=Time.get_ticks_usec()
		var draw: Dictionary={"render_frame":last_render_state.render_frame,"physics_tick":last_render_state.physics_tick,"wall_seconds":float(stamp_usec-started_usec)/1000000.0,"wall_interval_seconds":0.0 if last_draw_usec==0 else float(stamp_usec-last_draw_usec)/1000000.0,"simulation_seconds":last_render_state.simulation_seconds,"phase":last_render_state.phase,"file":""}
		last_draw_usec=stamp_usec
		if capture_png:
			var file: String="frames/%06d.png"%int(row.captured_frames)
			var result: int=get_viewport().get_texture().get_image().save_png(directory.path_join(file))
			draw.file=file
			draw.save_error=result
			draw.readback_save_seconds=float(Time.get_ticks_usec()-stamp_usec)/1000000.0
			row.captured_frames+=1
			if result!=OK: row.capture_failures+=1
		draw_file.store_line(JSON.stringify(draw))

	func finish() -> void:
		scene.player.set_review_motion(Vector2.ZERO)
		if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw): RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
		row.render_samples=render_frame
		physics_file.flush(); frame_file.flush(); draw_file.flush()
		physics_file=null; frame_file=null; draw_file=null

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output=arg.trim_prefix("--output=")
		if arg.begins_with("--case="): selected_case=arg.trim_prefix("--case=")
		if arg=="--capture-png": capture_png=true
		if arg.begins_with("--camera-script="): camera_script=arg.trim_prefix("--camera-script=")
	call_deferred("run")

func save_report() -> void:
	_record_backend_summary()
	FileAccess.open(output.path_join("camera-follow.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))

func point(x: float,y: float,z: float,hold: float=1.5) -> Dictionary:
	return {"position":[x,y,z],"hold":hold}

func run() -> void:
	if output.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(output)
	if not _start_backend_observer():
		save_report(); quit(2); return
	root.size=Vector2i(1280,720)
	root.content_scale_size=Vector2i(1280,720)
	var cases: Array=[
		{"name":"wuming_boardwalk","map":"wuming","start":[-89.4105,3.45,0.0],"path":[point(-89.4105,3.45,.9),point(-89.4105,3.45,-.9),point(-89.4105,3.45,0.0,3.0)],"required_component":"7084"},
		{"name":"wuming_stairs","map":"wuming","start":[-79.8,3.5,38.231],"path":[point(-77.5,3.5,38.231,3.0),point(-79.8,3.5,38.231,3.0)],"required_component":"6896"},
		{"name":"wuming_house","map":"wuming","start":[-79.8,3.5,38.231],"path":[point(-75.6,4.4,38.231,3.0),point(-79.8,3.5,38.231,3.0)],"expected_house_transitions":2},
		{"name":"youxian_house","map":"youxian","start":[-54.99952,3.3729863,44.87575],"path":[point(-51.34952,3.920986,44.87575,3.0),point(-54.99952,3.3729863,44.87575,3.0)],"expected_house_transitions":2}]
	if not selected_case.is_empty(): cases=cases.filter(func(item: Dictionary) -> bool: return item.name==selected_case)
	if cases.is_empty():
		report.failures.append("Unknown case: "+selected_case)
		save_report(); quit(2); return
	scene=load("res://worlds.tscn").instantiate()
	if not camera_script.is_empty():
		var replacement: String='load("'+camera_script.replace('\\','/')+'")'
		var world_script:=GDScript.new()
		world_script.source_code=FileAccess.get_file_as_string("res://scripts/worlds.gd").replace('preload("res://scripts/original_camera.gd")',replacement)
		if world_script.reload()!=OK:
			report.failures.append("Candidate worlds script failed to compile")
			save_report(); quit(2); return
		scene.set_script(world_script)
	report.camera_script=camera_script if not camera_script.is_empty() else "res://scripts/original_camera.gd"
	scene.hide_ui=true
	scene.source_rendering=true
	scene.source_distortion=true
	scene.source_atmosphere=true
	root.add_child(scene)
	while scene.loading or not is_instance_valid(scene.house_driver): await process_frame
	for definition: Dictionary in cases:
		if scene.slug!=definition.map: await scene._load_world(definition.map)
		scene.tour_finished=true
		scene.player.input_enabled=false
		scene.player.set_review_motion(Vector2.ZERO)
		scene.house_driver.reset_outdoors()
		var start: Array=definition.start
		if not scene.player.place_at_source_actor_position(Vector3(start[0],start[1],start[2])):
			report.failures.append(definition.name+": source start unsupported")
			continue
		scene.camera.reset_at(scene.player.get_camera_anchor())
		for i in 30: await process_frame
		driver=FollowDriver.new()
		driver.scene=scene
		driver.definition=definition
		driver.directory=output.path_join(definition.name)
		driver.capture_png=capture_png
		driver.begin()
		root.add_child(driver)
		while not driver.finished: await process_frame
		driver.finish()
		var row: Dictionary=driver.row
		if row.status!="complete": report.failures.append(definition.name+": timeout")
		if row.below_support_ticks>0 or row.support_missing_ticks>0: report.failures.append(definition.name+": support violation")
		if row.capture_failures>0: report.failures.append(definition.name+": frame save failed")
		if definition.has("required_component") and not row.source_components.has(definition.required_component): report.failures.append(definition.name+": original support not encountered")
		if definition.has("expected_house_transitions") and row.house_transitions.size()!=int(definition.expected_house_transitions): report.failures.append(definition.name+": incorrect house transition count")
		if definition.name=="wuming_stairs" and not row.house_transitions.is_empty(): report.failures.append("Stairs-only path entered a house; do not treat it as isolated stair evidence")
		report.cases.append(row)
		save_report()
		print("CAMERA_FOLLOW_CASE ",JSON.stringify({"case":definition.name,"status":row.status,"physics_ticks":row.physics_ticks,"render_samples":row.render_samples,"captured_frames":row.captured_frames,"house_transitions":row.house_transitions.size()}))
		driver.queue_free()
		await process_frame
	scene.queue_free()
	for i in 5: await process_frame
	report.status="observed" if report.failures.is_empty() else "failed"
	save_report()
	quit(0 if report.failures.is_empty() else 1)


# Backend observation only. The original four paths and FollowDriver are unchanged.
var _backend_expected: String = ""
var _backend_file: FileAccess
var _backend_started_usec: int = 0
var _backend_draws: int = 0
var _backend_case_phases: Dictionary = {}
var _backend_source_hashes: Dictionary = {}

func _backend_fail(message: String) -> void:
	if not report.failures.has(message): report.failures.append(message)

func _backend_sources() -> Dictionary:
	var result: Dictionary = {}
	for path: String in ["res://scripts/worlds.gd","res://scripts/original_player.gd","res://scripts/original_house.gd","res://scripts/original_camera.gd","res://scripts/source_animal_behavior.gd",get_script().resource_path]:
		result[path] = FileAccess.get_sha256(path)
	return result

func _start_backend_observer() -> bool:
	var choices: Array[String] = []
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--diagnostic-driver="): choices.append(arg.trim_prefix("--diagnostic-driver="))
	if choices.size()!=1 or choices[0] not in ["vulkan","d3d12"]:
		_backend_fail("Exactly one valid --diagnostic-driver is required")
		return false
	_backend_expected = choices[0]
	for arg: String in OS.get_cmdline_args():
		if arg in ["--headless","--fixed-fps","--write-movie","--disable-render-loop"] or arg.begins_with("--fixed-fps=") or arg.begins_with("--write-movie="):
			_backend_fail("Normal-speed rendered review rejects engine option: "+arg)
	if not camera_script.is_empty(): _backend_fail("Playable backend review requires original production camera")
	if capture_png: _backend_fail("Normal-speed timing review requires no per-frame PNG readback")
	if Engine.time_scale!=1.0: _backend_fail("Normal-speed review requires time_scale exactly 1")
	if RenderingServer.get_current_rendering_driver_name()!=_backend_expected or RenderingServer.get_current_rendering_method()!="forward_plus":
		_backend_fail("Actual rendering backend does not match required driver / Forward+")
	if not report.failures.is_empty(): return false
	_backend_source_hashes = _backend_sources()
	for path in _backend_source_hashes:
		if str(_backend_source_hashes[path]).is_empty(): _backend_fail("Missing runtime source hash: "+str(path))
	_backend_started_usec = Time.get_ticks_usec()
	_backend_file = FileAccess.open(output.path_join("backend-draw.jsonl"),FileAccess.WRITE)
	if _backend_file==null:
		_backend_fail("Could not create backend draw record")
		return false
	report["backend_review"] = {"expected_driver":_backend_expected,"method":"forward_plus","source_before":_backend_source_hashes,
		"engine_arguments":Array(OS.get_cmdline_args()),"user_arguments":Array(OS.get_cmdline_user_args()),
		"boundary":"Ordinary real-time rendering and original input paths. Every actual draw observes driver, time_scale and camera. CPU draw sampling is not GPU buffer readback, external video or art/comfort acceptance."}
	RenderingServer.frame_post_draw.connect(_observe_backend_draw)
	return report.failures.is_empty()

func _observe_backend_draw() -> void:
	var actual_driver := RenderingServer.get_current_rendering_driver_name()
	var actual_method := RenderingServer.get_current_rendering_method()
	if actual_driver!=_backend_expected or actual_method!="forward_plus": _backend_fail("Runtime driver/method changed or fell back")
	if Engine.time_scale!=1.0: _backend_fail("Runtime time_scale departed from exactly 1")
	var row: Dictionary = {"draw_index":_backend_draws,"wall_seconds":float(Time.get_ticks_usec()-_backend_started_usec)/1000000.0,
		"driver":actual_driver,"method":actual_method,"time_scale":Engine.time_scale,"engine_drawn_frames":Engine.get_frames_drawn(),
		"case":"","phase":"loading-or-between-cases"}
	if is_instance_valid(scene) and not scene.loading and is_instance_valid(scene.camera) and is_instance_valid(driver) and not driver.finished:
		row["case"] = str(driver.definition.name)
		row["phase"] = driver.phase
		row["simulation_seconds"] = driver.sim
		row["case_wall_seconds"] = driver.wall_seconds()
		row["inside"] = scene.house_driver.is_in_house
		row["map"] = scene.slug
		row["source_rendering"] = scene.source_rendering
		row["source_distortion"] = scene.source_distortion
		row["source_atmosphere"] = scene.source_atmosphere
		row["camera"] = driver.v3(scene.camera.global_position)
		row["camera_rotation"] = driver.v3(scene.camera.global_rotation)
		row["feet"] = driver.v3(scene.player.global_position)
		row["feet_screen"] = driver.v2(scene.camera.unproject_position(scene.player.global_position))
		row["source_house_scale"] = scene.player.source_house_scale
		if not scene.source_rendering or not scene.source_distortion or not scene.source_atmosphere or not is_instance_valid(scene.source_renderer):
			_backend_fail("A rendered route disabled an original effect or renderer")
		for value in row.camera+row.camera_rotation+row.feet+row.feet_screen:
			if not is_finite(float(value)): _backend_fail("Nonfinite camera/player draw observation")
		if not _backend_case_phases.has(row.case): _backend_case_phases[row.case] = {}
		var phases: Dictionary = _backend_case_phases[row.case]
		phases[row.phase] = int(phases.get(row.phase,0))+1
	_backend_file.store_line(JSON.stringify(row))
	_backend_draws += 1

func _record_backend_summary() -> void:
	if not report.has("backend_review"): return
	# Seal the final report before quit can schedule another empty-scene draw.
	if report.has("status") and RenderingServer.frame_post_draw.is_connected(_observe_backend_draw):
		RenderingServer.frame_post_draw.disconnect(_observe_backend_draw)
	if _backend_file!=null: _backend_file.flush()
	report.backend_review["draw_observations"] = _backend_draws
	report.backend_review["elapsed_wall_seconds"] = float(Time.get_ticks_usec()-_backend_started_usec)/1000000.0
	report.backend_review["case_phase_draws"] = _backend_case_phases
	report.backend_review["source_after"] = _backend_sources()
	report.backend_review["sources_exact"] = report.backend_review.source_after==_backend_source_hashes
	if not report.backend_review.sources_exact: _backend_fail("Original gameplay source or observer changed during run")
	if report.has("status"):
		for item: Dictionary in report.cases:
			var phases: Dictionary = _backend_case_phases.get(item.name,{})
			if int(phases.get("initial_hold",0))==0: _backend_fail(str(item.name)+": initial hold has no actual draw")
			for i in item.definition.path.size():
				for phase: String in ["move_%d"%i,"hold_%d"%i]:
					if int(phases.get(phase,0))==0: _backend_fail(str(item.name)+": no actual draw for "+phase)
		report.status = "observed" if report.failures.is_empty() else "failed"
