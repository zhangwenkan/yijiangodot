extends RefCounted
## Original BP_SceneNPC_Bird inherits MI_JHMaskLitSprite1 from BP_SceneNPC.
## Reuses the audited source ambient shader; owns no bird behavior or geometry.
const POLICY_PATH := "res://source_bird_candidate/source-bird-materials.json"
const SHADER_PATH := "res://source_ambient_candidate/original_ambient_lit_surface.gdshader"
var report: Dictionary = {}
var bindings: Array[Dictionary] = []

func _ue(matrix: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(matrix[0][0],matrix[2][0],matrix[1][0]),Vector3(matrix[0][2],matrix[2][2],matrix[1][2]),Vector3(matrix[0][1],matrix[2][1],matrix[1][1])),Vector3(matrix[0][3],matrix[2][3],matrix[1][3])*0.01)

func apply(scene: Node, map_name: String, reference: ShaderMaterial=null) -> Dictionary:
	restore()
	var value: Variant=JSON.parse_string(FileAccess.get_file_as_string(POLICY_PATH))
	if not value is Dictionary or value.get("schema","")!="source_bird_material_v1":
		return {"error":"Invalid source bird material policy."}
	var rows: Array=value.maps.get(map_name,[])
	report={"map":map_name,"expected":rows.size(),"bound":0,"unsupported":[],"nodes":[],
		"geometry_unchanged":true,"behavior_unchanged":true,
		"limits":["Reuses original ambient lit material adapter; Godot BRDF remains cross-engine.",
			"Source placeholder normal differs slightly from exact flat normal.",
			"Existing bird trigger, curve, path, scale, frame, pivot and shadow flags are preserved."]}
	var driver: Node
	for candidate in scene.world.find_children("*","Node",true,false):
		var script: Script=candidate.get_script()
		if script!=null and script.resource_path.ends_with("/original_animation.gd"):
			driver=candidate
			break
	if driver==null:
		if not rows.is_empty(): report.unsupported.append("Original animation driver absent.")
		return report
	var entries: Variant=driver.get("_birds")
	if not entries is Array or entries.size()!=rows.size():
		report.unsupported.append("Original bird order/count differs from source config.")
		return report
	var shader := load(SHADER_PATH) as Shader
	if shader==null:
		report.unsupported.append("Audited ambient shader absent.")
		return report
	for i in rows.size():
		var policy: Dictionary=rows[i]
		var entry: Dictionary=entries[i]
		var sprite: AnimatedSprite3D=entry.get("node")
		if not is_instance_valid(sprite):
			report.unsupported.append({"index":i,"reason":"Invalid bird sprite."})
			continue
		var source_transform: Transform3D=sprite.get_meta("source_actor_transform",Transform3D.IDENTITY)
		if not source_transform.is_equal_approx(_ue(policy.source_actor_matrix_ue)):
			report.unsupported.append({"index":i,"reason":"Source actor transform/order mismatch."})
			continue
		if sprite.billboard!=BaseMaterial3D.BILLBOARD_FIXED_Y:
			report.unsupported.append({"index":i,"reason":"Unexpected original bird billboard."})
			continue
		var mat:=ShaderMaterial.new()
		mat.shader=shader
		mat.resource_name="SourceBird_"+str(policy.material_name)
		mat.set_meta("source_surface_adapter",true)
		mat.set_meta("source_unshaded",false)
		mat.set_meta("source_material",str(policy.material))
		mat.set_meta("source_bird_material",true)
		mat.set_meta("source_component",str(policy.source_component))
		mat.set_shader_parameter("source_ambient_fixed_y",true)
		mat.set_shader_parameter("source_ambient_metallic",float(policy.metallic))
		mat.set_shader_parameter("source_ambient_roughness",float(policy.roughness))
		mat.set_shader_parameter("source_ambient_mask_dither",bool(policy.mask_dither))
		mat.set_shader_parameter("source_ambient_mask_y_offset",float(policy.mask_y_offset))
		if reference!=null and reference.shader!=null:
			for uniform in reference.shader.get_shader_uniform_list():
				if str(uniform.name).begins_with("source_lf_"):
					var parameter: Variant=reference.get_shader_parameter(uniform.name)
					if parameter!=null: mat.set_shader_parameter(uniform.name,parameter)
		var callback:=Callable(self,"_sync_frame").bind(sprite,mat)
		var before: Dictionary=_state(sprite)
		bindings.append({"sprite":sprite,"material":mat,"previous":sprite.material_override,
			"policy":policy,"callback":callback,"driver":driver,"entry":entry,"before":before})
		sprite.material_override=mat
		sprite.frame_changed.connect(callback)
		sprite.animation_changed.connect(callback)
		_sync_frame(sprite,mat)
		var unchanged:=before==_state(sprite)
		report.geometry_unchanged=report.geometry_unchanged and unchanged
		report.nodes.append({"source":policy.source_component,"index":i,"node":str(sprite.get_path()),
			"material":policy.material,"state_unchanged_at_bind":unchanged,
			"sprite_frames_id":sprite.sprite_frames.get_instance_id()})
		report.bound+=1
	report.status="installed" if report.bound==report.expected and report.unsupported.is_empty() else "partial"
	print("SOURCE_BIRD_MATERIALS_READY ",JSON.stringify({"map":map_name,"bound":report.bound,"unsupported":report.unsupported}))
	return report

func _state(sprite: AnimatedSprite3D) -> Dictionary:
	return {"transform":sprite.transform,"frames":sprite.sprite_frames,"offset":sprite.offset,
		"pixel_size":sprite.pixel_size,"animation":sprite.animation,"frame":sprite.frame,
		"progress":sprite.frame_progress,"filter":sprite.texture_filter,"billboard":sprite.billboard,
		"cast_shadow":sprite.cast_shadow,"modulate":sprite.modulate,"flip_h":sprite.flip_h,"flip_v":sprite.flip_v}

func _sync_frame(sprite: AnimatedSprite3D, material: ShaderMaterial) -> void:
	if not is_instance_valid(sprite) or material==null or sprite.sprite_frames==null: return
	if not sprite.sprite_frames.has_animation(sprite.animation): return
	var texture: Texture2D=sprite.sprite_frames.get_frame_texture(sprite.animation,sprite.frame)
	material.set_shader_parameter("source_ambient_atlas",texture.atlas if texture is AtlasTexture else texture)

func set_sun_enabled(enabled: bool) -> void:
	for binding in bindings: binding.material.set_shader_parameter("source_lf_sun_enabled",enabled)

func restore() -> Dictionary:
	var count:=0
	for binding in bindings:
		var sprite: AnimatedSprite3D=binding.sprite
		if not is_instance_valid(sprite): continue
		var callback: Callable=binding.callback
		if sprite.frame_changed.is_connected(callback): sprite.frame_changed.disconnect(callback)
		if sprite.animation_changed.is_connected(callback): sprite.animation_changed.disconnect(callback)
		if sprite.material_override==binding.material:
			sprite.material_override=binding.previous
			count+=1
	bindings.clear()
	return {"restored":count}

