extends CompositorEffect
## Read scene-linear RGBA16F after transparencies, before grading/Film/tonemap.
## The scene color has no CAN_COPY_FROM flag in Godot 4.7.2. Copy through compute.

const COPY_SOURCE := """
#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(rgba16f,set=0,binding=0) uniform readonly image2D source_image;
layout(rgba16f,set=0,binding=1) uniform writeonly image2D capture_image;
void main() {
    ivec2 p=ivec2(gl_GlobalInvocationID.xy);
    if(any(greaterThanEqual(p,imageSize(capture_image)))) return;
    imageStore(capture_image,p,imageLoad(source_image,p));
}
"""
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _copy := RID()
var _size := Vector2i.ZERO
var _mutex := Mutex.new()
var _requested := -1
var _in_flight := false
var _result: Dictionary = {}
var _error := ""

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	RenderingServer.call_on_render_thread(_initialize)

func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_fail("HDR readback requires the Forward+ RenderingDevice renderer.")
		return
	var source := RDShaderSource.new()
	source.source_compute = COPY_SOURCE
	var spirv := _rd.shader_compile_spirv_from_source(source)
	var message := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not message.is_empty():
		_fail(message)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

func request_face(token: int) -> bool:
	_mutex.lock()
	var available := _requested < 0 and not _in_flight and _result.is_empty() and _error.is_empty()
	if available:
		_requested = token
	_mutex.unlock()
	return available

func take_result() -> Dictionary:
	_mutex.lock()
	var result := _result
	_result = {}
	if not _error.is_empty():
		result = {"error":_error}
	_mutex.unlock()
	return result

func _fail(message: String) -> void:
	_mutex.lock()
	_error = message
	_in_flight = false
	_requested = -1
	_mutex.unlock()
	push_error("Source sky HDR capture: " + message)

func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null or not _pipeline.is_valid():
		return
	_mutex.lock()
	var token := _requested
	if token >= 0:
		_requested = -1
		_in_flight = true
	_mutex.unlock()
	if token < 0:
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_view_count() != 1:
		_fail("Expected one non-XR RenderSceneBuffersRD view.")
		return
	var size := buffers.get_internal_size()
	var color := buffers.get_color_layer(0)
	var input_format := _rd.texture_get_format(color)
	if size.x <= 0 or size.x != size.y or input_format.format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
		_fail("Expected square RGBA16F color buffer; size=%s format=%s" % [size,input_format.format])
		return
	if _size != size or not _copy.is_valid():
		if _copy.is_valid():
			_rd.free_rid(_copy)
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.width = size.x
		format.height = size.y
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		_copy = _rd.texture_create(format,RDTextureView.new())
		_size = size
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	source_uniform.binding = 0
	source_uniform.add_id(color)
	var target_uniform := RDUniform.new()
	target_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	target_uniform.binding = 1
	target_uniform.add_id(_copy)
	var uniforms := UniformSetCacheRD.get_cache(_shader,0,[source_uniform,target_uniform])
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_pipeline)
	_rd.compute_list_bind_uniform_set(commands,uniforms,0)
	_rd.compute_list_dispatch(commands,ceili(size.x/8.0),ceili(size.y/8.0),1)
	_rd.compute_list_end()
	# Async request snapshots this texture now, despite its delayed callback.
	var error := _rd.texture_get_data_async(_copy,0,_receive.bind(token,size))
	if error != OK:
		_fail("texture_get_data_async returned %s" % error)

func _receive(bytes: PackedByteArray, token: int, size: Vector2i) -> void:
	if bytes.size() != size.x*size.y*8:
		_fail("Incorrect RGBA16F byte count: %d" % bytes.size())
		return
	_mutex.lock()
	_result = {"token":token,"size":size,"bytes":bytes}
	_in_flight = false
	_mutex.unlock()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		if _copy.is_valid():
			_rd.free_rid(_copy)
		if _shader.is_valid():
			_rd.free_rid(_shader)
