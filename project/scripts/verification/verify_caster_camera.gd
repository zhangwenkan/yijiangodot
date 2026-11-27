extends SceneTree
## Bounded single-map diagnostic; not a production installation.
## --tlv-out=<absolute folder> --caster-binding=<absolute .gd or res:// path>
## Optional --caster-map=youxian. Default is wuming while frozen drift is audited.
var out := ""
var slug := "wuming"
var binding_path := "res://source_tlv_candidate/source_tlv_caster_camera_binding.gd"
var scene: Node3D
var binding: Node
var probe: Node
var old_mode := Node.PROCESS_MODE_INHERIT
var old_time := 1.0
var old_camera := Transform3D.IDENTITY
var old_mask := 0
var frozen := false
var ubo_observers: Array[Dictionary] = []
var compositor_states: Array[Dictionary] = []
var capture_token := 0
var report := {"stage":"starting","failures":[],"captures":[],"probe_captures":[],
	"enabled_captures_per_cascade":4,"shadow_refresh_forced":false,
	"scope":"One frozen source scene; exact disabled and restore controls, bound world geometry inputs, retained original masks. No source UE shadow parity claim."}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tlv-out="): out = arg.trim_prefix("--tlv-out=")
		elif arg.begins_with("--caster-binding="): binding_path = arg.trim_prefix("--caster-binding=")
		elif arg.begins_with("--caster-map="): slug = arg.trim_prefix("--caster-map=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: report.failures.append(message)

func progress(stage: String) -> void:
	report.stage = stage
	FileAccess.open(out.path_join("caster-camera.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("TLV_CASTER_PROGRESS ",stage)

func settle(frames: int = 10) -> void:
	for i in frames: await process_frame
	await RenderingServer.frame_post_draw

func capture(label: String) -> Image:
	await settle()
	var image := root.get_texture().get_image()
	image.save_png(out.path_join(label+".png"))
	report.captures.append({"label":label,"size":image.get_size(),"camera":str(scene.camera.global_transform),"time_scale":Engine.time_scale})
	return image

func difference(a: Image, b: Image) -> Dictionary:
	if a.get_size()!=b.get_size() or a.get_format()!=b.get_format(): return {"max_channel_delta":-1,"error":"Image format/size mismatch"}
	var av := a.get_data()
	var bv := b.get_data()
	var maximum := 0
	var total := 0.0
	var changed := 0
	for index in av.size():
		var delta := absi(int(av[index])-int(bv[index]))
		maximum = maxi(maximum,delta)
		total += delta
		if delta>0: changed += 1
	return {"max_channel_delta":maximum,"changed_channels":changed,"mean_channel_delta":total/av.size()}

func geometry_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for node in scene.find_children("*","GeometryInstance3D",true,false):
		var state := {"node":node,"path":str(node.get_path()),"transform":node.transform,"visible":node.visible,
			"layers":node.layers,"cast_shadow":node.cast_shadow,"override":node.material_override,"overlay":node.material_overlay}
		if node is MeshInstance3D:
			state.mesh = node.mesh
			state.surface_materials = []
			if node.mesh != null:
				for surface in node.mesh.get_surface_count(): state.surface_materials.append(node.get_active_material(surface))
		elif node is MultiMeshInstance3D:
			state.multimesh = node.multimesh
			if node.multimesh != null:
				state.buffer = node.multimesh.buffer
				state.visible_instances = node.multimesh.visible_instance_count
		elif node is SpriteBase3D:
			state.billboard = node.billboard
			if node is AnimatedSprite3D:
				state.animation = node.animation
				state.frame = node.frame
		result.append(state)
	return result

func verify_geometry(snapshot: Array[Dictionary], label: String) -> void:
	for state in snapshot:
		var node: GeometryInstance3D = state.node
		if not is_instance_valid(node): check(false,label+": disappeared "+state.path); continue
		check(node.transform==state.transform and node.visible==state.visible and node.layers==state.layers and node.cast_shadow==state.cast_shadow,label+": geometry transform/visibility/layers/shadow changed "+state.path)
		check(node.material_override==state.override and node.material_overlay==state.overlay,label+": material assignment changed "+state.path)
		if node is MeshInstance3D:
			check(node.mesh==state.mesh,label+": mesh resource changed "+state.path)
			if node.mesh!=null and node.mesh==state.mesh:
				for surface in node.mesh.get_surface_count(): check(node.get_active_material(surface)==state.surface_materials[surface],label+": surface material changed "+state.path)
		elif node is MultiMeshInstance3D:
			check(node.multimesh==state.multimesh,label+": MultiMesh resource changed "+state.path)
			if node.multimesh!=null and node.multimesh==state.multimesh:
				check(node.multimesh.buffer==state.buffer and node.multimesh.visible_instance_count==state.visible_instances,label+": instance buffer changed "+state.path)
		elif node is SpriteBase3D:
			check(node.billboard==state.billboard,label+": billboard mode changed "+state.path)
			if node is AnimatedSprite3D: check(node.animation==state.animation and node.frame==state.frame,label+": source sprite frame changed "+state.path)

func probe_capture(label: String, cascade: int) -> PackedByteArray:
	await settle(8)
	var before_state: Dictionary = capture_owner_state()
	capture_token += 1
	for item in ubo_observers: check(item.effect.request(capture_token),label+": UBO observer busy "+item.label)
	if not probe.readback.request_face(capture_token): check(false,label+": probe busy"); return PackedByteArray()
	var result: Dictionary = {}
	var observed: Dictionary = {}
	for i in 90:
		await process_frame
		if result.is_empty(): result = probe.readback.take_result()
		for item in ubo_observers:
			if not observed.has(item.label):
				var value: Dictionary = item.effect.take()
				if not value.is_empty(): observed[item.label] = value
		if not result.is_empty() and observed.size()==ubo_observers.size(): break
	if result.is_empty() or result.has("error"):
		check(false,label+": probe readback failed "+str(result)); return PackedByteArray()
	var bytes: PackedByteArray = result.bytes
	check(result.get("token",-1)==capture_token,label+": HDR capture token mismatch")
	check(result.size==Vector2i(512,512) and bytes.size()==512*512*8,label+": wrong probe dimensions/byte count")
	FileAccess.open(out.path_join(label+".rgba16f"),FileAccess.WRITE).store_buffer(bytes)
	check(observed.size()==ubo_observers.size(),label+": incomplete view UBO readback")
	for key in observed:
		var clock_bytes: PackedByteArray = observed[key].scene_ubo
		var filename: String = label+"-"+str(key)+"-scene-ubo.bin"
		FileAccess.open(out.path_join(filename),FileAccess.WRITE).store_buffer(clock_bytes)
		observed[key].scene_ubo = {"file":filename,"bytes":clock_bytes.size(),"sha256":sha256(clock_bytes)}
	for view in ["main","probe"]:
		if observed.has(view+"-before") and observed.has(view+"-after"):
			check(observed[view+"-before"].drawn_frame==observed[view+"-after"].drawn_frame,label+": "+view+" observer stages captured different frames")
	var entry: Dictionary = {"label":label,"size":result.size,"bytes":bytes.size(),"camera":str(probe.camera.global_transform),"bound":binding.report.enabled,
		"before_state":before_state,"after_state":capture_owner_state(),"view_ubo":observed,"capture_token":capture_token,
		"query_min_ue_cm":vec3_values(probe.material.get_shader_parameter("volume_min_ue_cm")),
		"query_voxel_cm":probe.material.get_shader_parameter("voxel_cm"),
		"query_sun_world_direction":vec3_values(probe.material.get_shader_parameter("sun_world_direction"))}
	report.probe_captures.append(entry)
	FileAccess.open(out.path_join(label+"-metadata.json"),FileAccess.WRITE).store_string(JSON.stringify(entry,"\t"))
	return bytes

func sha256(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty(): hash.update(bytes)
	return hash.finish().hex_encode()

func vec3_values(value: Vector3) -> Array:
	return [value.x,value.y,value.z]

func capture_owner_state() -> Dictionary:
	var sun: DirectionalLight3D = probe.get("_sun")
	var state: Dictionary = {"sun_shadow_enabled":sun.shadow_enabled,"sun_visible":sun.visible,"sun_transform":str(sun.global_transform),
		"sun_shadow_caster_mask":sun.shadow_caster_mask,"sun_light_cull_mask":sun.light_cull_mask,"sun_energy":sun.light_energy,
		"sun_directional_mode":sun.directional_shadow_mode,"sun_max_distance":sun.directional_shadow_max_distance,
		"main_cull_mask":scene.camera.cull_mask,"probe_cull_mask":probe.camera.cull_mask,"main_camera":str(scene.camera.global_transform),
		"probe_camera":str(probe.camera.global_transform),"binding_errors":binding.verify_bound_state(),"binding_enabled":binding.report.enabled,
		"engine_time_scale":Engine.time_scale,"drawn_frame":Engine.get_frames_drawn()}
	check(state.binding_errors.is_empty(),"Binding drift at capture boundary")
	return state

func install_ubo_observers() -> bool:
	var script: Script = load("res://scripts/verification/caster_ubo_readback.gd")
	if script==null or not script.can_instantiate(): check(false,"UBO readback script failed Godot compilation"); return false
	for pair in [["main",scene.camera],["probe",probe.camera]]:
		var compositor: Compositor = pair[1].compositor
		if compositor==null: check(false,"Missing compositor for "+pair[0]); return false
		var original: Array[CompositorEffect] = compositor.compositor_effects.duplicate()
		var before: CompositorEffect = script.new()
		var after: CompositorEffect = script.new()
		var installed: Array[CompositorEffect] = [before]
		installed.append_array(original)
		installed.append(after)
		compositor_states.append({"camera":pair[1],"compositor":compositor,"original":original,"installed":installed})
		# Retain compositor identity for the original separate-layer owner.
		compositor.compositor_effects = installed
		ubo_observers.append({"label":pair[0]+"-before","effect":before})
		ubo_observers.append({"label":pair[0]+"-after","effect":after})
	return true

func restore_ubo_observers() -> void:
	for item in ubo_observers: item.effect.enabled = false
	for state in compositor_states:
		if is_instance_valid(state.camera) and state.camera.compositor==state.compositor and state.compositor.compositor_effects==state.installed:
			state.compositor.compositor_effects = state.original
		else: check(false,"UBO observer compositor ownership changed")
	ubo_observers.clear()
	compositor_states.clear()

func save_original_binding_parameters() -> void:
	var entries: Array[Dictionary] = []
	for state in binding.get("_saved"):
		var parameters: Dictionary = {}
		for key in state.parameters:
			var value: Variant = state.parameters[key]
			if value is Resource:
				parameters[key] = {"variant_type":type_string(typeof(value)),"resource_class":value.get_class(),"resource_path":value.resource_path,"instance_id":value.get_instance_id()}
			else: parameters[key] = {"variant_type":type_string(typeof(value)),"value":var_to_str(value)}
		entries.append({"node":state.node,"family":state.family,"original_shader_sha256":state.original_sha256,"parameters":parameters,
			"bound_camera_world":vec3_values(state.material.get_shader_parameter("source_tlv_caster_camera_world")),
			"bound_camera_right":vec3_values(state.material.get_shader_parameter("source_tlv_caster_camera_right")),
			"bound_camera_back":vec3_values(state.material.get_shader_parameter("source_tlv_caster_camera_back"))})
	FileAccess.open(out.path_join("binding-original-parameters.json"),FileAccess.WRITE).store_string(JSON.stringify(entries,"\t"))

func finish() -> void:
	restore_ubo_observers()
	# Stop the secondary viewport before releasing the shader owner it depends on.
	if is_instance_valid(probe):
		probe.restore()
		probe.queue_free()
		probe = null
		await settle(4)
	if is_instance_valid(binding):
		report.cleanup_restore = binding.restore()
		check(report.cleanup_restore.remaining==0 and report.cleanup_restore.errors.is_empty(),"Final binding cleanup retained unresolved owners")
		binding.queue_free()
		binding = null
	if is_instance_valid(scene):
		if frozen:
			scene.camera.global_transform = old_camera
			scene.camera.cull_mask = old_mask
			scene.process_mode = old_mode
			Engine.time_scale = old_time
			frozen = false
		scene.queue_free()
		await settle(4)
	progress("complete" if report.failures.is_empty() else "failed")
	quit(0 if report.failures.is_empty() else 1)

func run() -> void:
	if out.is_empty() or slug not in ["wuming","youxian"]: quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	report.map = slug
	report.binding_path = binding_path
	root.size = Vector2i(960,540)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	var ready_scene := false
	for i in 1800:
		await process_frame
		if is_instance_valid(scene.source_renderer) and not scene.loading: ready_scene = true; break
	if not ready_scene: check(false,"Source scene load timed out"); await finish(); return
	scene.tour_finished = true
	if scene.slug!=slug: await scene._load_world(slug)
	await settle(40)
	old_mode = scene.process_mode
	old_time = Engine.time_scale
	old_camera = scene.camera.global_transform
	old_mask = scene.camera.cull_mask
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	Engine.time_scale = 0.0
	frozen = true
	var owners := 0
	for node in scene.find_children("*","Node",true,false):
		var script: Script = node.get_script()
		if script!=null and script.resource_path=="res://scripts/original_lightfunctions.gd": node._process(0.0); owners += 1
	check(owners==1,"Expected one frozen source LightFunction owner")
	var geometry := geometry_snapshot()
	report.geometry_count = geometry.size()
	progress("baseline")
	var baseline := await capture("baseline")
	var repeat := await capture("baseline-repeat")
	report.baseline_repeat = difference(baseline,repeat)
	check(report.baseline_repeat.max_channel_delta==0,"Frozen baseline drift before installing candidate")
	if not report.failures.is_empty(): await finish(); return
	var script: Script = load(binding_path)
	if script==null or not script.can_instantiate(): check(false,"Candidate script unavailable or Godot compilation failed"); await finish(); return
	binding = script.new()
	root.add_child(binding)
	report.install = binding.install(scene,scene.camera,0xFFFFF,false,false)
	check(report.install.get("status","")=="installed","Strict candidate installation failed")
	if report.install.get("status","")!="installed": await finish(); return
	check(int(report.install.family_counts.CharacterFixedY)>=1,"Player outside scene.world was not included")
	var saved: Array = binding.get("_saved").duplicate()
	save_original_binding_parameters()
	var bypass := await capture("bound-disabled")
	report.baseline_vs_disabled = difference(baseline,bypass)
	check(report.baseline_vs_disabled.max_channel_delta==0,"Disabled candidate differs from baseline")
	check(binding.set_enabled(true).is_empty(),"Could not enable frozen caster inputs")
	var enabled := await capture("bound-enabled")
	report.baseline_vs_enabled = difference(baseline,enabled)
	# Do not require enabled=baseline: source wind shadow pass formerly used light distance.
	check(binding.verify_bound_state().is_empty(),"Bound state changed before probe")
	verify_geometry(geometry,"bound")
	progress("probe")
	probe = load("res://source_tlv_candidate/sun_probe.gd").new()
	root.add_child(probe)
	report.probe_install = probe.install(scene)
	if report.probe_install.has("error"): check(false,"Probe install failed"); await finish(); return
	if not install_ubo_observers(): await finish(); return
	var bounds: Array[Dictionary] = load("res://source_tlv_candidate/volume_bounds.gd").from_camera(scene.camera,16.0/9.0)
	report.bounds = bounds
	for cascade in 2:
		probe.set_bounds(bounds[cascade].min_ue_cm,bounds[cascade].voxel_cm)
		check(binding.set_enabled(false).is_empty(),"Could not bypass caster inputs for probe")
		await probe_capture("cascade"+str(cascade)+"-disabled",cascade)
		check(binding.set_enabled(true).is_empty(),"Could not bind caster inputs for probe")
		var first: PackedByteArray = PackedByteArray()
		for repeat_index in 4:
			var suffix: String = "enabled" if repeat_index==0 else ("enabled-repeat" if repeat_index==1 else "enabled-repeat"+str(repeat_index))
			var current: PackedByteArray = await probe_capture("cascade"+str(cascade)+"-"+suffix,cascade)
			if repeat_index==0: first = current
			else: check(not first.is_empty() and first==current,"Bound frozen probe repeat drift at cascade "+str(cascade)+" repeat "+str(repeat_index))
	restore_ubo_observers()
	probe.restore()
	probe.queue_free()
	probe = null
	await settle(4)
	check(scene.camera.cull_mask==old_mask,"Probe did not restore original camera mask")
	check(binding.verify_bound_state().is_empty(),"Bound state changed after probe")
	check(binding.set_enabled(false).is_empty(),"Could not bypass after stopping probe")
	var post_probe := await capture("post-probe-disabled")
	report.baseline_vs_post_probe_disabled = difference(baseline,post_probe)
	check(report.baseline_vs_post_probe_disabled.max_channel_delta==0,"Post-probe disabled candidate differs from baseline")
	progress("restore")
	# Deliberately add a reversible competing shader owner; successful states retire.
	var conflict_state: Dictionary = saved[0]
	var intruder := Shader.new()
	intruder.code = conflict_state.installed.code
	conflict_state.material.shader = intruder
	report.owner_conflict = binding.restore()
	check(report.owner_conflict.remaining==1 and report.owner_conflict.errors.size()==1 and report.owner_conflict.restored_materials==saved.size()-1,"Partial restore owner-conflict contract failed")
	check(conflict_state.material.shader==intruder,"Conflicting shader owner was overwritten")
	conflict_state.material.shader = conflict_state.installed
	report.restore = binding.restore()
	check(report.restore.remaining==0 and report.restore.errors.is_empty(),"Retry restore failed")
	for state in saved:
		check(state.material.shader==state.shader and state.material.shader.code.sha256_text()==state.original_sha256,"Original shader not restored: "+state.node)
		check(state.material.next_pass==state.next_pass and state.material.render_priority==state.render_priority,"Pass/priority not restored: "+state.node)
		for key in state.parameters: check(state.material.get_shader_parameter(key)==state.parameters[key],"Original parameter not restored: "+state.node+" / "+str(key))
	verify_geometry(geometry,"restored")
	var restored := await capture("restored")
	report.baseline_vs_restore = difference(baseline,restored)
	check(report.baseline_vs_restore.max_channel_delta==0,"Restored frame differs from baseline")
	await finish()
