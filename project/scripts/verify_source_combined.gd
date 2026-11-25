extends SceneTree
## Real-clock integration check of both maps, source effects and room transitions.
var out := ""
var scene: Node3D
var report := {"maps":[], "failures":[], "capture_clock":"real wall clock; no fixed-fps or movie mode"}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--combined-report-dir="): out=arg.trim_prefix("--combined-report-dir=")
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition: report.failures.append(scene.slug+": "+label)

func shot(label: String) -> void:
	for i in 10: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(scene.slug+"-"+label+".png"))

func driver_named(suffix: String) -> Node:
	for node in scene.world.get_children():
		if node.get_script()!=null and node.get_script().resource_path.ends_with(suffix): return node
	return null

func check_transparent_sky(enabled: bool, label: String) -> void:
	var reflection: Node=scene.source_renderer.get("reflection") as Node
	check(is_instance_valid(reflection),label+" source reflection installed")
	if is_instance_valid(reflection):
		check(reflection.report.get("status","")=="installed",label+" source reflection status")
		check(reflection.report.get("mode",-1)==2,label+" source capture reflection mode")
		check(reflection.report.get("inside",null)==not enabled,label+" reflection indoor state")
		check(scene.source_renderer._environment.sky==reflection._candidate_sky,label+" source reflection sky retained")
		check(scene.source_renderer._environment.ambient_light_energy==(1.0 if enabled else 0.0),label+" source reflection environment gain")
		check(scene.source_renderer._environment.reflected_light_source==(Environment.REFLECTION_SOURCE_SKY if enabled else Environment.REFLECTION_SOURCE_DISABLED),label+" reflection indoor switch")
		for probe_state: Dictionary in reflection._probes:
			check(is_instance_valid(probe_state.probe) and not probe_state.probe.visible,label+" near-capture probe hidden")
	var adapter: Node=scene.source_renderer.get("transparent_sky") as Node
	check(is_instance_valid(adapter),label+" transparent sky installed")
	if not is_instance_valid(adapter): return
	var expected:=27 if scene.slug=="wuming" else 2
	check(adapter.report.get("status","")=="installed",label+" transparent sky status")
	check(int(adapter.report.get("bound",-1))==expected,label+" transparent sky material count")
	check(adapter.report.get("unsupported",["missing report"]).is_empty(),label+" transparent sky materials supported")
	check(adapter.report.get("skylight_enabled",null)==enabled,label+" transparent sky reported state")
	var saved: Array=adapter.get("_saved")
	check(saved.size()==expected,label+" transparent sky live binding count")
	for binding: Dictionary in saved:
		var material: ShaderMaterial=binding.material
		check(is_instance_valid(material),label+" transparent sky material remains valid")
		if not is_instance_valid(material): continue
		check(material.get_shader_parameter("source_sh9_enabled")==enabled,label+" transparent sky actual uniform "+material.resource_name)
		check(material.get_shader_parameter("source_transparent_sky_mode")==1,label+" transparent sky normal render mode "+material.resource_name)

func state() -> Dictionary:
	var renderer: Node=scene.source_renderer
	var transparent: Node=renderer.get("transparent_sky") as Node
	return {"transparent_sky":transparent.report.duplicate(true) if is_instance_valid(transparent) else {"status":"missing"},
		"reflection":renderer.reflection.report.duplicate(true) if is_instance_valid(renderer.reflection) else {"status":"missing"},
		"water_distortion":renderer.water_binding.report.duplicate(true) if is_instance_valid(renderer.water_binding) else {"status":"missing"},
		"inside":scene.house_driver.is_in_house, "film":renderer.film._inside,
		"bloom":renderer.bloom._inside, "sky":renderer.sh.report.skylight_enabled,
		"sun":renderer._sun.light_energy, "feet":scene.player.position,
		"atmosphere":renderer.atmosphere.effect.report,"dof":renderer.depth_of_field.effect.report.duplicate(true)}

