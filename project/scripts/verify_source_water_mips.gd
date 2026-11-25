extends SceneTree
var out := ""
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--water-report-dir="):
			out = arg.trim_prefix("--water-report-dir=")
	call_deferred("run")

func run() -> void:
	var scene: Node3D = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading:
		await process_frame
	scene.tour_finished = true
	scene.player.set_review_motion(Vector2.ZERO)
	var report := {"textures": [], "beams": [], "failures": []}
	for mesh in scene.world.find_children("*", "MeshInstance3D", true, false):
		if not mesh.has_meta("source_water_parameters"):
			continue
		var mat: ShaderMaterial = mesh.material_override
		for key in ["waves_1_normal", "waves_2_normal", "water_1_normal", "water_2_normal", "water_3_normal", "water_4_normal"]:
			var tex: Texture2D = mat.get_shader_parameter(key)
			var img := tex.get_image()
			var expected_mips := 9 if str(key).begins_with("waves") else 10
			var passed := img.get_format() == Image.FORMAT_RGTC_RG and img.has_mipmaps() and img.get_mipmap_count() == expected_mips
			report.textures.append({"parameter": key, "path": tex.resource_path, "width": img.get_width(), "height": img.get_height(), "format": img.get_format(), "mips_after_base": img.get_mipmap_count(), "passed": passed})
			if not passed:
				report.failures.append(key)
	for row in [["T_GodRay_Mask01", 10], ["T_TilingNoise02_M", 9]]:
		var tex: Texture2D = scene.environment_driver._texture(row[0])
		var img := tex.get_image()
		var passed: bool = img.has_mipmaps() and img.get_mipmap_count() == int(row[1])
		report.beams.append({"name": row[0], "path": tex.resource_path, "format": img.get_format(), "mips_after_base": img.get_mipmap_count(), "passed": passed})
		if not passed:
			report.failures.append(row[0])
	for i in 90:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join("source-water-mips.png"))
	var attrs: CameraAttributesPractical = scene.camera.attributes
	attrs.dof_blur_near_enabled = false
	attrs.dof_blur_far_enabled = false
	for i in 10:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join("source-water-mips-no-dof.png"))
	var file := FileAccess.open(out.path_join("source-water-mips.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("SOURCE_WATER_MIP_CHECK ", JSON.stringify(report))
	quit(0 if report.failures.is_empty() else 1)
