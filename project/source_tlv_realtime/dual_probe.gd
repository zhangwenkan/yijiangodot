extends Node
## Shares original world and existing Blender-authored draw mesh. No geometry edits.
var viewports: Array[SubViewport] = []
var cameras: Array[Camera3D] = []
var materials: Array[ShaderMaterial] = []
var effects: Array[CompositorEffect] = []
var layers: Array[int] = []
var sun: DirectionalLight3D
var source_lf: ShaderMaterial
var main_camera: Camera3D
var original_mask := 0
var installed_mask := 0

func install(scene: Node3D, bridge: RefCounted) -> Dictionary:
	main_camera=scene.camera
	original_mask=main_camera.cull_mask
	var suns: Array[Node] = scene.world.find_children("*","DirectionalLight3D",true,false)
	if suns.size()!=1: return {"error":"Exactly one source directional light is required."}
	sun=suns[0]
	source_lf=scene.source_renderer._find_lightfunction_material(scene.world)
	if source_lf==null or source_lf.shader==null: return {"error":"Source LightFunction owner missing."}
	var used := _used_geometry_layers(scene)
	for bit in range(19,-1,-1):
		var layer := 1<<bit
		if (used&layer)==0 and (sun.light_cull_mask&layer)!=0: layers.append(layer)
		if layers.size()==2: break
	if layers.size()!=2: return {"error":"Need two unused geometry layers already covered by the original sun mask."}
	var resource := load("res://assets/environment/particles/particle-draw.glb") as PackedScene
	if resource==null: return {"error":"Existing Blender particle draw mesh missing."}
	var packed := resource.instantiate()
	var mesh: Mesh
	for child in packed.find_children("*","MeshInstance3D",true,false):
		if str(child.name).begins_with("SourceParticleSpriteDraw"): mesh=child.mesh
	packed.free()
	if mesh==null: return {"error":"Existing Blender draw quad not found."}
	installed_mask=original_mask&~(layers[0]|layers[1])
	for cascade in 2:
		var viewport := SubViewport.new()
		viewport.name="SunTLVProbe"+str(cascade)
		viewport.size=Vector2i(512,512)
		viewport.world_3d=scene.get_world_3d()
		viewport.msaa_3d=Viewport.MSAA_DISABLED
		viewport.use_taa=false
		viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
		add_child(viewport)
		var camera := Camera3D.new()
		viewport.add_child(camera)
		camera.projection=Camera3D.PROJECTION_ORTHOGONAL
		camera.cull_mask=installed_mask|layers[cascade]
		camera.current=true
		var environment := Environment.new()
		environment.background_mode=Environment.BG_COLOR
		environment.background_color=Color.BLACK
		environment.ambient_light_source=Environment.AMBIENT_SOURCE_DISABLED
		environment.reflected_light_source=Environment.REFLECTION_SOURCE_DISABLED
		environment.tonemap_mode=Environment.TONE_MAPPER_LINEAR
		camera.environment=environment
		var effect := preload("res://source_tlv_realtime/probe_effect.gd").new()
		effect.bridge=bridge
		effect.cascade=cascade
		camera.compositor=Compositor.new()
		camera.compositor.compositor_effects=[effect]
		var material := ShaderMaterial.new()
		material.shader=preload("res://source_tlv_candidate/sun_volume_probe.gdshader")
		material.render_priority=127
		var draw := MeshInstance3D.new()
		draw.mesh=mesh
		draw.layers=layers[cascade]
		draw.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		draw.extra_cull_margin=4.0
		draw.material_override=material
		camera.add_child(draw)
		draw.position.z=-1.0
		viewports.append(viewport); cameras.append(camera); materials.append(material); effects.append(effect)
	main_camera.cull_mask=installed_mask
	return {"status":"installed","query_layers":layers,"original_mask":original_mask,"installed_mask":installed_mask}

func _used_geometry_layers(node: Node) -> int:
	var result: int = node.layers if node is VisualInstance3D else 0
	for child in node.get_children(): result |= _used_geometry_layers(child)
	return result

