extends RefCounted
## Creates only a material on the EXISTING AnimatedSprite3D. No mesh generation.
## Apply before the source lighting adapters; include sprite in their scan root.

var report: Dictionary = {}
var material: ShaderMaterial
var _sprite: AnimatedSprite3D
var _old_material: Material

func apply(sprite: AnimatedSprite3D, reference_lightfunction_material: ShaderMaterial = null) -> Dictionary:
	restore()
	_sprite = sprite
	_old_material = sprite.material_override
	material = ShaderMaterial.new()
	material.shader = load(get_script().resource_path.get_base_dir().path_join("original_character_surface.gdshader"))
	material.resource_name = "Source_MI_JHMaskLitSprite"
	material.set_meta("source_surface_adapter", true)
	material.set_meta("source_material", "Wandering_Sword/Content/JH/Core/Materilas/MI_JHMaskLitSprite.uasset")
	material.set_meta("source_unshaded", false)
	if reference_lightfunction_material != null:
		copy_lightfunction_parameters(reference_lightfunction_material)
	sprite.material_override = material
	sprite.frame_changed.connect(_sync_frame)
	sprite.animation_changed.connect(_sync_frame)
	_sync_frame()
	report = {"material":"MI_JHMaskLitSprite -> M_JHCharacter_Base", "metallic":0.699999988079071,
		"roughness":1.0, "specular":0.5, "geometry_unchanged":true,
		"lighting_scan_requirement":"Apply source SH9, heightfog and local cone to a root including this sprite; lightfunction uniform copy alone does not add those passes.",
		"limits":["Native character spotlight stays hidden in these two main maps: bInCave=false and UnLitMaterial=false.",
			"Normal is flat; no original hero AdditionalTextures are serialized.",
			"TickTime remains the original default0; damage/status flash events are not implemented.",
			"Temporal dither frame must be supplied for partially transparent/fading states; binary atlas at full visibility is unaffected."]}
	return report

func copy_lightfunction_parameters(reference: ShaderMaterial) -> void:
	if material == null or reference.shader == null:
		return
	for item in reference.shader.get_shader_uniform_list():
		if str(item.name).begins_with("source_lf_"):
			material.set_shader_parameter(item.name, reference.get_shader_parameter(item.name))

func _sync_frame() -> void:
	if not is_instance_valid(_sprite) or material == null or _sprite.sprite_frames == null:
		return
	var texture: Texture2D = _sprite.sprite_frames.get_frame_texture(_sprite.animation, _sprite.frame)
	if texture is AtlasTexture:
		var atlas: Texture2D = texture.atlas
		material.set_shader_parameter("source_character_atlas", atlas)
	else:
		material.set_shader_parameter("source_character_atlas", texture)

func restore() -> void:
	if is_instance_valid(_sprite):
		if _sprite.frame_changed.is_connected(_sync_frame):
			_sprite.frame_changed.disconnect(_sync_frame)
		if _sprite.animation_changed.is_connected(_sync_frame):
			_sprite.animation_changed.disconnect(_sync_frame)
		_sprite.material_override = _old_material
	_sprite = null
	material = null
	_old_material = null
