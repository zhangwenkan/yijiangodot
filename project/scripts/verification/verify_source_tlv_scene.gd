extends SceneTree
var out := ""
var scene: Node3D
var probe: Node
var report: Dictionary = {"captures":[], "maps":[], "failures":[],
	"scope":"Candidate actual-map sun shadow and source LightFunction input, not full TLV nor production material replacement."}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tlv-out="): out = arg.trim_prefix("--tlv-out=")
	call_deferred("run")

func progress(stage: String) -> void:
	report.stage = stage
	FileAccess.open(out.path_join("scene-probe.json"), FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("TLV_SCENE_PROGRESS ", stage)

func capture(label: String, bounds: Dictionary, cascade: int) -> void:
	progress(label)
	probe.set_bounds(bounds.min_ue_cm, bounds.voxel_cm)
	for i in 6: await process_frame
	if not probe.readback.request_face(report.captures.size()):
		report.failures.append(label + ": capture rejected"); return
	var result: Dictionary = {}
	for i in 60:
		await process_frame
		result = probe.readback.take_result()
		if not result.is_empty(): break
	if result.is_empty() or result.has("error"):
		report.failures.append(label + ": " + str(result)); return
	FileAccess.open(out.path_join(label+".rgba16f"), FileAccess.WRITE).store_buffer(result.bytes)
	var sun: DirectionalLight3D = probe.get("_sun")
	report.captures.append({"label":label,"cascade":cascade,"bounds":bounds,
		"min_ue_cm":[bounds.min_ue_cm.x,bounds.min_ue_cm.y,bounds.min_ue_cm.z],
		"sun_direction_ue": [sun.global_basis.z.x,sun.global_basis.z.z,sun.global_basis.z.y],
		"sun_energy":sun.light_energy,"sun_color":str(sun.light_color),
		"shadow":sun.shadow_enabled,"source_properties":sun.get_meta("ue_properties"),
		"camera_pose":str(scene.camera.global_transform),"probe_camera_pose":str(probe.camera.global_transform),
		"engine_time_scale":Engine.time_scale,"size":[result.size.x,result.size.y]})
	progress(label + ": captured")

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(640, 360)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading: await process_frame
	scene.tour_finished = true
	for slug in ["wuming", "youxian"]:
		if scene.slug != slug: await scene._load_world(slug)
		for i in 30: await process_frame
		var processing: bool = scene.is_processing()
		scene.set_process(false)
		var old_time := Engine.time_scale
		Engine.time_scale = 0.0
		probe = preload("res://source_tlv_candidate/sun_probe.gd").new()
		root.add_child(probe)
		var installed: Dictionary = probe.install(scene)
		report.maps.append({"map":slug,"probe":installed})
		if installed.has("error"):
			report.failures.append(slug+": "+installed.error)
		else:
			var bounds: Array[Dictionary] = preload("res://source_tlv_candidate/volume_bounds.gd").from_camera(scene.camera,16.0/9.0)
			for cascade in 2:
				await capture(slug+"-cascade"+str(cascade)+"-shadow",bounds[cascade],cascade)
				var sun: DirectionalLight3D = probe.get("_sun")
				var old_shadow := sun.shadow_enabled
				sun.shadow_enabled = false
				await capture(slug+"-cascade"+str(cascade)+"-unshadowed-control",bounds[cascade],cascade)
				sun.shadow_enabled = old_shadow
			Engine.time_scale = 1.0
			for i in 40: await process_frame
			await capture(slug+"-cascade1-live",bounds[1],1)
		probe.restore()
		probe.queue_free()
		probe = null
		Engine.time_scale = old_time
		scene.set_process(processing)
		for i in 5: await process_frame
		root.get_texture().get_image().save_png(out.path_join(slug+"-restored.png"))
	scene.queue_free()
	for i in 8: await process_frame
	progress("complete")
	quit(0 if report.failures.is_empty() else 1)
