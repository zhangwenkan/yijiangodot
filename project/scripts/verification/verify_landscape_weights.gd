extends SceneTree
## Headless production data/footstep selection check; no scene, model or audio.
## --report-dir=<new absolute output> [--baseline-dir=<isolated control run>]
const EXPECTED := {
	"wuming": {
		"size":[442,631],"covered":278902,
		"png":["20d4ee2b16a7a6c882f8a2a17ba4fa6452519e1720842607fe994a18c5914f9a","5fa5f478868059fe216891c52ee8123bc09a38c84208d4d1facd6a39b07d5e3a"],
		"rgba":["768df0c8718e7901bc51a119f755d1d7b5aa877585a756bef15b13a3fdeca468","558398812fe50def0ad7de4e43a1fbf7082cfe95d36707b47e5d8f8a58e3beb2"],
		"baseline_rgba":["4afaf4841fbcc342202c9a256d28940dbb806c5047a551fbb804520cda10414f","558398812fe50def0ad7de4e43a1fbf7082cfe95d36707b47e5d8f8a58e3beb2"]},
	"youxian": {
		"size":[442,379],"covered":159580,
		"png":["a36c26305bf5d4db732c255604ebc4a00c280d081e1394cf1d75d671e77f620b","ea88e802af273fbae156acd4f19c8dea980fe5136d928de8feb3b8289161e51d"],
		"rgba":["4279e0a41ff5c3152838538cc88dc584ae5ecee5a7d781b153c40b11244fcfb0","9cf69e22748a147135e1b0ffb3960819196d6a02cbd0bd0d06eae96d0f5d569c"],
		"baseline_rgba":["8fe101a7720eb4c304b990914518b63432409b035ab310b2b2e5bb1972bd5c00","9cf69e22748a147135e1b0ffb3960819196d6a02cbd0bd0d06eae96d0f5d569c"]}}
const NAMES := ["atlas-weights-1-4.png","atlas-weights-5-8.png"]
const FOOTSTEP_SCRIPT := "res://scripts/original_footsteps.gd"
const FOOTSTEP_MANIFEST := "res://assets/characters/original_hero/footsteps/manifest.json"
var output := ""
var baseline := ""
var report := {"stage":"starting","failures":[],"maps":[],"engine":Engine.get_version_info(),
	"source_hash_provenance":"Four PNG, decoded source RGBA and old baseline RGBA hashes preserved from the 2026-11-27 isolated import-control manifest before changing production import settings.",
	"scope":"Full imported RGBA equality and every covered atlas texel through the actual original_footsteps.select_map/_landscape_material methods. No audio playback, physical walking, image equivalence, SH/cube recapture or temporal drift claim."}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--report-dir="): output=arg.trim_prefix("--report-dir=")
		elif arg.begins_with("--baseline-dir="): baseline=arg.trim_prefix("--baseline-dir=")
	call_deferred("run")

func check(ok: bool,message: String) -> void:
	if not ok: report.failures.append(message)

