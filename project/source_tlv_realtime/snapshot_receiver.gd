extends "res://source_tlv_candidate/source_tlv_sun_receiver.gd"
## Same source sun-only shader; no extra original sun contribution.
var snapshot_id := -1
var _expected_shaders: Dictionary = {}
var _original_shaders: Dictionary = {}
var _pass_owners: Dictionary = {}

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
	var result := install(scene,snapshot.bounds,textures)
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
