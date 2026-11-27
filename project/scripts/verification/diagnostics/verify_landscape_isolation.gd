extends "res://scripts/verification/diagnostics/verify_tlv_drift.gd"
## Explicit diagnostic: original geometry and lights; only runtime visibility/shader controls.
## The existing raw-count builder, material checks and readback implementation are inherited.

var _phase := "whole-before"
var _isolated := false
var _target_node: MeshInstance3D
var _geometry_states: Array[Dictionary] = []
var _geometry_expected: Array = []
var _lights_expected: Array = []
var _original_effects: Array[CompositorEffect] = []
var _diagnostic_effects: Array[CompositorEffect] = []
var _original_compositor: Compositor
var _camera_transform := Transform3D.IDENTITY
var _material_baseline: Dictionary = {}
var _material_json := ""
var _source_hashes: Dictionary = {}

const INPUTS := [
	"res://scripts/verification/diagnostics/verify_landscape_isolation.gd",
	"res://scripts/verification/diagnostics/verify_tlv_drift.gd",
	"res://scripts/verification/diagnostics/stage_readback.gd",
	"res://scripts/verification/verify_source_tlv_receiver.gd",
	"res://scripts/worlds.gd", "res://scripts/original_environment.gd",
	"res://scripts/original_compiled_landscape.gd", "res://scripts/original_lightfunctions.gd",
	"res://scripts/original_source_renderer.gd", "res://shaders/original_landscape_compiled.gdshader",
	"res://shaders/original_lightfunction_receiving.gdshaderinc",
	"res://shaders/original_lightfunction_compiled.gdshaderinc",
	"res://source_lighting_candidate/original_local_cone.gdshaderinc",
	"res://source_lighting_candidate/original_local_cone_adapter.gd",
	"res://source_separate_translucency/separate_adapter.gd",
	"res://source_separate_translucency/separate_effect.gd"
]

func _write_json(name: String, value: Variant) -> String:
	var text := JSON.stringify(value,"\t")
	FileAccess.open(out.path_join(name),FileAccess.WRITE).store_string(text)
	return text.sha256_text()

func _stored(node: Object) -> Dictionary:
	var properties: Dictionary = {}
	for property in node.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_STORAGE)!=0:
			properties[str(property.name)] = landscape_value_record(node.get(property.name))
	return properties

func _node_record(node: Node3D) -> Dictionary:
	var metadata: Dictionary = {}
	for key in node.get_meta_list(): metadata[str(key)] = landscape_value_record(node.get_meta(key))
	return {"node":str(node.get_path()),"instance_id":node.get_instance_id(),"class":node.get_class(),
		"global_transform":var_to_str(node.global_transform),"visible":node.visible,
		"visible_in_tree":node.is_visible_in_tree(),"stored_properties":_stored(node),"metadata":metadata}

func _light_records() -> Array:
	var result: Array = []
	for node in scene.find_children("*","Light3D",true,false): result.append(_node_record(node))
	return result

func _geometry_records() -> Array:
	var result: Array = []
	for state in _geometry_states: result.append(_node_record(state.node))
	return result

func _source_snapshot() -> Dictionary:
	var result: Dictionary = {}
	for path in INPUTS: result[path] = FileAccess.get_sha256(path)
	return result

func _assert_state(label: String) -> void:
	var first: int = report.failures.size()
	var lights := _light_records()
	var geometry := _geometry_records()
	var lights_json := JSON.stringify(lights,"\t")
	var geometry_json := JSON.stringify(geometry,"\t")
	check(lights==_lights_expected,label+": original Light3D properties/visibility/transforms changed")
	check(geometry==_geometry_expected,label+": geometry state differs from this phase's explicit visibility state")
	check(scene.camera.global_transform==_camera_transform,label+": camera transform changed")
	check(scene.process_mode==Node.PROCESS_MODE_DISABLED and Engine.time_scale==0.0,label+": scene is not frozen")
	check(scene.camera.compositor==_original_compositor,label+": compositor identity changed")
	check(_original_compositor.compositor_effects==_diagnostic_effects,label+": diagnostic compositor effect order changed")
	var owner: Node = scene.source_renderer.separate_translucency
	check(is_instance_valid(owner),label+": separate-translucency owner missing")
	if is_instance_valid(owner):
		check(owner._installed==_original_compositor,label+": separate-translucency compositor owner changed")
		check(not owner.report.has("error"),label+": separate-translucency owner failed")
	var visible_geometry: Array[String] = []
	for state in _geometry_states:
		var node: GeometryInstance3D = state.node
		if node.is_visible_in_tree() and (node.layers & scene.camera.cull_mask)!=0:
			visible_geometry.append(str(node.get_path()))
	if _isolated:
		check(visible_geometry==[str(_target_node.get_path())],label+": isolated camera has geometry other than the identified landscape")
	report.isolation.state_checks.append({"label":label,"passed":report.failures.size()==first,
		"lights_sha256":lights_json.sha256_text(),"light_count":lights.size(),
		"geometry_sha256":geometry_json.sha256_text(),"geometry_count":geometry.size(),
		"visible_geometry_count":visible_geometry.size(),
		"visible_geometry":visible_geometry if _isolated else [],
		"isolated":_isolated,"compositor_identity_preserved":scene.camera.compositor==_original_compositor})

