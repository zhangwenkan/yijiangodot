extends "res://scripts/verification/diagnostics/verify_camera_follow_backend.gd"
## Opt-in real-time route observation. Reuses original FollowDriver and house paths.
## No frozen clock, direct set_inside, mid-route placement, or full GPU readback.
var tlv_mode := ""
var producer: Node
var tlv_file: FileAccess
var tlv_row: Dictionary = {}
var tlv_last_submission: Dictionary = {}
var tlv_start_usec := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tlv-route-mode="): tlv_mode=arg.trim_prefix("--tlv-route-mode=")
	super._initialize()

func _backend_sources() -> Dictionary:
	var hashes := super._backend_sources()
	for path in ["res://scripts/verification/diagnostics/verify_camera_follow_backend.gd",
		"res://source_tlv_realtime/realtime_sun.gd","res://source_tlv_realtime/snapshot_receiver.gd",
		"res://source_tlv_realtime/main_rd_bridge.gd","res://source_tlv_realtime/dual_probe.gd",
		"res://source_tlv_realtime/dynamic_caster_binding.gd"]:
		hashes[path]=FileAccess.get_sha256(path)
	return hashes

func route_check(condition: bool, message: String) -> void:
	if not condition: _backend_fail(message)

func observe_tlv_pre() -> void:
	var sample := {"frame":Engine.get_frames_drawn(),"wall_seconds":float(Time.get_ticks_usec()-tlv_start_usec)/1000000.0,
		"inside":scene.house_driver.is_in_house,"camera":str(scene.camera.global_transform),
		"time_scale":Engine.time_scale,"mode":tlv_mode,"active":false,"errors":[],"materials":0}
	if is_instance_valid(producer):
		sample.producer_status=producer.report.status
		sample.house_generation=producer._house_generation
		sample.owner_generation=producer._owner_generation
		sample.produced=producer.report.produced
		sample.published=producer.report.published
		var active: Dictionary=producer._active
		var receiver: Node=producer._receiver
		if not active.is_empty():
			sample.active=true
			sample.snapshot_id=active.snapshot_id
			sample.age_frames=Engine.get_frames_drawn()-int(active.request_frame)
			sample.active_inside=active.house_inside
			sample.request_frame=active.request_frame
			if not producer._fresh(active,Engine.get_frames_drawn()): sample.errors.append("Active pair exceeded normal freshness/coverage policy.")
			if bool(active.house_inside)!=bool(sample.inside): sample.errors.append("Previous house-state lighting escaped invalidation.")
		if receiver!=null:
			sample.errors.append_array(receiver.owner_errors())
			sample.materials=receiver._saved.size()
			sample.receiver_mode=receiver.report.mode
			var expected_count := 28 if scene.slug=="wuming" else 2
			if receiver._saved.size()!=expected_count: sample.errors.append("Incomplete receiver material set.")
			if active.is_empty():
				for saved in receiver._saved:
					if int(saved.material.get_shader_parameter("source_tlv_sun_mode"))!=0: sample.errors.append("Invalidated receiver failed to fall back to original sun.")
			else:
				if receiver.snapshot_id!=active.snapshot_id: sample.errors.append("Receiver token differs from active pair.")
				var textures: Array[Dictionary]=producer._slots[int(active.slot)].textures
				for saved in receiver._saved:
					var material: ShaderMaterial=saved.material
					if material.shader!=saved.installed: sample.errors.append("Receiver shader owner changed.")
					if int(material.get_shader_parameter("source_tlv_sun_mode"))!=1: sample.errors.append("Fresh receiver did not select TLV sun.")
					for cascade in 2:
						var suffix := "inner" if cascade==0 else "outer"
						for component in ["ambient","directional"]:
							if material.get_shader_parameter("source_tlv_"+component+"_"+suffix)!=textures[cascade][component]: sample.errors.append("Mixed texture pair submission.")
						if material.get_shader_parameter("source_tlv_min_"+suffix+"_cm")!=active.bounds[cascade].min_ue_cm: sample.errors.append("Mixed bounds submission.")
						var extent: float=float(active.bounds[cascade].voxel_cm)*int(active.bounds[cascade].dimension)
						if material.get_shader_parameter("source_tlv_inv_size_"+suffix)!=Vector3.ONE/extent: sample.errors.append("Mixed volume size submission.")
		elif not active.is_empty(): sample.errors.append("Active receiver pair has no receiver.")
	if Engine.time_scale!=1.0: sample.errors.append("Route time scale changed.")
	for message in sample.errors: route_check(false,str(message))
	tlv_last_submission=sample

