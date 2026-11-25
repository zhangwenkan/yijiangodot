extends Node
## Source landscape material formulas recovered from each map's cooked DXBC.
## Reuses the existing landscape mesh and original weight atlas; no geometry changes.

func setup(world: Node3D, slug: String) -> Dictionary:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/environment/source-landscape-materials.json"))
	var policy: Dictionary = source.get(slug, {})
	if policy.is_empty():
		return {"bound": 0, "reason": "missing_source_policy"}
	var material := ShaderMaterial.new()
	material.resource_name = "OriginalLandscape_Compiled_" + slug
	material.shader = load("res://shaders/original_landscape_compiled.gdshader")
	material.set_meta("source_surface_adapter", true)
	material.set_meta("source_surface_family", policy.source_family)
	material.set_meta("source_landscape_compiled", true)
	material.set_shader_parameter("weights_1_4", load("res://assets/%s/landscape/atlas-weights-1-4.png" % slug))
	material.set_shader_parameter("weights_5_8", load("res://assets/%s/landscape/atlas-weights-5-8.png" % slug))
	material.set_shader_parameter("source_normal_xy", load(policy.normal_atlas))
	var metal := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	var spec := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	var rough := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	for entry: Dictionary in policy.layers:
		var index := int(entry.index)
		for pair in [["layer_", "color_texture"], ["normal_", "normal_texture"]]:
			var reference: String = entry.get(pair[1], {}).get("object", "")
			var path := "res://assets/landscape-textures/%s.png" % reference.get_slice(".", 1)
			if ResourceLoader.exists(path):
				material.set_shader_parameter(pair[0] + str(index), load(path))
		var uv: Array = entry.source_uv_cm
		material.set_shader_parameter("layer_uv_" + str(index), Vector2(float(uv[0]), float(uv[1])))
		metal[index] = float(entry.metallic)
		spec[index] = float(entry.specular)
		rough[index] = float(entry.roughness)
	for pair in [["layer_metallic_", metal], ["layer_specular_", spec], ["layer_roughness_", rough]]:
		for part in 2:
			var offset := part * 4
			material.set_shader_parameter(pair[0] + str(part), Vector4(pair[1][offset], pair[1][offset + 1], pair[1][offset + 2], pair[1][offset + 3]))
	var count := 0
	for node: Node in world.find_children("*", "MeshInstance3D", true, false):
		if node.has_meta("original_landscape") or str(node.name).begins_with("OriginalLandscape_"):
			(node as MeshInstance3D).material_override = material
			count += 1
	var report := {"bound": count, "source_family": policy.source_family, "source_components": policy.component_count, "normal_seam_max": policy.source_normal_seam_max_byte_difference}
	print("ORIGINAL_LANDSCAPE_COMPILED_BOUND ", JSON.stringify(report))
	return report
