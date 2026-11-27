extends CompositorEffect
## One pending immutable request; separate instances share a main-RD bridge.
var bridge: RefCounted
var cascade := -1
var _mutex := Mutex.new()
var _request: Dictionary = {}

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true

func arm(snapshot: Dictionary) -> bool:
	_mutex.lock()
	var available := _request.is_empty()
	if available: _request=snapshot.duplicate(true)
	_mutex.unlock()
	return available

func disarm(token: int) -> void:
	_mutex.lock()
	if not _request.is_empty() and int(_request.snapshot_id)==token: _request={}
	_mutex.unlock()

func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind!=EFFECT_CALLBACK_TYPE_POST_TRANSPARENT: return
	_mutex.lock()
	var snapshot: Dictionary = _request
	_request={}
	_mutex.unlock()
	if not snapshot.is_empty() and bridge!=null: bridge.render_cascade(snapshot,cascade,render_data)
