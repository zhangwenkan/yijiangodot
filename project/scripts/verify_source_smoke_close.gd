extends SceneTree
var out := ""
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--particle-report-dir="): out=arg.trim_prefix("--particle-report-dir=")
	call_deferred("run")
func run() -> void:
	var scene: Node3D=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	scene.tour_finished=true
	scene.set_process(false)
	scene.player.set_physics_process(false)
	scene.house_driver.set_process(false)
	scene.camera.follow_target=null
	scene.camera.source_bounds.clear()
	scene.camera.attributes.dof_blur_near_enabled=false
	scene.camera.attributes.dof_blur_far_enabled=false
	var driver: Node
	for node in scene.world.get_children():
		if node.get_script()!=null and node.get_script().resource_path.ends_with("/original_particles.gd"): driver=node
	var smoke
	for emitter in driver._emitters:
		if emitter.smoke:
			smoke=emitter
			break
	assert(smoke!=null)
	scene.camera.reset_at(smoke.transform.origin+Vector3(0,0.6,0))
	scene.camera.zoom=0.22
	scene.camera._apply_pose()
	for frame in 120: await process_frame
	var samples: Array=[]
	for index in 120:
		await create_timer(1.0/15.0).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join("frame-%04d.png"%index))
		var values: Array=[]
		for particle_index in smoke.particles.size():
			var p=smoke.particles[particle_index]
			var col: Color=smoke.multi.get_instance_color(particle_index)
			values.append({"life":p.age/p.life,"temperature":p.dynamic_parameters.x,"intensity":p.dynamic_parameters.y,"mix":p.dynamic_parameters.z,"alpha":col.a,"size_m":str(smoke.multi.get_instance_transform(particle_index).basis.get_scale())})
		samples.append({"actual_time_msec":Time.get_ticks_msec(),"particles":values})
	driver.set_process(false)
	var m: ShaderMaterial=smoke.draw.material_override
	for mode in [1,2,3,4]:
		m.set_shader_parameter("audit_mode",mode)
		for frame in 4: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join("audit-%d.png"%mode))
	var f:=FileAccess.open(out.path_join("smoke-close.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"source":smoke.source_group,"samples":samples,"note":"Close diagnostic camera; actual sample timestamps recorded, PNG sampling is not a performance measurement."},"\t"))
	quit()
