extends SceneTree
## Parent-run actual-map verification; this script never writes source assets.
## Coordinate probes and physically walked routes are reported separately.
const CameraScript = preload("res://scripts/original_camera.gd")
var failures: Array[String] = []
var maps: Array[Dictionary] = []
var texture_hashes: Dictionary = {}
var output_path := ""
var walk_routes := true
const GROUND_MIN_Y := 2.0
const GROUND_MAX_Y := 8.0
const GROUND_GRID_STEP := 0.75
var ground_reachable: Dictionary = {}
var ground_predecessor: Dictionary = {}
var ground_origin := Vector3.ZERO

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--native-report="):
			output_path = argument.trim_prefix("--native-report=")
		elif argument == "--native-skip-walks":
			walk_routes = false
	call_deferred("_run")

func _run() -> void:
	var scene: Node3D = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	# A generic review runner may pass --tour. This validation owns motion;
	# external tour teleports invalidate all continuous-route evidence.
	scene.tour.clear()
	scene.tour_path = ""
	scene.tour_finished = true
	scene.capture_path = ""
	scene.motion_frames = ""
	for i in 1200:
		await physics_frame
		if is_instance_valid(scene.foreground_driver) and not scene.loading:
			break
	if not is_instance_valid(scene.foreground_driver):
		_fail("first actual map failed to load")
		_finish()
		return
	for slug in ["wuming", "youxian"]:
		if scene.slug != slug:
			await scene._load_world(slug)
		scene.tour.clear()
		scene.tour_finished = true
		var player: CharacterBody3D = scene.player
		var camera: Camera3D = scene.camera
		var foreground: Node = scene.foreground_driver
		player.set_review_motion(Vector2.ZERO)
		scene.house_driver.reset_outdoors()
		var record := {"map":slug,"binding":foreground.report.duplicate(true),"materials":[],
			"camera_coordinate_probes":[],"camera_continuous_walks":[],"foreground_walk":{}}
		_check(foreground.bound_count == (42 if slug=="youxian" else 0),slug+": expected original fade target count")
		_check(foreground.report.missing_actors.is_empty(),slug+": all native fade actors bound")
		_check(foreground.report.unsupported_materials.is_empty(),slug+": no unsupported fade materials")
		_check(foreground.report.enabled_fade_surfaces==(41 if slug=="youxian" else 0),slug+": compiled static switch enables exactly41 fades")
		_check(camera.source_bounds.size() == (3 if slug=="wuming" else 2),slug+": all source camera bounds configured")
		var seen: Dictionary = {}
		for entry in foreground.entries:
			var mesh: MeshInstance3D = entry.node
			var material: ShaderMaterial = entry.material
			var before: ShaderMaterial = entry.before_material
			var material_record := {"actor":entry.actor,"parameter_checks":0,"null_parameters":0,"mismatches":[],
				"wind_before":bool(material.get_meta("source_foreground_before_wind",false)),
				"surface_before":bool(material.get_meta("source_foreground_before_surface",false)),
				"isolated_slot0":material!=before,"same_mesh":mesh.mesh==entry.source_mesh}
			_check(not seen.has(entry.actor),slug+": duplicate effective actor "+str(entry.actor))
			seen[entry.actor]=true
			_check(material!=before,str(entry.actor)+": slot0 has isolated dynamic material")
			_check(mesh.mesh==entry.source_mesh,str(entry.actor)+": imported geometry unchanged")
			_check(is_zero_approx(mesh.transparency),str(entry.actor)+": no whole-mesh transparency override")
			for slot in entry.untouched_slots:
				_check(mesh.get_active_material(int(slot))==entry.untouched_slots[slot],str(entry.actor)+": other slot unchanged")
			var baseline: Dictionary=material.get_meta("source_foreground_parameter_baseline",{})
			for name in baseline:
				var value: Variant=baseline[name]
				if value==null:
					material_record.null_parameters+=1
					continue
				material_record.parameter_checks+=1
				if material.get_shader_parameter(name)!=value or before.get_shader_parameter(name)!=value:
					material_record.mismatches.append(name)
				if value is Texture2D:
					_hash_texture(value)
			_check(material_record.mismatches.is_empty(),str(entry.actor)+": wind/surface parameters retained in copy and shared original")
			var code: String=material.shader.code
			if entry.fade_enabled:
				_check(code.contains("source_foreground_visibility") and code.contains("fade_pattern"),str(entry.actor)+": compiled fade shader retained after all drivers")
				_hash_texture(material.get_shader_parameter("source_foreground_noise") as Texture2D)
			else:
				_check(not code.contains("source_foreground_visibility"),str(entry.actor)+": compiled-out fade remains disabled")
			if material_record.wind_before:
				_check(material.has_meta("source_wind_adapter") and code.contains("void vertex()") and code.contains("wind_intensity"),str(entry.actor)+": wind vertex program preserved")
			if material_record.surface_before:
				_check(code.contains("source_surface_mode"),str(entry.actor)+": source surface formula preserved")
			material_record.lightfunction_bound=material.has_meta("source_lightfunction_adapter")
			material_record.shader_values_verified=material_record.parameter_checks>0
			record.materials.append(material_record)
		var saved_position: Vector3=player.global_position
		player.set_physics_process(false)
		for entry in camera.source_bounds:
			var radius: float=player.get_node("MovementCapsule").shape.radius
			var halfheight: float=player.get_node("MovementCapsule").shape.height*0.5
			var axis: int=CameraScript._direction_axis(entry.direction)
			player.global_position=entry.center-Vector3.UP*halfheight
			camera._reset_source_overlap_state()
			camera._sample_source_bounds()
			var expected: float=CameraScript.source_lock_value(entry,radius,halfheight)
			_check(camera.source_axis_locked[axis],str(entry.source_name)+": actual rig locks at source brush center")
			_check(absf(camera.source_axis_values[axis]-expected)<.0001,str(entry.source_name)+": exact source lock value")
			camera.reset_at(player.get_camera_anchor())
			var rotation_before: Vector3=camera.rotation
			var camera_before: Vector3=camera.global_position
			for sample in 30:
				camera.advance(1.0/60.0,player.get_camera_anchor())
			_check(camera.rotation.distance_to(rotation_before)<.00001,str(entry.source_name)+": no rotational bob at rest")
			_check(camera.global_position.distance_to(camera_before)<.00001,str(entry.source_name)+": no periodic translation at rest")
			player.global_position=Vector3(10000,10000,10000)
			camera._sample_source_bounds()
			_check(not camera.source_axis_locked[axis],str(entry.source_name)+": actual rig unlocks after exit")
			record.camera_coordinate_probes.append({"source":entry.source_name,"axis":axis,"expected_lock_m":expected,
				"source_center_m":_v(entry.center),"mode":"explicit driver coordinate probe, not a walkability test"})
		player.global_position=saved_position
		player.set_physics_process(true)
		camera.reset_at(player.get_camera_anchor())
		if walk_routes:
			record.ground_connectivity=_build_ground_reachability(player,scene.initial_focus)
			for entry in camera.source_bounds:
				var route: Dictionary=_find_camera_route(player,entry)
				if route.is_empty():
					record.camera_continuous_walks.append({"source":entry.source_name,"status":"no supported short crossing found near source border; not teleported through"})
					continue
				route.source=entry.source_name
				route.axis=CameraScript._direction_axis(entry.direction)
				var result: Dictionary=await _walk_camera_route(scene,route)
				record.camera_continuous_walks.append(result)
			if slug=="youxian":
				record.foreground_walk=await _walk_foreground_route(scene)
		maps.append(record)
	for path in texture_hashes:
		var before_hash: String=texture_hashes[path]
		_check(FileAccess.get_sha256(path)==before_hash,"source texture unchanged on disk: "+path)
	scene.queue_free()
	await process_frame
	_finish()

