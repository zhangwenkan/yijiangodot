extends SceneTree
var out := ""
var report := {"materials":[],"textures":[],"failures":[],"butterflies":[]}
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--material-report-dir="): out=arg.trim_prefix("--material-report-dir=")
	call_deferred("run")
func shot(label: String) -> void:
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(label+".png"))
func run() -> void:
	var scene: Node3D=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	scene.tour_finished=true
	scene.set_process(false)
	scene.player.set_physics_process(false)
	scene.house_driver.set_process(false)
	scene.camera.follow_target=null
	scene.camera.source_bounds.clear()
	scene.camera.attributes.dof_blur_near_enabled=false
	scene.camera.attributes.dof_blur_far_enabled=false
	var anim: Node
	for n in scene.world.get_children():
		if n.get_script()!=null and n.get_script().resource_path.ends_with("original_animation.gd"): anim=n
	assert(anim!=null)
	var seen: Dictionary={}
	var slab: MeshInstance3D
	for node in scene.world.find_children("*","MeshInstance3D",true,false):
		if node.mesh==null: continue
		for surface in node.mesh.get_surface_count():
			var mat=node.get_active_material(surface)
			if mat is ShaderMaterial and mat.has_meta("source_surface_family"):
				var family: String=mat.get_meta("source_surface_family")
				if family not in ["M_Simple_Cutout","M_JHCharacter_Unlit_Base"]: continue
				report.materials.append({"node":str(node.name),"source":str(node.get_meta("source_name","")),"material":mat.resource_name,"family":family,"uv_offset":str(mat.get_shader_parameter("uv_offset")),"uv_scale":str(mat.get_shader_parameter("uv_scale")),"source_tint":str(mat.get_shader_parameter("source_diffuse_tint")),"alpha_clip":mat.get_shader_parameter("alpha_clip")})
				if family=="M_JHCharacter_Unlit_Base": slab=node
				for param in ["source_diffuse_texture","source_cutout_texture"]:
					var texture=mat.get_shader_parameter(param)
					if texture is Texture2D and not seen.has(texture.resource_path):
						seen[texture.resource_path]=true
						var im: Image=texture.get_image()
						var expected=7 if texture.resource_path.contains("DummySprite") else 9
						var ok=im.get_mipmap_count()==expected
						report.textures.append({"path":texture.resource_path,"size":str(im.get_size()),"mips":im.get_mipmap_count()+1,"ok":ok})
						if not ok: report.failures.append(texture.resource_path)
		if str(node.name)=="S_5971_StaticMeshComponent0_0_0":
			var arrays=node.mesh.surface_get_arrays(0)
			var positions: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var tangents: PackedFloat32Array=arrays[Mesh.ARRAY_TANGENT]
			var uv: PackedVector2Array=arrays[Mesh.ARRAY_TEX_UV]
			var vals: Array=[]
			for i in positions.size(): vals.append({"p":[positions[i].x,positions[i].y,positions[i].z],"uv":[uv[i].x,uv[i].y],"t":Array(tangents.slice(i*4,i*4+4))})
			var file:=FileAccess.open(out.path_join("crystal-import-tangents.json"),FileAccess.WRITE)
			file.store_string(JSON.stringify({"vertices":positions.size(),"tangent_floats":tangents.size(),"values":vals}))
	await shot("default-view")
	for index in mini(2,anim._butterflies.size()):
		var butterfly: Dictionary=anim._butterflies[index]
		var body: Node3D=butterfly.parts[0].node
		scene.camera.reset_at(body.global_position)
		scene.camera.zoom=0.12
		scene.camera._apply_pose()
		var before: Transform3D=butterfly.parts[1].node.global_transform
		await shot("butterfly-%d-a"%index)
		await create_timer(0.6).timeout
		await shot("butterfly-%d-b"%index)
		var after: Transform3D=butterfly.parts[1].node.global_transform
		report.butterflies.append({"index":index,"parts":butterfly.parts.size(),"moved":before!=after,"source":str(body.get_meta("source_name",""))})
		if before==after: report.failures.append("Butterfly did not move")
	if slab!=null:
		scene.camera.reset_at(slab.global_transform * slab.get_aabb().get_center())
		scene.camera.zoom=0.18
		scene.camera._apply_pose()
		await shot("source-small-slab")
	report["map"]=scene.slug
	report["butterfly_count"]=anim._butterflies.size()
	var f:=FileAccess.open(out.path_join("remaining-validation.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t"))
	quit(0 if report.failures.is_empty() else 1)
