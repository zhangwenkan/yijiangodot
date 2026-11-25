extends SceneTree
var out := ""
var scene: Node3D
var report := {"emitters":[],"smoke_emitters":[],"textures":[],"failures":[],"samples":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--particle-report-dir="): out = arg.trim_prefix("--particle-report-dir=")
	call_deferred("run")

func run() -> void:
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	scene.tour_finished = true
	scene.player.set_review_motion(Vector2.ZERO)
	var driver: Node
	for node in scene.world.get_children():
		if node.get_script() != null and node.get_script().resource_path.ends_with("/original_particles.gd"): driver = node
	assert(driver != null)
	report["coverage"] = driver.coverage
	for row in [["T_FallingWater_01",10],["T_FallingWater_01_N",10],["T_FallingWater_02",9],["T_FallingWater_02_N",9],["T_TilingNoise03",11],["1_6_smoke2_vg2",12],["Circle_normal",8]]:
		var tex: Texture2D = load("res://assets/environment/particles/"+row[0]+"_native.dds")
		var img := tex.get_image()
		var valid: bool = img.get_mipmap_count()==row[1]
		if row[0].ends_with("_N") or row[0]=="Circle_normal": valid = valid and img.get_format()==Image.FORMAT_RGTC_RG
		report.textures.append({"name":row[0],"format":img.get_format(),"mips_after_base":img.get_mipmap_count(),"passed":valid})
		if not valid: report.failures.append(row[0])
	scene.set_process(false)
	scene.player.set_physics_process(false)
	scene.house_driver.set_process(false)
	scene.camera.follow_target = null
	scene.camera.source_bounds.clear()
	var index := 0
	for e in driver._emitters:
		if not e.splash: continue
		scene.camera.reset_at(e.transform.origin+Vector3(0,1.0,0))
		scene.environment_driver.update_focus(e.transform.origin+Vector3(0,1.0,0))
		for frame in 90: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join("splash-%02d.png"%index))
		var entry := {"source":e.source_group,"position":[e.transform.origin.x,e.transform.origin.y,e.transform.origin.z],"particle_count":e.particles.size(),"samples":[]}
		for p in e.particles.slice(0,6):
			entry.samples.append({"age":p.age,"life":p.life,"dynamic":[p.dynamic_parameters.x,p.dynamic_parameters.y,p.dynamic_parameters.z,p.dynamic_parameters.w],"speed_cm_s":(e.transform.basis*driver._gd(p.current_velocity)).length()})
			if p.dynamic_parameters.z<0.8999 or p.dynamic_parameters.z>1.0001: report.failures.append("dynamic B outside source range")
		report.emitters.append(entry)
		index += 1
	if scene.slug=="wuming" and index !=9: report.failures.append("Expected9 water splash emitters")
	if scene.slug=="youxian" and index !=0: report.failures.append("Youxian must have no water splash emitters")
	var smoke_count := 0
	var first_smoke
	for e in driver._emitters:
		if not e.smoke: continue
		if first_smoke==null: first_smoke=e
		if smoke_count<3:
			scene.camera.reset_at(e.transform.origin+Vector3(0,1.0,0))
			scene.environment_driver.update_focus(e.transform.origin+Vector3(0,1.0,0))
			for frame in 90: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(out.path_join("smoke-%02d.png"%smoke_count))
		var data_image: Image=e.dynamic_texture.get_image()
		var maximum_error := 0.0
		for particle_index in e.particles.size():
			var expected: Vector4=e.particles[particle_index].dynamic_parameters
			var actual: Color=data_image.get_pixel(particle_index,0)
			maximum_error=maxf(maximum_error,absf(expected.x-actual.r))
			maximum_error=maxf(maximum_error,absf(expected.y-actual.g))
			maximum_error=maxf(maximum_error,absf(expected.z-actual.b))
		report.smoke_emitters.append({"source":e.source_group,"count":e.particles.size(),"format":data_image.get_format(),"width":data_image.get_width(),"gpu_texture_max_parameter_error":maximum_error})
		if maximum_error>0.0001 or data_image.get_format()!=Image.FORMAT_RGBAF: report.failures.append("Smoke data texture mismatch")
		smoke_count+=1
	if scene.slug=="wuming" and smoke_count!=11: report.failures.append("Expected11 smoke emitters")
	if first_smoke!=null:
		scene.camera.reset_at(first_smoke.transform.origin+Vector3(0,1.0,0))
		scene.environment_driver.update_focus(first_smoke.transform.origin+Vector3(0,1.0,0))
		var animation_dir:=out.path_join("smoke-motion")
		DirAccess.make_dir_recursive_absolute(animation_dir)
		for step in 24:
			await create_timer(0.5).timeout
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(animation_dir.path_join("frame-%03d.png"%step))
			report.samples.append({"time_msec":Time.get_ticks_msec(),"smoke_count":first_smoke.particles.size(),"maximum_life":driver._maximum(first_smoke.modules.Lifetime[0].Lifetime)})
	if index==0:
		for frame in 60: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join("unchanged-harbor.png"))
	var file := FileAccess.open(out.path_join("splash-validation.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	print("SOURCE_PARTICLE_VALIDATED splash=",index," smoke=",smoke_count," failures=",report.failures)
	quit(0 if report.failures.is_empty() else 1)
