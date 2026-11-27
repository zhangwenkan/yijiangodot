extends RefCounted
## Optional, main-thread-only diagnostic. No rendering calls or waits.
## Spans are inclusive monotonic elapsed time, not CPU-core execution or GPU time.
const DEFAULT_CAPACITY := 32768
const MAX_CAPACITY := 65536
const MAX_ERRORS := 64
var _capacity := DEFAULT_CAPACITY
var _records: Array[Dictionary] = []
var _stack: Array[int] = []
var _errors: Array[String] = []
var _error_count := 0
var _dropped := 0
var _metadata: Dictionary = {}
var _configured := false
var _sealed := false
var _bookkeeping_usec := 0
var _started_usec := 0

func configure(metadata: Dictionary, capacity: int = DEFAULT_CAPACITY) -> void:
	if _configured or not _records.is_empty():
		_error("Recorder cannot be reconfigured.")
		return
	_configured=true
	_metadata=metadata.duplicate(true)
	_capacity=clampi(capacity,1,MAX_CAPACITY)
	_started_usec=Time.get_ticks_usec()

func _error(message: String) -> void:
	_error_count+=1
	if _errors.size()<MAX_ERRORS: _errors.append(message)

func _reserve() -> bool:
	if _sealed: return false
	if _records.size()>=_capacity:
		_dropped+=1
		return false
	return true

func begin_span(stage: String, context: Dictionary = {}) -> int:
	var overhead_start := Time.get_ticks_usec()
	if not _reserve(): return -1
	var id := _records.size()
	var row := {"kind":"span","id":id,"parent_id":_stack.back() if not _stack.is_empty() else -1,
		"stage":stage,"draw_frame":Engine.get_frames_drawn(),"physics_frame":Engine.get_physics_frames(),
		"context":context.duplicate(true),"finished":false}
	_records.append(row)
	_stack.append(id)
	var stamp := Time.get_ticks_usec()
	row.start_us=stamp
	_bookkeeping_usec+=stamp-overhead_start
	return id

func end_span(id: int) -> void:
	if id<0: return
	var stamp := Time.get_ticks_usec()
	if _sealed: return
	if id>=_records.size() or _records[id].get("kind","")!="span":
		_error("Unknown span id: "+str(id))
		return
	var row: Dictionary = _records[id]
	if bool(row.finished):
		_error("Span ended twice: "+str(id))
		return
	if _stack.is_empty() or _stack.back()!=id:
		_error("Non-LIFO span end: "+str(id))
		_stack.erase(id)
	else:
		_stack.pop_back()
	row.end_us=stamp
	row.elapsed_us=stamp-int(row.start_us)
	row.end_draw_frame=Engine.get_frames_drawn()
	row.end_physics_frame=Engine.get_physics_frames()
	row.finished=true
	if int(row.elapsed_us)<0: _error("Monotonic clock went backwards.")
	_bookkeeping_usec+=Time.get_ticks_usec()-stamp

func record_event(stage: String, context: Dictionary = {}) -> void:
	var stamp := Time.get_ticks_usec()
	if not _reserve(): return
	_records.append({"kind":"event","id":_records.size(),
		"parent_id":_stack.back() if not _stack.is_empty() else -1,"stage":stage,"tick_us":stamp,
		"draw_frame":Engine.get_frames_drawn(),"physics_frame":Engine.get_physics_frames(),
		"context":context.duplicate(true)})
	_bookkeeping_usec+=Time.get_ticks_usec()-stamp

func seal() -> Dictionary:
	if _sealed: return {"valid":false,"error":"Recorder already sealed."}
	_sealed=true
	var unfinished: Array[int] = []
	for row in _records:
		if row.kind=="span" and not bool(row.finished): unfinished.append(int(row.id))
	if not _stack.is_empty() or not unfinished.is_empty(): _error("Recorder sealed with outstanding spans.")
	return {"schema":1,"valid":_configured and _dropped==0 and _error_count==0,
		"metadata":_metadata,"clock":"Time.get_ticks_usec monotonic microseconds",
		"started_us":_started_usec,"sealed_us":Time.get_ticks_usec(),
		"capacity":_capacity,"record_count":_records.size(),"dropped":_dropped,
		"error_count":_error_count,"errors":_errors,"outstanding_stack":_stack,"unfinished_spans":unfinished,
		"bookkeeping_elapsed_us":_bookkeeping_usec,
		"measurement_limits":["Span elapsed time includes child spans and engine/scheduler waits; never sum inclusive parents with their children.",
			"Bookkeeping counter covers measured recorder work only. Caller context creation, dispatch and profiler overhead are not fully quantified.",
			"Lifecycle event differences are latency, not CPU execution or GPU duration.",
			"No new GPU reads, timestamps, synchronization or per-frame file writes."],"records":_records}

func dump_once(path: String, extra_metadata: Dictionary = {}) -> Dictionary:
	var export_start := Time.get_ticks_usec()
	if _sealed: return {"written":false,"valid":false,"error":"Recorder already sealed."}
	var data := seal()
	data.extra_metadata=extra_metadata.duplicate(true)
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null: return {"written":false,"valid":false,"path":path,"error":"File open failed: "+str(FileAccess.get_open_error())}
	file.store_string(JSON.stringify(data))
	file.flush()
	var write_error := file.get_error()
	file.close()
	return {"written":write_error==OK,"valid":bool(data.valid) and write_error==OK,
		"path":path,"record_count":_records.size(),"dropped":_dropped,"error_count":_error_count,
		"unfinished_spans":data.unfinished_spans,"write_error":write_error,
		"export_elapsed_us":Time.get_ticks_usec()-export_start,
		"note":"Export is after case cleanup and outside recorded route spans."}
