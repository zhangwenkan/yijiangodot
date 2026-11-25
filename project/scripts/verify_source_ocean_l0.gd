extends SceneTree
var scene: Node3D
var out := ""
var report := {"maps":[],"failures":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ocean-l0-report-dir="): out=arg.trim_prefix("--ocean-l0-report-dir=")
	call_deferred("run")

func settle(count: int = 12) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func _material_inventory(node: Node) -> Array:
	var rows: Array=[]
	var seen: Dictionary={}
	for mesh in node.find_children("*","GeometryInstance3D",true,false):
		var mats: Array[Material]=[]
		if mesh.material_override!=null: mats.append(mesh.material_override)
		elif mesh is MeshInstance3D and mesh.mesh!=null:
			for i in mesh.mesh.get_surface_count(): mats.append(mesh.get_active_material(i))
		elif mesh is MultiMeshInstance3D and mesh.multimesh!=null and mesh.multimesh.mesh!=null:
			for i in mesh.multimesh.mesh.get_surface_count(): mats.append(mesh.multimesh.mesh.surface_get_material(i))
		for mat in mats:
			if not mat is ShaderMaterial or mat.shader==null or seen.has(mat.get_instance_id()): continue
			seen[mat.get_instance_id()]=true
			var code: String=mat.shader.code
			var family := ""
			if code.contains("uniform float fake_spec_intensity"): family="Ocean"
			elif code.contains("uniform float source_metallic"): family="Water"
			elif code.contains("vec3 source_blackbody("): family="Smoke1"
			elif code.contains("source_tiled") and code.contains("source_base_color"): family="SmokeSubUV"
			elif code.contains("splash_color_a"): family="Splash"
			elif mat.resource_name=="MAT_788050a6abf1": family="Waterfall imported fallback"
			if family.is_empty(): continue
			rows.append({"family":family,"material":mat.resource_name,"node":str(mesh.get_path()),
				"has_light_function":code.contains("float source_lf_at("),"has_cone":code.contains("source_local_cone_correction"),
				"has_source_SH9":code.contains("source_sh9_evaluate"),"shadows_disabled":code.contains("shadows_disabled"),
				"source_surface_adapter":mat.get_meta("source_surface_adapter",false),
				"albedo_color":mat.get_shader_parameter("albedo_color"),"alpha_clip":mat.get_shader_parameter("alpha_clip"),
				"source_opacity":mat.get_shader_parameter("source_opacity"),"visible":mesh.is_visible_in_tree(),
				"shader_sha256":code.sha256_text()})
	return rows

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		await settle(30)
		var entry: Dictionary={"map":slug,"before_materials":_material_inventory(scene.world),"variants":[]}
		var adapter=load("res://source_ocean_l0_candidate/source_ocean_l0_adapter.gd").new()
		scene.source_renderer.add_child(adapter)
		entry["install"]=adapter.install(scene,"res://sh9_candidate/"+slug+"-source-sh9.json",{})
		adapter.attach_house_driver(scene.house_driver)
		if adapter.report.get("bound",0)<=0: report.failures.append(slug+": no Ocean materials patched")
		if not adapter.report.get("unsupported",[]).is_empty(): report.failures.append(slug+": unsupported materials")
		var old_process: int=scene.process_mode
		var old_time: float=Engine.time_scale
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		for variant in [{"label":"baseline","mode":0,"sky":false},{"label":"point-l0","mode":1,"sky":false},{"label":"point-l0-source-sky","mode":1,"sky":true},{"label":"l0-direct-only","mode":3,"sky":false},{"label":"emission-only","mode":4,"sky":false}]:
			adapter.set_mode(variant.mode,variant.sky)
			await settle()
			root.get_texture().get_image().save_png(out.path_join(slug+"-"+variant.label+".png"))
			entry.variants.append(variant)
		entry["restore"]=adapter.restore()
		if not entry.restore.errors.is_empty(): report.failures.append(slug+": restore failed")
		await settle()
		root.get_texture().get_image().save_png(out.path_join(slug+"-restored.png"))
		entry["after_materials"]=_material_inventory(scene.world)
		scene.process_mode=old_process
		Engine.time_scale=old_time
		adapter.queue_free()
		report.maps.append(entry)
	FileAccess.open(out.path_join("ocean-l0-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_OCEAN_L0_DIAGNOSTIC ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	await settle(5)
	quit(0 if report.failures.is_empty() else 1)
