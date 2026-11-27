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
	var full_ubo: PackedByteArray=capture.get("scene_ubo_full",PackedByteArray())
	var clock_valid: bool=full_ubo.size()==5696 and clock_bytes.size()==16 and capture.get("scene_time_offset",-1)==2816 and capture.get("scene_ubo_layout","")=="godot-4.7.2-float-2848x2"
	if clock_valid:
		clock_valid=clock_bytes==full_ubo.slice(2816,2832)
	metadata["scene_clock_layout_verified"]=clock_valid
	if clock_valid:
		metadata["scene_shader_time"]=clock_bytes.decode_float(0)
		metadata["scene_taa_frame_count"]=clock_bytes.decode_float(4)
		check(is_finite(float(metadata.scene_shader_time)),"Nonfinite verified scene TIME "+label)
	else: check(false,"Missing or unsupported scene TIME UBO layout "+label)
	FileAccess.open(directory.path_join("capture.json"),FileAccess.WRITE).store_string(JSON.stringify(metadata,"\t"))
	check(capture.get("water_uniform_set_valid",false),"Invalid water uniform set "+label)
	return {"nonzero_pixels":nonzero,"max_channel":channel_max,"scene_shader_time":metadata.get("scene_shader_time"),
		"scene_taa_frame_count":metadata.get("scene_taa_frame_count"),"scene_clock_layout_verified":clock_valid,
		"water_frame_sha256":byte_hash(capture.get("water_frame_rgba32f",PackedByteArray())),
		"accumulation_file":directory.path_join("accumulation_rgba8.bin"),"capture_file":directory.path_join("capture.json"),
		"particle_count":capture.particle_count,"water_active":capture.water_active}
func byte_hash(bytes: PackedByteArray) -> String:
	var hash:=HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty(): hash.update(bytes)
	return hash.finish().hex_encode()
func verify_shared_water_clock(binding: Node) -> Dictionary:
	var material: ShaderMaterial=binding.draw.material_override
	var code: String=material.shader.code
	var expected: Array[String]=["TIME*surge_speed","TIME*wave_normal_speed*vec2(-0.5,0.8)","TIME*wave_normal_speed*vec2(0.4,-0.6)",
		"TIME*ocean_normal_speed*vec2(-0.5,1.2)","TIME*ocean_normal_speed*vec2(0.9,-0.6)","TIME*ocean_normal_speed*vec2(-1.2,0.2)","TIME*ocean_normal_speed*vec2(0.8,0.2)"]
	var missing: Array[String]=[]
	for token in expected:
		if not code.contains(token): missing.append(token)
	check(missing.is_empty(),"Actual main water shader time expressions changed")
	var pass_files: Dictionary={}
	for stage_name in ["vert","frag"]:
		var path: String="res://source_water_distortion_candidate/water_accumulate."+stage_name+".glsl.txt"
		var shader_source: String=FileAccess.get_file_as_string(path)
		var correct: bool=shader_source.contains("vec4 preceding[176]; vec4 time_taa;") and shader_source.contains("float t=clock_data.time_taa.x;") and not shader_source.contains("preceding[177]")
		check(correct,"Water distortion source clock contract changed "+stage_name)
		pass_files[stage_name]={"sha256":shader_source.sha256_text(),"clock_offset_verified":correct}
	return {"main_shader_sha256":code.sha256_text(),"main_shader_missing_time_expressions":missing,"distortion_shaders":pass_files,
		"shared_input":"The main Forward+ material TIME maps to scene_data_block.data.time; both distortion shaders bind this same main-view Scene UBO at binding 8 and read byte 2816.",
		"scope":"Source binding plus actual GPU-input capture; not independent native-UE frame parity."}
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
		# Keep CPU owners disabled: only the actual engine shader clock advances.
		var dynamic_failure_start: int=report.failures.size()
		row["main_water_clock_source"]=verify_shared_water_clock(binding)
		binding.set_active(true)
		effect.submit_source_instances(PackedFloat32Array(),0)
		Engine.time_scale=1.0
		await settle(60)
		Engine.time_scale=0.0
		await settle(8)
		row["water_only_later"]=await readback(effect,slug+"-water-only-later")
		var first: Dictionary=row.water_only
		var later: Dictionary=row.water_only_later
		var first_time: float=float(first.scene_shader_time) if first.get("scene_clock_layout_verified",false) else -1.0
		var later_time: float=float(later.scene_shader_time) if later.get("scene_clock_layout_verified",false) else -1.0
		var time_valid: bool=first.get("scene_clock_layout_verified",false) and later.get("scene_clock_layout_verified",false) and is_finite(first_time) and is_finite(later_time) and later_time>first_time
		check(time_valid,"Real main-view scene TIME did not advance with verified layout "+slug)
		check(first.get("particle_count",-1)==0 and later.get("particle_count",-1)==0,"Water-only capture contains particle distortion "+slug)
		check(first.get("water_active",false) and later.get("water_active",false),"Water-only capture was inactive "+slug)
		check(scene.process_mode==Node.PROCESS_MODE_DISABLED,"CPU scene advanced during water clock test "+slug)
		check(first.get("water_frame_sha256","")==later.get("water_frame_sha256",""),"Water frame/camera/parameters changed during clock-only advance "+slug)
		check(state(binding)==before,"Water source changed during clock-only advance "+slug)
		var first_bytes: PackedByteArray=FileAccess.get_file_as_bytes(first.get("accumulation_file",""))
		var later_bytes: PackedByteArray=FileAccess.get_file_as_bytes(later.get("accumulation_file",""))
		var changed_bytes: int=0
		if first_bytes.size()==later_bytes.size() and not first_bytes.is_empty():
			for byte_index in first_bytes.size():
				if first_bytes[byte_index]!=later_bytes[byte_index]: changed_bytes+=1
		else: check(false,"Missing or mismatched dual-time accumulation readback "+slug)
		check(changed_bytes>0,"Water-only distortion accumulation did not change at later real TIME "+slug)
		check(int(later.get("nonzero_pixels",0))>0,"Later water-only distortion contribution absent "+slug)
		row["water_dynamic"]={"passed":report.failures.size()==dynamic_failure_start,"first_time":first_time,"later_time":later_time,
			"elapsed_scene_time":later_time-first_time,"advance_process_frames":60,"cpu_scene_process_stayed_disabled":scene.process_mode==Node.PROCESS_MODE_DISABLED,
			"scope":"Verified same main-view TIME input and dynamic response. Shader-driven opaque depth can also change; not isolated causality or original UE parity.",
			"accumulation_changed_bytes":changed_bytes,"water_frame_exact":first.get("water_frame_sha256","")==later.get("water_frame_sha256","")}
		await shot(slug+"-water-only-later")
		effect.submit_source_instances(saved_snapshot.to_float32_array(),saved_count)
		scene.process_mode=old_mode
		Engine.time_scale=old_time
		report.maps.append(row)
	FileAccess.open(out.path_join("water-distortion-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_WATER_DISTORTION_VALIDATION ",JSON.stringify({"failures":report.failures,"frames":report.frames.size()}))
	scene.queue_free()
	await settle(4)
	quit(0 if report.failures.is_empty()else 1)
