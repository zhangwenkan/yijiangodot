extends SceneTree
## Parent-only GPU integration/visual diagnostic. No meshes are produced here.
var out: String=""
var scene: Node
var report: Dictionary={"failures":[],"frames":[],"textures":[],"scope":"One original leaf emitter/material; not full Cascade or complete scene fidelity."}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--leaf-report-dir="): out=arg.trim_prefix("--leaf-report-dir=")
	call_deferred("run")

func check(value: bool,message: String) -> void:
	if not value: report.failures.append(message)

func mesh_hash(mesh: Mesh) -> String:
	var context:=HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for surface in mesh.get_surface_count(): context.update(var_to_bytes(mesh.surface_get_arrays(surface)))
	return context.finish().hex_encode()

func capture(label: String) -> void:
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	var image: Image=root.get_texture().get_image()
	image.save_png(out.path_join(label+".png"))
	report.frames.append({"label":label,"width":image.get_width(),"height":image.get_height()})
	if label=="leaf-isolated-no-atmosphere-bloom":
		var darkest:=1.0
		var brightest:=0.0
		for y in range(0,image.get_height(),8):
			for x in range(0,image.get_width(),8):
				var color:=image.get_pixel(x,y)
				var value:=(color.r+color.g+color.b)/3.0
				darkest=minf(darkest,value)
				brightest=maxf(brightest,value)
		check(brightest-darkest>0.05,"Empty or uniform inspection image: "+label)

