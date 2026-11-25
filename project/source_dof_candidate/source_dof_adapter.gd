extends Node
## Source physical circle-of-confusion curve through Godot's physical DOF branch.
## This preserves current projection and exposure; Godot gather/recombine remains adapted.

var report: Dictionary = {}
var _camera: Camera3D
var _attributes: CameraAttributesPractical
var _previous: CameraAttributes
var _policy: Dictionary = {}
var _inside := false
var _house: Node
var _signature := ""
var _width_override := 0
var _previous_shape := 1
var _shape_installed := false
var _previous_quality := 1
var _previous_jitter := false

const BOKEH_SHAPE_SETTING := "rendering/camera/depth_of_field/depth_of_field_bokeh_shape"

func install(camera: Camera3D, policy_path: String, options: Dictionary = {}) -> Dictionary:
	if is_instance_valid(_camera): return {"error":"Restore existing installation first."}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(policy_path))
	if not parsed is Dictionary or parsed.get("schema","")!="source_dof_v1":
		return {"error":"Invalid source DOF policy."}
	if camera==null or not camera.attributes is CameraAttributesPractical:
		return {"error":"Expected a camera with CameraAttributesPractical."}
	var other: Variant = camera.get_meta("source_dof_owner") if camera.has_meta("source_dof_owner") else null
	if is_instance_valid(other): return {"error":"Camera already has a source DOF owner."}
	_policy=parsed
	report={}
	_inside=false
	_camera=camera
	_previous=camera.attributes
	_attributes=_previous.duplicate(true) as CameraAttributesPractical
	_width_override=int(options.get("internal_width",0))
	_previous_shape=int(options.get("previous_bokeh_shape",ProjectSettings.get_setting(BOKEH_SHAPE_SETTING,1)))
	RenderingServer.camera_attributes_set_dof_blur_bokeh_shape(RenderingServer.DOF_BOKEH_CIRCLE)
	_previous_quality=int(ProjectSettings.get_setting("rendering/camera/depth_of_field/depth_of_field_bokeh_quality",1))
	_previous_jitter=bool(ProjectSettings.get_setting("rendering/camera/depth_of_field/depth_of_field_use_jitter",false))
	# Source quality is high. Godot's high circle gather reduces the visible
	# low-quality sample rings, but remains a different kernel from UE.
	RenderingServer.camera_attributes_set_dof_blur_quality(RenderingServer.DOF_BLUR_QUALITY_HIGH,false)
	_shape_installed=true
	camera.attributes=_attributes
	camera.set_meta("source_dof_owner",self)
	process_priority=100
	set_process(true)
	_update()
	report.merge({"installed":true,"status":"source CoC candidate; Godot kernel adaptation",
		"required_integration":"original_environment.update_focus must return while camera source_dof_owner is valid; original house DOF near/far cache writes must also defer to this owner",
		"source_kernel":"Circle: source Fstop .08/.4 <= MinFstop1.2",
		"godot_gather_quality":"HIGH; cross-engine circle gather adaptation, jitter disabled",
		"shape_restore_source":"options.previous_bokeh_shape, otherwise startup ProjectSettings; engine exposes no runtime getter",
		"limits":["Godot gather/recombine and depth/alpha behavior differ from UE DiaphragmDOF.",
			"Godot physical gather has fixed 32px radius cap; UE source cap is .025*width. Report exposes mismatch.",
			"Camera focal-region and transition-region source fields belong to other DOF paths, not source Diaphragm CoC.",
			"GPU integration validation is recorded separately from the source formula checks."]},true)
	return report

func _process(_delta: float) -> void:
	_update()

func _update() -> void:
	if not is_instance_valid(_camera) or _camera.attributes!=_attributes: return
	var viewport := _camera.get_viewport()
	var width := _width_override
	# canvas_items stretch keeps a logical visible_rect; DOF operates on the
	# render texture's physical pixels, which can differ from that logical width.
	if width<=0: width=maxi(1,roundi(viewport.get_texture().get_width()*viewport.scaling_3d_scale))
	var projection := _camera.get_camera_projection()
	var state: Dictionary=_policy.interior if _inside else _policy.exterior
	var sensor: float=_policy.sensor_width_mm
	var focus: float=state.focus_cm*0.01
	var fstop: float=state.fstop
	var focal_mm: float=sensor*0.5*projection.x.x
	var radius: float=float(width)*focal_mm*focal_mm/(2.0*sensor*fstop*(focus*1000.0-focal_mm))
	var signature := "%s:%s:%s:%s" % [width,projection.x.x,focus,fstop]
	if signature==_signature: return
	_signature=signature
	_attributes.dof_blur_near_enabled=true
	_attributes.dof_blur_far_enabled=true
	_attributes.dof_blur_near_distance=focus
	_attributes.dof_blur_far_distance=focus
	_attributes.dof_blur_near_transition=-1.0
	_attributes.dof_blur_far_transition=-1.0
	_attributes.dof_blur_amount=radius/64.0
	report.merge({"inside":_inside,"internal_width":width,"projection_x":projection.x.x,
		"logical_viewport_width":viewport.get_visible_rect().size.x,"render_texture_width":viewport.get_texture().get_width(),
		"source_focus_m":focus,"source_fstop":fstop,"source_focal_length_mm":focal_mm,
		"infinity_coc_radius_px":radius,"godot_amount":radius/64.0,
		"source_radius_cap_px":width*float(_policy.max_background_radius_fraction),
		"godot_physical_gather_cap_px":32.0,
		"formula":"radius(z)=infinity_radius*(z-focus)/z; near negative"},true)
	print("SOURCE_DOF_UPDATED ",JSON.stringify(report))

func set_house_state(inside: bool) -> void:
	_inside=inside
	_update()

func attach_house_driver(driver: Node) -> Dictionary:
	_detach_house()
	if not is_instance_valid(driver) or not driver.has_signal("house_state_changed"):
		return {"error":"Expected house_state_changed signal."}
	_house=driver
	driver.connect("house_state_changed",Callable(self,"set_house_state"))
	var current: Variant=driver.get("is_in_house")
	set_house_state(current is bool and current)
	return {"attached":true}

func _detach_house() -> void:
	if is_instance_valid(_house) and _house.is_connected("house_state_changed",Callable(self,"set_house_state")):
		_house.disconnect("house_state_changed",Callable(self,"set_house_state"))
	_house=null

func restore() -> Dictionary:
	_detach_house()
	var restored := false
	if is_instance_valid(_camera):
		if _camera.attributes==_attributes:
			_camera.attributes=_previous
			restored=true
		if _camera.has_meta("source_dof_owner") and _camera.get_meta("source_dof_owner")==self: _camera.remove_meta("source_dof_owner")
	if _shape_installed:
		RenderingServer.camera_attributes_set_dof_blur_bokeh_shape(_previous_shape)
		RenderingServer.camera_attributes_set_dof_blur_quality(_previous_quality,_previous_jitter)
		_shape_installed=false
	_camera=null
	_attributes=null
	_previous=null
	_signature=""
	set_process(false)
	return {"restored":restored}

func _exit_tree() -> void:
	restore()
