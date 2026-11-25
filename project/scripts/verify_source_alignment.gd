extends SceneTree
## Normal-render source alignment check; no alpha, material, emission, or audit overrides.
var out := ""
var scene: Node3D
var driver: Node
var report := {"failures":[], "binding":{}, "frames":[], "splash":{}}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--alignment-report-dir="):
			out = arg.trim_prefix("--alignment-report-dir=")
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition:
		report.failures.append(label)

func vec(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func safe_unit(value: Vector3) -> Vector3:
	return value / sqrt(maxf(value.length_squared(), 0.00000001))

func expected_basis(emitter, index: int) -> Dictionary:
	var model: Transform3D = emitter.draw.global_transform * emitter.multi.get_instance_transform(index)
	var camera_direction := safe_unit((scene.camera.global_position-model.origin)*100.0)
	var x: Vector3
	var y: Vector3
	if emitter.source_alignment == 1:
		var value: Color = emitter.direction_image.get_pixel(index, 0)
		var direction := safe_unit(Vector3(value.r,value.g,value.b))
		x = -safe_unit(camera_direction.cross(direction))
		y = direction
	else:
		var axis: Vector3 = emitter.source_axis
		var down := safe_unit(axis.cross(camera_direction))
		var angle: float = -emitter.multi.get_instance_custom_data(index).r + 1.5707963705062866
		x = sin(angle)*down+cos(angle)*axis
		y = sin(angle)*axis-cos(angle)*down
	return {"position":vec(model.origin),"x":vec(x),"y":vec(y),
		"normal":vec(safe_unit(x.cross(y))),"screen":str(scene.camera.unproject_position(model.origin)),
		"kind":"CPU expected basis from uploaded direction; screenshot verifies actual rendering"}

func shot(label: String, emitter = null) -> void:
	for i in 10:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := out.path_join(label+".png")
	check(root.get_texture().get_image().save_png(path)==OK,"screenshot saved: "+label)
	var frame := {"file":path,"camera_position":vec(scene.camera.global_position),
		"camera_basis":str(scene.camera.global_basis),"normal_materials":true,"alpha_override":false,
		"inspection_dof_disabled":true}
	if emitter != null and not emitter.particles.is_empty():
		frame["source_component"] = emitter.source_group
		frame["source_emitter"] = emitter.data.source
		frame["expected_basis"] = expected_basis(emitter,0)
	report.frames.append(frame)

func close_views(label: String, emitter, zoom_value: float) -> void:
	var center: Vector3 = emitter.transform.origin+Vector3(0.0,0.65,0.0)
	scene.camera.reset_at(center)
	scene.camera.zoom = zoom_value
	scene.camera._apply_pose()
	await shot(label+"-source-view",emitter)
	var first_position: Vector3 = scene.camera.global_position
	var distance: float = first_position.distance_to(center)
	var side: Vector3 = scene.camera.global_basis.x
	scene.camera.global_position = first_position+side*distance*0.55+Vector3(0.0,distance*0.12,0.0)
	scene.camera.look_at(center,Vector3.UP)
	await shot(label+"-oblique-view",emitter)

func audit_binding() -> Dictionary:
	var result := {"velocity":0,"axis_rotate_z":0,"direction_textures":0,"active_velocity_particles":0,
		"active_axis_particles":0,"max_direction_upload_error_cm":0.0,"emitters":[]}
	for emitter in driver._emitters:
		if emitter.source_alignment==0:
			continue
		var material: ShaderMaterial = emitter.draw.material_override
		var key: String = emitter.source_group+" / "+str(emitter.data.source)
		var mode: int = emitter.source_alignment
		check(int(material.get_shader_parameter("source_alignment"))==mode,key+": source mode binding")
		check(material.shader.code.contains("source_safe_unit") and material.shader.code.contains("camera_direction"),key+": native vertex basis present")
		var audit_mode: Variant=material.get_shader_parameter("audit_mode")
		check(audit_mode==null or audit_mode==0,key+": normal material mode (unset uses shader default)")
		var row := {"component":emitter.source_group,"emitter":emitter.data.source,"mode":mode,
			"active_particles":emitter.particles.size(),"shader":material.shader.resource_path,
			"fog":material.shader.code.contains("source_hf_vertex_result")}
		if mode==1:
			result.velocity+=1
			result.active_velocity_particles+=emitter.particles.size()
			var bound: Texture2D = material.get_shader_parameter("source_direction_data")
			check(bound!=null and bound==emitter.direction_texture,key+": direction texture identity")
			check(material.get_shader_parameter("lock_vertical")!=true,key+": velocity takes priority over axis lock")
			if bound!=null:
				result.direction_textures+=1
				var uploaded: Image = bound.get_image()
				check(uploaded.get_width()==emitter.capacity and uploaded.get_height()==1,key+": texture dimensions")
				check(uploaded.get_format()==Image.FORMAT_RGBAF,key+": RGBAF data format")
				row["texture_width"] = uploaded.get_width()
				for index in emitter.particles.size():
					var particle = emitter.particles[index]
					var expected: Vector3 = emitter.transform.basis*driver._gd(particle.pos+driver._orbit(particle)-particle.previous_render_pos)
					var texel := uploaded.get_pixel(index,0)
					var error := (Vector3(texel.r,texel.g,texel.b)-expected).length()
					result.max_direction_upload_error_cm=maxf(result.max_direction_upload_error_cm,error)
					check(error<=0.0001+expected.length()*0.000001,key+": current-minus-previous direction upload")
					check(absf(emitter.multi.get_instance_custom_data(index).r)<0.000001,key+": source velocity ignores spin")
		else:
			result.axis_rotate_z+=1
			result.active_axis_particles+=emitter.particles.size()
			var axis: Vector3 = material.get_shader_parameter("source_lock_axis")
			row["axis"] = vec(axis)
			check(axis.is_equal_approx(Vector3.UP),key+": source world Z maps to Godot Y")
			check(material.shader.code.contains("1.5707963705062866"),key+": native PI/2 bias")
			for index in emitter.particles.size():
				check(is_equal_approx(emitter.multi.get_instance_custom_data(index).r,-emitter.particles[index].rotation),key+": signed spin")
		result.emitters.append(row)
	check(result.velocity==33,"33 source velocity emitters")
	check(result.axis_rotate_z==1,"1 source locked-axis emitter")
	check(result.direction_textures==33,"33 direction textures bound")
	check(result.active_velocity_particles>0,"velocity particles visible during audit")
	check(result.active_axis_particles>0,"locked-axis particles visible during audit")
	return result

func audit_splash() -> void:
	var renderer: Node = scene.source_renderer
	var binding: Node = renderer.splash_binding
	var effect = renderer.distortion
	var splash_emitters := 0
	var sample = null
	for emitter in driver._emitters:
		if not emitter.splash:
			continue
		splash_emitters+=1
		if sample==null and not emitter.particles.is_empty(): sample=emitter
		var material: ShaderMaterial = emitter.draw.material_override
		check(material.shader.code.contains("float angle = INSTANCE_CUSTOM.r;"),"splash main consumes shared angle without second negation")
		var audit_mode: Variant=material.get_shader_parameter("audit_mode")
		check(audit_mode==null or audit_mode==0,"splash remains normal material (unset uses shader default)")
		for index in emitter.particles.size():
			check(is_equal_approx(emitter.multi.get_instance_custom_data(index).r,-emitter.particles[index].rotation),"splash custom angle equals negative source spin")
	check(splash_emitters==9,"9 source splash main emitters")
	check(binding.audit.source_emitters==9 and binding.audit.mesh_copied,"9 paired distortion emitters and copied source quad")
	check(is_equal_approx(float(effect.get("_angle_sign")),1.0),"distortion multiplier remains +1")
	check(int(effect.get("_audit_mode"))==0,"distortion normal mode")
	if sample!=null:
		scene.camera.reset_at(sample.transform.origin+Vector3(0.0,0.6,0.0))
		scene.camera.zoom=0.35
		scene.camera._apply_pose()
		await shot("splash-normal-paired")
	else:
		check(false,"active source splash available")
	var expected := PackedFloat32Array()
	for draw in binding._draws:
		if not draw.is_visible_in_tree(): continue
		var multi: MultiMesh = draw.multimesh
		var count: int = multi.visible_instance_count if multi.visible_instance_count>=0 else multi.instance_count
		var material: ShaderMaterial = draw.material_override
		var pivot: Vector2 = material.get_shader_parameter("pivot")
		for index in count:
			var transform: Transform3D = draw.global_transform*multi.get_instance_transform(index)
			var scale := Vector3(transform.basis.x.length(),transform.basis.y.length(),transform.basis.z.length())
			var custom := multi.get_instance_custom_data(index)
			var color := multi.get_instance_color(index)
			expected.append_array(PackedFloat32Array([transform.origin.x,transform.origin.y,transform.origin.z,custom.r,
				scale.x,scale.y,scale.z,color.a,pivot.x,pivot.y,custom.b,custom.a]))
	effect.request_validation_capture()
	var capture: Dictionary = {}
	for i in 60:
		await process_frame
		capture=effect.take_validation_capture()
		if not capture.is_empty(): break
	check(not capture.is_empty(),"distortion GPU validation readback returned")
	var sample_report := {"main_emitters":splash_emitters,"binding":binding.audit.duplicate(true),
		"expected_instance_floats":expected.size(),"sign":float(effect.get("_angle_sign"))}
	if not capture.is_empty():
		check(is_equal_approx(float(capture.angle_sign),1.0),"GPU frame captured angle_sign +1")
		var actual: PackedByteArray = capture.instances_rgba32f
		check(actual==expected.to_byte_array(),"GPU distortion instance snapshot exactly matches main draw transforms/custom data")
		sample_report["gpu_instance_bytes"] = actual.size()
		sample_report["gpu_particle_count"] = capture.particle_count
		sample_report["gpu_angle_sign"] = capture.angle_sign
		sample_report["identical_main_instance_payload"] = actual==expected.to_byte_array()
		FileAccess.open(out.path_join("splash-instances-rgba32f.bin"),FileAccess.WRITE).store_buffer(actual)
		FileAccess.open(out.path_join("splash-frame-rgba32f.bin"),FileAccess.WRITE).store_buffer(capture.frame_rgba32f)
	report.splash=sample_report

func run() -> void:
	if out.is_empty():
		push_error("Pass --alignment-report-dir=<absolute output folder>")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	scene.source_rendering=true
	scene.source_distortion=true
	scene.source_atmosphere=true
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	if scene.slug!="wuming": await scene._load_world("wuming")
	scene.tour_finished=true
	scene.set_process(false)
	scene.player.set_physics_process(false)
	scene.house_driver.set_physics_process(false)
	scene.camera.follow_target=null
	scene.camera.source_bounds.clear()
	# Inspection close-ups use normal materials but disable DOF explicitly.
	var dof_owner: Variant = scene.camera.get_meta("source_dof_owner") if scene.camera.has_meta("source_dof_owner") else null
	if is_instance_valid(dof_owner): dof_owner.set_process(false)
	scene.camera.attributes.dof_blur_near_enabled=false
	scene.camera.attributes.dof_blur_far_enabled=false
	for node in scene.world.get_children():
		if node.get_script()!=null and node.get_script().resource_path.ends_with("/original_particles.gd"):
			driver=node
	if driver==null:
		check(false,"original particle driver found")
	else:
		for i in 150: await process_frame
		driver.set_process(false)
		Engine.time_scale=0.0
		report.binding=audit_binding()
		var bonfire = null
		var torch = null
		for emitter in driver._emitters:
			if emitter.source_alignment==1 and bonfire==null and not emitter.particles.is_empty(): bonfire=emitter
			if emitter.source_alignment==2: torch=emitter
		if bonfire!=null: await close_views("bonfire",bonfire,0.24)
		if torch!=null: await close_views("locked-torch",torch,0.18)
		await audit_splash()
	Engine.time_scale=1.0
	FileAccess.open(out.path_join("alignment-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_ALIGNMENT_VERIFIED ",JSON.stringify({"velocity":report.binding.get("velocity",0),
		"axis":report.binding.get("axis_rotate_z",0),"frames":report.frames.size(),"failures":report.failures}))
	scene.source_renderer.shutdown()
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
