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
var _house_reuse_scan := false
var _house_source_views: Dictionary = {}
var _house_reference_graph: Array = []

func install(scene: Node3D, main_camera: Camera3D, caster_layers: int = 0xFFFFF,
		allow_partial_diagnostic: bool = false, enabled: bool = true) -> Dictionary:
	var memo_owner := not _analysis_memo_active
	if memo_owner: _begin_install_analysis()
	if cpu_stage_timing!=null: _cpu_reset_build_stats()
	var result := super.install(scene,main_camera,caster_layers,allow_partial_diagnostic,enabled)
	if result.get("status")=="installed": _house_reference_graph=_capture_house_reference_graph(scene)
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
	if _house_reuse_scan: return _build_candidate_for_install(code,family)
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
	if _house_reuse_scan:
		super._scan(node)
		return
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
	if _house_reuse_scan:
		_house_bind(material,node)
		return
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
	if _house_reuse_scan: return _comments_for_install(code)
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

func _end_install_analysis(install_result: Dictionary, summary_stage: String = "caster_analysis_memo_summary") -> void:
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
	cpu_stage_timing.record_event(summary_stage,summary)

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

func reuse_after_house(scene: Node3D, camera: Camera3D, receiver_views: Dictionary = {}) -> Dictionary:
	# Caller has invalidated the old pair and waited for its ACK before entry.
	# A legitimate receiver layered over a caster must unwind before caster verify.
	for state in _saved:
		if is_instance_valid(state.material) and receiver_views.has(state.material.get_instance_id()):
			return {"status":"reinstall","reason":"Caster and receiver share a material; retain original unwind order."}
	var errors := verify_bound_state()
	if not errors.is_empty(): return {"status":"failed","errors":errors,"reason":"Caster owner conflict."}
	if _saved.is_empty() or _analysis_memo_active:
		return {"status":"reinstall","reason":"No saved caster set or another analysis is active."}
	if not is_instance_valid(scene) or camera!=_camera:
		return {"status":"reinstall","reason":"Caster scene/camera identity changed."}
	if (camera.cull_mask & 0xFFFFF)!=_mask or not _enabled:
		return {"status":"reinstall","reason":"Caster mask/enabled contract changed."}
	var current_graph: Array=_capture_house_reference_graph(scene)
	if _house_reference_graph!=current_graph:
		return {"status":"reinstall","reason":"Scene material slot/mesh/node/pass reference graph changed.","graph_diff":_house_reference_graph_diff(_house_reference_graph,current_graph)}
	var saved_by_id: Dictionary={}
	for state in _saved:
		var id: int=state.material.get_instance_id()
		saved_by_id[id]=state
	var previous_report: Dictionary=report
	var original_templates: Dictionary={}
	for label in previous_report.materials: original_templates[label.family]=label.template_sha256
	var previous_seen: Dictionary=_seen
	var previous_nodes: Dictionary=_material_nodes
	var previous_pending: Array[Dictionary]=_pending
	var previous_templates: Dictionary=_template_cache
	report=previous_report.duplicate(true)
	for key in ["cpu_analysis_memo","cpu_build_candidate","cpu_scan_breakdown"]: report.erase(key)
	for key in ["materials","unsupported","not_modified"]: report[key]=[]
	for key in ["bound","potential_casters","skipped_shadow_off","skipped_visibility_or_layer"]: report[key]=0
	for family in report.family_counts: report.family_counts[family]=0
	_seen={}; _material_nodes={}; _pending=[]; _template_cache={}
	_house_source_views=receiver_views.duplicate(false)
	for id in saved_by_id: _house_source_views[id]=saved_by_id[id].shader
	_house_reuse_scan=true
	_begin_install_analysis()
	_scan(scene)
	_house_reuse_scan=false
	_house_source_views.clear()
	var scanned: Dictionary=report
	var candidates: Array[Dictionary]=_pending
	var nodes: Dictionary=_material_nodes
	var analysis: Dictionary={}
	_end_install_analysis(analysis,"caster_house_reuse_analysis_summary")
	report=previous_report
	_seen=previous_seen; _material_nodes=previous_nodes; _pending=previous_pending; _template_cache=previous_templates
	if not scanned.unsupported.is_empty():
		return {"status":"reinstall","reason":"Current visible caster audit requires original strict install.","unsupported":scanned.unsupported}
	if candidates.size()!=_saved.size():
		return {"status":"reinstall","reason":"Visible caster material count changed.","previous_bound":_saved.size(),"current_bound":candidates.size()}
	for candidate in candidates:
		var id: int=candidate.material.get_instance_id()
		if not saved_by_id.has(id):
			return {"status":"reinstall","reason":"Visible caster material identity changed."}
		var state: Dictionary=saved_by_id[id]
		if candidate.family!=state.family or candidate.code!=state.installed.code or candidate.audit.template_sha256!=original_templates.get(candidate.family,""):
			return {"status":"reinstall","reason":"Caster family/template/output changed."}
	# Recheck before committing report or camera uniforms; no Shader was replaced.
	errors=prepare_snapshot(camera)
	if not errors.is_empty(): return {"status":"failed","errors":errors,"reason":"Caster camera/owner changed during check."}
	for candidate in candidates:
		var id: int=candidate.material.get_instance_id()
		var state: Dictionary=saved_by_id[id]
		var label: Dictionary=candidate.audit.duplicate(true)
		label.nodes=nodes.get(id,[candidate.node])
		label.original_parameter_count=state.parameters.size()
		scanned.materials.append(label)
		scanned.family_counts[candidate.family]+=1
		scanned.bound+=1
		state.node=candidate.node
	scanned.status="installed"
	scanned.camera_transform=str(camera.global_transform)
	scanned.caster_mask=_mask
	scanned.house_reuse={"reused_materials":_saved.size(),"shader_assignments":0,"analysis":analysis.get("cpu_analysis_memo",{})}
	report=scanned
	return {"status":"reused","bound":_saved.size(),"reason":"Same visible materials, original owners, templates and output code.","report":report}

