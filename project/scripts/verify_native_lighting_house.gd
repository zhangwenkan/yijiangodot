extends SceneTree
## Diagnostic only: actual collision walk, native Film/Bloom and source SH9.
var out := ""
var capture_sky := false
var scene: Node3D
var film: CompositorEffect
var bloom: CompositorEffect
var sh: Node
var height_fog: Node
var local_lights: RefCounted
var env: Environment
var sun: DirectionalLight3D
var failures: Array[String] = []
var report := {"diagnostic_only":true,"maps":[],"bloom_quality_assumption":3}
var record: Dictionary

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lighting-report-dir="): out=arg.trim_prefix("--lighting-report-dir=")
		elif arg=="--capture-source-sky": capture_sky=true
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok: failures.append(scene.slug+": "+label)

func state(label: String) -> Dictionary:
	return {"label":label,"inside":scene.house_driver.is_in_house,
		"sun_energy":sun.light_energy,"sky_enabled":sh.report.get("skylight_enabled"),
		"film_inside":film._inside,"bloom_inside":bloom._inside,
		"ambient_energy":env.ambient_light_energy,"tonemap":env.tonemap_mode,
		"feet":[scene.player.position.x,scene.player.position.y,scene.player.position.z]}

func shot(label: String) -> void:
	for i in 20: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(scene.slug+"-"+label+".png"))
	record.states.append(state(label))

func run() -> void:
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	scene.tour_finished=true
	for slug in ["wuming","youxian"]:
		if scene.slug != slug: await scene._load_world(slug)
		scene.tour_finished=true
		scene.player.set_review_motion(Vector2.ZERO)
		sun=scene.world.find_children("*","DirectionalLight3D",true,false)[0]
		env=scene.world.find_children("*","WorldEnvironment",true,false)[0].environment
		record={"map":slug,"states":[],"walk_samples":[]}
		film=load("res://native_film_candidate/original_native_film.gd").new()
		bloom=load("res://native_bloom_candidate/original_native_bloom.gd").new()
		bloom.set_source_intensities(5.0,5.0)
		var compositor:=Compositor.new()
		compositor.compositor_effects=[bloom,film]
		scene.camera.compositor=compositor
		env.tonemap_mode=Environment.TONE_MAPPER_LINEAR
		env.tonemap_exposure=1.0
		env.glow_enabled=false
		scene.environment_driver.sun_energy_per_source_unit=1.0/PI
		sun.light_energy=30.0/PI
		sh=load("res://sh9_candidate/source_sh9_adapter.gd").new()
		root.add_child(sh)
		var installation: Dictionary=sh.install(scene.world,"res://sh9_candidate/"+slug+"-source-sh9.json",{"include_wind":true})
		record["sh_binding"]={"bound":installation.get("bound",0),"unsupported":installation.get("unsupported",[])}
		check(installation.get("status","")=="installed","SH installed")
		record["house_binding"]=sh.attach_house_driver(scene.house_driver)
		scene.house_driver.house_state_changed.connect(film.set_source_indoor)
		scene.house_driver.house_state_changed.connect(bloom.set_source_indoor)
		film.set_source_indoor(scene.house_driver.is_in_house)
		bloom.set_source_indoor(scene.house_driver.is_in_house)
		await shot("port-before-local-fog")
		local_lights=load("res://source_lighting_candidate/original_local_light_calibration.gd").new()
		record["local_lights"]=local_lights.apply(scene.world,true,true)
		height_fog=load("res://source_lighting_candidate/source_height_fog_adapter.gd").new()
		root.add_child(height_fog)
		record["height_fog"]=height_fog.install(scene.world,env,"res://source_lighting_candidate/"+slug+"-height-fog.json",{})
		check(record.height_fog.get("status","")=="installed","source height fog installed")
		height_fog.attach_house_driver(scene.house_driver)
		if capture_sky:
			# IRRADIANCE overrides Environment ambient, so explicitly disable SH.
			sh.set_skylight_enabled(false)
			var sky_capture=load("res://sky_capture_candidate/capture_source_sky.gd").new()
			root.add_child(sky_capture)
			var capture_result: Dictionary=await sky_capture.capture(scene,scene.world,env,out.path_join(slug).path_join("capture"),128,Vector3.ZERO)
			record["source_sky_capture"]=capture_result.report
			check(capture_result.error.is_empty(),"source-lit source-fog sky capture")
			sh.set_skylight_enabled(true)
			sky_capture.queue_free()
		await shot("port-bloom-film")
		bloom.enabled=false
		await shot("port-film-only")
		bloom.enabled=true
		var center: Vector3=scene.house_driver._boxes[0].transform.origin
		scene.house_driver.reset_outdoors()
		check(scene.player.place_at_source_actor_position(center+Vector3(-3.65,0,0)),"doorway supported")
		scene.camera.reset_at(scene.player.get_camera_anchor())
		await shot("doorway-outside")
		scene.player.set_review_motion(Vector2.UP)
		var entry_frame:=-1
		for i in 150:
			await physics_frame
			if i%10==0: record.walk_samples.append(state("enter-"+str(i)))
			if scene.house_driver.is_in_house:
				entry_frame=i
				break
		scene.player.set_review_motion(Vector2.ZERO)
		check(entry_frame>=0,"real walk reached IntoBox")
		record["entry_frame"]=entry_frame
		if entry_frame>=0:
			scene.player.set_review_motion(Vector2.UP)
			for i in 12: await physics_frame
			scene.player.set_review_motion(Vector2.ZERO)
			await shot("inside-bloom-film")
			check(is_equal_approx(sun.light_energy,3.0/PI),"interior source sun 3/pi")
			check(not sh.report.skylight_enabled,"interior sky disabled")
			check(film._inside and bloom._inside,"interior Film and Bloom changed")
			check(is_equal_approx(scene.player.source_house_scale,0.6),"interior actor scale")
			local_lights.restore()
			await shot("inside-old-local-lights")
			local_lights.apply(scene.world,true,true)
			bloom.enabled=false
			await shot("inside-film-only")
			bloom.enabled=true
			scene.player.set_review_motion(Vector2.DOWN)
			var exit_frame:=-1
			for i in 150:
				await physics_frame
				if i%10==0: record.walk_samples.append(state("exit-"+str(i)))
				if not scene.house_driver.is_in_house:
					exit_frame=i
					break
			scene.player.set_review_motion(Vector2.ZERO)
			record["exit_frame"]=exit_frame
			check(exit_frame>=0,"real walk reached exit box")
			await shot("outside-restored")
			check(is_equal_approx(sun.light_energy,30.0/PI),"outside sun restored")
			check(sh.report.skylight_enabled and not film._inside and not bloom._inside,"outside render state restored")
		record["height_fog_restore"]=height_fog.restore()
		height_fog.queue_free()
		height_fog=null
		local_lights.restore()
		local_lights=null
		record["sh_restore"]=sh.restore()
		check(record.sh_restore.errors.is_empty(),"SH shaders restored")
		scene.house_driver.house_state_changed.disconnect(film.set_source_indoor)
		scene.house_driver.house_state_changed.disconnect(bloom.set_source_indoor)
		scene.camera.compositor=null
		compositor=null
		film=null
		bloom=null
		sh.queue_free()
		sh=null
		report.maps.append(record)
		await process_frame
	report["failures"]=failures
	FileAccess.open(out.path_join("lighting-house.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("NATIVE_LIGHTING_HOUSE_DONE ",JSON.stringify({"failures":failures,"maps":report.maps.size()}))
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if failures.is_empty() else 1)
