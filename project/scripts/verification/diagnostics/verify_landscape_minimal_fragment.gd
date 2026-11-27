extends "res://scripts/verification/diagnostics/verify_landscape_minimal_light.gd"
## Same original vertex/geometry and minimal light body; only fragment differs.
## Existing parent initialization, 20-capture envelope, UBO markers and restoration remain.

var _actual_driver := ""
var _actual_method := ""

func _command_option(option: String) -> String:
	var args := OS.get_cmdline_args()
	for i in args.size():
		if args[i]==option and i+1<args.size(): return args[i+1]
		if args[i].begins_with(option+"="): return args[i].trim_prefix(option+"=")
	return ""

func _observe_renderer(label: String) -> void:
	var first: int = report.failures.size()
	var driver := RenderingServer.get_current_rendering_driver_name()
	var method := RenderingServer.get_current_rendering_method()
	if not report.has("rendering_backend"):
		_actual_driver = driver
		_actual_method = method
		var expected_values: Array[String] = []
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--diagnostic-driver="): expected_values.append(arg.trim_prefix("--diagnostic-driver="))
		check(expected_values.size()==1,"Exactly one --diagnostic-driver is required")
		var expected := expected_values[0] if expected_values.size()==1 else ""
		check(expected in ["vulkan","d3d12"],"Diagnostic driver must be vulkan or d3d12")
		report.rendering_backend = {"driver":driver,"method":method,"checks":[],
			"expected_driver":expected,
			"requested_driver":_command_option("--rendering-driver"),
			"requested_method":_command_option("--rendering-method"),
			"engine_arguments":Array(OS.get_cmdline_args()),"user_arguments":Array(OS.get_cmdline_user_args()),
			"source":"RenderingServer.get_current_rendering_driver_name/get_current_rendering_method actual runtime return values"}
	check(not driver.is_empty() and driver==_actual_driver,label+": actual rendering driver missing or changed")
	check(driver==str(report.rendering_backend.expected_driver),label+": actual rendering driver differs from explicit diagnostic expectation")
	check(method=="forward_plus" and method==_actual_method,label+": expected unchanged Forward+ rendering method")
	var requested_driver: String = report.rendering_backend.requested_driver
	var requested_method: String = report.rendering_backend.requested_method
	if not requested_driver.is_empty(): check(driver==requested_driver,label+": actual driver differs from explicitly requested driver")
	if not requested_method.is_empty(): check(method==requested_method,label+": actual method differs from explicitly requested method")
	report.rendering_backend.checks.append({"label":label,"driver":driver,"method":method,"passed":report.failures.size()==first})

func progress(stage: String) -> void:
	_observe_renderer("progress-"+stage)
	super.progress(stage)

func _source_snapshot() -> Dictionary:
	_observe_renderer("source-snapshot")
	var result: Dictionary = super._source_snapshot()
	var path := "res://scripts/verification/diagnostics/verify_landscape_minimal_fragment.gd"
	result[path] = FileAccess.get_sha256(path)
	return result

func save_distortion(label: String) -> void:
	_observe_renderer("before-"+_phase+"-"+label)
	await super.save_distortion(label)
	_observe_renderer("after-"+_phase+"-"+label)

func _fragment_span(code: String) -> Dictionary:
	var pattern := RegEx.new()
	pattern.compile("void\\s+fragment\\s*\\(\\s*\\)\\s*\\{")
	var matches := pattern.search_all(code)
	check(matches.size()==1,"Expected one original fragment function")
	if matches.size()!=1: return {}
	var start: int = matches[0].get_start()
	var cursor: int = matches[0].get_end()
	var depth := 1
	while cursor<code.length() and depth>0:
		if code[cursor]=="{": depth += 1
		elif code[cursor]=="}": depth -= 1
		cursor += 1
	check(depth==0,"Unbalanced original fragment function")
	if depth!=0: return {}
	return {"start":start,"end":cursor,"source":code.substr(start,cursor-start)}

