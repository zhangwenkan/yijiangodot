extends "res://source_tlv_candidate/source_tlv_caster_camera_binding.gd"
const COMMENT_MASK := preload("res://source_tlv_realtime/comment_mask.gd")
## Reuses audited source-template edits. Only owned camera uniforms are updated.
## Original material animation values remain under their original owners.
var cpu_stage_timing: RefCounted
var _cpu_build_stats: Dictionary = {}
var _cpu_build_serial := 0
var _cpu_scan_stats: Dictionary = {}
var _cpu_scan_depth := 0
var _cpu_bind_depth := 0
var _analysis_memo_active := false
var _comment_memo: Dictionary = {}
var _risk_memo: Dictionary = {}
var _build_memo: Dictionary = {}
var _analysis_memo_stats: Dictionary = {}

func install(scene: Node3D, main_camera: Camera3D, caster_layers: int = 0xFFFFF,
		allow_partial_diagnostic: bool = false, enabled: bool = true) -> Dictionary:
	var memo_owner := not _analysis_memo_active
	if memo_owner: _begin_install_analysis()
	if cpu_stage_timing!=null: _cpu_reset_build_stats()
	var result := super.install(scene,main_camera,caster_layers,allow_partial_diagnostic,enabled)
	if memo_owner: _end_install_analysis(result)
	if cpu_stage_timing!=null: _cpu_emit_build_stats("caster_build_summary",result)
	result.scope="Audited camera-dependent vertex substitutions updated from the current main-camera snapshot. Original geometry, fragment/discard and external animation parameters are retained."
	if result.has("limits"):
		result.limits.erase("Freeze camera, time, animation, state and material owners until probes stop and restore completes.")
		result.limits.append("Dynamic parameter owners are retained; camera uniforms and shader/pass ownership are guarded. Scene-topology changes require a drained rescan.")
	return result

func verify_bound_state() -> Array[String]:
	if cpu_stage_timing==null: return _cpu_body_verify_bound_state()
	var span: int=cpu_stage_timing.begin_span("caster_verify",{"bound":_saved.size()})
	var errors: Array[String]=_cpu_body_verify_bound_state()
	cpu_stage_timing.end_span(span)
	return errors

func _cpu_body_verify_bound_state() -> Array[String]:
	var errors: Array[String] = []
	# Reuse digests only inside this synchronous check. The next call reads again.
	var shader_hashes: Dictionary = {}
	if not is_instance_valid(_camera): errors.append("Original camera disappeared.")
	for state in _saved:
		if not is_instance_valid(state.material):
			errors.append("Material disappeared: "+state.node)
			continue
		var material: ShaderMaterial = state.material
		if material.shader!=state.installed or _shader_digest(material.shader,shader_hashes)!=state.installed_sha256:
			errors.append("Shader owner or code changed: "+state.node)
			continue
		if _shader_digest(state.shader,shader_hashes)!=state.original_sha256:
			errors.append("Original shader resource changed: "+state.node)
		if material.next_pass!=state.next_pass or material.render_priority!=state.render_priority:
			errors.append("Material pass/priority owner changed: "+state.node)
		for pair in [[ENABLED,_enabled],[CAMERA_WORLD,_camera_transform.origin],[CAMERA_RIGHT,_camera_transform.basis.x],[CAMERA_BACK,_camera_transform.basis.z]]:
			if material.get_shader_parameter(pair[0])!=pair[1]: errors.append("Owned camera uniform changed: "+state.node+" / "+str(pair[0]))
	return errors

func _shader_digest(shader: Shader, hashes: Dictionary) -> String:
	var identity := shader.get_instance_id()
	if not hashes.has(identity): hashes[identity]=shader.code.sha256_text()
	return hashes[identity]

func prepare_snapshot(camera: Camera3D) -> Array[String]:
	var errors := verify_bound_state()
	if camera!=_camera: errors.append("Active camera identity changed; reinstall required.")
	if not errors.is_empty(): return errors
	var pose: Transform3D = camera.global_transform
	if not pose.origin.is_finite() or not pose.basis.x.is_finite() or not pose.basis.y.is_finite() or not pose.basis.z.is_finite():
		return ["Camera transform must be finite."]
	if not pose.basis.is_equal_approx(pose.basis.orthonormalized()): return ["Camera basis must stay orthonormal."]
	if Vector3.UP.cross(pose.basis.z).length_squared()<0.000001 or pose.basis.x.cross(Vector3.UP).length_squared()<0.000001:
		return ["Fixed-Y camera basis is degenerate."]
	_camera_transform=pose
	for state in _saved:
		state.material.set_shader_parameter(CAMERA_WORLD,pose.origin)
		state.material.set_shader_parameter(CAMERA_RIGHT,pose.basis.x)
		state.material.set_shader_parameter(CAMERA_BACK,pose.basis.z)
	return []

func restore() -> Dictionary:
	# Restore the current animation values, not the frozen install-time snapshot.
	# Preserve superclass owner guards; only update values for untouched owners.
	for state in _saved:
		if not is_instance_valid(state.material) or state.material.shader!=state.installed: continue
		for key in state.parameters:
			state.parameters[key]=_snapshot_value(state.material.get_shader_parameter(key))
	return super.restore()

