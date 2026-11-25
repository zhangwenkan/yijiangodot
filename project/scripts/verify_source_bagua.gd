extends SceneTree
## Parent GPU entry after installing original bagua adapter before source renderer.
var scene: Node3D
var out:=""
var report:={"failures":[],"frames":[],"nodes":[]}
func hash_bytes(data: PackedByteArray) -> String:
	var context:=HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish().hex_encode()
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bagua-report-dir="): out=arg.trim_prefix("--bagua-report-dir=")
	call_deferred("run")
func settle(count: int=10) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func digest(node: MeshInstance3D) -> String:
	var parts: Array[String]=[]
	for surface in node.mesh.get_surface_count():
		for value in node.mesh.surface_get_arrays(surface):
			if value!=null: parts.append(hash_bytes(var_to_bytes(value)))
	return str(node.transform)+"|"+"|".join(parts)
func capture(label: String) -> void:
	await settle()
	var image: Image=root.get_texture().get_image()
	image.save_png(out.path_join(label+".png"))
	report.frames.append({"name":label,"width":image.get_width(),"height":image.get_height(),"sha256":hash_bytes(image.get_data())})
func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	if scene.slug!="wuming": await scene._load_world("wuming")
	scene.tour_finished=true
	await settle(30)
	var adapter: Node
	for node in scene.world.find_children("*","Node",true,false):
		var script: Script=node.get_script()
		if script!=null and script.resource_path.ends_with("source_bagua_adapter.gd"):
			adapter=node
			break
	if adapter==null:
		report.failures.append("Source bagua adapter not installed.")
	else:
		report["install"]=adapter.report.duplicate(true)
		if adapter.report.get("bound_surfaces",0)!=4: report.failures.append("Expected exactly four bagua surfaces.")
		var nodes: Array[MeshInstance3D]=[]
		var before: Dictionary={}
		for node in scene.world.find_children("*","MeshInstance3D",true,false):
			if not adapter.NAMES.has(str(node.name)): continue
			nodes.append(node)
			before[str(node.name)]=digest(node)
			var mat: Material=node.get_active_material(0)
			if not mat is ShaderMaterial or not bool(mat.get_meta("source_bagua_compiled",false)):
				report.failures.append("Missing compiled material "+str(node.name))
				continue
			var code: String=mat.shader.code
			report.nodes.append({"node":str(node.name),"visible":node.is_visible_in_tree(),
				"vertices":node.mesh.surface_get_array_len(0),"indices":node.mesh.surface_get_array_index_len(0),
				"light_function":code.contains("source_lf_at"),"cone":code.contains("source_local_cone_correction"),
				"source_sky":code.contains("source_sh9_evaluate"),"source_fog":code.contains("source_height_fog"),
				"opaque":not code.contains("ALPHA ="),"shader_sha256":code.sha256_text()})
		var old_process: int=scene.process_mode
		var old_time: float=Engine.time_scale
		var old_camera: Transform3D=scene.camera.global_transform
		var old_dof_enabled: bool=scene.source_renderer.depth_of_field.effect.enabled
		scene.source_renderer.depth_of_field.effect.enabled=false
		report["inspection_hdr_dof_disabled"]=true
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		for node in nodes:
			var center: Vector3=node.global_transform*node.get_aabb().get_center()
			scene.camera.global_position=center+scene.camera.global_basis.z*9.0
			adapter.set_audit_time(0.0)
			await capture(str(node.name)+"-t0")
			adapter.set_audit_time(2.0)
			await capture(str(node.name)+"-t2")
		if not nodes.is_empty():
			var target: Vector3=nodes[0].global_transform*nodes[0].get_aabb().get_center()
			scene.camera.global_position=target+scene.camera.global_basis.z*5.0
			for mode in [1,2,3,4]:
				adapter.set_audit_view(mode)
				await capture("bagua-audit-"+str(mode))
			adapter.set_audit_view(0)
			adapter.set_audit_time(-1.0)
		for node in nodes:
			if before[str(node.name)]!=digest(node): report.failures.append("Geometry changed "+str(node.name))
		scene.camera.global_transform=old_camera
		scene.source_renderer.depth_of_field.effect.enabled=old_dof_enabled
		scene.process_mode=old_process
		Engine.time_scale=old_time
	FileAccess.open(out.path_join("bagua-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_BAGUA_VALIDATION ",JSON.stringify({"failures":report.failures,"frames":report.frames.size()}))
	scene.queue_free()
	await settle(4)
	quit(0 if report.failures.is_empty() else 1)

