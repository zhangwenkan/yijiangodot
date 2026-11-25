extends RefCounted
## Bind M_Bjb1 fixed textures omitted by the named-parameter-only import.
## Call before original_surface and lightfunction injection.

static func bind(world: Node3D) -> int:
	var material := ShaderMaterial.new()
	material.resource_name = "MAT_14790ca775f7"
	material.shader = load("res://shaders/original_backdrop_surface.gdshader")
	material.set_shader_parameter("backdrop_color", load("res://assets/environment/surface-textures/T_Bjb1.png"))
	material.set_shader_parameter("backdrop_normal", load("res://assets/environment/surface-textures/T_Bjb1_no.png"))
	material.set_meta("source_surface_adapter", true)
	material.set_meta("source_surface_family", "M_Bjb1")
	material.set_meta("source_material", "Wandering_Sword/Content/JH/MapEditor/Environment/sky/Material/M_Bjb1.uasset::M_Bjb1")
	material.set_meta("source_surface_formula", "compiled DXBC and fixed ReferencedTextures")
	material.set_meta("source_color_texture_group", "TEXTUREGROUP_Pixels2D")
	var count := 0
	for mesh: Node in world.find_children("*", "MeshInstance3D", true, false):
		var node := mesh as MeshInstance3D
		if node.mesh == null:
			continue
		for surface in node.mesh.get_surface_count():
			var current: Material = node.get_active_material(surface)
			if current != null and current.resource_name == "MAT_14790ca775f7":
				node.set_surface_override_material(surface, material)
				count += 1
	print("ORIGINAL_BACKDROP_SURFACE_BOUND ", count)
	return count
