extends CompositorEffect
signal failed(message: String)
var report: Dictionary = {"status":"initializing","frames":0}
var _rd: RenderingDevice
var _lock := Mutex.new()
var _mesh: Dictionary = {}
var _groups: Array = []
var _shader := RID()
var _compute_shader := RID()
var _pipeline := RID()
var _compute_pipeline := RID()
var _vertex_buffer := RID()
var _index_buffer := RID()
var _vertex_array := RID()
var _index_array := RID()
var _vertex_format := 0
var _repeat := RID()
var _nearest := RID()
var _layer := RID()
var _framebuffer := RID()
var _size := Vector2i.ZERO
var _resources: Dictionary = {}
var _capture_requested := false
var _capture: Dictionary = {}
var _capture_before := RID()
var _capture_after := RID()
var _capture_size := Vector2i.ZERO

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_initialize)

func configure_mesh(mesh: Mesh) -> Dictionary:
	if mesh==null or mesh.get_surface_count()!=1: return {"error":"Expected existing one-surface Blender quad."}
	var arrays := mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if positions.is_empty() or positions.size()!=uvs.size() or indices.is_empty(): return {"error":"No geometry may be synthesized."}
	var data := PackedFloat32Array()
	for i in positions.size(): data.append_array(PackedFloat32Array([positions[i].x,positions[i].y,positions[i].z,uvs[i].x,uvs[i].y]))
	_lock.lock()
	_mesh={"vertices":data.to_byte_array(),"indices":indices.to_byte_array(),"vertex_count":positions.size(),"index_count":indices.size()}
	_lock.unlock()
	return {"vertices":positions.size(),"indices":indices.size(),"vertex_sha256":data.to_byte_array().hex_encode().sha256_text(),"index_sha256":indices.to_byte_array().hex_encode().sha256_text()}

func submit(groups: Array) -> void:
	_lock.lock()
	_groups=groups
	_lock.unlock()

func request_capture() -> void:
	_lock.lock()
	_capture={}
	_capture_requested=true
	_lock.unlock()

func take_capture() -> Dictionary:
	_lock.lock()
	var result := _capture
	_capture={}
	_lock.unlock()
	return result

func _fail(message: String) -> void:
	report.status="failed"
	report.error=message
	enabled=false
	_notify_failure.call_deferred(message)

func _notify_failure(message: String) -> void:
	failed.emit(message)

func _compile(vertex: String, fragment: String, compute: String) -> RID:
	var source := RDShaderSource.new()
	var folder: String = get_script().resource_path.get_base_dir()
	var stages: Array[int]
	if not report.has("shader_source_sha256"):report.shader_source_sha256={}
	if compute.is_empty():
		source.source_vertex=FileAccess.get_file_as_string(folder.path_join(vertex))
		source.source_fragment=FileAccess.get_file_as_string(folder.path_join(fragment))
		report.shader_source_sha256[vertex]=source.source_vertex.sha256_text()
		report.shader_source_sha256[fragment]=source.source_fragment.sha256_text()
		stages=[RenderingDevice.SHADER_STAGE_VERTEX,RenderingDevice.SHADER_STAGE_FRAGMENT]
	else:
		source.source_compute=FileAccess.get_file_as_string(folder.path_join(compute))
		report.shader_source_sha256[compute]=source.source_compute.sha256_text()
		stages=[RenderingDevice.SHADER_STAGE_COMPUTE]
	var spirv := _rd.shader_compile_spirv_from_source(source)
	for stage in stages:
		var error := spirv.get_stage_compile_error(stage)
		if not error.is_empty():
			_fail(error)
			return RID()
	var shader := _rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():_fail("Separate shader creation returned an invalid RID.")
	return shader

