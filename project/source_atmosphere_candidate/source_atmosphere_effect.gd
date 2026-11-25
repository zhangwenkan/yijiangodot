extends CompositorEffect
signal diagnostic_ready(metadata: Dictionary)
## Original AtmosphericFog lookup tables, after opaque+sky and before transparency.
## Requires the source height-fog adapter already active, with matching policy.
## Source units and RGBA16F tables stay linear. No geometry/material edits.

var report: Dictionary = {"status":"unconfigured","frames":0}
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _nearest := RID()
var _linear := RID()
var _transmittance := RID()
var _irradiance := RID()
var _inscatter := RID()
var _parameters := RID()
var _diagnostic_dummy := RID()
var _diagnostic_active := RID()
var _diagnostic_request: Dictionary = {}
var _diagnostic_busy := false
var last_diagnostic: Dictionary = {}
var _policy: Dictionary = {}
var _height: Dictionary = {}
var _texture_data: Dictionary = {}
var _source := ""
var _sun_scale := 1.0
var _capture := false
var _mutex := Mutex.new()

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true

func configure(atmosphere_policy: String, height_policy: String, options: Dictionary = {}) -> Dictionary:
	if not _policy.is_empty(): return {"error":"Already configured"}
	var p: Variant = JSON.parse_string(FileAccess.get_file_as_string(atmosphere_policy))
	var h: Variant = JSON.parse_string(FileAccess.get_file_as_string(height_policy))
	if not p is Dictionary or p.get("schema","") != "source_atmosphere_v1":
		return {"error":"Invalid atmosphere policy"}
	if not h is Dictionary or h.get("schema","") != "source_height_fog_v1":
		return {"error":"Invalid source height-fog policy"}
	if p.map != h.map or int(p.get("precompute_counter",0)) != 2:
		return {"error":"Map mismatch or invalid source precompute"}
	_source = FileAccess.get_file_as_string(get_script().resource_path.get_base_dir().path_join("source_atmosphere_compute.glsl.txt"))
	if _source.is_empty(): return {"error":"Missing adjacent compute shader"}
	_policy = p
	_height = h
	_capture = bool(options.get("reflection_capture",false))
	for name in ["transmittance","irradiance","inscatter"]:
		var item: Dictionary = p.textures[name]
		var data := FileAccess.get_file_as_bytes(str(item.path))
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(data)
		if data.size() != int(item.size) or hash.finish().hex_encode() != str(item.sha256):
			_policy = {}
			return {"error":"Original texture byte count/SHA mismatch: "+name}
		_texture_data[name] = data
	report = {"status":"initializing","map":p.map,"frames":0,"reflection_capture":_capture,
		"stage":"PRE_TRANSPARENT: includes opaque and sky; excludes transparent material draws",
		"composition":"A.t*C_height + H.t*A.rgb + (1-A.t)*H.rgb",
		"source_texture_sha256":{},
		"limits":["Cross-engine candidate, requires GPU validation.",
			"Original LightShaftMask is not reconstructed.",
			"Requires same height-fog policy and no additional screen effect before this compositor.",
			"Camera projection/depth are Godot; original uses axial CalcSceneDepth.",
			"Source angle .5357000231742859 degrees is verified from shipping DirectionalLightComponent ctor."]}
	for name in p.textures: report.source_texture_sha256[name] = p.textures[name].sha256
	RenderingServer.call_on_render_thread(_initialize)
	return report

func set_source_sun_intensity(source_intensity: float) -> void:
	_mutex.lock()
	_sun_scale = maxf(source_intensity,0.0)/maxf(float(_policy.get("sun_intensity",30.0)),0.000001)
	_mutex.unlock()

func set_reflection_capture(value: bool) -> void:
	_mutex.lock()
	_capture = value
	_mutex.unlock()

## Captures one subsequent frame. Each sampled pixel contains six RGBA32F records:
## before HDR, after HDR (before RGBA16F store), world position + depth,
## atmosphere RGB + transmittance, heightfog RGB + transmittance,
## view position + finite-result flag. Default stride 4 limits diagnostic bandwidth.
func request_diagnostic(output_directory: String, stride: int = 4) -> Dictionary:
	if output_directory.is_empty(): return {"error":"Expected output directory."}
	_mutex.lock()
	if _diagnostic_busy:
		_mutex.unlock()
		return {"error":"A diagnostic capture is already pending."}
	_diagnostic_busy = true
	_diagnostic_request = {"directory":output_directory,"stride":maxi(stride,1)}
	_mutex.unlock()
	return {"queued":true,"directory":output_directory,"stride":maxi(stride,1)}

func _fail(message: String) -> void:
	report.status = "error"
	report.error = message
	enabled = false
	push_error("Source AtmosphericFog: "+message)

