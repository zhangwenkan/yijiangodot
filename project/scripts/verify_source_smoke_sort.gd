extends SceneTree
var out := ""
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--particle-report-dir="): out=arg.trim_prefix("--particle-report-dir=")
	call_deferred("run")
func shot(label: String) -> void:
	for frame in 8: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(label+".png"))
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
	for frame in 160: await process_frame
	driver.set_process(false)
	Engine.time_scale=0.0
	var water: Array=[]
	for node in scene.world.find_children("*","MeshInstance3D",true,false):
		if node.has_meta("source_water_parameters"):
			water.append(node)
	assert(water.size()>0)
	var mat: ShaderMaterial=smoke.draw.material_override
	await shot("priority10-normal")
	smoke.draw.visible=false
	await shot("priority10-no-smoke")
	smoke.draw.visible=true
	for node in water: node.material_override.render_priority=0
	await shot("priority0-normal")
	smoke.draw.visible=false
	await shot("priority0-no-smoke")
	smoke.draw.visible=true
	for node in water: node.visible=false
	await shot("water-hidden-normal")
	for node in water: node.visible=true
	mat.set_shader_parameter("audit_mode",1)
	await shot("priority0-audit1")
	mat.set_shader_parameter("audit_mode",0)
	var vals: Array=[]
	for i in smoke.particles.size():
		var p=smoke.particles[i]
		vals.append({"life":p.age/p.life,"dynamic":str(p.dynamic_parameters),"color":str(smoke.multi.get_instance_color(i)),"instance":str(smoke.multi.get_instance_transform(i))})
	var report={"source":smoke.source_group,"water_count":water.size(),"origin":str(smoke.transform),"particles":vals}
	var file:=FileAccess.open(out.path_join("sort-report.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	quit()
