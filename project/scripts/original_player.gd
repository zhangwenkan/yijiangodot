extends CharacterBody3D
## Original Paper2D hero with a foot-origin controller. Camera stays external.
## Sprite pixels, pivots and timing come from source cooked assets.
## MoveSpeed/InSideMoveSpeed are recovered from the native constructor.
## Capsule defaults retain the existing controller evidence; see source-manifest.

const CAPSULE_RADIUS := 0.42
const CAPSULE_HALF_HEIGHT := 0.96
const MAX_STEP_HEIGHT := 0.20
const SUPPORT_LAYER := 4
const FLOOR_MIN_DOT := 0.573576436
const PIXEL_SIZE := 0.045
const CONTACT_MARGIN := 0.012
const SOURCE_SEA_LEVEL := 0.0
const MIN_DRY_FOOT_HEIGHT := SOURCE_SEA_LEVEL + 0.04

@export var move_speed := 6.0
var input_enabled := true
var view_camera: Camera3D
var sprite: AnimatedSprite3D
var review_motion := Vector2.ZERO
var review_override := false
var last_direction := "down"
var blocked_at_edge := false
var spawn_supported := false
var travelled_distance := 0.0
var source_actor_position := Vector3.ZERO
var last_safe_position := Vector3.ZERO
var _sprite_manifest: Dictionary = {}
var _grounded_once := false
var footsteps: Node
var source_house_scale := 1.0

func _ready() -> void:
	name = "OriginalHero"
	collision_layer = 2
	collision_mask = 1
	floor_max_angle = deg_to_rad(55.0)
	floor_snap_length = MAX_STEP_HEIGHT + 0.05
	floor_constant_speed = true
	floor_stop_on_slope = true
	safe_margin = 0.005
	var shape := CapsuleShape3D.new()
	shape.radius = CAPSULE_RADIUS
	shape.height = CAPSULE_HALF_HEIGHT * 2.0
	var collider := CollisionShape3D.new()
	collider.name = "MovementCapsule"
	collider.shape = shape
	collider.position.y = CAPSULE_HALF_HEIGHT
	add_child(collider)
	_sprite_manifest = JSON.parse_string(FileAccess.get_file_as_string("res://assets/characters/original_hero/source-manifest.json"))
	sprite = AnimatedSprite3D.new()
	sprite.name = "SourcePaperFlipbook"
	sprite.sprite_frames = load("res://assets/characters/original_hero/original_hero.tres")
	sprite.pixel_size = PIXEL_SIZE
	sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.shaded = true
	sprite.double_sided = true
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.alpha_scissor_threshold = 0.3333
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	add_child(sprite)
	sprite.frame_changed.connect(_update_source_pivot)
	sprite.animation_changed.connect(_update_source_pivot)
	sprite.play("idle_down")
	_update_source_pivot()
	footsteps = preload("res://scripts/original_footsteps.gd").new()
	add_child(footsteps)

func configure(camera: Camera3D) -> void:
	view_camera = camera

func get_camera_anchor() -> Vector3:
	return global_position + Vector3.UP * CAPSULE_HALF_HEIGHT * source_house_scale

func set_review_motion(motion: Vector2) -> void:
	review_motion = motion.limit_length()
	review_override = true

func clear_review_motion() -> void:
	review_motion = Vector2.ZERO
	review_override = false

func place_at_source_actor_position(actor_position: Vector3) -> bool:
	source_actor_position = actor_position
	if is_instance_valid(footsteps):
		# The source entry points are separate worlds. Later review points keep
		# the map selected by their initial spawn instead of inferring each time.
		if footsteps.terrain.is_empty():
			footsteps.select_map("youxian" if actor_position.distance_to(Vector3(-61.85358,3.68085,28.81919)) < 2.0 else "wuming")
	velocity = Vector3.ZERO
	var support := _support_at(actor_position, 2.0, 12.0)
	spawn_supported = not support.is_empty()
	if spawn_supported:
		global_position = Vector3(actor_position.x, support.position.y + CONTACT_MARGIN, actor_position.z)
		last_safe_position = global_position
		_grounded_once = true
	else:
		global_position = actor_position - Vector3.UP * CAPSULE_HALF_HEIGHT
		push_warning("Original hero spawn has no imported support: " + str(actor_position))
	return spawn_supported