func observe_tlv_post() -> void:
	if tlv_last_submission.is_empty() or tlv_file==null: return
	var row := tlv_last_submission.duplicate(true)
	row.post_draw_frame=Engine.get_frames_drawn()
	row.phase=driver.phase if is_instance_valid(driver) else "warmup"
	row.route_active=is_instance_valid(driver) and not driver.finished
	if bool(row.route_active):
		row.simulation_seconds=driver.sim
		row.case_wall_seconds=driver.wall_seconds()
		row.feet=driver.v3(scene.player.global_position)
		tlv_row.route_draws+=1
		if bool(row.active): tlv_row.active_route_draws+=1
		else: tlv_row.fallback_route_draws+=1
		var key := "inside" if bool(row.inside) else "outside"
		tlv_row.house_state_draws[key]=int(tlv_row.house_state_draws.get(key,0))+1
		if bool(row.active):
			tlv_row.active_house_state_draws[key]=int(tlv_row.active_house_state_draws.get(key,0))+1
			if str(row.phase).begins_with("move_"): tlv_row.active_moving_draws+=1
			if int(row.house_generation)>=2 and not bool(row.inside): tlv_row.active_after_exit_draws+=1
	if int(row.frame)!=int(row.post_draw_frame): route_check(false,"Pre/post draw frame correlation mismatch.")
	tlv_file.store_line(JSON.stringify(row))
	tlv_row.draws+=1

func stop_route_producer() -> void:
	if RenderingServer.frame_pre_draw.is_connected(observe_tlv_pre): RenderingServer.frame_pre_draw.disconnect(observe_tlv_pre)
	if RenderingServer.frame_post_draw.is_connected(observe_tlv_post): RenderingServer.frame_post_draw.disconnect(observe_tlv_post)
	if is_instance_valid(producer):
		producer.stop("Completed real-input house route.")
		var closed := false
		for frame in 90:
			await process_frame
			var result: Dictionary=producer.drain_shutdown()
			if bool(result.closed): closed=true; break
		route_check(closed,"Route producer GPU cleanup did not acknowledge closed.")
		route_check(producer.report.status=="stopped","Route producer reported restore conflict.")
		for kind in ["receiver","caster","probe"]:
			route_check(producer.report.stop[kind].errors.is_empty(),"Route "+kind+" restoration failed.")
		tlv_row.producer=producer.report.duplicate(true)
		producer.queue_free()
		producer=null
	if tlv_file!=null: tlv_file.flush(); tlv_file=null