func _find_camera_route(player: CharacterBody3D, entry: Dictionary) -> Dictionary:
	var radius: float=player.get_node("MovementCapsule").shape.radius
	var halfheight: float=player.get_node("MovementCapsule").shape.height*.5
	var axis: int=CameraScript._direction_axis(entry.direction)
	if axis==1: return {}
	var other:=2 if axis==0 else 0
	var boundary: float=CameraScript.source_lock_value(entry,radius,halfheight)
	var toward:=1.0 if str(entry.direction)=="Left" else -1.0
	var max_offset: float=maxf(entry.world_extent[other]-1.0,0.0)
	for offset in _offsets(max_offset,3.0):
		var start: Vector3=entry.origin
		start[axis]=boundary-toward*1.2
		start[other]+=offset
		var end:=start
		end[axis]=boundary+toward*1.2
		var route:=_supported_route(player,start,end)
		if not route.is_empty():
			return route
	return {}

func _supported_route(player: CharacterBody3D,start: Vector3,end: Vector3) -> Dictionary:
	# Query ordinary player ground only. Actor roots can be29m up in canopy;
	# starting above them can incorrectly select treetops or roof geometry.
	var probe:=Vector3(start.x,GROUND_MAX_Y,start.z)
	var first: Dictionary=player._support_at(probe,0.0,GROUND_MAX_Y-GROUND_MIN_Y)
	if first.is_empty(): return {}
	start.y=first.position.y
	var connectivity: Dictionary=_ground_connection(player,start)
	if connectivity.is_empty(): return {}
	var last_height:=start.y
	for step in range(1,9):
		var sample:=start.lerp(end,float(step)/8.0)
		sample.y=last_height
		var support: Dictionary=player._support_at(sample,.4,.6)
		if support.is_empty() or absf(support.position.y-last_height)>.28 or support.position.y<GROUND_MIN_Y or support.position.y>GROUND_MAX_Y:
			return {}
		last_height=support.position.y
	end.y=last_height
	return {"start":start,"end":end,"source_position":start+Vector3.UP*.96,"connection_to_dock":connectivity}

