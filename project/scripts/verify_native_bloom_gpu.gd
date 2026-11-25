extends SceneTree
## Empty sky-only numerical fixture; no generated scene geometry.
var out := ""
var grab: CompositorEffect
var bloom: CompositorEffect
var compositor: Compositor
var camera: Camera3D
var sky_mat: ShaderMaterial
var report: Array = []
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fixture-dir="): out=arg.trim_prefix("--fixture-dir=")
	call_deferred("run")
func capture(label: String) -> void:
	for i in 6: await process_frame
	assert(grab.request_face(report.size()))
	for i in 180:
		await process_frame
		var result: Dictionary=grab.take_result()
		if result.has("error"):
			push_error(str(result.error)); quit(2); return
		if result.has("bytes"):
			FileAccess.open(out.path_join(label+".bin"),FileAccess.WRITE).store_buffer(result.bytes)
			report.append({"label":label,"size":[result.size.x,result.size.y],"bytes":result.bytes.size()})
			return
	push_error("HDR readback timed out"); quit(3)
func run() -> void:
	root.size=Vector2i(128,128)
	root.content_scale_size=Vector2i(128,128)
	var world:=Node3D.new()
	root.add_child(world)
	var environment:=Environment.new()
	environment.background_mode=Environment.BG_SKY
	environment.tonemap_mode=Environment.TONE_MAPPER_LINEAR
	environment.glow_enabled=false
	var sky:=Sky.new()
	sky_mat=ShaderMaterial.new()
	var shader:=Shader.new()
	shader.code="shader_type sky; uniform bool low = false; void sky(){ vec2 p=SCREEN_UV; COLOR=low?vec3(0.5):vec3(p.x<0.5?0.2:4.0, p.y<0.5?2.0:0.1, (abs(p.x-0.5)<0.08 && abs(p.y-0.5)<0.08)?12.0:0.0); }"
	sky_mat.shader=shader
	sky.sky_material=sky_mat
	environment.sky=sky
	var env_node:=WorldEnvironment.new()
	env_node.environment=environment
	world.add_child(env_node)
	camera=Camera3D.new()
	world.add_child(camera)
	camera.current=true
	grab=load("res://sky_capture_candidate/source_sky_hdr_readback.gd").new()
	bloom=load("res://native_bloom_candidate/original_native_bloom.gd").new()
	# Explicit numerical fixture levels; main-map houses use 5/5, not 5/0.5.
	bloom.set_source_intensities(5.0,0.5)
	compositor=Compositor.new()
	compositor.compositor_effects=[bloom,grab]
	camera.compositor=compositor
	bloom.enabled=false
	await capture("source")
	bloom.enabled=true
	for profile in [0,3]:
		bloom.set_source_postprocess_quality(profile)
		for inside in [false,true]:
			bloom.set_source_indoor(inside)
			await capture("q%d-%s"%[profile,"indoor" if inside else "outdoor"])
	sky_mat.set_shader_parameter("low",true)
	bloom.enabled=false
	await capture("low-source")
	bloom.enabled=true
	await capture("low-bloom")
	camera.compositor=null
	compositor=null
	bloom=null
	grab=null
	for i in 6: await process_frame
	FileAccess.open(out.path_join("readbacks.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("BLOOM_GPU_READBACK_DONE captures=",report.size())
	world.queue_free()
	await process_frame
	quit()
