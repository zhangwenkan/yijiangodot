extends "res://source_tlv_candidate/source_tlv_sun_receiver.gd"
const COMMENT_MASK := preload("res://source_tlv_realtime/comment_mask.gd")
## Same source sun-only shader; no extra original sun contribution.
var snapshot_id := -1
var _expected_shaders: Dictionary = {}
var _original_shaders: Dictionary = {}
var _pass_owners: Dictionary = {}
var cpu_stage_timing: RefCounted
var _cpu_build_stats: Dictionary = {}
var _cpu_build_serial := 0
var _cpu_scan_stats: Dictionary = {}
var _cpu_scan_depth := 0
var _cpu_bind_depth := 0

func set_mode(mode: int) -> void:
	_mode=clampi(mode,0,2)
	var conflicts: Array[String] = []
	for state in _saved:
		if not is_instance_valid(state.material): continue
		var identity: int = state.material.get_instance_id()
		# install_snapshot calls this before its hash map is populated; identity
		# still has to match the freshly installed shader in that initial batch.
		var expected: String = _expected_shaders.get(identity,state.installed.code.sha256_text())
		if state.material.shader!=state.installed or state.installed.code.sha256_text()!=expected:
			conflicts.append("Mode change skipped foreign receiver owner: "+state.material.resource_name)
			continue
		state.material.set_shader_parameter("source_tlv_sun_mode",_mode)
	report.mode=_mode
	report.mode_conflicts=conflicts

func install_snapshot(scene: Node, snapshot: Dictionary, textures: Array[Dictionary]) -> Dictionary:
	if cpu_stage_timing!=null: _cpu_reset_build_stats()
	var result := install(scene,snapshot.bounds,textures)
	if cpu_stage_timing!=null: _cpu_emit_build_stats("receiver_build_summary",result)
	set_mode(0)
	if result.get("status")!="installed": return result
	for state in _saved:
		var id: int = state.material.get_instance_id()
		_expected_shaders[id]=state.installed.code.sha256_text()
		_original_shaders[id]=state.shader.code.sha256_text()
		_pass_owners[id]=[state.material.next_pass,state.material.render_priority]
	return result

func owner_errors() -> Array[String]:
	var errors: Array[String] = []
	for state in _saved:
		if not is_instance_valid(state.material):
			errors.append("Receiver material disappeared.")
			continue
		if state.material.shader!=state.installed or state.installed.code.sha256_text()!=_expected_shaders.get(state.material.get_instance_id(),""):
			errors.append("Receiver shader owner/code changed.")
		var id: int = state.material.get_instance_id()
		if state.shader.code.sha256_text()!=_original_shaders.get(id,""): errors.append("Original receiver shader resource changed.")
		if [state.material.next_pass,state.material.render_priority]!=_pass_owners.get(id,[]): errors.append("Receiver pass/priority owner changed.")
	return errors

func publish(snapshot: Dictionary, textures: Array[Dictionary]) -> Dictionary:
	var errors := owner_errors()
	if not errors.is_empty(): return {"updated":false,"errors":errors}
	var validation := _validate_volumes(snapshot.bounds,textures)
	if not validation.is_empty(): return {"updated":false,"error":validation}
	# Called only from one synchronous frame_pre_draw batch. Runtime epoch capture
	# is still required to establish the observed per-draw publication boundary.
	set_mode(0)
	var updated := update_volumes(snapshot.bounds,textures)
	if not bool(updated.get("updated",false)): return updated
	snapshot_id=int(snapshot.snapshot_id)
	set_mode(1)
	return {"updated":true,"snapshot_id":snapshot_id,"materials":_saved.size()}