func _build_ground_reachability(player: CharacterBody3D,source_spawn: Vector3) -> Dictionary:
	ground_reachable.clear()
	ground_predecessor.clear()
	var initial: Dictionary=player._support_at(source_spawn,2.0,12.0)
	if initial.is_empty(): return {"status":"original spawn has no support","cells":0}
	ground_origin=Vector3(source_spawn.x,initial.position.y,source_spawn.z)
	ground_reachable[Vector2i.ZERO]=ground_origin
	var queue: Array[Vector2i]=[Vector2i.ZERO]
	var visited: Dictionary={Vector2i.ZERO:true}
	var cursor:=0
	while cursor<queue.size() and ground_reachable.size()<15000:
		var cell: Vector2i=queue[cursor]
		cursor+=1
		var foot: Vector3=ground_reachable[cell]
		for step in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
			var next: Vector2i=cell+step
			if visited.has(next): continue
			var point:=Vector3(ground_origin.x+float(next.x)*GROUND_GRID_STEP,foot.y,ground_origin.z+float(next.y)*GROUND_GRID_STEP)
			var next_foot: Variant=_ground_segment(player,foot,point)
			if next_foot==null: continue
			visited[next]=true
			ground_reachable[next]=next_foot
			ground_predecessor[next]=cell
			queue.append(next)
	return {"status":"capped" if ground_reachable.size()>=15000 else "completed","cells":ground_reachable.size(),
		"spawn_foot":_v(ground_origin),"ground_height_range_m":[GROUND_MIN_Y,GROUND_MAX_Y],"grid_step_m":GROUND_GRID_STEP,
		"method":"flood from original dock spawn; 0.25m supporting substeps and existing capsule sweeps; no generated collision"}

