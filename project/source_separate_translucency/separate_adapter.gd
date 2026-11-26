extends Node
## Only three source AfterDOF emitter materials. Existing simulation and mesh are retained.
const SOURCES := {
	"/Game/JH/Particles/Fire/Materials/TorcheFire_fwd3_D_Inst.TorcheFire_fwd3_D_Inst":0,
	"/Game/JH/Particles/Fire/Materials/Flame_Inst1.Flame_Inst1":1,
	"/Game/JH/Particles/Particles_Wind_Control_System/Materials/M_Fireflies.M_Fireflies":3,
}
var report: Dictionary = {}
var effect
var _camera: Camera3D
var _previous: Compositor
var _installed: Compositor
var _draws: Array[Dictionary] = []
var _fallback_texture: Texture2D
var _routed := false
var _upstream_dof: CompositorEffect
var _upstream_owner: Node
var _before_dof: Compositor
# Test-only: retain the original draws and capture their direct HDR output.
var diagnostic_reference_only := false

func install(scene: Node, placement: String="after_dof") -> Dictionary:
	if is_instance_valid(_camera): return {"error":"Restore first."}
	if placement not in ["after_dof","before_dof"]: return {"error":"Unknown diagnostic placement."}
	_camera=scene.camera
	if _camera.projection!=Camera3D.PROJECTION_PERSPECTIVE:return {"error":"Only the source perspective camera has audited sorting."}
	_previous=_camera.compositor
	if _previous==null: return {"error":"Source renderer must be installed first."}
	var dof_index := -1
	var bloom_index := -1
	for i in _previous.compositor_effects.size():
		var script: Script=_previous.compositor_effects[i].get_script()
		if script==null: continue
		if script.resource_path.get_file()=="source_hdr_dof_effect.gd": dof_index=i
		if script.resource_path.get_file()=="original_native_bloom.gd": bloom_index=i
	if dof_index<0 or bloom_index!=dof_index+1: return {"error":"Expected adjacent source HDR DOF / Bloom."}
	_upstream_dof=_previous.compositor_effects[dof_index]
	_upstream_owner=_camera.get_meta("source_dof_owner",null)
	if not is_instance_valid(_upstream_owner):return {"error":"Source HDR DOF owner is unavailable."}
	_before_dof=_upstream_owner.get("_previous_compositor")
	if _before_dof==null:return {"error":"Source HDR DOF restoration chain is unavailable."}
	var pending: Array[Node] = [scene.world]
	var mesh: Mesh
	while not pending.is_empty():
		var node: Node=pending.pop_back()
		# Stack traversal keeps source scene child order for equal-priority/depth ties.
		var children := node.get_children()
		children.reverse()
		for child in children: pending.append(child)
		if not node is MultiMeshInstance3D: continue
		var draw := node as MultiMeshInstance3D
		var material := draw.material_override as ShaderMaterial
		if material==null: continue
		var source := str(material.get_meta("source_material",""))
		if not SOURCES.has(source): continue
		var mode: Variant=material.get_shader_parameter("material_mode")
		var alignment: Variant=material.get_shader_parameter("source_alignment")
		if mode==null or int(mode)!=SOURCES[source] or alignment==null or int(alignment) not in [0,2]:
			return {"error":"Source emitter mode/alignment changed; candidate refused.","source":source}
		if not material.shader.code.contains("source_height_fog") or not material.shader.code.contains("unshaded"):
			return {"error":"Expected source height-fog and unlit/emission material.","source":source}
		if draw.multimesh==null or draw.multimesh.mesh==null: return {"error":"Existing source quad unavailable."}
		if mesh==null: mesh=draw.multimesh.mesh
		elif mesh!=draw.multimesh.mesh: return {"error":"Distinct source meshes need separate audited uploads."}
		_draws.append({"draw":draw,"material":material,"layers":draw.layers,"source":source,"order":_draws.size(),"mesh":draw.multimesh.mesh})
	var expected := 2 if str(scene.slug)=="wuming" else 1
	if _draws.size()!=expected: return {"error":"Source AfterDOF emitter count differs.","found":_draws.size(),"expected":expected}
	_fallback_texture=load("res://assets/environment/particles/native_transparent/Flame_native.dds")
	var effect_script: Script=load(get_script().resource_path.get_base_dir().path_join("separate_effect.gd"))
	if effect_script==null or not effect_script.can_instantiate(): return {"error":"Separate effect script could not compile."}
	effect=effect_script.new()
	var uploaded: Dictionary=effect.configure_mesh(mesh)
	if uploaded.has("error"): return uploaded
	effect.failed.connect(_on_failed)
	var effects: Array[CompositorEffect] = []
	for i in _previous.compositor_effects.size():
		if (placement=="before_dof" and i==dof_index) or (placement=="after_dof" and i==bloom_index): effects.append(effect)
		effects.append(_previous.compositor_effects[i])
	_installed=Compositor.new()
	_installed.compositor_effects=effects
	_camera.compositor=_installed
	_upstream_dof.connect("failed",_on_upstream_failed)
	for item in _draws:
		item.visibility_callback=_source_visibility_changed.bind(item.draw)
		item.draw.visibility_changed.connect(item.visibility_callback)
	process_priority=120
	report={"status":"waiting_for_gpu","placement":placement,"emitter_count":_draws.size(),"mesh":uploaded,"sources":[],"frames":0,
		"limitations":["Three source default-AfterDOF emitters only; not complete UE separate-translucency resolution/recombine.","Source cvar default 1 is proven; live original frame cvar not captured.","Retains current adapter particle sort order and reconstructed source fog; native random sequence remains separate.","GPU and live visual validation required before production."]}
	for item in _draws: report.sources.append({"source":item.source,"node":str(item.draw.get_path()),"component":item.draw.get_meta("source_component",""),"emitter":item.draw.get_meta("source_emitter","")})
	return report

