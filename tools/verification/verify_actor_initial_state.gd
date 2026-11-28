extends SceneTree
const Policy = preload("res://scripts/original_actor_initial_state.gd")
var failures: Array = []
var checks := 0
var output: Dictionary = {}
func _initialize() -> void:
	call_deferred("_run")
func require(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _run() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://fixtures.json"))
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Policy.MANIFEST))
	var houses: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/environment/original-houses.json"))
	for slug in ["wuming", "youxian"]:
		var expected: Dictionary = manifest.expected_bindings[slug]
		var visual := Node3D.new()
		var bodies := Node3D.new()
		root.add_child(visual)
		root.add_child(bodies)
		var allowed: Dictionary = {}
		for actor in manifest.maps[slug]:
			for component in actor.components:
				allowed[str(actor.source_map)+"|"+str(component.source_name)] = actor
			for group in ["inside_actors", "outside_actors"]:
				for house_actor in houses.maps[slug][group]:
					require(house_actor.source_name != actor.source_actor, slug+": house overlaps initial-state actor")
		for kind in ["visual", "collision"]:
			var parent: Node3D = visual if kind == "visual" else bodies
			for row in fixture[slug][kind]:
				var node: Node3D = Node3D.new() if kind == "visual" else StaticBody3D.new()
				node.name = row.name
				node.set_meta("source_name", row.source_name)
				node.set_meta("source_map", row.source_map)
				node.visible = bool(row.source_visible) if kind == "visual" else true
				if node is StaticBody3D:
					node.collision_layer = 5
					node.collision_mask = 7
				parent.add_child(node)
		var before_visual_count: int = visual.get_child_count()
		var before_body_count: int = bodies.get_child_count()
		var visual_report: Dictionary = Policy.apply_visuals(visual, slug)
		var collision_report: Dictionary = Policy.apply_collisions(bodies, slug)
		require(visual_report.bound == int(expected.visual_nodes), slug+": visual binding count")
		require(visual_report.changed == int(expected.new_visual_hides), slug+": changed visual count")
		require(collision_report.bound == int(expected.collision_bodies), slug+": collision binding count")
		require(collision_report.changed == int(expected.collision_bodies), slug+": changed collision count")
		require(before_visual_count == visual.get_child_count() and before_body_count == bodies.get_child_count(), slug+": no source nodes removed")
		for kind in ["visual", "collision"]:
			var parent: Node3D = visual if kind == "visual" else bodies
			for i in parent.get_child_count():
				var node: Node3D = parent.get_child(i)
				var row: Dictionary = fixture[slug][kind][i]
				var actor: Dictionary = allowed.get(str(row.source_map)+"|"+str(row.source_name),{})
				if kind == "visual":
					require(node.visible == (bool(row.source_visible) if actor.is_empty() else false), slug+": exact visual policy "+str(row.name))
					if not actor.is_empty():
						require(node.get_meta("source_actor_original_visible") == bool(row.source_visible), slug+": original component visibility saved")
				else:
					require(node.collision_layer == (5 if actor.is_empty() else 0), slug+": exact collision policy "+str(row.name))
					require(node.collision_mask == (7 if actor.is_empty() else 0), slug+": exact collision mask "+str(row.name))
				if not actor.is_empty():
					require(node.get_meta("source_actor_visible_components") == actor.source_visible_components, slug+": raw ordered quest evidence retained")
		var house := preload("res://scripts/original_house.gd").new()
		house._data = houses.maps[slug]
		house._index_visuals(visual)
		house._index_collisions(bodies)
		for inside in [true,false,true,false]:
			house._set_group("inside_actors", inside)
			house._set_group("outside_actors", not inside)
			for node in visual.get_children():
				if node.has_meta("source_actor_initial_hidden"):
					require(not node.visible, slug+": house transition preserves initial target")
			for node in bodies.get_children():
				if node.has_meta("source_actor_initial_collision_enabled"):
					require(node.collision_layer == 0, slug+": house transition preserves collision target")
		house.free()
		var second: Dictionary = Policy.apply_collisions(bodies, slug)
		require(second.changed == 0, slug+": cache/reapply is idempotent")
		for node in bodies.get_children():
			if node.has_meta("source_actor_original_collision_layer"):
				require(node.get_meta("source_actor_original_collision_layer") == 5, slug+": future original filters retained")
				require(node.get_meta("source_actor_original_collision_mask") == 7, slug+": future original mask retained")
		output[slug] = {"visual":visual_report,"collision":collision_report,"source_visual_nodes":before_visual_count,"source_collision_nodes":before_body_count}
		visual.free()
		bodies.free()
	# Same component name in a different package and a prefix collision must stay visible.
	var actor: Dictionary = manifest.maps.wuming[0]
	var comp: Dictionary = actor.components[0]
	var negative := Node3D.new()
	for wrong in ["other-map", "name-prefix"]:
		var node := Node3D.new()
		node.set_meta("source_name", str(comp.source_name) + ("_extra" if wrong == "name-prefix" else ""))
		node.set_meta("source_map", "different.umap" if wrong == "other-map" else actor.source_map)
		negative.add_child(node)
	var rejected: Dictionary = Policy.apply_visuals(negative,"wuming")
	require(rejected.bound == 0, "wrong map/name does not match")
	for node in negative.get_children():require(node.visible, "negative fixture remains visible")
	negative.free()
	output["checks"] = checks
	output["failures"] = failures
	output["passed"] = failures.is_empty()
	var file := FileAccess.open("res://result.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t"))
	file.close()
	print("ACTOR_INITIAL_TEST ", JSON.stringify({"checks":checks,"failures":failures}))
	quit(0 if failures.is_empty() else 1)
