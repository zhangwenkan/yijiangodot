extends CompositorEffect
## Diagnostic only: copy color and depth, never write the original scene targets.
const SOURCE := """
#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(rgba16f,set=0,binding=0) uniform readonly image2D source_image;
layout(rgba16f,set=0,binding=1) uniform writeonly image2D capture_image;
layout(set=0,binding=2) uniform sampler2D depth_image;
layout(std430,set=0,binding=3) writeonly buffer Depth { float values[]; } d;
void main() {
    ivec2 p=ivec2(gl_GlobalInvocationID.xy);
    ivec2 size=imageSize(capture_image);
    if(any(greaterThanEqual(p,size))) return;
    imageStore(capture_image,p,imageLoad(source_image,p));
    d.values[p.y*size.x+p.x]=texelFetch(depth_image,p,0).r;
}
"""
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _copy := RID()
var _depth := RID()
var _nearest := RID()
var _size := Vector2i.ZERO
var _mutex := Mutex.new()
var _request := -1
var _result: Dictionary = {}
var _serial := 0
var _error := ""

func _init() -> void:
	access_resolved_color = true
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_initialize)

func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = SOURCE
	var spirv := _rd.shader_compile_spirv_from_source(source)
	_error = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not _error.is_empty(): push_error(_error); return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_nearest = _rd.sampler_create(RDSamplerState.new())

func request(token: int) -> void:
	_mutex.lock()
	_request = token
	_result = {}
	_mutex.unlock()

func take() -> Dictionary:
	_mutex.lock()
	var result := _result
	_result = {}
	_mutex.unlock()
	return result

func _uniform(binding: int, kind: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = binding
	uniform.uniform_type = kind
	for id in ids: uniform.add_id(id)
	return uniform

func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind != effect_callback_type or _rd == null or not _pipeline.is_valid(): return
	_serial += 1
	_mutex.lock()
	var token := _request
	_request = -1
	_mutex.unlock()
	if token < 0: return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	var size := buffers.get_internal_size()
	if size != _size:
		if _copy.is_valid(): _rd.free_rid(_copy)
		if _depth.is_valid(): _rd.free_rid(_depth)
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.width = size.x; format.height = size.y
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		_copy = _rd.texture_create(format,RDTextureView.new())
		_depth = _rd.storage_buffer_create(size.x*size.y*4)
		_size = size
	var uniforms := UniformSetCacheRD.get_cache(_shader,0,[
		_uniform(0,RenderingDevice.UNIFORM_TYPE_IMAGE,[buffers.get_color_layer(0)]),
		_uniform(1,RenderingDevice.UNIFORM_TYPE_IMAGE,[_copy]),
		_uniform(2,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[_nearest,buffers.get_depth_layer(0)]),
		_uniform(3,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_depth])])
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_pipeline)
	_rd.compute_list_bind_uniform_set(commands,uniforms,0)
	_rd.compute_list_dispatch(commands,ceili(size.x/8.0),ceili(size.y/8.0),1)
	_rd.compute_list_end()
	var result := {"token":token,"width":size.x,"height":size.y,"callback_serial":_serial,"drawn_frame":Engine.get_frames_drawn(),
		"rgba16f":_rd.texture_get_data(_copy,0),"depth_f32":_rd.buffer_get_data(_depth),
		"scene_ubo":_rd.buffer_get_data(scene.get_uniform_buffer())}
	_mutex.lock()
	_result = result
	_mutex.unlock()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		for id in [_copy,_depth,_nearest,_pipeline,_shader]:
			if id.is_valid(): _rd.free_rid(id)
