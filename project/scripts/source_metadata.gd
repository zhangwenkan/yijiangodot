extends RefCounted
## Godot's GLTF importer may retain extras as one nested dictionary or omit it.
## Read the source GLB JSON chunk and restore authored extras to nodes by exact name.
static func restore(root: Node, glb_path: String) -> int:
	var file := FileAccess.open(glb_path, FileAccess.READ)
	if file == null or file.get_32() != 0x46546c67:
		push_warning("Cannot read source GLB metadata: " + glb_path)
		return 0
	file.get_32()
	file.get_32()
	var json_length := file.get_32()
	if file.get_32() != 0x4e4f534a:
		return 0
	var document = JSON.parse_string(file.get_buffer(json_length).get_string_from_utf8())
	if not document is Dictionary:
		return 0
	var extras: Dictionary = {}
	for source_node in document.get("nodes", []):
		if source_node.has("extras"):
			extras[source_node.get("name", "")] = source_node["extras"]
	# Blender duplicate suffixes such as .001 become _001 during Godot import.
	# Add aliases only after exact names so a valid exact name is never overwritten.
	for source_name in extras.keys():
		var sanitized := str(source_name).replace(".", "_")
		if not extras.has(sanitized):
			extras[sanitized] = extras[source_name]
	var restored := _restore_node(root, extras)
	print("SOURCE_METADATA_RESTORED ", glb_path, " nodes=", restored)
	return restored

static func _restore_node(node: Node, extras: Dictionary) -> int:
	var count := 0
	var values: Dictionary = extras.get(str(node.name), {})
	if not values.is_empty():
		for key in values:
			node.set_meta(key, values[key])
		count += 1
	for child in node.get_children():
		count += _restore_node(child, extras)
	return count
