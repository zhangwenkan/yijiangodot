extends SceneTree
## Run only after the exact reviewed candidate has been deployed by the parent.
const VISIBLE_MAX_ATTEMPTS := 6
const VISIBLE_RETRY_FRAMES := 30
const DYNAMIC_GAP_FRAMES := 45
var out := ""
var scene: Node3D
var watch_generation := 0
var report: Dictionary={"maps":[],"captures":[],"visibility_observations":{},"failures":[],"scope":"Production default renderer, moving source particles with bounded visible sampling, resize, real house state signals, source parent visibility, failure restoration and original synchronous map teardown."}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--separate-out="):out=arg.trim_prefix("--separate-out=")
	call_deferred("run")

func progress(stage: String) -> void:
	report.stage=stage
	FileAccess.open(out.path_join("integration-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SEPARATE_INTEGRATION_PROGRESS ",stage)

func check(value: bool, message: String) -> void:
	if not value:report.failures.append(message)

func wait_marker(kind: String, index: int) -> void:
	report.waiting={"kind":kind,"index":index,"stage":report.get("stage",""),"ticks_ms":Time.get_ticks_msec(),"process_frames":Engine.get_process_frames(),"frames_drawn":Engine.get_frames_drawn()}
	FileAccess.open(out.path_join("wait-state.json"),FileAccess.WRITE).store_string(JSON.stringify(report.waiting,"\t"))

func watch_timeout(generation: int) -> void:
	if generation!=watch_generation:return
	report.failures.append("40s watchdog expired: "+str(report.get("waiting",{})))
	progress("watchdog timeout")
	quit(3)

func settle(frames: int=5) -> void:
	for i in frames:
		watch_generation+=1
		create_timer(40.0,true,false,true).timeout.connect(watch_timeout.bind(watch_generation))
		wait_marker("await process_frame",i)
		await process_frame
		watch_generation+=1
		wait_marker("process_frame received",i)
	watch_generation+=1
	create_timer(40.0,true,false,true).timeout.connect(watch_timeout.bind(watch_generation))
	wait_marker("await frame_post_draw",frames)
	await RenderingServer.frame_post_draw
	wait_marker("frame_post_draw received",frames)
	watch_generation+=1

func source_simulation(adapter: Node) -> Array:
	var result: Array=[]
	for child in scene.world.get_children():
		if child.get_script()==null or child.get_script().resource_path!="res://scripts/original_particles.gd":continue
		for emitter in child.get("_emitters"):
			for item in adapter.get("_draws"):
				if emitter.draw==item.draw:
					result.append({"source":str(item.draw.get_meta("source_emitter","")),"component":str(item.draw.get_meta("source_component","")),"time":emitter.time,"particles":emitter.particles.size()})
	return result

func layer_coverage(bytes: PackedByteArray) -> int:
	var active := 0
	# Four half-floats per pixel. Ignore only the sign bits of +/- zero.
	# NaN/Inf count as active here and fail the independent CPU finite checks.
	for offset in range(0,bytes.size(),8):
		if bytes.decode_u64(offset)&0x7fff7fff7fff7fff:active+=1
	return active

func capture(adapter: Node, label: String) -> Dictionary:
	progress(label+": rendering")
	await settle()
	wait_marker("get_image starting",0)
	var image:=root.get_texture().get_image()
	wait_marker("get_image returned; save_png starting",0)
	image.save_png(out.path_join(label+".png"))
	wait_marker("save_png returned; requesting capture",0)
	if adapter.effect==null:
		check(false,label+": effect missing");return {}
	var request_frame := Engine.get_process_frames()
	var requested_simulation := source_simulation(adapter)
	adapter.effect.request_capture()
	var result: Dictionary={}
	for i in 30:
		await process_frame
		result=adapter.effect.take_capture()
		if not result.is_empty():break
	if result.is_empty():check(false,label+": readback timeout");return {}
	var folder:=out.path_join(label)
	DirAccess.make_dir_recursive_absolute(folder)
	var metadata:=result.duplicate()
	metadata.capture_label=label
	metadata.camera_transform=str(scene.camera.global_transform)
	metadata.house_inside=scene.house_driver.is_in_house
	metadata.request_process_frame=request_frame
	metadata.readback_process_frame=Engine.get_process_frames()
	metadata.readback_frames_drawn=Engine.get_frames_drawn()
	metadata.readback_ticks_ms=Time.get_ticks_msec()
	metadata.request_source_simulation=requested_simulation
	metadata.readback_source_simulation=source_simulation(adapter)
	metadata.observed_layer_active_pixels=layer_coverage(result.layer_rgba16f)
	for key in result:
		if result[key] is PackedByteArray:
			FileAccess.open(folder.path_join(key+".bin"),FileAccess.WRITE).store_buffer(result[key])
			metadata[key]={"file":key+".bin","bytes":result[key].size()}
	FileAccess.open(folder.path_join("capture.json"),FileAccess.WRITE).store_string(JSON.stringify(metadata,"\t"))
	report.captures.append(label)
	return metadata

func observe_visible(adapter: Node, label: String) -> Dictionary:
	var camera_pose: Transform3D=scene.camera.global_transform
	var observation: Dictionary={"camera_transform":str(camera_pose),"start_process_frame":Engine.get_process_frames(),
		"start_ticks_ms":Time.get_ticks_msec(),"attempts":[],"selected_capture":"","status":"observing"}
	report.visibility_observations[label]=observation
	for attempt in VISIBLE_MAX_ATTEMPTS:
		if attempt>0:await settle(VISIBLE_RETRY_FRAMES)
		var candidate:=label+"-candidate-"+str(attempt+1).pad_zeros(2)
		var metadata:=await capture(adapter,candidate)
		check(scene.camera.global_transform==camera_pose,label+": camera moved during bounded observation")
		observation.attempts.append({"capture":candidate,"attempt":attempt+1,
			"coverage":metadata.get("observed_layer_active_pixels",-1),"readback_process_frame":metadata.get("readback_process_frame",-1),
			"elapsed_ms":Time.get_ticks_msec()-int(observation.start_ticks_ms)})
		if metadata.is_empty():
			observation.status="capture_failed";break
		if int(metadata.observed_layer_active_pixels)>0:
			observation.selected_capture=candidate
			observation.status="visible"
			observation.end_process_frame=Engine.get_process_frames()
			observation.elapsed_ms=Time.get_ticks_msec()-int(observation.start_ticks_ms)
			progress(label+": selected nonempty candidate "+str(attempt+1))
			return metadata
	observation.end_process_frame=Engine.get_process_frames()
	observation.elapsed_ms=Time.get_ticks_msec()-int(observation.start_ticks_ms)
	if observation.status=="observing":observation.status="exhausted"
	check(false,label+": no visible layer within "+str(VISIBLE_MAX_ATTEMPTS)+" candidates")
	progress(label+": "+str(observation.status))
	return {}

func emitter_state(adapter: Node) -> Array:
	var result: Array=[]
	for item in adapter.get("_draws"):
		var draw: MultiMeshInstance3D=item.draw
		result.append({"source":item.source,"node":str(draw.get_path()),"visible":draw.visible,"in_tree_visible":draw.is_visible_in_tree(),"layers":draw.layers,
			"particles":draw.multimesh.visible_instance_count,"instance_hash":draw.multimesh.buffer.to_byte_array().hex_encode().sha256_text(),
			"material":draw.material_override.get_instance_id(),"mesh":draw.multimesh.mesh.get_instance_id()})
	return result

func chain(camera: Camera3D) -> Array:
	var result: Array=[]
	if camera.compositor!=null:
		for effect in camera.compositor.compositor_effects:
			result.append({"script":effect.get_script().resource_path.get_file(),"enabled":effect.enabled})
	return result

func anchor_camera(adapter: Node) -> void:
	var center:=Vector3.ZERO
	var count:=0
	for item in adapter.get("_draws"):
		var draw: MultiMeshInstance3D=item.draw
		for i in draw.multimesh.visible_instance_count:
			center+=(draw.global_transform*draw.multimesh.get_instance_transform(i)).origin
			count+=1
	if count==0:return
	center/=float(count)
	var pose: Transform3D=scene.camera.global_transform
	# Fireflies occupy a wide source volume; the source outdoor distance retains
	# visible particles around the existing houses while the 12m mean may sit behind them.
	var view_distance := 32.2 if str(scene.slug)=="youxian" else 12.0
	pose.origin=center+pose.basis.z.normalized()*view_distance
	scene.camera.global_transform=pose

func expect_chain(adapter: Node, label: String) -> void:
	var effects: Array=scene.camera.compositor.compositor_effects
	var separate_index: int=effects.find(adapter.effect)
	var dof_index: int=effects.find(scene.source_renderer.depth_of_field.effect)
	var bloom_index: int=effects.find(scene.source_renderer.bloom)
	check(separate_index==dof_index+1 and bloom_index==separate_index+1,label+": order is not DOF -> separate -> Bloom")
	check(adapter.report.get("status","")=="routed",label+": route not active")

func temporary_dof_probe(adapter: Node, prefix: String, entry: Dictionary) -> void:
	var owner: Node=scene.source_renderer.depth_of_field
	var dof_effect: CompositorEffect=owner.effect
	var separate_effect: CompositorEffect=adapter.effect
	var attributes: CameraAttributes=scene.camera.attributes
	var compositor: Compositor=scene.camera.compositor
	var nodes:=emitter_state(adapter)
	var initial_failures: int=report.failures.size()
	var states: Array=[]
	for enabled: bool in [false,true]:
		dof_effect.enabled=enabled
		await settle(5)
		var label:=prefix+("-dof-reenabled" if enabled else "-dof-disabled")
		check(owner.effect==dof_effect and dof_effect.enabled==enabled,label+": DOF owner/effect changed")
		check(scene.camera.attributes==attributes and scene.camera.compositor==compositor,label+": camera ownership changed")
		check(scene.camera.get_meta("source_dof_owner",null)==owner,label+": source DOF metadata changed")
		check(adapter.effect==separate_effect and separate_effect.enabled,label+": separate layer was removed")
		if adapter.effect==null:break
		var sample:=await observe_visible(adapter,label)
		check(sample.get("groups",0)>0,label+": no routed source group")
		expect_chain(adapter,label)
		var current:=emitter_state(adapter)
		for i in current.size():
			check(current[i].visible==nodes[i].visible and current[i].layers==nodes[i].layers,label+": source node state changed")
		states.append({"label":label,"enabled":enabled,"capture":sample.get("capture_label",""),"chain":chain(scene.camera)})
	dof_effect.enabled=true
	entry.temporary_dof_toggle={"passed":report.failures.size()==initial_failures and states.size()==2,"states":states}

func explicit_restore_probe(adapter: Node, prefix: String, entry: Dictionary) -> void:
	var owner: Node=scene.source_renderer.depth_of_field
	var before_dof: Compositor=owner.get("_previous_compositor")
	var attributes: CameraAttributes=owner.get("_previous_attributes")
	var initial_failures: int=report.failures.size()
	var restored: Dictionary=owner.restore()
	await settle(5)
	check(owner.effect==null and adapter.effect==null,prefix+": explicit restore left active owners")
	check(scene.camera.compositor==before_dof,prefix+": explicit restore retained stale DOF wrapper")
	check(scene.camera.attributes==attributes and not scene.camera.has_meta("source_dof_owner"),prefix+": explicit restore retained attributes/metadata")
	var old_chain:=chain(scene.camera)
	var installed: Dictionary=owner.install(scene.camera,"res://source_dof_candidate/source-dof.json")
	check(not installed.has("error"),prefix+": DOF reinstall failed "+str(installed.get("error","")))
	var attached: Dictionary=owner.attach_house_driver(scene.house_driver)
	check(not attached.has("error"),prefix+": DOF house reattach failed")
	var routed: Dictionary=adapter.install(scene)
	check(not routed.has("error"),prefix+": separate reinstall failed "+str(routed.get("error","")))
	await settle(5)
	check(owner.effect!=null and adapter.effect!=null,prefix+": reinstall missing effects")
	if owner.effect!=null and adapter.effect!=null:expect_chain(adapter,prefix+": reinstalled")
	check(scene.camera.get_meta("source_dof_owner",null)==owner,prefix+": reinstall metadata missing")
	entry.explicit_dof_restore={"passed":report.failures.size()==initial_failures,"restore":restored,"restored_chain":old_chain,"reinstalled_chain":chain(scene.camera)}

func failure_probe(kind: String, entry: Dictionary) -> void:
	var adapter: Node=scene.source_renderer.separate_translucency
	var owner: Node=scene.source_renderer.depth_of_field
	var dof_effect: CompositorEffect=owner.effect
	var attributes: CameraAttributes=scene.camera.attributes
	var baseline_attributes: CameraAttributes=owner.get("_previous_attributes")
	var before_separate: Compositor=adapter.get("_previous")
	var before_dof: Compositor=owner.get("_previous_compositor")
	var source_draws: Array[Dictionary]=adapter.get("_draws").duplicate()
	var saved_state:=emitter_state(adapter)
	var source_effect: CompositorEffect=adapter.effect
	progress(kind+": injecting explicit diagnostic failure")
	if kind=="separate-failure":
		RenderingServer.call_on_render_thread(Callable(source_effect,"_fail").bind("intentional integration diagnostic"))
	else:
		RenderingServer.call_on_render_thread(Callable(dof_effect,"_fail").bind("intentional integration diagnostic"))
	for i in 60:
		await process_frame
		if adapter.effect==null:break
	check(adapter.effect==null,kind+": source draws were not restored")
	check(not source_effect.enabled,kind+": failed separate effect remains enabled")
	if kind=="separate-failure":
		check(scene.camera.compositor==before_separate,kind+": valid DOF compositor not retained")
		check(scene.camera.attributes==attributes,kind+": valid DOF attributes changed")
		check(dof_effect.enabled and owner.effect==dof_effect,kind+": valid DOF was disabled")
		check(scene.camera.get_meta("source_dof_owner",null)==owner,kind+": valid DOF metadata lost")
	else:
		check(scene.camera.compositor==before_dof,kind+": stale disabled DOF wrapper remains")
		check(scene.camera.attributes==baseline_attributes,kind+": original camera attributes not restored")
		check(not scene.camera.has_meta("source_dof_owner"),kind+": failed DOF owner metadata remains")
		check(owner.effect==null and not dof_effect.enabled,kind+": failed DOF still owned")
	for i in source_draws.size():
		var draw: MultiMeshInstance3D=source_draws[i].draw
		check(draw.visible==saved_state[i].visible and draw.layers==saved_state[i].layers,kind+": source node state changed")
	await settle()
	root.get_texture().get_image().save_png(out.path_join(kind+"-original-routing.png"))
	entry[kind]={"adapter":adapter.report.duplicate(true),"chain":chain(scene.camera),"camera_attributes_restored":scene.camera.attributes==baseline_attributes,
		"source_nodes":saved_state,"original_draw_routing_restored":adapter.effect==null,"dof_metadata_present":scene.camera.has_meta("source_dof_owner")}

func run() -> void:
	if out.is_empty():quit(2);return
	DirAccess.make_dir_recursive_absolute(out)
	report.input_sha256={}
	for file in ["separate_adapter.gd","separate_effect.gd","separate.vert.glsl.txt","separate.frag.glsl.txt","composite.glsl.txt"]:
		report.input_sha256[file]=FileAccess.get_sha256("res://source_separate_translucency/"+file)
	report.renderer_sha256=FileAccess.get_sha256("res://scripts/original_source_renderer.gd")
	report.visibility_sampling={"max_attempts":VISIBLE_MAX_ATTEMPTS,"retry_frames":VISIBLE_RETRY_FRAMES,"dynamic_gap_frames":DYNAMIC_GAP_FRAMES,
		"capture_settle_frames":5,"readback_max_frames":30,"max_retry_frames":(VISIBLE_MAX_ATTEMPTS-1)*VISIBLE_RETRY_FRAMES,
		"max_requested_process_frames_per_observation":VISIBLE_MAX_ATTEMPTS*35+(VISIBLE_MAX_ATTEMPTS-1)*VISIBLE_RETRY_FRAMES,
		"single_wait_watchdog_seconds":40,"meaning":"Conditional visible samples within a finite observation; not a claim that every frame contains visible particles."}
	root.size=Vector2i(1280,720)
	progress("loading production scene")
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading:await process_frame
	scene.tour_finished=true
	for index in 3:
		var slug: String=["wuming","youxian","wuming"][index]
		if scene.slug!=slug:
			progress("switching through production _load_world to "+slug)
			# This calls the real synchronous renderer.shutdown -> queue_free path.
			await scene._load_world(slug)
		var adapter: Node=scene.source_renderer.get("separate_translucency")
		if not is_instance_valid(adapter):
			check(false,slug+": production adapter missing");progress("failed");scene.queue_free();await process_frame;quit(2);return
		await settle(60)
		expect_chain(adapter,slug)
		var camera_pose: Transform3D=scene.camera.global_transform
		var was_processing: bool=scene.is_processing()
		var house_processing: bool=scene.house_driver.is_processing()
		# Stop only the camera-driver parent. All child particle and effect nodes run.
		scene.set_process(false)
		scene.house_driver.set_process(false)
		anchor_camera(adapter)
		var entry: Dictionary={"map":slug,"index":index,"initial_chain":chain(scene.camera),"initial_emitters":emitter_state(adapter)}
		var prefix:=str(index)+"-"+slug
		entry.dynamic_first=await observe_visible(adapter,prefix+"-dynamic-first")
		var first_state:=emitter_state(adapter)
		entry.dynamic_first_emitters=first_state
		await settle(DYNAMIC_GAP_FRAMES)
		entry.dynamic_second=await observe_visible(adapter,prefix+"-dynamic-second")
		var second_state:=emitter_state(adapter)
		var changed:=false
		for i in second_state.size():
			changed=changed or second_state[i].instance_hash!=first_state[i].instance_hash
			check(second_state[i].layers==entry.initial_emitters[i].layers and second_state[i].visible==entry.initial_emitters[i].visible,prefix+": routing changed source node state")
		check(changed,prefix+": source particle animation did not advance")
		entry.dynamic_buffers_changed=changed
		entry.dynamic_second_emitters=second_state
		await temporary_dof_probe(adapter,prefix,entry)
		if index==0:
			root.size=Vector2i(960,540)
			entry.resize_small=await capture(adapter,prefix+"-resize-960")
			check(entry.resize_small.get("width")==960 and entry.resize_small.get("height")==540,"resize did not rebuild source layer")
			root.size=Vector2i(1280,720)
			entry.resize_restored=await capture(adapter,prefix+"-resize-1280")
			check(entry.resize_restored.get("width")==1280,"resize did not restore source width")
		for inside: bool in [true,false]:
			scene.house_driver.set_inside(inside)
			var phase:=prefix+("-inside" if inside else "-outside")
			entry[phase]=await capture(adapter,phase)
			check(scene.house_driver.is_in_house==inside,phase+": house state changed unexpectedly")
			expect_chain(adapter,phase)
		# House state directly reapplies the player's camera pose even while this
		# scene's _process is stopped. Return to the source effect before testing
		# its visibility; an off-screen effect cannot prove show/hide restoration.
		anchor_camera(adapter)
		var targets: Array[Dictionary]=adapter.get("_draws")
		var parent: Node3D=targets[0].draw.get_parent()
		var old_visible:=parent.visible
		parent.visible=false
		var hidden:=await capture(adapter,prefix+"-source-parent-hidden")
		check(hidden.get("groups",-1)==0,prefix+": invisible source parent still rendered in separate layer")
		parent.visible=old_visible
		var shown:=await observe_visible(adapter,prefix+"-source-parent-restored")
		check(shown.get("groups",0)>0,prefix+": restored source parent did not render")
		entry.effect=adapter.effect.report.duplicate(true)
		if index==0:await failure_probe("separate-failure",entry)
		if index==1:await failure_probe("dof-failure",entry)
		if index==2:await explicit_restore_probe(adapter,prefix,entry)
		report.maps.append(entry)
		scene.camera.global_transform=camera_pose
		scene.set_process(was_processing)
		scene.house_driver.set_process(house_processing)
		progress(prefix+": complete")
	progress("synchronous renderer shutdown and queue_free")
	report.shutdown=scene.source_renderer.shutdown()
	scene.queue_free()
	# These frames only deliver normal queue_free/exit. No pre-deletion settling.
	for i in 4:await process_frame
	progress("completed")
	quit(0 if report.failures.is_empty() else 1)
