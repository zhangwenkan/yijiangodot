extends RefCounted
## Binds recovered shader operations to existing imported geometry.
const BEAM_SHADER = preload("res://shaders/original_light_beam_compiled.gdshader")
const SKY_SHADER = preload("res://shaders/original_sky_card_compiled.gdshader")

static func bind_beam(mesh: MeshInstance3D, values: Dictionary, mask: Texture2D,
        noise: Texture2D, animated := true) -> ShaderMaterial:
    var scalar: Dictionary = values.get("Scalar", {})
    var vectors: Dictionary = values.get("Vector", {})
    var rgba: Dictionary = vectors.get("color", {"R":1.0,"G":1.0,"B":1.0,"A":0.0})
    var material := ShaderMaterial.new()
    material.shader = BEAM_SHADER
    material.set_shader_parameter("mask_texture", mask)
    material.set_shader_parameter("noise_texture", noise)
    material.set_shader_parameter("beam_color", Vector4(
        float(rgba.get("R",1)),float(rgba.get("G",1)),float(rgba.get("B",1)),float(rgba.get("A",0))))
    material.set_shader_parameter("brightness", float(scalar.get("Brightness", 1.0)))
    material.set_shader_parameter("phase", float(scalar.get("random", 0.0)))
    material.set_shader_parameter("fade_distance_m", float(scalar.get("fadedistance", 1024.0)) * 0.01)
    var length_m := float(scalar.get("Length",512.0)) * 0.01
    var width_m := float(scalar.get("width",512.0)) * 0.01
    material.set_shader_parameter("length_m", length_m)
    material.set_shader_parameter("width_m", width_m)
    material.set_shader_parameter("animated", animated)
    material.set_meta("source_formula", "M_GodRay_Animated original DXBC and UE4.27 frozen preshaders")
    mesh.material_override = material
    mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    # Original source BoundsScale=10000 keeps the camera-facing WPO visible.
    # Keep a finite, conservative bound around the imported mesh and its WPO.
    mesh.extra_cull_margin = length_m + width_m
    return material

static func bind_skies(world: Node, texture: Texture2D, renderer_exposure_scale := 1.0) -> int:
    var material := ShaderMaterial.new()
    material.shader = SKY_SHADER
    material.set_shader_parameter("base_color_texture", texture)
    material.set_shader_parameter("renderer_exposure_scale", renderer_exposure_scale)
    material.set_meta("source_material", "/Game/JH/MapEditor/Environment/sky/MI_Sky_02")
    var count := 0
    for mesh in world.find_children("*", "MeshInstance3D", true, false):
        if mesh.mesh == null:
            continue
        var source_keys := str(mesh.get_meta("source_material_keys", ""))
        for surface in mesh.mesh.get_surface_count():
            var old: Material = mesh.mesh.surface_get_material(surface)
            if (old != null and old.resource_name == "MI_Sky_02") or source_keys.contains("/MI_Sky_02."):
                mesh.set_surface_override_material(surface, material)
                mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                count += 1
    return count

