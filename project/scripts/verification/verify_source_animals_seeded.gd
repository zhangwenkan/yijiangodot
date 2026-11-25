extends "res://scripts/verify_source_animals_runtime.gd"
## Headless behavior/physics regression, reusing production asset loading and the
## existing runtime verifier's _sample/_vec. It is not a visual or FPS benchmark.
## Run at --fixed-fps 60 with explicit --source-animal-seed before setup.
const TraceBehavior = preload("res://scripts/verification/source_animal_request_trace.gd")
var review_slug := "youxian"
var fixed_step := 1.0/60.0
var seeded_initial_actors: Array[Dictionary] = []
var seeded_errors: Array[String] = []

func _run() -> void:
	var has_seed := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			review_slug = arg.trim_prefix("--map=")
		elif arg.begins_with("--source-animal-seed="):
			has_seed = true
	if not has_seed or review_slug not in ["youxian","wuming"] or duration<=0.0:
		push_error("Seeded review requires --source-animal-seed=<integer>, valid map, and positive --animal-duration")
		quit(2)
		return
	Engine.physics_ticks_per_second = 60
	level = Node3D.new()
	level.name = "SeededAnimalReview"
	root.add_child(level)
	var collision = load("res://scripts/original_collision.gd").new()
	level.add_child(collision)
	var collision_report: Dictionary = collision.setup(review_slug)
	await physics_frame
	await physics_frame
	ambient = load("res://scripts/original_ambient_sprites.gd").new()
	ambient.name = "ProductionAmbientSprites"
	level.add_child(ambient)
	ambient.set_physics_process(false)
	ambient.setup(review_slug,level)
	# Exactly the existing one-time settling code, before behavior initialization.
	ambient._physics_process(fixed_step)
	var hero := Node3D.new()
	hero.name = "ReviewHero"
	level.add_child(hero)
	hero.global_position = Vector3(9000,9000,9000)
	behavior = TraceBehavior.new()
	behavior.name = "ObservedProductionBehavior"
	level.add_child(behavior)
	behavior.set_physics_process(false)
	behavior.setup(review_slug,ambient,hero)
	if behavior.disabled or behavior.rng_seed_source!="explicit_setup_review_seed":
		push_error("Production behavior did not accept explicit setup seed")
		quit(3)
		return
	# Manual fixed stepping starts at setup, so loading duration consumes no AI RNG.
	behavior._physics_process(fixed_step)
	behavior._physics_process(fixed_step)
	checks = {"map":review_slug,"renderer":RenderingServer.get_current_rendering_method(),"mode":"headless_original_collision_and_production_sprites_behavior","visual_validation":false,"fixed_step":fixed_step,"manual_behavior_steps":true,"collision":collision_report,"expected_active":0,"expected_components":[],"source_tree_without_nav":[],"ticks":0,"pivot_errors":[],"atlas_errors":[],"without_tree_moved":[],"fish_ground_flag":[],"fish_anchor_offset_max":0.0,"ground_anchor_offset_max":0.0,"ground_support_samples":0,"ground_support_gap_max":0.0,"surface_failure_start":behavior.report.surface_failures,"only_observed_source_routes":true,"full_map_traversal_verified":false,"approach_depart_test":"actual review hero repositioned at ticks 900/1380","captures":[],"seed_at_setup":behavior.report.rng_seed,"seed_source":behavior.rng_seed_source,"rng_state_after_initialization":str(behavior.rng.state)}
	for entry in ambient.sprites:
		var d: Dictionary = entry.definition
		if not d.is_npc or bool(d.get("is_human",false)):
			continue
		var id := int(d.component)
		var cfg: Dictionary = behavior.source.npcs.get(str(int(d.npc_id)),{})
		var tree := str(cfg.get("tree","None")).get_file().get_slice(".",0)
		if tree!="None" and not tree.is_empty():
			var matrix: Array = d.matrix_ue
			var authored := Vector3(float(matrix[0][3]),float(matrix[2][3]),float(matrix[1][3]))*0.01
			var source_anchor: Dictionary = behavior.navigation.project(authored)
			if source_anchor.is_empty():
				checks.source_tree_without_nav.append(id)
			else:
				checks.expected_active += 1
				checks.expected_components.append(id)
		starts[id] = entry.holder.global_position
		rows[id] = {"npc":int(d.npc_id),"source_animation":str(entry.sprite.animation),"animations":{},"frames":{},"max_displacement":0.0,"animation_changes":0,"last_animation":str(entry.sprite.animation),"needs_ground_after_start":entry.needs_ground,"support_gap_max":0.0,"support_gap_event":{}}
	for actor in behavior.actors:
		rows[actor.component].source_anchor_offset = actor.height_offset
		rows[actor.component].resource = actor.cfg.resource
		rows[actor.component].tree = actor.tree
		rows[actor.component].initial_actor_position = _vec(actor.holder.global_position)
		rows[actor.component].initial_nav_position = _vec(actor.anchor.point)
		seeded_initial_actors.append(_actor_state(actor))
		if actor.tree=="BT_RunAway" and (flee_actor.is_empty() or actor.cfg.resource=="HouZi"):
			flee_actor = actor
	if behavior.actors.is_empty() or flee_actor.is_empty():
		push_error("No active source animals or no original RunAway actor")
		quit(4)
		return
	var target_ticks := int(round(duration/fixed_step))
	for frame_index in range(target_ticks):
		await physics_frame
		tick_count = frame_index+1
		elapsed = float(tick_count)*fixed_step
		behavior.review_tick = tick_count
		if tick_count==900:
			approached = true
			hero.global_position = flee_actor.holder.global_position+Vector3(0,0,0.8)
			checks.approach_component = int(flee_actor.component)
		if tick_count==1380:
			departed = true
			checks.seen_before_depart = bool(flee_actor.seen_hero)
			hero.global_position = Vector3(9000,9000,9000)
		behavior._physics_process(fixed_step)
		_sample()
	checks.ticks = tick_count
	checks.active = behavior.actors.size()
	checks.active_matches_source = checks.active==checks.expected_active
	checks.rows = rows
	checks.duration_seconds = elapsed
	checks.seen_after_depart = bool(flee_actor.seen_hero)
	checks.approached = approached
	checks.departed = departed
	checks.behavior_report = behavior.report
	checks.validation_purpose = "deterministic original-request replay and existing per-frame invariants; not removal of support rejections"
	checks.complete_restoration_verified = false
	checks.native_capsule_movement_verified = false
	checks.support_rejections_observed = int(behavior.report.local_support_rejected)
	checks.support_rejection_sample_count = behavior.report.local_support_rejections.size()
	checks.support_rejections_resolved = false
	checks.support_rejection_status = "observed_unresolved" if checks.support_rejections_observed>0 else "none_in_this_short_run_only"
	checks.support_rejection_classifications = {}
	checks.initial_actors = seeded_initial_actors
	checks.final_actors = []
	checks.request_trace = behavior.request_trace
	checks.rng_final_state = str(behavior.rng.state)
	checks.moved = 0
	for actor in behavior.actors:
		checks.final_actors.append(_actor_state(actor))
	for row in rows.values():
		if float(row.max_displacement)>0.1:
			checks.moved += 1
	if not checks.active_matches_source:
		seeded_errors.append("active animal count differs from source candidates")
	if not checks.pivot_errors.is_empty() or not checks.atlas_errors.is_empty() or not checks.without_tree_moved.is_empty() or not checks.fish_ground_flag.is_empty():
		seeded_errors.append("existing sprite/atlas/static/fish checks failed")
	if int(behavior.report.path_failures)>0 or int(behavior.report.surface_failures)>0:
		seeded_errors.append("path or surface failure observed")
	if behavior.request_trace.is_empty():
		seeded_errors.append("no original movement requests observed")
	# A support rejection remains a recorded unresolved behavior limitation.
	# Check the new diagnostics honestly; never omit it to make errors empty.
	if checks.support_rejection_sample_count!=mini(checks.support_rejections_observed,20):
		seeded_errors.append("support rejection count and capped diagnostic samples disagree")
	for rejection in behavior.report.local_support_rejections:
		if not rejection.has_all(["component","position","nav_position","support_classification","support_probe","anchor","requested_goal","rng_state","physics_frame"]):
			seeded_errors.append("support rejection diagnostic fields missing")
			continue
		var classification := str(rejection.support_classification)
		checks.support_rejection_classifications[classification] = int(checks.support_rejection_classifications.get(classification,0))+1
		var probe: Dictionary = rejection.support_probe
		if classification=="no_ray_hit":
			if str(probe.get("classification",""))!="no_ray_hit":
				seeded_errors.append("no-hit rejection has inconsistent probe classification")
		elif classification=="slope_rejected":
			if str(probe.get("classification",""))!="slope_rejected" or not probe.has_all(["normal","hit_position","source_component","source_mesh","source_name"]) or float(probe.normal[1])>=0.71:
				seeded_errors.append("slope rejection lacks the original steep hit evidence")
		elif classification=="step_discontinuity":
			if str(probe.get("classification",""))!="walkable_hit" or rejection.support_y==null:
				seeded_errors.append("step discontinuity lacks walkable height evidence")
		else:
			seeded_errors.append("unknown support rejection classification")
	checks.errors = seeded_errors
	checks.existing_invariants_and_diagnostics_valid = seeded_errors.is_empty()
	var f := FileAccess.open(output.path_join(review_slug+"-animal-review.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(checks,"\t"))
	f.close()
	print("SEEDED_SOURCE_ANIMAL_REVIEW ",JSON.stringify({"map":review_slug,"active":checks.active,"moved":checks.moved,"ticks":tick_count,"requests":behavior.request_trace.size(),"support_rejected":behavior.report.local_support_rejected,"partial_requests":behavior.report.partial_requests,"errors":seeded_errors,"output":output}))
	level.queue_free()
	for i in range(3):
		await process_frame
	quit(0 if seeded_errors.is_empty() else 1)

func _actor_state(actor: Dictionary) -> Dictionary:
	var point: Vector3 = actor.anchor.point
	return {"component":int(actor.component),"resource":str(actor.cfg.resource),"tree":str(actor.tree),"position":_vec(actor.holder.global_position),"anchor":{"poly":int(actor.anchor.poly),"point":_vec(point)},"height_offset":float(actor.height_offset),"support_grounded":bool(actor.support_grounded),"phase":str(actor.phase),"wait":float(actor.wait),"action_timer":float(actor.action_timer),"action_interval":float(actor.action_interval),"seen_hero":bool(actor.seen_hero),"direction":int(actor.direction),"waypoint":int(actor.waypoint),"animation":str(actor.sprite.animation)}
