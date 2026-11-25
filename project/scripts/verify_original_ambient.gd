extends SceneTree
## Checks source sprites against the imported original map collision.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var slug := "wuming"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--map="):
			slug = argument.trim_prefix("--map=")
	var scene := Node3D.new()
	root.add_child(scene)
	var collision := preload("res://scripts/original_collision.gd").new()
	scene.add_child(collision)
	var collision_report: Dictionary = collision.setup(slug)
	await physics_frame
	await physics_frame
	var ambient := preload("res://scripts/original_ambient_sprites.gd").new()
	scene.add_child(ambient)
	var report: Dictionary = ambient.setup(slug, scene)
	var frame_changes: Dictionary = {}
	var original_positions: Dictionary = {}
	for entry in ambient.sprites:
		var node: AnimatedSprite3D = entry.sprite
		frame_changes[str(entry.definition.component)] = {}
		original_positions[str(entry.definition.component)] = entry.holder.position
	for i in 150:
		await physics_frame
		for entry in ambient.sprites:
			frame_changes[str(entry.definition.component)][str(entry.sprite.frame)] = true
	var changed := 0
	var valid := true
	var items: Array = []
	for entry in ambient.sprites:
		var key := str(entry.definition.component)
		var original: Vector3 = original_positions[key]
		var actual: Vector3 = entry.holder.position
		var count: int = frame_changes[key].size()
		changed += int(count > 1)
		valid = valid and actual.is_finite() and entry.sprite.pixel_size > 0.0 and entry.sprite.sprite_frames.get_frame_texture(entry.sprite.animation,entry.sprite.frame) != null
		items.append({"component":key,"name":entry.definition.name,"unique_frames":count,"source_position":_v(original),"settled_position":_v(actual),"ground_delta":actual.y-original.y,"npc":entry.definition.is_npc,"pixel_size":entry.sprite.pixel_size})
	report.merge({"collision":collision_report,"animated_objects":changed,"valid":valid,"items":items})
	var path := ProjectSettings.globalize_path("res://../artifacts/wandering-original-worlds-review/player/ambient-"+slug+"-test.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var output := FileAccess.open(path,FileAccess.WRITE)
	output.store_string(JSON.stringify(report,"\t"))
	print("ORIGINAL_AMBIENT_TEST ",slug," objects=",items.size()," animated=",changed," valid=",valid)
	quit(0 if valid and items.size() > 0 and changed > 0 else 1)

func _v(value: Vector3) -> Array:
	return [value.x,value.y,value.z]
