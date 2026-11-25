extends CompositorEffect
## Install before Bloom and Film. Main-thread binder supplies original mesh/instance data.
const ROOT := "res://native_distortion_candidate/"
var water_pass: RefCounted = preload("res://source_water_distortion_candidate/water_accumulation_pass.gd").new()
var _rd: RenderingDevice
var _lock := Mutex.new()
var _mesh_payload: Dictionary = {}
var _snapshot := PackedByteArray()
var _count := 0
var _textures: Array[Texture2D] = []
var _angle_sign := 1.0
var _audit_mode := 0
var _native_mip_bias := 0.0
var _raster_shader := RID()
var _copy_shader := RID()
var _apply_shader := RID()
var _raster_pipeline := RID()
var _copy_pipeline := RID()
var _apply_pipeline := RID()
var _vertex_buffer := RID()
var _index_buffer := RID()
var _vertex_array := RID()
var _index_array := RID()
var _vertex_format := 0
var _instances := RID()
var _instance_capacity := 0
var _frame := RID()
var _repeat_sampler := RID()
var _point_sampler := RID()
var _linear_sampler := RID()
var _accumulation := RID()
var _scene_copy := RID()
var _framebuffer := RID()
var _size := Vector2i.ZERO
var _unsupported_reported := false
var _validation_requested := false
var _validation_capture: Dictionary = {}
var _validation_output := RID()

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_initialize)

func configure_original_mesh(mesh: Mesh, textures: Array[Texture2D]) -> bool:
	if mesh == null or mesh.get_surface_count() != 1 or textures.size() != 4:
		push_error("Native distortion requires the existing one-surface Blender particle mesh and four original textures.")
		return false
	var arrays := mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if positions.is_empty() or positions.size() != uvs.size() or indices.is_empty():
		push_error("Native distortion will not synthesize missing mesh data.")
		return false
	var vertices := PackedFloat32Array()
	for i in positions.size():
		vertices.append_array(PackedFloat32Array([positions[i].x, positions[i].y, positions[i].z, uvs[i].x, uvs[i].y]))
	_lock.lock()
	_mesh_payload = {"vertices": vertices.to_byte_array(), "indices": indices.to_byte_array(), "vertex_count": positions.size(), "index_count": indices.size()}
	_textures = textures
	_lock.unlock()
	return true

func submit_source_instances(data: PackedFloat32Array, count: int) -> void:
	assert(data.size() == count * 12)
	_lock.lock()
	_snapshot = data.to_byte_array()
	_count = count
	_lock.unlock()

func set_main_pass_angle_sign(value: float) -> void:
	# 1 matches the existing main shader; -1 only with the paired source-rotation fix.
	_lock.lock()
	_angle_sign = value
	_lock.unlock()

func set_audit_mode(value: int) -> void:
	_lock.lock()
	_audit_mode = value
	_lock.unlock()

func set_native_mip_bias(value: float) -> void:
	_lock.lock()
	_native_mip_bias = value
	_lock.unlock()

func request_validation_capture() -> void:
	# Explicit one-shot debug readback only. Not part of the ordinary render path.
	_lock.lock()
	_validation_capture = {}
	_validation_requested = true
	_lock.unlock()

func take_validation_capture() -> Dictionary:
	_lock.lock()
	var result := _validation_capture
	_validation_capture = {}
	_lock.unlock()
	return result

func _compile(vertex_file: String, fragment_file: String, compute_file: String) -> RID:
	var source := RDShaderSource.new()
	var stages: Array[int] = []
	if not vertex_file.is_empty():
		source.source_vertex = FileAccess.get_file_as_string(ROOT + vertex_file)
		source.source_fragment = FileAccess.get_file_as_string(ROOT + fragment_file)
		stages = [RenderingDevice.SHADER_STAGE_VERTEX, RenderingDevice.SHADER_STAGE_FRAGMENT]
	else:
		source.source_compute = FileAccess.get_file_as_string(ROOT + compute_file)
		stages = [RenderingDevice.SHADER_STAGE_COMPUTE]
	var spirv := _rd.shader_compile_spirv_from_source(source)
	for stage in stages:
		var error := spirv.get_stage_compile_error(stage)
		if not error.is_empty():
			push_error("Native distortion compile: " + error)
			return RID()
	return _rd.shader_create_from_spirv(spirv)

