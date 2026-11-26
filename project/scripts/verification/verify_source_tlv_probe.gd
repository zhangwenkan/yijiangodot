extends SceneTree
## Isolated shadow-query diagnostic. No production rendering changes.
var out := ""
var report: Dictionary = {"captures": [], "failures": [], "scope": "Real Godot directional shadows queried at 64 cubed volume positions; existing Blender quad caster and probe. Synthetic oracle, not original UE parity."}
var readback: CompositorEffect
var sun: DirectionalLight3D
var caster_material: ShaderMaterial
var local_mode := false
var local_light: OmniLight3D
var force_refresh := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tlv-out="): out = arg.trim_prefix("--tlv-out=")
		if arg == "--local-probe": local_mode = true
		if arg == "--force-shadow-refresh": force_refresh = true
	call_deferred("run")

func save_report() -> void:
	FileAccess.open(out.path_join("probe.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))

func capture(label: String) -> void:
	report.stage = label
	save_report()
	if local_mode and force_refresh and local_light.shadow_enabled:
		local_light.shadow_enabled = false
		local_light.shadow_enabled = true
	for i in 8: await process_frame
	if not readback.request_face(report.captures.size()):
		report.failures.append(label + ": capture request rejected")
		return
	var result: Dictionary = {}
	for i in 60:
		await process_frame
		result = readback.take_result()
		if not result.is_empty(): break
	if result.is_empty() or result.has("error"):
		report.failures.append(label + ": " + str(result))
		return
	FileAccess.open(out.path_join(label + ".rgba16f"), FileAccess.WRITE).store_buffer(result.bytes)
	report.captures.append({"label": label, "width": result.size.x, "height": result.size.y,
		"shadow_enabled": local_light.shadow_enabled if local_mode else sun.shadow_enabled,
		"light_visible": local_light.visible if local_mode else sun.visible,
		"query_local":local_mode,
		"caster_uses_time":not force_refresh,
		"explicit_owned_light_refresh":force_refresh,
		"half_mask": caster_material.get_shader_parameter("half_mask"),
		"wind_offset": caster_material.get_shader_parameter("wind_offset")})
	save_report()
	print("TLV_PROBE_CAPTURE ", label)

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	root.disable_3d = true
	var viewport := SubViewport.new()
	viewport.size = Vector2i(512, 512)
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := Node3D.new()
	viewport.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 0, 8)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8.1
	camera.near = 0.01
	camera.far = 16.1
	camera.environment = env
	camera.current = true
	readback = preload("res://sky_capture_candidate/source_sky_hdr_readback.gd").new()
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [readback]
	var imported: Node = load("res://assets/environment/particles/particle-draw.glb").instantiate()
	var quad: Mesh
	for node in imported.find_children("*", "MeshInstance3D", true, false):
		if str(node.name).begins_with("SourceParticleSpriteDraw"): quad = node.mesh
	imported.free()
	if quad == null:
		report.failures.append("Existing Blender quad missing")
		save_report(); quit(2); return
	var caster := MeshInstance3D.new()
	caster.mesh = quad
	caster.scale = Vector3(4, 4, 4)
	caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	caster_material = ShaderMaterial.new()
	caster_material.shader = preload("res://source_tlv_candidate/probe_caster.gdshader")
	if force_refresh:
		var static_shader := Shader.new()
		static_shader.code = caster_material.shader.code.replace(" + sin(TIME) * dynamic_amplitude", "")
		caster_material.shader = static_shader
	caster.material_override = caster_material
	world.add_child(caster)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.shadow_bias = 0.0
	sun.shadow_normal_bias = 0.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	world.add_child(sun)
	if local_mode:
		sun.visible = false
		local_light = OmniLight3D.new()
		local_light.position = Vector3(0, 0, 4)
		local_light.omni_range = 100.0
		local_light.omni_attenuation = 0.0
		local_light.shadow_enabled = true
		local_light.shadow_bias = 0.0
		local_light.shadow_normal_bias = 0.0
		local_light.light_cull_mask = 2
		local_light.shadow_caster_mask = 1
		world.add_child(local_light)
		report.scope = "Real Godot enlarged local Omni shadow query; original caster layer separate from probe illumination layer. Not native UE Spot projection parity."
	var draw := MeshInstance3D.new()
	draw.mesh = quad
	draw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	draw.extra_cull_margin = 32.0
	var material := ShaderMaterial.new()
	material.shader = preload("res://source_tlv_candidate/shadow_probe.gdshader")
	material.set_shader_parameter("query_local", local_mode)
	material.render_priority = 127
	draw.material_override = material
	if local_mode: draw.layers = 2
	world.add_child(draw)
	await capture("opaque-shadow")
	caster_material.set_shader_parameter("half_mask", true)
	await capture("masked-shadow")
	caster_material.set_shader_parameter("wind_offset", 0.25)
	await capture("deformed-masked-shadow")
	sun.shadow_enabled = false
	if local_mode: local_light.shadow_enabled = false
	await capture("shadow-disabled-control")
	sun.visible = false
	if local_mode: local_light.visible = false
	await capture("light-absent-control")
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	camera.compositor = null
	readback = null
	viewport.queue_free()
	for i in 5: await process_frame
	report.stage = "complete"
	save_report()
	quit(0 if report.failures.is_empty() else 1)
