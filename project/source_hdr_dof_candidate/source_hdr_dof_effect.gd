extends CompositorEffect
signal diagnostic_ready(metadata: Dictionary)
signal failed(message: String)
## Scene-linear HDR DOF before source Bloom/Film; Godot 4.7.2 circle adaptation.

var report: Dictionary = {"status":"unconfigured","frames":0}
var last_diagnostic: Dictionary = {}
var _rd: RenderingDevice
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _nearest := RID()
var _linear := RID()
var _coc := RID()
var _bokeh := RID()
var _parameters := RID()
var _diagnostic_dummy := RID()
var _diagnostic_active := RID()
var _allocated_size := Vector2i.ZERO
var _policy: Dictionary = {}
var _source := ""
var _inside := false
var _mutex := Mutex.new()
var _diagnostic_request: Dictionary = {}
var _diagnostic_busy := false

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true

func configure(policy_path: String) -> Dictionary:
	if not _policy.is_empty(): return {"error":"Already configured."}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(policy_path))
	if not parsed is Dictionary or parsed.get("schema","")!="source_dof_v1":
		return {"error":"Invalid source DOF policy."}
	_source = FileAccess.get_file_as_string(get_script().resource_path.get_base_dir().path_join("source_hdr_dof_compute.glsl.txt"))
	if _source.is_empty(): return {"error":"Missing adjacent HDR DOF compute shader."}
	_policy = parsed
	report = {"status":"initializing","frames":0,
		"stage":"POST_TRANSPARENT before source Bloom and Film",
		"kernel":"Godot 4.7.2 circular half-resolution gather; HIGH radial scale .5; deterministic",
		"limits":["Not UE Diaphragm gather/scatter/recombine.",
			"Source CoC clamped to .025W; gather support remains32px.",
			"Transparent layers currently use shared scene depth; original SeparateTranslucency is not reproduced.",
			"Half-size flooring and sampling offsets follow Godot, including odd dimensions.",
			"Shader and runtime require parent GPU validation."]}
	RenderingServer.call_on_render_thread(_initialize)
	return report

func set_source_indoor(value: bool) -> void:
	_mutex.lock()
	_inside = value
	_mutex.unlock()

func request_diagnostic(directory: String, stride: int = 4) -> Dictionary:
	if directory.is_empty(): return {"error":"Expected output directory."}
	_mutex.lock()
	if _diagnostic_busy:
		_mutex.unlock()
		return {"error":"Diagnostic already pending."}
	_diagnostic_busy = true
	_diagnostic_request = {"directory":directory,"stride":maxi(stride,1)}
	_mutex.unlock()
	return {"queued":true,"directory":directory,"stride":maxi(stride,1)}

func _fail(message: String) -> void:
	report.status = "error"
	report.error = message
	enabled = false
	push_error("Source HDR DOF: "+message)
	_notify_failure.call_deferred(message)

func _notify_failure(message: String) -> void:
	failed.emit(message)

func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd==null:
		_fail("Forward+ RenderingDevice required.")
		return
	for operation in 3:
		var source := RDShaderSource.new()
		source.source_compute = _source.replace("#version 450", "#version 450\n#define OPERATION %d" % operation)
		var spirv := _rd.shader_compile_spirv_from_source(source)
		var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not error.is_empty():
			_fail("Operation %d: %s" % [operation,error])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders.append(shader)
		var pipeline := _rd.compute_pipeline_create(shader)
		_pipelines.append(pipeline)
		if not shader.is_valid() or not pipeline.is_valid():
			_fail("Could not initialize operation %d." % operation)
			return
	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_nearest = _rd.sampler_create(sampler)
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_linear = _rd.sampler_create(sampler)
	_parameters = _rd.storage_buffer_create(112)
	_diagnostic_dummy = _rd.storage_buffer_create(48)
	report.status = "ready"
	print("SOURCE_HDR_DOF_READY ",JSON.stringify(report))

func _texture(size: Vector2i) -> RID:
	var format := RDTextureFormat.new()
	format.width = size.x
	format.height = size.y
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return _rd.texture_create(format,RDTextureView.new(),[])

