extends SceneTree
var out := ""
var scene: Node3D
var report := {"diagnostic_only": true, "variants": []}
var sun: DirectionalLight3D
var env: Environment

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lighting-report-dir="):
			out = arg.trim_prefix("--lighting-report-dir=")
	call_deferred("run")

func run() -> void:
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading:
		await process_frame
	scene.tour_finished = true
	scene.player.set_review_motion(Vector2.ZERO)
	var suns: Array[Node] = scene.world.find_children("*", "DirectionalLight3D", true, false)
	sun = suns[0]
	var environments: Array[Node] = scene.world.find_children("*", "WorldEnvironment", true, false)
	env = (environments[0] as WorldEnvironment).environment
	await capture("calibrated-aces")
	var grade: CompositorEffect = load("res://native_film_candidate/original_native_film.gd").new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [grade]
	scene.camera.compositor = compositor
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	# This isolated candidate replaces the curve; native bloom integration is
	# separate. Disable Godot glow after Film so it cannot remap display values.
	env.glow_enabled = false
	await capture("native-film-sun1p5")
	for energy in [3.0, 30.0 / PI, 30.0]:
		sun.light_energy = energy
		await capture("native-film-sun" + str(energy).replace(".", "p"))
	scene.camera.compositor = null
	grade = null
	compositor = null
	var f := FileAccess.open(out.path_join("film-diagnostic.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "\t"))
	quit()

func capture(label: String) -> void:
	for i in 60:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(label + ".png"))
	report.variants.append({"label":label,"sun_energy":sun.light_energy,"tonemap":env.tonemap_mode,"glow":env.glow_enabled})