func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("Native distortion needs the RD Forward+ renderer.")
		return
	_raster_shader = _compile("splash_accumulate.vert.glsl.txt", "splash_accumulate.frag.glsl.txt", "")
	_copy_shader = _compile("", "", "copy_scene.glsl.txt")
	_apply_shader = _compile("", "", "apply_distortion.glsl.txt")
	if not _raster_shader.is_valid() or not _copy_shader.is_valid() or not _apply_shader.is_valid():
		return
	_copy_pipeline = _rd.compute_pipeline_create(_copy_shader)
	_apply_pipeline = _rd.compute_pipeline_create(_apply_shader)
	_frame = _rd.uniform_buffer_create(224)
	var repeat_state := RDSamplerState.new()
	repeat_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	repeat_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	repeat_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	repeat_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	repeat_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	repeat_state.max_lod = 1000.0
	_repeat_sampler = _rd.sampler_create(repeat_state)
	var point_state := RDSamplerState.new()
	point_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	point_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_point_sampler = _rd.sampler_create(point_state)
	var linear_state := RDSamplerState.new()
	linear_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear_sampler = _rd.sampler_create(linear_state)

func _ensure_mesh(payload: Dictionary) -> bool:
	if _vertex_array.is_valid():
		return true
	if payload.is_empty():
		return false
	var vertices: PackedByteArray = payload["vertices"]
	var indices: PackedByteArray = payload["indices"]
	_vertex_buffer = _rd.vertex_buffer_create(vertices.size(), vertices)
	_index_buffer = _rd.index_buffer_create(int(payload["index_count"]), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, indices)
	var position := RDVertexAttribute.new()
	position.location = 0
	position.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	position.stride = 20
	var uv := RDVertexAttribute.new()
	uv.location = 1
	uv.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	uv.offset = 12
	uv.stride = 20
	_vertex_format = _rd.vertex_format_create([position, uv])
	_vertex_array = _rd.vertex_array_create(int(payload["vertex_count"]), _vertex_format, [_vertex_buffer, _vertex_buffer])
	_index_array = _rd.index_array_create(_index_buffer, 0, int(payload["index_count"]))
	return _vertex_array.is_valid() and _index_array.is_valid()

func _ensure_targets(size: Vector2i) -> void:
	if size == _size:
		_ensure_splash_pipeline()
		return
	if _accumulation.is_valid():
		_rd.free_rid(_accumulation) # also invalidates its framebuffer
	if _scene_copy.is_valid():
		_rd.free_rid(_scene_copy)
	if _validation_output.is_valid():
		_rd.free_rid(_validation_output)
		_validation_output = RID()
	_size = size
	var format := RDTextureFormat.new()
	format.width = size.x
	format.height = size.y
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_accumulation = _rd.texture_create(format, RDTextureView.new())
	_framebuffer = _rd.framebuffer_create([_accumulation])
	format = RDTextureFormat.new()
	format.width = size.x
	format.height = size.y
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_scene_copy = _rd.texture_create(format, RDTextureView.new())
	_ensure_splash_pipeline()

func _ensure_splash_pipeline() -> void:
	if not _raster_pipeline.is_valid() and _vertex_array.is_valid():
		var attachment := RDPipelineColorBlendStateAttachment.new()
		attachment.enable_blend = true
		attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
		attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
		var blend := RDPipelineColorBlendState.new()
		blend.attachments = [attachment]
		var raster := RDPipelineRasterizationState.new()
		raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
		_raster_pipeline = _rd.render_pipeline_create(_raster_shader, _rd.framebuffer_get_format(_framebuffer), _vertex_format, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend)

func _uniform(type: int, binding: int, ids: Array[RID]) -> RDUniform:
	var value := RDUniform.new()
	value.uniform_type = type
	value.binding = binding
	for id in ids:
		value.add_id(id)
	return value

func _append_projection(data: PackedFloat32Array, p: Projection) -> void:
	for v in [p.x, p.y, p.z, p.w]:
		data.append_array(PackedFloat32Array([v.x, v.y, v.z, v.w]))

