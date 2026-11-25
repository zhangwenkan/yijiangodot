extends SceneTree
## Run after deployment with --headless --script res://scripts/verify_original_house.gd.
## This is continuous real-collision walking. A blocked entrance is reported, not bypassed.
var results: Array[Dictionary] = []
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene: Node3D = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	for i in 1200:
		await physics_frame
		if is_instance_valid(scene.house_driver) and not scene.loading:
			break
	if not is_instance_valid(scene.house_driver):
		push_error("House verification could not load its first map")
		quit(2)
		return
	for slug in ["wuming", "youxian"]:
		if scene.slug != slug:
			await scene._load_world(slug)
		var house: Node = scene.house_driver
		var player: CharacterBody3D = scene.player
		var camera: Camera3D = scene.camera
		var record: Dictionary = {"map": slug, "binding_report": house.report.duplicate(true), "samples": []}
		_check(_group_matches(house, false), slug + ": initial outside state")
		var outdoor_offset: Vector3 = camera.source_offset
		var into: Dictionary = house._boxes[0]
		var center: Vector3 = into.transform.origin
		var start := center + Vector3(-3.65, 0, 0)
		house.reset_outdoors()
		_check(player.place_at_source_actor_position(start), slug + ": doorway approach has support")
		camera.reset_at(player.get_camera_anchor())
		player.set_review_motion(Vector2.ZERO)
		for i in 20:
			await physics_frame
		player.set_review_motion(Vector2.UP)
		var entry_frame := -1
		for i in 150:
			await physics_frame
			if i % 10 == 0:
				record.samples.append({"phase": "enter", "frame": i, "feet": _v(player.position), "inside": house.is_in_house})
			if house.is_in_house:
				entry_frame = i
				break
		player.set_review_motion(Vector2.ZERO)
		record.entry_frame = entry_frame
		record.entry_feet = _v(player.position)
		_check(entry_frame >= 0, slug + ": continuous walk reached original IntoBox")
		if entry_frame >= 0:
			_check(is_equal_approx(player.source_house_scale, 0.6), slug + ": interior actor scale")
			_check(_group_matches(house, true), slug + ": interior visibility and collision")
			_check(camera.source_offset.distance_to(outdoor_offset) > 1.0, slug + ": interior camera offset")
			_check(scene.environment_driver.get_meta("source_house_interior", false), slug + ": interior environment state")
			# Continue beyond the entry sensor, stop, then return across the original exit box.
			player.set_review_motion(Vector2.UP)
			for i in 12:
				await physics_frame
			player.set_review_motion(Vector2.ZERO)
			for i in 20:
				await physics_frame
			player.set_review_motion(Vector2.DOWN)
			var exit_frame := -1
			for i in 150:
				await physics_frame
				if i % 10 == 0:
					record.samples.append({"phase": "exit", "frame": i, "feet": _v(player.position), "inside": house.is_in_house})
				if not house.is_in_house:
					exit_frame = i
					break
			player.set_review_motion(Vector2.ZERO)
			record.exit_frame = exit_frame
			_check(exit_frame >= 0, slug + ": continuous return reached original exit box")
			_check(_group_matches(house, false), slug + ": restored actor visibility and collision")
			_check(is_equal_approx(player.source_house_scale, 1.0), slug + ": restored actor scale")
			_check(camera.source_offset.is_equal_approx(outdoor_offset), slug + ": restored camera offset")
		# Lifecycle check is explicit and separate from the walk result above.
		house.set_inside(true)
		house.shutdown()
		_check(not house.is_in_house and is_equal_approx(player.source_house_scale, 1.0), slug + ": shutdown restores player")
		_check(camera.source_offset.is_equal_approx(outdoor_offset), slug + ": shutdown restores persistent camera")
		record.exit_feet = _v(player.position)
		results.append(record)
	var output := {"passed": failures.is_empty(), "failures": failures, "maps": results}
	print("ORIGINAL_HOUSE_VERIFICATION ", JSON.stringify(output))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--house-report="):
			var file := FileAccess.open(argument.trim_prefix("--house-report="), FileAccess.WRITE)
			if file != null:
				file.store_string(JSON.stringify(output, "\t"))
	scene.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _group_matches(house: Node, inside: bool) -> bool:
	for group in ["inside_actors", "outside_actors"]:
		var shown: bool = inside if group == "inside_actors" else not inside
		for item in house._data[group]:
			for node in house._visuals.get(item.source_name, []):
				if node.visible != shown:
					return false
			for state in house._bodies.get(item.source_name, []):
				if state.node.collision_layer != (state.layer if shown else 0):
					return false
	return true

func _check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)

func _v(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
