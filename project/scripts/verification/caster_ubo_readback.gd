extends CompositorEffect
## Diagnostic only: read the complete current-view UBO, never touch color/depth.
var _rd: RenderingDevice
var _mutex := Mutex.new()
var _request := -1
var _result: Dictionary = {}
var _serial := 0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize)

func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()

func request(token: int) -> bool:
	_mutex.lock()
	var available: bool = _request<0 and _result.is_empty()
	if available: _request = token
	_mutex.unlock()
	return available

func take() -> Dictionary:
	_mutex.lock()
	var result: Dictionary = _result
	_result = {}
	_mutex.unlock()
	return result

func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind!=effect_callback_type or _rd==null: return
	_serial += 1
	_mutex.lock()
	var token: int = _request
	_request = -1
	_mutex.unlock()
	if token<0: return
	var scene: RenderSceneData = render_data.get_render_scene_data()
	var bytes: PackedByteArray = _rd.buffer_get_data(scene.get_uniform_buffer())
	var result: Dictionary = {"token":token,"callback_serial":_serial,"drawn_frame":Engine.get_frames_drawn(),"scene_ubo":bytes,"size":bytes.size()}
	# Verified 4.7.2 float layout: 2848 bytes each for current and previous UBO.
	# 2832/2836 are emissive/IBL exposure, not the scene clock.
	if bytes.size()==5696:
		result.layout = "godot-4.7.2-float-2848x2"
		result.time_offset = 2816
		result.taa_frame_count_offset = 2820
		result.time = bytes.decode_float(2816)
		result.taa_frame_count = bytes.decode_float(2820)
		result.taa_jitter = [bytes.decode_float(2824),bytes.decode_float(2828)]
		result.previous_time = bytes.decode_float(5664)
		result.previous_taa_frame_count = bytes.decode_float(5668)
	else:
		result.layout_error = "Unsupported Scene UBO length; preserve raw bytes without decoding"
	_mutex.lock()
	_result = result
	_mutex.unlock()
