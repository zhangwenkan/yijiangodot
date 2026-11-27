extends "res://scripts/verification/diagnostics/verify_landscape_isolation.gd"
## Explicit follow-up: same source fragment and marker, two different light bodies.
## Parent owns the 20-capture full-scene/isolation envelope and complete restoration.

var _marker_z_far := 0.0
var _marker_gain := 0.0
var _marker_inputs_ready := false

func _source_snapshot() -> Dictionary:
	var result: Dictionary = super._source_snapshot()
	var path := "res://scripts/verification/diagnostics/verify_landscape_minimal_light.gd"
	result[path] = FileAccess.get_sha256(path)
	return result

func _bytes_sha(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

func _check_capture_ubo(label: String) -> void:
	var folder := out.path_join(label)
	var metadata: Variant = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("capture.json")))
	check(metadata is Dictionary,label+": capture metadata missing for marker inputs")
	if not metadata is Dictionary: return
	var upstream: Array = metadata.get("upstream",[])
	check(upstream.size()==3,label+": marker requires all three upstream records")
	if upstream.size()!=3: return
	if not report.has("light_marker"):
		report.light_marker = {"ubo_checks":[],"geometry_id":1,"count_scale":16,"marker_scale":1024,
			"z_far_offset":2680,"emissive_gain_offset":2832,"ubo_expected_bytes":5696,
			"scope":"Diagnostic geometry stamp and inferred tile/slice computed by this shader, not internal cluster buffer or material-ID readback."}
	var files: Array[String] = []
	for row: Dictionary in upstream: files.append(str(row.scene_ubo.file))
	files.append(str(metadata.scene_ubo_full.file))
	for i in files.size():
		var path := folder.path_join(files[i])
		var bytes := FileAccess.get_file_as_bytes(path)
		var first: int = report.failures.size()
		check(bytes.size()==5696,label+": unexpected scene UBO layout/length in "+files[i])
		if bytes.size()!=5696: continue
		var z_far := bytes.decode_float(2680)
		var gain := bytes.decode_float(2832)
		check(is_finite(z_far) and z_far>0.0,label+": invalid current UBO z_far")
		check(is_finite(gain) and gain==1.0,label+": current UBO emissive gain must be exactly 1")
		if not _marker_inputs_ready and i==0:
			check(label=="whole-before-original-00", "Marker constants must come from the first capture of this run")
			check(int(metadata.width)==960 and int(metadata.height)==540,"Unexpected marker viewport dimensions")
			check(ceili(float(metadata.width)/32.0)*ceili(float(metadata.height)/32.0)<=2048,"Tile marker exceeds exact half integer range")
			if report.failures.size()==first:
				_marker_z_far = z_far
				_marker_gain = gain
				_marker_inputs_ready = true
				report.light_marker.input = {"capture":label,"file":files[i],"sha256":_bytes_sha(bytes),
					"z_far":z_far,"z_far_f32_hex":bytes.slice(2680,2684).hex_encode(),
					"gain":gain,"gain_f32_hex":bytes.slice(2832,2836).hex_encode(),
					"upstream_token":upstream[0].token,"drawn_frame":upstream[0].drawn_frame,
					"callback_serial":upstream[0].callback_serial,"width":metadata.width,"height":metadata.height}
		check(_marker_inputs_ready and z_far==_marker_z_far and gain==_marker_gain,label+": marker constants differ from current scene UBO")
		report.light_marker.ubo_checks.append({"label":label,"file":files[i],"bytes":bytes.size(),
			"sha256":_bytes_sha(bytes),"z_far":z_far,"gain":gain,"passed":report.failures.size()==first})

func save_distortion(label: String) -> void:
	await super.save_distortion(label)
	_check_capture_ubo(_phase+"-"+label)

func _marker_source() -> String:
	var z_literal := String.num(_marker_z_far,17)
	if not z_literal.contains("."): z_literal += ".0"
	# These run-local constants do not alter the original 70-uniform interface.
	return """
// Same-frame diagnostic markers. z_far is read from this run's first scene UBO.
const float source_drift_z_far = %s;
const float source_drift_emissive_gain = 1.0;
const float source_drift_geometry_id = 1.0;
vec2 source_drift_tile = floor(FRAGCOORD.xy / 32.0);
float source_drift_tile_width = ceil(VIEWPORT_SIZE.x / 32.0);
float source_drift_tile_code = source_drift_tile.x + source_drift_tile.y * source_drift_tile_width + 1.0;
bool source_drift_valid = !isnan(VERTEX.z) && !isinf(VERTEX.z)
    && source_drift_z_far > 0.0 && source_drift_emissive_gain == 1.0
    && source_drift_tile_code >= 1.0 && source_drift_tile_code <= 2048.0;
if (source_drift_valid) {
    float source_drift_slice = floor(clamp((-VERTEX.z / source_drift_z_far) * 32.0, 0.0, 31.0));
    float source_drift_identity_slice = source_drift_geometry_id * 32.0 + source_drift_slice;
    EMISSION = vec3(0.0, source_drift_tile_code, source_drift_identity_slice) / (1024.0 * source_drift_emissive_gain);
}
""" % z_literal

