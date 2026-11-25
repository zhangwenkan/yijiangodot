extends SceneTree
var out:=""
var scene: Node3D
var report:={"maps":[],"frames":[],"failures":[]}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ambient-material-report-dir="): out=arg.trim_prefix("--ambient-material-report-dir=")
	call_deferred("run")

func check(ok: bool,label: String) -> void:
	if not ok: report.failures.append(label)

func shot(label: String) -> void:
	for i in 10: await process_frame
	await RenderingServer.frame_post_draw
	var path:=out.path_join(scene.slug+"-"+label+".png")
	check(root.get_texture().get_image().save_png(path)==OK,"save "+path)
	report.frames.append({"file":path,"normal_materials":true,"camera":str(scene.camera.global_transform)})

func inspect(adapter: RefCounted) -> Dictionary:
	var counts:={"bound":0,"lit":0,"unlit":0,"dither":0,"nondither":0,"atlas":0,"sh_lit":0,"fog":0,"humans":0}
	var first_monkey: AnimatedSprite3D
	if scene.has_meta("audit_monkey"): scene.remove_meta("audit_monkey")
	if scene.has_meta("audit_amina"): scene.remove_meta("audit_amina")
	for binding in adapter.bindings:
		var sprite: AnimatedSprite3D=binding.sprite
		var material: ShaderMaterial=binding.material
		var policy: Dictionary=binding.policy
		var key: String=binding.key
		check(sprite.material_override==material,"same material object: "+key)
		var tex: Texture2D=sprite.sprite_frames.get_frame_texture(sprite.animation,sprite.frame)
		var atlas: Texture2D=tex.atlas if tex is AtlasTexture else tex
		check(material.get_shader_parameter("source_ambient_atlas")==atlas,"current atlas binding: "+key)
		counts.atlas+=1
		counts.bound+=1
		if bool(binding.definition.get("is_human",false)): counts.humans+=1
		check(material.get_shader_parameter("source_ambient_fixed_y")== (sprite.billboard==BaseMaterial3D.BILLBOARD_FIXED_Y),"billboard preserved: "+key)
		if bool(policy.lit):
			counts.lit+=1
			check(is_equal_approx(float(material.get_shader_parameter("source_ambient_metallic")),0.699999988079071),"source metallic: "+key)
			check(material.get_shader_parameter("source_ambient_mask_dither")==bool(policy.mask_dither),"source MaskDither: "+key)
			if bool(policy.mask_dither): counts.dither+=1
			else: counts.nondither+=1
			if material.shader.code.contains("source_sh9_coefficients"): counts.sh_lit+=1
			check(material.shader.code.contains("source_sh9_coefficients"),"lit participates in source SH: "+key)
		else:
			counts.unlit+=1
			check(material.get_meta("source_unshaded",false)==true,"unlit metadata: "+key)
			check(not material.shader.code.contains("source_sh9_coefficients"),"unlit excluded from SH: "+key)
		if material.shader.code.contains("FOG = source_height_fog_to_godot"):
			counts.fog+=1
		check(material.shader.code.contains("FOG = source_height_fog_to_godot"),"source fog injected: "+key)
		# The existing Sprite owns geometry, frames and pivots. Exercise callbacks,
		# restore exact frame/progress, and verify adapter never swaps SpriteFrames.
		var old_frames: SpriteFrames=sprite.sprite_frames
		var old_frame: int=sprite.frame
		var old_progress: float=sprite.frame_progress
		var old_transform: Transform3D=sprite.transform
		var old_billboard: int=sprite.billboard
		var old_size: float=sprite.pixel_size
		if old_frames.get_frame_count(sprite.animation)>1:
			sprite.set_frame_and_progress((old_frame+1)%old_frames.get_frame_count(sprite.animation),0.0)
			var next: Texture2D=old_frames.get_frame_texture(sprite.animation,sprite.frame)
			check(material.get_shader_parameter("source_ambient_atlas")== (next.atlas if next is AtlasTexture else next),"frame change updates atlas: "+key)
			sprite.set_frame_and_progress(old_frame,old_progress)
		check(sprite.sprite_frames==old_frames and sprite.transform==old_transform and sprite.billboard==old_billboard and is_equal_approx(sprite.pixel_size,old_size),"frame restore preserves sprite: "+key)
		if first_monkey==null and str(binding.definition.flipbook).contains("/HouZi/"):
			first_monkey=sprite
		if str(binding.definition.get("display_name",""))=="阿美娜": scene.set_meta("audit_amina",sprite)
	if first_monkey!=null: scene.set_meta("audit_monkey",first_monkey)
	return counts

