extends SceneTree
const CAPTURE = preload("res://sky_capture_candidate/capture_source_sky.gd")
var out := ""
var scene: Node3D
var sun: DirectionalLight3D
var env: Environment
var report := {"diagnostic_only":true,"variants":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lighting-report-dir="): out = arg.trim_prefix("--lighting-report-dir=")
	call_deferred("run")

func run() -> void:
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	scene.tour_finished = true
	scene.player.set_review_motion(Vector2.ZERO)
	sun = scene.world.find_children("*","DirectionalLight3D",true,false)[0]
	env = scene.world.find_children("*","WorldEnvironment",true,false)[0].environment
	await screenshot("baseline")
	var film = load("res://native_film_candidate/original_native_film.gd").new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [film]
	scene.camera.compositor = compositor
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.glow_enabled = false
	sun.light_energy = 30.0/PI
	await screenshot("film-source-sun-old-sky")
	var old_sky := env.sky
	var visible_cube: Cubemap = old_sky.sky_material.get_shader_parameter("source_open_sky")
	var candidate = CAPTURE.new()
	root.add_child(candidate)
	var result: Dictionary = await candidate.capture(scene,scene.world,env,out.path_join("capture"),128,Vector3.ZERO)
	report["capture"] = result.report
	if result.error.is_empty():
		env.sky = CAPTURE.make_diffuse_sky(result.cube,visible_cube)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 1.0
		await screenshot("film-source-sun-scene-sky")
	else:
		push_error(result.error)
	candidate.queue_free()
	scene.camera.compositor = null
	film = null
	compositor = null
	var f := FileAccess.open(out.path_join("sky-film-diagnostic.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t"))
	quit(0 if result.error.is_empty() else 1)

func screenshot(label: String) -> void:
	for i in 60: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(label+".png"))
	report.variants.append({"label":label,"sun_energy":sun.light_energy,"tonemap":env.tonemap_mode,"glow":env.glow_enabled,"ambient_source":env.ambient_light_source})