func real_motion() -> Dictionary:
	var folder:=out.path_join(scene.slug+"-real-motion")
	DirAccess.make_dir_recursive_absolute(folder)
	var samples: Array=[]
	var frame_ms: Array=[]
	var start:=Time.get_ticks_usec()
	var previous:=start
	var last_sample:=-1.0
	var first: Vector3=scene.player.position
	while float(Time.get_ticks_usec()-start)/1000000.0<8.0:
		await process_frame
		var now:=Time.get_ticks_usec()
		var elapsed:=float(now-start)/1000000.0
		frame_ms.append(float(now-previous)/1000.0)
		previous=now
		scene.player.set_review_motion(Vector2.RIGHT if elapsed<2.0 else (Vector2.LEFT if elapsed>=4.0 and elapsed<6.0 else Vector2.ZERO))
		if elapsed-last_sample>=0.25:
			last_sample=elapsed
			await RenderingServer.frame_post_draw
			var name:="frame-%03d.png"%samples.size()
			root.get_texture().get_image().save_png(folder.path_join(name))
			samples.append({"seconds":elapsed,"feet":scene.player.position,"camera":scene.camera.position,
				"direction":scene.player.last_direction,"animation":scene.player.sprite.animation,"frame":scene.player.sprite.frame,"file":name})
	scene.player.set_review_motion(Vector2.ZERO)
	var summary:={"samples":samples,"frame_ms_with_capture_overhead":frame_ms,
		"start":first,"end":scene.player.position,"travelled_m":scene.player.travelled_distance}
	FileAccess.open(folder.path_join("timing.json"),FileAccess.WRITE).store_string(JSON.stringify(summary,"\t"))
	return {"samples":samples.size(),"duration_seconds":float(Time.get_ticks_usec()-start)/1000000.0,
		"travelled_m":scene.player.travelled_distance,"timing":folder.path_join("timing.json")}

