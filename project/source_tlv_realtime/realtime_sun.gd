extends Node
## Opt-in candidate. Default is a sidecar producer; receiver stays original.
## One pair in flight avoids replacing probe state before its draw consumes it.
const BOUNDS := preload("res://source_tlv_candidate/volume_bounds.gd")
var report: Dictionary = {}
var _scene: Node3D
var _bridge: RefCounted
var _probes: Node
var _caster: Node
var _receiver: Node
var _slots: Array[Dictionary] = []
var _inflight: Dictionary = {}
var _active: Dictionary = {}
var _running := false
var _initialized := false
var _receiver_enabled := false
var _install_generation := 0
var _house_generation := 0
var _owner_generation := 0
var _snapshot_serial := 0
var _inside := false
var _max_age_frames := 8
var _map_slug := ""
var _light_fingerprint := 0
var _last_pose := Transform3D.IDENTITY
var _camera_projection: Array = []
var _house: Node
var _rescan_casters := false
var _diagnostic_directory := ""

func install(scene: Node3D, map_slug: String, options: Dictionary = {}) -> Dictionary:
	if _running or _bridge!=null: return {"status":"failed","error":"Already installed; create a new owner after stop."}
	if not is_instance_valid(scene) or map_slug.is_empty(): return {"status":"failed","error":"Scene/map identity required."}
	var version := Engine.get_version_info()
	if int(version.major)!=4 or int(version.minor)!=7 or int(version.patch)!=2 or PackedVector3Array([Vector3.ZERO]).to_byte_array().size()!=12:
		return {"status":"failed","error":"This candidate requires the audited non-double Godot 4.7.2."}
	_scene=scene
	_map_slug=map_slug
	_receiver_enabled=bool(options.get("enable_receiver",false))
	_diagnostic_directory=str(options.get("diagnostic_once_directory",""))
	if not _diagnostic_directory.is_empty():
		if not _diagnostic_directory.is_absolute_path(): return {"status":"failed","error":"Diagnostic dump requires an explicit absolute output directory."}
		if DirAccess.make_dir_recursive_absolute(_diagnostic_directory)!=OK: return {"status":"failed","error":"Cannot create diagnostic output directory."}
	_max_age_frames=clampi(int(options.get("max_age_frames",8)),2,30)
	_install_generation+=1
	_bridge=preload("res://source_tlv_realtime/main_rd_bridge.gd").new()
	_probes=preload("res://source_tlv_realtime/dual_probe.gd").new()
	add_child(_probes)
	var probe_result: Dictionary = _probes.install(scene,_bridge)
	if probe_result.has("error"):
		_probes.queue_free(); _probes=null; _bridge=null
		return {"status":"failed","error":probe_result.error}
	_caster=preload("res://source_tlv_realtime/dynamic_caster_binding.gd").new()
	_caster.restore_on_exit_tree=false
	add_child(_caster)
	var caster_result: Dictionary = _caster.install(scene,scene.camera,0xFFFFF,false,true)
	if caster_result.get("status")!="installed":
		_probes.restore(); _caster.restore()
		_probes.queue_free(); _caster.queue_free(); _bridge=null
		return {"status":"failed","error":"Dynamic caster template preflight failed.","caster":caster_result}
	var light: Dictionary = _probes.snapshot_light()
	if light.has("error"):
		_probes.restore(); _caster.restore()
		_probes.queue_free(); _caster.queue_free(); _bridge=null
		return {"status":"failed","error":light.error}
	_light_fingerprint=int(light.light_fingerprint)
	_last_pose=scene.camera.global_transform
	_camera_projection=_projection_signature()
	_house=scene.get("house_driver")
	if is_instance_valid(_house) and _house.has_signal("house_state_changed"):
		_inside=bool(_house.get("is_in_house"))
		_house.connect("house_state_changed",_on_house_state)
	report={"status":"initializing","map":map_slug,"engine":version,
		"backend":RenderingServer.get_current_rendering_driver_name(),"method":RenderingServer.get_current_rendering_method(),
		"max_age_frames":_max_age_frames,"receiver_enabled":_receiver_enabled,
		"published":0,"produced":0,"rejected":0,"dropped_busy":0,"events":[],"pair_history":[],"pair_history_dropped":0,"request_history":[],
		"probe":probe_result,"caster":caster_result,"complete_restoration":false,
		"scope":"Sun-only paired producer. Original LF, shadows and SH math; current Godot shadow sampling, not native UE atlas parity.",
		"limits":["One paired job in flight; update frequency is limited by status ACK latency.",
			"Main-RD/Texture3DRD runtime and per-draw publication require the staged diagnostic; this source is not runtime-certified.",
			"Unknown newly-added casters/material owners require reinstall; no dynamic scene-topology support.",
			"Camera coverage policy is conservative; whole-map moving-view validation remains required."]}
	_running=true
	RenderingServer.frame_pre_draw.connect(_pre_draw)
	_bridge.initialize(3,_diagnostic_directory)
	return report

