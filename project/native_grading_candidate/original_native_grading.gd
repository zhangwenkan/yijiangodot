extends CompositorEffect
## Isolated source-grading candidate, HDR scene-linear BEFORE Godot tonemap.
## Install all four files in res://native_grading_candidate/ for a diagnostic run.

const ASSET_ROOT := "res://native_grading_candidate/"
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _constants := RID()
var _lock := Mutex.new()
var _inside := false
var _last_inside := false
var _exposure_domain_scale := 1.0
var _outdoor := PackedByteArray()
var _indoor := PackedByteArray()

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	_outdoor = FileAccess.get_file_as_bytes(ASSET_ROOT + "native-grading-outdoor.bin")
	_indoor = FileAccess.get_file_as_bytes(ASSET_ROOT + "native-grading-indoor.bin")
	RenderingServer.call_on_render_thread(_initialize_compute)

func set_source_indoor(value: bool) -> void:
	_lock.lock()
	_inside = value
	_lock.unlock()

func set_diagnostic_exposure_domain_scale(value: float) -> void:
	# Default1. This knob is diagnostic only; no native equivalence is implied.
	_lock.lock()
	_exposure_domain_scale = maxf(value, 0.0)
	_lock.unlock()

func _initialize_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("Native grading needs the RD Forward+ renderer.")
		return
	if _outdoor.size() != 1072 or _indoor.size() != 1072:
		push_error("Native grading source constant buffers are missing.")
		return
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(ASSET_ROOT + "original_native_grading.glsl").replace("#[compute]", "")
	var spirv := _rd.shader_compile_spirv_from_source(source)
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		push_error("Native grading candidate compile failed: " + error)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_constants = _rd.storage_buffer_create(_outdoor.size(), _outdoor)

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null or not _pipeline.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	_lock.lock()
	var inside := _inside
	var scale_value := _exposure_domain_scale
	_lock.unlock()
	if inside != _last_inside:
		_rd.buffer_update(_constants, 0, 1072, _indoor if inside else _outdoor)
		_last_inside = inside
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, size.x)
	push.encode_s32(4, size.y)
	push.encode_float(8, scale_value)
	push.encode_float(12, 0.0)
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(color)
		var constants_uniform := RDUniform.new()
		constants_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		constants_uniform.binding = 1
		constants_uniform.add_id(_constants)
		var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [color_uniform, constants_uniform])
		var commands := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(commands, _pipeline)
		_rd.compute_list_bind_uniform_set(commands, uniforms, 0)
		_rd.compute_list_set_push_constant(commands, push, push.size())
		_rd.compute_list_dispatch(commands, ceili(float(size.x) / 8.0), ceili(float(size.y) / 8.0), 1)
		_rd.compute_list_end()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# RD defers deletion until in-flight frames finish. Do not queue a
		# callable bound to this already-dying RefCounted resource.
		if _rd != null:
			if _constants.is_valid():
				_rd.free_rid(_constants)
			if _shader.is_valid():
				_rd.free_rid(_shader) # Also releases its dependent pipeline.
