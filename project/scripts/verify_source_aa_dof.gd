extends SceneTree
## Isolated image-quality diagnostic. No geometry, material, texture or lighting edits.
## Keep this outside the normal game flow; all settings are restored before exit.

var out := ""
var target_map := "youxian"
var scene: Node3D
var report := {"schema":"source_aa_dof_audit_v1","frames":[],"failures":[]}
var restore_values: Dictionary = {}
const Q_SETTING := "rendering/camera/depth_of_field/depth_of_field_bokeh_quality"
const J_SETTING := "rendering/camera/depth_of_field/depth_of_field_use_jitter"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--aa-dof-report-dir="): out=arg.trim_prefix("--aa-dof-report-dir=")
		if arg.begins_with("--map="): target_map=arg.trim_prefix("--map=")
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition: report.failures.append(label)

func sha256(data: PackedByteArray) -> String:
	var context:=HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish().hex_encode()

func coc_state() -> Dictionary:
	var a: CameraAttributesPractical=scene.camera.attributes
	return {"near_enabled":a.dof_blur_near_enabled,"far_enabled":a.dof_blur_far_enabled,
		"near":a.dof_blur_near_distance,"far":a.dof_blur_far_distance,
		"near_transition":a.dof_blur_near_transition,"far_transition":a.dof_blur_far_transition,
		"amount":a.dof_blur_amount,"camera_transform":str(scene.camera.global_transform),
		"projection":str(scene.camera.get_camera_projection())}

func capture(label: String, setting: Dictionary) -> Image:
	var before:=Time.get_ticks_usec()
	for i in 12: await process_frame
	await RenderingServer.frame_post_draw
	var after:=Time.get_ticks_usec()
	var im:=root.get_texture().get_image()
	var path:=out.path_join(target_map+"-"+label+".png")
	check(im.save_png(path)==OK,"save "+label)
	check(coc_state()==report.source_coc,"CoC/camera preserved: "+label)
	check(not root.use_taa,"TAA disabled: "+label)
	var frame:=setting.duplicate(true)
	frame.merge({"file":path,"label":label,"size":[im.get_width(),im.get_height()],
		"image_sha256":sha256(im.get_data()),
		"mean_wall_frame_ms":float(after-before)/12000.0,
		"msaa":root.msaa_3d,"screen_space_aa":root.screen_space_aa,
		"texture_mipmap_bias_property":root.texture_mipmap_bias,
		"effective_mipmap_bias":root.texture_mipmap_bias-(0.25 if root.screen_space_aa==Viewport.SCREEN_SPACE_AA_FXAA else 0.0)},true)
	check(is_equal_approx(float(frame.effective_mipmap_bias),float(report.effective_mipmap_bias)),"effective mip bias preserved: "+label)
	report.frames.append(frame)
	return im

func variant(label: String, quality: int, fxaa: bool, jitter: bool=false) -> Image:
	root.msaa_3d=Viewport.MSAA_DISABLED if fxaa else Viewport.MSAA_4X
	root.screen_space_aa=Viewport.SCREEN_SPACE_AA_FXAA if fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
	# Godot automatically subtracts .25 with FXAA. Counter only that implicit change.
	root.texture_mipmap_bias=float(report.effective_mipmap_bias)+(0.25 if fxaa else 0.0)
	RenderingServer.camera_attributes_set_dof_blur_quality(quality,jitter)
	return await capture(label,{"dof_quality_requested":quality,"dof_jitter_requested":jitter,
		"bokeh":"circle","jitter_expected_to_affect_circle":false,
		"texture_filtering_preserved":true,"source_aa_method_candidate":fxaa})

func image_delta(a: Image,b: Image) -> Dictionary:
	if a.get_size()!=b.get_size() or a.get_format()!=b.get_format(): return {"incompatible":true}
	var aa:=a.get_data()
	var bb:=b.get_data()
	var changed:=0
	var max_delta:=0
	var total:=0
	for i in aa.size():
		var d:=absi(int(aa[i])-int(bb[i]))
		if d>0: changed+=1
		max_delta=maxi(max_delta,d)
		total+=d
	return {"changed_channels":changed,"max_channel_delta":max_delta,
		"mean_channel_delta":float(total)/maxi(1,aa.size()),"total_channels":aa.size()}