func _ground_segment(player: CharacterBody3D,start: Vector3,end: Vector3) -> Variant:
	var current:=start
	var distance:=Vector2(end.x-start.x,end.z-start.z).length()
	var count:=maxi(1,ceili(distance/.25))
	for i in range(1,count+1):
		var next:=start.lerp(end,float(i)/float(count))
		next.y=current.y
		var support: Dictionary=player._support_at(next,.22,.27)
		if support.is_empty() or support.position.y<GROUND_MIN_Y or support.position.y>GROUND_MAX_Y: return null
		next.y=support.position.y
		var from:=Transform3D(player.global_basis,current+Vector3.UP*.025)
		var motion:=next-current
		if player.test_move(from,motion,null,.0001):
			var step_lift:=Vector3.UP*.205
			if player.test_move(from,step_lift,null,.0001): return null
			from.origin+=step_lift
			if player.test_move(from,motion,null,.0001): return null
		current=next
	return current

func _ground_connection(player: CharacterBody3D,point: Vector3) -> Dictionary:
	var cell:=Vector2i(roundi((point.x-ground_origin.x)/GROUND_GRID_STEP),roundi((point.z-ground_origin.z)/GROUND_GRID_STEP))
	for dx in range(-1,2):
		for dz in range(-1,2):
			var candidate:=cell+Vector2i(dx,dz)
			if not ground_reachable.has(candidate): continue
			var foot: Vector3=ground_reachable[candidate]
			if absf(foot.y-point.y)>.5: continue
			var connected: Variant=_ground_segment(player,foot,point)
			if connected==null or absf(connected.y-point.y)>.1: continue
			var path: Array=[]
			var cursor:=candidate
			while ground_reachable.has(cursor):
				path.append(_v(ground_reachable[cursor]))
				if cursor==Vector2i.ZERO: break
				cursor=ground_predecessor[cursor]
			path.reverse()
			return {"source":"original dock-connected support graph","steps":path.size(),"path_m":path}
	return {}

func _walk_camera_route(scene: Node3D,route: Dictionary) -> Dictionary:
	var player: CharacterBody3D=scene.player
	var camera: Camera3D=scene.camera
	scene.house_driver.reset_outdoors()
	var placed: bool=player.place_at_source_actor_position(route.source_position)
	var result: Dictionary={"source":route.source,"source_position":_v(route.source_position),"destination":_v(route.end),
		"placed_on_support":placed,"connection_to_dock":route.connection_to_dock,"forward":{},"return":{}}
	if not placed:
		result.status="initial supported placement failed"
		return result
	camera.reset_at(player.get_camera_anchor())
	var forward: Dictionary=await _walk_to(player,camera,route.end,int(route.axis))
	player.set_review_motion(Vector2.ZERO)
	for frame in 20: await physics_frame
	var returning: Dictionary=await _walk_to(player,camera,route.start,int(route.axis))
	player.set_review_motion(Vector2.ZERO)
	for frame in 20: await physics_frame
	result.forward=forward
	result["return"]=returning
	result.unlocked_after_return=not camera.source_axis_locked[int(route.axis)]
	result.status="walked" if forward.reached and returning.reached else "blocked_by_actual_collision"
	# Collision-blocked candidates are reported honestly, not counted as proof
	# of the overlap mechanism. Successful walks must observe both transitions.
	if forward.reached and returning.reached:
		_check(forward.saw_locked,str(route.source)+": continuous crossing observed native lock")
		_check(result.unlocked_after_return,str(route.source)+": continuous return released native lock")
	return result

func _walk_to(player: CharacterBody3D,camera: Camera3D,destination: Vector3,axis: int) -> Dictionary:
	var result: Dictionary={"reached":false,"saw_locked":false,"samples":[],"blocked_frames":0}
	for frame in 180:
		var delta:=destination-player.global_position
		delta.y=0
		if delta.length()<.16:
			result.reached=true
			break
		var controls:=Vector2(delta.z,-delta.x).normalized()
		player.set_review_motion(controls)
		await physics_frame
		result.saw_locked=result.saw_locked or bool(camera.source_axis_locked[axis])
		if player.blocked_at_edge: result.blocked_frames+=1
		if frame%6==0:
			result.samples.append({"frame":frame,"feet":_v(player.global_position),"camera":_v(camera.global_position),"locked":camera.source_axis_locked.duplicate()})
	player.set_review_motion(Vector2.ZERO)
	result.end_feet=_v(player.global_position)
	return result

