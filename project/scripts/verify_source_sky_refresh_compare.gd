extends "res://scripts/verify_source_reflection.gd"
## Compare current and refreshed irradiance/radiance without deploying resources.
var refresh_root := ""
var capture_directory := "capture-v1"
var integrated_directory := "integrated"
var _old_cube: Cubemap
var _new_cube: Cubemap
var _new_coefficients := PackedVector3Array()
var _sky_material: ShaderMaterial

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--sky-refresh-out="): out=argument.trim_prefix("--sky-refresh-out=")
		if argument.begins_with("--sky-refresh-root="): refresh_root=argument.trim_prefix("--sky-refresh-root=")
		if argument.begins_with("--sky-capture-directory="): capture_directory=argument.trim_prefix("--sky-capture-directory=")
		if argument.begins_with("--sky-integrated-directory="): integrated_directory=argument.trim_prefix("--sky-integrated-directory=")
	call_deferred("run")

func apply_variant(diffuse: bool,radiance: bool) -> void:
	for state: Dictionary in _material_states:
		if state.parameters.has("source_sh9_coefficients"):
			state.material.set_shader_parameter("source_sh9_coefficients",_new_coefficients if diffuse else state.parameters.source_sh9_coefficients)
	_sky_material.set_shader_parameter("source_scene_capture",_new_cube if radiance else _old_cube)

func run() -> void:
	if out.is_empty() or refresh_root.is_empty(): quit(2); return
	root.size=Vector2i(1280,720)
	DirAccess.make_dir_recursive_absolute(out)
	report={"maps":[],"failures":[],"scope":"Same frozen cameras; update diffuse/reflection separately; no native UE pixel equivalence claim"}
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug: String in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		scene.house_driver.reset_outdoors()
		await settle(30)
		var old_time:=Engine.time_scale
		var old_process: int=scene.process_mode
		var camera_before: Transform3D=scene.camera.global_transform
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		_material_states.clear()
		_seen.clear()
		_remember_scene(scene)
		_sky_material=scene.source_renderer.reflection._candidate_sky.sky_material
		_old_cube=_sky_material.get_shader_parameter("source_scene_capture")
		_new_cube=load(refresh_root.path_join(capture_directory).path_join(slug).path_join("capture-0/source_scene_capture.res"))
		var data: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(refresh_root.path_join(integrated_directory).path_join(slug).path_join("source-sh9.json")))
		_new_coefficients.clear()
		for coefficient: Array in data.e_over_pi_coefficients: _new_coefficients.append(Vector3(coefficient[0],coefficient[1],coefficient[2]))
		var entry: Dictionary={"map":slug,"views":[],"new_capture_manifest_sha256":data.capture_manifest_sha256,"new_coefficients":data.e_over_pi_coefficients}
		for view: Dictionary in _views():
			scene.camera.global_transform=view.transform
			var images: Dictionary={}
			for variant: Dictionary in [{"name":"old","diffuse":false,"radiance":false},{"name":"new-diffuse","diffuse":true,"radiance":false},{"name":"new-reflection","diffuse":false,"radiance":true},{"name":"new-both","diffuse":true,"radiance":true},{"name":"old-restored","diffuse":false,"radiance":false}]:
				apply_variant(variant.diffuse,variant.radiance)
				await settle(48)
				var image: Image=root.get_texture().get_image()
				image.save_png(out.path_join(slug+"-"+view.name+"-"+variant.name+".png"))
				images[variant.name]=image
				if variant.name=="old" or variant.name=="new-both":
					await settle(16)
					var repeat: Dictionary=_difference(image,root.get_texture().get_image())
					if repeat.max_channel_delta!=0: report.failures.append(slug+"/"+view.name+"/"+variant.name+": frozen image unstable")
			var result: Dictionary={"name":view.name,"old_to_diffuse":_difference(images.old,images["new-diffuse"]),"old_to_reflection":_difference(images.old,images["new-reflection"]),"old_to_both":_difference(images.old,images["new-both"]),"restored":_difference(images.old,images["old-restored"])}
			if result.restored.max_channel_delta!=0: report.failures.append(slug+"/"+view.name+": restore image mismatch")
			entry.views.append(result)
		entry["material_restoration"]=_check_materials()
		if not entry.material_restoration.errors.is_empty(): report.failures.append(slug+": material restore mismatch")
		scene.camera.global_transform=camera_before
		scene.process_mode=old_process
		Engine.time_scale=old_time
		report.maps.append(entry)
		print("SOURCE_SKY_REFRESH_COMPARE ",slug," ",entry.views)
	FileAccess.open(out.path_join("sky-refresh-comparison.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	scene.source_renderer.shutdown()
	scene.queue_free()
	await settle(8)
	quit(0 if report.failures.is_empty() else 1)