func restore() -> Dictionary:
	var restored := 0
	var errors: Array[String] = []
	var remaining: Array[Dictionary] = []
	for state in _saved:
		if not is_instance_valid(state.material): continue
		var material: ShaderMaterial = state.material
		var id := material.get_instance_id()
		if material.shader!=state.installed or state.installed.code.sha256_text()!=_expected_shaders.get(id,state.installed.code.sha256_text()):
			errors.append("Another receiver shader owner/code changed; unwind it first."); remaining.append(state); continue
		if state.shader.code.sha256_text()!=_original_shaders.get(id,state.shader.code.sha256_text()):
			errors.append("Original receiver shader resource changed; unwind it first."); remaining.append(state); continue
		if [material.next_pass,material.render_priority]!=_pass_owners.get(id,[material.next_pass,material.render_priority]):
			errors.append("Receiver pass/priority owner changed; unwind it first."); remaining.append(state); continue
		for key in state.parameters: state.parameters[key]=material.get_shader_parameter(key)
		material.shader=state.shader
		for key in state.parameters: material.set_shader_parameter(key,state.parameters[key])
		restored+=1
	_saved=remaining
	if _saved.is_empty():
		_seen.clear(); _cache.clear(); _bounds.clear(); _textures.clear()
		_expected_shaders.clear(); _original_shaders.clear(); _pass_owners.clear()
	return {"restored_materials":restored,"errors":errors}

func build_candidate(code: String, family: String, library: String) -> Dictionary:
	if cpu_stage_timing==null: return super.build_candidate(code,family,library)
	var started_us := Time.get_ticks_usec()
	var result: Dictionary = super.build_candidate(code,family,library)
	var ended_us := Time.get_ticks_usec()
	_cpu_record_build(family if FAMILIES.has(family) else "Unsupported",started_us,ended_us,result.has("error"))
	return result

func _cpu_reset_build_stats() -> void:
	_cpu_reset_scan_stats()
	_cpu_build_serial+=1
	_cpu_build_stats={"binding_instance_id":get_instance_id(),"install_serial":_cpu_build_serial,
		"first_call_start_us":-1,"last_call_end_us":-1,"calls":0,"elapsed_us":0,"max_us":0,"error_count":0,"families":{}}

func _cpu_record_build(family: String, started_us: int, ended_us: int, failed: bool) -> void:
	if _cpu_build_stats.is_empty(): _cpu_reset_build_stats()
	var elapsed_us := ended_us-started_us
	if int(_cpu_build_stats.first_call_start_us)<0: _cpu_build_stats.first_call_start_us=started_us
	_cpu_build_stats.last_call_end_us=ended_us
	_cpu_build_stats.calls+=1
	_cpu_build_stats.elapsed_us+=elapsed_us
	_cpu_build_stats.max_us=maxi(int(_cpu_build_stats.max_us),elapsed_us)
	if failed: _cpu_build_stats.error_count+=1
	if not _cpu_build_stats.families.has(family):
		_cpu_build_stats.families[family]={"calls":0,"elapsed_us":0,"max_us":0,"error_count":0}
	var row: Dictionary=_cpu_build_stats.families[family]
	row.calls+=1
	row.elapsed_us+=elapsed_us
	row.max_us=maxi(int(row.max_us),elapsed_us)
	if failed: row.error_count+=1

func _cpu_emit_build_stats(stage: String, install_result: Dictionary) -> void:
	var summary: Dictionary=_cpu_build_stats.duplicate(true)
	summary.bound=int(install_result.get("bound",0))
	summary.install_status=str(install_result.get("status",""))
	summary.scope="Inclusive super.build_candidate elapsed only; not a GPU or Shader compile measurement. This is a subset of the enclosing install span."
	install_result.cpu_build_candidate=summary
	cpu_stage_timing.record_event(stage,summary)
	_cpu_emit_scan_stats("receiver_scan_summary",install_result)

func _scan(node: Node) -> void:
	if cpu_stage_timing==null:
		super._scan(node)
		return
	if _cpu_scan_stats.is_empty(): _cpu_reset_scan_stats()
	var outermost := _cpu_scan_depth==0
	var started_us := Time.get_ticks_usec() if outermost else -1
	_cpu_scan_stats.scan_calls+=1
	_cpu_scan_depth+=1
	super._scan(node)
	_cpu_scan_depth-=1
	if outermost:
		var ended_us := Time.get_ticks_usec()
		_cpu_scan_stats.scan_root_calls+=1
		_cpu_scan_stats.scan_root_elapsed_us+=ended_us-started_us
		_cpu_scan_stats.scan_first_start_us=started_us if int(_cpu_scan_stats.scan_first_start_us)<0 else _cpu_scan_stats.scan_first_start_us
		_cpu_scan_stats.scan_last_end_us=ended_us

