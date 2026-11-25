extends SceneTree
var out := ""
var report := {"water":[],"variants":[]}
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--water-report-dir="):
			out=arg.trim_prefix("--water-report-dir=")
	call_deferred("run")
func run() -> void:
	var scene: Node3D=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading:
		await process_frame
	scene.tour_finished=true
	scene.player.set_review_motion(Vector2.ZERO)
	var waters: Array[ShaderMaterial]=[]
	for mesh in scene.world.find_children("*","MeshInstance3D",true,false):
		if not mesh.has_meta("source_water_parameters"):
			continue
		var arrays: Array=mesh.mesh.surface_get_arrays(0)
		var material: ShaderMaterial=mesh.material_override
		waters.append(material)
		var tangents: Variant=arrays[Mesh.ARRAY_TANGENT]
		report.water.append({"source":mesh.get_meta("source_name",""),"vertices":arrays[Mesh.ARRAY_VERTEX].size(),"tangent_floats":0 if tangents==null else tangents.size()})
	var fogtex: Texture2D=load("res://assets/environment/textures/T_TilingNoise03_M_native.dds")
	var fogimage: Image=fogtex.get_image()
	report.fog_texture={"has_mipmaps":fogimage.has_mipmaps(),"mipmaps":fogimage.get_mipmap_count(),"format":fogimage.get_format()}
	var env: Environment=scene.world.find_children("*","WorldEnvironment",true,false)[0].environment
	var sky_mat: ShaderMaterial=env.sky.sky_material
	await capture("baseline")
	var attrs: CameraAttributesPractical=scene.camera.attributes
	var old_near:=attrs.dof_blur_near_enabled
	var old_far:=attrs.dof_blur_far_enabled
	attrs.dof_blur_near_enabled=false
	attrs.dof_blur_far_enabled=false
	await capture("baseline-no-dof")
	for value in [6,5,2]:
		for material in waters:material.set_shader_parameter("audit_view",value)
		await capture("water-audit-"+str(value))
	for material in waters:material.set_shader_parameter("audit_view",0)
	attrs.dof_blur_near_enabled=old_near
	attrs.dof_blur_far_enabled=old_far
	sky_mat.set_shader_parameter("capture_energy",1.0)
	sky_mat.set_shader_parameter("capture_tint",Vector3.ONE)
	await capture("prefab-capture-unscaled")
	sky_mat.set_shader_parameter("capture_energy",0.10)
	sky_mat.set_shader_parameter("capture_tint",Vector3(1.0,.82,.68))
	# Diagnostic only: current-scene environment reflection, no diffuse ambient.
	var probe:=ReflectionProbe.new()
	probe.name="DiagnosticCurrentSceneCapture"
	probe.size=Vector3(1400,1400,1400)
	probe.max_distance=700.0
	probe.box_projection=false
	probe.ambient_mode=ReflectionProbe.AMBIENT_DISABLED
	probe.update_mode=ReflectionProbe.UPDATE_ONCE
	probe.intensity=1.0
	probe.enable_shadows=true
	scene.world.add_child(probe)
	probe.global_position=Vector3(0,10,0)
	for light in scene.environment_driver._data.light_components:
		if str(light["class"]).ends_with("SkyLightComponent"):
			probe.global_transform=scene.environment_driver._ue_transform(light.matrix_ue)
			probe.intensity=float(light.properties.get("Intensity",1.0))
	await capture("scene-reflection-capture")
	attrs.dof_blur_near_enabled=false
	attrs.dof_blur_far_enabled=false
	await capture("scene-reflection-no-dof")
	report.probe={"origin":[probe.position.x,probe.position.y,probe.position.z],"intensity":probe.intensity,"status":"diagnostic renderer adaptation, not native capture equivalence"}
	var f:=FileAccess.open(out.path_join("water-render-audit.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t"))
	print("WATER_RENDER_AUDIT ",JSON.stringify(report))
	quit()
func capture(label: String) -> void:
	for i in 40:await process_frame
	await RenderingServer.frame_post_draw
	var path:=out.path_join(label+".png")
	root.get_texture().get_image().save_png(path)
	report.variants.append({"label":label,"path":path,"fps":Engine.get_frames_per_second()})
	print("WATER_AUDIT_CAPTURE ",path)
