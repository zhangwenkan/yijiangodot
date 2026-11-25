extends Node
## Independent diagnostic candidate. No meshes/vertices are created or changed.
## Add as a sibling of worlds.gd, then await capture(scene_root, world, environment, out_dir).
## Temporarily changes shared material parameters/shaders and restores all of them.

const READER = preload("source_sky_hdr_readback.gd")
const DIFFUSE_SKY = preload("source_scene_diffuse_sky.gdshader")
const FACE_NAMES := ["px","nx","py","ny","pz","nz"]
const DIRECTIONS := [Vector3.RIGHT,Vector3.LEFT,Vector3.UP,Vector3.DOWN,Vector3.BACK,Vector3.FORWARD]
# Exact Godot 4.7.2 renderer_scene_cull.cpp reflection-probe camera orientations.
const UPS := [Vector3.DOWN,Vector3.DOWN,Vector3.BACK,Vector3.FORWARD,Vector3.DOWN,Vector3.DOWN]
var report: Dictionary = {}
var _saved: Array[Dictionary] = []
var _seen: Dictionary = {}
var _shader_cache: Dictionary = {}
var _viewport: SubViewport
var _camera: Camera3D
var _reader
var _busy := false
var source_atmosphere_slug := ""
var _saved_time_scale := 1.0
var _time_frozen := false