func _bind(material: Material, node: Node) -> void:
	if cpu_stage_timing==null:
		super._bind(material,node)
		return
	if _cpu_scan_stats.is_empty(): _cpu_reset_scan_stats()
	var outermost := _cpu_bind_depth==0
	var in_scan := _cpu_scan_depth>0
	var started_us := Time.get_ticks_usec() if outermost else -1
	_cpu_scan_stats.bind_calls+=1
	_cpu_bind_depth+=1
	super._bind(material,node)
	_cpu_bind_depth-=1
	if outermost:
		var elapsed_us := Time.get_ticks_usec()-started_us
		_cpu_scan_stats.bind_root_calls+=1
		_cpu_scan_stats.bind_root_elapsed_us+=elapsed_us
		if in_scan: _cpu_scan_stats.bind_in_scan_elapsed_us+=elapsed_us
		else: _cpu_scan_stats.bind_outside_scan_elapsed_us+=elapsed_us

func _without_comments(code: String) -> String:
	if cpu_stage_timing==null: return COMMENT_MASK.without_comments(code)
	if _cpu_scan_stats.is_empty(): _cpu_reset_scan_stats()
	var in_scan := _cpu_scan_depth>0
	var in_bind := _cpu_bind_depth>0
	var started_us := Time.get_ticks_usec()
	var result: String=COMMENT_MASK.without_comments(code)
	var elapsed_us := Time.get_ticks_usec()-started_us
	_cpu_scan_stats.comment_calls+=1
	_cpu_scan_stats.comment_elapsed_us+=elapsed_us
	_cpu_scan_stats.comment_max_us=maxi(int(_cpu_scan_stats.comment_max_us),elapsed_us)
	if in_scan: _cpu_scan_stats.comments_in_scan_elapsed_us+=elapsed_us
	else: _cpu_scan_stats.comments_outside_scan_elapsed_us+=elapsed_us
	if in_bind: _cpu_scan_stats.comments_in_bind_elapsed_us+=elapsed_us
	else: _cpu_scan_stats.comments_outside_bind_elapsed_us+=elapsed_us
	return result

func _cpu_reset_scan_stats() -> void:
	_cpu_scan_depth=0
	_cpu_bind_depth=0
	_cpu_scan_stats={"scan_calls":0,"scan_root_calls":0,"scan_root_elapsed_us":0,
		"scan_first_start_us":-1,"scan_last_end_us":-1,
		"bind_calls":0,"bind_root_calls":0,"bind_root_elapsed_us":0,
		"bind_in_scan_elapsed_us":0,"bind_outside_scan_elapsed_us":0,
		"comment_calls":0,"comment_elapsed_us":0,"comment_max_us":0,
		"comments_in_scan_elapsed_us":0,"comments_outside_scan_elapsed_us":0,
		"comments_in_bind_elapsed_us":0,"comments_outside_bind_elapsed_us":0}

func _cpu_emit_scan_stats(stage: String, install_result: Dictionary) -> void:
	var summary: Dictionary=_cpu_scan_stats.duplicate(true)
	summary.binding_instance_id=get_instance_id()
	summary.install_serial=_cpu_build_serial
	summary.scan_depth_at_emit=_cpu_scan_depth
	summary.bind_depth_at_emit=_cpu_bind_depth
	summary.bound=int(install_result.get("bound",0))
	summary.install_status=str(install_result.get("status",""))
	summary.scope="Overlapping aggregates: scan roots contain bind roots, and both contain comment cleaning. Comment time overlaps existing build totals. Only in-scan comments may be subtracted from scan. Remainders are unattributed, not Shader compile time."
	install_result.cpu_scan_breakdown=summary
	cpu_stage_timing.record_event(stage,summary)