func inspect_humans(adapter: RefCounted) -> Array:
	var humans: Array[Dictionary]=[]
	for binding in adapter.bindings:
		if not bool(binding.definition.get("is_human",false)): continue
		var sprite: AnimatedSprite3D=binding.sprite
		var holder: Node3D=sprite.get_parent()
		humans.append({"binding":binding,"holder":holder,"settled":holder.global_position,"frames":{}})
	if humans.is_empty(): return []
	for tick in 120:
		await physics_frame
		for human in humans:
			var binding: Dictionary=human.binding
			var sprite: AnimatedSprite3D=binding.sprite
			var holder: Node3D=human.holder
			var owner_node: Node=holder.get_parent()
			var manifest: Dictionary=owner_node.get("manifest")
			var src: Dictionary=manifest.sprites[manifest.flipbooks[str(sprite.animation)].frames[sprite.frame].sprite]
			var unit: float=.01/float(src.ppu)
			var desired:=Vector3((float(src.region[2])*.5-float(src.pivot[0]))*unit,(float(src.pivot[1])-float(src.region[3])*.5)*unit,0.0)
			var atlas:=sprite.sprite_frames.get_frame_texture(sprite.animation,sprite.frame) as AtlasTexture
			check(holder.global_position.distance_to(human.settled)<.00001,"human stays at settled position: "+binding.key)
			check(sprite.position.distance_to(desired)<.00001,"human original per-frame pivot: "+binding.key)
			check(atlas!=null and atlas.region==Rect2(float(src.region[0]),float(src.region[1]),float(src.region[2]),float(src.region[3])),"human original atlas region: "+binding.key)
			check(atlas!=null and binding.material.get_shader_parameter("source_ambient_atlas")==atlas.atlas,"human current shader atlas: "+binding.key)
			human.frames[str(sprite.frame)]=true
	var rows: Array=[]
	for human in humans:
		var binding: Dictionary=human.binding
		var holder: Node3D=human.holder
		var p: Vector3=holder.global_position
		var ray:=PhysicsRayQueryParameters3D.create(p+Vector3.UP*.5,p-Vector3.UP*2.0,4)
		var hit: Dictionary=holder.get_world_3d().direct_space_state.intersect_ray(ray)
		var matrix: Array=binding.definition.matrix_ue
		var authored:=Vector3(float(matrix[0][3]),float(matrix[2][3]),float(matrix[1][3]))*.01
		check(Vector2(p.x,p.z).distance_to(Vector2(authored.x,authored.z))<.00001,"human authored horizontal position: "+binding.key)
		check(human.frames.size()>1,"human idle animates: "+binding.key)
		var row:={"key":binding.key,"name":binding.definition.get("display_name",""),"position":str(p),"authored":str(authored),"unique_frames":human.frames.size(),"support_found":not hit.is_empty(),"support_is_existing_settle_adapter":true}
		if not hit.is_empty():
			row["foot_origin_gap_m"]=p.y-float(hit.position.y)
			row["support_normal"]=str(hit.normal)
			row["support_collider"]=str(hit.collider.get_path())
		rows.append(row)
	return rows

