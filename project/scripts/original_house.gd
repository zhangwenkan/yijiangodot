extends Node
## Source BP_IntoHouseTrigger environmental state machine. No geometry creation.
## Exact actor lists / oriented trigger transforms; native USphere origin recovered from constructor.

const MANIFEST := "res://assets/environment/original-houses.json"
signal house_state_changed(inside: bool)

var is_in_house := false
var report: Dictionary = {}
var _data: Dictionary = {}
var _config: Dictionary = {}
var _player: Node3D
var _camera: Camera3D
var _environment: Node
var _visuals: Dictionary = {}
var _bodies: Dictionary = {}
var _boxes: Array[Dictionary] = []
var _overlaps: Dictionary = {}
var _active := false
var cpu_stage_timing: RefCounted

func setup(slug: String, world: Node3D, collision_world: Node3D, player: Node3D, camera: Camera3D, environment: Node) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not parsed is Dictionary or not parsed.get("maps", {}).has(slug):
		push_error("Original house manifest missing: " + slug)
		return {}
	_config = parsed
	_data = parsed.maps[slug]
	_player = player
	_camera = camera
	_environment = environment
	report = {"map": slug, "source_actor": _data.source_actor, "bound_visuals": {}, "bound_collisions": {}, "missing_visual_actors": [], "missing_collision_actors": [], "limitations": _config.limitations.duplicate()}
	_index_visuals(world)
	_index_collisions(collision_world)
	for group in ["inside_actors", "outside_actors"]:
		for item in _data[group]:
			var actor: String = item.source_name
			if not _visuals.has(actor) and not report.missing_visual_actors.has(actor):
				report.missing_visual_actors.append(actor)
			if str(item["class"]).ends_with("StaticMeshActor") and not _bodies.has(actor) and not report.missing_collision_actors.has(actor):
				report.missing_collision_actors.append(actor)
	for actor in _visuals:
		report.bound_visuals[actor] = _visuals[actor].size()
	for actor in _bodies:
		report.bound_collisions[actor] = _bodies[actor].size()
	for source in _data.boxes:
		var transform := _ue_transform(source.matrix_ue)
		var extent: Array = source.extent_ue_cm
		_boxes.append({"name": source.name, "transform": transform, "extent": Vector3(extent[0], extent[2], extent[1]) * 0.01})
		_overlaps[source.name] = false
	# BeginPlay in the source blueprint explicitly starts outdoors.
	_set_group("inside_actors", false)
	_set_group("outside_actors", true)
	process_physics_priority = 10 # sample after the player's movement
	_active = true
	print("ORIGINAL_HOUSE_READY ", JSON.stringify(report))
	return report

func _actor_name(source: String) -> String:
	var marker := ".PersistentLevel."
	var at := source.find(marker)
	if at < 0:
		return ""
	var first := at + marker.length()
	var ending := source.find(".", first)
	return source if ending < 0 else source.substr(0, ending)

func _is_listed(actor: String) -> bool:
	for group in ["inside_actors", "outside_actors"]:
		for item in _data[group]:
			if item.source_name == actor:
				return true
	return false

func _is_static_actor(actor: String) -> bool:
	for group in ["inside_actors", "outside_actors"]:
		for item in _data[group]:
			if item.source_name == actor and str(item["class"]).ends_with("StaticMeshActor"):
				return true
	return false

func _index_visuals(node: Node) -> void:
	if node is Node3D and node.has_meta("source_name"):
		var actor := _actor_name(str(node.get_meta("source_name")))
		if _is_listed(actor):
			if not _visuals.has(actor):
				_visuals[actor] = []
			_visuals[actor].append(node)
	for child in node.get_children():
		_index_visuals(child)

func _index_collisions(node: Node) -> void:
	if node is StaticBody3D and node.has_meta("source_name"):
		var actor := _actor_name(str(node.get_meta("source_name")))
		if _is_static_actor(actor):
			if not _bodies.has(actor):
				_bodies[actor] = []
			_bodies[actor].append({"node": node, "layer": node.collision_layer, "mask": node.collision_mask})
	for child in node.get_children():
		_index_collisions(child)

func _set_group(group: String, shown: bool) -> void:
	var handled: Dictionary = {}
	for item in _data[group]:
		var actor: String = item.source_name
		if handled.has(actor):
			continue
		handled[actor] = true
		for node in _visuals.get(actor, []):
			if is_instance_valid(node):
				node.visible = shown
		if _data.change_collision:
			for state in _bodies.get(actor, []):
				if is_instance_valid(state.node):
					state.node.collision_layer = state.layer if shown else 0
					state.node.collision_mask = state.mask if shown else 0

