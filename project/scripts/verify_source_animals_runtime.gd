extends SceneTree
## Review-only entry point. Run with the REAL project and a real GPU renderer.
## It loads worlds.tscn, observes every selected animal, changes review camera
## positions, and moves the hero only for an explicit approach/depart test.

var output := ""
var duration := 60.0
var level: Node3D
var behavior: Node
var ambient: Node3D
var starts: Dictionary = {}
var checks: Dictionary = {}
var rows: Dictionary = {}
var elapsed := 0.0
var sampling := 0.0
var next_shot := 0
var shots: Array[Dictionary] = []
var approached := false
var departed := false
var flee_actor: Dictionary = {}
var hero_start := Vector3.ZERO
var tick_count := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--animal-out="):
			output = arg.trim_prefix("--animal-out=")
		elif arg.begins_with("--animal-duration="):
			duration = float(arg.trim_prefix("--animal-duration="))
	if output.is_empty():
		push_error("Supply --animal-out=<absolute output directory>")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output)
	call_deferred("_run")

func _run() -> void:
	level = load("res://worlds.tscn").instantiate()
	root.add_child(level)
	var waited := 0.0
	while waited < 150.0:
		await create_timer(0.2).timeout
		waited += 0.2
		if level.world==null or level.loading:
			continue
		for child in level.world.get_children():
			if child.get_script()!=null and child.get_script().resource_path.ends_with("source_animal_behavior.gd"):
				behavior=child
		if behavior!=null and behavior.startup_ticks==0:
			break
	if behavior==null:
		push_error("Animal behavior was not integrated or world did not load")
		quit(3)
		return
	ambient = behavior.ambient
	behavior.rng.seed = 20261125
	level.inspection = true
	level.camera.inspection = true
	level.player.input_enabled = false
	level.player.set_physics_process(false)
	hero_start = level.player.global_position
	level.player.global_position = Vector3(9000,9000,9000)
	checks = {"map":level.slug,"renderer":RenderingServer.get_current_rendering_method(),"expected_active":0,"expected_components":[],"source_tree_without_nav":[],"ticks":0,"pivot_errors":[],"atlas_errors":[],"without_tree_moved":[],"fish_ground_flag":[],"fish_anchor_offset_max":0.0,"ground_anchor_offset_max":0.0,"ground_support_samples":0,"ground_support_gap_max":0.0,"surface_failure_start":behavior.report.surface_failures,"only_observed_source_routes":true,"full_map_traversal_verified":false,"approach_depart_test":"actual hero repositioned for review only","captures":[]}
	for entry in ambient.sprites:
		var d: Dictionary=entry.definition
		if not d.is_npc or bool(d.get("is_human",false)):
			continue
		var id:=int(d.component)
		var cfg: Dictionary=behavior.source.npcs.get(str(int(d.npc_id)),{})
		var tree:=str(cfg.get("tree","None")).get_file().get_slice(".",0)
		if tree!="None" and not tree.is_empty():
			var matrix: Array=d.matrix_ue
			var authored:=Vector3(float(matrix[0][3]),float(matrix[2][3]),float(matrix[1][3]))*0.01
			var source_anchor: Dictionary=behavior.navigation.project(authored)
			if source_anchor.is_empty():
				checks.source_tree_without_nav.append(id)
			else:
				checks.expected_active+=1
				checks.expected_components.append(id)
		starts[id]=entry.holder.global_position
		rows[id]={"npc":int(d.npc_id),"source_animation":str(entry.sprite.animation),"animations":{},"frames":{},"max_displacement":0.0,"animation_changes":0,"last_animation":str(entry.sprite.animation),"needs_ground_after_start":entry.needs_ground,"support_gap_max":0.0,"support_gap_event":{}}
	for actor in behavior.actors:
		rows[actor.component].source_anchor_offset=actor.height_offset
		rows[actor.component].resource=actor.cfg.resource
		rows[actor.component].tree=actor.tree
		rows[actor.component].initial_actor_position=_vec(actor.holder.global_position)
		rows[actor.component].initial_nav_position=_vec(actor.anchor.point)
		if actor.tree=="BT_RunAway" and (flee_actor.is_empty() or actor.cfg.resource=="HouZi"):
			flee_actor=actor
	var candidates: Dictionary={}
	for actor in behavior.actors:
		if not candidates.has(actor.tree):
			candidates[actor.tree]=actor
	var first: Dictionary=candidates.get("BT_Yu",candidates.get("BT_Bird_2",behavior.actors[0]))
	shots=[{"time":1.0,"label":"source_animation","actor":first},{"time":8.0,"label":"local_patrol","actor":flee_actor},{"time":17.0,"label":"hero_approach","actor":flee_actor},{"time":27.0,"label":"hero_departed","actor":flee_actor},{"time":40.0,"label":"specific_tree","actor":candidates.get("BT_TuZi",candidates.get("BT_Bird_2",first))},{"time":55.0,"label":"final_source_routes","actor":first}]
	if candidates.has("BT_YeYa"):
		shots.push_front({"time":0.4,"label":"duck-source-pose-dof-disabled","actor":candidates.BT_YeYa,"close":true})
		shots.insert(2,{"time":6.5,"label":"duck-short-swim-dof-disabled","actor":candidates.BT_YeYa,"close":true})
	while elapsed<duration:
		await physics_frame
		var delta:=root.get_physics_process_delta_time()
		elapsed+=delta
		tick_count+=1
		if elapsed>=15.0 and not approached:
			approached=true
			level.player.global_position=flee_actor.holder.global_position+Vector3(0,0,0.8)
			checks.approach_component=flee_actor.component
		if elapsed>=23.0 and not departed:
			departed=true
			checks.seen_before_depart=flee_actor.seen_hero
			level.player.global_position=Vector3(9000,9000,9000)
		_sample()
		if next_shot<shots.size() and elapsed>=float(shots[next_shot].time):
			var shot: Dictionary=shots[next_shot]
			await _capture(shot,next_shot)
			next_shot+=1
	checks.ticks=tick_count
	checks.active=behavior.actors.size()
	checks.active_matches_source=checks.active==checks.expected_active
	checks.rows=rows
	checks.duration_seconds=elapsed
	checks.seen_after_depart=flee_actor.seen_hero
	checks.behavior_report=behavior.report
	checks.moved=0
	for row in rows.values():
		if float(row.max_displacement)>0.1:
			checks.moved+=1
	var f:=FileAccess.open(output+"/"+level.slug+"-animal-review.json",FileAccess.WRITE)
	f.store_string(JSON.stringify(checks,"\t"))
	f.close()
	print("SOURCE_ANIMAL_GPU_REVIEW ",JSON.stringify({"map":level.slug,"active":checks.active,"moved":checks.moved,"pivot_errors":checks.pivot_errors.size(),"atlas_errors":checks.atlas_errors.size(),"static_moved":checks.without_tree_moved.size(),"fish_offset_max":checks.fish_anchor_offset_max,"seen_after_depart":checks.seen_after_depart,"full_map_traversal_verified":false,"output":output}))
	quit()

