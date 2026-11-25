extends Node
## Recovered animal behavior trees on the original Detour navigation domain.
## This adapter does not recreate UE CharacterMovement acceleration or avoidance.

const NavigationSource = preload("res://scripts/source_navigation.gd")
const MANIFEST := "res://assets/source-animals/manifest.json"
var source: Dictionary
var navigation = NavigationSource.new()
var actors: Array[Dictionary] = []
var report: Dictionary = {}
var player: Node3D
var ambient: Node3D
var startup_ticks := 2
var disabled := false
var rng := RandomNumberGenerator.new()

func setup(slug: String, ambient_node: Node3D, player_node: Node3D) -> void:
	ambient = ambient_node
	player = player_node
	source = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	navigation.setup(slug)
	rng.randomize()
	report = {"map":slug,"source_navigation":navigation.report,"active":0,"without_tree":0,"unmatched":[],"initial_connectors":[],"missing_actions":{},"moves":0,"path_failures":0,"surface_failures":0,"sticky_hero_detection":true,"native_character_movement":false,"random_sequence":"Godot RNG; source distributions, not original UE sequence","local_support_actors":0,"local_support_updates":0,"local_support_rejected":0,"local_support_rejections":[],"local_support_max_nav_delta":0.0}
	report.rng_seed = str(rng.seed)
	report.rng_initial_state = str(rng.state)
	report.path_failure_samples = []

func _initialize_actors() -> void:
	for entry in ambient.sprites:
		var d: Dictionary = entry.definition
		if not d.is_npc or bool(d.get("is_human",false)):
			continue
		var cfg: Dictionary = source.npcs.get(str(int(d.npc_id)),{})
		var tree := str(cfg.get("tree","None")).get_file().get_slice(".",0)
		if tree == "None" or tree.is_empty():
			report.without_tree += 1
			continue
		var holder: Node3D = entry.holder
		# Use the cooked actor pose to locate its nav island, then retain the
		# actual support offset established by the existing ambient renderer.
		var m: Array = d.matrix_ue
		var authored := Vector3(float(m[0][3]),float(m[2][3]),float(m[1][3]))*0.01
		var anchor: Dictionary = navigation.project(authored)
		if anchor.is_empty():
			report.unmatched.append({"component":d.component,"npc":d.npc_id,"reason":"source pose has no original nav surface within 0.75m horizontal / 1.25m vertical; kept original loop"})
			continue
		var offset := Vector2(authored.x-anchor.point.x,authored.z-anchor.point.z).length()
		if offset > 0.001:
			report.initial_connectors.append({"component":d.component,"horizontal_m":offset})
		var resource: Dictionary = source.resources[cfg.resource]
		var state := {"holder":holder,"sprite":entry.sprite,"component":int(d.component),"cfg":cfg,"resource":resource,"tree":tree,"origin":anchor.point,"anchor":anchor,"path":[],"waypoint":0,"wait":0.0,"phase":"begin","seen_hero":false,"direction":-1 if d.flipbook in resource.IdleLeftFlipbook else 1,"height_offset":holder.global_position.y-anchor.point.y,"speed":float(cfg.source_movement_fields.MoveSpeed)*0.01,"fish":tree=="BT_Yu","action_timer":rng.randf_range(3.0,4.0),"action_interval":0.0,"is_idle":true,"attack":false,"skill":false,"loc_a_to_b":false,"post_wait":0.0,"initial_connector":offset>0.001,"original_flipbook":d.flipbook}
		state.support_grounded = false
		if cfg.resource in ["HaiGui","HaiGui_1","PangXie","JiJuXie","HouZi","Gui"]:
			var support := _local_support(holder.global_position)
			state.support_grounded = not support.is_empty() and absf(holder.global_position.y-support.position.y-0.025)<0.08
			if state.support_grounded:
				report.local_support_actors += 1
		state.action_interval = state.action_timer
		actors.append(state)
	report.active = actors.size()
	print("SOURCE_ANIMAL_BEHAVIOR_READY ",JSON.stringify(report))

