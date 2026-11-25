extends RefCounted
## Reversible local-light UNIT + RADIAL-DECAY diagnostic only.
## Optional source CastShadows switch; cone profiles and source shapes remain separate.
## Godot non-physical light units and native exposure=1 are required.

var report: Dictionary = {}
var _backup: Array[Dictionary] = []

func apply(world: Node, include_inferred_unitless: bool = true, enable_source_shadows: bool = false) -> Dictionary:
	restore()
	report = {"applied": [], "skipped": [], "source_shadows_requested": enable_source_shadows,
		"scope": "source units and radial decay; optional source CastShadows; cone/source shape unchanged"}
	for light in world.find_children("*", "Light3D", true, false):
		if not (light is OmniLight3D or light is SpotLight3D):
			continue
		if not light.has_meta("ue_properties"):
			continue
		var properties: Dictionary = light.get_meta("ue_properties")
		var source_name := str(light.get_meta("source_name", light.name))
		if not bool(properties.get("bUseInverseSquaredFalloff", true)):
			report.skipped.append({"name": source_name, "reason": "native inverse-square disabled; needs custom falloff"})
			continue
		var ies: Variant = properties.get("IESTexture")
		var has_ies := ies != null and str(ies) != "None"
		if ies is Dictionary:
			has_ies = int(ies.get("index", 0)) != 0 or str(ies.get("object", "None")) != "None"
		if has_ies:
			report.skipped.append({"name": source_name, "reason": "IES photometric modulation requires separate calibration"})
			continue
		var inferred := not properties.has("IntensityUnits")
		var units := str(properties.get("IntensityUnits", "ELightUnits::Unitless"))
		if inferred and not include_inferred_unitless:
			report.skipped.append({"name": source_name, "reason": "omitted unit intentionally left for separate default-chain comparison"})
			continue
		var intensity := float(properties.get("Intensity", 5000.0))
		var multiplier := 0.0
		if units.ends_with("Candelas"):
			multiplier = 1.0 / PI
		elif units.ends_with("Lumens"):
			if light is SpotLight3D:
				var inner := deg_to_rad(clampf(float(properties.get("InnerConeAngle", 0.0)), 0.0, 89.0))
				var outer := clampf(deg_to_rad(float(properties.get("OuterConeAngle", 44.0))), inner + 0.001, 1.5543431043624878)
				multiplier = 1.0 / (2.0 * PI * PI * (1.0 - cos(outer)))
			else:
				multiplier = 1.0 / (4.0 * PI * PI)
		elif units.ends_with("Unitless"):
			multiplier = 16.0 / (10000.0 * PI)
		else:
			report.skipped.append({"name": source_name, "reason": "unknown unit " + units})
			continue
		var old_attenuation: float = light.spot_attenuation if light is SpotLight3D else light.omni_attenuation
		var old_range: float = light.spot_range if light is SpotLight3D else light.omni_range
		_backup.append({"node": light, "energy": light.light_energy, "attenuation": old_attenuation,
			"range": old_range, "shadow_enabled": light.shadow_enabled})
		var energy := intensity * multiplier
		light.light_energy = energy
		var source_range := float(properties.get("AttenuationRadius", 1000.0)) * 0.01
		if light is SpotLight3D:
			light.spot_attenuation = 2.0
			light.spot_range = source_range
		else:
			light.omni_attenuation = 2.0
			light.omni_range = source_range
		if enable_source_shadows:
			light.shadow_enabled = bool(properties.get("CastShadows", true))
		report.applied.append({"name": source_name, "units": units, "units_inferred_from_default": inferred,
			"source_intensity": intensity, "coefficient": multiplier, "old_energy": _backup.back().energy,
			"energy": energy, "old_decay": old_attenuation, "decay": 2.0, "range_m": source_range,
			"source_radius_cm": float(properties.get("SourceRadius", 0.0)),
			"source_inner_degrees": float(properties.get("InnerConeAngle", 0.0)),
			"source_outer_degrees": float(properties.get("OuterConeAngle", 44.0)),
			"source_color": properties.get("LightColor", "default-white"),
			"source_cast_shadows": bool(properties.get("CastShadows", true)),
			"source_cast_shadows_inferred": not properties.has("CastShadows"),
			"old_shadow_enabled": _backup.back().shadow_enabled, "godot_shadow_enabled": light.shadow_enabled,
			"source_mobility": properties.get("Mobility", "native-default"),
			"visible_at_apply": light.visible})
	return report

func restore() -> void:
	for state in _backup:
		if not is_instance_valid(state.node):
			continue
		state.node.light_energy = state.energy
		state.node.shadow_enabled = state.shadow_enabled
		if state.node is SpotLight3D:
			state.node.spot_attenuation = state.attenuation
			state.node.spot_range = state.range
		elif state.node is OmniLight3D:
			state.node.omni_attenuation = state.attenuation
			state.node.omni_range = state.range
	_backup.clear()
