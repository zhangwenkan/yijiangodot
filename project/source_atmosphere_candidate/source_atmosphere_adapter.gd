extends Node
## Reversible owner for one WorldEnvironment or Camera3D compositor.
var report: Dictionary = {}
var effect
var _target: Node
var _previous: Compositor
var _installed: Compositor
var _house: Node
var _outside := 30.0
var _inside := 3.0

func install(target: Node, atmosphere_policy: String, height_policy: String, options: Dictionary = {}) -> Dictionary:
	if is_instance_valid(_target): return {"error":"Restore existing atmosphere installation first."}
	if not target is WorldEnvironment and not target is Camera3D:
		return {"error":"Target must be WorldEnvironment or Camera3D."}
	var path: String = get_script().resource_path.get_base_dir().path_join("source_atmosphere_effect.gd")
	effect = load(path).new()
	var configured: Dictionary = effect.configure(atmosphere_policy,height_policy,options)
	if configured.has("error"):
		effect = null
		return configured
	_target = target
	_previous = target.compositor
	_installed = Compositor.new()
	var effects: Array[CompositorEffect] = []
	if _previous != null:
		for item in _previous.compositor_effects: effects.append(item)
	effects.append(effect)
	_installed.compositor_effects = effects
	target.compositor = _installed
	_outside = float(options.get("exterior_sun_intensity",30.0))
	_inside = float(options.get("interior_sun_intensity",3.0))
	report = {"installed":true,"target":str(target.get_path()),"effect":configured,
		"restore_order":"capture owner first, atmosphere adapter next, then cone/heightfog/SH owners in reverse installation order"}
	return report

func set_source_sun_intensity(value: float) -> void:
	if effect!=null: effect.set_source_sun_intensity(value)

func request_diagnostic(output_directory: String, stride: int = 4) -> Dictionary:
	if effect==null: return {"error":"Atmosphere effect is not installed."}
	return effect.request_diagnostic(output_directory,stride)

func attach_house_driver(driver: Node) -> Dictionary:
	_detach()
	if not is_instance_valid(driver) or not driver.has_signal("house_state_changed"):
		return {"error":"Expected house_state_changed signal."}
	_house=driver
	driver.connect("house_state_changed",Callable(self,"_on_house"))
	var inside: Variant=driver.get("is_in_house")
	_on_house(inside is bool and inside)
	return {"attached":true}

func _on_house(inside: bool) -> void:
	set_source_sun_intensity(_inside if inside else _outside)

func _detach() -> void:
	if is_instance_valid(_house) and _house.is_connected("house_state_changed",Callable(self,"_on_house")):
		_house.disconnect("house_state_changed",Callable(self,"_on_house"))
	_house=null

func restore() -> Dictionary:
	_detach()
	var restored := false
	if is_instance_valid(_target) and _target.compositor==_installed:
		_target.compositor=_previous
		restored=true
	if effect!=null: effect.enabled=false
	_target=null
	_previous=null
	_installed=null
	effect=null
	return {"restored":restored}