func _projection_signature() -> Array:
	var camera: Camera3D = _scene.camera
	return [camera.get_instance_id(),camera.projection,camera.fov,camera.size,camera.keep_aspect,
		camera.get_viewport().get_visible_rect().size]

func _pre_draw() -> void:
	if not _running: return
	var events: Array[Dictionary] = _bridge.take_events()
	# A failed initialization can enqueue fatal and closed in the same batch.
	# Retain cleanup evidence before a fatal branch ends normal processing.
	for event in events:
		if event.kind=="closed": report.gpu_closed=true
	for event in events:
		match str(event.kind):
			"fatal":
				stop(str(event.error))
				return
			"initialized":
				_slots=event.slots
				for slot in _slots: slot.token=-1
				_initialized=true
				report.pool={"slots":_slots.size(),"filtered_bytes":event.filtered_pool_bytes,"scratch_bytes":event.raw_scratch_bytes,"ack_bytes":event.status_bytes}
			"ubo_layout":
				# Keep the first raw UBO as diagnostic evidence; only two records total.
				if not report.has("ubo_layout"): report.ubo_layout=[]
				report.ubo_layout.append(event)
			"complete": _complete(event)
			"diagnostic": report.single_pair_diagnostic=event
		if not _running: return
	if not _running or not _initialized: return
	var frame := Engine.get_frames_drawn()
	var camera: Camera3D = _scene.camera
	if _rescan_casters:
		# A house transition toggles whole actor groups. Drain the old pair before
		# rescanning newly-visible potential casters under the same template rules.
		if not _inflight.is_empty(): return
		if _receiver!=null:
			var receiver_restored: Dictionary = _receiver.restore()
			if not receiver_restored.errors.is_empty(): stop("Receiver rescan owner conflict: "+str(receiver_restored)); return
			_receiver.queue_free()
			_receiver=null
		var restored: Dictionary = _caster.restore()
		if not restored.errors.is_empty(): stop("Caster rescan owner conflict: "+str(restored)); return
		var rescanned: Dictionary = _caster.install(_scene,camera,0xFFFFF,false,true)
		if rescanned.get("status")!="installed": stop("Caster rescan rejected: "+str(rescanned)); return
		_rescan_casters=false
		report.caster=rescanned
	var errors: Array[String] = _caster.prepare_snapshot(camera)
	if not errors.is_empty():
		stop("Caster owner/camera failed: "+str(errors))
		return
	if _projection_signature()!=_camera_projection:
		_owner_generation+=1
		_camera_projection=_projection_signature()
		_invalidate("Camera identity/projection/viewport changed.")
	var pose := camera.global_transform
	if pose.origin.distance_to(_last_pose.origin)>5.0 or pose.basis.z.angle_to(_last_pose.basis.z)>deg_to_rad(30.0):
		_owner_generation+=1
		_invalidate("Camera teleport/large turn.")
	_last_pose=pose
	var light: Dictionary = _probes.snapshot_light()
	if light.has("error"):
		_invalidate(str(light.error))
		return
	if int(light.light_fingerprint)!=_light_fingerprint:
		_owner_generation+=1
		_light_fingerprint=int(light.light_fingerprint)
		_invalidate("Source sun/LF state changed.")
	if not _active.is_empty() and not _fresh(_active,frame): _invalidate("Active volume exceeded age/coverage policy.")
	if not _inflight.is_empty():
		if frame-int(_inflight.request_frame)>_max_age_frames:
			_probes.cancel(int(_inflight.snapshot_id))
			_bridge.abandon(int(_inflight.snapshot_id),"Producer timeout; wait for ACK before slot reuse.")
			report.status="waiting_for_retirement"
		else: report.dropped_busy=int(report.dropped_busy)+1
		return
	var slot_index := _free_slot()
	if slot_index<0: return
	var size := camera.get_viewport().get_visible_rect().size
	if size.y<=0.0: _invalidate("Empty viewport."); return
	var bounds := BOUNDS.from_camera(camera,size.x/size.y)
	_snapshot_serial+=1
	if _snapshot_serial>=0xFFFFFFFF:
		stop("Snapshot uint32 exhausted; reinstall with a new owner.")
		return
	var snapshot: Dictionary = light.duplicate(true)
	snapshot.merge({"map_slug":_map_slug,"snapshot_id":_snapshot_serial,"install_generation":_install_generation,
		"house_generation":_house_generation,"owner_generation":_owner_generation,"house_inside":_inside,
		"slot":slot_index,"request_frame":frame,"camera_pose":pose,"projection":_camera_projection.duplicate(),
		"bounds":bounds,"probe_masks":[_probes.cameras[0].cull_mask,_probes.cameras[1].cull_mask]})
	_slots[slot_index].token=_snapshot_serial
	_inflight=snapshot
	report.request_history.append({"snapshot_id":_snapshot_serial,"request_frame":frame,"slot":slot_index,
		"install_generation":_install_generation,"house_generation":_house_generation,"owner_generation":_owner_generation})
	if report.request_history.size()>256: report.request_history.pop_front()
	_bridge.begin(snapshot)
	var arm_error: String = _probes.arm(snapshot)
	if not arm_error.is_empty(): _bridge.abandon(_snapshot_serial,arm_error)
	report.status="producing"