func _initialize() -> void:
	_rd=RenderingServer.get_rendering_device()
	if _rd==null:
		_fail("Forward+ RenderingDevice required.")
		return
	_shader=_compile("separate.vert.glsl.txt","separate.frag.glsl.txt","")
	_compute_shader=_compile("","","composite.glsl.txt")
	if not _shader.is_valid() or not _compute_shader.is_valid(): return
	_compute_pipeline=_rd.compute_pipeline_create(_compute_shader)
	if not _compute_pipeline.is_valid():
		_fail("Separate composite compute pipeline creation failed.")
		return
	var sampler := RDSamplerState.new()
	sampler.min_filter=RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter=RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mip_filter=RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u=RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.repeat_v=RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.max_lod=1000.0
	_repeat=_rd.sampler_create(sampler)
	sampler=RDSamplerState.new()
	sampler.repeat_u=RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_v=RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_nearest=_rd.sampler_create(sampler)
	if not _repeat.is_valid() or not _nearest.is_valid():
		_fail("Separate texture sampler creation failed.")
		return
	report.status="ready"

func _mesh_ready(payload: Dictionary) -> bool:
	if _vertex_array.is_valid(): return true
	if payload.is_empty():
		_fail("Existing source mesh upload payload is empty.")
		return false
	_vertex_buffer=_rd.vertex_buffer_create(payload.vertices.size(),payload.vertices)
	_index_buffer=_rd.index_buffer_create(payload.index_count,RenderingDevice.INDEX_BUFFER_FORMAT_UINT32,payload.indices)
	if not _vertex_buffer.is_valid() or not _index_buffer.is_valid():
		_fail("Existing source mesh buffer upload failed.")
		return false
	var pos := RDVertexAttribute.new()
	pos.location=0
	pos.format=RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	pos.stride=20
	var uv := RDVertexAttribute.new()
	uv.location=1
	uv.format=RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	uv.offset=12
	uv.stride=20
	_vertex_format=_rd.vertex_format_create([pos,uv])
	_vertex_array=_rd.vertex_array_create(payload.vertex_count,_vertex_format,[_vertex_buffer,_vertex_buffer])
	_index_array=_rd.index_array_create(_index_buffer,0,payload.index_count)
	if not _vertex_array.is_valid() or not _index_array.is_valid():
		_fail("Existing source mesh vertex/index array creation failed.")
		return false
	return true

func _targets(size: Vector2i) -> void:
	if size!=_size:
		if _layer.is_valid(): _rd.free_rid(_layer)
		_size=size
		var format := RDTextureFormat.new()
		format.width=size.x
		format.height=size.y
		format.format=RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.usage_bits=RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT|RenderingDevice.TEXTURE_USAGE_STORAGE_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		_layer=_rd.texture_create(format,RDTextureView.new())
		_framebuffer=_rd.framebuffer_create([_layer])
		if not _layer.is_valid() or not _framebuffer.is_valid():
			_fail("Separate RGBA16F target/framebuffer creation failed.")
			return
	if not _pipeline.is_valid():
		var attachment := RDPipelineColorBlendStateAttachment.new()
		attachment.enable_blend=true
		attachment.src_color_blend_factor=RenderingDevice.BLEND_FACTOR_SRC_ALPHA
		attachment.dst_color_blend_factor=RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		attachment.src_alpha_blend_factor=RenderingDevice.BLEND_FACTOR_ONE
		attachment.dst_alpha_blend_factor=RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		var blend := RDPipelineColorBlendState.new()
		blend.attachments=[attachment]
		var raster := RDPipelineRasterizationState.new()
		raster.cull_mode=RenderingDevice.POLYGON_CULL_DISABLED
		_pipeline=_rd.render_pipeline_create(_shader,_rd.framebuffer_get_format(_framebuffer),_vertex_format,RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,raster,RDPipelineMultisampleState.new(),RDPipelineDepthStencilState.new(),blend)
		if not _pipeline.is_valid(): _fail("Separate source raster pipeline creation failed.")

func _uniform(binding: int, kind: int, ids: Array[RID]) -> RDUniform:
	var result := RDUniform.new()
	result.binding=binding
	result.uniform_type=kind
	for id in ids: result.add_id(id)
	return result