func _value(material: ShaderMaterial, name: String, fallback: Variant) -> Variant:
	var value: Variant=material.get_shader_parameter(name)
	return fallback if value==null else value

func _vec(data: PackedFloat32Array, v: Vector3, w: float) -> void:
	data.append_array(PackedFloat32Array([v.x,v.y,v.z,w]))

func _parameters(material: ShaderMaterial) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.append_array(PackedFloat32Array([float(_value(material,"material_mode",-1)),float(_value(material,"source_depth_fade_cm",100)),float(_value(material,"source_emission",1)),float(_value(material,"source_mip_bias",0))]))
	var atlas: Vector2=_value(material,"atlas",Vector2.ONE)
	data.append_array(PackedFloat32Array([atlas.x,atlas.y,1,float(_value(material,"audit_mode",0))]))
	_vec(data,_value(material,"source_hf_layer0",Vector3.ZERO),float(_value(material,"source_hf_max_opacity",0)))
	_vec(data,_value(material,"source_hf_layer1",Vector3.ZERO),float(_value(material,"source_hf_start_cm",0)))
	_vec(data,_value(material,"source_hf_color",Vector3.ZERO),float(_value(material,"source_hf_cutoff_cm",0)))
	_vec(data,_value(material,"source_hf_direction",Vector3.ZERO),float(_value(material,"source_hf_max_observer_height_cm",65536)))
	_vec(data,_value(material,"source_hf_directional_color",Vector3.ZERO),float(_value(material,"source_hf_directional_exponent",4)))
	data.append_array(PackedFloat32Array([float(_value(material,"source_hf_directional_start_cm",0)),float(_value(material,"source_hf_sun_scale",1)),1.0 if bool(_value(material,"source_hf_directional_enabled",false)) else 0.0,0]))
	return data

