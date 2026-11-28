extends Node3D
## Loads only Blender-authored collision meshes. No visible geometry is generated.
## Layer 1 is physical blocking; bit 4 identifies real ground/support for downward probes.

const MetadataRestore = preload("res://scripts/source_metadata.gd")
var report: Dictionary = {}

func setup(slug: String, use_cache := true) -> Dictionary:
	var path := "res://assets/%s/collision.glb" % slug
	var cache_path := "res://assets/%s/collision-cache.scn" % slug
	if use_cache and ResourceLoader.exists(cache_path):
		var cached: Node3D = load(cache_path).instantiate()
		if cached.get_meta("source_collision_sha256", "") == FileAccess.get_sha256(path):
			add_child(cached)
			report = cached.get_meta("collision_report", {}).duplicate()
			report["map"] = slug
			report["cached"] = true
			report["actor_initial_state"] = preload("res://scripts/original_actor_initial_state.gd").apply_collisions(cached, slug)
			print("ORIGINAL_COLLISION_READY ", JSON.stringify(report))
			return report
		cached.free()
	var source: Node3D
	if ResourceLoader.exists(path):
		source = load(path).instantiate()
	else:
		# Supports a first lightweight physics check before the editor imports the GLB.
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var error := document.append_from_file(path, state)
		if error != OK:
			push_error("Cannot load original collision asset: " + path)
			return {"map": slug, "error": error, "bodies": 0}
		source = document.generate_scene(state)
	MetadataRestore.restore(source, path)
	report = build_collision_from_scene(source)
	report["map"] = slug
	report["actor_initial_state"] = preload("res://scripts/original_actor_initial_state.gd").apply_collisions(self, slug)
	print("ORIGINAL_COLLISION_READY ", JSON.stringify(report))
	source.free()
	return report

func build_collision_from_scene(source: Node3D) -> Dictionary:
	var counts := {"nodes": 0, "bodies": 0, "support": 0, "blocker": 0, "convex": 0, "trimesh": 0, "skipped_degenerate": 0, "failed": 0}
	for node in source.find_children("*", "MeshInstance3D", true, false):
		counts.nodes += 1
		if bool(node.get_meta("collision_degenerate", false)):
			counts.skipped_degenerate += 1
			continue
		if node.mesh == null:
			counts.failed += 1
			continue
		var role := str(node.get_meta("collision_role", ""))
		var kind := str(node.get_meta("collision_shape", ""))
		if role not in ["support", "blocker"] or kind not in ["convex", "trimesh"]:
			push_error("Missing original collision metadata: " + str(node.name))
			counts.failed += 1
			continue
		var shape: Shape3D
		if kind == "convex":
			shape = node.mesh.create_convex_shape(true, false)
		else:
			shape = node.mesh.create_trimesh_shape()
			if shape is ConcavePolygonShape3D:
				shape.backface_collision = true
		if shape == null:
			push_error("Cannot create original collision shape: " + str(node.name))
			counts.failed += 1
			continue
		var body := StaticBody3D.new()
		body.name = node.name
		body.collision_layer = 5 if role == "support" else 1
		body.collision_mask = 0
		for key in node.get_meta_list():
			body.set_meta(key, node.get_meta(key))
		var collision := CollisionShape3D.new()
		collision.name = "OriginalSourceShape"
		collision.shape = shape
		body.add_child(collision)
		# All authored nodes have unit transforms and vertices in original world space.
		body.transform = node.transform
		add_child(body)
		counts.bodies += 1
		counts[role] += 1
		counts[kind] += 1
	return counts

func probe_support(world_position: Vector3, above := 1.5, below := 4.0) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(world_position + Vector3.UP * above, world_position - Vector3.UP * below, 4)
	query.hit_from_inside = false
	query.hit_back_faces = true
	return get_world_3d().direct_space_state.intersect_ray(query)
