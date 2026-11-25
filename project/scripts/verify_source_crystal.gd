extends SceneTree
var out := ""
var mip_manifest := ""
var scene: Node3D
var report := {"materials":[],"textures":[],"views":[],"failures":[]}
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--material-report-dir="): out=arg.trim_prefix("--material-report-dir=")
		elif arg.begins_with("--mip-manifest="): mip_manifest=arg.trim_prefix("--mip-manifest=")
	call_deferred("run")
func shot(label: String) -> void:
	for i in 12: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(label+".png"))
func run() -> void:
	scene=load("res://worlds.tscn").instantiate()
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
	var policies: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/environment/source-surface-materials.json"))
	var expected_mips: Dictionary={}
	for row in JSON.parse_string(FileAccess.get_file_as_string(mip_manifest)).textures: expected_mips[row.resource]=row
	var materials: Dictionary={}
	var textures: Dictionary={}
	var representatives: Dictionary={}
	var components:=0
	for node in scene.world.find_children("*","MeshInstance3D",true,false):
		if node.mesh==null: continue
		for surface in node.mesh.get_surface_count():
			var mat=node.get_active_material(surface)
			if not mat is ShaderMaterial or mat.get_meta("source_surface_family","")!="M_BetterCrystal_8Samples": continue
			components+=1
			if materials.has(mat.resource_name): continue
			materials[mat.resource_name]=true
			var policy: Dictionary=policies[mat.resource_name]
			var constants: PackedVector4Array=mat.get_shader_parameter("source_constants")
			var max_error:=0.0
			for i in constants.size():
				for channel in 4: max_error=maxf(max_error,absf(constants[i][channel]-float(policy.source_constants[i][channel])))
			var material_record: Dictionary={"material":mat.resource_name,"source":policy.source_material_key,"constants":constants.size(),"constant_max_error":max_error,"desaturation":policy.source_desaturation,"node":str(node.name)}
			report.materials.append(material_record)
			if constants.size()!=39 or max_error>0.0001: report.failures.append(material_record)
			var signature:=str(policy.source_desaturation)
			for param in policy.textures:
				var config: Dictionary=policy.textures[param]
				signature+=str(config.srgb)+str(config.repeat)
				var texture: Texture2D=mat.get_shader_parameter(param)
				var path: String=config.path
				if textures.has(path): continue
				textures[path]=true
				var im: Image=texture.get_image()
				var expected: Dictionary=expected_mips[path]
				var ok:=im.get_mipmap_count()+1==int(expected.levels) and im.get_width()==int(expected.width) and im.get_height()==int(expected.height)
				if expected.format=="PF_BC5": ok=ok and im.get_format()==Image.FORMAT_RGTC_RG
				report.textures.append({"path":path,"width":im.get_width(),"height":im.get_height(),"levels":im.get_mipmap_count()+1,"format":im.get_format(),"ok":ok})
				if not ok: report.failures.append(path)
			if not representatives.has(signature): representatives[signature]={"node":node,"record":material_record}
	report["components"]=components
	report["unique_materials"]=materials.size()
	if components!=140 or materials.size()!=70 or textures.size()!=58: report.failures.append("Binding counts differ from source")
	await shot("default-view")
	var index:=0
	for entry in representatives.values():
		var node: MeshInstance3D=entry.node
		var center: Vector3=node.global_transform*node.get_aabb().get_center()
		scene.camera.zoom=0.25
		scene.camera.reset_at(center)
		scene.camera._apply_pose()
		var initial: Transform3D=scene.camera.global_transform
		await shot("crystal-%d-front"%index)
		scene.camera.global_position+=scene.camera.global_basis.x*2.0
		scene.camera.look_at(center,Vector3.UP)
		await shot("crystal-%d-oblique"%index)
		report.views.append({"index":index,"material":entry.record.material,"node":str(node.name),"center":[center.x,center.y,center.z],"view_changed":initial!=scene.camera.global_transform})
		index+=1
	FileAccess.open(out.path_join("crystal-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("CRYSTAL_VALIDATION ",JSON.stringify({"components":components,"materials":materials.size(),"textures":textures.size(),"views":index,"failures":report.failures}))
	quit(0 if report.failures.is_empty() else 1)