func _light_span(code: String) -> Dictionary:
	var pattern := RegEx.new()
	pattern.compile("void\\s+light\\s*\\(\\s*\\)\\s*\\{")
	var matches := pattern.search_all(code)
	check(matches.size()==1,"Expected exactly one complete source light function")
	if matches.size()!=1: return {}
	var start: int = matches[0].get_start()
	var cursor: int = matches[0].get_end()
	var depth := 1
	while cursor<code.length() and depth>0:
		if code[cursor]=="{": depth += 1
		elif code[cursor]=="}": depth -= 1
		cursor += 1
	check(depth==0,"Unbalanced source light body")
	if depth!=0: return {}
	return {"start":start,"end":cursor,"source":code.substr(start,cursor-start)}

func _build_marker_variants(code: String) -> Dictionary:
	check(not code.contains("source_drift_"),"Marker identifiers already exist in original source")
	var diffuse := "DIFFUSE_LIGHT += radiance * (nl / PI);"
	var replacement := "if (!LIGHT_IS_DIRECTIONAL) { DIFFUSE_LIGHT += vec3(1.0, 0.0, 0.0) / 16.0; }"
	var specular: Array[String] = [
		"SPECULAR_LIGHT += radiance*leaf_wrap*leaf_scatter*source_leaf_subsurface;",
		"SPECULAR_LIGHT += radiance * distribution * visibility * fresnel * nl * SPECULAR_AMOUNT;"]
	var tail := "FOG = source_height_fog_to_godot(source_hf_result,false);\n}\r\n"
	# Exactly the established raw-count neutral fragment output, followed by G/B markers.
	var neutral := "ALBEDO = vec3(1.0);\nMETALLIC = 0.0;\nSPECULAR = 0.0;\nEMISSION = vec3(0.0);\nIRRADIANCE = vec4(0.0,0.0,0.0,1.0);\nRADIANCE = vec4(0.0,0.0,0.0,1.0);\n"
	var marker := _marker_source()
	var injected_tail := tail.substr(0,tail.length()-3)+neutral+marker+"}\r\n"
	var accumulation := RegEx.new()
	accumulation.compile("\\b(?:DIFFUSE_LIGHT|SPECULAR_LIGHT)\\s*\\+=")
	check(accumulation.search_all(code).size()==3 and code.count(diffuse)==1,"Expected exactly three original accumulations")
	check(code.count("void fragment() {")==1 and code.count(tail)==1 and code.ends_with(tail),"Unexpected original fragment tail")
	for addition in specular: check(code.count(addition)==1,"Missing unique original specular accumulation")
	var render_mode := RegEx.new()
	render_mode.compile("(?m)^render_mode\\s+[^;]+;")
	var declarations := render_mode.search_all(code)
	check(declarations.size()==1,"Expected one original render_mode")
	if not report.failures.is_empty(): return {}
	var original_mode: String = declarations[0].get_string()
	check(not "fog_disabled" in original_mode and not "ambient_light_disabled" in original_mode and not "unshaded" in original_mode,"Unexpected source lighting render_mode")
	if not report.failures.is_empty(): return {}
	var installed_mode := original_mode.substr(0,original_mode.length()-1)+", fog_disabled, ambient_light_disabled;"
	var count_code := code.replace(original_mode,installed_mode).replace(tail,injected_tail).replace(diffuse,replacement)
	for addition in specular: count_code = count_code.replace(addition,"if (false) { "+addition+" }")
	var inverse := count_code.replace(installed_mode,original_mode).replace(injected_tail,tail).replace(replacement,diffuse)
	for addition in specular: inverse = inverse.replace("if (false) { "+addition+" }",addition)
	check(inverse==code,"Count-marker changed source beyond audited raw-count edits and marker insertion")
	var span := _light_span(count_code)
	if span.is_empty() or not report.failures.is_empty(): return {}
	var minimal_light := "void light() {\n    if (!LIGHT_IS_DIRECTIONAL) {\n        DIFFUSE_LIGHT += vec3(1.0, 0.0, 0.0) / 16.0;\n    }\n}"
	var prefix := count_code.substr(0,span.start)
	var suffix := count_code.substr(span.end)
	var minimal_code := prefix+minimal_light+suffix
	var minimal_span := _light_span(minimal_code)
	if minimal_span.is_empty(): return {}
	var minimal_inverse := minimal_code.substr(0,minimal_span.start)+str(span.source)+minimal_code.substr(minimal_span.end)
	check(minimal_inverse==count_code,"Minimal-light changed bytes outside the full light function")
	var uniform := RegEx.new()
	uniform.compile("(?m)^uniform\\s+[^;]+;")
	var original_uniforms: Array[String] = []
	for match_uniform in uniform.search_all(code): original_uniforms.append(match_uniform.get_string())
	for variant in [count_code,minimal_code]:
		var uniforms: Array[String] = []
		for match_uniform in uniform.search_all(variant): uniforms.append(match_uniform.get_string())
		check(uniforms==original_uniforms,"Marker changed source uniform declarations")
	if not report.failures.is_empty(): return {}
	return {"count_code":count_code,"minimal_code":minimal_code,"audit":{
		"count_marker_sha256":count_code.sha256_text(),"minimal_light_marker_sha256":minimal_code.sha256_text(),
		"diffuse_original":diffuse,"diffuse_replacement":replacement,"specular_original":specular,
		"fragment_tail_original":tail,"fragment_tail_installed":injected_tail,"neutral_output":neutral,"marker_source":marker,
		"render_mode_original":original_mode,"render_mode_installed":installed_mode,"original_inverse_exact":inverse==code,
		"count_light_source":span.source,"minimal_light_source":minimal_light,"light_start":span.start,
		"count_light_end":span.end,"minimal_light_end":minimal_span.end,"minimal_inverse_exact":minimal_inverse==count_code,
		"outside_light_prefix_sha256":prefix.sha256_text(),"outside_light_suffix_sha256":suffix.sha256_text(),
		"uniform_declarations_exact":true,"source_uniform_declaration_count":original_uniforms.size(),
		"source_boundary":"Original vertex and fragment evaluation plus the existing neutral raw-count tail and markers are identical between variants. Only the complete light function differs. Unused computation may be optimized out; identical compiled instructions are not asserted."}}