func save_distortion(label: String) -> void:
	var name := _phase+"-"+label
	_assert_state("before-"+name)
	await super.save_distortion(name)
	_assert_state("after-"+name)

func _identify() -> bool:
	var found: Array[MeshInstance3D] = []
	for node in scene.world.find_children("*","MeshInstance3D",true,false):
		if str(node.name)!="OriginalLandscape_youxian": continue
		var material: Material = node.material_override
		if node.get_meta("original_landscape",false)!=true or str(node.get_meta("map_slug",""))!="youxian": continue
		if not material is ShaderMaterial or material.shader==null: continue
		if material.resource_name!="OriginalLandscape_Compiled_youxian": continue
		if material.get_meta("source_landscape_compiled",false)!=true or str(material.get_meta("source_surface_family",""))!="M_TFK_Dipi01": continue
		found.append(node)
	check(found.size()==1,"Isolation requires exactly one identified source landscape")
	if found.size()!=1: return false
	_target_node = found[0]
	check(_target_node.is_visible_in_tree() and (_target_node.layers & scene.camera.cull_mask)!=0,"Original landscape is not visible in the source camera")
	check(_target_node.material_overlay==null and _target_node.material_override.next_pass==null,"Target landscape has an additional material pass")
	return report.failures.is_empty()

func _set_isolation(enabled: bool) -> void:
	for state in _geometry_states:
		var node: GeometryInstance3D = state.node
		node.visible = bool(state.visible) if not enabled or node==_target_node else false
	_isolated = enabled
	# Keep every property except local/effective visibility byte-for-byte equal.
	var current := _geometry_records()
	for i in current.size():
		var previous: Dictionary = _geometry_states[i].record
		var adjusted: Dictionary = previous.duplicate(true)
		if enabled and _geometry_states[i].node!=_target_node:
			adjusted.visible = false
			adjusted.visible_in_tree = false
			adjusted.stored_properties.visible = landscape_value_record(false)
		check(current[i]==adjusted,"Visibility control changed another geometry property: "+str(previous.node))
	_geometry_expected = current
	var name := "geometry-isolated.json" if enabled else "geometry-restored.json"
	report.isolation[name] = {"sha256":_write_json(name,current),"count":current.size()}

func _restore_target() -> void:
	var material: ShaderMaterial = _target_node.material_override
	var state: Dictionary = _material_baseline[material.get_instance_id()]
	check(material.shader==state.shader,"Raw-count control did not restore original shader before outer cleanup")
	if material.shader!=state.shader:
		material.shader = state.shader
		for key in state.parameters: material.set_shader_parameter(key,state.parameters[key])
	var current := JSON.stringify(landscape_material_records(landscape_snapshot_materials()),"\t")
	check(current==_material_json,"All-material snapshot differs after isolated shader restoration")

