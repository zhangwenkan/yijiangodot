extends RefCounted
## Preserve serialized Actor flags omitted by component-only mesh import.
## Initialization only: future source quest actions may change visibility/collision.
const MANIFEST := "res://scripts/data/original-actor-initial-state.json"

static func apply_visuals(root: Node, slug: String) -> Dictionary:
	return _apply(root, slug, false)

static func apply_collisions(root: Node, slug: String) -> Dictionary:
	return _apply(root, slug, true)

static func _apply(root: Node, slug: String, physics: bool) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not parsed is Dictionary or not parsed.get("maps", {}).has(slug):
		push_error("Original actor initial-state manifest missing: " + slug)
		return {"error": "manifest", "map": slug}
	var bindings: Dictionary = {}
	for actor in parsed.maps[slug]:
		for component in actor.components:
			bindings[str(component.source_name)] = actor
	var result := {"map": slug, "kind": "collision" if physics else "visual", "actors": parsed.maps[slug].size(), "bound": 0, "changed": 0}
	_apply_node(root, bindings, physics, result)
	print("ORIGINAL_ACTOR_INITIAL_STATE ", JSON.stringify(result))
	return result

static func _apply_node(node: Node, bindings: Dictionary, physics: bool, result: Dictionary) -> void:
	var source := str(node.get_meta("source_name", ""))
	var actor: Dictionary = bindings.get(source, {})
	# Match source map too; component names are not a cross-package identifier.
	if not actor.is_empty() and str(node.get_meta("source_map", "")) == str(actor.source_map):
		if physics and node is StaticBody3D:
			result.bound += 1
			if not bool(actor.initial_collision_enabled):
				if node.collision_layer != 0 or node.collision_mask != 0:
					result.changed += 1
				# Keep original filters for a future source-backed quest-state adapter.
				if not node.has_meta("source_actor_original_collision_layer"):
					node.set_meta("source_actor_original_collision_layer", node.collision_layer)
					node.set_meta("source_actor_original_collision_mask", node.collision_mask)
				node.collision_layer = 0
				node.collision_mask = 0
				node.set_meta("source_actor_initial_collision_enabled", false)
		elif not physics and node is Node3D:
			result.bound += 1
			if bool(actor.initial_hidden):
				if not node.has_meta("source_actor_original_visible"):
					node.set_meta("source_actor_original_visible", node.visible)
				if node.visible:
					result.changed += 1
				node.visible = false
				node.set_meta("source_actor_initial_hidden", true)
		if (physics and node is StaticBody3D) or (not physics and node is Node3D):
			node.set_meta("source_actor_name", actor.source_actor)
			node.set_meta("source_actor_visible_components", actor.source_visible_components.duplicate(true))
	for child in node.get_children():
		_apply_node(child, bindings, physics, result)
