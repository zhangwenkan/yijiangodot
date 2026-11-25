extends SceneTree
var scene: Node3D
var out:=""
var report:={"maps":[],"failures":[],"scope":"Original Water roughness 0 against previous 0.5; all other inputs frozen. Not full source reflection or TLV parity."}
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--water-roughness-report-dir="):out=arg.trim_prefix("--water-roughness-report-dir=")
	call_deferred("run")
func check(value: bool,message: String) -> void:
	if not value:report.failures.append(message)
func capture(name: String) -> String:
	for i in 12:await process_frame
	await RenderingServer.frame_post_draw
	var image: Image=root.get_texture().get_image()
	image.save_png(out.path_join(name+".png"))
	var hash:=HashingContext.new()
	hash.start(HashingContext.HASH_SHA256);hash.update(image.get_data())
	return hash.finish().hex_encode()
func run() -> void:
	if out.is_empty():quit(2);return
	DirAccess.make_dir_recursive_absolute(out)
	root.size=Vector2i(1280,720)
	scene=load("res://worlds.tscn").instantiate();root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading:await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug:await scene._load_world(slug)
		scene.tour_finished=true
		for i in 30:await process_frame
		var bindings: Array[Dictionary]=[]
		var seen: Dictionary={}
		for node in scene.world.find_children("*","MeshInstance3D",true,false):
			if node.mesh==null:continue
			for surface in node.mesh.get_surface_count():
				var mat: Material=node.get_active_material(surface)
				if not mat is ShaderMaterial or mat.shader==null or seen.has(mat.get_instance_id()):continue
				if not mat.shader.code.contains("uniform float source_metallic"):continue
				seen[mat.get_instance_id()]=true
				check(mat.shader.code.count("ROUGHNESS = 0.0;")==1,slug+": source water roughness not zero")
				var values: Dictionary={}
				for uniform in mat.shader.get_shader_uniform_list():values[uniform.name]=mat.get_shader_parameter(uniform.name)
				bindings.append({"material":mat,"shader":mat.shader,"values":values,"node":str(node.get_path()),"mesh":node.mesh})
		check(bindings.size()==1,slug+": expected one Water material")
		var old_mode: int=scene.process_mode
		var old_scale:=Engine.time_scale
		scene.process_mode=Node.PROCESS_MODE_DISABLED;Engine.time_scale=0.0
		var source_hash:=await capture(slug+"-source-roughness-zero")
		for row in bindings:
			var replacement:=Shader.new()
			replacement.code=row.shader.code.replace("ROUGHNESS = 0.0;","ROUGHNESS = 0.5;")
			row.material.shader=replacement
			for key in row.values:row.material.set_shader_parameter(key,row.values[key])
		var previous_hash:=await capture(slug+"-previous-roughness-half")
		for row in bindings:
			row.material.shader=row.shader
			for key in row.values:row.material.set_shader_parameter(key,row.values[key])
		var restored_hash:=await capture(slug+"-restored-source")
		check(source_hash==restored_hash,slug+": source restore image mismatch")
		report.maps.append({"map":slug,"bound":bindings.size(),"source_sha256":source_hash,"previous_sha256":previous_hash,"restore_sha256":restored_hash,"changed_pixels":source_hash!=previous_hash})
		scene.process_mode=old_mode;Engine.time_scale=old_scale
	FileAccess.open(out.path_join("water-roughness-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_WATER_ROUGHNESS_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	for i in 5:await process_frame
	quit(0 if report.failures.is_empty() else 1)