func run() -> void:
	if out.is_empty(): quit(2);return
	DirAccess.make_dir_recursive_absolute(out)
	root.size=Vector2i(1280,720)
	scene=load("res://worlds.tscn").instantiate();root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	if scene.slug!="youxian":
		scene._load_world("youxian")
		while scene.loading: await process_frame
	scene.tour_finished=true
	for i in 180: await process_frame
	check(is_instance_valid(scene.source_renderer),"Source renderer absent")
	var leaf: RefCounted=scene.source_renderer.leaf
	report.binding=leaf.report
	check(leaf.report.get("bound_emitters",0)==1,"Expected exactly one original leaf emitter")
	var target: MultiMeshInstance3D
	for node in scene.world.find_children("*","MultiMeshInstance3D",true,false):
		if str(node.get_meta("source_component",""))==leaf.COMPONENT and str(node.get_meta("source_emitter",""))==leaf.EMITTER: target=node
	if target==null:
		check(false,"Original leaf draw missing");await save();return
	var material: ShaderMaterial=target.material_override
	var original_mesh: Mesh=target.multimesh.mesh
	var original_hash:=mesh_hash(original_mesh)
	report.mesh_sha256=original_hash
	report.active_before=target.multimesh.visible_instance_count
	for key in ["base","normal","roughness","ao","metallic"]:
		var texture: Texture2D=material.get_shader_parameter("source_leaf_"+key)
		check(texture!=null,"Missing leaf texture "+key)
		if texture!=null: report.textures.append({"channel":key,"path":texture.resource_path,"width":texture.get_width(),"height":texture.get_height()})
	report.lightfunction_count=material.get_shader_parameter("source_lf_count")
	report.cone_count=material.get_shader_parameter("source_local_cone_count")
	report.sh9_enabled=material.get_shader_parameter("source_sh9_enabled")
	check(material.shader.code.contains("source_leaf_subsurface * source_sh9_evaluate"),"Rear sky contribution missing")
	check(material.shader.code.contains("leaf_wrap"),"Source direct foliage transmission missing")
	check(material.shader.code.contains("source_height_fog"),"Height fog adaptation missing")
	await capture("youxian-native-view")
	scene.set_process(false)
	var old_camera: Transform3D=scene.camera.global_transform
	var dof_effect: CompositorEffect=scene.source_renderer.depth_of_field.effect
	var dof_enabled:=dof_effect.enabled
	dof_effect.enabled=false
	report.inspection_hdr_dof_disabled=true
	if target.multimesh.visible_instance_count>0:
		var center: Vector3=target.global_transform*target.multimesh.get_instance_transform(0).origin
		scene.camera.global_position=center+scene.camera.global_basis.z*5.0
		report.inspection_center=str(center)
		report.inspection_camera=str(scene.camera.global_transform)
		await capture("leaf-material-close-t0")
		var positions_before: PackedVector3Array=PackedVector3Array()
		for i in mini(target.multimesh.visible_instance_count,32):positions_before.append(target.multimesh.get_instance_transform(i).origin)
		for i in 90:await process_frame
		report.active_after=target.multimesh.visible_instance_count
		var moved:=0
		for i in mini(positions_before.size(),target.multimesh.visible_instance_count):
			if target.multimesh.get_instance_transform(i).origin.distance_to(positions_before[i])>0.00001:moved+=1
		report.observed_moving_instances=moved
		check(moved>0,"No leaf movement observed")
		await capture("leaf-material-close-t1")
		# The original emitter can be behind rock from this close camera. Inspect
		# its existing instances without foreground geometry, then restore it all.
		var saved_visibility: Array[Dictionary]=[]
		for node in scene.find_children("*","GeometryInstance3D",true,false):
			if node!=target:
				saved_visibility.append({"node":node,"visible":node.visible})
				node.visible=false
		var old_mode: int=scene.process_mode
		scene.process_mode=Node.PROCESS_MODE_DISABLED
		var leaf_transform: Transform3D=target.global_transform*target.multimesh.get_instance_transform(0)
		var leaf_bounds: AABB=leaf_transform*original_mesh.get_aabb()
		center=leaf_bounds.get_center()
		var distance:=maxf(0.4,leaf_bounds.size.length()*2.5)
		scene.camera.global_position=center+scene.camera.global_basis.z*distance
		report.isolated_bounds=str(leaf_bounds)
		report.isolated_camera_distance=distance
		report.isolation_scope="Only diagnostic visibility changed; existing mesh, instances, transforms and source material retained."
		await capture("leaf-isolated-native-material")
		# With all opaque scenery hidden, original bright sky and depth-based
		# postprocess dominate the isolated image. Disable only postprocess for
		# a separate material inspection; the full-scene captures keep them on.
		var atmosphere_enabled: bool=scene.source_renderer.atmosphere.effect.enabled
		var bloom_enabled: bool=scene.source_renderer.bloom.enabled
		scene.source_renderer.atmosphere.effect.enabled=false
		scene.source_renderer.bloom.enabled=false
		await capture("leaf-isolated-no-atmosphere-bloom")
		scene.source_renderer.atmosphere.effect.enabled=atmosphere_enabled
		scene.source_renderer.bloom.enabled=bloom_enabled
		scene.process_mode=old_mode
		for saved in saved_visibility:saved.node.visible=saved.visible
	else: check(false,"No visible original leaf particles after warmup")
	dof_effect.enabled=dof_enabled
	scene.camera.global_transform=old_camera
	check(target.multimesh.mesh==original_mesh and mesh_hash(original_mesh)==original_hash,"Imported leaf geometry changed")
	report.renderer_restore=scene.source_renderer.shutdown()
	check(report.renderer_restore.get("leaf",{}).get("restored_emitters",0)==1,"Leaf restore did not release one material override")
	check(report.renderer_restore.get("leaf",{}).get("errors",[]).is_empty(),"Leaf restore errors")
	check(target.multimesh.mesh==original_mesh and mesh_hash(original_mesh)==original_hash,"Geometry changed after restore")
	await save()

func save() -> void:
	FileAccess.open(out.path_join("leaf-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_LEAF_REVIEW ",JSON.stringify({"failures":report.failures,"frames":report.frames.size()}))
	if is_instance_valid(scene):scene.queue_free()
	for i in 8:await process_frame
	quit(0 if report.failures.is_empty() else 1)