func run_landscape_raw_count(target: ShaderMaterial, states: Dictionary, target_state: Dictionary, code: String) -> void:
	check(_marker_inputs_ready,"This run did not supply valid first-capture UBO marker constants")
	check(states.size()==370 and target_state.parameters.size()==70,"Marker controls require the original 370 materials and 70 uniforms")
	if not report.failures.is_empty(): return
	var variants := _build_marker_variants(code)
	if variants.is_empty(): return
	var target_id: int = target.get_instance_id()
	report.landscape_control["experiment"] = "count-marker-vs-minimal-light-marker"
	report["scope"] = "Original Youxian geometry/lights and source fragment; two isolated light-function controls share same-frame tile/geometry/slice markers. Explicit diagnosis, not a production fix or internal GPU cluster/material ID readback."
	report.landscape_control["marker_variants"] = variants.audit
	report.landscape_control["original_shader_sha256"] = code.sha256_text()
	report.landscape_control["target_material_id"] = target_id
	report.landscape_control["material_count"] = states.size()
	report.landscape_control["other_material_count"] = states.size()-1
	report.light_marker["geometry_mapping"] = {"stamp":1,"node":str(_target_node.get_path()),"node_id":_target_node.get_instance_id(),
		"material_id":target_id,"material_resource_name":target.resource_name,"original_shader_sha256":code.sha256_text()}
	_write_json("landscape-materials-before.json",landscape_material_records(states))
	FileAccess.open(out.path_join("landscape-runtime-original.gdshader"),FileAccess.WRITE).store_string(code)
	FileAccess.open(out.path_join("landscape-runtime-count-marker.gdshader"),FileAccess.WRITE).store_string(variants.count_code)
	FileAccess.open(out.path_join("landscape-runtime-minimal-light-marker.gdshader"),FileAccess.WRITE).store_string(variants.minimal_code)
	_write_json("marker-source-transforms.json",variants.audit)
	landscape_verify_materials(states,target_id,null,"before-marker-controls")
	for variant in [{"label":"count-marker","code":variants.count_code},{"label":"minimal-light-marker","code":variants.minimal_code}]:
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