func _free_slot() -> int:
	for index in _slots.size():
		if int(_slots[index].token)>=0: continue
		var valid := true
		for pair in _slots[index].textures:
			for key in ["ambient","directional"]:
				var texture: Texture3D = pair[key]
				if texture.get_width()!=64 or texture.get_height()!=64 or texture.get_depth()!=64 or texture.get_format()!=Image.FORMAT_RGBAH: valid=false
		if valid: return index
	return -1

func _fresh(snapshot: Dictionary, frame: int) -> bool:
	if snapshot.install_generation!=_install_generation or snapshot.map_slug!=_map_slug or snapshot.house_generation!=_house_generation or snapshot.owner_generation!=_owner_generation: return false
	if snapshot.house_inside!=_inside or frame-int(snapshot.request_frame)>_max_age_frames or frame<int(snapshot.request_frame): return false
	var pose: Transform3D = _scene.camera.global_transform
	var old_pose: Transform3D = snapshot.camera_pose
	var distance_limit := float(snapshot.bounds[0].voxel_cm)*0.01*2.0
	return pose.origin.distance_to(old_pose.origin)<=distance_limit and pose.basis.z.angle_to(old_pose.basis.z)<=deg_to_rad(12.0) and snapshot.projection==_projection_signature()

func _status_error(event: Dictionary) -> String:
	var snapshot: Dictionary = event.snapshot
	var bytes: PackedByteArray = event.status
	if bool(event.cancelled) or not str(event.error).is_empty(): return "Cancelled/rejected: "+str(event.error)
	if event.done!=[true,true] or event.frames[0]!=event.frames[1]: return "Incomplete or cross-frame producer pair."
	if bytes.size()!=192: return "Status record length mismatch."
	var expected := [snapshot.snapshot_id,snapshot.install_generation,snapshot.house_generation,snapshot.owner_generation]
	for cascade in 2:
		var base := cascade*96
		if bytes.decode_u32(base)!=0 or bytes.decode_u32(base+4)!=0 or bytes.decode_u32(base+8)!=262144 or bytes.decode_u32(base+12)!=262144: return "GPU invalid/missing voxel(s)."
		for index in 4:
			if bytes.decode_u32(base+16+index*4)!=int(expected[index]): return "GPU token/generation mismatch."
		for offset in [32,36,40,44,48,52,56,60]:
			if not is_finite(bytes.decode_float(base+offset)): return "Nonfinite scene clock/TAA."
		if bytes.decode_float(base+64)!=1.0 or bytes.decode_float(base+76)!=1.0: return "Probe exposure/pass alpha is not unity."
		if bytes.decode_u32(base+72)!=int(snapshot.probe_masks[cascade]): return "Probe camera layer mask changed."
		if bytes.decode_u32(base+80)!=1 or bytes.decode_u32(base+84)!=cascade or bytes.decode_u32(base+88)!=(int(snapshot.request_frame)&0xFFFFFFFF): return "Probe sun count/cascade/request mismatch."
	# Both actual current and previous clock/TAA/jitter tuples must agree.
	if bytes.slice(32,64)!=bytes.slice(128,160): return "Near/far actual shader clocks or TAA differ."
	return ""