func _physics_process(delta: float) -> void:
	if not spawn_supported:
		return
	var controls := _read_controls()
	var heading := _world_heading(controls)
	var start := global_position
	blocked_at_edge = false
	var support_here := _support_at(global_position, MAX_STEP_HEIGHT + 0.06, MAX_STEP_HEIGHT + 0.14)
	if not support_here.is_empty():
		_grounded_once = true
		last_safe_position = global_position
	if heading.length_squared() > 0.001:
		heading = _supported_heading(heading, delta)
	var desired := heading * move_speed
	velocity.x = move_toward(velocity.x, desired.x, 100.0 * delta)
	velocity.z = move_toward(velocity.z, desired.z, 100.0 * delta)
	if is_on_floor():
		velocity.y = -0.1
	else:
		velocity.y -= 24.0 * delta
	if heading.length_squared() > 0.001 and not support_here.is_empty():
		_try_step(Vector3(velocity.x, 0, velocity.z) * delta)
	var requested_motion := Vector3(velocity.x, 0, velocity.z) * delta
	move_and_slide()
	if heading.length_squared() > 0.001 and Vector2(global_position.x-start.x,global_position.z-start.z).length_squared() < 0.00000001:
		_retry_floor_tangent_motion(requested_motion)
	var support_after := _support_at(global_position, MAX_STEP_HEIGHT + 0.07, MAX_STEP_HEIGHT + 0.15)
	if support_after.is_empty() and _grounded_once:
		# Source bCanWalkOffLedges=false: retain last supported footprint instead
		# of letting the character fall into sea or through an unexported surface.
		global_position = start
		velocity = Vector3.ZERO
		blocked_at_edge = true
	else:
		last_safe_position = global_position
	var displacement := global_position - start
	travelled_distance += Vector2(displacement.x, displacement.z).length()
	footsteps.update_motion(delta, Vector2(displacement.x, displacement.z).length(), support_after, global_position)
	_update_animation(controls, Vector2(displacement.x, displacement.z).length() > 0.0008)

func _read_controls() -> Vector2:
	if review_override:
		return review_motion
	if not input_enabled:
		return Vector2.ZERO
	var result := Vector2.ZERO
	result.x = float(Input.is_physical_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT))
	result.y = float(Input.is_physical_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP))
	return result.limit_length()

func _world_heading(controls: Vector2) -> Vector3:
	var right := Vector3(0, 0, 1)
	var forward := Vector3(1, 0, 0)
	if is_instance_valid(view_camera):
		right = view_camera.global_basis.x
		forward = -view_camera.global_basis.z
		right.y = 0
		forward.y = 0
		right = right.normalized()
		forward = forward.normalized()
	return (right * controls.x - forward * controls.y).limit_length()

func _support_at(point: Vector3, above: float, below: float) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * above, point - Vector3.UP * below, SUPPORT_LAYER)
	query.exclude = [get_rid()]
	query.hit_back_faces = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.normal.dot(Vector3.UP) < FLOOR_MIN_DOT or hit.position.y < MIN_DRY_FOOT_HEIGHT:
		return {}
	return hit

func _footprint_is_supported(heading: Vector3, delta: float) -> bool:
	var distance_ahead := move_speed * delta + CAPSULE_RADIUS * source_house_scale * 0.55
	var ahead := global_position + heading * distance_ahead
	# The query looks beyond the capsule center: a legal steep ramp can rise
	# farther than one step over that horizontal distance. Actual step-up still
	# has the strict source 20 cm limit in _try_step.
	var slope_rise := distance_ahead * tan(floor_max_angle)
	return not _support_at(ahead, maxf(MAX_STEP_HEIGHT, slope_rise) + 0.06, MAX_STEP_HEIGHT + 0.10).is_empty()

func _supported_heading(heading: Vector3, delta: float) -> Vector3:
	if _footprint_is_supported(heading, delta):
		return heading
	blocked_at_edge = true
	# Allow sliding along a valid shoreline edge without letting diagonal input
	# bypass the support check.
	for alternative in [Vector3(heading.x, 0, 0), Vector3(0, 0, heading.z)]:
		if alternative.length_squared() > 0.001 and _footprint_is_supported(alternative, delta):
			return alternative
	return Vector3.ZERO

