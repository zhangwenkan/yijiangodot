extends "res://source_tlv_realtime/realtime_sun.gd"
## Explicit frozen diagnostic only. The ordinary producer is byte-exact v2.
## Hold the first complete receiver publication without releasing its slot.
## This deliberately exceeds normal age limits; it is NOT a realtime result.
var diagnostic_holding := false
var diagnostic_frames := 0

func install(scene: Node3D, map_slug: String, options: Dictionary = {}) -> Dictionary:
	if Engine.time_scale != 0.0 or scene.process_mode != Node.PROCESS_MODE_DISABLED:
		return {"status":"failed","error":"Frozen receiver diagnostic requires disabled scene processing and zero time scale."}
	if not bool(options.get("enable_receiver",false)):
		return {"status":"failed","error":"Frozen receiver diagnostic requires explicit receiver opt-in."}
	var result: Dictionary = super.install(scene,map_slug,options)
	result.diagnostic_policy="Freeze first published pair only; no realtime age/frequency claim."
	return result

func _complete(event: Dictionary) -> void:
	var previous := int(report.get("published",0))
	super._complete(event)
	if _running and int(report.get("published",0)) > previous:
		diagnostic_holding = true
		report.diagnostic_hold = {"snapshot_id":_active.snapshot_id,"slot":_active.slot,
			"entered_frame":Engine.get_frames_drawn(),"normal_age_policy_suspended":true,
			"reason":"Explicit frozen publication diagnostic only."}

func _free_slot() -> int:
	# _complete runs within the original _pre_draw. Prevent it from starting an
	# additional pair in that same callback after the first publication is held.
	return -1 if diagnostic_holding else super._free_slot()

func _pre_draw() -> void:
	if not diagnostic_holding:
		super._pre_draw()
		return
	if not _running: return
	var errors: Array[String] = []
	if Engine.time_scale != 0.0 or _scene.process_mode != Node.PROCESS_MODE_DISABLED:
		errors.append("Frozen scene/time contract ended.")
	if not _inflight.is_empty() or _active.is_empty():
		errors.append("Held publication is absent or a second pair is in flight.")
	else:
		if _scene.camera.global_transform != _active.camera_pose or _projection_signature() != _active.projection:
			errors.append("Frozen camera changed.")
		if _active.house_generation != _house_generation or _active.owner_generation != _owner_generation:
			errors.append("Frozen source generation changed.")
		var light: Dictionary = _probes.snapshot_light()
		if light.has("error") or int(light.get("light_fingerprint",0)) != int(_active.light_fingerprint):
			errors.append("Frozen source sun/LF changed.")
	if _receiver == null:
		errors.append("Held receiver disappeared.")
	else:
		errors.append_array(_receiver.owner_errors())
	if _caster != null: errors.append_array(_caster.prepare_snapshot(_scene.camera))
	if not errors.is_empty():
		stop("Frozen receiver diagnostic invalidated: "+str(errors))
		return
	diagnostic_frames += 1
	report.diagnostic_hold.observed_frames = diagnostic_frames
	report.status = "diagnostic_frozen_hold"
