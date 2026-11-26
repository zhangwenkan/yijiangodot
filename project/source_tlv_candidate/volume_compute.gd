extends RefCounted
## GPU-only candidate verifier. Resolved per-voxel inputs must already include
## actual shadow, LightFunction and outer-edge handling. Missing inputs fail.
var rd: RenderingDevice
var shader_inject := RID()
var shader_filter := RID()
var pipeline_inject := RID()
var pipeline_filter := RID()
var sampler := RID()
var volumes: Array[RID] = []
var buffers: Array[RID] = []
var validation := RID()

func initialize(device: RenderingDevice, folder: String) -> String:
	rd = device
	for name in ["inject_resolved.glsl.txt", "filter_volume.glsl.txt"]:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string(folder.path_join(name))
		if source.source_compute.is_empty(): return "Missing " + name
		var spirv := rd.shader_compile_spirv_from_source(source)
		var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not error.is_empty(): return name + ": " + error
		var shader := rd.shader_create_from_spirv(spirv)
		var pipeline := rd.compute_pipeline_create(shader)
		if name.begins_with("inject"): shader_inject = shader; pipeline_inject = pipeline
		else: shader_filter = shader; pipeline_filter = pipeline
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = rd.sampler_create(state)
	var initial_status := PackedByteArray()
	initial_status.resize(16)
	validation = rd.storage_buffer_create(16, initial_status)
	for i in 4:
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.width = 64; format.height = 64; format.depth = 64
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		volumes.append(rd.texture_create(format, RDTextureView.new()))
	return ""

func clear() -> void:
	for volume in volumes: rd.texture_clear(volume, Color(0,0,0,0), 0, 1, 0, 1)
	var zeros := PackedByteArray()
	zeros.resize(16)
	rd.buffer_update(validation,0,16,zeros)

func uniform(kind: int, binding: int, ids: Array[RID]) -> RDUniform:
	var item := RDUniform.new()
	item.uniform_type = kind
	item.binding = binding
	for id in ids: item.add_id(id)
	return item

func inject(resolved: PackedByteArray, directions: PackedByteArray) -> String:
	if resolved.size() != 64*64*64*16 or directions.size() != resolved.size(): return "Expected finite resolved and direction vec4 buffers for every voxel"
	var r := rd.storage_buffer_create(resolved.size(), resolved)
	var d := rd.storage_buffer_create(directions.size(), directions)
	buffers.append(r); buffers.append(d)
	var uniforms: Array[RDUniform] = [uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,0,[r]),
		uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,1,[d]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,2,[volumes[0]]), uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,3,[volumes[1]]),
		uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,4,[validation])]
	var set := rd.uniform_set_create(uniforms, shader_inject, 0)
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands, pipeline_inject)
	rd.compute_list_bind_uniform_set(commands, set, 0)
	rd.compute_list_dispatch(commands, 16, 16, 16)
	rd.compute_list_end()
	rd.free_rid(set)
	return ""

func filter() -> void:
	for i in 2:
		var uniforms: Array[RDUniform] = [uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,0,[sampler,volumes[i]]),
			uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,[volumes[i+2]])]
		var set := rd.uniform_set_create(uniforms, shader_filter, 0)
		var commands := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(commands, pipeline_filter)
		rd.compute_list_bind_uniform_set(commands, set, 0)
		rd.compute_list_dispatch(commands, 16, 16, 16)
		rd.compute_list_end()
		rd.free_rid(set)

func release() -> void:
	for id in buffers + volumes: rd.free_rid(id)
	buffers.clear(); volumes.clear()
	for id in [validation, sampler, pipeline_inject, pipeline_filter, shader_inject, shader_filter]:
		if id.is_valid(): rd.free_rid(id)
