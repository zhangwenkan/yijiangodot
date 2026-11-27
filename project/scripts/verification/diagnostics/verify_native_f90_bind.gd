extends SceneTree
## CPU/headless source-generation and cache isolation; no world or render required.
const NATIVE_DEFINE := "#define SOURCE_LF_NATIVE_F90\n"
const INCLUDE_LINE := "#include \"res://shaders/original_lightfunction_receiving.gdshaderinc\""
const SOURCE := "shader_type spatial;\nrender_mode cull_back;\nvoid fragment() { ALBEDO=vec3(.3); SPECULAR=.5; ROUGHNESS=.7; }\n"
var result := {"status":"running","failures":[],"orders":[],"scope":"CPU binding source/cache checks; no GPU fidelity or drift claim."}

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value: result.failures.append(message)

func material_for(shader: Shader, mark: Variant) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	if mark != null: material.set_meta("source_landscape_compiled",mark)
	return material

func run_order(native_first: bool) -> void:
	var adapter: Node = load("res://scripts/original_lightfunctions.gd").new()
	var old_adapter: Node = load(get_script().resource_path.get_base_dir().path_join("fixtures/original_lightfunctions.before.gd")).new()
	var shared := Shader.new()
	shared.code = SOURCE
	var plain := material_for(shared,null)
	var explicit_false := material_for(shared,false)
	var native := material_for(shared,true)
	var native_again := material_for(shared,true)
	var old_plain := material_for(shared,null)
	old_adapter.call("_bind",old_plain)
	for material in ([native,plain,explicit_false,native_again] if native_first else [plain,native,explicit_false,native_again]):
		adapter.call("_bind",material)
	var cache: Dictionary = adapter.get("_shaders")
	check(cache.size()==2,"Two cache variants required for one original Shader and two metadata flags")
	check(plain.shader==explicit_false.shader,"Missing and false landscape flags must share the legacy cache entry")
	check(native.shader==native_again.shader,"True landscape flags must share the native cache entry")
	check(plain.shader!=native.shader,"Different flags on the same original Shader must never share the generated shader")
	check(plain.shader.code.to_utf8_buffer()==old_plain.shader.code.to_utf8_buffer(),"Nonlandscape LF-bound source changed byte-for-byte")
	check(not plain.shader.code.contains(NATIVE_DEFINE),"Nonlandscape acquired native define")
	check(native.shader.code.count(NATIVE_DEFINE)==1,"Landscape requires exactly one native define")
	check(native.shader.code.find(NATIVE_DEFINE)<native.shader.code.find(INCLUDE_LINE),"Native define must precede receiving include")
	check(native.shader.code.replace(NATIVE_DEFINE,"").to_utf8_buffer()==old_plain.shader.code.to_utf8_buffer(),"Removing only landscape define must restore legacy generated source")
	result.orders.append({"native_first":native_first,"cache_entries":cache.size(),
		"nonlandscape_source_sha256":plain.shader.code.sha256_text(),"legacy_source_sha256":old_plain.shader.code.sha256_text(),
		"landscape_source_sha256":native.shader.code.sha256_text()})
	adapter.free()
	old_adapter.free()

func run() -> void:
	run_order(false)
	run_order(true)
	result.status = "passed" if result.failures.is_empty() else "failed"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--f90-bind-out="):
			var path: String = arg.trim_prefix("--f90-bind-out=")
			var file := FileAccess.open(path,FileAccess.WRITE)
			if file == null:
				check(false,"Cannot write CPU check output")
			else:
				var text := JSON.stringify(result,"\t")
				file.store_string(text)
				check(file.get_error()==OK,"CPU check output write failed")
				file.close()
				check(FileAccess.get_file_as_string(path)==text,"CPU check output readback differs")
	result.status = "passed" if result.failures.is_empty() else "failed"
	print("NATIVE_F90_BIND_CPU ",JSON.stringify(result))
	quit(0 if result.failures.is_empty() else 1)
