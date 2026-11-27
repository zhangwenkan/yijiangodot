extends CompositorEffect
## Explicit main-view diagnostic; no writes to scene color or material data.
## Runs before the existing post-transparent chain, retaining its identity.
## CPU submission metadata + actual scene UBO do NOT prove fragment epochs.
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
var _pending: Dictionary = {}
var _result: Dictionary = {}
var _error := ""
var _in_flight := false
var _closing := false
var _closed := false
var _serial := 0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	RenderingServer.call_on_render_thread(_initialize)

func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null: _fail("Main RenderingDevice unavailable."); return
	var source := RDShaderSource.new()
	source.source_compute = COPY_SOURCE
	var spirv := _rd.shader_compile_spirv_from_source(source)
	var message := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not message.is_empty(): _fail(message); return
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid(): _fail("Readback shader creation failed."); return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid(): _fail("Readback pipeline creation failed.")

func request(metadata: Dictionary) -> bool:
	_mutex.lock()
	var available := not _closing and not _in_flight and _pending.is_empty() and _result.is_empty() and _error.is_empty()
	if available: _pending = metadata.duplicate(true)
	_mutex.unlock()
	return available

func take_result() -> Dictionary:
	_mutex.lock()
	var result: Dictionary = _result
	_result = {}
	if not _error.is_empty(): result = {"error":_error}
	_mutex.unlock()
	return result

func _fail(message: String) -> void:
	_mutex.lock()
	_error = message
	_in_flight = false
	_pending = {}
	_mutex.unlock()
	push_error("Receiver draw diagnostic: "+message)

func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind != effect_callback_type or _rd == null or not _pipeline.is_valid(): return
	_mutex.lock()
	var metadata: Dictionary = _pending
	_pending = {}
	if not metadata.is_empty(): _in_flight = true
	_mutex.unlock()
	if metadata.is_empty(): return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_view_count() != 1:
		_fail("Expected one non-XR main view."); return
	var size := buffers.get_internal_size()
	var color := buffers.get_color_layer(0)
	var scene_data := render_data.get_render_scene_data()
	if scene_data == null: _fail("Main render scene data unavailable."); return
	var ubo := scene_data.get_uniform_buffer()
	if size.x <= 0 or size.y <= 0 or not color.is_valid() or not ubo.is_valid():
		_fail("Main scene color/UBO unavailable."); return
	var input_format := _rd.texture_get_format(color)
	if input_format.format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT or (input_format.usage_bits & RenderingDevice.TEXTURE_USAGE_STORAGE_BIT)==0:
		_fail("Expected RGBA16F main scene color."); return
	if size != _size or not _copy.is_valid():
		if _copy.is_valid(): _rd.free_rid(_copy)
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.width = size.x
		format.height = size.y
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		_copy = _rd.texture_create(format,RDTextureView.new())
		if not _copy.is_valid(): _fail("Readback staging texture creation failed."); return
		_size = size
	var source_uniform := RDUniform.new()
	source_uniform.binding = 0
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	source_uniform.add_id(color)
	var target_uniform := RDUniform.new()
	target_uniform.binding = 1
	target_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	target_uniform.add_id(_copy)
	var uniforms := UniformSetCacheRD.get_cache(_shader,0,[source_uniform,target_uniform])
	if not uniforms.is_valid(): _fail("Readback uniform set creation failed."); return
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_pipeline)
	_rd.compute_list_bind_uniform_set(commands,uniforms,0)
	_rd.compute_list_dispatch(commands,ceili(size.x/8.0),ceili(size.y/8.0),1)
	_rd.compute_list_end()
	# Deliberately synchronous and diagnostic-only; not a realtime performance run.
	var bytes := _rd.texture_get_data(_copy,0)
	var scene_bytes := _rd.buffer_get_data(ubo)
	if bytes.size() != size.x*size.y*8 or scene_bytes.size() != 5696:
		_fail("Main color/UBO byte count mismatch: %d / %d" % [bytes.size(),scene_bytes.size()]); return
	_serial += 1
	var result := {"submission":metadata,"width":size.x,"height":size.y,
		"drawn_frame":Engine.get_frames_drawn(),"callback_serial":_serial,
		"rgba16f":bytes,"scene_ubo":scene_bytes,"capture_ticks_usec":Time.get_ticks_usec(),
		"stage":"main POST_TRANSPARENT before original compositor chain; separate translucency may be composited later"}
	_mutex.lock()
	_result = result
	_in_flight = false
	_mutex.unlock()

func shutdown() -> void:
	enabled = false
	_mutex.lock()
	_closing = true
	_pending = {}
	_mutex.unlock()
	RenderingServer.call_on_render_thread(_close)

func is_closed() -> bool:
	_mutex.lock()
	var result := _closed
	_mutex.unlock()
	return result

func _close() -> void:
	if _rd != null:
		for id in [_copy,_pipeline,_shader]:
			if id.is_valid(): _rd.free_rid(id)
	_copy = RID()
	_pipeline = RID()
	_shader = RID()
	_rd = null
	_mutex.lock()
	_closed = true
	_mutex.unlock()