func _house_bind(material: Material, node: GeometryInstance3D) -> void:
	# Same preflight as the frozen _bind, but inspect proven original shader views.
	# This path only creates pending text candidates; it never binds a Shader.
	if material==null: return
	var id := material.get_instance_id()
	var path := str(node.get_path())
	if not _material_nodes.has(id): _material_nodes[id]=[]
	if not _material_nodes[id].has(path): _material_nodes[id].append(path)
	if _seen.has(id): return
	_seen[id]=true
	_house_bind(material.next_pass,node)
	if material is BaseMaterial3D:
		if material.billboard_mode!=BaseMaterial3D.BILLBOARD_DISABLED:
			_unsupported(node,material,"BaseMaterial3D billboard requires its source ShaderMaterial adapter.")
		return
	if not material is ShaderMaterial or material.shader==null: return
	var source: Shader=_house_source_views.get(id,material.shader)
	var code: String=source.code
	var clean := _without_comments(code)
	var family := _family(material,clean)
	if not family.is_empty():
		var built := build_candidate(code,family)
		if built.has("error"):
			_unsupported(node,material,built.error)
			return
		if family.begins_with("Ambient"):
			var fixed_y: Variant=material.get_shader_parameter("source_ambient_fixed_y")
			if fixed_y!=true:
				if fixed_y!=false: _unsupported(node,material,"Ambient fixed-Y uniform is not an explicit bool.")
				else: report.not_modified.append({"node":path,"material":material.resource_name,"reason":"Source ambient fixed-Y is disabled; existing geometry orientation is camera independent."})
				return
		_pending.append({"material":material,"node":path,"code":built.code,"family":family,
			"audit":{"family":family,"material":material.resource_name,"source_material":str(material.get_meta("source_material","")),
				"source_shader_sha256":code.sha256_text(),"bound_shader_sha256":str(built.code).sha256_text(),
				"template_sha256":built.template_sha256,"fragment_exact":built.fragment_exact,
				"inverse_edit_exact":built.inverse_edit_exact,"replacements":built.replacements}})
		return
	var risk := _reachable_vertex_risk(clean)
	if not risk.is_empty(): _unsupported(node,material,"Unrecognized camera-dependent caster: "+risk)