func capture(scene_root: Node, world: Node3D, source_environment: Environment, output_dir: String,
		resolution: int = 128, capture_position: Vector3 = Vector3.ZERO) -> Dictionary:
	if _busy or not is_instance_valid(world) or source_environment == null:
		return {"error":"Busy or missing source world/environment."}
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		return {"error":"Run this HDR candidate with Forward+."}
	if resolution < 16 or resolution > 2048 or (resolution & (resolution-1)) != 0:
		return {"error":"Resolution must be a power of two, 16..2048."}
	_busy = true
	_saved.clear()
	_seen.clear()
	_shader_cache.clear()
	report = {"status":"capturing","origin":[capture_position.x,capture_position.y,capture_position.z],
		"resolution":resolution,"near_m":20.0,"face_order":FACE_NAMES,"lower_hemisphere":"black, direction.y < 0",
		"input_format":"RGBA16F scene-linear before postprocessing", "disabled":[],"roughness_overrides":0,
		"roughness_unhandled":[],"captures":[],"sky_feedback_overrides":0,
		"sh9_feedback_overrides":0,"sh9_emission_feedback_overrides":0,"sh9_feedback_disable_errors":[],
		"time_policy":"Scene processing and shader TIME frozen for all six faces",
		"orientation":"Godot probe directions/up; normal viewport readback flipped vertically once",
		"limits":["Godot sky convolution is not UE third-order SH.","Existing cross-engine materials, fog and direct lights remain capture inputs.",
		"Frozen scene is a reconstructed-scene capture, not the original UE GPU buffer.","Finite far plane encloses existing geometry; UE capture used reversed infinite projection."]}
	var mkdir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if mkdir_error != OK:
		_busy = false
		return {"error":"Cannot create capture directory: %s" % mkdir_error}
	# Pause scene logic before temporary material changes so drivers cannot overwrite them.
	_saved_time_scale = Engine.time_scale
	report["time_scale_before_capture"] = _saved_time_scale
	Engine.time_scale = 0.0
	report["time_scale_during_capture"] = Engine.time_scale
	_time_frozen = true
	_scan_scene(scene_root)
	var capture_environment: Environment = source_environment.duplicate()
	capture_environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	capture_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	capture_environment.ambient_light_energy = 0.0
	capture_environment.ssao_enabled = false
	capture_environment.ssil_enabled = false
	capture_environment.ssr_enabled = false
	capture_environment.sdfgi_enabled = false
	capture_environment.volumetric_fog_ambient_inject = 0.0
	capture_environment.glow_enabled = false
	capture_environment.adjustment_enabled = false
	capture_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	capture_environment.tonemap_exposure = 1.0
	_viewport = SubViewport.new()
	_viewport.name = "SourceSkyHDRCaptureViewport"
	_viewport.size = Vector2i(resolution,resolution)
	_viewport.world_3d = world.get_world_3d()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_viewport.use_taa = false
	_viewport.use_debanding = false
	_viewport.scaling_3d_scale = 1.0
	_viewport.positional_shadow_atlas_size = 4096
	_viewport.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.name = "SourceSkyHDRCaptureCamera"
	_camera.environment = capture_environment
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 90.0
	_camera.near = 20.0
	_camera.far = _geometry_far(scene_root,capture_position)
	report["far_m"] = _camera.far
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	var attributes := CameraAttributesPractical.new()
	attributes.auto_exposure_enabled = false
	attributes.exposure_multiplier = 1.0
	attributes.dof_blur_far_enabled = false
	attributes.dof_blur_near_enabled = false
	_camera.attributes = attributes
	_reader = READER.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [_reader]
	if not source_atmosphere_slug.is_empty():
		var atmosphere = load("res://source_atmosphere_candidate/source_atmosphere_effect.gd").new()
		var atmosphere_report: Dictionary = atmosphere.configure(
			"res://source_atmosphere_candidate/"+source_atmosphere_slug+"-atmosphere.json",
			"res://source_lighting_candidate/"+source_atmosphere_slug+"-height-fog.json", {"reflection_capture":true})
		report["atmosphere"] = atmosphere_report
		if atmosphere_report.has("error"):
			_cleanup()
			_busy = false
			return {"error":str(atmosphere_report.error),"report":report}
		compositor.compositor_effects = [atmosphere,_reader]
	_camera.compositor = compositor
	_viewport.add_child(_camera)
	_camera.current = true
	var faces: Array[Image] = []
	var failure := ""
	for face in 6:
		_camera.global_position = capture_position
		_camera.look_at(capture_position+DIRECTIONS[face],UPS[face])
		# Set pose, flush several frames, THEN arm a token for the following render.
		for settle in 4:
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
		if not _reader.request_face(face):
			failure = "Reader could not accept face %s: %s" % [face,_reader.take_result()]
			break
		var result: Dictionary = {}
		var deadline := Time.get_ticks_msec()+45000
		while result.is_empty() and Time.get_ticks_msec()<deadline:
			await get_tree().process_frame
			result = _reader.take_result()
		if result.is_empty() or result.has("error") or int(result.get("token",-1)) != face:
			failure = "Readback failed/timed out on face %s: %s" % [face,result]
			break
		var bytes: PackedByteArray = result["bytes"]
		var raw_file := FileAccess.open(output_dir.path_join("face_%s_raw.rgba16f" % FACE_NAMES[face]),FileAccess.WRITE)
		if raw_file == null:
			failure = "Cannot write raw capture face."
			break
		raw_file.store_buffer(bytes)
		raw_file.close()
		var image := Image.create_from_data(resolution,resolution,false,Image.FORMAT_RGBAH,bytes)
		# Normal viewport flip_y=true vs reflection-probe flip_y=false.
		image.flip_y()
		var stats := _mask_and_measure(image,face)
		if int(stats.invalid_pixels)>0:
			failure = "Non-finite HDR pixels on face %s; raw data retained." % FACE_NAMES[face]
			break
		var exr_path := output_dir.path_join("face_%s.exr" % FACE_NAMES[face])
		var exr_error := image.save_exr(exr_path,false)
		if exr_error != OK:
			failure = "EXR save failed (%s). Raw half-float data retained." % exr_error
			break
		stats["face"] = FACE_NAMES[face]
		stats["raw_bytes"] = bytes.size()
		stats["file"] = exr_path
		report.captures.append(stats)
		faces.append(image)
		print("SOURCE_SKY_CAPTURE_FACE ",JSON.stringify(stats))
	_cleanup()
	var cube: Cubemap
	if failure.is_empty() and faces.size()==6:
		cube = Cubemap.new()
		var cube_error := cube.create_from_images(faces)
		if cube_error != OK:
			failure = "Cubemap.create_from_images failed: %s" % cube_error
		else:
			var save_error := ResourceSaver.save(cube,output_dir.path_join("source_scene_capture.res"))
			if save_error != OK:
				failure = "Cubemap resource save failed: %s" % save_error
	report["status"] = "captured" if failure.is_empty() else "failed"
	report["error"] = failure
	var manifest := FileAccess.open(output_dir.path_join("capture-manifest.json"),FileAccess.WRITE)
	if manifest != null:
		manifest.store_string(JSON.stringify(report,"\t"))
		manifest.close()
	_busy = false
	return {"cube":cube,"report":report,"error":failure}

func _save(object: Object, property: StringName, value: Variant) -> void:
	_saved.append({"object":object,"property":property,"value":object.get(property)})
	object.set(property,value)