func _walk_foreground_route(scene: Node3D) -> Dictionary:
	var foreground: Node=scene.foreground_driver
	var player: CharacterBody3D=scene.player
	for entry in foreground.entries:
		if not entry.fade_enabled: continue
		var root_ue: Vector3=entry.root_ue_cm
		var boundary: float=(root_ue.x+float(entry.x_axis_ue_cm))*.01
		var lateral_range: float=minf(12.0,entry.mini_range_ue_cm.y*.01-.5)
		for offset in _offsets(lateral_range,2.0):
			var start:=Vector3(boundary-1.2,root_ue.z*.01,root_ue.y*.01+offset)
			var end:=start+Vector3(2.4,0,0)
			var route:=_supported_route(player,start,end)
			if route.is_empty(): continue
			scene.house_driver.reset_outdoors()
			if not player.place_at_source_actor_position(route.source_position): continue
			scene.camera.reset_at(player.get_camera_anchor())
			player.set_review_motion(Vector2.ZERO)
			for frame in 60: await physics_frame
			var before: float=entry.visibility
			var forward: Dictionary=await _walk_to(player,scene.camera,route.end,0)
			for frame in 60: await physics_frame
			var during: float=entry.visibility
			var returning: Dictionary=await _walk_to(player,scene.camera,route.start,0)
			for frame in 60: await physics_frame
			var after: float=entry.visibility
			var result: Dictionary={"actor":entry.actor,"source_rule":entry.source,"source_position":_v(route.source_position),
				"destination":_v(route.end),"visibility_before":before,"visibility_inside":during,"visibility_after":after,
				"connection_to_dock":route.connection_to_dock,"forward":forward,"return":returning,"status":"walked" if forward.reached and returning.reached else "blocked_by_actual_collision"}
			if forward.reached and returning.reached:
				_check(before>.95 and during<.05 and after>.95,str(entry.actor)+": continuous original threshold hide/restore")
			return result
	return {"status":"no supported short foreground crossing found; not teleported through"}

func _offsets(maximum: float,step: float) -> Array[float]:
	var result: Array[float]=[0.0]
	for i in range(1,ceili(maximum/step)+1):
		var value:=minf(float(i)*step,maximum)
		result.append(value)
		result.append(-value)
	return result

func _hash_texture(texture: Texture2D) -> void:
	if texture==null: return
	var path:=texture.resource_path
	if path.is_empty() or texture_hashes.has(path) or not FileAccess.file_exists(path): return
	texture_hashes[path]=FileAccess.get_sha256(path)

func _check(value: bool,message: String) -> void:
	if not value: _fail(message)

func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)

func _finish() -> void:
	var output: Dictionary={"passed":failures.is_empty(),"failures":failures,"maps":maps,
		"source_texture_hashes":texture_hashes,"renderer":DisplayServer.get_name(),
		"supersedes":"Early native-validation continuous routes invalidated: external --tour reset player and an actor-height ray selected29m canopy. Those walks are discarded, not proof.",
		"scope":"driver coordinates and actual collisions separate; source material values require GPU renderer, headless nulls are reported unverified"}
	print("ORIGINAL_NATIVE_VERIFICATION ",JSON.stringify(output))
	if not output_path.is_empty():
		var file:=FileAccess.open(output_path,FileAccess.WRITE)
		if file!=null: file.store_string(JSON.stringify(output,"\t"))
	quit(0 if failures.is_empty() else 1)

func _v(value: Vector3) -> Array:
	return [value.x,value.y,value.z]