func run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	# Set the review size in run(), after startup window overrides have applied.
	root.content_scale_size=Vector2i(1280,720)
	root.size=Vector2i(1280,720)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian","wuming"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		var renderer: Node=scene.source_renderer
		check(scene.source_rendering and scene.source_distortion and scene.source_atmosphere,"source rendering defaults")
		var beam: Node=driver_named("/original_torch_beam.gd")
		var particles: Node=driver_named("/original_particle_materials.gd")
		check(renderer!=null and renderer.report.status=="installed","source renderer installed")
		check(is_instance_valid(renderer.water_binding),"source Water distortion binding installed")
		if is_instance_valid(renderer.water_binding):
			check(renderer.water_binding.report.expected==1 and renderer.water_binding.report.bound==1,"one original Water distortion mesh per map")
		check_transparent_sky(true,"initial outdoor")
		check(beam!=null and beam.coverage.bound_beam_emitters==(1 if slug=="wuming" else 0),"source Beam2 count")
		check(particles.coverage.bound_emitters==(81 if slug=="wuming" else 9),"source transparent material count")
		check(renderer.ambient.report.bound==(74 if slug=="wuming" else 77),"ambient and restored human materials")
		check(renderer.ambient.report.unsupported.is_empty(),"all source sprite materials supported")
		check(renderer.birds.report.bound==(0 if slug=="wuming" else 20),"original bird materials")
		check(renderer.birds.report.unsupported.is_empty(),"all original bird materials supported")
		check(renderer.leaf.report.bound_emitters==(0 if slug=="wuming" else 1),"original leaf material")
		check(renderer.leaf.report.unsupported.is_empty(),"original leaf material supported")
		var animals: Node=driver_named("/source_animal_behavior.gd")
		check(animals!=null,"source animal controller installed")
		# Actor initialization deliberately waits two physics ticks after load.
		# A map-switch await may return before those ticks, unlike initial startup.
		for startup_frame in 12:
			if animals.startup_ticks==0: break
			await physics_frame
		check(animals.startup_ticks==0,"source animals completed deferred startup")
		check(animals.report.active==(30 if slug=="wuming" else 36),"source animal active count")
		var waterfall: Node=driver_named("/source_waterfall_adapter.gd")
		var bagua: Node=driver_named("/source_bagua_adapter.gd")
		if slug=="wuming":
			check(waterfall!=null and waterfall.report.bound_surfaces==2,"both original waterfall surfaces installed")
			check(waterfall.report.unsupported.is_empty(),"waterfall binding supported")
			check(bagua!=null and bagua.report.bound_surfaces==4,"all four original bagua materials installed")
			check(bagua.report.unsupported.is_empty(),"bagua bindings supported")
		else:
			check(waterfall==null,"no added waterfall in Youxian")
			check(bagua==null,"no added bagua in Youxian")
		for foreground_entry in scene.foreground_driver.entries:
			if foreground_entry.fade_enabled:
				check(is_zero_approx(float(foreground_entry.material.get_shader_parameter("source_foreground_phase"))),"foreground FXAA phase remains zero")
		var entry:={"map":slug,"renderer":renderer.report.duplicate(true),"beam":beam.coverage.duplicate(true),
			"animals":animals.report.duplicate(true),"waterfall":waterfall.report.duplicate(true) if waterfall!=null else {},
			"bagua":bagua.report.duplicate(true) if bagua!=null else {},
			"foreground":scene.foreground_driver.report.duplicate(true),"states":[]}
		await shot("combined-port")
		if is_instance_valid(renderer.water_binding):
			check(renderer.water_binding.report.unsupported.is_empty(),"Water distortion binding supported after evaluated updates")
		check(renderer.atmosphere.effect.report.status=="ready","atmosphere RD ready")
		check(renderer.splash_binding.audit.source_emitters==(9 if slug=="wuming" else 0),"distortion source emitter count")
		check(renderer.report.local_cones.unsupported.is_empty(),"cone bindings supported")
		check(renderer.report.height_fog.unsupported.is_empty(),"fog bindings supported")
		entry.states.append(state())
		if report.maps.size()<2:
			entry["motion"]=await real_motion()
			for index in scene.positions.size():
				scene.player.set_review_motion(Vector2.ZERO)
				check(scene.player.place_at_source_actor_position(scene.positions[index]),"viewpoint support "+str(index))
				scene.camera.reset_at(scene.player.get_camera_anchor())
				await shot("combined-view-%02d"%index)
		var center: Vector3=scene.house_driver._boxes[0].transform.origin
		scene.house_driver.reset_outdoors()
		check(scene.player.place_at_source_actor_position(center+Vector3(-3.65,0,0)),"doorway support")
		scene.camera.reset_at(scene.player.get_camera_anchor())
		scene.player.set_review_motion(Vector2.UP)
		for i in 150:
			await physics_frame
			if scene.house_driver.is_in_house: break
		check(scene.house_driver.is_in_house,"walk entered house")
		for i in 12: await physics_frame
		scene.player.set_review_motion(Vector2.ZERO)
		await shot("combined-inside")
		entry.states.append(state())
		check(renderer.film._inside and renderer.bloom._inside and not renderer.sh.report.skylight_enabled,"indoor render state")
		check_transparent_sky(false,"indoor")
		check(is_equal_approx(renderer._sun.light_energy,3.0/PI),"indoor sunlight")
		check(is_equal_approx(renderer.depth_of_field.effect.report.source_focus_m,14.7),"indoor source DOF")
		check(renderer.depth_of_field.effect.report.inside,"indoor DOF reporting")
		check(not scene.camera.attributes.dof_blur_near_enabled and not scene.camera.attributes.dof_blur_far_enabled,"builtin DOF stays disabled")
		scene.player.set_review_motion(Vector2.DOWN)
		for i in 150:
			await physics_frame
			if not scene.house_driver.is_in_house: break
		scene.player.set_review_motion(Vector2.ZERO)
		await shot("combined-exit")
		entry.states.append(state())
		check(not scene.house_driver.is_in_house and not renderer.film._inside and renderer.sh.report.skylight_enabled,"exit render state")
		check_transparent_sky(true,"restored outdoor")
		check(is_equal_approx(renderer._sun.light_energy,30.0/PI),"outdoor sunlight")
		check(is_equal_approx(renderer.depth_of_field.effect.report.source_focus_m,32.2),"outdoor source DOF")
		if slug=="wuming" and report.maps.is_empty():
			scene.set_process(false)
			scene.player.set_physics_process(false)
			scene.house_driver.set_physics_process(false)
			scene.camera.follow_target=null
			scene.camera.source_bounds.clear()
			scene.camera.reset_at(Vector3(-72.15966796875,3.462461242675781,65.4056884765625))
			scene.camera.zoom=.27
			scene.camera._apply_pose()
			scene.camera.attributes.dof_blur_near_enabled=false
			scene.camera.attributes.dof_blur_far_enabled=false
			renderer.depth_of_field.effect.enabled=false
			await shot("beam-close")
			for frame in 6:
				beam.set_audit_mode(0,float(frame)*.1)
				await shot("beam-material-%02d"%frame)
			beam.set_audit_mode(0,-1.0)
			renderer.depth_of_field.effect.enabled=true
			var material: ShaderMaterial=beam._materials[0]
			check(material.shader.code.contains("INV_VIEW_MATRIX*MODELVIEW_MATRIX*vec4"),"billboard heightfog position")
			scene.house_driver.set_physics_process(true)
			scene.set_process(true)
		entry["distortion"]=renderer.splash_binding.audit.duplicate(true)
		report.maps.append(entry)
	# Exercise the fallback destruction path as well as the explicit map-switch path.
	var held_character_material: ShaderMaterial=scene.source_renderer.character.material
	var held_transparent: Array[Dictionary]=[]
	var transparent: Node=scene.source_renderer.get("transparent_sky") as Node
	if is_instance_valid(transparent):
		for binding: Dictionary in transparent.get("_saved"):
			var original: Dictionary={"material":binding.material,"shader":binding.shader,"parameters":binding.parameters.duplicate(),"layers":["transparent_sky"]}
			# Whole-renderer shutdown also removes lower layers. Keep the actual
			# oldest saved Shader reference, not the transparent adapter's preimage.
			for owner_name in ["local_cones","height_fog","sh"]:
				var owner: Object=scene.source_renderer.get(owner_name)
				if not is_instance_valid(owner): continue
				for lower: Dictionary in owner.get("_saved"):
					if lower.get("object")==binding.material and lower.has("shader"):
						original.shader=lower.shader
						original.parameters=lower.parameters.duplicate()
						original.layers.append(owner_name)
			held_transparent.append(original)
	check(held_transparent.size()==27,"direct-free holds every Wuming transparent material")
	var water_pass_ref: WeakRef=weakref(scene.source_renderer.distortion.water_pass)
	var water_effect_ref: WeakRef=weakref(scene.source_renderer.distortion)
	var water_binding_ref: WeakRef=weakref(scene.source_renderer.water_binding)
	var held_environment: Environment=scene.source_renderer._environment
	var reflection_original: Dictionary=scene.source_renderer.reflection._saved.duplicate()
	check(scene.source_renderer.distortion.water_pass.active(),"direct-free starts with active original Water pass")
	scene.source_renderer.queue_free()
	for i in 3: await process_frame
	var restored_transparent:=0
	for original: Dictionary in held_transparent:
		var material: ShaderMaterial=original.material
		check(is_instance_valid(material),"direct-free held transparent material remains valid")
		if not is_instance_valid(material): continue
		check(material.shader==original.shader,"direct-free transparent original Shader reference restored")
		check(not material.shader.code.contains("source_transparent_sky"),"direct-free transparent sky layer removed")
		for parameter in original.parameters:
			check(material.get_shader_parameter(parameter)==original.parameters[parameter],"direct-free transparent original parameter "+str(parameter))
		if material.shader==original.shader: restored_transparent+=1
	# Weak references must not keep either RefCounted owner alive for this test.
	var water_pass_released: bool=water_pass_ref.get_ref()==null
	var water_effect_released: bool=water_effect_ref.get_ref()==null
	var water_binding_freed: bool=water_binding_ref.get_ref()==null
	check(water_pass_released,"direct-free Water pass released")
	check(water_effect_released,"direct-free distortion compositor effect released")
	check(water_binding_freed,"direct-free Water binding node released")
	check(held_environment.sky==reflection_original.sky,"direct-free original reflection sky restored")
	check(held_environment.ambient_light_energy==reflection_original.energy,"direct-free original environment energy restored")
	check(held_environment.reflected_light_source==reflection_original.reflection_source,"direct-free original reflection source restored")
	report["direct_free"]={"held_transparent_materials":held_transparent.size(),"original_shader_references_restored":restored_transparent,
		"water_pass_released":water_pass_released,"distortion_effect_released":water_effect_released,"water_binding_freed":water_binding_freed}
	check(not held_character_material.shader.code.contains("source_sh9"),"direct-free SH layer removed")
	check(not held_character_material.shader.code.contains("source_height_fog("),"direct-free fog layer removed")
	check(scene.camera.compositor==null,"direct-free compositor restored")
	check(not scene.camera.has_meta("source_dof_owner"),"direct-free DOF owner removed")
	scene.source_renderer=null
	FileAccess.open(out.path_join("combined-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_COMBINED_VERIFIED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	for i in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