func run() -> void:
	if output.is_empty() or tlv_mode not in ["baseline","receiver"]: quit(2); return
	DirAccess.make_dir_recursive_absolute(output)
	if not _start_backend_observer(): save_report(); quit(2); return
	root.size=Vector2i(1280,720)
	root.content_scale_size=Vector2i(1280,720)
	var cases: Array=[
		{"name":"wuming_house","map":"wuming","start":[-79.8,3.5,38.231],"path":[point(-75.6,4.4,38.231,3.0),point(-79.8,3.5,38.231,3.0)],"expected_house_transitions":2},
		{"name":"youxian_house","map":"youxian","start":[-54.99952,3.3729863,44.87575],"path":[point(-51.34952,3.920986,44.87575,3.0),point(-54.99952,3.3729863,44.87575,3.0)],"expected_house_transitions":2}]
	if not selected_case.is_empty(): cases=cases.filter(func(item: Dictionary) -> bool: return item.name==selected_case)
	if cases.is_empty(): report.failures.append("Unknown house case."); save_report(); quit(2); return
	report.tlv_route={"mode":tlv_mode,"cases":[],"scope":"Original continuous input routes with real-time receiver state observation. CPU material submissions are not GPU fragment epoch evidence. Timing includes this observer; not production benchmarking."}
	scene=load("res://worlds.tscn").instantiate()
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
		var directory := output.path_join(definition.name)
		DirAccess.make_dir_recursive_absolute(directory)
		tlv_file=FileAccess.open(directory.path_join("tlv-draw.jsonl"),FileAccess.WRITE)
		if tlv_file==null:
			report.failures.append("Could not create TLV draw evidence file.")
			break
		tlv_start_usec=Time.get_ticks_usec()
		tlv_row={"name":definition.name,"mode":tlv_mode,"draws":0,"route_draws":0,"active_route_draws":0,"fallback_route_draws":0,"house_state_draws":{},"active_house_state_draws":{},"active_moving_draws":0,"active_after_exit_draws":0,"initial_inside":scene.house_driver.is_in_house}
		tlv_last_submission={}
		if tlv_mode=="receiver":
			producer=preload("res://source_tlv_realtime/realtime_sun.gd").new()
			root.add_child(producer)
			var installed: Dictionary=producer.install(scene,definition.map,{"enable_receiver":true,"max_age_frames":8})
			route_check(installed.get("status")!="failed","Route producer installation failed: "+str(installed))
			if installed.get("status")=="failed":
				producer.queue_free(); producer=null
				tlv_file.flush(); tlv_file=null
				break
		RenderingServer.frame_pre_draw.connect(observe_tlv_pre)
		RenderingServer.frame_post_draw.connect(observe_tlv_post)
		if is_instance_valid(producer):
			for i in 180:
				await process_frame
				if int(producer.report.published)>=4 or producer.report.status in ["stopped","restore_conflict"]: break
			route_check(int(producer.report.published)>=4,"Route warmup did not publish four fresh pairs.")
			if int(producer.report.published)<4:
				await stop_route_producer()
				report.tlv_route.cases.append(tlv_row.duplicate(true))
				break
		driver=FollowDriver.new()
		driver.scene=scene
		driver.definition=definition
		driver.directory=directory
		driver.capture_png=false
		driver.begin()
		root.add_child(driver)
		while not driver.finished: await process_frame
		driver.finish()
		var row: Dictionary=driver.row
		route_check(row.status=="complete",definition.name+": route timeout")
		route_check(row.below_support_ticks==0 and row.support_missing_ticks==0,definition.name+": support violation")
		route_check(row.house_transitions.size()==2,definition.name+": expected actual house enter and exit")
		if row.house_transitions.size()==2:
			route_check(bool(row.house_transitions[0].inside) and not bool(row.house_transitions[1].inside),definition.name+": expected enter-then-exit transition order")
		route_check(not bool(tlv_row.initial_inside) and not bool(scene.house_driver.is_in_house),definition.name+": route must begin and end outdoors")
		route_check(tlv_row.house_state_draws.has("inside") and tlv_row.house_state_draws.has("outside"),definition.name+": missing rendered house state")
		if tlv_mode=="receiver":
			route_check(int(tlv_row.active_house_state_draws.get("inside",0))>0 and int(tlv_row.active_house_state_draws.get("outside",0))>0,definition.name+": receiver must be freshly active inside and outside")
			route_check(tlv_row.active_moving_draws>0,definition.name+": receiver never active during actual movement")
			route_check(tlv_row.active_after_exit_draws>0,definition.name+": receiver never republished fresh outdoor lighting after exit")
		await stop_route_producer()
		report.cases.append(row)
		report.tlv_route.cases.append(tlv_row.duplicate(true))
		save_report()
		print("REALTIME_HOUSE_ROUTE_CASE ",JSON.stringify({"case":definition.name,"status":row.status,"transitions":row.house_transitions.size(),"active_draws":tlv_row.active_route_draws,"fallback_draws":tlv_row.fallback_route_draws}))
		driver.queue_free()
		await process_frame
	scene.queue_free()
	for i in 5: await process_frame
	report.status="observed" if report.failures.is_empty() else "failed"
	save_report()
	quit(0 if report.failures.is_empty() else 1)