func _targets(size: Vector2i) -> void:
	if size==_allocated_size: return
	if _coc.is_valid(): _rd.free_rid(_coc)
	if _bokeh.is_valid(): _rd.free_rid(_bokeh)
	_coc = _texture(size)
	_bokeh = _texture(Vector2i(maxi(1,size.x>>1),maxi(1,size.y>>1)))
	_allocated_size = size

func _uniform(binding: int, kind: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = binding
	uniform.uniform_type = kind
	for id in ids: uniform.add_id(id)
	return uniform

func _parameter_bytes(projection: Projection, size: Vector2i, inside: bool, diagnostic: Dictionary) -> PackedByteArray:
	var floats := PackedFloat32Array()
	var inverse := projection.inverse()
	for col in [inverse.x,inverse.y,inverse.z,inverse.w]:
		floats.append_array(PackedFloat32Array([col.x,col.y,col.z,col.w]))
	var state: Dictionary = _policy.interior if inside else _policy.exterior
	var sensor: float = _policy.sensor_width_mm
	var focus: float = state.focus_cm*.01
	var fstop: float = state.fstop
	var focal: float = sensor*.5*projection.x.x
	var radius: float = size.x*focal*focal/(2.0*sensor*fstop*(focus*1000.0-focal))
	var near_cap: float = size.x*float(_policy.max_foreground_radius_fraction)
	var far_cap: float = size.x*float(_policy.max_background_radius_fraction)
	floats.append_array(PackedFloat32Array([focus,radius,near_cap,far_cap,32.0,.5,0.0,0.0]))
	var bytes := floats.to_byte_array()
	bytes.resize(112)
	if not diagnostic.is_empty():
		bytes.encode_s32(96,1)
		bytes.encode_s32(100,int(diagnostic.stride))
		bytes.encode_s32(104,int(diagnostic.sample_size[0]))
		bytes.encode_s32(108,int(diagnostic.sample_size[1]))
	else:
		bytes.encode_s32(96,0)
		bytes.encode_s32(100,1)
	report.merge({"inside":inside,"internal_size":[size.x,size.y],"source_focus_m":focus,
		"source_fstop":fstop,"source_focal_mm":focal,"infinity_coc_radius_px":radius,
		"source_cap_px":[near_cap,far_cap],"gather_cap_px":32.0},true)
	return bytes

func _prepare_diagnostic(size: Vector2i) -> Dictionary:
	_mutex.lock()
	var request := _diagnostic_request.duplicate()
	_diagnostic_request.clear()
	_mutex.unlock()
	if request.is_empty(): return {}
	if _diagnostic_active.is_valid(): _rd.free_rid(_diagnostic_active)
	var stride: int = request.stride
	var sample_size := Vector2i(ceili(size.x/float(stride)),ceili(size.y/float(stride)))
	var payload: int = sample_size.x*sample_size.y*48
	_diagnostic_active = _rd.storage_buffer_create(payload)
	request.merge({"schema":"source_hdr_dof_diagnostic_v1","image_size":[size.x,size.y],
		"sample_size":[sample_size.x,sample_size.y],"record_shape":[sample_size.y,sample_size.x,3,4],
		"record_fields":["before_hdr_rgba","after_hdr_rgba","linear_depth_m_center_coc_bokeh_coc_mix"],
		"dtype":"little-endian float32","payload_bytes":payload,"frame":int(report.frames)+1})
	return request

func _dispatch(commands: int, uniforms: RID, size: Vector2i, operation: int) -> void:
	var push := PackedInt32Array([size.x,size.y,operation,0]).to_byte_array()
	_rd.compute_list_bind_compute_pipeline(commands,_pipelines[operation])
	_rd.compute_list_bind_uniform_set(commands,uniforms,0)
	_rd.compute_list_set_push_constant(commands,push,16)
	_rd.compute_list_dispatch(commands,ceili(size.x/8.0),ceili(size.y/8.0),1)
	_rd.compute_list_add_barrier(commands)

func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind!=EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd==null or report.status!="ready": return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	if buffers==null or scene==null or buffers.get_view_count()!=1:
		_fail("Expected one non-XR view.")
		return
	var size := buffers.get_internal_size()
	if size.x<=0 or size.y<=0: return
	var color := buffers.get_color_layer(0)
	var depth := buffers.get_depth_layer(0)
	if _rd.texture_get_format(color).format!=RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
		_fail("Expected RGBA16F scene-linear HDR color.")
		return
	_targets(size)
	var diagnostic := _prepare_diagnostic(size)
	_mutex.lock()
	var inside := _inside
	_mutex.unlock()
	var bytes := _parameter_bytes(scene.get_view_projection(0),size,inside,diagnostic)
	_rd.buffer_update(_parameters,0,112,bytes)
	var diagnostics := _diagnostic_dummy if diagnostic.is_empty() else _diagnostic_active
	# Each operation has disjoint scratch input/output bindings; no sampled/storage alias.
	var coc_uniforms := UniformSetCacheRD.get_cache(_shaders[0],0,[
		_uniform(0,RenderingDevice.UNIFORM_TYPE_IMAGE,[color]),
		_uniform(1,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_nearest,depth]),
		_uniform(4,RenderingDevice.UNIFORM_TYPE_IMAGE,[_coc]),
		_uniform(6,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_parameters])])
	var gather_uniforms := UniformSetCacheRD.get_cache(_shaders[1],0,[
		_uniform(2,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_linear,_coc]),
		_uniform(5,RenderingDevice.UNIFORM_TYPE_IMAGE,[_bokeh]),
		_uniform(6,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_parameters])])
	var recombine_uniforms := UniformSetCacheRD.get_cache(_shaders[2],0,[
		_uniform(0,RenderingDevice.UNIFORM_TYPE_IMAGE,[color]),
		_uniform(1,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_nearest,depth]),
		_uniform(2,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_linear,_coc]),
		_uniform(3,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_linear,_bokeh]),
		_uniform(6,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_parameters]),
		_uniform(7,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[diagnostics])])
	var commands := _rd.compute_list_begin()
	_dispatch(commands,coc_uniforms,size,0)
	_dispatch(commands,gather_uniforms,Vector2i(maxi(1,size.x>>1),maxi(1,size.y>>1)),1)
	_dispatch(commands,recombine_uniforms,size,2)
	_rd.compute_list_end()
	if not diagnostic.is_empty():
		diagnostic.parameters_f32 = Array(bytes.slice(0,96).to_float32_array())
		diagnostic.state = report.duplicate(true)
		var error := _rd.buffer_get_data_async(_diagnostic_active,_receive_diagnostic.bind(diagnostic),0,int(diagnostic.payload_bytes))
		if error!=OK:
			diagnostic.error = "Async readback failed: %s" % error
			_write_diagnostic.call_deferred(PackedByteArray(),diagnostic)
	report.frames = int(report.frames)+1