func _capture_house_reference_graph(scene: Node) -> Array:
	# Visibility alone is expected to change at house transitions. Compare every
	# geometry resource/slot regardless of visibility before reusing its owners.
	var graph: Array=[]
	var particle_identities: Dictionary=_house_particle_identities(scene)
	var pending: Array[Node]=[scene]
	var materials: Dictionary={}
	while not pending.is_empty():
		var node: Node=pending.pop_back()
		for child in node.get_children(): pending.append(child)
		if not node is GeometryInstance3D: continue
		var geometry: GeometryInstance3D=node
		var ancestry: Array=[]
		var ancestor: Node=node.get_parent()
		while ancestor!=null:
			ancestry.append([ancestor.get_instance_id(),str(ancestor.name)])
			ancestor=ancestor.get_parent()
		var row: Array=[node.get_instance_id(),str(node.name),ancestry,geometry.layers,geometry.cast_shadow,
			_house_material_reference(geometry.material_override,materials),_house_material_reference(geometry.material_overlay,materials)]
		if node is MeshInstance3D:
			row.append(node.mesh.get_instance_id() if node.mesh!=null else 0)
			if node.mesh!=null:
				for index in node.mesh.get_surface_count():
					row.append([_house_material_reference(node.mesh.surface_get_material(index),materials),
						_house_material_reference(node.get_surface_override_material(index),materials)])
		elif node is MultiMeshInstance3D:
			row.append(node.multimesh.get_instance_id() if node.multimesh!=null else 0)
			if node.multimesh!=null:
				row.append(node.multimesh.instance_count)
				var animated_particle_count: bool=geometry.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and particle_identities.has(node.get_instance_id())
				row.append("source_particle_animation_count" if animated_particle_count else node.multimesh.visible_instance_count)
				row.append(node.multimesh.mesh.get_instance_id() if node.multimesh.mesh!=null else 0)
				if node.multimesh.mesh!=null:
					for index in node.multimesh.mesh.get_surface_count(): row.append(_house_material_reference(node.multimesh.mesh.surface_get_material(index),materials))
		if node is MultiMeshInstance3D:
			row.append({"particle_identity":particle_identities.get(node.get_instance_id(),{})})
		graph.append(row)
	graph.append(materials)
	return graph

func _house_material_reference(material: Material, materials: Dictionary) -> int:
	if material==null: return 0
	var id := material.get_instance_id()
	if materials.has(id): return id
	materials[id]=[]
	materials[id]=[material.render_priority,_house_material_reference(material.next_pass,materials)]
	return id

