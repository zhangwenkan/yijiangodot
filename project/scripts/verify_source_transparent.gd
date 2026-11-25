extends SceneTree
var out := ""
var scene: Node3D
var report:={"failures":[],"maps":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--transparent-report-dir="): out=arg.trim_prefix("--transparent-report-dir=")
	call_deferred("run")

func shot(label: String) -> void:
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(scene.slug+"-"+label+".png"))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	scene.source_rendering=true
	scene.source_distortion=true
	scene.source_atmosphere=true
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		scene.set_process(false)
		scene.player.set_physics_process(false)
		scene.house_driver.set_physics_process(false)
		scene.camera.follow_target=null
		scene.camera.source_bounds.clear()
		scene.camera.attributes.dof_blur_near_enabled=false
		scene.camera.attributes.dof_blur_far_enabled=false
		var driver: Node
		var binder: Node
		for node in scene.world.get_children():
			if node.get_script()==null: continue
			if node.get_script().resource_path.ends_with("/original_particles.gd"): driver=node
			if node.get_script().resource_path.ends_with("/original_particle_materials.gd"): binder=node
		for i in 150: await process_frame
		driver.set_process(false)
		Engine.time_scale=0.0
		var entry:={"map":slug,"binding":binder.coverage,"textures":{},"families":{}}
		if binder.coverage.bound_emitters!=(81 if slug=="wuming" else 9): report.failures.append(slug+": emitter count")
		for material in binder._materials:
			for key in ["source_texture","source_tiled"]:
				var texture: Texture2D=material.get_shader_parameter(key)
				if texture==null or texture.resource_path=="" or entry.textures.has(texture.resource_path): continue
				var image:=texture.get_image()
				entry.textures[texture.resource_path]={"width":image.get_width(),"height":image.get_height(),"mips":image.get_mipmap_count()+1,"format":image.get_format()}
		for emitter in driver._emitters:
			var material: ShaderMaterial=emitter.draw.material_override
			if not material.get_meta("source_particle_native_material",false): continue
			var family:=str(material.get_meta("source_family"))
			if entry.families.has(family) or emitter.particles.is_empty(): continue
			entry.families[family]={"particles":emitter.particles.size(),"source":emitter.source_group,"fog":material.shader.code.contains("source_hf_vertex_result")}
			var center: Vector3=emitter.draw.global_transform*emitter.multi.get_instance_transform(0).origin
			scene.camera.reset_at(center)
			scene.camera.zoom=.35
			scene.camera._apply_pose()
			await shot(family+"-normal")
			material.set_shader_parameter("audit_mode",2)
			await shot(family+"-alpha")
			material.set_shader_parameter("audit_mode",0)
		report.maps.append(entry)
		Engine.time_scale=1.0
		driver.set_process(true)
		scene.set_process(true)
		scene.house_driver.set_physics_process(true)
	FileAccess.open(out.path_join("transparent-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_TRANSPARENT_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.source_renderer.shutdown()
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
