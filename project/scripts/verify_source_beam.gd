extends SceneTree
var out := ""
var scene: Node3D
var report:={"failures":[],"frames":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--beam-report-dir="): out=arg.trim_prefix("--beam-report-dir=")
	call_deferred("run")

func shot(label: String) -> void:
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(label+".png"))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	scene.source_rendering=true
	scene.source_distortion=true
	scene.source_atmosphere=true
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	scene.tour_finished=true
	scene.set_process(false)
	scene.player.set_physics_process(false)
	scene.house_driver.set_physics_process(false)
	scene.camera.follow_target=null
	scene.camera.source_bounds.clear()
	scene.camera.attributes.dof_blur_near_enabled=false
	scene.camera.attributes.dof_blur_far_enabled=false
	var beam: Node
	for node in scene.world.get_children():
		if node.get_script()!=null and node.get_script().resource_path.ends_with("/original_torch_beam.gd"): beam=node
	var meshes: Array[Node]=beam._generated.find_children("*","MeshInstance3D",true,false)
	var mesh: MeshInstance3D=meshes[0]
	var center: Vector3=mesh.global_transform*(mesh.get_aabb().get_center())
	report["mesh"]={"global":mesh.global_transform,"bounds":mesh.get_aabb(),"center":center,"uv":str(mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV])}
	report["beam"]=beam.coverage
	scene.camera.reset_at(center)
	scene.camera.zoom=.18
	scene.camera._apply_pose()
	for i in 40: await process_frame
	report["screen_center"]=scene.camera.unproject_position(center)
	Engine.time_scale=0.0
	for mode in [0,1,2,3,4,5]:
		beam.set_audit_mode(mode,.13)
		await shot("beam-audit-%d"%mode)
	for i in 8:
		beam.set_audit_mode(0,.1*float(i))
		await shot("beam-time-%02d"%i)
		report.frames.append({"time":.1*float(i),"name":"beam-time-%02d.png"%i})
	beam.set_audit_mode(0,-1.0)
	Engine.time_scale=1.0
	FileAccess.open(out.path_join("beam-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_BEAM_VERIFIED ",JSON.stringify({"mesh_count":meshes.size(),"beam_count":beam.coverage.bound_beam_emitters,"center":center}))
	scene.source_renderer.shutdown()
	scene.queue_free()
	for i in 5: await process_frame
	quit()