func _physics_process(delta: float) -> void:
	if disabled or ambient == null:
		return
	if startup_ticks > 0:
		startup_ticks -= 1
		if startup_ticks == 0:
			_initialize_actors()
		return
	for actor in actors:
		_tick(actor,delta)

func _tick(a: Dictionary, delta: float) -> void:
	if a.tree == "BT_RunAway" and is_instance_valid(player) and not a.seen_hero:
		if a.holder.global_position.distance_to(player.global_position) < 4.0 and player.visible:
			a.seen_hero = true
			# Source observer can abort the ordinary patrol branch.
			a.path = []
			a.phase = "flee_wait"
			a.wait = 0.1
			_animation(a,"Idle")
	if a.tree in ["BT_TuZi","BT_YeYa"]:
		a.action_timer -= delta
		if a.action_timer <= 0.0:
			a.action_timer += a.action_interval
			if rng.randf() < 0.4:
				a.is_idle = false
				if rng.randf() < 0.5:
					a.attack = true
				else:
					a.skill = true
				if a.phase in ["begin","gui_roam_wait","gui_move_wait","duck_roam_wait","duck_move_wait","moving"]:
					a.path = []
					a.wait = 0.0
					a.phase = "begin"
	if a.phase == "moving":
		_advance(a,delta)
		return
	if a.wait > 0.0:
		a.wait -= delta
		if a.wait > 0.0:
			return
	match a.tree:
		"BT_RunAway": _run_away(a)
		"BT_Yu": _fish(a)
		"BT_TuZi": _gui(a)
		"BT_YeYa": _duck(a)
		"BT_Bird_2": _bird_two(a)

func _run_away(a: Dictionary) -> void:
	if a.seen_hero:
		if a.phase != "flee_wait":
			a.phase = "flee_wait"
			a.wait = 0.1
			return
		var away: Vector3 = a.holder.global_position-player.global_position
		away.y = 0.0
		var center: Vector3 = a.anchor.point+away.normalized()
		var near: Dictionary = navigation.project(center,1.0,1.25)
		if near.is_empty():
			a.wait = 0.5
			return
		var goal: Dictionary = navigation.random_reachable(int(near.poly),center,1.0,rng)
		_begin_path(a,goal,0.5,"begin")
	else:
		# The source task tests one random query, then assigns a second query.
		var base: Dictionary = navigation.project(a.origin)
		if base.is_empty():
			a.wait = 3.0
			return
		navigation.random_reachable(int(base.poly),a.origin,3.0,rng)
		_begin_path(a,navigation.random_reachable(int(base.poly),a.origin,3.0,rng),3.0,"begin")

func _fish(a: Dictionary) -> void:
	if a.phase == "begin":
		a.phase = "fish_pick"
		a.wait = 0.1
	elif a.phase == "fish_pick":
		a.goal = navigation.random_reachable(int(a.anchor.poly),a.anchor.point,3.0,rng)
		a.phase = "fish_move"
		a.wait = 0.1
	else:
		_begin_path(a,a.goal,0.0,"begin")

func _gui(a: Dictionary) -> void:
	if a.phase == "gui_attack_end":
		a.is_idle = true
		a.attack = false
		a.phase = "gui_skill_check"
		a.wait = 0.2
		_animation(a,"Idle")
		return
	if a.phase == "gui_skill_check":
		if a.skill:
			_animation(a,"FightIdle")
			a.wait = rng.randf_range(2.0,4.0)
			a.phase = "gui_skill_end"
		else:
			a.phase = "begin"
		return
	if a.phase == "gui_skill_end":
		a.is_idle = true
		a.skill = false
		a.wait = 0.2
		a.phase = "begin"
		_animation(a,"Idle")
		return
	if not a.is_idle:
		# Source is a Sequence: Skill alone fails its preceding Attack child.
		# Preserve that source branch instead of inventing a skill-only selector.
		if a.attack:
			_animation(a,"Attack")
			a.wait = rng.randf_range(2.0,4.0)
			a.phase = "gui_attack_end"
		return
	if a.phase == "begin":
		a.wait = rng.randf_range(2.0,6.0)
		a.phase = "gui_roam_wait"
	elif a.phase == "gui_roam_wait":
		a.goal = navigation.random_reachable(int(a.anchor.poly),a.anchor.point,2.0,rng)
		a.wait = 0.2
		a.phase = "gui_move_wait"
	elif a.phase == "gui_move_wait":
		_begin_path(a,a.goal,0.0,"begin")