func digest(data: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(data)
	return hash.finish().hex_encode()

func file_digest(path: String) -> String:
	return digest(FileAccess.get_file_as_bytes(path))

func save_report() -> void:
	var file := FileAccess.open(output.path_join("landscape-weights-report.json"),FileAccess.WRITE)
	if file==null:
		push_error("Cannot save landscape weights report")
		return
	file.store_string(JSON.stringify(report,"\t"))

func image_rgba(image: Image,label: String) -> PackedByteArray:
	if image==null or image.is_empty():
		check(false,label+": missing image")
		return PackedByteArray()
	if image.is_compressed():
		var error := image.decompress()
		check(error==OK,label+": decompression failed")
		if error!=OK: return PackedByteArray()
	if image.has_mipmaps(): image.clear_mipmaps()
	image.convert(Image.FORMAT_RGBA8)
	return image.get_data()

func difference(a: PackedByteArray,b: PackedByteArray,width: int) -> Dictionary:
	if a.size()!=b.size():return {"byte_exact":false,"size_mismatch":true}
	var changed_channels := 0
	var changed_pixels := 0
	var maximum := 0
	var samples: Array[Dictionary] = []
	for pixel in (a.size() >> 2):
		var differs := false
		for channel in 4:
			var offset := pixel*4+channel
			if a[offset]!=b[offset]:
				differs=true
				changed_channels+=1
				maximum=maxi(maximum,absi(int(a[offset])-int(b[offset])))
		if differs:
			changed_pixels+=1
			if samples.size()<16:samples.append({"xy":[pixel%width,floori(float(pixel)/width)],"source":Array(a.slice(pixel*4,pixel*4+4)),"imported":Array(b.slice(pixel*4,pixel*4+4))})
	return {"byte_exact":changed_channels==0,"changed_channels":changed_channels,"changed_pixels":changed_pixels,"max_channel_delta_u8":maximum,"first_16_differences":samples}

func category(physical: String) -> String:
	# Same mapping as original_footsteps.update_motion; no audio routine is invoked.
	if physical in ["PM_Wood","PM_WoodBridge"]: return "Wood"
	if physical=="PM_Grass":return "Grass"
	return "Dirt"

func count_item(dictionary: Dictionary,key: String) -> void:
	dictionary[key]=int(dictionary.get(key,0))+1

func read_json(path: String) -> Dictionary:
	var value: Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
	if value is Dictionary:return value
	check(false,"Invalid JSON "+path)
	return {}

func snapshot() -> Dictionary:
	var files: Array[String]=[FOOTSTEP_SCRIPT,FOOTSTEP_MANIFEST]
	var baseline_hashes := {}
	for slug: String in EXPECTED:
		var folder := "res://assets/%s/landscape/"%slug
		files.append(folder+"atlas-manifest.json")
		files.append(folder+"atlas-coverage.png")
		for name: String in NAMES:
			files.append(folder+name)
			files.append(folder+name+".import")
			var config := ConfigFile.new()
			if config.load(folder+name+".import")==OK:
				var cache: String=str(config.get_value("remap","path",""))
				if not cache.is_empty():files.append(cache)
		if not baseline.is_empty():
			for index in NAMES.size():
				var old_path: String=baseline.path_join(slug+"-"+NAMES[index].trim_suffix(".png")+"-baseline.rgba8")
				files.append(old_path)
				baseline_hashes[old_path]=EXPECTED[slug].baseline_rgba[index]
	var result := {}
	for path: String in files:
		check(FileAccess.file_exists(path),"Required input missing: "+path)
		if FileAccess.file_exists(path):
			result[path]=file_digest(path)
			if baseline_hashes.has(path):
				check(result[path]==baseline_hashes[path],"Optional baseline RGBA hash mismatch: "+path)
	return result

func verify_map(slug: String,footstep_manifest: Dictionary) -> void:
	var expected: Dictionary=EXPECTED[slug]
	var width := int(expected["size"][0])
	var height := int(expected["size"][1])
	var folder := "res://assets/%s/landscape/"%slug
	var row := {"map":slug,"atlases":[],"baseline_inputs":[],"footsteps":{}}
	var raw_atlases: Array[PackedByteArray]=[]
	var imported_atlases: Array[PackedByteArray]=[]
	var old_atlases: Array[PackedByteArray]=[]
	for index in 2:
		var path: String=folder+NAMES[index]
		check(file_digest(path)==expected.png[index],slug+": original PNG hash changed "+NAMES[index])
		var raw_image := Image.load_from_file(ProjectSettings.globalize_path(path))
		var texture := load(path) as Texture2D
		if texture==null:
			check(false,slug+": could not load imported texture "+path)
			return
		var imported_image: Image=texture.get_image()
		var raw := image_rgba(raw_image,path+" raw")
		var imported := image_rgba(imported_image,path+" imported")
		if raw.size()!=width*height*4 or imported.size()!=width*height*4:
			check(false,slug+": unexpected atlas dimensions or byte count")
			return
		check(raw_image.get_size()==Vector2i(width,height) and imported_image.get_size()==Vector2i(width,height),slug+": atlas dimensions mismatch")
		check(digest(raw)==expected.rgba[index],slug+": raw RGBA hash changed")
		var diff := difference(raw,imported,width)
		check(bool(diff.byte_exact),slug+": imported atlas is not exact source "+NAMES[index])
		var config := ConfigFile.new()
		check(config.load(path+".import")==OK,slug+": could not read import settings")
		check(config.get_value("params","process/fix_alpha_border",null)==false,slug+": data atlas alpha-border fix remains enabled")
		var filename: String=slug+"-"+NAMES[index].trim_suffix(".png")+"-production.rgba8"
		var output_file := FileAccess.open(output.path_join(filename),FileAccess.WRITE)
		check(output_file!=null,slug+": cannot save imported RGBA")
		if output_file!=null:output_file.store_buffer(imported)
		row.atlases.append({"path":path,"raw_png_sha256":file_digest(path),"raw_rgba_sha256":digest(raw),
			"imported_rgba_sha256":digest(imported),"comparison":diff,"import_file_sha256":file_digest(path+".import"),"saved_rgba8":filename})
		raw_atlases.append(raw)
		imported_atlases.append(imported)
		if not baseline.is_empty():
			var old_path: String=baseline.path_join(slug+"-"+NAMES[index].trim_suffix(".png")+"-baseline.rgba8")
			var old_bytes := FileAccess.get_file_as_bytes(old_path)
			var old_sha256 := digest(old_bytes)
			check(old_bytes.size()==raw.size(),slug+": missing/invalid optional baseline RGBA")
			check(old_sha256==expected.baseline_rgba[index],slug+": optional baseline RGBA hash mismatch "+NAMES[index])
			if old_bytes.size()!=raw.size() or old_sha256!=expected.baseline_rgba[index]:return
			old_atlases.append(old_bytes)
			row.baseline_inputs.append({"path":old_path,"sha256":old_sha256,"expected_sha256":expected.baseline_rgba[index],"bytes":old_bytes.size()})
	var coverage_image := Image.load_from_file(ProjectSettings.globalize_path(folder+"atlas-coverage.png"))
	if coverage_image==null or coverage_image.is_empty():
		check(false,slug+": missing raw coverage image")
		return
	check(coverage_image.get_size()==Vector2i(width,height),slug+": coverage size mismatch")
	coverage_image.convert(Image.FORMAT_L8)
	var coverage := coverage_image.get_data()
	if coverage.size()!=width*height:
		check(false,slug+": coverage byte count mismatch")
		return
	var atlas_manifest := read_json(folder+"atlas-manifest.json")
	if not footstep_manifest.get("landscapes",{}).has(slug) or atlas_manifest.is_empty():
		check(false,slug+": missing landscape/footstep manifest")
		return
	var terrain: Dictionary=footstep_manifest.landscapes[slug]
	check(terrain.minimum_xy_ue_cm==atlas_manifest.minimum_xy_ue_cm and terrain.grid_step_xy_ue_cm==atlas_manifest.grid_step_xy_ue_cm,slug+": footstep world mapping differs from atlas")
	var script: Script=load(FOOTSTEP_SCRIPT)
	if script==null or not script.can_instantiate():
		check(false,"Footstep script cannot instantiate")
		return
	var driver: Node=script.new()
	# Do not add to SceneTree: _ready would load audio and create voices.
	driver.set("manifest",footstep_manifest)
	driver.call("select_map",slug)
	check(not driver.is_inside_tree() and driver.get_child_count()==0,slug+": footstep driver unexpectedly entered scene")
	var runtime_images: Array=driver.get("weights")
	check(runtime_images.size()==2,slug+": select_map did not load both weight images")
	for index in mini(runtime_images.size(),2):
		var probe_image: Image=runtime_images[index].duplicate()
		check(image_rgba(probe_image,"footstep loaded image")==raw_atlases[index],slug+": actual select_map image differs from source")
	var stats := {"covered_texels":0,"weight_sum_mismatches":0,"source_zero_sum":0,"imported_zero_sum":0,
		"source_weight_sum_min":2147483647,"source_weight_sum_max":0,"imported_weight_sum_min":2147483647,"imported_weight_sum_max":0,
		"footstep_calls":0,"footstep_mismatches":0,"source_physical_counts":{},"runtime_physical_counts":{},
		"source_groups":{"Grass":0,"Dirt":0,"Wood":0},"runtime_groups":{"Grass":0,"Dirt":0,"Wood":0},
		"samples_by_physical":{},"first_16_failures":[],"baseline_available":old_atlases.size()==2,
		"baseline_changed_texels":0,"baseline_zero_sum":0,"baseline_physmat_changes":0,"baseline_group_changes":0,
		"baseline_physical_transitions":{},"first_16_baseline_selection_changes":[]}
	var origin: Array=terrain.minimum_xy_ue_cm
	var step: Array=terrain.grid_step_xy_ue_cm
	for pixel in coverage.size():
		if coverage[pixel]==0:continue
		stats.covered_texels+=1
		var source_sum := 0
		var imported_sum := 0
		var old_sum := 0
		var source_max := -1
		var source_layer := 0
		var old_max := -1
		var old_layer := 0
		var old_changed := false
		for layer in 8:
			var atlas := layer >> 2
			var offset := pixel*4+(layer%4)
			var amount := int(raw_atlases[atlas][offset])
			source_sum+=amount
			imported_sum+=int(imported_atlases[atlas][offset])
			if amount>source_max:source_max=amount;source_layer=layer
			if old_atlases.size()==2:
				var old_amount := int(old_atlases[atlas][offset])
				old_sum+=old_amount
				if old_amount>old_max:old_max=old_amount;old_layer=layer
				if old_amount!=amount:old_changed=true
		if source_sum!=imported_sum:stats.weight_sum_mismatches+=1
		if source_sum==0:stats.source_zero_sum+=1
		if imported_sum==0:stats.imported_zero_sum+=1
		stats.source_weight_sum_min=mini(stats.source_weight_sum_min,source_sum)
		stats.source_weight_sum_max=maxi(stats.source_weight_sum_max,source_sum)
		stats.imported_weight_sum_min=mini(stats.imported_weight_sum_min,imported_sum)
		stats.imported_weight_sum_max=maxi(stats.imported_weight_sum_max,imported_sum)
		var x := pixel%width
		var y := floori(float(pixel)/width)
		var feet := Vector3((float(origin[0])+x*float(step[0]))*.01,0.0,(float(origin[1])+y*float(step[1]))*.01)
		var expected_physical: String=str(terrain.layers[source_layer]) if source_layer<terrain.layers.size() else ""
		var actual_physical: String=str(driver.call("_landscape_material",feet))
		stats.footstep_calls+=1
		count_item(stats.source_physical_counts,expected_physical)
		count_item(stats.runtime_physical_counts,actual_physical)
		count_item(stats.source_groups,category(expected_physical))
		count_item(stats.runtime_groups,category(actual_physical))
		if not stats.samples_by_physical.has(expected_physical):stats.samples_by_physical[expected_physical]={"xy":[x,y],"feet":[feet.x,feet.y,feet.z],"source_layer":source_layer,"expected":expected_physical,"actual":actual_physical}
		if actual_physical!=expected_physical:
			stats.footstep_mismatches+=1
			if stats.first_16_failures.size()<16:stats.first_16_failures.append({"xy":[x,y],"source_layer":source_layer,"expected":expected_physical,"actual":actual_physical})
		if old_atlases.size()==2:
			if old_changed:stats.baseline_changed_texels+=1
			if old_sum==0:stats.baseline_zero_sum+=1
			var old_physical: String=str(terrain.layers[old_layer]) if old_layer<terrain.layers.size() else ""
			if old_physical!=expected_physical:
				stats.baseline_physmat_changes+=1
				count_item(stats.baseline_physical_transitions,old_physical+" -> "+expected_physical)
				if stats.first_16_baseline_selection_changes.size()<16:stats.first_16_baseline_selection_changes.append({"xy":[x,y],"before":old_physical,"source_and_expected_after":expected_physical})
			if category(old_physical)!=category(expected_physical):stats.baseline_group_changes+=1
	check(stats.covered_texels==int(expected.covered),slug+": covered texel count differs")
	check(stats.weight_sum_mismatches==0 and stats.source_zero_sum==0 and stats.imported_zero_sum==0,slug+": coverage weight sum mismatch or zero")
	check(stats.footstep_calls==stats.covered_texels and stats.footstep_mismatches==0,slug+": actual footstep selection differs from source weights")
	check(stats.source_groups==stats.runtime_groups,slug+": footstep group distribution differs")
	check(not driver.is_inside_tree() and driver.get_child_count()==0 and driver.get("voices").is_empty() and driver.get("streams").is_empty() and int(driver.get("play_count"))==0,slug+": audio was initialized or played")
	stats.audio_ready_not_invoked=driver.get_child_count()==0 and driver.get("voices").is_empty() and int(driver.get("play_count"))==0
	driver.free()
	row.footsteps=stats
	report.maps.append(row)
	save_report()
	print("LANDSCAPE_WEIGHTS_MAP ",JSON.stringify({"map":slug,"covered":stats.covered_texels,"footstep_mismatches":stats.footstep_mismatches,"groups":stats.runtime_groups}))

func run() -> void:
	if output.is_empty():push_error("Missing --report-dir");quit(2);return
	if DirAccess.make_dir_recursive_absolute(output)!=OK:push_error("Could not create output directory");quit(2);return
	var start := Time.get_ticks_msec()
	report.inputs_before=snapshot()
	var manifest := read_json(FOOTSTEP_MANIFEST)
	if report.failures.is_empty():
		for slug: String in ["wuming","youxian"]:verify_map(slug,manifest)
	report.inputs_after=snapshot()
	check(report.inputs_before==report.inputs_after,"Verifier changed input files")
	check(report.maps.size()==2,"Expected both maps completed")
	report.elapsed_seconds=float(Time.get_ticks_msec()-start)/1000.0
	report.stage="complete"
	report.overall_passed=report.failures.is_empty()
	save_report()
	print("LANDSCAPE_WEIGHTS_RESULT ",JSON.stringify({"passed":report.overall_passed,"elapsed_seconds":report.elapsed_seconds,"failures":report.failures}))
	quit(0 if report.overall_passed else 1)