func _diagnostic_targets(size: Vector2i) -> void:
	if _capture_size==size: return
	for id in [_capture_before,_capture_after]:
		if id.is_valid(): _rd.free_rid(id)
	var format := RDTextureFormat.new()
	format.width=size.x
	format.height=size.y
	format.format=RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_capture_before=_rd.texture_create(format,RDTextureView.new())
	_capture_after=_rd.texture_create(format,RDTextureView.new())
	if not _capture_before.is_valid() or not _capture_after.is_valid():
		_fail("Separate diagnostic texture allocation failed.")
		return
	_capture_size=size

func _matrix(data: PackedFloat32Array,p: Projection) -> void:
	for v in [p.x,p.y,p.z,p.w]: data.append_array(PackedFloat32Array([v.x,v.y,v.z,v.w]))

func _prepare(group: Dictionary, scene: RenderSceneData, size: Vector2i, depth: RID) -> RID:
	var id: int=group.id
	if not _resources.has(id): _resources[id]={"frame":_rd.uniform_buffer_create(400),"instances":RID(),"capacity":0}
	var resources: Dictionary=_resources[id]
	if not resources.frame.is_valid():
		_fail("Separate material frame uniform buffer allocation failed.")
		return RID()
	var bytes: PackedByteArray=group.instances
	if bytes.size()>int(resources.capacity):
		if resources.instances.is_valid(): _rd.free_rid(resources.instances)
		resources.capacity=maxi(bytes.size(),int(resources.capacity)*2)
		resources.instances=_rd.storage_buffer_create(resources.capacity)
	if not resources.instances.is_valid():
		_fail("Separate source instance storage buffer allocation failed.")
		return RID()
	_rd.buffer_update(resources.instances,0,bytes.size(),bytes)
	var projection := scene.get_view_projection(0)
	var camera := scene.get_cam_transform()
	var data := PackedFloat32Array()
	_matrix(data,projection)
	_matrix(data,projection.inverse())
	_matrix(data,Projection(camera.affine_inverse()))
	_matrix(data,Projection(camera))
	data.append_array(PackedFloat32Array([size.x,size.y,0,0]))
	data.append_array(group.parameters)
	assert(data.size()==100)
	_rd.buffer_update(resources.frame,0,400,data.to_byte_array())
	if group.texture==null or not is_instance_valid(group.texture):
		_fail("Source texture resource is missing.")
		return RID()
	var texture := RenderingServer.texture_get_rd_texture(group.texture.get_rid(),true)
	if not texture.is_valid():
		_fail("Source sRGB texture unavailable.")
		return RID()
	var uniform := UniformSetCacheRD.get_cache(_shader,0,[_uniform(0,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[resources.instances]),_uniform(1,RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,[resources.frame]),_uniform(2,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_repeat,texture]),_uniform(3,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_nearest,depth])])
	if not uniform.is_valid():_fail("Separate source raster uniform set creation failed.")
	return uniform

