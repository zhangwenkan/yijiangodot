extends RefCounted
## Restores source material inputs on existing sprites. Owns no behavior or geometry.
var report: Dictionary={}
var bindings: Array[Dictionary]=[]
var _policy: Dictionary={}
var _reference: ShaderMaterial

func apply(scene: Node, map_name: String, reference: ShaderMaterial=null) -> Dictionary:
	restore()
	var path: String=get_script().resource_path.get_base_dir().path_join("source-ambient-materials.json")
	var value: Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
	if not value is Dictionary or value.get("schema","")!="source_ambient_material_v1":
		return {"error":"Invalid ambient source-material policy."}
	_policy=value.maps.get(map_name,{})
	_reference=reference
	report={"map":map_name,"bound":0,"lit":0,"unlit":0,"nondither":0,"dither":0,
		"native_defaults":0,"unsupported":[],"materials":[],"geometry_unchanged":true,
		"limits":["Source lit shader default inputs and MaskDither permutation restored; Godot BRDF remains adapted.",
			"Flat placeholder normal approximation remains; native XY are -1/255, not exactly zero.",
			"Animation and behavior remain owned by original_ambient_sprites and source animal controller.",
			"Selection/damage events are inactive here; partial fade dither epoch is not synced to UE.",
			"Pixel filtering, image data, SpriteFrames, pivot, scale, shadow flags and transforms are preserved.",
			"Apply before source SH9, height fog and local cone scans; restore after they unwind."]}
	_visit(scene)
	_reference=null
	print("SOURCE_AMBIENT_MATERIALS_READY ",JSON.stringify({"map":map_name,"bound":report.bound,
		"lit":report.lit,"unlit":report.unlit,"unsupported":report.unsupported}))
	return report

func _visit(node: Node) -> void:
	var script: Script=node.get_script()
	if script!=null and script.resource_path.ends_with("/original_ambient_sprites.gd"):
		var entries: Variant=node.get("sprites")
		if entries is Array:
			for entry in entries:
				_bind(entry)
	for child in node.get_children(): _visit(child)

func _bind(entry: Dictionary) -> void:
	var sprite: AnimatedSprite3D=entry.sprite
	var definition: Dictionary=entry.definition
	var key:=str(definition.map)+"::"+str(int(definition.component))
	if not _policy.has(key):
		report.unsupported.append({"key":key,"reason":"No source-material evidence for this component."})
		return
	if sprite.billboard!=BaseMaterial3D.BILLBOARD_DISABLED and sprite.billboard!=BaseMaterial3D.BILLBOARD_FIXED_Y:
		report.unsupported.append({"key":key,"reason":"Unsupported existing billboard mode."})
		return
	var policy: Dictionary=_policy[key]
	var mat:=ShaderMaterial.new()
	var file_name:="original_ambient_lit_surface.gdshader" if bool(policy.lit) else "original_ambient_unlit_surface.gdshader"
	mat.shader=load(get_script().resource_path.get_base_dir().path_join(file_name))
	mat.resource_name="SourceAmbient_"+str(policy.material_name)
	mat.set_meta("source_surface_adapter",true)
	mat.set_meta("source_unshaded",not bool(policy.lit))
	mat.set_meta("source_material",str(policy.material))
	mat.set_meta("source_ambient_component",key)
	mat.set_shader_parameter("source_ambient_fixed_y",sprite.billboard==BaseMaterial3D.BILLBOARD_FIXED_Y)
	if bool(policy.lit):
		mat.set_shader_parameter("source_ambient_metallic",float(policy.metallic))
		mat.set_shader_parameter("source_ambient_roughness",float(policy.roughness))
		mat.set_shader_parameter("source_ambient_mask_dither",bool(policy.mask_dither))
		mat.set_shader_parameter("source_ambient_mask_y_offset",float(policy.mask_y_offset))
		if _reference!=null and _reference.shader!=null:
			for uniform in _reference.shader.get_shader_uniform_list():
				if str(uniform.name).begins_with("source_lf_"):
					var uniform_value: Variant=_reference.get_shader_parameter(uniform.name)
					if uniform_value!=null: mat.set_shader_parameter(uniform.name,uniform_value)
	var binding:={"sprite":sprite,"material":mat,"previous":sprite.material_override,
		"policy":policy,"definition":definition,"key":key}
	var callback:=Callable(self,"_sync_frame").bind(sprite,mat)
	binding["callback"]=callback
	bindings.append(binding)
	sprite.material_override=mat
	sprite.frame_changed.connect(callback)
	sprite.animation_changed.connect(callback)
	_sync_frame(sprite,mat)
	report.bound+=1
	if bool(policy.lit): report.lit+=1
	else: report.unlit+=1
	if bool(policy.mask_dither): report.dither+=1
	else: report.nondither+=1
	if bool(policy.native_default_material): report.native_defaults+=1
	report.materials.append({"key":key,"node":str(sprite.get_path()),"material":policy.material,
		"lit":policy.lit,"metallic":policy.metallic,"mask_dither":policy.mask_dither,
		"native_default_material":policy.native_default_material,"billboard":sprite.billboard})

func _sync_frame(sprite: AnimatedSprite3D, material: ShaderMaterial) -> void:
	if not is_instance_valid(sprite) or material==null or sprite.sprite_frames==null: return
	if not sprite.sprite_frames.has_animation(sprite.animation): return
	var texture: Texture2D=sprite.sprite_frames.get_frame_texture(sprite.animation,sprite.frame)
	material.set_shader_parameter("source_ambient_atlas",texture.atlas if texture is AtlasTexture else texture)

func set_sun_enabled(enabled: bool) -> void:
	for binding in bindings:
		if bool(binding.policy.lit):
			binding.material.set_shader_parameter("source_lf_sun_enabled",enabled)

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
	_policy.clear()
	_reference=null
	return {"restored":count}