func _scan_scene(node: Node) -> void:
	if node == self:
		return
	if node.is_processing():
		_saved.append({"object":node,"method":"set_process","value":true})
		node.set_process(false)
	if node.is_physics_processing():
		_saved.append({"object":node,"method":"set_physics_process","value":true})
		node.set_physics_process(false)
	var source_class := str(node.get_meta("source_class",""))
	var source_component := str(node.get_meta("source_component",""))
	var particle := node is GPUParticles3D or node is CPUParticles3D or source_class.contains("ParticleSystem")
	particle = particle or node.has_meta("source_emitter") or source_component.contains("ParticleSystemComponent")
	# OriginalCascadeParticles is an adapter-owned parent, not an arbitrary beam mesh.
	particle = particle or str(node.name).begins_with("OriginalCascadeParticles_")
	var gi_feedback := node is ReflectionProbe or node is VoxelGI or node is LightmapGI
	if node is Node3D and (particle or gi_feedback):
		_save(node,&"visible",false)
		report.disabled.append({"node":str(node.get_path()),"reason":"particles" if particle else "sky/GI feedback"})
	if node is GeometryInstance3D:
		_bind_material(node.material_override)
		_bind_material(node.material_overlay)
		if node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count():
				_bind_material(node.get_active_material(surface))
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			for surface in node.multimesh.mesh.get_surface_count():
				_bind_material(node.multimesh.mesh.surface_get_material(surface))
	for child in node.get_children():
		_scan_scene(child)

func _bind_material(material: Material) -> void:
	if material == null or _seen.has(material.get_instance_id()):
		return
	_seen[material.get_instance_id()] = true
	_bind_material(material.next_pass)
	if material is BaseMaterial3D:
		_save(material,&"roughness",1.0)
		_save(material,&"roughness_texture",null)
		if material is ORMMaterial3D and material.orm_texture != null:
			report.roughness_unhandled.append("ORM texture requires a dedicated roughness-only override: "+material.resource_path)
		report.roughness_overrides += 1
		return
	if not material is ShaderMaterial or material.shader == null:
		return
	var original: Shader = material.shader
	var code := original.code
	if not code.contains("shader_type spatial"):
		return
	var parameters: Dictionary = {}
	for item in original.get_shader_uniform_list():
		parameters[item.name] = material.get_shader_parameter(item.name)
	var has_sh9 := parameters.has("source_sh9_enabled")
	var sh9_emission := has_sh9 and bool(material.get_meta("source_two_sided_foliage",false))
	_saved.append({"object":material,"shader":original,"parameters":parameters,
		"sh9_feedback":has_sh9,"sh9_emission_feedback":sh9_emission})
	if has_sh9:
		# SH also feeds leaf transmission through EMISSION. Disable its producer;
		# clearing all EMISSION would erase real source-material self-illumination.
		material.set_shader_parameter("source_sh9_enabled",false)
		report.sh9_feedback_overrides += 1
		if sh9_emission: report.sh9_emission_feedback_overrides += 1
	if parameters.has("source_lf_count"):
		material.set_shader_parameter("source_lf_count",0)
	if parameters.has("source_lf_sun_enabled"):
		material.set_shader_parameter("source_lf_sun_enabled",false)
	if not _shader_cache.has(original.get_instance_id()):
		var fragment_pattern := RegEx.new()
		fragment_pattern.compile("void\\s+fragment\\s*\\(\\s*\\)\\s*\\{")
		var match_fragment := fragment_pattern.search(code)
		if match_fragment == null:
			report.roughness_unhandled.append(original.resource_path)
			return
		var cursor := match_fragment.get_end()
		var depth := 1
		while cursor<code.length() and depth>0:
			if code[cursor]=="{": depth+=1
			elif code[cursor]=="}": depth-=1
			cursor+=1
		if depth != 0:
			report.roughness_unhandled.append(original.resource_path)
			return
		# Existing source shaders have no fragment early return. Preserve all other math.
		var replacement := Shader.new()
		# A disabled Environment does not override custom IRRADIANCE/RADIANCE.
		# Suppress both current SH owners and any custom sky radiance at the final
		# fragment output, so recapture cannot feed the old capture into itself.
		replacement.code = code.insert(cursor-1,"\nROUGHNESS = 1.0; // source capture override\nIRRADIANCE = vec4(0.0, 0.0, 0.0, 1.0);\nRADIANCE = vec4(0.0, 0.0, 0.0, 1.0);\n")
		_shader_cache[original.get_instance_id()] = replacement
	material.shader = _shader_cache[original.get_instance_id()]
	# Shader replacement restores saved uniforms, including the SH switch.
	# Reapply all capture-only switches after restoring the other parameters.
	for parameter in parameters:
		material.set_shader_parameter(parameter,parameters[parameter])
	if parameters.has("source_lf_count"): material.set_shader_parameter("source_lf_count",0)
	if parameters.has("source_lf_sun_enabled"): material.set_shader_parameter("source_lf_sun_enabled",false)
	if has_sh9:
		material.set_shader_parameter("source_sh9_enabled",false)
		if material.get_shader_parameter("source_sh9_enabled") != false:
			report.sh9_feedback_disable_errors.append(original.resource_path)
	report.roughness_overrides += 1
	report.sky_feedback_overrides += 1

