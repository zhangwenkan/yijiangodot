extends SceneTree
var scene: Node3D
var out:=""
var report:={"failures":[],"maps":[],"frames":[]}
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bird-material-report-dir="): out=arg.trim_prefix("--bird-material-report-dir=")
	call_deferred("run")
func settle(count: int=4) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func capture(label: String) -> void:
	await settle()
	var image: Image=root.get_texture().get_image()
	image.save_png(out.path_join(label+".png"))
	report.frames.append({"name":label,"width":image.get_width(),"height":image.get_height()})
func check(value: bool, message: String) -> void:
	if not value: report.failures.append(message)
func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		await settle(20)
		var adapter: Variant=scene.source_renderer.get("birds")
		if adapter==null:
			report.failures.append("Install source bird adapter in original_source_renderer.")
			continue
		var entry: Dictionary={"map":slug,"install":adapter.report.duplicate(true),"checked_sprites":0,"checked_frames":0,"checks":[]}
		check(adapter.report.get("bound",-1)==(20 if slug=="youxian" else 0),"Unexpected bird material count "+slug)
		check(adapter.report.get("unsupported",[]).is_empty(),"Unsupported bird binding "+slug)
		var old_process: int=scene.process_mode
		var old_time: float=Engine.time_scale
		var old_camera: Transform3D=scene.camera.global_transform
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		var dof_effect: CompositorEffect=scene.source_renderer.depth_of_field.get("effect")
		var dof_enabled:=dof_effect.enabled if dof_effect!=null else false
		if dof_effect!=null: dof_effect.enabled=false
		for binding in adapter.bindings:
			var sprite: AnimatedSprite3D=binding.sprite
			var material: ShaderMaterial=binding.material
			var before: Dictionary=adapter._state(sprite)
			var native_entry: Dictionary=binding.entry.duplicate(true)
			var code: String=material.shader.code
			check(bool(material.get_meta("source_bird_material",false)),"Missing bird metadata")
			check(code.contains("source_sh9_evaluate"),"Bird SH9 absent")
			check(code.contains("source_height_fog"),"Bird height fog absent")
			check(code.contains("source_local_cone_correction"),"Bird local cone absent")
			check(code.contains("source_lf_at"),"Bird light function absent")
			check(is_equal_approx(float(material.get_shader_parameter("source_ambient_metallic")),0.7),"Bird metallic not source0.7")
			check(not bool(material.get_shader_parameter("source_ambient_mask_dither")),"Bird incorrectly dithered")
			for animation in sprite.sprite_frames.get_animation_names():
				var frame_count:=sprite.sprite_frames.get_frame_count(animation)
				for frame in frame_count:
					sprite.set_animation(animation)
					sprite.set_frame_and_progress(frame,0.0)
					var tex: Texture2D=sprite.sprite_frames.get_frame_texture(animation,frame)
					var atlas: Texture2D=tex.atlas if tex is AtlasTexture else tex
					check(material.get_shader_parameter("source_ambient_atlas")==atlas,"Bird atlas desync "+str(animation)+":"+str(frame))
					check(sprite.material_override==material,"Bird material replaced during frame update")
					entry.checked_frames+=1
			sprite.set_animation(before.animation)
			sprite.set_frame_and_progress(before.frame,before.progress)
			check(adapter._state(sprite)==before,"Bird presentation state changed after frame audit")
			check(binding.entry==native_entry,"Bird behavior entry changed during material audit")
			entry.checked_sprites+=1
		if not adapter.bindings.is_empty():
			var binding: Dictionary=adapter.bindings[0]
			var sprite: AnimatedSprite3D=binding.sprite
			var before: Dictionary=adapter._state(sprite)
			scene.camera.global_position=sprite.global_position+Vector3.UP*0.12+scene.camera.global_basis.z*3.0
			for animation in ["idle_left","idle_right","run_left","run_right"]:
				sprite.set_animation(animation)
				sprite.set_frame_and_progress(0,0.0)
				await capture("bird-"+animation+"-source-material")
			sprite.set_animation(before.animation)
			sprite.set_frame_and_progress(before.frame,before.progress)
		if dof_effect!=null: dof_effect.enabled=dof_enabled
		scene.camera.global_transform=old_camera
		scene.process_mode=old_process
		Engine.time_scale=old_time
		entry["inspection_hdr_dof_disabled"]=true
		report.maps.append(entry)
	FileAccess.open(out.path_join("bird-material-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_BIRD_MATERIAL_VALIDATION ",JSON.stringify({"failures":report.failures,"frames":report.frames.size()}))
	scene.queue_free()
	await settle(4)
	quit(0 if report.failures.is_empty()else 1)

