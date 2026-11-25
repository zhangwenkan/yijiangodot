extends Node
## Snapshot an existing Water_Blueprint mesh/material without changing it.
const CONFIG := "res://assets/environment/original-environment-config.json"
const PARAMS := ["overall_scale","wave_normal_scale","wave_normal_speed","wave_normal_strength",
	"ocean_normal_scale","ocean_normal_speed","ocean_normal_strength","overall_normal_power",
	"normal_fresnel_power","water_height_cm","shore_depth_cm","shore_fade_cm",
	"shallow_opacity","deep_opacity","shallow_ior","deep_ior",
	"refraction_depth_bias_cm","surge_divisor","surge_speed","surge_height_cm","adapter_layer_offset_m"]
const TEXTURES := ["waves_2_normal","waves_1_normal","water_4_normal","water_3_normal","water_2_normal","water_1_normal"]
var report := {"expected":1,"bound":0,"unsupported":[],"geometry_changed":false,"material_changed":false}
var effect: Variant
var draw: MeshInstance3D
var material: ShaderMaterial
var _active := true

func configure(scene: Node, target: CompositorEffect) -> Dictionary:
	effect=target
	process_priority=101
	var version: Dictionary=Engine.get_version_info()
	if int(version.major)!=4 or int(version.minor)!=7 or int(version.patch)!=2:
		report.unsupported.append("Scene TIME UBO contract verified only for installed Godot4.7.2 float desktop build")
		return report
	var data: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	var expected: Array[String]=[]
	for item in data.get("maps",{}).get(scene.slug,{}).get("dynamic_materials",[]):
		if str(item.name).contains("Water_Blueprint"):
			expected.append(str(item.name).rsplit(".",true,1)[0])
	report.expected=expected.size()
	var matched: Array[MeshInstance3D]=[]
	for node in scene.world.find_children("*","MeshInstance3D",true,false):
		if str(node.get_meta("source_component","")) in expected or str(node.get_meta("source_name","")) in expected:
			matched.append(node)
	if expected.size()!=1 or matched.size()!=1:
		report.unsupported.append("Expected one exact original Water_Blueprint mesh; expected="+str(expected)+" matched="+str(matched.size()))
		return report
	draw=matched[0]
	material=draw.material_override as ShaderMaterial
	if material==null or not material.shader.code.contains("wave_normal_strength"):
		report.unsupported.append("Original Water material not installed")
		return report
	var textures: Array[Texture2D]=[]
	for key in TEXTURES:
		var value: Texture2D=material.get_shader_parameter(key) as Texture2D
		if value==null:
			report.unsupported.append("Missing source water normal "+key)
			return report
		textures.append(value)
	var configured: Dictionary=effect.water_pass.configure_original_mesh(draw.mesh,textures)
	report["mesh"]=configured
	if not configured.get("passed",false):
		report.unsupported.append(configured)
		return report
	report.bound=1
	report["source"]=expected[0]
	report["node"]=str(draw.get_path())
	report["limits"]=["Existing imported UV-derivative basis, not recovered native TANGENT.","Dry branch matches current main material; source rain-normal Z at zero RainScale is not established.","Original IOR/FOV/viewport/depth-bias expressions; no TLV or reflection change."]
	_process(0.0)
	return report

func set_active(value: bool) -> void:
	_active=value
	_process(0.0)

func _process(_delta: float) -> void:
	if effect==null or not is_instance_valid(draw) or material==null or report.bound!=1:
		return
	var values:=PackedFloat32Array()
	for key in PARAMS:
		var value: Variant=material.get_shader_parameter(key)
		if value==null:
			value=RenderingServer.shader_get_parameter_default(material.shader.get_rid(),key)
		if value==null:
			var failure: String = "Missing evaluated water parameter " + str(key)
			if not report.unsupported.has(failure):report.unsupported.append(failure)
			effect.water_pass.submit(Transform3D.IDENTITY,PackedFloat32Array(),false)
			return
		values.append(float(value))
	# Same native mip sampler bias convention as the existing splash pass.
	values.append(0.0)
	values.append(0.0)
	values.append(0.0)
	effect.water_pass.submit(draw.global_transform,values,_active and draw.is_visible_in_tree())

func shutdown() -> void:
	set_process(false)
	if effect!=null:
		effect.water_pass.submit(Transform3D.IDENTITY,PackedFloat32Array(),false)
	effect=null
	draw=null
	material=null