func build_candidate(code: String, family: String) -> Dictionary:
	if cpu_stage_timing==null: return _build_candidate_for_install(code,family)
	var started_us := Time.get_ticks_usec()
	var result: Dictionary = _build_candidate_for_install(code,family)
	var ended_us := Time.get_ticks_usec()
	_cpu_record_build(family if TEMPLATES.has(family) else "Unsupported",started_us,ended_us,result.has("error"))
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
	summary.scope="Inclusive logical build wrapper elapsed, including memo lookup/copy and actual builds on misses; not legacy-only execution, GPU or Shader compile time. This is a subset of the enclosing install span."
	install_result.cpu_build_candidate=summary
	cpu_stage_timing.record_event(stage,summary)
	_cpu_emit_scan_stats("caster_scan_summary",install_result)

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

func _bind(material: Material, node: GeometryInstance3D) -> void:
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
	if cpu_stage_timing==null: return _comments_for_install(code)
	if _cpu_scan_stats.is_empty(): _cpu_reset_scan_stats()
	var in_scan := _cpu_scan_depth>0
	var in_bind := _cpu_bind_depth>0
	var started_us := Time.get_ticks_usec()
	var result: String=_comments_for_install(code)
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
	summary.scope="Overlapping aggregates: scan roots contain bind roots and logical comment wrappers (memo lookup or cleaning). Comment time overlaps logical build totals. Only in-scan comments may be subtracted from scan. Remainders are unattributed, not Shader compile time."
	install_result.cpu_scan_breakdown=summary
	cpu_stage_timing.record_event(stage,summary)

func _begin_install_analysis() -> void:
	_comment_memo.clear()
	_risk_memo.clear()
	_build_memo.clear()
	_analysis_memo_stats.clear()
	if cpu_stage_timing!=null:
		for operation in ["comments","risk","build"]:
			_analysis_memo_stats[operation]={"calls":0,"hits":0,"misses":0,"errors":0,"stores":0}
	_analysis_memo_active=true

func _end_install_analysis(install_result: Dictionary) -> void:
	var summary: Dictionary=_analysis_memo_stats.duplicate(true) if cpu_stage_timing!=null else {}
	_analysis_memo_active=false
	_comment_memo.clear()
	_risk_memo.clear()
	_build_memo.clear()
	_analysis_memo_stats.clear()
	if cpu_stage_timing==null: return
	summary.binding_instance_id=get_instance_id()
	summary.install_serial=_cpu_build_serial
	summary.install_status=str(install_result.get("status",""))
	summary.scope="Exact-input pure text reuse only inside this synchronous install. Misses execute original analysis; build errors are not cached. All memo entries cleared before this event."
	install_result.cpu_analysis_memo=summary
	cpu_stage_timing.record_event("caster_analysis_memo_summary",summary)

func _memo_record(operation: String, hit: bool, failed: bool = false, stored: bool = false) -> void:
	if cpu_stage_timing==null: return
	var row: Dictionary=_analysis_memo_stats[operation]
	row.calls+=1
	if hit: row.hits+=1
	else: row.misses+=1
	if failed: row.errors+=1
	if stored: row.stores+=1

func _comments_for_install(code: String) -> String:
	if not _analysis_memo_active: return COMMENT_MASK.without_comments(code)
	if _comment_memo.has(code):
		_memo_record("comments",true)
		return _comment_memo[code]
	var result: String=COMMENT_MASK.without_comments(code)
	_comment_memo[code]=result
	_memo_record("comments",false,false,true)
	return result

func _reachable_vertex_risk(clean: String) -> String:
	if not _analysis_memo_active: return super._reachable_vertex_risk(clean)
	if _risk_memo.has(clean):
		_memo_record("risk",true)
		return _risk_memo[clean]
	var result: String=super._reachable_vertex_risk(clean)
	_risk_memo[clean]=result
	_memo_record("risk",false,false,true)
	return result

func _build_candidate_for_install(code: String, family: String) -> Dictionary:
	if not _analysis_memo_active: return super.build_candidate(code,family)
	# The superclass owns template loading. Read only the exact text it consumes.
	if TEMPLATES.has(family) and _template_cache.has(family):
		var template: String=_template_cache[family]
		if _build_memo.has(family) and _build_memo[family].has(template) and _build_memo[family][template].has(code):
			_memo_record("build",true)
			return _build_memo[family][template][code].duplicate(true)
	var result: Dictionary=super.build_candidate(code,family)
	var store_result := not result.has("error") and TEMPLATES.has(family) and _template_cache.has(family)
	if store_result:
		var template: String=_template_cache[family]
		if not _build_memo.has(family): _build_memo[family]={}
		if not _build_memo[family].has(template): _build_memo[family][template]={}
		_build_memo[family][template][code]=result.duplicate(true)
	_memo_record("build",false,result.has("error"),store_result)
	return result