func _capture(shot: Dictionary, index: int) -> void:
	var camera: Camera3D=level.camera
	var close:=bool(shot.get("close",false))
	var previous: Dictionary={"transform":camera.global_transform,"zoom":camera.zoom,"tracked":camera.tracked,"follow":camera.follow_target,"bounds":camera.source_bounds.duplicate(true),"axis_locked":camera.source_axis_locked.duplicate(),"axis_values":camera.source_axis_values,"bounds_report":camera.source_bounds_report.duplicate(true)}
	var attributes:=camera.attributes as CameraAttributesPractical
	var near_enabled:=attributes.dof_blur_near_enabled if attributes!=null else false
	var far_enabled:=attributes.dof_blur_far_enabled if attributes!=null else false
	var dof_owner: Variant=camera.get_meta("source_dof_owner") if camera.has_meta("source_dof_owner") else null
	var dof_effect: CompositorEffect=dof_owner.get("effect") if is_instance_valid(dof_owner) else null
	var effect_enabled:=dof_effect.enabled if dof_effect!=null else false
	if close:
		if attributes!=null:
			attributes.dof_blur_near_enabled=false
			attributes.dof_blur_far_enabled=false
		if dof_effect!=null:
			dof_effect.enabled=false
	camera.source_bounds.clear()
	camera.follow_target=null
	camera.reset_at(shot.actor.holder.global_position+Vector3.UP*(0.4 if close else 0.6))
	if close:
		camera.zoom=0.22
		camera._apply_pose()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var path:=output+"/%s-%02d-%s.png" % [level.slug,index,shot.label]
	root.get_texture().get_image().save_png(path)
	var capture: Dictionary={"path":path,"elapsed":elapsed,"component":shot.actor.component,"tree":shot.actor.tree,"actor_position":_vec(shot.actor.holder.global_position),"camera_position":_vec(camera.global_position),"zoom":camera.zoom,"animation":str(shot.actor.sprite.animation),"frame":shot.actor.sprite.frame,"inspection_dof_disabled":close,"hdr_dof_present":dof_effect!=null,"hdr_dof_enabled_at_capture":dof_effect.enabled if dof_effect!=null else false}
	if attributes!=null:
		attributes.dof_blur_near_enabled=near_enabled
		attributes.dof_blur_far_enabled=far_enabled
	if dof_effect!=null:
		dof_effect.enabled=effect_enabled
	camera.zoom=previous.zoom
	camera.tracked=previous.tracked
	camera.follow_target=previous.follow
	camera.source_bounds=previous.bounds
	camera.source_axis_locked=previous.axis_locked
	camera.source_axis_values=previous.axis_values
	camera.source_bounds_report=previous.bounds_report
	camera.global_transform=previous.transform
	capture.dof_restored=(attributes==null or (attributes.dof_blur_near_enabled==near_enabled and attributes.dof_blur_far_enabled==far_enabled)) and (dof_effect==null or dof_effect.enabled==effect_enabled)
	checks.captures.append(capture)

