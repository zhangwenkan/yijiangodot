extends SceneTree
## Same-frame comparison of source HDR ordering and the previous builtin placement.
var out := ""
var scene: Node3D
var report := {"maps":[],"failures":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dof-order-report-dir="): out=arg.trim_prefix("--dof-order-report-dir=")
	call_deferred("run")

func check(value: bool,label: String) -> void:
	if not value: report.failures.append(scene.slug+": "+label)

func shot(label: String) -> Image:
	for i in 12: await process_frame
	await RenderingServer.frame_post_draw
	var image:=root.get_texture().get_image()
	check(image.save_png(out.path_join(scene.slug+"-"+label+".png"))==OK,"capture "+label)
	return image

func delta(a: Image,b: Image) -> Dictionary:
	var aa:=a.get_data()
	var bb:=b.get_data()
	var changed:=0
	var peak:=0
	var total:=0
	for i in aa.size():
		var d:=absi(int(aa[i])-int(bb[i]))
		changed+=int(d>0)
		peak=maxi(peak,d)
		total+=d
	return {"changed_channels":changed,"max_channel_delta":peak,"mean_channel_delta":float(total)/aa.size()}

func run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	root.size=Vector2i(1280,720)
	root.content_scale_size=Vector2i(1280,720)
	root.scaling_3d_scale=1.0
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		Engine.time_scale=1.0
		scene.process_mode=Node.PROCESS_MODE_INHERIT
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		for i in 20: await process_frame
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		var renderer: Node=scene.source_renderer
		var hdr: Node=renderer.depth_of_field
		var camera_transform: Transform3D=scene.camera.global_transform
		var first:=await shot("hdr-before-bloom-film")
		var repeated:=await shot("hdr-repeat")
		var entry:={"map":slug,"size":root.size,"freeze_delta":delta(first,repeated),"hdr":hdr.effect.report.duplicate(true)}
		hdr.restore()
		var old: Node=load("res://source_dof_candidate/source_dof_adapter.gd").new()
		renderer.add_child(old)
		old.install(scene.camera,"res://source_dof_candidate/source-dof.json")
		old.attach_house_driver(scene.house_driver)
		var builtin:=await shot("builtin-after-bloom-film")
		entry["builtin"]=old.report.duplicate(true)
		entry["order_delta"]=delta(first,builtin)
		check(scene.camera.global_transform==camera_transform,"comparison kept camera unchanged")
		check(root.screen_space_aa==Viewport.SCREEN_SPACE_AA_FXAA and not root.use_taa,"same FXAA settings")
		old.restore()
		old.queue_free()
		hdr.install(scene.camera,"res://source_dof_candidate/source-dof.json")
		hdr.attach_house_driver(scene.house_driver)
		var restored:=await shot("hdr-restored")
		entry["restored_delta"]=delta(first,restored)
		check(not scene.camera.attributes.dof_blur_near_enabled,"builtin restored to disabled")
		report.maps.append(entry)
	Engine.time_scale=1.0
	FileAccess.open(out.path_join("dof-order-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_DOF_ORDER_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
