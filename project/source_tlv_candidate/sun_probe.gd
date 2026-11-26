extends Node
## Separate camera and its real scene shadows. Candidate only: current Godot
## 8-bit directional attenuation, not the original UE cascade shadow atlas.
const LAYER := 1 << 19
var viewport: SubViewport
var camera: Camera3D
var draw: MeshInstance3D
var material: ShaderMaterial
var readback: CompositorEffect
var report: Dictionary = {}
var _main_camera: Camera3D
var _main_mask := 0
var _sun: DirectionalLight3D

func install(scene: Node3D) -> Dictionary:
	_main_camera = scene.camera
	_main_mask = _main_camera.cull_mask
	var suns: Array[Node] = scene.world.find_children("*", "DirectionalLight3D", true, false)
	if suns.size() != 1: return {"error":"Expected exactly one source sun"}
	_sun = suns[0]
	var source_lf: ShaderMaterial = scene.source_renderer._find_lightfunction_material(scene.world)
	if source_lf == null: return {"error":"Source LightFunction bindings missing"}
	var packed: Node = load("res://assets/environment/particles/particle-draw.glb").instantiate()
	var mesh: Mesh
	for child in packed.find_children("*", "MeshInstance3D", true, false):
		if str(child.name).begins_with("SourceParticleSpriteDraw"): mesh = child.mesh
	packed.free()
	if mesh == null: return {"error":"Blender draw quad missing"}
	viewport = SubViewport.new()
	viewport.size = Vector2i(512, 512)
	viewport.world_3d = scene.get_world_3d()
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	camera = Camera3D.new()
	viewport.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.cull_mask = _main_mask | LAYER
	camera.current = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	camera.environment = env
	readback = preload("res://sky_capture_candidate/source_sky_hdr_readback.gd").new()
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [readback]
	material = ShaderMaterial.new()
	material.shader = preload("res://source_tlv_candidate/sun_volume_probe.gdshader")
	material.render_priority = 127
	for pair in [["lf_local_y","source_lf_local_y"], ["lf_local_z","source_lf_local_z"],
		["lf_tiling_power","source_lf_tiling_power"], ["lf_speeds","source_lf_speeds"]]:
		material.set_shader_parameter(pair[0], source_lf.get_shader_parameter(pair[1])[0])
	var scale4: Vector4 = source_lf.get_shader_parameter("source_lf_scale_fade")[0]
	material.set_shader_parameter("lf_scale", Vector2(scale4.x, scale4.y))
	for key in ["spot_offsets", "spot_sizes", "sun_color", "cloud1", "cloud2"]:
		material.set_shader_parameter("lf_" + key, source_lf.get_shader_parameter("source_lf_" + key))
	material.set_shader_parameter("sun_world_direction", _sun.global_basis.z.normalized())
	draw = MeshInstance3D.new()
	draw.mesh = mesh
	draw.layers = LAYER
	draw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	draw.extra_cull_margin = 4.0
	draw.material_override = material
	camera.add_child(draw)
	draw.position.z = -1.0
	_main_camera.cull_mask = _main_mask & ~LAYER
	report = {"status":"installed", "sun":str(_sun.get_meta("source_name")),
		"camera_mask":camera.cull_mask, "main_mask_before":_main_mask,
		"atlas_layout":"8x8 tiles, each 64x64 UE XY, Z=tileY*8+tileX",
		"production_ready":false,"main_view_caster_equivalence":"not established: camera-dependent wind and Sprite3D billboards require a matching caster pass",
		"query_normal":"world direction towards sun; not a source surface normal",
		"scope":"Actual probe-view scene shadow + source LF. Separate orthographic shadow projection; 8-bit Godot attenuation. No local-light input or source shadow parity."}
	return report

func set_bounds(min_ue_cm: Vector3, voxel_cm: float) -> void:
	material.set_shader_parameter("volume_min_ue_cm", min_ue_cm)
	material.set_shader_parameter("voxel_cm", voxel_cm)
	material.set_shader_parameter("lf_enabled", not bool(_sun.get_meta("source_house_light_function_disabled", false)))
	var center_godot := (min_ue_cm + Vector3.ONE * voxel_cm * 32.0) * 0.01
	center_godot = Vector3(center_godot.x, center_godot.z, center_godot.y)
	var size_m := voxel_cm * 66.0 * 0.01
	camera.position = center_godot + Vector3(0, 0, size_m)
	camera.near = 0.01
	camera.far = size_m * 2.0
	camera.size = size_m
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func restore() -> void:
	if is_instance_valid(_main_camera): _main_camera.cull_mask = _main_mask
	if is_instance_valid(viewport):
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		camera.compositor = null
		viewport.queue_free()
	readback = null
