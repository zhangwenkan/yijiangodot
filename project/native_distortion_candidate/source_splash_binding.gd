extends Node
## Captures existing source MultiMeshes after their animation update. No geometry is authored.
const MATERIAL := "/Game/JH/MapEditor/Environment/Ocean/Materials/M_水花.M_水花"
var effect
var scene_root: Node
var audit := {"source_emitters": 0, "active_particles": 0, "mesh_copied": false}
var _draws: Array[MultiMeshInstance3D] = []
var _scan_seconds := 0.0

func configure(root: Node, target_effect: CompositorEffect) -> void:
	scene_root = root
	effect = target_effect
	process_priority = 100
	_scan()

func _scan() -> void:
	_draws.clear()
	if scene_root == null:
		return
	var stack: Array[Node] = [scene_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is not MultiMeshInstance3D:
			continue
		var draw := node as MultiMeshInstance3D
		var material := draw.material_override as ShaderMaterial
		if material != null and str(material.get_meta("source_material", "")) == MATERIAL:
			_draws.append(draw)
	audit["source_emitters"] = _draws.size()
	if not bool(audit["mesh_copied"]) and not _draws.is_empty():
		var material := _draws[0].material_override as ShaderMaterial
		var textures: Array[Texture2D] = []
		for name in ["splash_color_a", "splash_color_b", "splash_normal_a", "splash_normal_b"]:
			textures.append(material.get_shader_parameter(name) as Texture2D)
		audit["mesh_copied"] = effect.configure_original_mesh(_draws[0].multimesh.mesh, textures)

func _process(delta: float) -> void:
	if effect == null or scene_root == null:
		return
	_scan_seconds += delta
	# configure() already scans. A map with no splash must not traverse its
	# entire scene on every frame merely because the correct result is empty.
	if _scan_seconds >= 1.0:
		_scan_seconds = 0.0
		_scan()
	var data := PackedFloat32Array()
	var count := 0
	for draw in _draws:
		if not is_instance_valid(draw) or not draw.is_visible_in_tree() or draw.multimesh == null:
			continue
		var multi := draw.multimesh
		var visible := multi.visible_instance_count if multi.visible_instance_count >= 0 else multi.instance_count
		var material := draw.material_override as ShaderMaterial
		var pivot_value: Variant = material.get_shader_parameter("pivot")
		var pivot := Vector2.ZERO if pivot_value == null else Vector2(pivot_value)
		for i in visible:
			var transform := draw.global_transform * multi.get_instance_transform(i)
			var scale := Vector3(transform.basis.x.length(), transform.basis.y.length(), transform.basis.z.length())
			var color := multi.get_instance_color(i)
			var custom := multi.get_instance_custom_data(i)
			data.append_array(PackedFloat32Array([transform.origin.x, transform.origin.y, transform.origin.z, custom.r, scale.x, scale.y, scale.z, color.a, pivot.x, pivot.y, custom.b, custom.a]))
			count += 1
	effect.submit_source_instances(data, count)
	audit["active_particles"] = count