func _geometry_far(node: Node, origin: Vector3) -> float:
	var far_value := 1800.0
	if node is GeometryInstance3D:
		var bounds: AABB = node.get_aabb()
		for point in 8:
			far_value = maxf(far_value,(node.global_transform*bounds.get_endpoint(point)).distance_to(origin)+100.0)
	for child in node.get_children():
		if child != self: far_value = maxf(far_value,_geometry_far(child,origin))
	return far_value

func _mask_and_measure(image: Image, face: int) -> Dictionary:
	var sum := Vector3.ZERO
	var maximum := 0.0
	var invalid := 0
	var size := image.get_width()
	for y in size:
		for x in size:
			var v := (float(y)+0.5)/float(size)*2.0-1.0
			var lower := face==3 or (face!=2 and v>0.0)
			if lower:
				image.set_pixel(x,y,Color(0,0,0,1))
				continue
			var color := image.get_pixel(x,y)
			if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b):
				invalid+=1
			else:
				sum+=Vector3(color.r,color.g,color.b)
				maximum=maxf(maximum,maxf(color.r,maxf(color.g,color.b)))
	var mean := sum/float(size*size)
	return {"mean_rgb":[mean.x,mean.y,mean.z],"maximum_rgb":maximum,"invalid_pixels":invalid}

func _cleanup() -> void:
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_viewport.queue_free()
	_viewport = null
	_camera = null
	_reader = null
	var restoration_errors: Array[String] = []
	var restored_entries := 0
	var restored_sh9 := 0
	var restored_sh9_emission := 0
	for i in range(_saved.size()-1,-1,-1):
		var state := _saved[i]
		var object: Object = state.object
		if not is_instance_valid(object):
			restoration_errors.append("Saved object disappeared during capture.")
			continue
		if state.has("shader"):
			object.set("shader",state.shader)
			for parameter in state.parameters:
				object.call("set_shader_parameter",parameter,state.parameters[parameter])
				if object.call("get_shader_parameter",parameter)!=state.parameters[parameter]:
					restoration_errors.append("Shader parameter did not restore: "+str(parameter))
			if object.get("shader")!=state.shader:
				restoration_errors.append("Shader resource did not restore.")
			if state.get("sh9_feedback",false) and object.call("get_shader_parameter","source_sh9_enabled")==state.parameters["source_sh9_enabled"]:
				restored_sh9 += 1
				if state.get("sh9_emission_feedback",false): restored_sh9_emission += 1
		elif state.has("method"):
			object.call(state.method,state.value)
			var getter := "is_processing" if state.method=="set_process" else "is_physics_processing"
			if object.call(getter)!=state.value:
				restoration_errors.append("Processing state did not restore.")
		else:
			object.set(state.property,state.value)
			if object.get(state.property)!=state.value:
				restoration_errors.append("Property did not restore: "+str(state.property))
		restored_entries+=1
	report["restored_scene_state"] = restoration_errors.is_empty()
	report["restoration"] = {"entries":restored_entries,"errors":restoration_errors}
	report["restored_sh9_feedback_overrides"] = restored_sh9
	report["restored_sh9_emission_feedback_overrides"] = restored_sh9_emission
	_saved.clear()
	_shader_cache.clear()
	if _time_frozen:
		report["time_scale_before_restore"] = Engine.time_scale
		Engine.time_scale = _saved_time_scale
		_time_frozen = false
		report["time_scale_after_capture"] = Engine.time_scale
		report["time_scale_restored"] = Engine.time_scale == _saved_time_scale

static func make_diffuse_sky(capture_cube: Cubemap, visible_ue_cube: Cubemap) -> Sky:
	var material := ShaderMaterial.new()
	material.shader = DIFFUSE_SKY
	material.set_shader_parameter("source_scene_capture",capture_cube)
	material.set_shader_parameter("source_open_sky",visible_ue_cube)
	var source_color := Color(1.0,219.0/255.0,195.0/255.0).srgb_to_linear()
	material.set_shader_parameter("source_skylight_linear_gain",Vector3(source_color.r,source_color.g,source_color.b)*1.100000023841858)
	var sky := Sky.new()
	sky.sky_material = material
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	return sky

func _exit_tree() -> void:
	if not _saved.is_empty() or _time_frozen: _cleanup()
