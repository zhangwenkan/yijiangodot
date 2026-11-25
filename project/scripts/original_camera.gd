extends Camera3D
## Fixed source rotation, composed from the original spring arm and camera component.
## Follow only the actor's world position; sprite frame offsets never enter this rig.

const SOURCE_OFFSET := Vector3(-30.8971, 9.3447, -0.01)
const SOURCE_PITCH := -14.5
const NATIVE_BOUNDS_PATH := "res://assets/environment/native-camera-foreground.json"
var follow_target: Node3D
var actor_center_offset := Vector3.ZERO
var tracked := Vector3.ZERO
var inspection := false
var zoom := 1.0
var initialized := false
var tracking_speed := 8.0
var height_speed := 3.0
var source_offset := SOURCE_OFFSET
var source_bounds: Array[Dictionary] = []
var source_axis_locked := [false, false, false]
var source_axis_values := Vector3.ZERO
var source_bounds_report := {"map":"", "bounds":0, "begins":0, "ends":0}

func _ready() -> void:
	keep_aspect = Camera3D.KEEP_WIDTH
	fov = 40.0
	near = 0.10
	far = 1800.0
	current = true
	set_meta("source_camera", "BP_SceneHero CameraBoom + TopDownCamera; native JHCameraBlockingVolume axis locks; follow smoothing adapted")

func reset_at(actor_position: Vector3) -> void:
	tracked = actor_position + actor_center_offset
	_reset_source_overlap_state()
	_sample_source_bounds()
	tracked = _locked_anchor(tracked)
	zoom = 1.0
	initialized = true
	_apply_pose()

func advance(delta: float, fallback: Vector3) -> void:
	if not initialized:
		reset_at(fallback)
	if inspection:
		var motion := Vector3.ZERO
		motion.z = float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT))
		motion.x = float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)) - float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
		tracked += motion.normalized() * delta * (18.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 7.0)
		tracked.y += (float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q))) * delta * 3.0
	else:
		_sample_source_bounds()
		var goal := fallback + actor_center_offset
		if is_instance_valid(follow_target):
			if follow_target.has_method("get_camera_anchor"):
				goal = follow_target.get_camera_anchor()
			else:
				goal = follow_target.global_position + actor_center_offset
		goal = _locked_anchor(goal)
		tracked.x = lerpf(tracked.x, goal.x, 1.0 - exp(-tracking_speed * delta))
		tracked.z = lerpf(tracked.z, goal.z, 1.0 - exp(-tracking_speed * delta))
		# Slower terrain-height following suppresses steps without any periodic bob.
		tracked.y = lerpf(tracked.y, goal.y, 1.0 - exp(-height_speed * delta))
	_apply_pose()

func configure_source_bounds(slug: String, player: Node3D) -> void:
	# Native Begin/EndOverlap lock the spring-arm origin on one world axis.
	# They do not clamp the whole level or collide a ray from camera to hero.
	follow_target = player
	source_bounds.clear()
	source_bounds_report = {"map":slug, "bounds":0, "begins":0, "ends":0}
	_reset_source_overlap_state()
	if not FileAccess.file_exists(NATIVE_BOUNDS_PATH):
		return
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(NATIVE_BOUNDS_PATH))
	for raw in config.get("maps", {}).get(slug, {}).get("camera_bounds", []):
		var entry: Dictionary = raw.duplicate(true)
		entry.center = _array_vector(raw.center_m)
		entry.origin = _array_vector(raw.root_origin_m)
		entry.extent = _array_vector(raw.half_extents_m)
		entry.world_extent = _array_vector(raw.world_aabb_half_extents_m)
		var columns: Array = raw.basis_columns
		entry.basis = Basis(_array_vector(columns[0]), _array_vector(columns[1]), _array_vector(columns[2]))
		entry.overlapping = false
		source_bounds.append(entry)
	source_bounds_report.bounds = source_bounds.size()
	_sample_source_bounds()
	print("ORIGINAL_CAMERA_BOUNDS_BOUND ", JSON.stringify(source_bounds_report))

