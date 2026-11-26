extends SceneTree
## Frozen, real-scene sun-only receiver diagnostic. No production installation.
var out := ""
var scene: Node3D
var report: Dictionary = {"maps":[],"captures":[],"failures":[],
	"scope":"Matching frozen scene shadow/LF volumes and final material receivers; sun only, no interactive or UE pixel parity claim."}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tlv-out="): out = arg.trim_prefix("--tlv-out=")
	call_deferred("run")

func progress(stage: String) -> void:
	report.stage = stage
	FileAccess.open(out.path_join("receiver.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("TLV_RECEIVER_PROGRESS ",stage)

func check(value: bool, message: String) -> void:
	if not value: report.failures.append(message)

func synchronize_frozen_light_function() -> void:
	var found := 0
	for node in scene.find_children("*","Node",true,false):
		var script: Script = node.get_script()
		if script != null and script.resource_path == "res://scripts/original_lightfunctions.gd":
			node._process(0.0)
			found += 1
	check(found == 1,"Expected one original LightFunction state owner")

func settle(frames: int = 10) -> void:
	for i in frames: await process_frame
	await RenderingServer.frame_post_draw

func capture(label: String) -> Image:
	await settle()
	if label.begins_with("youxian-default"):
		# Preserve the upstream buffers and actual scene UBO time for the known
		# frozen-background drift. Do not raise the exact-image acceptance gate.
		var folder := out.path_join(label+"-diagnostic")
		DirAccess.make_dir_recursive_absolute(folder)
		var dof: CompositorEffect = scene.source_renderer.depth_of_field.effect
		var separate: CompositorEffect = scene.source_renderer.separate_translucency.effect
		var requested: Dictionary = dof.request_diagnostic(folder.path_join("dof"),1)
		check(bool(requested.get("queued",false)),label+": DOF readback not queued")
		separate.request_capture()
		var layer: Dictionary = {}
		for i in 60:
			await process_frame
			if layer.is_empty(): layer = separate.take_capture()
			if not layer.is_empty() and dof.last_diagnostic.get("directory","")==folder.path_join("dof"): break
		check(not layer.is_empty() and dof.last_diagnostic.get("directory","")==folder.path_join("dof"),label+": stage readback timeout")
		check(bool(dof.last_diagnostic.get("complete",false)) and not dof.last_diagnostic.has("error"),label+": DOF readback failed")
		for key in layer.keys():
			if layer[key] is PackedByteArray:
				FileAccess.open(folder.path_join(str(key)+".bin"),FileAccess.WRITE).store_buffer(layer[key])
				layer[key] = {"file":str(key)+".bin"}
		FileAccess.open(folder.path_join("stage.json"),FileAccess.WRITE).store_string(JSON.stringify(layer,"\t"))
		await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(out.path_join(label+".png"))
	report.captures.append({"name":label,"size":image.get_size(),"camera":str(scene.camera.global_transform),"time_scale":Engine.time_scale})
	return image

func difference(a: Image, b: Image) -> Dictionary:
	if a.get_size() != b.get_size(): return {"error":"Image size mismatch"}
	var av := a.get_data()
	var bv := b.get_data()
	var maximum := 0
	var total := 0.0
	var changed := 0
	for i in av.size():
		var delta := absi(int(av[i])-int(bv[i]))
		maximum = maxi(maximum,delta)
		total += delta
		if delta > 0: changed += 1
	return {"max_channel_delta":maximum,"mean_channel_delta":total/av.size(),"changed_channels":changed}

func views() -> Array[Dictionary]:
	var result: Array[Dictionary] = [{"name":"default","transform":scene.camera.global_transform,"family":"Ocean"}]
	var classifier := preload("res://source_tlv_candidate/source_tlv_sun_receiver.gd").new()
	var found: Dictionary = {}
	for node in scene.world.find_children("*","GeometryInstance3D",true,false):
		if not node.is_visible_in_tree() or (node.layers & scene.camera.cull_mask)==0: continue
		var material: Material = node.material_override
		if material == null and node is MeshInstance3D and node.mesh != null: material = node.get_active_material(0)
		if not material is ShaderMaterial or material.shader == null: continue
		var family: String = classifier._family(material.shader.code)
		if family not in ["Water","Waterfall","Smoke1","SmokeSubUV","Splash"] or found.has(family): continue
		var anchor: Vector3 = node.global_position
		if node is MultiMeshInstance3D:
			if node.multimesh == null or node.multimesh.visible_instance_count == 0 or node.multimesh.instance_count == 0: continue
			var count: int = node.multimesh.instance_count if node.multimesh.visible_instance_count<0 else node.multimesh.visible_instance_count
			var active := -1
			for index in count:
				var pose: Transform3D = node.multimesh.get_instance_transform(index)
				if node.multimesh.get_instance_color(index).a>0.001 and pose.basis.get_scale().length_squared()>0.000001:
					active = index; break
			if active<0: continue
			anchor = node.global_transform * node.multimesh.get_instance_transform(active).origin
		elif family == "Waterfall": anchor.y -= 4.0
		elif family == "Water": anchor = node.global_transform * node.get_aabb().get_center()
		var pose: Transform3D = scene.camera.global_transform
		pose.origin = anchor + pose.basis.z.normalized()*32.2
		result.append({"name":family.to_lower(),"family":family,"material_id":material.get_instance_id(),"transform":pose,"anchor":anchor,"source_node":str(node.get_path())})
		found[family] = true
	classifier.free()
	for family in (["Water","Waterfall","Smoke1","SmokeSubUV","Splash"] if scene.slug=="wuming" else ["Water"]): check(found.has(family),"Missing visible diagnostic anchor "+family)
	return result

func snapshot(bounds: Array[Dictionary], folder: String) -> Dictionary:
	var probe := preload("res://source_tlv_candidate/sun_probe.gd").new()
	root.add_child(probe)
	var installed: Dictionary = probe.install(scene)
	var captures: Array[PackedByteArray] = []
	var failed := ""
	if installed.has("error"):
		failed = installed.error
	else:
		for cascade in 2:
			probe.set_bounds(bounds[cascade].min_ue_cm,bounds[cascade].voxel_cm)
			await settle(6)
			if not probe.readback.request_face(cascade): failed = "Probe busy"; break
			var result: Dictionary = {}
			for i in 60:
				await process_frame
				result = probe.readback.take_result()
				if not result.is_empty(): break
			if result.is_empty() or result.has("error"):
				failed = "Probe failed "+str(result); break
			captures.append(result.bytes)
			FileAccess.open(folder.path_join("cascade"+str(cascade)+"-shadow-lf.rgba16f"),FileAccess.WRITE).store_buffer(result.bytes)
	var sun: DirectionalLight3D = probe.get("_sun")
	probe.restore()
	probe.queue_free()
	await settle(4)
	if not failed.is_empty(): return {"error":failed}
	var started := Time.get_ticks_msec()
	var baked: Dictionary = preload("res://source_tlv_candidate/frozen_sun_baker.gd").bake(captures,bounds,sun,folder)
	baked.bake_msec = Time.get_ticks_msec()-started
	baked.probe = installed
	baked.sun_shadow_enabled = sun.shadow_enabled
	baked.sun_light_function_disabled = sun.get_meta("source_house_light_function_disabled",false)
	return baked

func verify_view(view: Dictionary, entry: Dictionary) -> void:
	scene.camera.global_transform = view.transform
	var label: String = scene.slug+"-"+view.name
	progress(label+": snapshot")
	var folder := out.path_join(label)
	DirAccess.make_dir_recursive_absolute(folder)
	var bounds: Array[Dictionary] = preload("res://source_tlv_candidate/volume_bounds.gd").from_camera(scene.camera,16.0/9.0)
	var baked := await snapshot(bounds,folder)
	if baked.has("error"):
		check(false,label+": "+baked.error); return
	var textures: Array[Dictionary] = baked.textures
	baked.erase("textures")
	var item := {"name":view.name,"camera":str(scene.camera.global_transform),"bounds":bounds,"bake":baked}
	var before := await capture(label+"-baseline")
	var repeat := await capture(label+"-baseline-repeat")
	item.baseline_repeat = difference(before,repeat)
	check(item.baseline_repeat.max_channel_delta == 0,label+": frozen baseline unstable")
	var receiver := preload("res://source_tlv_candidate/source_tlv_sun_receiver.gd").new()
	root.add_child(receiver)
	item.install = receiver.install(scene,bounds,textures)
	if item.install.get("status","") != "installed":
		check(false,label+": receiver install failed "+str(item.install)); receiver.queue_free(); entry.views.append(item); return
	# The two source waterfall surfaces share one ShaderMaterial.
	var expected := {"Ocean":1,"Water":1,"Waterfall":1 if scene.slug=="wuming" else 0,"Smoke1":11 if scene.slug=="wuming" else 0,"SmokeSubUV":5 if scene.slug=="wuming" else 0,"Splash":9 if scene.slug=="wuming" else 0}
	for family in expected: check(int(receiver.report.family_counts.get(family,0)) == expected[family],label+": unexpected "+family+" material count")
	var saved: Array = receiver.get("_saved").duplicate()
	for state in saved:
		for key in state.parameters: check(state.material.get_shader_parameter(key)==state.parameters[key],label+": original uniform changed "+str(key))
	for audit in receiver.report.materials:
		check(audit.vertex_preserved and audit.fragment_preserved_as_prefix,label+": original vertex/fragment changed")
	receiver.set_mode(0)
	var mode0 := await capture(label+"-receiver-bypass")
	item.baseline_vs_bypass = difference(before,mode0)
	check(item.baseline_vs_bypass.max_channel_delta==0,label+": receiver bypass differs from original")
	receiver.set_mode(1)
	var lit := await capture(label+"-sun-tlv")
	item.baseline_vs_tlv = difference(mode0,lit)
	receiver.set_mode(2)
	var no_sun := await capture(label+"-sun-suppressed")
	item.tlv_vs_no_sun = difference(lit,no_sun)
	check(item.tlv_vs_no_sun.changed_channels>0,label+": no visible sun-volume contribution")
	if view.has("family"):
		receiver.set_mode(0)
		var selected: ShaderMaterial
		for state in saved:
			if state.family == view.family and (not view.has("material_id") or state.material.get_instance_id()==view.material_id):
				selected = state.material; break
		check(selected != null,label+": target material missing")
		if selected != null:
			selected.set_shader_parameter("source_tlv_sun_mode",1)
			var isolated := await capture(label+"-target-tlv")
			selected.set_shader_parameter("source_tlv_sun_mode",2)
			var target_off := await capture(label+"-target-suppressed")
			item.target_material_delta = difference(isolated,target_off)
			item.target_family = view.family
			check(item.target_material_delta.changed_channels>0,label+": target material invisible or unlit")
	if view.name == "default":
		# A partially conflicting restore must be recoverable without retaining
		# already-restored entries and permanently mistaking them for new owners.
		var state: Dictionary = saved[0]
		var intruder := Shader.new()
		intruder.code = state.installed.code
		state.material.shader = intruder
		var conflict: Dictionary = receiver.restore()
		check(conflict.errors.size()==1 and conflict.restored_materials==saved.size()-1,label+": ownership conflict handling")
		state.material.shader = state.installed
		item.ownership_conflict = conflict
	item.restore = receiver.restore()
	check(item.restore.errors.is_empty(),label+": restore ownership failed")
	for state in saved:
		check(state.material.shader==state.shader,label+": shader not restored")
		for key in state.parameters: check(state.material.get_shader_parameter(key)==state.parameters[key],label+": uniform not restored "+str(key))
	var restored := await capture(label+"-restored")
	item.baseline_vs_restore = difference(before,restored)
	check(item.baseline_vs_restore.max_channel_delta==0,label+": restored frame differs from baseline")
	receiver.queue_free()
	entry.views.append(item)
	progress(label+": complete")

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(960,540)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading: await process_frame
	scene.tour_finished = true
	for slug in ["wuming","youxian"]:
		if scene.slug != slug: await scene._load_world(slug)
		await settle(40)
		var old_mode: int = scene.process_mode
		var old_time := Engine.time_scale
		var old_camera: Transform3D = scene.camera.global_transform
		scene.process_mode = Node.PROCESS_MODE_DISABLED
		Engine.time_scale = 0.0
		synchronize_frozen_light_function()
		var entry := {"map":slug,"views":[]}
		for view in views(): await verify_view(view,entry)
		# Exercise the actual house transition. Source indoor sun is 3/PI, not zero.
		scene.house_driver.set_inside(true)
		synchronize_frozen_light_function()
		await verify_view({"name":"inside-state","transform":scene.camera.global_transform},entry)
		scene.house_driver.set_inside(false)
		synchronize_frozen_light_function()
		scene.camera.global_transform = old_camera
		scene.process_mode = old_mode
		Engine.time_scale = old_time
		report.maps.append(entry)
		progress(slug+": restored")
	scene.queue_free()
	await settle(5)
	progress("complete")
	quit(0 if report.failures.is_empty() else 1)