func _bird_two(a: Dictionary) -> void:
	if a.phase == "bird_action":
		_animation(a,"Attack" if rng.randf()<0.5 else "FightIdle")
		a.wait = a.bird_wait
		a.phase = "begin"
		return
	# These two exact authored UE points belong to JiJuXie, despite tree name.
	var center := Vector3(-69.292084961,1.305190887,19.892143555) if a.loc_a_to_b else Vector3(-69.274731445,0.788918381,13.706634521)
	a.bird_wait = 2.0 if a.loc_a_to_b else 1.0
	a.loc_a_to_b = not a.loc_a_to_b
	var base: Dictionary = navigation.project(center,3.0,2.0)
	if base.is_empty():
		a.wait = 1.0
		return
	_begin_path(a,navigation.random_reachable(int(base.poly),center,3.0,rng),0.0,"bird_action")

func _begin_path(a: Dictionary, goal: Dictionary, post_wait: float, next_phase: String) -> void:
	# Record external review reseeding too; strings preserve all 64 RNG bits.
	report.rng_seed = str(rng.seed)
	report.rng_state_at_last_path = str(rng.state)
	if goal.is_empty():
		a.wait = maxf(post_wait,0.1)
		return
	var path: Array[Dictionary] = navigation.route(a.anchor,goal)
	if path.is_empty():
		report.path_failures += 1
		if report.path_failure_samples.size() < 20:
			var start_point: Vector3 = a.anchor.point
			var goal_point: Vector3 = goal.point
			report.path_failure_samples.append({"component":a.component,"tree":a.tree,"phase":a.phase,"seen_hero":a.seen_hero,"rng_seed":str(rng.seed),"rng_state":str(rng.state),"start":{"poly":int(a.anchor.poly),"point":[start_point.x,start_point.y,start_point.z]},"goal":{"poly":int(goal.poly),"point":[goal_point.x,goal_point.y,goal_point.z]}})
		a.wait = maxf(post_wait,0.1)
		return
	if a.initial_connector:
		path.push_front({"point":a.anchor.point,"poly":a.anchor.poly,"connector":true})
	a.path = path
	a.waypoint = 0
	a.post_wait = post_wait
	a.next_phase = next_phase
	a.phase = "moving"
	report.moves += 1
	_animation(a,"Run")

func _advance(a: Dictionary, delta: float) -> void:
	var step: Dictionary = a.path[int(a.waypoint)]
	var holder: Node3D = a.holder
	var pos: Vector3 = holder.global_position
	var target: Vector3 = step.point+Vector3.UP*float(a.height_offset)
	var movement := Vector3(target.x-pos.x,0.0,target.z-pos.z)
	var length := movement.length()
	var amount := minf(float(a.speed)*delta,length)
	var candidate := pos+movement.normalized()*amount
	_update_direction(a,movement)
	_animation(a,"Run")
	if step.get("connector",false):
		# A short approach from an authored start outside the nav boundary;
		# original transform is never teleported onto a nearby polygon.
		candidate.y = move_toward(pos.y,target.y,float(a.speed)*delta)
	else:
		var query_point := Vector3(candidate.x,a.anchor.point.y,candidate.z) if a.support_grounded else candidate-Vector3.UP*float(a.height_offset)
		var projected: Dictionary = navigation.project(query_point,0.03,1.0)
		if projected.is_empty():
			report.surface_failures += 1
			a.path = []
			a.phase = "begin"
			a.wait = 0.2
			_animation(a,"Idle")
			return
		candidate = projected.point+Vector3.UP*float(a.height_offset)
		if a.support_grounded:
			var support := _local_support(projected.point)
			if support.is_empty() or absf(float(support.position.y)+0.025-pos.y)>maxf(0.20,amount*1.01):
				report.local_support_rejected += 1
				if report.local_support_rejections.size()<20:
					report.local_support_rejections.append({"component":a.component,"position":[pos.x,pos.y,pos.z],"nav_position":[projected.point.x,projected.point.y,projected.point.z],"reason":"no nearby walkable original support" if support.is_empty() else "local step discontinuity","support_y":null if support.is_empty() else support.position.y})
				a.path = []
				a.phase = "begin"
				a.wait = 0.2
				_animation(a,"Idle")
				return
			candidate.y = support.position.y+0.025
			report.local_support_updates += 1
			report.local_support_max_nav_delta = maxf(report.local_support_max_nav_delta,absf(projected.point.y-support.position.y))
		a.anchor = projected
	holder.global_position = candidate
	if length <= amount+0.005:
		a.initial_connector = false
		a.anchor = {"point":step.point,"poly":step.poly}
		a.waypoint += 1
		if int(a.waypoint)>=a.path.size():
			a.phase = a.next_phase
			a.wait = a.post_wait
			a.path = []
			_animation(a,"Idle")