func _reset_source_overlap_state() -> void:
	source_axis_locked = [false, false, false]
	source_axis_values = Vector3.ZERO
	for entry in source_bounds:
		entry.overlapping = false

func _sample_source_bounds() -> void:
	if not is_instance_valid(follow_target):
		return
	var collider := follow_target.get_node_or_null("MovementCapsule") as CollisionShape3D
	if collider == null or not collider.shape is CapsuleShape3D:
		return
	var capsule := collider.shape as CapsuleShape3D
	var scale_value := collider.global_basis.get_scale().abs()
	var radius := capsule.radius * minf(scale_value.x, scale_value.z)
	var half_height := capsule.height * 0.5 * scale_value.y
	for entry in source_bounds:
		var overlap := source_capsule_overlaps(entry, collider.global_position, radius, half_height)
		if overlap == bool(entry.overlapping):
			continue
		entry.overlapping = overlap
		var axis := _direction_axis(str(entry.direction))
		if overlap:
			source_axis_locked[axis] = true
			source_axis_values[axis] = source_lock_value(entry, radius, half_height)
			source_bounds_report.begins += 1
		else:
			# The source clears this axis on EndOverlap; it has no volume stack.
			source_axis_locked[axis] = false
			source_bounds_report.ends += 1

static func source_capsule_overlaps(entry: Dictionary, center: Vector3, radius: float, half_height: float) -> bool:
	# Extractor verifies original brush convexes are boxes, upright after world
	# transformation. Distance from the vertical capsule segment to this OBB
	# gives exact overlap including rounded corners, without extra geometry.
	var local: Vector3 = entry.basis.transposed() * (center - entry.center)
	var extent: Vector3 = entry.extent
	var segment_half := maxf(half_height - radius, 0.0)
	var distance := Vector3(maxf(absf(local.x) - extent.x, 0.0),
		maxf(absf(local.y) - segment_half - extent.y, 0.0),
		maxf(absf(local.z) - extent.z, 0.0))
	return distance.length_squared() <= radius * radius

static func source_lock_value(entry: Dictionary, radius: float, half_height: float) -> float:
	var origin: Vector3 = entry.origin
	var extent: Vector3 = entry.world_extent
	match str(entry.direction):
		"Left": return origin.z - extent.z - radius
		"Right": return origin.z + extent.z + radius
		"Up": return origin.x + extent.x + radius
		"Down": return origin.x - extent.x - radius
		"Top": return origin.y - extent.y - half_height
	return 0.0

static func _direction_axis(direction: String) -> int:
	if direction in ["Left", "Right"]:
		return 2
	return 1 if direction == "Top" else 0

func _locked_anchor(value: Vector3) -> Vector3:
	for axis in 3:
		if source_axis_locked[axis]:
			value[axis] = source_axis_values[axis]
	return value

static func _array_vector(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _apply_pose() -> void:
	global_position = tracked + source_offset * zoom
	var pitch := deg_to_rad(SOURCE_PITCH)
	var direction := Vector3(cos(pitch), sin(pitch), 0.0)
	look_at(global_position + direction, Vector3.UP)

func change_zoom(factor: float) -> void:
	zoom = clampf(zoom * factor, 0.75, 1.8)
	_apply_pose()

func set_source_house_state(inside: bool, source: Dictionary) -> void:
	if inside:
		var location: Array = source.camera_relative_ue_cm
		var actor_scale := float(source.actor_scale)
		# Same UE component composition as outdoors. Spring-arm world length and
		# socket offset stay unscaled here; native manager behaviour remains adapted.
		var x := float(location[0]) * 0.95 * actor_scale - float(source.camera_boom_arm_cm)
		var z := float(location[2]) * actor_scale + 100.0
		var pitch := deg_to_rad(1.5)
		source_offset = Vector3(cos(pitch)*x-sin(pitch)*z, sin(pitch)*x+cos(pitch)*z, float(location[1])*actor_scale) * 0.01
	else:
		source_offset = SOURCE_OFFSET
	zoom = 1.0
	set_meta("source_house_interior", inside)
	_apply_pose()
