extends SceneTree
## Explicit receiver diagnostic. No launcher/default/runtime integration.
## frozen: exact image restore + contribution using one held complete pair.
## normal: unmodified age policy, moving clock, four publication draw samples.
var out := ""
var wanted_driver := ""
var diagnostic_mode := ""
var opted_in := false
var scene: Node3D
var producer: Node
var caster_control: Node
var readback: CompositorEffect
var compositor: Compositor
var original_effects: Array[CompositorEffect] = []
var installed_effects: Array[CompositorEffect] = []
var pending_label := ""
var expected_mode := -1
var capture_requested := false
var record_submissions := false
var normal_tokens: Dictionary = {}
var original_receiver_states: Array[Dictionary] = []
var old_process_mode := Node.PROCESS_MODE_INHERIT
var old_time_scale := 1.0
var frozen := false
var report: Dictionary = {"failures":[],"captures":[],"submissions":[],
	"scope":"CPU material submissions correlated with main-view draws and observed sun contribution; no GPU fragment epoch/atomicity or native UE parity claim.",
	"limits":["A single Wuming default camera view only; not whole-map acceptance.",
		"Full readbacks are explicit diagnostics and distort timing; not a performance benchmark.",
		"The raw main HDR is before the source post chain; separate translucency can be composited later.",
		"All receiver uniforms are CPU-observed; an actual UBO clock does not reveal per-fragment sampler epochs."]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tlv-out="): out=arg.trim_prefix("--tlv-out=")
		elif arg.begins_with("--diagnostic-driver="): wanted_driver=arg.trim_prefix("--diagnostic-driver=")
		elif arg.begins_with("--receiver-diagnostic-mode="): diagnostic_mode=arg.trim_prefix("--receiver-diagnostic-mode=")
		elif arg=="--enable-tlv-receiver": opted_in=true
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition and not report.failures.has(message): report.failures.append(message)

func progress(stage: String) -> void:
	report.stage=stage
	if producer!=null: report.producer=producer.report
	FileAccess.open(out.path_join("realtime-receiver.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("REALTIME_RECEIVER_STAGE ",stage)

func settle(frames: int = 4) -> void:
	for i in frames: await process_frame
	await RenderingServer.frame_post_draw

func encode(value: Variant) -> Variant:
	if value is Texture3D:
		var result := {"class":value.get_class(),"instance_id":value.get_instance_id(),"rid":value.get_rid().get_id(),
			"width":value.get_width(),"height":value.get_height(),"depth":value.get_depth(),"format":value.get_format()}
		if value is Texture3DRD: result.rd_rid=value.texture_rd_rid.get_id()
		return result
	if value is Resource:
		var result := {"class":value.get_class(),"instance_id":value.get_instance_id(),"path":value.resource_path}
		if value is Texture: result.rid=value.get_rid().get_id()
		return result
	if value is Vector3: return [value.x,value.y,value.z]
	if value is Vector2: return [value.x,value.y]
	if value is Vector4: return [value.x,value.y,value.z,value.w]
	if value is Color: return [value.r,value.g,value.b,value.a]
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[str(key)]=encode(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value: result.append(encode(item))
		return result
	if typeof(value) in [TYPE_NIL,TYPE_BOOL,TYPE_INT,TYPE_FLOAT,TYPE_STRING,TYPE_STRING_NAME]: return value
	return {"type":type_string(typeof(value)),"literal":var_to_str(value)}

func uniforms(material: ShaderMaterial) -> Dictionary:
	var result: Dictionary = {}
	for uniform in material.shader.get_shader_uniform_list():
		result[str(uniform.name)]=encode(material.get_shader_parameter(uniform.name))
	return result

func submission_snapshot(label: String) -> Dictionary:
	var result := {"label":label,"pre_draw_frame":Engine.get_frames_drawn(),"submit_ticks_usec":Time.get_ticks_usec(),
		"time_scale":Engine.time_scale,"scene_process_mode":scene.process_mode,"snapshot_id":-1,
		"materials":[],"errors":[],"camera":str(scene.camera.global_transform),"camera_cull_mask":scene.camera.cull_mask,
		"diagnostic_mode":diagnostic_mode,"gpu_fragment_epoch_verified":false,"texture_format_rgba16f":Image.FORMAT_RGBAH}
	if producer==null or not bool(producer._running) or producer._receiver==null: return result
	var receiver: Node = producer._receiver
	var active: Dictionary = producer._active
	result.errors.append_array(receiver.owner_errors())
	if active.is_empty():
		result.errors.append("Receiver exists without a current complete snapshot.")
		return result
	result.snapshot_id=active.snapshot_id
	result.slot=active.slot
	result.request_frame=active.request_frame
	result.age_frames=Engine.get_frames_drawn()-int(active.request_frame)
	result.install_generation=active.install_generation
	result.house_generation=active.house_generation
	result.owner_generation=active.owner_generation
	result.bounds=encode(active.bounds)
	result.receiver_snapshot_id=receiver.snapshot_id
	result.mode=receiver.report.mode
	result.family_counts=receiver.report.family_counts.duplicate(true)
	result.frozen_hold=bool(producer.get("diagnostic_holding")) if diagnostic_mode=="frozen" else false
	var textures: Array[Dictionary] = producer._slots[int(active.slot)].textures
	var expected: Dictionary = {"source_tlv_sun_mode":int(receiver.report.mode)}
	for cascade in 2:
		var suffix := "inner" if cascade==0 else "outer"
		expected["source_tlv_ambient_"+suffix]=textures[cascade].ambient
		expected["source_tlv_directional_"+suffix]=textures[cascade].directional
		expected["source_tlv_min_"+suffix+"_cm"]=active.bounds[cascade].min_ue_cm
		var extent: float = float(active.bounds[cascade].voxel_cm)*int(active.bounds[cascade].dimension)
		expected["source_tlv_inv_size_"+suffix]=Vector3.ONE/extent
	result.expected_uniforms=encode(expected)
	if int(receiver.snapshot_id)!=int(active.snapshot_id): result.errors.append("Receiver token differs from active pair.")
	if expected_mode>=0 and int(receiver.report.mode)!=expected_mode: result.errors.append("Requested diagnostic mode was overwritten.")
	if diagnostic_mode=="normal" and not producer._fresh(active,Engine.get_frames_drawn()): result.errors.append("Normal publication exceeds ordinary freshness policy.")
	if receiver._saved.size()!=28: result.errors.append("Expected all 28 Wuming receiver materials.")
	for state in receiver._saved:
		var material: ShaderMaterial = state.material
		var item := {"material_id":material.get_instance_id(),"name":material.resource_name,"family":state.family,
			"shader_id":material.shader.get_instance_id(),"shader_sha256":material.shader.code.sha256_text(),
			"original_shader_sha256":state.shader.code.sha256_text(),"uniforms":uniforms(material),
			"render_priority":material.render_priority,"next_pass":encode(material.next_pass)}
		for key in expected:
			if material.get_shader_parameter(key)!=expected[key]: result.errors.append("Mixed/incorrect publication on material %s: %s" % [material.get_instance_id(),key])
		for key in ["source_tlv_ambient_inner","source_tlv_directional_inner","source_tlv_ambient_outer","source_tlv_directional_outer"]:
			var texture: Texture3D = material.get_shader_parameter(key)
			if texture==null or not texture is Texture3DRD or texture.get_width()!=64 or texture.get_height()!=64 or texture.get_depth()!=64 or texture.get_format()!=Image.FORMAT_RGBAH:
				result.errors.append("Invalid Texture3DRD dimensions/format: "+key)
			elif not texture.texture_rd_rid.is_valid() or not texture.get_rid().is_valid(): result.errors.append("Missing texture RID: "+key)
		if diagnostic_mode=="frozen":
			for key in state.parameters:
				if material.get_shader_parameter(key)!=state.parameters[key]: result.errors.append("Original frozen uniform changed: "+str(key))
		result.materials.append(item)
	return result

func on_pre_draw() -> void:
	var snapshot := submission_snapshot(pending_label if not pending_label.is_empty() else "observe")
	for error in snapshot.errors: check(false,str(error))
	if record_submissions and int(snapshot.snapshot_id)>=0:
		report.submissions.append(snapshot)
		if report.submissions.size()>256:
			report.submissions.pop_front()
			check(false,"Submission history exceeded the diagnostic bound.")
	if diagnostic_mode=="normal" and pending_label.is_empty() and normal_tokens.size()<4 and int(snapshot.snapshot_id)>=0 and not normal_tokens.has(int(snapshot.snapshot_id)):
		pending_label="normal-token-"+str(snapshot.snapshot_id)
		snapshot.label=pending_label
	if pending_label.is_empty() or capture_requested: return
	if readback.request(snapshot):
		capture_requested=true
		if diagnostic_mode=="normal": normal_tokens[int(snapshot.snapshot_id)]=true

func save_capture(result: Dictionary) -> Dictionary:
	if result.has("error"):
		check(false,str(result.error)); return {}
	var label: String = result.submission.label
	var bytes: PackedByteArray = result.rgba16f
	var ubo: PackedByteArray = result.scene_ubo
	FileAccess.open(out.path_join(label+".rgba16f"),FileAccess.WRITE).store_buffer(bytes)
	FileAccess.open(out.path_join(label+".scene-ubo.bin"),FileAccess.WRITE).store_buffer(ubo)
	check(result.drawn_frame==result.submission.pre_draw_frame,label+": CPU submission and main draw frame disagree")
	check(ubo.size()==5696,label+": unsupported scene UBO layout")
	var image := root.get_texture().get_image()
	check(image.save_png(out.path_join(label+".png"))==OK,label+": PNG write failed")
	var item: Dictionary = result.duplicate(false)
	item.erase("rgba16f")
	item.erase("scene_ubo")
	item.hdr_file=label+".rgba16f"
	item.ubo_file=label+".scene-ubo.bin"
	item.png_file=label+".png"
	item.viewport_png_drawn_frame=Engine.get_frames_drawn()
	check(item.viewport_png_drawn_frame==result.drawn_frame,label+": final PNG and raw HDR were sampled from different drawn frames")
	item.color_bytes=bytes.size()
	item.ubo_bytes=ubo.size()
	if ubo.size()==5696:
		item.clock={"time":ubo.decode_float(2816),"taa":ubo.decode_float(2820),
			"jitter":[ubo.decode_float(2824),ubo.decode_float(2828)],"previous_time":ubo.decode_float(5664),
			"previous_taa":ubo.decode_float(5668),"camera_mask":ubo.decode_u32(2840),
			"current_tuple_hex":ubo.slice(2816,2832).hex_encode(),"previous_tuple_hex":ubo.slice(5664,5680).hex_encode()}
		check(item.clock.camera_mask==int(result.submission.camera_cull_mask),label+": actual main UBO camera mask disagrees")
		if producer!=null and int(result.submission.snapshot_id)>=0:
			for pair in producer.report.pair_history:
				if int(pair.snapshot_id)!=int(result.submission.snapshot_id): continue
				item.producer_pair=pair.duplicate(true)
				var status: PackedByteArray = str(pair.status_hex).hex_decode()
				if status.size()==192:
					item.main_minus_probe_seconds=ubo.decode_float(2816)-status.decode_float(32)
					item.main_previous_equals_probe=ubo.slice(5664,5680)==status.slice(48,64)
					item.previous_clock_note="Probe and main viewport have distinct temporal history; new probes may have previous TIME zero. Near/far probe histories are independently required to agree."
					if diagnostic_mode=="frozen": check(ubo.slice(2816,2832)==status.slice(32,48),label+": frozen main/probe clock or TAA differ")
				break
			check(item.has("producer_pair"),label+": no matching accepted producer pair")
	report.captures.append(item)
	pending_label=""
	capture_requested=false
	return {"image":image,"hdr":bytes,"entry":item}

func capture(label: String) -> Dictionary:
	await settle()
	pending_label=label
	capture_requested=false
	for frame in 120:
		await RenderingServer.frame_post_draw
		var result: Dictionary = readback.take_result()
		if not result.is_empty(): return save_capture(result)
	check(false,label+": main draw readback timeout")
	pending_label=""
	capture_requested=false
	return {}

func difference(a: Dictionary, b: Dictionary) -> Dictionary:
	if a.is_empty() or b.is_empty(): return {"error":"Missing capture","png_changed_channels":-1,"hdr_changed_bytes":-1}
	var av: PackedByteArray = a.image.get_data()
	var bv: PackedByteArray = b.image.get_data()
	if a.image.get_size()!=b.image.get_size() or av.size()!=bv.size(): return {"error":"PNG size mismatch","png_changed_channels":-1,"hdr_changed_bytes":-1}
	var changed := 0
	var maximum := 0
	for i in av.size():
		var delta := absi(int(av[i])-int(bv[i]))
		if delta>0: changed+=1
		maximum=maxi(maximum,delta)
	var ah: PackedByteArray = a.hdr
	var bh: PackedByteArray = b.hdr
	var hdr_changed := 0
	if ah.size()!=bh.size(): hdr_changed=-1
	else:
		for i in ah.size():
			if ah[i]!=bh[i]: hdr_changed+=1
	return {"png_changed_channels":changed,"png_max_channel_delta":maximum,"hdr_changed_bytes":hdr_changed}

func exact(a: Dictionary, b: Dictionary, name: String) -> void:
	var delta := difference(a,b)
	report[name]=delta
	check(delta.png_changed_channels==0 and delta.hdr_changed_bytes==0,name+": frozen images are not byte exact")

func install_readback() -> bool:
	compositor=scene.camera.compositor
	if compositor==null: check(false,"Main compositor missing"); return false
	original_effects=compositor.compositor_effects.duplicate()
	readback=preload("res://source_tlv_realtime/receiver_draw_readback.gd").new()
	installed_effects=[readback]
	installed_effects.append_array(original_effects)
	compositor.compositor_effects=installed_effects
	return true

func caster_signature(binding: Node) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for state in binding._saved:
		var camera_uniforms: Dictionary = {}
		for key in ["source_tlv_caster_camera_enabled","source_tlv_caster_camera_world","source_tlv_caster_camera_right","source_tlv_caster_camera_back"]:
			camera_uniforms[key]=encode(state.material.get_shader_parameter(key))
		result.append({"material_id":state.material.get_instance_id(),"installed_shader_sha256":state.installed.code.sha256_text(),
			"original_shader_sha256":state.shader.code.sha256_text(),"camera_uniforms":camera_uniforms,
			"render_priority":state.material.render_priority,"next_pass":encode(state.material.next_pass)})
	return result

func synchronize_frozen_light_function() -> void:
	var count := 0
	for node in scene.find_children("*","Node",true,false):
		var script: Script = node.get_script()
		if script!=null and script.resource_path=="res://scripts/original_lightfunctions.gd":
			node._process(0.0)
			count+=1
	check(count==1,"Expected one source LF state owner")

func install_producer(hold: bool) -> bool:
	producer=preload("res://source_tlv_realtime/receiver_diagnostic_owner.gd").new() if hold else preload("res://source_tlv_realtime/realtime_sun.gd").new()
	root.add_child(producer)
	var installed: Dictionary = producer.install(scene,"wuming",{"enable_receiver":true,"max_age_frames":8})
	if installed.get("status")=="failed": check(false,"Producer install failed: "+str(installed)); return false
	# Producer's publication callback must run before the CPU submission observer.
	if RenderingServer.frame_pre_draw.is_connected(on_pre_draw): RenderingServer.frame_pre_draw.disconnect(on_pre_draw)
	RenderingServer.frame_pre_draw.connect(on_pre_draw)
	record_submissions=true
	return true

func wait_publication() -> bool:
	for frame in 180:
		await process_frame
		if int(producer.report.get("published",0))>0:
			original_receiver_states=producer._receiver._saved.duplicate(true)
			report.receiver_install=producer._receiver.report.duplicate(true)
			return true
		if producer.report.get("status") in ["stopped","restore_conflict"]: break
	check(false,"First receiver publication timed out or failed")
	return false

func drain() -> bool:
	for frame in 90:
		await process_frame
		var result: Dictionary = producer.drain_shutdown()
		if bool(result.closed): return true
	check(false,"GPU shutdown did not acknowledge closed")
	return false

func restore_producer(exercise_conflict: bool) -> void:
	record_submissions=false
	expected_mode=-1
	if exercise_conflict:
		var installed_mask: int = producer._probes.installed_mask
		var original_mask: int = producer._probes.original_mask
		var foreign_mask: int = installed_mask ^ 1
		scene.camera.cull_mask=foreign_mask
		producer.stop("Frozen diagnostic completed; deliberate probe owner conflict.")
		var first: Dictionary = producer.report.stop.duplicate(true)
		check(producer.report.status=="restore_conflict" and first.probe.errors.size()==1,"Deliberate probe conflict not retained by stop")
		check(scene.camera.cull_mask==foreign_mask,"Stop overwrote foreign probe camera mask")
		var blocked: Dictionary = producer.retry_restore_shutdown().duplicate(true)
		check(producer.report.status=="restore_conflict" and blocked.probe.errors.size()==1,"Retry lost unresolved probe conflict")
		check(scene.camera.cull_mask==foreign_mask,"Retry overwrote foreign probe camera mask")
		await drain()
		var closed_retry: Dictionary = producer.retry_restore_shutdown().duplicate(true)
		check(closed_retry.gpu_cleanup=="closed" and producer.report.status=="restore_conflict","Closed retry regressed cleanup or hid owner conflict")
		if scene.camera.cull_mask==foreign_mask: scene.camera.cull_mask=installed_mask
		var recovered: Dictionary = producer.retry_restore_shutdown().duplicate(true)
		check(producer.report.status=="stopped" and recovered.probe.errors.is_empty(),"Probe owner recovery failed")
		check(recovered.gpu_cleanup=="closed" and scene.camera.cull_mask==original_mask,"Successful retry lost closed/original mask")
		report.retry_conflict={"stop":first,"blocked_retry":blocked,"closed_retry":closed_retry,"recovered":recovered,
			"original_mask":original_mask,"installed_mask":installed_mask,"foreign_mask":foreign_mask}
	else:
		producer.stop("Normal-time receiver diagnostic completed.")
		await drain()
	check(producer.report.status=="stopped","Producer did not finish in stopped state")
	for key in ["probe","receiver","caster"]: check(producer.report.stop[key].errors.is_empty(),"Unresolved restore errors: "+key)
	for state in original_receiver_states:
		check(state.material.shader==state.shader,"Receiver original shader was not restored")
		if diagnostic_mode=="frozen":
			for key in state.parameters: check(state.material.get_shader_parameter(key)==state.parameters[key],"Frozen original uniform not restored: "+str(key))
	progress("producer-restored")
	producer.queue_free()
	producer=null

func run_frozen() -> void:
	old_process_mode=scene.process_mode
	old_time_scale=Engine.time_scale
	scene.process_mode=Node.PROCESS_MODE_DISABLED
	Engine.time_scale=0.0
	frozen=true
	synchronize_frozen_light_function()
	var baseline := await capture("baseline")
	var repeat := await capture("baseline-repeat")
	exact(baseline,repeat,"baseline_repeat")
	if not report.failures.is_empty(): return
	# Caster camera correction can itself change shadows. Establish a separate
	# same-binding control before attributing any difference to the receiver.
	caster_control=preload("res://source_tlv_realtime/dynamic_caster_binding.gd").new()
	caster_control.restore_on_exit_tree=false
	root.add_child(caster_control)
	var caster_install: Dictionary = caster_control.install(scene,scene.camera,0xFFFFF,false,true)
	check(caster_install.get("status")=="installed","Caster-only control install failed")
	if caster_install.get("status")!="installed": return
	var caster_prepare: Array[String] = caster_control.prepare_snapshot(scene.camera)
	check(caster_prepare.is_empty(),"Caster-only control owner check failed")
	if not caster_prepare.is_empty(): return
	var control_signature := caster_signature(caster_control)
	check(control_signature.size()==165,"Caster-only control expected all 165 Wuming bindings")
	var caster_baseline := await capture("caster-only")
	var caster_repeat := await capture("caster-only-repeat")
	exact(caster_baseline,caster_repeat,"caster_repeat")
	var caster_restore: Dictionary = caster_control.restore()
	check(caster_restore.errors.is_empty() and caster_restore.remaining==0 and caster_restore.restored_materials==165,"Caster-only control did not restore")
	report.caster_control={"install":caster_install,"prepare_errors":caster_prepare,"signature":control_signature,"restore":caster_restore,
		"camera":str(scene.camera.global_transform),
		"original_vs_caster":difference(baseline,caster_baseline)}
	if not caster_restore.errors.is_empty() or caster_restore.remaining!=0: return
	caster_control.queue_free()
	caster_control=null
	if not install_producer(true): return
	check(caster_signature(producer._caster)==control_signature,"Producer caster differs from the isolated control")
	if not await wait_publication(): return
	producer._receiver.set_mode(0)
	expected_mode=0
	var bypass := await capture("receiver-bypass")
	exact(caster_baseline,bypass,"caster_vs_bypass")
	producer._receiver.set_mode(1)
	expected_mode=1
	var lit := await capture("sun-tlv")
	var lit_repeat := await capture("sun-tlv-repeat")
	exact(lit,lit_repeat,"tlv_repeat")
	producer._receiver.set_mode(2)
	expected_mode=2
	var suppressed := await capture("sun-suppressed")
	report.tlv_vs_no_sun=difference(lit,suppressed)
	check(report.tlv_vs_no_sun.png_changed_channels>0 and report.tlv_vs_no_sun.hdr_changed_bytes>0,"No visible TLV sun contribution in main HDR/final PNG")
	producer._receiver.set_mode(0)
	expected_mode=0
	var bypass_return := await capture("receiver-bypass-return")
	exact(caster_baseline,bypass_return,"caster_vs_bypass_return")
	await restore_producer(true)
	var restored := await capture("restored")
	exact(baseline,restored,"baseline_vs_restore")

func run_normal() -> void:
	check(Engine.time_scale==1.0,"Normal diagnostic requires time scale 1")
	if not install_producer(false): return
	expected_mode=1
	for frame in 240:
		await RenderingServer.frame_post_draw
		var result: Dictionary = readback.take_result()
		if not result.is_empty():
			var saved := save_capture(result)
			if saved.is_empty(): break
		if original_receiver_states.is_empty() and producer._receiver!=null:
			original_receiver_states=producer._receiver._saved.duplicate(true)
			report.receiver_install=producer._receiver.report.duplicate(true)
		if report.captures.size()>=4: break
		if producer.report.get("status") in ["stopped","restore_conflict"]: break
	check(report.captures.size()==4 and normal_tokens.size()==4,"Expected four distinct normal-time receiver publication draws")
	if report.captures.size()>=2:
		check(float(report.captures[-1].clock.time)>float(report.captures[0].clock.time),"Normal main-view shader clock did not advance")
	await restore_producer(false)

func finish() -> void:
	record_submissions=false
	if RenderingServer.frame_pre_draw.is_connected(on_pre_draw): RenderingServer.frame_pre_draw.disconnect(on_pre_draw)
	if caster_control!=null:
		var caster_restore: Dictionary = caster_control.restore()
		check(caster_restore.errors.is_empty(),"Caster control cleanup failed")
		caster_control.queue_free()
		caster_control=null
	if producer!=null:
		if bool(producer._running): producer.stop("Receiver diagnostic cleanup after incomplete verification.")
		await drain()
		progress("cleanup")
		producer.queue_free()
		producer=null
	if readback!=null:
		if scene.camera.compositor==compositor and compositor.compositor_effects==installed_effects:
			compositor.compositor_effects=original_effects
		else: check(false,"Main compositor observer owner changed")
		readback.shutdown()
		for frame in 90:
			await process_frame
			if readback.is_closed(): break
		check(readback.is_closed(),"Main readback GPU resources did not acknowledge closed")
		report.readback_closed=readback.is_closed()
	if frozen:
		scene.process_mode=old_process_mode
		Engine.time_scale=old_time_scale
		frozen=false
	progress("complete")
	scene.queue_free()
	for frame in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)

func run() -> void:
	if out.is_empty() or not out.is_absolute_path() or wanted_driver not in ["d3d12","vulkan"] or diagnostic_mode not in ["frozen","normal"] or not opted_in:
		quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	report.mode=diagnostic_mode
	report.driver=RenderingServer.get_current_rendering_driver_name()
	report.method=RenderingServer.get_current_rendering_method()
	report.engine=Engine.get_version_info()
	check(report.driver==wanted_driver and report.method=="forward_plus","Requested backend/Forward+ is not active")
	if not report.failures.is_empty(): progress("backend-rejected"); quit(1); return
	root.size=Vector2i(960,540)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	var ready := false
	for frame in 600:
		await process_frame
		if is_instance_valid(scene.source_renderer) and not scene.loading: ready=true; break
	if not ready: check(false,"Source scene startup timed out"); progress("startup-failed"); quit(1); return
	scene.tour_finished=true
	if scene.slug!="wuming": await scene._load_world("wuming")
	await settle(40)
	if not install_readback(): await finish(); return
	RenderingServer.frame_pre_draw.connect(on_pre_draw)
	progress("ready")
	if diagnostic_mode=="frozen": await run_frozen()
	else: await run_normal()
	await finish()