func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_fail("Forward+ RenderingDevice is required.")
		return
	var source := RDShaderSource.new()
	source.source_compute = _source
	var spirv := _rd.shader_compile_spirv_from_source(source)
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		_fail(error)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var nearest := RDSamplerState.new()
	nearest.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_nearest = _rd.sampler_create(nearest)
	var linear := RDSamplerState.new()
	linear.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear = _rd.sampler_create(linear)
	_transmittance = _texture("transmittance")
	_irradiance = _texture("irradiance")
	_inscatter = _texture("inscatter")
	_parameters = _rd.storage_buffer_create(320)
	_diagnostic_dummy = _rd.storage_buffer_create(16,PackedInt32Array([0,0,0,0]).to_byte_array())
	if not _transmittance.is_valid() or not _irradiance.is_valid() or not _inscatter.is_valid():
		_fail("Could not create exact source LUT textures.")
		return
	report.status = "ready"
	print("SOURCE_ATMOSPHERE_READY ",JSON.stringify(report))

func _texture(name: String) -> RID:
	var item: Dictionary = _policy.textures[name]
	var size: Array = item.dimensions
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D if size.size()==3 else RenderingDevice.TEXTURE_TYPE_2D
	format.width = int(size[0])
	format.height = int(size[1])
	format.depth = int(size[2]) if size.size()==3 else 1
	format.mipmaps = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var data: PackedByteArray = _texture_data[name].duplicate()
	if str(item.format) == "BGRA8":
		format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		for i in range(0,data.size(),4):
			var b := data[i]
			data[i] = data[i+2]
			data[i+2] = b
	else:
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	return _rd.texture_create(format,RDTextureView.new(),[data])

func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for col in [projection.x,projection.y,projection.z,projection.w]:
		values.append_array(PackedFloat32Array([col.x,col.y,col.z,col.w]))

func _append(values: PackedFloat32Array, row: Array) -> void:
	for value in row: values.append(float(value))

func _buffer(scene: RenderSceneData) -> PackedByteArray:
	var values := PackedFloat32Array()
	_append_projection(values,scene.get_view_projection(0).inverse())
	_append_projection(values,Projection(scene.get_cam_transform()))
	_mutex.lock()
	var sun_scale := _sun_scale
	var capture := _capture
	_mutex.unlock()
	_append(values,[_policy.sun_power,_policy.fog_power,_policy.inverse_density,_policy.density_offset])
	_append(values,[_policy.ground_offset_cm,_policy.distance_scale,_policy.altitude_scale,_policy.rayleigh_height_km])
	_append(values,[_policy.start_km,_policy.distance_offset_km,_policy.sun_half_angle_cos,1.0 if capture or bool(_policy.disable_sun_disk) else 0.0])
	var color: Array = _policy.sun_rgb_linear
	_append(values,[color[0],color[1],color[2],sun_scale])
	var direction: Array = _policy.sun_direction_ue
	_append(values,[direction[0],direction[1],direction[2],_policy.inscatter_altitude_samples])
	var disk: Array = _policy.sun_luminance_linear
	_append(values,[disk[0],disk[1],disk[2],1.0 if bool(_policy.disable_ground_scattering) else 0.0])
	for layer in _height.layers:
		_append(values,[layer.density_per_cm,layer.falloff_per_cm,layer.height_cm,0.0])
	color = _height.color_linear
	_append(values,[color[0],color[1],color[2],_height.max_opacity])
	direction = _height.direction_godot
	_append(values,[direction[0],direction[1],direction[2],_height.directional_exponent])
	color = _height.directional_color_linear
	_append(values,[color[0],color[1],color[2],_height.directional_start_cm])
	_append(values,[_height.start_cm,_height.cutoff_cm,_height.max_observer_height_cm,1.0 if bool(_height.directional_enabled) else 0.0])
	return values.to_byte_array()

func _uniform(binding: int, kind: int, ids: Array[RID]) -> RDUniform:
	var value := RDUniform.new()
	value.binding = binding
	value.uniform_type = kind
	for id in ids: value.add_id(id)
	return value

