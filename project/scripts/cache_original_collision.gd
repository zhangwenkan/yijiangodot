extends SceneTree
## Serializes physics Shape3D resources from the original Blender collision GLB.
## No vertices/indices, transforms, source metadata or shape parameters are edited.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var report: Array = []
	for slug in ["wuming", "youxian"]:
		var started := Time.get_ticks_msec()
		var source := preload("res://scripts/original_collision.gd").new()
		root.add_child(source)
		var counts := source.setup(slug, false)
		var packed_root := Node3D.new()
		packed_root.name = "CachedOriginalCollision"
		packed_root.set_meta("source_collision_sha256", FileAccess.get_sha256("res://assets/%s/collision.glb" % slug))
		packed_root.set_meta("collision_report", counts)
		for body in source.get_children():
			source.remove_child(body)
			packed_root.add_child(body)
			body.owner = packed_root
			for collision in body.get_children():
				collision.owner = packed_root
		var packed := PackedScene.new()
		var status := packed.pack(packed_root)
		if status == OK:
			status = ResourceSaver.save(packed, "res://assets/%s/collision-cache.scn" % slug, ResourceSaver.FLAG_COMPRESS)
		var item := {"map": slug, "status": status, "bodies": counts.bodies, "elapsed_ms": Time.get_ticks_msec() - started,
			"source_sha256": packed_root.get_meta("source_collision_sha256")}
		report.append(item)
		print("ORIGINAL_COLLISION_CACHE ", JSON.stringify(item))
		packed_root.free()
		source.queue_free()
		await process_frame
	var report_path := ProjectSettings.globalize_path("res://../artifacts/wandering-original-worlds-review/player/collision-cache-report.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	quit()
