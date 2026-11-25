extends SceneTree
## Actual imported-map physics validation. No substitute terrain/test geometry.

var results: Dictionary = {"tests": []}
var scene: Node3D
var player: CharacterBody3D

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var selected := "wuming"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--map="):
			selected = argument.trim_prefix("--map=")
	scene = Node3D.new()
	root.add_child(scene)
	var collision := preload("res://scripts/original_collision.gd").new()
	scene.add_child(collision)
	results["collision"] = collision.setup(selected)
	player = preload("res://scripts/original_player.gd").new()
	scene.add_child(player)
	await physics_frame
	await physics_frame
	var spawn := Vector3(-89.4105, 3.44927, 10.53873) if selected == "wuming" else Vector3(-61.85358, 3.68085, 28.81919)
	results["map"] = selected
	results["spawn_source_actor"] = _v(spawn)
	results["spawn_supported"] = player.place_at_source_actor_position(spawn)
	results["spawn_foot"] = _v(player.global_position)
	for test in [{"name": "right", "input": Vector2.RIGHT}, {"name": "left", "input": Vector2.LEFT},
		{"name": "up", "input": Vector2.UP}, {"name": "down", "input": Vector2.DOWN}]:
		player.place_at_source_actor_position(spawn)
		player.set_review_motion(Vector2.ZERO)
		for i in 8:
			await physics_frame
		var origin := player.global_position
		player.set_review_motion(test.input)
		var frames_seen: Dictionary = {}
		var edge_frames := 0
		var min_height := origin.y
		var max_height := origin.y
		var max_anchor_error := 0.0
		for i in 240:
			await physics_frame
			frames_seen[str(player.sprite.animation) + ":" + str(player.sprite.frame)] = true
			edge_frames += int(player.blocked_at_edge)
			min_height = minf(min_height, player.global_position.y)
			max_height = maxf(max_height, player.global_position.y)
			max_anchor_error = maxf(max_anchor_error, absf(player.get_camera_anchor().y - player.global_position.y - player.CAPSULE_HALF_HEIGHT))
		player.set_review_motion(Vector2.ZERO)
		for i in 12:
			await physics_frame
		var stopped_step_count: int = player.footsteps.play_count
		for i in 20:
			await physics_frame
		var finish := player.global_position
		var support: Dictionary = collision.probe_support(finish, 0.3, 0.5)
		var item := {"name": test.name, "start": _v(origin), "end": _v(finish), "displacement_m": origin.distance_to(finish),
			"blocked_edge_frames": edge_frames, "height_range": [min_height, max_height], "animation_frames": frames_seen.keys(),
			"supported_at_end": not support.is_empty(), "anchor_offset_error": max_anchor_error,
			"idle_after_release": str(player.sprite.animation).begins_with("idle_"),
			"footsteps_total": player.footsteps.play_count, "footsteps_stop_with_motion": player.footsteps.play_count == stopped_step_count}
		results.tests.append(item)
		print("PLAYER_TEST ", JSON.stringify(item))
	if selected == "wuming":
		results["source_routes"] = []
		for route in [
			{"name": "original_stair_6896_up", "start": Vector3(-79.8, 3.5, 38.231), "input": Vector2.UP, "frames": 48},
			{"name": "original_stair_6896_down", "start": Vector3(-77.3, 4.4, 38.231), "input": Vector2.DOWN, "frames": 48},
			{"name": "original_harbor_boardwalk_right", "start": Vector3(-89.4105,3.45,0), "input": Vector2.RIGHT, "frames": 12},
			{"name": "original_harbor_boardwalk_left", "start": Vector3(-89.4105,3.45,0), "input": Vector2.LEFT, "frames": 12},
			{"name": "original_harbor_boardwalk_up", "start": Vector3(-89.4105,3.45,0), "input": Vector2.UP, "frames": 12},
			{"name": "original_harbor_boardwalk_down", "start": Vector3(-89.4105,3.45,0), "input": Vector2.DOWN, "frames": 12},
			{"name": "original_shore_long", "start": spawn, "input": Vector2.RIGHT, "frames": 1800}
		]:
			player.set_review_motion(Vector2.ZERO)
			var placed: bool = player.place_at_source_actor_position(route.start)
			for i in 8:
				await physics_frame
			var begin := player.global_position
			var route_min := begin.y
			var route_max := begin.y
			var edge_count := 0
			var support_names: Dictionary = {}
			player.set_review_motion(route.input)
			for i in route.frames:
				await physics_frame
				route_min = minf(route_min, player.global_position.y)
				route_max = maxf(route_max, player.global_position.y)
				edge_count += int(player.blocked_at_edge)
				var floor_hit: Dictionary = collision.probe_support(player.global_position, 0.3, 0.5)
				if not floor_hit.is_empty():
					support_names[str(floor_hit.collider.get_meta("source_component", "terrain"))] = true
			player.set_review_motion(Vector2.ZERO)
			for i in 12:
				await physics_frame
			var route_result := {"name": route.name, "placed": placed, "start": _v(begin), "end": _v(player.global_position),
				"height_range": [route_min, route_max], "blocked_edge_frames": edge_count,
				"support_source_components": support_names.keys(), "stays_dry": route_min >= player.MIN_DRY_FOOT_HEIGHT - 0.015}
			results.source_routes.append(route_result)
			print("PLAYER_SOURCE_ROUTE ", JSON.stringify(route_result))
	results["submerged_support_probe"] = {}
	for x in range(-140, 121, 20):
		for z in range(-60, 221, 20):
			var sample := Vector3(x, 0.5, z)
			var seabed: Dictionary = collision.probe_support(sample, 0.4, 20.0)
			if not seabed.is_empty() and seabed.position.y < -0.1:
				results.submerged_support_probe = {"point": _v(sample), "original_seabed_y": seabed.position.y,
					"player_rejects_submerged_support": player._support_at(sample, 0.4, 20.0).is_empty()}
				break
		if not results.submerged_support_probe.is_empty():
			break
	# Source bCanWalkOffLedges=false: probe dock-edge approach and report the
	# observed stopping behavior; do not fabricate a flat acceptance course.
	var output := ProjectSettings.globalize_path("res://../artifacts/wandering-original-worlds-review/player/physics-" + selected + ".json")
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(results, "\t"))
	var success: bool = results.spawn_supported
	for item in results.tests:
		success = success and item.supported_at_end and item.idle_after_release and item.anchor_offset_error < 0.0001
		success = success and item.animation_frames.size() >= 3 and item.displacement_m > 0.5 and item.footsteps_stop_with_motion
	success = success and not results.submerged_support_probe.is_empty() and results.submerged_support_probe.player_rejects_submerged_support
	if selected == "wuming":
		for route in results.source_routes:
			success = success and route.placed and route.stays_dry
			if "stair_6896" in route.name:
				success = success and "6896.0" in route.support_source_components and route.height_range[1] - route.height_range[0] > 0.5
			elif "harbor_boardwalk" in route.name:
				var travel := Vector2(float(route.end[0])-float(route.start[0]),float(route.end[2])-float(route.start[2]))
				success = success and "7084.0" in route.support_source_components and travel.length() > 0.3
			elif "shore_long" in route.name:
				success = success and route.blocked_edge_frames > 100
	print("PLAYER_PHYSICS_RESULT ", "PASS" if success else "FAIL", " ", output)
	quit(0 if success else 2)

func _v(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