func _try_step(motion: Vector3) -> void:
	if motion.length_squared() < 0.000001 or not test_move(global_transform, motion):
		return
	var raised := global_transform
	var lift := Vector3.UP * (MAX_STEP_HEIGHT + CONTACT_MARGIN)
	if test_move(raised, lift):
		return
	raised.origin += lift
	if test_move(raised, motion):
		return
	var next_foot := raised.origin + motion
	var support := _support_at(next_foot, 0.025, MAX_STEP_HEIGHT + 0.04)
	if support.is_empty():
		return
	var rise: float = support.position.y - global_position.y
	if rise > 0.01 and rise <= MAX_STEP_HEIGHT + CONTACT_MARGIN:
		global_position.y = support.position.y + CONTACT_MARGIN
		velocity.y = 0

func _retry_floor_tangent_motion(motion: Vector3) -> void:
	# Some original complex platforms can report the same upward contact at
	# zero travel for every slide iteration. Only retry a motion whose contacts
	# are all flat ground; any wall contact remains blocking. The capsule is
	# swept above the numerical contact margin and swept back onto the floor.
	if motion.length_squared() < 0.000001 or get_slide_collision_count() == 0:
		return
	for i in get_slide_collision_count():
		if get_slide_collision(i).get_normal().y < 0.999:
			return
	var lift := Vector3.UP * CONTACT_MARGIN
	if test_move(global_transform,lift,null,0.0001):
		return
	var raised := global_transform
	raised.origin += lift
	if test_move(raised,motion,null,safe_margin):
		return
	global_transform = raised
	move_and_collide(motion,false,safe_margin)
	move_and_collide(Vector3.DOWN*(CONTACT_MARGIN+MAX_STEP_HEIGHT),false,safe_margin)

func _update_animation(controls: Vector2, is_moving: bool) -> void:
	if controls.length_squared() > 0.01:
		if absf(controls.x) > absf(controls.y):
			last_direction = "right" if controls.x > 0 else "left"
		else:
			last_direction = "down" if controls.y > 0 else "up"
	var animation_name := ("run_" if is_moving else "idle_") + last_direction
	if sprite.animation != animation_name:
		sprite.play(animation_name)

func _update_source_pivot() -> void:
	if not is_instance_valid(sprite):
		return
	for animation in _sprite_manifest.get("animations", []):
		if animation.name != str(sprite.animation):
			continue
		var source_frame: Dictionary = animation.frames[mini(sprite.frame, animation.frames.size() - 1)]
		var source: Dictionary = _sprite_manifest.sprites[source_frame.sprite]
		var region: Array = source.region
		var pivot: Array = source.pivot
		# Sprite center follows the exact source pivot; the collision/camera root
		# never follows a changing alpha bounding box or animation frame center.
		sprite.position = Vector3((float(region[2]) * 0.5 - float(pivot[0])) * PIXEL_SIZE,
			(float(pivot[1]) - float(region[3]) * 0.5) * PIXEL_SIZE, 0) * source_house_scale
		return

func set_source_house_scale(value: float) -> void:
	# UE adjusts actor location by the capsule-height delta on entry/exit.
	# Our controller is already foot-origin, so preserve its global foot position.
	source_house_scale = clampf(value, 0.1, 2.0)
	var collider := get_node_or_null("MovementCapsule") as CollisionShape3D
	if collider != null and collider.shape is CapsuleShape3D:
		collider.shape.radius = CAPSULE_RADIUS * source_house_scale
		collider.shape.height = CAPSULE_HALF_HEIGHT * 2.0 * source_house_scale
		collider.position.y = CAPSULE_HALF_HEIGHT * source_house_scale
	if is_instance_valid(sprite):
		sprite.scale = Vector3.ONE * source_house_scale
		_update_source_pivot()
	set_meta("source_house_scale", source_house_scale)
	# Native SceneHero reflection offsets 0x520/0x524 and constructor stores
	# confirm InSideMoveSpeed=300 cm/s and MoveSpeed=600 cm/s.
	move_speed = 3.0 if source_house_scale < 1.0 else 6.0