func _compute(pipeline: RID, uniform_set: RID, push: PackedByteArray, size: Vector2i) -> void:
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands, pipeline)
	_rd.compute_list_bind_uniform_set(commands, uniform_set, 0)
	_rd.compute_list_set_push_constant(commands, push, push.size())
	_rd.compute_list_dispatch(commands, ceili(float(size.x)/8.0), ceili(float(size.y)/8.0), 1)
	_rd.compute_list_end()

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null or not _copy_pipeline.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	if buffers == null or scene == null:
		return
	if buffers.get_view_count() != 1:
		if not _unsupported_reported:
			push_error("Native distortion candidate currently supports the original single desktop view only.")
			_unsupported_reported = true
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	_lock.lock()
	var payload := _mesh_payload
	var snapshot := _snapshot
	var count := _count
	var textures := _textures
	var angle_sign := _angle_sign
	var audit := _audit_mode
	var mip_bias := _native_mip_bias
	var validation_requested := _validation_requested
	_validation_requested = false
	_lock.unlock()
	var has_splash := count > 0 and _ensure_mesh(payload)
	var has_water: bool = water_pass.active()
	if not has_splash and not has_water:
		return
	_ensure_targets(size)
	if has_splash and not _raster_pipeline.is_valid():
		return
	if has_splash and snapshot.size() > _instance_capacity:
		if _instances.is_valid():
			_rd.free_rid(_instances)
		_instance_capacity = maxi(snapshot.size(), _instance_capacity * 2)
		_instances = _rd.storage_buffer_create(_instance_capacity)
	if has_splash: _rd.buffer_update(_instances, 0, snapshot.size(), snapshot)
	var projection := scene.get_view_projection(0)
	var camera := scene.get_cam_transform()
	var output_size := buffers.get_target_size()
	var frame_data := PackedFloat32Array()
	_append_projection(frame_data, projection)
	_append_projection(frame_data, projection.inverse())
	_append_projection(frame_data, Projection(camera.affine_inverse()))
	frame_data.append_array(PackedFloat32Array([size.x, size.y, output_size.x, output_size.y, 700.0, 0.0, mip_bias, angle_sign]))
	_rd.buffer_update(_frame, 0, 224, frame_data.to_byte_array())
	var depth := buffers.get_depth_layer(0)
	var color := buffers.get_color_layer(0)
	var raster_set := RID()
	if has_splash:
		var raster_uniforms: Array[RDUniform] = [_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_instances]), _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 1, [_frame])]
		for i in 4:
			var texture := RenderingServer.texture_get_rd_texture(textures[i].get_rid(), i < 2)
			if not texture.is_valid():
				return
			raster_uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2+i, [_repeat_sampler, texture]))
		raster_uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6, [_point_sampler, depth]))
		raster_set = UniformSetCacheRD.get_cache(_raster_shader, 0, raster_uniforms)
	var water_set: RID = water_pass.prepare(_rd, _framebuffer, scene, size, output_size, depth, _repeat_sampler, _point_sampler) if has_water else RID()
	var draw := _rd.draw_list_begin(_framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_ALL, PackedColorArray([Color(0,0,0,0)]))
	if has_splash:
		_rd.draw_list_bind_render_pipeline(draw, _raster_pipeline)
		_rd.draw_list_bind_uniform_set(draw, raster_set, 0)
		_rd.draw_list_bind_vertex_array(draw, _vertex_array)
		_rd.draw_list_bind_index_array(draw, _index_array)
		_rd.draw_list_draw(draw, true, count)
	water_pass.draw(draw, water_set)
	_rd.draw_list_end()
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, size.x)
	push.encode_s32(4, size.y)
	push.encode_s32(8, audit)
	var copy_set := UniformSetCacheRD.get_cache(_copy_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]), _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_scene_copy])])
	_compute(_copy_pipeline, copy_set, push, size)
	var apply_set := UniformSetCacheRD.get_cache(_apply_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_linear_sampler, _scene_copy]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_point_sampler, _accumulation]), _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [color])])
	_compute(_apply_pipeline, apply_set, push, size)
	if validation_requested:
		if not _validation_output.is_valid():
			var output_format := RDTextureFormat.new()
			output_format.width = size.x
			output_format.height = size.y
			output_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
			output_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
			_validation_output = _rd.texture_create(output_format, RDTextureView.new())
		var output_set := UniformSetCacheRD.get_cache(_copy_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]), _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_validation_output])])
		_compute(_copy_pipeline, output_set, push, size)
		var capture := {"width": size.x, "height": size.y, "output_width": output_size.x, "output_height": output_size.y, "particle_count": count, "audit_mode": audit, "angle_sign": angle_sign, "native_mip_bias": mip_bias, "frame_rgba32f": frame_data.to_byte_array(), "instances_rgba32f": snapshot}
		capture["water_active"] = has_water
		capture["water_uniform_set_valid"] = water_set.is_valid()
		capture["water_frame_rgba32f"] = water_pass.last_frame
		capture["scene_time_ubo"] = _rd.buffer_get_data(scene.get_uniform_buffer(), 2832, 16) if has_water else PackedByteArray()
		capture["before_rgba16f"] = _rd.texture_get_data(_scene_copy, 0)
		capture["accumulation_rgba8"] = _rd.texture_get_data(_accumulation, 0)
		capture["after_rgba16f"] = _rd.texture_get_data(_validation_output, 0)
		_lock.lock()
		_validation_capture = capture
		_lock.unlock()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		water_pass.release(_rd)
		for id in [_vertex_buffer, _index_buffer, _instances, _frame, _accumulation, _scene_copy, _validation_output, _repeat_sampler, _point_sampler, _linear_sampler, _raster_shader, _copy_shader, _apply_shader]:
			if id.is_valid():
				_rd.free_rid(id)