func _complete(event: Dictionary) -> void:
	var snapshot: Dictionary = event.snapshot
	var token: int = snapshot.snapshot_id
	if _inflight.is_empty() or int(_inflight.snapshot_id)!=token:
		_release(snapshot)
		return
	_inflight={}
	var reason := _status_error(event)
	var frame := Engine.get_frames_drawn()
	var current_light: Dictionary = _probes.snapshot_light()
	if reason.is_empty() and (current_light.has("error") or int(current_light.get("light_fingerprint",0))!=int(snapshot.light_fingerprint)):
		reason="Source light/LF changed before publication."
	if reason.is_empty() and not _fresh(snapshot,frame): reason="Stale generation/age/camera coverage."
	var pair_record := {"snapshot_id":token,"install_generation":snapshot.install_generation,
		"house_generation":snapshot.house_generation,"owner_generation":snapshot.owner_generation,
		"house_inside":snapshot.house_inside,"map_slug":snapshot.map_slug,"slot":snapshot.slot,
		"request_frame":snapshot.request_frame,"actual_frames":event.frames,"received_frame":frame,
		"age_frames":frame-int(snapshot.request_frame),"status_hex":event.status.hex_encode(),
		"done":event.done,"cancelled":event.cancelled,"accepted":reason.is_empty(),"reason":reason,
		"bounds":snapshot.bounds,"camera_pose":str(snapshot.camera_pose),"light_fingerprint":snapshot.light_fingerprint,
		"radiance":[snapshot.radiance.x,snapshot.radiance.y,snapshot.radiance.z],
		"direction_ue":[snapshot.direction_ue.x,snapshot.direction_ue.y,snapshot.direction_ue.z]}
	report.pair_history.append(pair_record)
	if report.pair_history.size()>256:
		report.pair_history.pop_front()
		report.pair_history_dropped=int(report.pair_history_dropped)+1
	if not reason.is_empty():
		report.rejected=int(report.rejected)+1
		_log({"rejected":token,"reason":reason,"age_frames":frame-int(snapshot.request_frame)})
		_release(snapshot)
		return
	var textures: Array[Dictionary] = _slots[int(snapshot.slot)].textures
	if _receiver_enabled:
		if _receiver==null:
			_receiver=preload("res://source_tlv_realtime/snapshot_receiver.gd").new()
			_receiver.restore_on_exit_tree=false
			add_child(_receiver)
			var installed: Dictionary = _receiver.install_snapshot(_scene,snapshot,textures)
			if installed.get("status")!="installed":
				_release(snapshot)
				stop("Receiver installation failed: "+str(installed))
				return
		var published: Dictionary = _receiver.publish(snapshot,textures)
		if not bool(published.get("updated",false)):
			_release(snapshot)
			stop("Receiver complete-snapshot publication failed: "+str(published))
			return
		report.published=int(report.published)+1
	var previous: Dictionary = _active
	_active=snapshot
	if not previous.is_empty(): _release(previous)
	report.produced=int(report.produced)+1
	report.last_snapshot={"snapshot_id":token,"produced_frame":event.frames[0],"accepted_frame":frame,
		"age_frames":frame-int(snapshot.request_frame),"house_generation":snapshot.house_generation,
		"owner_generation":snapshot.owner_generation,"bounds":snapshot.bounds,"status":event.status}
	report.status="active" if _receiver_enabled else "sidecar_ready"

func _release(snapshot: Dictionary) -> void:
	var slot: int = snapshot.slot
	var token: int = snapshot.snapshot_id
	if slot<0 or slot>=_slots.size() or int(_slots[slot].token)!=token: return
	_bridge.release_slot(slot,token)
	_slots[slot].token=-1

func _invalidate(reason: String) -> void:
	if _receiver!=null: _receiver.set_mode(0)
	if not _active.is_empty():
		_release(_active)
		_active={}
	if not _inflight.is_empty():
		_probes.cancel(int(_inflight.snapshot_id))
		_bridge.abandon(int(_inflight.snapshot_id),reason)
	_log({"fallback":"original sun","reason":reason,"frame":Engine.get_frames_drawn()})

func _on_house_state(inside: bool) -> void:
	_inside=inside
	_house_generation+=1
	_rescan_casters=true
	_invalidate("House state changed after source lighting update.")

func invalidate_owner(reason: String) -> void:
	_owner_generation+=1
	_rescan_casters=true
	_invalidate(reason)