func run() -> void:
	if out.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	report = {"maps":[],"captures":[],"failures":[],"isolation":{"state_checks":[]},
		"scope":"Frozen original Youxian landscape with original lights; non-target geometry visibility is the only scene subtraction. No new geometry, production change, RenderDoc or claimed drift repair. PNG is later than HDR."}
	var args := OS.get_cmdline_user_args()
	check("--drift-landscape-raw-count-controls" in args,"Explicit inherited raw-count flag is required")
	check("--map=youxian" in args,"Direct Youxian startup is required")
	for arg in args:
		check(not str(arg).begins_with("--drift-renderdoc"),"RenderDoc options are not permitted in this diagnostic")
		if str(arg).begins_with("--drift-") and arg!="--drift-landscape-raw-count-controls": check(false,"Unexpected additional diagnostic control: "+arg)
	_source_hashes = _source_snapshot()
	_write_json("input-sha256.json",_source_hashes)
	for path in _source_hashes: check(not str(_source_hashes[path]).is_empty(),"Missing input source "+path)
	if not report.failures.is_empty(): progress("rejected"); quit(2); return
	root.size = Vector2i(960,540)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading: await process_frame
	scene.tour_finished = true
	await settle(40)
	check(scene.slug=="youxian","Unexpected startup map")
	if not _identify():
		progress("rejected")
		scene.queue_free()
		await settle(5)
		quit(2)
		return
	var old_mode: int = scene.process_mode
	var old_time := Engine.time_scale
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	Engine.time_scale = 0.0
	synchronize_frozen_light_function()
	_camera_transform = scene.camera.global_transform
	report.camera = str(_camera_transform)
	report.environment = {"msaa":root.msaa_3d,"taa":root.use_taa,"screen_aa":root.screen_space_aa}
	_material_baseline = landscape_snapshot_materials()
	_material_json = JSON.stringify(landscape_material_records(_material_baseline),"\t")
	_write_json("all-materials-before.json",landscape_material_records(_material_baseline))
	check(_material_baseline.size()==370,"Expected 370 original referenced materials")
	_lights_expected = _light_records()
	report.isolation.lights = {"count":_lights_expected.size(),"sha256":_write_json("lights-before.json",_lights_expected),
		"scope":"All exposed stored Light3D properties, global transforms, effective visibility and metadata. CPU state, not GPU light/cluster buffer."}
	check(not _lights_expected.is_empty(),"Original lights missing")
	for node in scene.find_children("*","GeometryInstance3D",true,false):
		_geometry_states.append({"node":node,"visible":node.visible,"record":_node_record(node)})
	_geometry_expected = _geometry_records()
	report.isolation.geometry_before = {"count":_geometry_expected.size(),"sha256":_write_json("geometry-before.json",_geometry_expected)}
	var other_visuals: Array = []
	for node in scene.find_children("*","VisualInstance3D",true,false):
		if node is GeometryInstance3D or node is Light3D: continue
		other_visuals.append(_node_record(node))
		check(node is ReflectionProbe and not node.is_visible_in_tree(),"Unexpected active non-geometry visual instance: "+str(node.get_path()))
	_write_json("other-visual-instances.json",other_visuals)
	_original_compositor = scene.camera.compositor
	_original_effects.assign(_original_compositor.compositor_effects)
	for kind in [CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE,CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT,CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT]:
		var item: CompositorEffect = load("res://scripts/verification/diagnostics/stage_readback.gd").new()
		item.effect_callback_type = kind
		stage_effects.append(item)
	var effects: Array[CompositorEffect] = [stage_effects[0],stage_effects[1]]
	effects.append_array(_original_effects)
	effects.append(stage_effects[2])
	_diagnostic_effects.assign(effects)
	_original_compositor.compositor_effects = effects
	report.isolation.boundary = "Only the identified MeshInstance3D is visible in isolated POST_OPAQUE. Source sky/environment and lights remain. Hiding other geometry intentionally also removes its shadows/occlusion; this is diagnosis, not an equivalent full scene. The existing AfterDOF owner remains installed and follows visibility signals. Later HDR/PNG are retained but are not standalone opaque identity proof."
	progress("frozen inputs recorded")
	if report.failures.is_empty():
		for i in 4: await save_distortion("original-%02d" % i)
		_set_isolation(true)
		_phase = "isolated"
		await settle(20)
		_assert_state("isolated-before-controls")
		if report.failures.is_empty(): await run_landscape_controls("raw-count")
		_restore_target()
		_set_isolation(false)
		_phase = "whole-restored"
		await settle(20)
		_assert_state("whole-restored-before-captures")
		for i in 4: await save_distortion("original-%02d" % i)
	check(report.captures.size()==20,"Expected 20 captures across full/isolated/raw-count/restored conditions")
	var restored_materials := landscape_material_records(landscape_snapshot_materials())
	check(JSON.stringify(restored_materials,"\t")==_material_json,"Final all-material snapshot differs")
	_write_json("all-materials-restored.json",restored_materials)
	_write_json("lights-restored.json",_light_records())
	_assert_state("before-observer-removal")
	scene.camera.compositor = _original_compositor
	_original_compositor.compositor_effects = _original_effects
	check(scene.camera.compositor==_original_compositor and scene.camera.compositor.compositor_effects==_original_effects,"Compositor/effects restoration failed")
	report.isolation.compositor_restored = scene.camera.compositor==_original_compositor and scene.camera.compositor.compositor_effects==_original_effects
	effects.clear()
	_diagnostic_effects.clear()
	stage_effects.clear()
	var final_sources := _source_snapshot()
	check(final_sources==_source_hashes,"Input source files changed during diagnostic")
	_write_json("input-sha256-after.json",final_sources)
	report.isolation.shutdown = scene.source_renderer.shutdown()
	check(report.isolation.shutdown.get("status","")=="restored","Source renderer shutdown failed")
	scene.process_mode = old_mode
	Engine.time_scale = old_time
	report.isolation.controller_restored = scene.process_mode==old_mode and Engine.time_scale==old_time
	check(report.isolation.controller_restored,"Controller/time restoration failed")
	scene.queue_free()
	await settle(5)
	progress("complete")
	quit(0 if report.failures.is_empty() else 1)
