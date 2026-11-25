extends Node
## Bind original light-function material expressions to per-light shading.
## No geometry is created. Native UE projection is ported separately from BRDF.
const CONFIG := "res://assets/environment/original-lightfunctions.json"
const INCLUDE := "res://shaders/original_lightfunction_receiving.gdshaderinc"
var report := {"materials":0,"surfaces":0,"lights":0,"skipped_unlit":0}
var _materials: Dictionary = {}
var _shaders: Dictionary = {}
var _parameters: Dictionary = {}
var _sun: DirectionalLight3D
var _sun_enabled := true

func setup(slug: String, world: Node3D) -> Dictionary:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	var lights: Array = config.maps.get(slug, [])
	var local_x := PackedVector4Array()
	var local_y := PackedVector4Array()
	var local_z := PackedVector4Array()
	var positions := PackedVector4Array()
	var scales := PackedVector4Array()
	var tilings := PackedVector4Array()
	var speeds := PackedVector4Array()
	var trees := PackedVector4Array()
	for item in lights:
		var properties: Dictionary = item.properties
		var source: Dictionary = config.materials[properties.LightFunctionMaterial]
		var values: Dictionary = source.include_arguments
		var transform := _ue_transform(item.matrix_ue)
		var inverse := transform.affine_inverse()
		local_x.append(Vector4(inverse.basis.x.x,inverse.basis.y.x,inverse.basis.z.x,inverse.origin.x))
		local_y.append(Vector4(inverse.basis.x.y,inverse.basis.y.y,inverse.basis.z.y,inverse.origin.y))
		local_z.append(Vector4(inverse.basis.x.z,inverse.basis.y.z,inverse.basis.z.z,inverse.origin.z))
		positions.append(Vector4(transform.origin.x,transform.origin.y,transform.origin.z,tan(deg_to_rad(float(properties.get("OuterConeAngle",45.0))))))
		var scale_source: Dictionary = properties.get("LightFunctionScale", {"X":1024.0,"Y":1024.0,"Z":1024.0})
		if scale_source.has("LightFunctionScale"):
			scale_source=scale_source.LightFunctionScale
		scales.append(Vector4(float(scale_source.X)*.01,float(scale_source.Y)*.01,float(scale_source.Z)*.01,float(properties.get("LightFunctionFadeDistance",100000.0))*.01))
		tilings.append(Vector4(values.tiling[0],values.tiling[1],values.power1,values.power2))
		speeds.append(Vector4(values.speed1[0],values.speed1[1],values.speed2[0],values.speed2[1]))
		var tree_texture := str(source.textures.get("Param",""))
		trees.append(Vector4(float(values.get("tree_tiling",1)),float(values.get("sway_frequency",0)),float(values.get("sway_amplitude",0)),2.0 if tree_texture.contains("002") else 3.0))
		if str(item["class"]).ends_with("DirectionalLightComponent"):
			_parameters["source_lf_spot_offsets"]=Vector4(values.offset_speed1[0],values.offset_speed1[1],values.offset_speed2[0],values.offset_speed2[1])
			_parameters["source_lf_spot_sizes"]=Vector2(values.spot_size1,values.spot_size2)
			_parameters["source_lf_sun_color"]=Vector3(values.source_color[0],values.source_color[1],values.source_color[2])
	# Packed arrays copy on write; pad the original variables, not loop copies.
	local_x.resize(24)
	local_y.resize(24)
	local_z.resize(24)
	positions.resize(24)
	scales.resize(24)
	tilings.resize(24)
	speeds.resize(24)
	trees.resize(24)
	_parameters.merge({"source_lf_count":lights.size(),"source_lf_local_x":local_x,"source_lf_local_y":local_y,"source_lf_local_z":local_z,"source_lf_position_angle":positions,"source_lf_scale_fade":scales,"source_lf_tiling_power":tilings,"source_lf_speeds":speeds,"source_lf_tree":trees})
	for pair in [["source_lf_cloud1","envtx_cloudshadow"],["source_lf_cloud2","envtx_cloudshadow1"],["source_lf_tree2","T_HD_Shuying002"],["source_lf_tree3","T_HD_Shuying003"]]:
		_parameters[pair[0]]=load("res://assets/environment/textures/%s.png" % pair[1])
	report.lights=lights.size()
	for node in world.find_children("*","DirectionalLight3D",true,false):
		_sun=node
	for node in world.find_children("*","GeometryInstance3D",true,false):
		if node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count():
				_bind(node.get_active_material(surface))
		elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null:
			for surface in node.multimesh.mesh.get_surface_count():
				_bind(node.multimesh.mesh.surface_get_material(surface))
	print("ORIGINAL_LIGHTFUNCTIONS_READY ",JSON.stringify(report))
	return report

func _bind(material: Material) -> void:
	if not material is ShaderMaterial or material.shader == null:
		return
	if _materials.has(material.get_instance_id()):
		report.surfaces+=1
		return
	var code: String=material.shader.code
	var unshaded_mode := RegEx.new()
	unshaded_mode.compile("render_mode[^;]*\\bunshaded\\b")
	if unshaded_mode.search(code) != null or code.contains("void light()") or not code.contains("void fragment()"):
		report.skipped_unlit+=1
		return
	var shader_key: int=material.shader.get_instance_id()
	if not _shaders.has(shader_key):
		var open := code.find("{",code.find("void fragment()"))
		var close:=open+1
		var nesting:=1
		while close<code.length() and nesting>0:
			if code[close]=="{": nesting+=1
			elif code[close]=="}": nesting-=1
			close+=1
		var addition: String="\nsource_lf_fragment_world=(INV_VIEW_MATRIX*vec4(VERTEX,1.0)).xyz;\nsource_lf_f0=mix(vec3(0.16*SPECULAR*SPECULAR),ALBEDO,METALLIC);\nsource_lf_camera_distance=length(VERTEX);\n"
		code=code.insert(close-1,addition)
		code=code.replace("shader_type spatial;","shader_type spatial;\n#include \"%s\"\n" % INCLUDE)
		var shader:=Shader.new()
		shader.code=code
		_shaders[shader_key]=shader
	material.shader=_shaders[shader_key]
	for parameter in _parameters:
		material.set_shader_parameter(parameter,_parameters[parameter])
	material.set_meta("source_lightfunction_adapter",true)
	_materials[material.get_instance_id()]=material
	report.materials+=1
	report.surfaces+=1

func _process(_delta: float) -> void:
	var enabled:=not is_instance_valid(_sun) or not bool(_sun.get_meta("source_house_light_function_disabled",false))
	if enabled==_sun_enabled:
		return
	_sun_enabled=enabled
	for material in _materials.values():
		material.set_shader_parameter("source_lf_sun_enabled",enabled)

func _ue_transform(m: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(m[0][0],m[2][0],m[1][0]),Vector3(m[0][2],m[2][2],m[1][2]),Vector3(m[0][1],m[2][1],m[1][1])),Vector3(m[0][3],m[2][3],m[1][3])*.01)

