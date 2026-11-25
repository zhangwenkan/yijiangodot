extends SceneTree
## Parent-only Forward+ GPU verification. This script was not run by the stage author.
var out := ""
var scene: Node3D
var report := {"maps":[],"failures":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hdr-dof-report-dir="): out=arg.trim_prefix("--hdr-dof-report-dir=")
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition: report.failures.append(scene.slug+": "+label)

func settle(count: int = 15) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func inspect(inside: bool) -> Dictionary:
	var adapter: Node=scene.source_renderer.depth_of_field
	var attributes: CameraAttributesPractical=scene.camera.attributes
	check(adapter.effect!=null,"HDR DOF effect is installed")
	if adapter.effect==null: return {}
	var state: Dictionary=adapter.effect.report.duplicate(true)
	check(state.get("status","")=="ready","HDR DOF effect is ready")
	check(state.get("inside",null)==inside,"source house state")
	check(is_equal_approx(float(state.get("source_focus_m",0)),14.7 if inside else 32.2),"source focal distance")
	check(not attributes.dof_blur_near_enabled and not attributes.dof_blur_far_enabled,"builtin DOF disabled")
	var names: Array[String]=[]
	var stages: Array[int]=[]
	for effect in scene.camera.compositor.compositor_effects:
		names.append(effect.get_script().resource_path.get_file())
		stages.append(effect.effect_callback_type)
	var dof: int=names.find("source_hdr_dof_effect.gd")
	var bloom: int=names.find("original_native_bloom.gd")
	var film: int=names.find("original_native_film.gd")
	check(dof>=0 and bloom==dof+1 and film>bloom,"compositor DOF then Bloom then Film")
	if dof>=0 and bloom>=0 and film>=0:
		check(stages[dof]==CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT and stages[dof]==stages[bloom] and stages[bloom]==stages[film],"ordered stages share POST_TRANSPARENT")
	check(not root.use_taa,"TAA remains disabled")
	check(root.screen_space_aa==Viewport.SCREEN_SPACE_AA_FXAA,"FXAA remains enabled")
	scene.environment_driver.update_focus(Vector3(100,200,300))
	check(not attributes.dof_blur_near_enabled and not attributes.dof_blur_far_enabled,"old follow focus cannot enable builtin DOF")
	state["compositor_names"]=names
	state["callback_types"]=stages
	return state

func capture(label: String, inside: bool) -> Dictionary:
	await settle()
	var state: Dictionary=inspect(inside)
	var adapter: Node=scene.source_renderer.depth_of_field
	if adapter.effect==null: return state
	var effect=adapter.effect
	var directory: String=out.path_join(scene.slug+"-"+label)
	var queued: Dictionary=adapter.request_diagnostic(directory,4)
	check(not queued.has("error"),"queued HDR readback "+label)
	for i in 300:
		await process_frame
		if effect.last_diagnostic.get("directory","")==directory: break
	var diagnostic: Dictionary=effect.last_diagnostic.duplicate(true)
	check(diagnostic.get("directory","")==directory and diagnostic.get("complete",false),"completed HDR readback "+label)
	state["diagnostic"]=diagnostic
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(scene.slug+"-"+label+".png"))
	return state

func run() -> void:
	if out.is_empty():
		push_error("Pass -- --hdr-dof-report-dir=<absolute stage output directory>")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		var entry: Dictionary={"map":slug,"outside":await capture("outside",false)}
		var center: Vector3=scene.house_driver._boxes[0].transform.origin
		check(scene.player.place_at_source_actor_position(center+Vector3(-3.65,0,0)),"doorway support")
		scene.camera.reset_at(scene.player.get_camera_anchor())
		scene.player.set_review_motion(Vector2.UP)
		for i in 150:
			await physics_frame
			if scene.house_driver.is_in_house: break
		scene.player.set_review_motion(Vector2.ZERO)
		check(scene.house_driver.is_in_house,"walk entered house")
		entry["inside"]=await capture("inside",true)
		scene.player.set_review_motion(Vector2.DOWN)
		for i in 150:
			await physics_frame
			if not scene.house_driver.is_in_house: break
		scene.player.set_review_motion(Vector2.ZERO)
		check(not scene.house_driver.is_in_house,"walk exited house")
		entry["exit"]=await capture("exit",false)
		var old_scale: float=root.scaling_3d_scale
		root.scaling_3d_scale=old_scale*.75
		entry["resized"]=await capture("resized",false)
		if entry.exit.has("internal_size") and entry.resized.has("internal_size"):
			var ratio: float=float(entry.resized.internal_size[0])/float(entry.exit.internal_size[0])
			check(ratio<1.0,"render buffer resize handled")
			check(is_equal_approx(float(entry.resized.infinity_coc_radius_px),float(entry.exit.infinity_coc_radius_px)*ratio),"CoC uses actual render buffer width")
		root.scaling_3d_scale=old_scale
		await settle(8)
		report.maps.append(entry)
	scene.house_driver.reset_outdoors()
	var adapter: Node=scene.source_renderer.depth_of_field
	var previous_attributes: CameraAttributes=adapter._previous_attributes
	var previous_compositor: Compositor=adapter._previous_compositor
	report["restore"]=adapter.restore()
	check(scene.camera.attributes==previous_attributes,"restored original attributes")
	check(scene.camera.compositor==previous_compositor,"restored previous compositor")
	check(not scene.camera.has_meta("source_dof_owner"),"removed owner metadata")
	scene.source_renderer.shutdown()
	FileAccess.open(out.path_join("hdr-dof-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_HDR_DOF_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	await settle(5)
	quit(0 if report.failures.is_empty() else 1)