func _build_fragment_variants(code: String) -> Dictionary:
	# Reuse the already-reviewed minimal-light construction. Its count-marker
	# intermediate is never installed or captured in this experiment.
	var inherited := _build_marker_variants(code)
	if inherited.is_empty(): return {}
	var light_code: String = inherited.minimal_code
	var marker: String = inherited.audit.marker_source
	var span := _fragment_span(light_code)
	if span.is_empty(): return {}
	var minimal_outputs := "ALBEDO = vec3(1.0);\nMETALLIC = 0.0;\nSPECULAR = 0.0;\nROUGHNESS = 1.0;\nNORMAL = vec3(0.0, 1.0, 0.0);\nAO = 1.0;\nAO_LIGHT_AFFECT = 0.0;\nIRRADIANCE = vec4(0.0,0.0,0.0,1.0);\nRADIANCE = vec4(0.0,0.0,0.0,1.0);\nEMISSION = vec3(0.0);\n"
	var minimal_fragment := "void fragment() {\n"+minimal_outputs+marker+"}"
	var prefix := light_code.substr(0,span.start)
	var suffix := light_code.substr(span.end)
	var fragment_code := prefix+minimal_fragment+suffix
	var new_span := _fragment_span(fragment_code)
	if new_span.is_empty(): return {}
	var inverse := fragment_code.substr(0,new_span.start)+str(span.source)+fragment_code.substr(new_span.end)
	check(inverse==light_code,"Minimal-fragment changed bytes outside the fragment function")
	check(light_code.count(marker)==1 and fragment_code.count(marker)==1,"Marker source must occur once unchanged in both variants")
	check(_light_span(light_code).source==_light_span(fragment_code).source,"Minimal light function differs between fragment controls")
	var uniform := RegEx.new()
	uniform.compile("(?m)^uniform\\s+[^;]+;")
	var original_uniforms: Array[String] = []
	for match_uniform in uniform.search_all(code): original_uniforms.append(match_uniform.get_string())
	for variant in [light_code,fragment_code]:
		var uniforms: Array[String] = []
		for match_uniform in uniform.search_all(variant): uniforms.append(match_uniform.get_string())
		check(uniforms==original_uniforms,"Fragment control changed original uniform declarations")
	if not report.failures.is_empty(): return {}
	return {"light_code":light_code,"fragment_code":fragment_code,"audit":{
		"experiment":"minimal-light-marker-vs-minimal-fragment-marker",
		"minimal_light_marker_sha256":light_code.sha256_text(),"minimal_fragment_marker_sha256":fragment_code.sha256_text(),
		"minimal_light_derivation":inherited.audit,"marker_source":marker,"marker_source_sha256":marker.sha256_text(),
		"original_fragment_source":span.source,"minimal_fragment_source":minimal_fragment,"minimal_outputs":minimal_outputs,
		"fragment_start":span.start,"original_fragment_end":span.end,"minimal_fragment_end":new_span.end,
		"fragment_inverse_exact":inverse==light_code,
		"outside_fragment_prefix_sha256":prefix.sha256_text(),"outside_fragment_suffix_sha256":suffix.sha256_text(),
		"light_function_exact":true,"uniform_declarations_exact":true,"source_uniform_declaration_count":original_uniforms.size(),
		"source_boundary":"Only the complete fragment function differs between installed variants. Original vertex, helper/uniform declarations, geometry and minimal light function are identical. This changes fragment evaluation/outputs intentionally; it is not an equivalent production material or proof of a driver defect."}}

func run_landscape_raw_count(target: ShaderMaterial, states: Dictionary, target_state: Dictionary, code: String) -> void:
	check(_marker_inputs_ready,"This run did not supply valid first-capture UBO marker constants")
	check(states.size()==370 and target_state.parameters.size()==70,"Fragment controls require original 370 materials and 70 uniforms")
	if not report.failures.is_empty(): return
	var variants := _build_fragment_variants(code)
	if variants.is_empty(): return
	var target_id: int = target.get_instance_id()
	report.landscape_control["control_variant"] = "minimal-fragment-series"
	report.landscape_control["experiment"] = "minimal-light-marker-vs-minimal-fragment-marker"
	report["scope"] = "Original Youxian geometry/lights and vertex; two isolated controls differ only in fragment function and share minimal light plus exact same-frame markers. Explicit diagnosis, not a production fix or internal GPU cluster/material ID readback."
	report.landscape_control["marker_variants"] = variants.audit
	report.landscape_control["original_shader_sha256"] = code.sha256_text()
	report.landscape_control["target_material_id"] = target_id
	report.landscape_control["material_count"] = states.size()
	report.landscape_control["other_material_count"] = states.size()-1
	report.light_marker["geometry_mapping"] = {"stamp":1,"node":str(_target_node.get_path()),"node_id":_target_node.get_instance_id(),
		"material_id":target_id,"material_resource_name":target.resource_name,"original_shader_sha256":code.sha256_text()}
	_write_json("landscape-materials-before.json",landscape_material_records(states))
	FileAccess.open(out.path_join("landscape-runtime-original.gdshader"),FileAccess.WRITE).store_string(code)
	FileAccess.open(out.path_join("landscape-runtime-minimal-light-marker.gdshader"),FileAccess.WRITE).store_string(variants.light_code)
	FileAccess.open(out.path_join("landscape-runtime-minimal-fragment-marker.gdshader"),FileAccess.WRITE).store_string(variants.fragment_code)
	_write_json("marker-source-transforms.json",variants.audit)
	landscape_verify_materials(states,target_id,null,"before-fragment-controls")
	for variant in [{"label":"minimal-light-marker","code":variants.light_code},{"label":"minimal-fragment-marker","code":variants.fragment_code}]:
		var installed := Shader.new()
		installed.code = variant.code
		report.landscape_control.installed_shader_sha256 = installed.code.sha256_text()
		target.shader = installed
		for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
		await settle(20)
		landscape_verify_materials(states,target_id,installed,"before-"+variant.label)
		for i in 4: await save_distortion(variant.label+"-%02d" % i)
		landscape_verify_materials(states,target_id,installed,"after-"+variant.label)
		check(target.shader==installed and target_state.shader.code.sha256_text()==code.sha256_text(),variant.label+": source/installed shader ownership changed before restore")
		target.shader = target_state.shader
		for key in target_state.parameters: target.set_shader_parameter(key,target_state.parameters[key])
		await settle(20)
		landscape_verify_materials(states,target_id,null,"after-"+variant.label+"-restore")
		_write_json("materials-after-"+variant.label+"-restore.json",landscape_material_records(landscape_snapshot_materials()))
	landscape_verify_materials(states,target_id,null,"before-normal-restored")
	for i in 4: await save_distortion("normal-restored-%02d" % i)
	landscape_verify_materials(states,target_id,null,"after-normal-restored")
	_write_json("landscape-materials-restored.json",landscape_material_records(landscape_snapshot_materials()))
