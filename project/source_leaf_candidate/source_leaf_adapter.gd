extends RefCounted
## One original mesh emitter; bind before SH9/fog/cone and restore after them.
const COMPONENT := "LV_YouXianCun_S.PersistentLevel.BP_Leaves_263.ParticleSystem"
const EMITTER := "P_Leaves.ParticleSpriteEmitter_0"
const TEXTURES := "res://assets/environment/leaf/"
var report: Dictionary = {}
var material: ShaderMaterial
var _saved: Array[Dictionary] = []

func install(world: Node, lightfunction_donor: ShaderMaterial = null) -> Dictionary:
	if not _saved.is_empty(): return {"error":"Already installed; restore first."}
	report={"bound_emitters":0,"nodes":[],"unsupported":[],"geometry_unchanged":true,"simulation_unchanged":true,
		"limits":["UV derivatives replace missing original TANGENT; this is not the original smooth tangent basis.",
			"Leaf transmission uses the source TwoSidedBxDF formula with Godot attenuation; source separate transmission shadows are unavailable.",
			"Source sky is the existing captured SH9; rear-hemisphere contribution keeps scalar AO, not the complete UE multibounce AO/reflection chain."]}
	var targets: Array[Node]=[]
	for node in world.find_children("*","MultiMeshInstance3D",true,false):
		if str(node.get_meta("source_component",""))==COMPONENT and str(node.get_meta("source_emitter",""))==EMITTER:
			targets.append(node)
	if targets.is_empty():
		report.status="not_present"
		print("SOURCE_LEAF_BOUND ",JSON.stringify(report))
		return report
	material=ShaderMaterial.new()
	material.resource_name="MI_Leaf_5_native"
	material.shader=load("res://source_leaf_candidate/source_leaf.gdshader") as Shader
	if material.shader==null: return {"error":"Missing recovered leaf shader."}
	for pair in [["base","T_Leaf_Bird_Cherry_B"],["normal","T_Leaf_Bird_Cherry_N"],["roughness","T_Leaf_Bird_Cherry_R"],["ao","T_Leaf_Bird_Cherry_AO"],["metallic","T_Metallic"]]:
		var texture := load(TEXTURES+pair[1]+"_native.dds") as Texture2D
		if texture==null: return {"error":"Missing original leaf texture "+pair[1]}
		material.set_shader_parameter("source_leaf_"+pair[0],texture)
	if lightfunction_donor!=null and lightfunction_donor.shader!=null:
		for uniform in lightfunction_donor.shader.get_shader_uniform_list():
			if str(uniform.name).begins_with("source_lf_"):
				material.set_shader_parameter(uniform.name,lightfunction_donor.get_shader_parameter(uniform.name))
	material.set_meta("source_material","/Game/JH/Particles/Particles_Wind_Control_System/Materials/Instances/MI_Leaf_5.MI_Leaf_5")
	material.set_meta("source_surface_adapter",true)
	material.set_meta("source_unshaded",false)
	material.set_meta("source_two_sided_foliage",true)
	material.set_meta("source_surface_family","M_Master_Material / MI_Leaf_5")
	for node in targets:
		if node.multimesh==null or node.multimesh.mesh==null:
			report.unsupported.append("Leaf emitter has no imported mesh."); continue
		_saved.append({"node":node,"previous":node.material_override,"mesh":node.multimesh.mesh,"multimesh":node.multimesh})
		node.material_override=material
		report.bound_emitters+=1
		report.nodes.append(str(node.get_path()))
	report.status="installed" if report.bound_emitters==1 else "not_youxian_or_missing_emitter"
	print("SOURCE_LEAF_BOUND ",JSON.stringify(report))
	return report

func set_sun_enabled(enabled: bool) -> void:
	if material!=null: material.set_shader_parameter("source_lf_sun_enabled",enabled)

func restore() -> Dictionary:
	var restored:=0
	var errors: Array[String]=[]
	for state in _saved:
		if not is_instance_valid(state.node): continue
		if state.node.multimesh!=state.multimesh or state.node.multimesh.mesh!=state.mesh:
			errors.append("Unexpected imported leaf mesh replacement.")
		if state.node.material_override!=material:
			errors.append("Another material owner replaced leaf; restore it first."); continue
		state.node.material_override=state.previous
		restored+=1
	if errors.is_empty(): _saved.clear()
	return {"restored_emitters":restored,"errors":errors}