func run() -> void:
	if out.is_empty():
		push_error("Provide --aa-dof-report-dir=<absolute directory>.")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	restore_values={"size":root.size,"content_scale_size":root.content_scale_size,
		"scale":root.scaling_3d_scale,"scaling_mode":root.scaling_3d_mode,
		"msaa":root.msaa_3d,"aa":root.screen_space_aa,"taa":root.use_taa,
		"bias":root.texture_mipmap_bias,"time_scale":Engine.time_scale,
		"dof_quality":ProjectSettings.get_setting(Q_SETTING,1),
		"dof_jitter":ProjectSettings.get_setting(J_SETTING,false)}
	root.size=Vector2i(1280,720)
	root.content_scale_size=Vector2i(1280,720)
	root.scaling_3d_scale=1.0
	root.scaling_3d_mode=Viewport.SCALING_3D_MODE_BILINEAR
	root.use_taa=false
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	if scene.slug!=target_map: await scene._load_world(target_map)
	scene.tour_finished=true
	for i in 30: await process_frame
	check(scene.source_rendering and is_instance_valid(scene.source_renderer.depth_of_field),"source DOF active")
	check(scene.camera.attributes is CameraAttributesPractical,"practical DOF attributes")
	scene.process_mode=Node.PROCESS_MODE_DISABLED
	Engine.time_scale=0.0
	report["engine"]=Engine.get_version_info()
	report["source_coc"]=coc_state()
	report["source_dof_report"]=scene.source_renderer.depth_of_field.report.duplicate(true)
	report["startup_settings"]=restore_values.duplicate(true)
	report["effective_mipmap_bias"]=float(restore_values.bias)-(0.25 if int(restore_values.aa)==Viewport.SCREEN_SPACE_AA_FXAA else 0.0)-(0.5 if bool(restore_values.taa) else 0.0)
	report["limits"]=["Godot FXAA is a method-level adapter, not the original UE FXAA shader.",
		"Godot circle gather/recombine differs from UE ring gather plus 3x3 median.",
		"Quality HIGH is a density diagnostic, not a direct mapping from Unreal scalability 3.",
		"Jitter is a negative control: the runtime circle branch does not read it.",
		"Original screenshot has UI, different exact player/camera timing, and is not pixel registered.",
		"mean_wall_frame_ms includes readback and scheduling and is not a GPU profiler measurement.",
		"DOF runtime getter is absent; restore quality/jitter assumes startup project settings."]
	var baseline:=await variant("msaa4-low",RenderingServer.DOF_BLUR_QUALITY_LOW,false)
	var repeated:=await variant("msaa4-low-repeat",RenderingServer.DOF_BLUR_QUALITY_LOW,false)
	report["freeze_repeat_delta"]=image_delta(baseline,repeated)
	await variant("msaa4-high",RenderingServer.DOF_BLUR_QUALITY_HIGH,false)
	await variant("fxaa-low",RenderingServer.DOF_BLUR_QUALITY_LOW,true)
	await variant("fxaa-medium",RenderingServer.DOF_BLUR_QUALITY_MEDIUM,true)
	var high:=await variant("fxaa-high",RenderingServer.DOF_BLUR_QUALITY_HIGH,true)
	var high_jitter:=await variant("fxaa-high-jitter-control",RenderingServer.DOF_BLUR_QUALITY_HIGH,true,true)
	report["circle_jitter_delta"]=image_delta(high,high_jitter)
	# Repeat differences are reported, not silently attributed to AA or DOF.
	RenderingServer.camera_attributes_set_dof_blur_quality(int(restore_values.dof_quality),bool(restore_values.dof_jitter))
	root.msaa_3d=int(restore_values.msaa)
	root.screen_space_aa=int(restore_values.aa)
	root.use_taa=bool(restore_values.taa)
	root.texture_mipmap_bias=float(restore_values.bias)
	root.scaling_3d_mode=int(restore_values.scaling_mode)
	root.scaling_3d_scale=float(restore_values.scale)
	root.content_scale_size=restore_values.content_scale_size
	root.size=restore_values.size
	Engine.time_scale=float(restore_values.time_scale)
	FileAccess.open(out.path_join("aa-dof-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_AA_DOF_AUDIT ",JSON.stringify({"frames":report.frames.size(),"failures":report.failures,
		"freeze_repeat_delta":report.freeze_repeat_delta,"circle_jitter_delta":report.circle_jitter_delta}))
	scene.queue_free()
	for i in 3: await process_frame
	quit(0 if report.failures.is_empty() else 1)
