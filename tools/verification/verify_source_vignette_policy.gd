## Run from the repository root with --path ./project --script ./tools/verification/verify_source_vignette_policy.gd.
## Optional -- --output=<existing-directory/report.json>; no outputs are written unless requested.
## Requires the local source map configuration described in docs/LOCAL_RESOURCES.md.
extends SceneTree
var results: Array = []
var failed := 0
var resolver
var output := ""
const SOURCE_CONFIG := "res://assets/environment/original-environment-config.json"
const SOURCE_RENDERER := "res://scripts/original_source_renderer.gd"
func check(label: String, volumes: Variant, expected: String, intensity := 0.0) -> void:
	var actual: Dictionary = resolver.resolve_source_vignette(volumes)
	var passed: bool = actual.status == expected and actual.intensity == intensity
	if expected == "unsupported": passed = passed and not str(actual.reason).is_empty()
	results.append({"name":label,"passed":passed,"actual":actual})
	if not passed: failed += 1
func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	resolver = load(SOURCE_RENDERER)
	if resolver == null or not FileAccess.file_exists(SOURCE_CONFIG):
		push_error("Source renderer or local source map configuration is missing. Restore local project resources first.")
		quit(2)
		return
	var source: Variant = JSON.parse_string(FileAccess.get_file_as_string(SOURCE_CONFIG))
	if not source is Dictionary or not source.get("maps") is Dictionary:
		push_error("Source map configuration is malformed.")
		quit(2)
		return
	var maps: Dictionary = {}
	for map_name: String in ["wuming", "youxian"]:
		var record: Variant = source.maps.get(map_name)
		if not record is Dictionary or not record.get("postprocess") is Array:
			push_error("Source PostProcess records are missing for "+map_name)
			quit(2)
			return
		maps[map_name] = record.postprocess
	for map_name in ["wuming", "youxian"]:
		check(map_name+" cooked defaults", maps[map_name], "applied", 0.6499999761581421)
	var good: Array = maps.wuming.duplicate(true)
	good[0].properties.bEnabled = true
	good[0].properties.BlendWeight = 1.0
	check("explicit full weight",good,"applied",0.6499999761581421)
	check("missing metadata",null,"unsupported")
	check("malformed metadata",{},"unsupported")
	check("no volumes",[],"unsupported")
	check("multiple volumes",[good[0],good[0]],"unsupported")
	check("malformed volume",[3],"unsupported")
	for key in ["properties", "class"]:
		var item: Array = good.duplicate(true)
		item[0].erase(key)
		check("missing "+key,item,"unsupported")
	var bad_class: Array = good.duplicate(true)
	bad_class[0].class = "/Script/Unknown.Volume"
	check("unknown native class",bad_class,"unsupported")
	for value in [false, 1, "true", null]:
		var item: Array = good.duplicate(true)
		item[0].properties.bEnabled = value
		check("invalid enabled "+str(value),item,"unsupported")
	for value in [false, 1, "true", null]:
		var item: Array = good.duplicate(true)
		item[0].properties.bUnbound = value
		check("invalid unbound "+str(value),item,"unsupported")
	for value in [0.0, 0.5, 0.999999, 1.000001, 2.0, true, "1", null, NAN, INF]:
		var item: Array = good.duplicate(true)
		item[0].properties.BlendWeight = value
		check("invalid blend weight "+str(value),item,"unsupported")
	for key in ["bUnbound", "Settings"]:
		var item: Array = good.duplicate(true)
		item[0].properties.erase(key)
		check("missing "+key,item,"unsupported")
	for key in ["bOverride_VignetteIntensity", "VignetteIntensity"]:
		var item: Array = good.duplicate(true)
		item[0].properties.Settings.erase(key)
		check("missing "+key,item,"unsupported")
	for value in [false, 1, "true", null]:
		var item: Array = good.duplicate(true)
		item[0].properties.Settings.bOverride_VignetteIntensity = value
		check("invalid override "+str(value),item,"unsupported")
	for value in [-0.001, 1.001, true, "0.65", null, NAN, INF]:
		var item: Array = good.duplicate(true)
		item[0].properties.Settings.VignetteIntensity = value
		check("invalid intensity "+str(value),item,"unsupported")
	for value in [0.0,1.0]:
		var item: Array = good.duplicate(true)
		item[0].properties.Settings.VignetteIntensity = value
		check("valid endpoint "+str(value),item,"applied",value)
	var report := {"scope":"Actual project policy function and local map metadata; CPU headless, not GPU rendering",
		"engine":Engine.get_version_info().string, "test_count":results.size(), "failed":failed, "results":results,
		"source_renderer_sha256":FileAccess.get_sha256(SOURCE_RENDERER),
		"source_config_sha256":FileAccess.get_sha256(SOURCE_CONFIG)}
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		if file == null:
			push_error("Could not write requested report: "+output)
			quit(2)
			return
		file.store_string(JSON.stringify(report,"\t"))
	print("VIGNETTE_POLICY ",results.size()," tests; failed=",failed)
	quit(0 if failed==0 else 1)
