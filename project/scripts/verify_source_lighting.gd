extends SceneTree
var out := ""
var scene: Node3D
var report := {"diagnostic_only": true, "variants": []}
var grading_test := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lighting-report-dir="):
			out = arg.trim_prefix("--lighting-report-dir=")
		if arg == "--grading-test":
			grading_test = true
	call_deferred("run")

func run() -> void:
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading:
		await process_frame
	scene.tour_finished = true
	scene.player.set_review_motion(Vector2.ZERO)
	var suns: Array[Node] = scene.world.find_children("*", "DirectionalLight3D", true, false)
	var sun: DirectionalLight3D = suns[0]
	var source: Dictionary = sun.get_meta("ue_properties")
	await capture("calibrated-sun", sun.light_energy)
	if grading_test:
		var grade: CompositorEffect = load("res://native_grading_candidate/original_native_grading.gd").new()
		var compositor := Compositor.new()
		compositor.compositor_effects = [grade]
		scene.camera.compositor = compositor
		await capture("source-grading", sun.light_energy)
		sun.light_energy = 3.0
		await capture("source-grading-sun3-diagnostic", sun.light_energy)
		scene.camera.compositor = null
		grade = null
		compositor = null
		var grading_file := FileAccess.open(out.path_join("lighting-diagnostic.json"), FileAccess.WRITE)
		grading_file.store_string(JSON.stringify(report, "\t"))
		quit()
		return
	# Isolated source-value comparison, not an assertion of equivalent radiometry.
	sun.light_energy = float(source.Intensity)
	await capture("source-number-sun", sun.light_energy)
	sun.light_energy = float(source.Intensity) / PI
	await capture("source-number-over-pi", sun.light_energy)
	var f := FileAccess.open(out.path_join("lighting-diagnostic.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "\t"))
	quit()

func capture(label: String, energy: float) -> void:
	for i in 60:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(label+".png"))
	report.variants.append({"label":label,"sun_energy":energy})