func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind!=EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or report.status!="ready": return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	if buffers==null or scene==null:
		_fail("Separate callback is missing its source scene data or RD buffers.")
		return
	if buffers.get_view_count()!=1:
		_fail("Only source single-view path supported.")
		return
	var size := buffers.get_internal_size()
	if size.x<=0 or size.y<=0: return
	_lock.lock()
	var groups := _groups
	var mesh := _mesh
	var capture := _capture_requested
	_capture_requested=false
	_lock.unlock()
	if not _mesh_ready(mesh): return
	_targets(size)
	if report.status!="ready" or not _pipeline.is_valid(): return
	var color := buffers.get_color_layer(0)
	var depth := buffers.get_depth_layer(0)
	if not color.is_valid() or not depth.is_valid():
		_fail("Separate callback is missing source HDR color or opaque depth.")
		return
	var prepared: Array = []
	var particles := 0
	for group in groups:
		if group.count==0: continue
		var uniform := _prepare(group,scene,size,depth)
		if not uniform.is_valid(): return
		prepared.append({"uniform":uniform,"count":group.count})
		particles+=group.count
	# Scene color may not have CAN_COPY_FROM. Copy during the audited compute operation.
	_diagnostic_targets(size if capture else (_capture_size if _capture_size!=Vector2i.ZERO else Vector2i.ONE))
	if report.status!="ready":return
	var draw := _rd.draw_list_begin(_framebuffer,RenderingDevice.DRAW_CLEAR_COLOR_ALL,PackedColorArray([Color(0,0,0,0)]))
	_rd.draw_list_bind_render_pipeline(draw,_pipeline)
	_rd.draw_list_bind_vertex_array(draw,_vertex_array)
	_rd.draw_list_bind_index_array(draw,_index_array)
	for group in prepared:
		_rd.draw_list_bind_uniform_set(draw,group.uniform,0)
		_rd.draw_list_draw(draw,true,group.count)
	_rd.draw_list_end()
	var uniform := UniformSetCacheRD.get_cache(_compute_shader,0,[_uniform(0,RenderingDevice.UNIFORM_TYPE_IMAGE,[color]),_uniform(1,RenderingDevice.UNIFORM_TYPE_IMAGE,[_layer]),_uniform(2,RenderingDevice.UNIFORM_TYPE_IMAGE,[_capture_before]),_uniform(3,RenderingDevice.UNIFORM_TYPE_IMAGE,[_capture_after])])
	if not uniform.is_valid():
		_fail("Separate composite uniform set creation failed.")
		return
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0,size.x)
	push.encode_s32(4,size.y)
	push.encode_s32(8,1 if capture else 0)
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_compute_pipeline)
	_rd.compute_list_bind_uniform_set(commands,uniform,0)
	_rd.compute_list_set_push_constant(commands,push,push.size())
	_rd.compute_list_dispatch(commands,ceili(size.x/8.0),ceili(size.y/8.0),1)
	_rd.compute_list_end()
	report.frames=int(report.frames)+1
	report.particles=particles
	report.groups=prepared.size()
	report.size=[size.x,size.y]
	if capture:
		var result := {"width":size.x,"height":size.y,"particles":particles,"groups":prepared.size(),"before_rgba16f":_rd.texture_get_data(_capture_before,0),"layer_rgba16f":_rd.texture_get_data(_layer,0),"after_rgba16f":_rd.texture_get_data(_capture_after,0)}
		# Diagnostic only: preserve full data and require the verified 4.7.2 float layout.
		var scene_ubo_full: PackedByteArray = _rd.buffer_get_data(scene.get_uniform_buffer())
		var scene_clock: PackedByteArray = scene_ubo_full.slice(2816,2832) if scene_ubo_full.size()==5696 else PackedByteArray()
		result.scene_ubo_full=scene_ubo_full
		result.scene_ubo_size=scene_ubo_full.size()
		result.scene_time_offset=2816
		result.scene_ubo_layout="godot-4.7.2-float-2848x2" if scene_ubo_full.size()==5696 else "unsupported"
		result.scene_time_ubo=scene_clock
		result.scene_shader_time=scene_clock.decode_float(0) if scene_clock.size()==16 else -1.0
		result.scene_taa_frame_count=scene_clock.decode_float(4) if scene_clock.size()==16 else -1.0
		_lock.lock()
		_capture=result
		_lock.unlock()

static func _release(rd: RenderingDevice, ids: Array[RID]) -> void:
	for id in ids:
		if id.is_valid(): rd.free_rid(id)

func _notification(what: int) -> void:
	if what==NOTIFICATION_PREDELETE and _rd!=null:
		var ids: Array[RID]=[_vertex_buffer,_index_buffer,_repeat,_nearest,_layer,_capture_before,_capture_after,_pipeline,_compute_pipeline,_shader,_compute_shader]
		for resources in _resources.values():
			ids.append(resources.frame)
			ids.append(resources.instances)
		RenderingServer.call_on_render_thread(_release.bind(_rd,ids))