func _sample() -> void:
	for entry in ambient.sprites:
		var d: Dictionary=entry.definition
		if not d.is_npc or bool(d.get("is_human",false)):
			continue
		var id:=int(d.component)
		var sprite: AnimatedSprite3D=entry.sprite
		var row: Dictionary=rows[id]
		row.max_displacement=maxf(row.max_displacement,entry.holder.global_position.distance_to(starts[id]))
		if str(sprite.animation)!=str(row.last_animation):
			row.animation_changes+=1
			row.last_animation=str(sprite.animation)
		row.animations[str(sprite.animation)]=true
		row.frames[str(sprite.animation)+":"+str(sprite.frame)]=true
		var frame: Dictionary=ambient.manifest.flipbooks[str(sprite.animation)].frames[sprite.frame]
		var src: Dictionary=ambient.manifest.sprites[frame.sprite]
		var unit:=0.01/float(src.ppu)
		var desired:=Vector3((float(src.region[2])*0.5-float(src.pivot[0]))*unit,(float(src.pivot[1])-float(src.region[3])*0.5)*unit,0)
		if sprite.position.distance_to(desired)>0.0001 or absf(sprite.pixel_size-unit)>0.000001:
			if checks.pivot_errors.size()<20:
				checks.pivot_errors.append({"component":id,"animation":str(sprite.animation),"frame":sprite.frame,"error":sprite.position.distance_to(desired)})
		var atlas:=sprite.sprite_frames.get_frame_texture(sprite.animation,sprite.frame) as AtlasTexture
		if atlas==null or atlas.region!=Rect2(float(src.region[0]),float(src.region[1]),float(src.region[2]),float(src.region[3])) or (not atlas.atlas.resource_path.is_empty() and atlas.atlas.resource_path.get_file()!=str(src.texture_file)):
			if checks.atlas_errors.size()<20:
				checks.atlas_errors.append({"component":id,"animation":str(sprite.animation),"frame":sprite.frame})
		var cfg: Dictionary=behavior.source.npcs[str(int(d.npc_id))]
		if cfg.tree=="None" and row.max_displacement>0.0001 and not id in checks.without_tree_moved:
			checks.without_tree_moved.append(id)
	for actor in behavior.actors:
		if actor.initial_connector:
			continue
		var offset_error:=absf(actor.holder.global_position.y-actor.anchor.point.y-float(actor.height_offset))
		if actor.fish or actor.tree=="BT_YeYa":
			checks.fish_anchor_offset_max=maxf(checks.fish_anchor_offset_max,offset_error)
			if bool(rows[actor.component].needs_ground_after_start) and not actor.component in checks.fish_ground_flag:
				checks.fish_ground_flag.append(actor.component)
		else:
			checks.ground_anchor_offset_max=maxf(checks.ground_anchor_offset_max,offset_error)
			if tick_count%15==0:
				var pos: Vector3=actor.holder.global_position
				var ray:=PhysicsRayQueryParameters3D.create(pos+Vector3.UP*0.6,pos-Vector3.UP*1.2,4)
				var hit:=level.get_world_3d().direct_space_state.intersect_ray(ray)
				if not hit.is_empty():
					checks.ground_support_samples+=1
					var gap:=absf(pos.y-hit.position.y)
					checks.ground_support_gap_max=maxf(checks.ground_support_gap_max,gap)
					var row: Dictionary=rows[actor.component]
					if gap>float(row.support_gap_max):
						row.support_gap_max=gap
						var collider: Node=hit.collider
						row.support_gap_event={"elapsed":elapsed,"position":_vec(pos),"support_position":_vec(hit.position),"nav_position":_vec(actor.anchor.point),"nav_poly":actor.anchor.poly,"normal":_vec(hit.normal),"collider":str(collider.get_path()),"signed_gap":pos.y-hit.position.y,"phase":actor.phase,"sprite_position":_vec(actor.sprite.position),"animation":str(actor.sprite.animation),"frame":actor.sprite.frame}

func _vec(v: Vector3) -> Array:
	return [v.x,v.y,v.z]