func run() -> void:
	if out.is_empty():
		push_error("Supply --ambient-material-report-dir=<directory>.")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		Engine.time_scale=1.0
		scene.process_mode=Node.PROCESS_MODE_INHERIT
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		for i in 30: await process_frame
		var adapter: RefCounted=scene.source_renderer.get("ambient")
		check(adapter!=null,slug+": ambient adapter installed")
		if adapter==null: continue
		var human_rows: Array=await inspect_humans(adapter)
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		Engine.time_scale=0.0
		var entry:={"map":slug,"counts":inspect(adapter),"adapter_report":adapter.report.duplicate(true),"humans":human_rows}
		var expected_humans:=0
		var expected_extra_animals:=0
		if FileAccess.file_exists("res://assets/source-npcs/manifest.json"):
			var human_manifest: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/source-npcs/manifest.json"))
			expected_humans=human_manifest.get("maps",{}).get(slug,[]).size()
		if FileAccess.file_exists("res://assets/source-animals/manifest.json"):
			var animal_manifest: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/source-animals/manifest.json"))
			expected_extra_animals=animal_manifest.get("maps",{}).get(slug,[]).size()
		check(entry.counts.humans==expected_humans,slug+": all installed source humans bound")
		check(entry.counts.bound==(72 if slug=="wuming" else 67)+expected_humans+expected_extra_animals,slug+": complete material bindings")
		check(entry.counts.lit==(48 if slug=="wuming" else 61)+expected_humans+expected_extra_animals,slug+": correct lit count")
		check(entry.counts.unlit==(24 if slug=="wuming" else 6),slug+": correct unlit count")
		check(adapter.report.unsupported.is_empty(),slug+": no unsupported source materials")
		await shot("source-harbor")
		var old_camera: Transform3D=scene.camera.global_transform
		var old_zoom: float=scene.camera.zoom
		var old_tracked: Vector3=scene.camera.tracked
		var old_follow: Node3D=scene.camera.follow_target
		var old_bounds: Array[Dictionary]=scene.camera.source_bounds.duplicate(true)
		var old_axis_locked: Array=scene.camera.source_axis_locked.duplicate()
		var old_axis_values: Vector3=scene.camera.source_axis_values
		var old_bounds_report: Dictionary=scene.camera.source_bounds_report.duplicate(true)
		for subject in [{"meta":"audit_monkey","label":"monkey"},{"meta":"audit_amina","label":"amina"}]:
			if not scene.has_meta(subject.meta): continue
			var monkey: AnimatedSprite3D=scene.get_meta(subject.meta)
			var attributes: CameraAttributesPractical=scene.camera.attributes
			var near_enabled:=attributes.dof_blur_near_enabled
			var far_enabled:=attributes.dof_blur_far_enabled
			var dof_effect: CompositorEffect=scene.source_renderer.depth_of_field.get("effect")
			var effect_enabled:=dof_effect.enabled if dof_effect!=null else false
			attributes.dof_blur_near_enabled=false
			attributes.dof_blur_far_enabled=false
			if dof_effect!=null: dof_effect.enabled=false
			scene.camera.source_bounds.clear()
			scene.camera.follow_target=null
			scene.camera.reset_at(monkey.global_position+Vector3.UP*0.5)
			scene.camera.zoom=.28
			scene.camera._apply_pose()
			await shot(str(subject.label)+"-inspection-dof-disabled")
			attributes.dof_blur_near_enabled=near_enabled
			attributes.dof_blur_far_enabled=far_enabled
			if dof_effect!=null: dof_effect.enabled=effect_enabled
			scene.camera.zoom=old_zoom
			scene.camera.tracked=old_tracked
			scene.camera.follow_target=old_follow
			scene.camera.source_bounds=old_bounds
			scene.camera.source_axis_locked=old_axis_locked
			scene.camera.source_axis_values=old_axis_values
			scene.camera.source_bounds_report=old_bounds_report
			scene.camera.global_transform=old_camera
			entry[str(subject.label)+"_closeup_dof_disabled"]=true
		report.maps.append(entry)
	Engine.time_scale=1.0
	FileAccess.open(out.path_join("ambient-material-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_AMBIENT_MATERIAL_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"frames":report.frames.size(),"failures":report.failures}))
	scene.queue_free()
	for i in 3: await process_frame
	quit(0 if report.failures.is_empty() else 1)
