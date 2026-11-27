extends "res://source_tlv_candidate/source_tlv_caster_camera_binding.gd"
## Reuses audited source-template edits. Only owned camera uniforms are updated.
## Original material animation values remain under their original owners.

func install(scene: Node3D, main_camera: Camera3D, caster_layers: int = 0xFFFFF,
		allow_partial_diagnostic: bool = false, enabled: bool = true) -> Dictionary:
	var result := super.install(scene,main_camera,caster_layers,allow_partial_diagnostic,enabled)
	result.scope="Audited camera-dependent vertex substitutions updated from the current main-camera snapshot. Original geometry, fragment/discard and external animation parameters are retained."
	if result.has("limits"):
		result.limits.erase("Freeze camera, time, animation, state and material owners until probes stop and restore completes.")
		result.limits.append("Dynamic parameter owners are retained; camera uniforms and shader/pass ownership are guarded. Scene-topology changes require a drained rescan.")
	return result

func verify_bound_state() -> Array[String]:
	var errors: Array[String] = []
	if not is_instance_valid(_camera): errors.append("Original camera disappeared.")
	for state in _saved:
		if not is_instance_valid(state.material):
			errors.append("Material disappeared: "+state.node)
			continue
		var material: ShaderMaterial = state.material
		if material.shader!=state.installed or material.shader.code.sha256_text()!=state.installed_sha256:
			errors.append("Shader owner or code changed: "+state.node)
			continue
		if state.shader.code.sha256_text()!=state.original_sha256:
			errors.append("Original shader resource changed: "+state.node)
		if material.next_pass!=state.next_pass or material.render_priority!=state.render_priority:
			errors.append("Material pass/priority owner changed: "+state.node)
		for pair in [[ENABLED,_enabled],[CAMERA_WORLD,_camera_transform.origin],[CAMERA_RIGHT,_camera_transform.basis.x],[CAMERA_BACK,_camera_transform.basis.z]]:
			if material.get_shader_parameter(pair[0])!=pair[1]: errors.append("Owned camera uniform changed: "+state.node+" / "+str(pair[0]))
	return errors

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
