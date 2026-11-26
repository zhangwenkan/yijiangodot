extends Node
## Reversible source-parameter HDR DOF owner; inserts immediately before Native Bloom.
## Does not change global Godot bokeh quality/shape. Builtin camera DOF is disabled.
var report: Dictionary = {}
var effect
var _camera: Camera3D
var _attributes: CameraAttributesPractical
var _previous_attributes: CameraAttributes
var _previous_compositor: Compositor
var _installed: Compositor
var _house: Node

func install(camera: Camera3D, policy_path: String, _options: Dictionary = {}) -> Dictionary:
	if is_instance_valid(_camera): return {"error":"Restore existing HDR DOF installation first."}
	if camera==null or not camera.attributes is CameraAttributesPractical:
		return {"error":"Expected CameraAttributesPractical."}
	var other: Variant = camera.get_meta("source_dof_owner") if camera.has_meta("source_dof_owner") else null
	if is_instance_valid(other): return {"error":"Existing source DOF owner must restore first."}
	if camera.compositor==null: return {"error":"Expected source Bloom/Film compositor."}
	var before := camera.compositor.compositor_effects
	var bloom_index := -1
	var film_index := -1
	for i in before.size():
		var script: Script = before[i].get_script()
		if script==null: continue
		var name := script.resource_path.get_file()
		if name=="original_native_bloom.gd": bloom_index=i
		if name=="original_native_film.gd": film_index=i
	if bloom_index<0 or film_index<=bloom_index:
		return {"error":"Required ordering Native Bloom then Native Film not found."}
	var path: String = get_script().resource_path.get_base_dir().path_join("source_hdr_dof_effect.gd")
	effect = load(path).new()
	var configured: Dictionary = effect.configure(policy_path)
	if configured.has("error"):
		effect=null
		return configured
	_camera=camera
	_previous_attributes=camera.attributes
	_previous_compositor=camera.compositor
	_attributes=_previous_attributes.duplicate(true) as CameraAttributesPractical
	_attributes.dof_blur_near_enabled=false
	_attributes.dof_blur_far_enabled=false
	var effects: Array[CompositorEffect] = []
	for i in before.size():
		if i==bloom_index: effects.append(effect)
		effects.append(before[i])
	_installed=Compositor.new()
	_installed.compositor_effects=effects
	camera.attributes=_attributes
	camera.compositor=_installed
	camera.set_meta("source_dof_owner",self)
	effect.failed.connect(_on_effect_failed)
	report={"installed":true,"status":"HDR DOF compositor candidate","effect":configured,
		"builtin_dof_disabled":true,"chain":"[optional distortion] -> HDR DOF -> [source separate-translucency owner] -> Native Bloom -> Native Film",
		"restore_order":"after house.reset_outdoors(), restore HDR DOF before atmosphere/renderer compositor owners",
		"limits":["Three source AfterDOF emitters have a separate owner; full UE resolution/recombine remains different.",
			"Godot circle gather retains its foreground/background rules but differs from UE.",
			"Do not enable TAA/upscalers after Film; parent keeps verified FXAA configuration."]}
	return report

func _on_effect_failed(message: String) -> void:
	report.error=message
	report.status="failed; restoring previous camera state"
	restore()

func set_house_state(inside: bool) -> void:
	if effect!=null: effect.set_source_indoor(inside)

func attach_house_driver(driver: Node) -> Dictionary:
	_detach_house()
	if not is_instance_valid(driver) or not driver.has_signal("house_state_changed"):
		return {"error":"Expected house_state_changed signal."}
	_house=driver
	driver.connect("house_state_changed",Callable(self,"set_house_state"))
	var current: Variant=driver.get("is_in_house")
	set_house_state(current is bool and current)
	return {"attached":true}

func request_diagnostic(directory: String, stride: int = 4) -> Dictionary:
	if effect==null: return {"error":"HDR DOF effect not installed."}
	return effect.request_diagnostic(directory,stride)

func _detach_house() -> void:
	if is_instance_valid(_house) and _house.is_connected("house_state_changed",Callable(self,"set_house_state")):
		_house.disconnect("house_state_changed",Callable(self,"set_house_state"))
	_house=null

func restore() -> Dictionary:
	_detach_house()
	var restored_attributes := false
	var restored_compositor := false
	if is_instance_valid(_camera):
		if _camera.attributes==_attributes:
			_camera.attributes=_previous_attributes
			restored_attributes=true
		if _camera.compositor==_installed:
			_camera.compositor=_previous_compositor
			restored_compositor=true
		if _camera.has_meta("source_dof_owner") and _camera.get_meta("source_dof_owner")==self:
			_camera.remove_meta("source_dof_owner")
	if effect!=null:
		effect.enabled=false
		if effect.failed.is_connected(_on_effect_failed): effect.failed.disconnect(_on_effect_failed)
	_camera=null
	_attributes=null
	_previous_attributes=null
	_previous_compositor=null
	_installed=null
	effect=null
	return {"restored_attributes":restored_attributes,"restored_compositor":restored_compositor}

func _exit_tree() -> void:
	restore()

