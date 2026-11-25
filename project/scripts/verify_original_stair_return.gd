extends SceneTree

var player: CharacterBody3D
var samples: Array = []
var cases: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var collision := preload("res://scripts/original_collision.gd").new()
	scene.add_child(collision)
	collision.setup("wuming")
	player = preload("res://scripts/original_player.gd").new()
	scene.add_child(player)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.rotation = Vector3(-0.253072410821915,-1.57079637050629,0.0)
	player.configure(camera)
	await physics_frame
	await physics_frame
	for case_name in ["continuous_up_stop_down","exact_gpu_stuck_footprint"]:
		await _run_case(case_name)
	var passed := true
	for item in cases:
		passed = passed and item.passed
	var report_path := ProjectSettings.globalize_path("res://../artifacts/wandering-original-worlds-review/player/stair-return-regression.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var output := FileAccess.open(report_path,FileAccess.WRITE)
	output.store_string(JSON.stringify({"passed":passed,"cases":cases,"samples":samples},"\t"))
	print("STAIR_RETURN_REGRESSION ","PASS" if passed else "FAIL"," ",JSON.stringify(cases))
	player.set_review_motion(Vector2.ZERO)
	for i in 15:
		await physics_frame
	scene.queue_free()
	await process_frame
	quit(0 if passed else 1)

func _run_case(case_name: String) -> void:
	player.place_at_source_actor_position(Vector3(-79.8,3.5,38.231))
	var top := Vector3.ZERO
	var first_return := Vector3.ZERO
	for phase in [
		{"name":"settle","frames":30,"motion":Vector2.ZERO},
		{"name":"up","frames":108,"motion":Vector2.UP},
		{"name":"stop","frames":180,"motion":Vector2.ZERO},
		{"name":"return_down","frames":108,"motion":Vector2.DOWN}
	]:
		if phase.name == "stop" and case_name == "exact_gpu_stuck_footprint":
			player.position = Vector3(-76.8778915,3.3488419,38.2308426)
			player.velocity = Vector3.ZERO
		if phase.name == "return_down":
			top = player.position
		player.set_review_motion(phase.motion)
		for i in phase.frames:
			await physics_frame
			if phase.name == "return_down" and i == 9:
				first_return = player.position
			if i < 10 or i % 15 == 0 or i == phase.frames-1:
				var contacts: Array = []
				for n in player.get_slide_collision_count():
					var contact := player.get_slide_collision(n)
					var body: Object = contact.get_collider()
					contacts.append({"normal":_v(contact.get_normal()),"point":_v(contact.get_position()),"travel":_v(contact.get_travel()),"remainder":_v(contact.get_remainder()),"depth":contact.get_depth(),"collider":str(body.get("name")),"source":str(body.get_meta("source_component", "terrain"))})
				samples.append({"case":case_name,"phase":phase.name,"frame":i,"feet":_v(player.position),"velocity":_v(player.velocity),"on_floor":player.is_on_floor(),"floor_normal":_v(player.get_floor_normal()),"edge_blocked":player.blocked_at_edge,"contacts":contacts})
	var returned: Vector3 = player.position
	cases.append({"name":case_name,"top":_v(top),"after_10_return_frames":_v(first_return),"returned":_v(returned),"passed":first_return.x < top.x-0.3 and returned.x < -79.8 and returned.y < 3.0})

func _v(v: Vector3) -> Array:
	return [v.x,v.y,v.z]
