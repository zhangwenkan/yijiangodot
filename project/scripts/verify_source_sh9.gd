extends SceneTree
var out := ""
var captured_sky := ""
var coefficients := "res://sh9_candidate/youxian-source-sh9.json"
var scene: Node3D
var env: Environment
var sun: DirectionalLight3D
var report := {"diagnostic_only":true,"variants":[]}
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lighting-report-dir="): out=arg.trim_prefix("--lighting-report-dir=")
		elif arg.begins_with("--captured-sky="): captured_sky=arg.trim_prefix("--captured-sky=")
		elif arg.begins_with("--sh9-coefficients="): coefficients=arg.trim_prefix("--sh9-coefficients=")
	call_deferred("run")
func shot(label: String) -> void:
	for frame in 30: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(label+".png"))
	report.variants.append({"label":label,"sun_energy":sun.light_energy,"tonemap":env.tonemap_mode})
func run() -> void:
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	scene.tour_finished=true
	scene.player.set_review_motion(Vector2.ZERO)
	sun=scene.world.find_children("*","DirectionalLight3D",true,false)[0]
	env=scene.world.find_children("*","WorldEnvironment",true,false)[0].environment
	for i in 60: await process_frame
	scene.set_process(false)
	scene.house_driver.set_process(false)
	scene.player.set_physics_process(false)
	Engine.time_scale=0.0
	await shot("default-aces")
	var film=load("res://native_film_candidate/original_native_film.gd").new()
	var compositor:=Compositor.new()
	compositor.compositor_effects=[film]
	scene.camera.compositor=compositor
	env.tonemap_mode=Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure=1.0
	env.glow_enabled=false
	sun.light_energy=30.0/PI
	await shot("film-source-sun-old-sky")
	var cube: Cubemap=load(captured_sky)
	var visible_cube: Cubemap=env.sky.sky_material.get_shader_parameter("source_open_sky")
	var capture=load("res://sky_capture_candidate/capture_source_sky.gd")
	env.sky=capture.make_diffuse_sky(cube,visible_cube)
	env.ambient_light_source=Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution=1.0
	await shot("film-source-sun-capture-mip")
	env.ambient_light_energy=1.0
	await shot("film-source-sun-capture-mip-energy1")
	var adapter=load("res://sh9_candidate/source_sh9_adapter.gd").new()
	root.add_child(adapter)
	report["installation"]=adapter.install(scene.world,coefficients,{"include_wind":true})
	await shot("film-source-sun-capture-sh9")
	sun.visible=false
	await shot("film-sky-sh9-no-sun")
	adapter.set_skylight_enabled(false)
	await shot("film-sky-disabled-no-sun")
	adapter.set_skylight_enabled(true)
	sun.visible=true
	report["restore"]=adapter.restore()
	await shot("film-source-sun-restored-mip")
	scene.camera.compositor=null
	film=null
	compositor=null
	var f:=FileAccess.open(out.path_join("sh9-validation.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t"))
	quit()