func _house_reference_graph_diff(before: Array, after: Array) -> Dictionary:
	# Bounded evidence only. This does not alter the graph or fallback decision.
	var old_nodes: Dictionary={}
	var new_nodes: Dictionary={}
	var old_materials: Dictionary={}
	var new_materials: Dictionary={}
	for row in before:
		if row is Dictionary: old_materials=row
		elif row is Array and not row.is_empty(): old_nodes[row[0]]=row
	for row in after:
		if row is Dictionary: new_materials=row
		elif row is Array and not row.is_empty(): new_nodes[row[0]]=row
	var added: Array=[]
	var removed: Array=[]
	var changed: Array=[]
	var fields: Dictionary={}
	var changed_count := 0
	var particle_count_only := 0
	var changed_materials: Array=[]
	var changed_material_count := 0
	for id in old_nodes:
		if not new_nodes.has(id): removed.append(id)
	for id in new_nodes:
		if not old_nodes.has(id):
			added.append(id)
			continue
		var previous: Array=old_nodes[id]
		var current: Array=new_nodes[id]
		if previous==current: continue
		changed_count+=1
		var node: Object=instance_from_id(id)
		var field_names: Array=["node_id","name","ancestry","layers","cast_shadow","material_override","material_overlay"]
		if node is MultiMeshInstance3D:
			field_names.append_array(["multimesh_id","instance_count","visible_instance_count","mesh_id"])
		elif node is MeshInstance3D: field_names.append("mesh_id")
		var differences: Array=[]
		var indices: Array=[]
		for index in maxi(previous.size(),current.size()):
			var old_value: Variant=previous[index] if index<previous.size() else null
			var new_value: Variant=current[index] if index<current.size() else null
			if typeof(old_value)==typeof(new_value) and old_value==new_value: continue
			indices.append(index)
			var field: String=str(field_names[index]) if index<field_names.size() else "surface_%d"%index
			if (old_value is Dictionary and old_value.has("particle_identity")) or (new_value is Dictionary and new_value.has("particle_identity")): field="particle_identity"
			fields[field]=int(fields.get(field,0))+1
			if differences.size()<12: differences.append({"index":index,"field":field,"before":old_value,"after":new_value})
		var source_emitter: String=str(node.get_meta("source_emitter","")) if is_instance_valid(node) else ""
		var only_count: bool=node is MultiMeshInstance3D and indices==[9] and previous[4]==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and current[4]==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and not source_emitter.is_empty()
		if only_count: particle_count_only+=1
		if changed.size()<12:
			changed.append({"id":id,"path":str(node.get_path()) if node is Node else "missing",
				"class":node.get_class() if is_instance_valid(node) else "missing","source_emitter":source_emitter,
				"source_component":str(node.get_meta("source_component","")) if is_instance_valid(node) else "",
				"only_shadow_off_source_particle_count":only_count,"differences":differences})
	var material_ids: Dictionary={}
	for id in old_materials: material_ids[id]=true
	for id in new_materials: material_ids[id]=true
	for id in material_ids:
		if old_materials.get(id)!=new_materials.get(id):
			changed_material_count+=1
			if changed_materials.size()<12: changed_materials.append({"id":id,"before":old_materials.get(id),"after":new_materials.get(id)})
	return {"diagnostic_only":true,"sample_limit":12,"before_geometry":old_nodes.size(),"after_geometry":new_nodes.size(),
		"added_count":added.size(),"added_ids":added.slice(0,12),"removed_count":removed.size(),"removed_ids":removed.slice(0,12),
		"changed_node_count":changed_count,"changed_field_counts":fields,"changed_nodes":changed,
		"only_shadow_off_source_particle_count_nodes":particle_count_only,
		"changed_material_count":changed_material_count,"changed_materials":changed_materials,
		"same_node_rows_and_materials_different_order":added.is_empty() and removed.is_empty() and changed_count==0 and changed_material_count==0}

func _house_particle_identities(scene: Node) -> Dictionary:
	# A metadata label alone is not proof of the original particle owner. Match
	# its actual emitter table and resource references afresh on every snapshot.
	var identities: Dictionary={}
	var claimed: Dictionary={}
	var pending: Array[Node]=[scene]
	while not pending.is_empty():
		var owner: Node=pending.pop_back()
		for child in owner.get_children(): pending.append(child)
		var script: Script=owner.get_script()
		if script==null or script.resource_path!="res://scripts/original_particles.gd": continue
		var emitters: Variant=owner.get("_emitters")
		var generated: Variant=owner.get("_generated")
		var world: Variant=owner.get("_world")
		if not emitters is Array or not is_instance_valid(generated) or not generated is Node or not is_instance_valid(world) or not world is Node: continue
		if owner.get_parent()!=world or generated.get_parent()!=world: continue
		for emitter in emitters:
			if not is_instance_valid(emitter): continue
			var draw: Variant=emitter.get("draw")
			var multi: Variant=emitter.get("multi")
			var data: Variant=emitter.get("data")
			if not draw is MultiMeshInstance3D or not is_instance_valid(draw) or not multi is MultiMesh or not data is Dictionary: continue
			if draw.get_parent()!=generated or draw.multimesh!=multi: continue
			var source_emitter: String=str(data.get("source",""))
			var source_component: String=str(emitter.get("source_group"))
			if source_emitter.is_empty() or source_component.is_empty(): continue
			if str(draw.get_meta("source_emitter",""))!=source_emitter or str(draw.get_meta("source_component",""))!=source_component: continue
			var draw_id: int=draw.get_instance_id()
			if claimed.has(draw_id):
				identities.erase(draw_id)
				continue
			claimed[draw_id]=true
			identities[draw.get_instance_id()]={"kind":"original_cascade_particle","class":draw.get_class(),
				"owner_id":owner.get_instance_id(),"owner_script_id":script.get_instance_id(),"owner_script":script.resource_path,
				"emitter_id":emitter.get_instance_id(),"generated_id":generated.get_instance_id(),"world_id":world.get_instance_id(),
				"source_emitter":source_emitter,"source_component":source_component}
	return identities