func refresh_snapshot() -> void:
	if effect==null or effect.report.get("status","")!="ready" or not is_instance_valid(_camera): return
	if _camera.compositor!=_installed:
		_on_failed("Source compositor owner changed; restoring original particle draws.")
		return
	if _upstream_dof==null:
		_on_failed("Source HDR DOF owner is missing; restoring original particle draws.")
		return
	if not is_instance_valid(_upstream_owner) or _upstream_owner.get("effect")!=_upstream_dof:
		# Explicit owner.restore() cannot remove a compositor wrapped by this
		# module. Complete that restoration without keeping its disabled wrapper.
		_previous=_before_dof
		_on_failed("Source HDR DOF ownership ended; restoring the pre-DOF camera chain.")
		return
	# Existing source diagnostics temporarily disable DOF while retaining its
	# compositor and owner. Keep this layer valid across that reversible pause;
	# only the real failed signal unwinds the complete upstream camera chain.
	var groups: Array = []
	for item in _draws:
		var draw: MultiMeshInstance3D=item.draw
		if not is_instance_valid(draw): continue
		if draw.material_override!=item.material or draw.multimesh==null or draw.multimesh.mesh!=item.mesh:
			_on_failed("Source material or mesh owner changed; restore required.")
			return
		# Keep the node's source visibility, layers and simulation untouched. Changing
		# layers to zero can leave Godot LIGHT pairs stale during later unpairing.
		# Server visibility false unpairs while the original layer mask still exists.
		RenderingServer.instance_set_visible(draw.get_instance(),draw.is_visible_in_tree() if diagnostic_reference_only else false)
		if not draw.is_visible_in_tree() or (int(draw.layers)&_camera.cull_mask)==0: continue
		var multi := draw.multimesh
		var count := multi.visible_instance_count if multi.visible_instance_count>=0 else multi.instance_count
		var material: ShaderMaterial=item.material
		var pivot: Vector2=_value(material,"pivot",Vector2.ZERO)
		var lock_vertical: bool=_value(material,"lock_vertical",false)
		var alignment: int=_value(material,"source_alignment",0)
		var axis: Vector3=_value(material,"source_lock_axis",Vector3.UP)
		var data := PackedFloat32Array()
		for i in count:
			var transform := draw.global_transform*multi.get_instance_transform(i)
			var custom := multi.get_instance_custom_data(i)
			var tint := multi.get_instance_color(i)
			_vec(data,transform.origin,custom.r)
			_vec(data,Vector3(transform.basis.x.length(),transform.basis.y.length(),transform.basis.z.length()),custom.g)
			data.append_array(PackedFloat32Array([tint.r,tint.g,tint.b,tint.a,pivot.x,pivot.y,1.0 if lock_vertical else 0.0,float(alignment)]))
			_vec(data,axis,0)
		var texture: Texture2D=_value(material,"source_texture",_fallback_texture)
		# Godot's perspective alpha key is Euclidean distance to the transformed
		# AABB centre (or node origin), minus the explicit sorting offset.
		var center := draw.global_position
		if draw.sorting_use_aabb_center:
			var bounds: AABB=draw.custom_aabb
			if bounds.size==Vector3.ZERO:bounds=multi.get_aabb()
			center=(draw.global_transform*bounds).get_center()
		var depth := _camera.global_position.distance_to(center)-draw.sorting_offset
		groups.append({"id":draw.get_instance_id(),"instances":data.to_byte_array(),"count":count,"parameters":_parameters(material),"texture":texture,"depth":depth,"order":item.order,"priority":material.render_priority})
	groups.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:
		if a.priority!=b.priority: return a.priority<b.priority
		if a.depth!=b.depth: return a.depth>b.depth
		return a.order<b.order)
	effect.submit([] if diagnostic_reference_only else groups)
	_routed=true
	report.status="routed"
	report.frames=int(report.frames)+1

func _process(_delta: float) -> void:
	refresh_snapshot()

func _source_visibility_changed(draw: MultiMeshInstance3D) -> void:
	# Node3D emits this after its normal server visibility notification, including
	# parent show/hide. Keep source state authoritative while preventing a late
	# deferred visibility change from drawing both routes during the same frame.
	if not _routed or effect==null or effect.report.get("status","")!="ready":return
	if is_instance_valid(draw):
		RenderingServer.instance_set_visible(draw.get_instance(),draw.is_visible_in_tree() if diagnostic_reference_only else false)
	refresh_snapshot()

func _on_failed(message: String) -> void:
	report.error=message
	report.status="failed; original routing restored"
	restore()

func _on_upstream_failed(message: String) -> void:
	# The DOF owner connected its handler before this adapter. It has already
	# restored attributes, but our nested compositor prevented its identity-based
	# compositor restoration. Restore the saved pre-DOF chain, not the disabled
	# DOF wrapper. An unrelated replacement camera compositor remains untouched.
	report.error="Upstream HDR DOF failed: "+message
	report.status="failed; original routing and pre-DOF camera chain restored"
	_previous=_before_dof
	restore()

func restore() -> Dictionary:
	var restored := 0
	_routed=false
	if _upstream_dof!=null and _upstream_dof.is_connected("failed",_on_upstream_failed):
		_upstream_dof.disconnect("failed",_on_upstream_failed)
	for item in _draws:
		if is_instance_valid(item.draw) and item.has("visibility_callback") and item.draw.visibility_changed.is_connected(item.visibility_callback):
			item.draw.visibility_changed.disconnect(item.visibility_callback)
	for item in _draws:
		if is_instance_valid(item.draw):
			RenderingServer.instance_set_visible(item.draw.get_instance(),item.draw.is_visible_in_tree())
			restored+=1
	if is_instance_valid(_camera) and _camera.compositor==_installed: _camera.compositor=_previous
	if effect!=null:
		effect.enabled=false
		if effect.failed.is_connected(_on_failed): effect.failed.disconnect(_on_failed)
	effect=null
	_draws.clear()
	_camera=null
	_previous=null
	_installed=null
	_upstream_dof=null
	_upstream_owner=null
	_before_dof=null
	_fallback_texture=null
	_routed=false
	return {"source_instance_visibility_restored":restored,"source_layers_modified":false}

func _exit_tree() -> void:
	restore()