func _prepare_diagnostic(size: Vector2i, bytes: PackedByteArray) -> Dictionary:
	_mutex.lock()
	var request := _diagnostic_request.duplicate()
	_diagnostic_request.clear()
	_mutex.unlock()
	if request.is_empty(): return {}
	if _diagnostic_active.is_valid(): _rd.free_rid(_diagnostic_active)
	var stride: int = request.stride
	var sample_size := Vector2i(ceili(size.x/float(stride)),ceili(size.y/float(stride)))
	var payload_size := sample_size.x*sample_size.y*96
	_diagnostic_active = _rd.storage_buffer_create(16+payload_size)
	_rd.buffer_update(_diagnostic_active,0,16,PackedInt32Array([1,stride,sample_size.x,sample_size.y]).to_byte_array())
	var parameters := bytes.to_float32_array()
	request.merge({"schema":"source_atmosphere_diagnostic_v1","map":_policy.map,
		"image_size":[size.x,size.y],"sample_size":[sample_size.x,sample_size.y],
		"sample_origin":[0,0],"sample_uv":"(sample_xy*stride+0.5)/image_size",
		"dtype":"little-endian float32","record_shape":[sample_size.y,sample_size.x,6,4],
		"record_fields":["before_hdr_rgba","after_hdr_rgba_pre_half_store","world_position_xyz_depth","atmosphere_rgb_transmittance","heightfog_rgb_transmittance","view_position_xyz_finite_flag"],
		"payload_bytes":payload_size,"parameter_f32":Array(parameters),
		"projection":"inverse get_view_projection(0); Godot already applies Vulkan depth/Y correction and TAA jitter",
		"position_units":"Godot metres; depth<=0 is sky and position is ray proxy at depth 1e-6, not a surface",
		"frame":int(report.frames)+1})
	return request

func _receive_diagnostic(data: PackedByteArray, metadata: Dictionary) -> void:
	_write_diagnostic.call_deferred(data,metadata)

func _write_diagnostic(data: PackedByteArray, metadata: Dictionary) -> void:
	var path: String = metadata.directory
	var error := DirAccess.make_dir_recursive_absolute(path)
	if error!=OK or data.size()!=int(metadata.payload_bytes):
		metadata.error = "Cannot save diagnostic directory or readback size mismatch."
	else:
		var file := FileAccess.open(path.path_join("samples.rgba32f"),FileAccess.WRITE)
		if file==null:
			metadata.error = "Cannot write diagnostic float data."
		else:
			file.store_buffer(data)
			file.close()
			metadata.samples_file = path.path_join("samples.rgba32f")
			metadata.complete = true
			var json := FileAccess.open(path.path_join("capture.json"),FileAccess.WRITE)
			if json!=null:
				json.store_string(JSON.stringify(metadata,"\t"))
				json.close()
			else:
				metadata.error = "Cannot write diagnostic metadata."
				metadata.complete = false
	_mutex.lock()
	last_diagnostic = metadata
	_diagnostic_busy = false
	_mutex.unlock()
	print("SOURCE_ATMOSPHERE_DIAGNOSTIC ",JSON.stringify(metadata))
	diagnostic_ready.emit(metadata)

func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT or _rd == null or not _pipeline.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	if buffers == null or scene == null or buffers.get_view_count() != 1:
		_fail("Expected one non-XR view.")
		return
	var size := buffers.get_internal_size()
	var color := buffers.get_color_layer(0)
	var depth := buffers.get_depth_layer(0)
	if _rd.texture_get_format(color).format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
		_fail("Expected scene-linear RGBA16F color.")
		return
	var bytes := _buffer(scene)
	if bytes.size()!=320:
		_fail("Parameter buffer layout mismatch.")
		return
	_rd.buffer_update(_parameters,0,bytes.size(),bytes)
	var diagnostic := _prepare_diagnostic(size,bytes)
	var diagnostic_buffer := _diagnostic_dummy if diagnostic.is_empty() else _diagnostic_active
	var uniforms := UniformSetCacheRD.get_cache(_shader,0,[
		_uniform(0,RenderingDevice.UNIFORM_TYPE_IMAGE,[color]),
		_uniform(1,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_nearest,depth]),
		_uniform(2,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_linear,_transmittance]),
		_uniform(3,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_linear,_irradiance]),
		_uniform(4,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_linear,_inscatter]),
		_uniform(5,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_parameters]),
		_uniform(6,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[diagnostic_buffer])])
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_pipeline)
	_rd.compute_list_bind_uniform_set(commands,uniforms,0)
	_rd.compute_list_dispatch(commands,ceili(size.x/8.0),ceili(size.y/8.0),1)
	_rd.compute_list_end()
	if not diagnostic.is_empty():
		var error := _rd.buffer_get_data_async(_diagnostic_active,_receive_diagnostic.bind(diagnostic),16,int(diagnostic.payload_bytes))
		if error!=OK:
			diagnostic.error = "buffer_get_data_async failed: %s" % error
			_write_diagnostic.call_deferred(PackedByteArray(),diagnostic)
	report.frames = int(report.frames)+1

static func _release(rd: RenderingDevice, ids: Array[RID]) -> void:
	for id in ids:
		if id.is_valid(): rd.free_rid(id)

func _notification(what: int) -> void:
	if what==NOTIFICATION_PREDELETE and _rd!=null:
		var ids: Array[RID] = [_diagnostic_active,_diagnostic_dummy,_parameters,_inscatter,_irradiance,_transmittance,_nearest,_linear,_pipeline,_shader]
		RenderingServer.call_on_render_thread(_release.bind(_rd,ids))