func _receive_diagnostic(bytes: PackedByteArray, metadata: Dictionary) -> void:
	_write_diagnostic.call_deferred(bytes,metadata)

func _write_diagnostic(bytes: PackedByteArray, metadata: Dictionary) -> void:
	var directory: String = metadata.directory
	if DirAccess.make_dir_recursive_absolute(directory)!=OK or bytes.size()!=int(metadata.payload_bytes):
		metadata.error = "Diagnostic directory/readback size error."
	else:
		var file := FileAccess.open(directory.path_join("samples.rgba32f"),FileAccess.WRITE)
		if file==null:
			metadata.error = "Cannot write diagnostic samples."
		else:
			file.store_buffer(bytes)
			file.close()
			metadata.complete = true
	var json := FileAccess.open(directory.path_join("capture.json"),FileAccess.WRITE)
	if json!=null:
		json.store_string(JSON.stringify(metadata,"\t"))
		json.close()
	_mutex.lock()
	last_diagnostic = metadata
	_diagnostic_busy = false
	_mutex.unlock()
	diagnostic_ready.emit(metadata)

static func _release(rd: RenderingDevice, ids: Array[RID]) -> void:
	for id in ids:
		if id.is_valid(): rd.free_rid(id)

func _notification(what: int) -> void:
	if what==NOTIFICATION_PREDELETE and _rd!=null:
		var ids: Array[RID] = [_diagnostic_active,_diagnostic_dummy,_parameters,_bokeh,_coc,_nearest,_linear]
		ids.append_array(_pipelines)
		ids.append_array(_shaders)
		RenderingServer.call_on_render_thread(_release.bind(_rd,ids))