func set_receiver_enabled(enabled: bool) -> void:
	_receiver_enabled=enabled
	report.receiver_enabled=enabled
	if not enabled and _receiver!=null: _receiver.set_mode(0)
	# Enabling waits for the next complete pair; it never republishes an old slot.

func _log(event: Dictionary) -> void:
	report.events.append(event)
	if report.events.size()>128: report.events.pop_front()

func stop(reason: String = "Requested stop.") -> Dictionary:
	if not _running: return report
	_running=false
	_install_generation+=1
	if RenderingServer.frame_pre_draw.is_connected(_pre_draw): RenderingServer.frame_pre_draw.disconnect(_pre_draw)
	if is_instance_valid(_house) and _house.is_connected("house_state_changed",_on_house_state): _house.disconnect("house_state_changed",_on_house_state)
	var probe_restore: Dictionary = _probes.restore()
	var receiver_restore: Dictionary = {"errors":[]}
	if _receiver!=null:
		_receiver.set_mode(0)
		receiver_restore=_receiver.restore()
	var caster_restore: Dictionary = _caster.restore()
	# If another shader owner prevents rollback, retain textures until explicitly
	# unwound; freeing a still-bound texture is worse than a reported quarantine.
	if receiver_restore.errors.is_empty(): _bridge.close()
	report.status="stopped" if receiver_restore.errors.is_empty() and caster_restore.errors.is_empty() and probe_restore.errors.is_empty() else "restore_conflict"
	report.stop={"reason":reason,"probe":probe_restore,"receiver":receiver_restore,"caster":caster_restore,
		"gpu_cleanup":"queued; asynchronous completion still required" if receiver_restore.errors.is_empty() else "quarantined for receiver owner conflict"}
	if bool(report.get("gpu_closed",false)): report.stop.gpu_cleanup="closed"
	return report

func _exit_tree() -> void:
	if _running: stop("Owner left tree.")

func drain_shutdown() -> Dictionary:
	# The diagnostic caller must keep this owner alive and call until closed.
	# A queued cleanup is not equivalent to a verified resource release.
	if _running or _bridge==null: return {"closed":false,"error":"Stop first."}
	var events: Array[Dictionary] = _bridge.take_events()
	for event in events:
		if event.kind=="closed":
			report.stop.gpu_cleanup="closed"
			report.gpu_closed=true
		elif event.kind=="fatal":
			report.stop.gpu_cleanup="quarantined: "+str(event.error)
		elif event.kind=="complete":
			report.pair_history.append({"snapshot_id":event.snapshot.snapshot_id,
				"install_generation":event.snapshot.install_generation,"house_generation":event.snapshot.house_generation,
				"owner_generation":event.snapshot.owner_generation,"request_frame":event.snapshot.request_frame,
				"actual_frames":event.frames,"received_frame":Engine.get_frames_drawn(),"status_hex":event.status.hex_encode(),
				"done":event.done,"cancelled":event.cancelled,"accepted":false,"reason":"Owner stopped; acknowledged retirement only."})
		elif event.kind=="diagnostic": report.single_pair_diagnostic=event
	return {"closed":bool(report.get("gpu_closed",false)),"events":events}

func retry_restore_shutdown() -> Dictionary:
	if _running: return {"error":"Stop first."}
	if not report.has("stop"): return {"error":"No installed owner to restore."}
	# A successful probe restore already reinstated original_mask, so calling it
	# again would mistake that restored mask for a foreign owner. Retry only an
	# actual unresolved probe conflict, and retain it in the final status gate.
	var probe_restore: Dictionary = report.stop.get("probe",{"errors":[]})
	if not probe_restore.errors.is_empty(): probe_restore=_probes.restore()
	var receiver_restore: Dictionary = {"errors":[]}
	if _receiver!=null:
		_receiver.set_mode(0)
		receiver_restore=_receiver.restore()
	var caster_restore: Dictionary = _caster.restore() if _caster!=null else {"errors":[]}
	report.stop.probe=probe_restore
	report.stop.receiver=receiver_restore
	report.stop.caster=caster_restore
	if receiver_restore.errors.is_empty():
		if bool(report.get("gpu_closed",false)):
			report.stop.gpu_cleanup="closed"
		elif report.stop.gpu_cleanup!="queued; asynchronous completion still required":
			_bridge.close()
			report.stop.gpu_cleanup="queued; asynchronous completion still required"
	report.status="stopped" if receiver_restore.errors.is_empty() and caster_restore.errors.is_empty() and probe_restore.errors.is_empty() else "restore_conflict"
	return report.stop
