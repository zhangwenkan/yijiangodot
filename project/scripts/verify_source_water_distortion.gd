extends SceneTree
var scene: Node3D
var out:=""
var report:={"failures":[],"maps":[],"frames":[]}
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--water-distortion-report-dir="): out=arg.trim_prefix("--water-distortion-report-dir=")
	call_deferred("run")
func check(value: bool,message: String) -> void:
	if not value: report.failures.append(message)
func settle(count: int=4) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func shot(name: String) -> Image:
	await settle()
	var image: Image=root.get_texture().get_image()
	image.save_png(out.path_join(name+".png"))
	report.frames.append({"name":name,"width":image.get_width(),"height":image.get_height()})
	return image
func state(binding: Node) -> Dictionary:
	var draw: MeshInstance3D=binding.draw
	var material: ShaderMaterial=draw.material_override
	var values: Dictionary={}
	for uniform in material.shader.get_shader_uniform_list():
		values[uniform.name]=material.get_shader_parameter(uniform.name)
	var context:=HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for array in draw.mesh.surface_get_arrays(0):
		context.update(var_to_bytes(array))
	return {"mesh":draw.mesh.get_instance_id(),"geometry_sha256":context.finish().hex_encode(),"transform":draw.global_transform,
		"material":material.get_instance_id(),"shader":material.shader.code.sha256_text(),"visible":draw.visible,"shadow":draw.cast_shadow,"evaluated_parameters":values,
		"parameters":draw.get_meta("source_water_parameters",{}).duplicate(true)}
func readback(effect: CompositorEffect, label: String) -> Dictionary:
	effect.request_validation_capture()
	var capture: Dictionary={}
	for i in 90:
		await settle(1)
		capture=effect.take_validation_capture()
		if not capture.is_empty(): break
	check(not capture.is_empty(),"No water distortion readback "+label)
	if capture.is_empty(): return {}
	var directory:=out.path_join(label)
	DirAccess.make_dir_recursive_absolute(directory)
	var metadata:=capture.duplicate()
	for key in capture:
		if capture[key] is PackedByteArray:
			FileAccess.open(directory.path_join(str(key)+".bin"),FileAccess.WRITE).store_buffer(capture[key])
			metadata[key]={"bytes":capture[key].size(),"file":str(key)+".bin"}
	var accumulation: PackedByteArray=capture.accumulation_rgba8
	var nonzero:=0
	var channel_max:=0
	for i in range(0,accumulation.size(),4):
		if accumulation[i]!=0 or accumulation[i+1]!=0 or accumulation[i+2]!=0 or accumulation[i+3]!=0: nonzero+=1
		channel_max=maxi(channel_max,maxi(maxi(accumulation[i],accumulation[i+1]),maxi(accumulation[i+2],accumulation[i+3])))
	metadata["nonzero_accumulation_pixels"]=nonzero
	metadata["max_encoded_channel"]=channel_max
	var clock_bytes: PackedByteArray=capture.get("scene_time_ubo",PackedByteArray())
	if clock_bytes.size()==16:
		metadata["scene_shader_time"]=clock_bytes.decode_float(0)
		check(is_finite(float(metadata.scene_shader_time)),"Nonfinite exact scene TIME "+label)
	else: check(false,"Missing scene TIME UBO capture "+label)
	FileAccess.open(directory.path_join("capture.json"),FileAccess.WRITE).store_string(JSON.stringify(metadata,"\t"))
	check(capture.get("water_uniform_set_valid",false),"Invalid water uniform set "+label)
	return {"nonzero_pixels":nonzero,"max_channel":channel_max,"scene_shader_time":metadata.get("scene_shader_time"),"particle_count":capture.particle_count,"water_active":capture.water_active}
func run() -> void:
	if out.is_empty(): quit(2);return
	DirAccess.make_dir_recursive_absolute(out)
	root.size=Vector2i(1280,720)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		await settle(30)
		var renderer: Node=scene.source_renderer
		var binding: Node=renderer.get("water_binding")
		var effect: CompositorEffect=renderer.distortion
		if binding==null or effect==null:
			check(false,"Install source water binding with distortion enabled "+slug)
			continue
		check(binding.report.bound==1 and binding.report.unsupported.is_empty(),"Water source binding mismatch "+slug)
		if binding.report.bound!=1:continue
		var row: Dictionary={"map":slug,"install":binding.report.duplicate(true)}
		var before:=state(binding)
		var old_mode: int=scene.process_mode
		var old_time: float=Engine.time_scale
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		var saved_snapshot: PackedByteArray=effect.get("_snapshot")
		var saved_count: int=effect.get("_count")
		binding.set_active(false)
		var baseline: Image=await shot(slug+"-baseline-splash-only")
		binding.set_active(true)
		await shot(slug+"-combined-water-and-splash")
		row["combined"]=await readback(effect,slug+"-combined")
		effect.submit_source_instances(PackedFloat32Array(),0)
		await shot(slug+"-water-only-contribution")
		row["water_only"]=await readback(effect,slug+"-water-only")
		check(int(row.water_only.get("nonzero_pixels",0))>0,"No visible native water distortion contribution at harbor "+slug)
		effect.set_audit_mode(1)
		await shot(slug+"-water-accumulation-audit")
		effect.set_audit_mode(0)
		effect.submit_source_instances(saved_snapshot.to_float32_array(),saved_count)
		binding.set_active(false)
		var restored: Image=await shot(slug+"-restore-splash-only")
		check(baseline.get_data()==restored.get_data(),"Frozen baseline/restore pixel mismatch "+slug)
		check(state(binding)==before,"Water source geometry/material/transform changed "+slug)
		row["source_unchanged"]=state(binding)==before
		row["restored_pixels_equal"]=baseline.get_data()==restored.get_data()
		binding.set_active(true)
		scene.process_mode=old_mode
		Engine.time_scale=old_time
		report.maps.append(row)
	FileAccess.open(out.path_join("water-distortion-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_WATER_DISTORTION_VALIDATION ",JSON.stringify({"failures":report.failures,"frames":report.frames.size()}))
	scene.queue_free()
	await settle(4)
	quit(0 if report.failures.is_empty()else 1)