func snapshot_light() -> Dictionary:
	if not is_instance_valid(sun) or not sun.is_visible_in_tree() or source_lf==null or source_lf.shader==null:
		return {"error":"Source sun/LF owner unavailable."}
	var lf: Dictionary = {}
	for pair in [["lf_local_y","source_lf_local_y"],["lf_local_z","source_lf_local_z"],
		["lf_tiling_power","source_lf_tiling_power"],["lf_speeds","source_lf_speeds"]]:
		var values: Variant = source_lf.get_shader_parameter(pair[1])
		if values==null or values.size()<1: return {"error":"Missing LF array: "+str(pair[1])}
		lf[pair[0]]=values[0]
	var scale_values: Variant = source_lf.get_shader_parameter("source_lf_scale_fade")
	if scale_values==null or scale_values.size()<1: return {"error":"Missing LF scale."}
	var scale4: Vector4 = scale_values[0]
	if not scale4.is_finite() or is_zero_approx(scale4.x) or is_zero_approx(scale4.y): return {"error":"Invalid LF scale."}
	lf.lf_scale=Vector2(scale4.x,scale4.y)
	for key in ["spot_offsets","spot_sizes","sun_color","cloud1","cloud2"]:
		var value: Variant = source_lf.get_shader_parameter("source_lf_"+key)
		if value==null: return {"error":"Missing LF value: "+key}
		lf["lf_"+key]=value
	var direction := sun.global_basis.z.normalized()
	var color := sun.light_color.srgb_to_linear()
	var radiance := Vector3(color.r,color.g,color.b)*sun.light_energy
	if not direction.is_finite() or not radiance.is_finite(): return {"error":"Nonfinite source light."}
	lf.sun_world_direction=direction
	lf.lf_enabled=not bool(sun.get_meta("source_house_light_function_disabled",false))
	var shadow_state: Dictionary = {}
	for property in sun.get_property_list():
		var name := str(property.name)
		if name.begins_with("shadow_") or name.begins_with("directional_shadow_") or name.begins_with("distance_fade_"):
			shadow_state[name]=sun.get(name)
	var identity := [sun.get_instance_id(),source_lf.get_instance_id(),source_lf.shader.get_instance_id(),
		source_lf.shader.code.sha256_text(),sun.light_cull_mask,sun.shadow_enabled,sun.directional_shadow_mode,
		sun.directional_shadow_max_distance,sun.global_transform,sun.light_color,sun.light_energy,shadow_state,lf]
	return {"lf":lf,"radiance":radiance,"direction_ue":Vector3(direction.x,direction.z,direction.y),
		"light_fingerprint":hash(identity),"shadow_state":shadow_state,"sun_id":sun.get_instance_id(),"lf_id":source_lf.get_instance_id()}

func arm(snapshot: Dictionary) -> String:
	if not is_instance_valid(main_camera) or main_camera.cull_mask!=installed_mask: return "Main camera/layer owner changed."
	for cascade in 2:
		var material: ShaderMaterial = materials[cascade]
		for key in snapshot.lf: material.set_shader_parameter(key,snapshot.lf[key])
		var bound: Dictionary = snapshot.bounds[cascade]
		material.set_shader_parameter("volume_min_ue_cm",bound.min_ue_cm)
		material.set_shader_parameter("voxel_cm",bound.voxel_cm)
		var center: Vector3 = (bound.min_ue_cm+Vector3.ONE*float(bound.voxel_cm)*32.0)*0.01
		center=Vector3(center.x,center.z,center.y)
		var size_m := float(bound.voxel_cm)*66.0*0.01
		cameras[cascade].position=center+Vector3(0,0,size_m)
		cameras[cascade].near=0.01
		cameras[cascade].far=size_m*2.0
		cameras[cascade].size=size_m
		if not effects[cascade].arm(snapshot):
			for effect in effects: effect.disarm(int(snapshot.snapshot_id))
			return "Probe already has an unconsumed request."
	for viewport in viewports: viewport.render_target_update_mode=SubViewport.UPDATE_ONCE
	return ""

func cancel(token: int) -> void:
	for effect in effects: effect.disarm(token)
	for viewport in viewports: viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED

func restore() -> Dictionary:
	var errors: Array[String] = []
	for viewport in viewports: viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
	for camera in cameras: camera.compositor=null
	if is_instance_valid(main_camera):
		if main_camera.cull_mask==installed_mask: main_camera.cull_mask=original_mask
		else: errors.append("Main camera cull owner changed; its mask was not overwritten.")
	for viewport in viewports: viewport.queue_free()
	viewports.clear(); cameras.clear(); materials.clear(); effects.clear()
	return {"errors":errors}