func _ue_transform(m: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(m[0][0], m[2][0], m[1][0]), Vector3(m[0][2], m[2][2], m[1][2]), Vector3(m[0][1], m[2][1], m[1][1])), Vector3(m[0][3], m[2][3], m[1][3]) * 0.01)

func _sphere_touches_box(center: Vector3, radius: float, box: Dictionary) -> bool:
	var transform: Transform3D = box.transform
	var extent: Vector3 = box.extent
	var nearest := transform.origin
	var relative := center - transform.origin
	for index in 3:
		var axis: Vector3 = transform.basis[index]
		var length := axis.length()
		if length <= 0.000001:
			return false
		axis /= length
		nearest += axis * clampf(relative.dot(axis), -extent[index] * length, extent[index] * length)
	return center.distance_squared_to(nearest) <= radius * radius

func _physics_process(_delta: float) -> void:
	if not _active or not is_instance_valid(_player) or not _player.spawn_supported:
		return
	var relative: Array = _config.sensor.relative_location_ue_cm
	var sensor_offset := Vector3(relative[0], relative[2], relative[1]) * 0.01
	# USphere is attached to the capsule actor root. Sprite-facing labels do not
	# define actor rotation; apply only the actual actor basis, then source scale.
	var center: Vector3 = _player.get_camera_anchor() + _player.global_basis.orthonormalized() * sensor_offset * _player.source_house_scale
	var radius: float = float(_config.sensor.radius_m) * _player.source_house_scale
	var entered: Array[String] = []
	for box in _boxes:
		var overlapping := _sphere_touches_box(center, radius, box)
		if overlapping and not _overlaps[box.name]:
			entered.append(box.name)
		_overlaps[box.name] = overlapping
	# UE overlap handlers guard against entering/exiting the same state again.
	if not is_in_house and entered.has("IntoBox"):
		set_inside(true)
	elif is_in_house:
		for key in entered:
			if key.begins_with("OutoBox"):
				set_inside(false)
				break

func set_inside(inside: bool) -> void:
	if cpu_stage_timing == null:
		_cpu_body_set_inside(inside)
		return
	var cpu_span: int = _cpu_begin("house_total", {"requested_inside":inside})
	_cpu_body_set_inside(inside)
	_cpu_end(cpu_span)

func _cpu_body_set_inside(inside: bool) -> void:
	if not _active or inside == is_in_house:
		return
	is_in_house = inside
	var cpu_house_outside_group: int = _cpu_begin("house_outside_group")
	_set_group("outside_actors", not inside)
	_cpu_end(cpu_house_outside_group)
	var cpu_house_inside_group: int = _cpu_begin("house_inside_group")
	_set_group("inside_actors", inside)
	_cpu_end(cpu_house_inside_group)
	if is_instance_valid(_player):
		_player.set_source_house_scale(float(_config.interior.actor_scale) if inside else 1.0)
	if is_instance_valid(_camera):
		_camera.set_source_house_state(inside, _config.interior)
	if is_instance_valid(_environment) and _environment.has_method("set_source_house_lighting"):
		var cpu_house_environment: int = _cpu_begin("house_environment")
		_environment.set_source_house_lighting(inside, _config.interior)
		_cpu_end(cpu_house_environment)
	var cpu_house_emit: int = _cpu_begin("house_emit")
	house_state_changed.emit(inside)
	_cpu_end(cpu_house_emit)
	print("ORIGINAL_HOUSE_STATE ", report.get("map", ""), " inside=", inside)

func reset_outdoors() -> void:
	set_inside(false)
	for key in _overlaps:
		_overlaps[key] = false

func shutdown() -> void:
	if not _active:
		return
	reset_outdoors()
	_active = false
	set_physics_process(false)

func _exit_tree() -> void:
	shutdown()

func _cpu_begin(stage: String, extra: Dictionary = {}) -> int:
	if cpu_stage_timing == null: return -1
	var context := {"map":str(report.get("map","")),"inside":is_in_house}
	context.merge(extra,true)
	return cpu_stage_timing.begin_span(stage,context)

func _cpu_end(span: int) -> void:
	if cpu_stage_timing != null: cpu_stage_timing.end_span(span)
