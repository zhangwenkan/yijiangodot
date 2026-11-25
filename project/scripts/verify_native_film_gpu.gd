extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var fixture_dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fixture-dir="):
			fixture_dir = arg.trim_prefix("--fixture-dir=")
	assert(not fixture_dir.is_empty())
	var device := RenderingServer.create_local_rendering_device()
	assert(device != null)
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string("res://native_film_candidate/original_native_film.glsl").replace("#[compute]", "")
	var spirv := device.shader_compile_spirv_from_source(source)
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		push_error(compile_error)
		quit(1)
		return
	var shader := device.shader_create_from_spirv(spirv)
	var pipeline := device.compute_pipeline_create(shader)
	for mode in ["outdoor", "indoor"]:
		var tex_format := RDTextureFormat.new()
		tex_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		tex_format.width = 64
		tex_format.height = 64
		tex_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		var pixels := FileAccess.get_file_as_bytes(fixture_dir.path_join("input-rgba16f.bin"))
		var texture := device.texture_create(tex_format, RDTextureView.new(), [pixels])
		var cb := FileAccess.get_file_as_bytes("res://native_film_candidate/native-film-" + mode + ".bin")
		var constants := device.storage_buffer_create(cb.size(), cb)
		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(texture)
		var constants_uniform := RDUniform.new()
		constants_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		constants_uniform.binding = 1
		constants_uniform.add_id(constants)
		var uniforms := device.uniform_set_create([color_uniform, constants_uniform], shader, 0)
		var push := PackedByteArray()
		push.resize(16)
		push.encode_s32(0, 64)
		push.encode_s32(4, 64)
		push.encode_float(8, 1.0)
		var commands := device.compute_list_begin()
		device.compute_list_bind_compute_pipeline(commands, pipeline)
		device.compute_list_bind_uniform_set(commands, uniforms, 0)
		device.compute_list_set_push_constant(commands, push, 16)
		device.compute_list_dispatch(commands, 8, 8, 1)
		device.compute_list_end()
		device.submit()
		device.sync()
		var output := device.texture_get_data(texture, 0)
		assert(output.size() == pixels.size())
		var f := FileAccess.open(fixture_dir.path_join(mode + "-gpu-rgba16f.bin"), FileAccess.WRITE)
		f.store_buffer(output)
		f.close()
		device.free_rid(uniforms)
		device.free_rid(constants)
		device.free_rid(texture)
	device.free_rid(shader)
	device.free()
	print("NATIVE_FILM_GPU_FIXTURE_COMPLETE")
	quit()