func _update_direction(a: Dictionary, movement: Vector3) -> void:
	# Shipping JHPaperFlipbookComponent::Tick reads UE Velocity.Y first.
	# UE Y maps to Godot Z; EGridDirect Left=0, Right=2. With bOneFace
	# true, pure depth movement would request Up/Down and SetDirect keeps
	# the previous Left/Right. The source camera sees +Z as screen-right.
	if movement.z > 0.0:
		a.direction = 1
	elif movement.z < 0.0:
		a.direction = -1

func _animation(a: Dictionary, action: String) -> void:
	var side := "Right" if int(a.direction)>0 else "Left"
	var suffix := "Flipbooks" if action=="Attack" else "Flipbook"
	var refs: Array = a.resource.get(action+side+suffix,[])
	if refs.is_empty():
		var key := str(a.cfg.resource)+":"+action+side
		report.missing_actions[key] = true
		# The cooked reference really is None. Keep current source animation;
		# native missing-action fallback is not established, so do not fabricate.
		return
	var ref := str(refs[rng.randi_range(0,refs.size()-1)]) if action=="Attack" else str(refs[0])
	var sprite: AnimatedSprite3D = a.sprite
	sprite.flip_h = false
	if str(sprite.animation)!=ref:
		sprite.play(ref)

func _local_support(point: Vector3) -> Dictionary:
	# A bounded rendering/locomotion adapter for already supported terrestrial
	# actors only. The original Detour surface chooses XZ and route topology;
	# it is a coarse navigation approximation, not the visible terrain height.
	# This is not a claim to reproduce native UE CharacterMovement.
	var ray := PhysicsRayQueryParameters3D.create(point+Vector3.UP*0.75,point-Vector3.UP*0.75,4)
	var hit := ambient.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty() or hit.normal.y<0.71:
		return {}
	return hit

func _duck(a: Dictionary) -> void:
	# BT_YeYa uses a Selector for non-idle actions, unlike BT_TuZi's Sequence.
	if a.phase in ["duck_attack_end","duck_skill_end"]:
		a.is_idle = true
		if a.phase == "duck_attack_end":
			a.attack = false
		else:
			a.skill = false
		a.phase = "begin"
		a.wait = 0.2
		_animation(a,"Idle")
		return
	if not a.is_idle:
		if a.attack:
			_animation(a,"Attack")
			a.wait = rng.randf_range(2.0,4.0)
			a.phase = "duck_attack_end"
		elif a.skill:
			_animation(a,"FightIdle")
			a.wait = rng.randf_range(2.0,4.0)
			a.phase = "duck_skill_end"
		return
	if a.phase == "begin":
		a.wait = rng.randf_range(0.5,1.5)
		a.phase = "duck_roam_wait"
	elif a.phase == "duck_roam_wait":
		a.goal = navigation.random_reachable(int(a.anchor.poly),a.anchor.point,2.0,rng)
		a.wait = 0.2
		a.phase = "duck_move_wait"
	elif a.phase == "duck_move_wait":
		_begin_path(a,a.goal,0.0,"begin")
