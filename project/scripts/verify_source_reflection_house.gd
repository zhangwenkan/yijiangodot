extends SceneTree
## Run after the parent applies the default renderer integration patch.
## Exercises actual house state/caches/signals, not trigger navigation or walking.
var out := ""
var scene: Node3D
var report := {"maps":[],"failures":[],"scope":"Actual house.set_inside state transitions and renderer teardown, not a doorway navigation test."}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--reflection-house-report-dir="): out = arg.trim_prefix("--reflection-house-report-dir=")
	call_deferred("run")

func settle(count: int = 12) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func _sky_material_state() -> Dictionary:
	var result := {"opaque":[],"transparent":[]}
	for state: Dictionary in scene.source_renderer.sh._saved:
		if is_instance_valid(state.object): result.opaque.append(state.object.get_shader_parameter("source_sh9_enabled"))
	for state: Dictionary in scene.source_renderer.transparent_sky._saved:
		if is_instance_valid(state.material): result.transparent.append(state.material.get_shader_parameter("source_sh9_enabled"))
	return result

func _check_phase(adapter: Node, expected_inside: bool) -> Dictionary:
	var environment: Environment = scene.source_renderer._environment
	var errors: Array[String] = []
	if bool(scene.house_driver.is_in_house) != expected_inside: errors.append("House state differs.")
	if bool(adapter._inside) != expected_inside: errors.append("Reflection adapter did not receive house signal.")
	if environment.sky != adapter._candidate_sky: errors.append("Candidate sky resource changed.")
	if environment.ambient_light_energy != (0.0 if expected_inside else 1.0): errors.append("Environment energy differs.")
	var expected_reflection := Environment.REFLECTION_SOURCE_DISABLED if expected_inside else Environment.REFLECTION_SOURCE_SKY
	if environment.reflected_light_source != expected_reflection: errors.append("Reflection indoor/outdoor mode differs.")
	var expected_ambient := Environment.AMBIENT_SOURCE_COLOR if expected_inside else Environment.AMBIENT_SOURCE_SKY
	if environment.ambient_light_source != expected_ambient: errors.append("Ambient source did not follow source house cache.")
	for state: Dictionary in adapter._probes:
		if not is_instance_valid(state.probe) or state.probe.visible: errors.append("Incorrect source adaptation probe became visible.")
	var material_state := _sky_material_state()
	for family in material_state:
		for enabled in material_state[family]:
			if enabled != not expected_inside: errors.append("SH enabled state differs for "+family); break
	var cache: Array = scene.environment_driver._house_lighting_cache
	if expected_inside and cache.is_empty(): errors.append("Source house cache was not populated.")
	if not expected_inside and not cache.is_empty(): errors.append("Source house cache was not drained.")
	return {"inside":expected_inside,"errors":errors,"energy":environment.ambient_light_energy,
		"reflection_source":environment.reflected_light_source,"ambient_source":environment.ambient_light_source,
		"house_cache_entries":cache.size(),"opaque_SH_count":material_state.opaque.size(),"transparent_SH_count":material_state.transparent.size(),
		"candidate_sky_preserved":environment.sky == adapter._candidate_sky,"probe_hidden_count":adapter._probes.size()}

func run() -> void:
	if out.is_empty(): quit(2); return
	root.size = Vector2i(1280,720)
	DirAccess.make_dir_recursive_absolute(out)
	scene = load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug != slug: await scene._load_world(slug)
		scene.tour_finished = true
		scene.house_driver.reset_outdoors()
		await settle(24)
		var adapter: Node = scene.source_renderer.get("reflection")
		if not is_instance_valid(adapter) or adapter._saved.is_empty():
			report.failures.append(slug+": default reflection adapter missing")
			continue
		var environment: Environment = scene.source_renderer._environment
		var saved: Dictionary = adapter._saved.duplicate()
		var probe_states: Array = adapter._probes.duplicate()
		var previous_process: int = scene.process_mode
		var previous_time := Engine.time_scale
		scene.process_mode = Node.PROCESS_MODE_DISABLED
		Engine.time_scale = 0.0
		var entry := {"map":slug,"phases":[]}
		for phase in [{"name":"outdoor-initial","inside":false},{"name":"indoor-1","inside":true},{"name":"outdoor-1","inside":false},{"name":"indoor-2","inside":true},{"name":"outdoor-2","inside":false}]:
			scene.house_driver.set_inside(phase.inside)
			await settle()
			var result := _check_phase(adapter,phase.inside)
			result["name"] = phase.name
			entry.phases.append(result)
			if not result.errors.is_empty(): report.failures.append(slug+" "+phase.name+": "+str(result.errors))
			root.get_texture().get_image().save_png(out.path_join(slug+"-"+phase.name+".png"))
		# Teardown while indoors must reset the house before restoring saved sky,
		# otherwise the cached energy1/probe-hidden state could overwrite baseline.
		scene.house_driver.set_inside(true)
		await settle()
		entry["shutdown_from_indoor"] = scene.source_renderer.shutdown()
		var shutdown_errors: Array[String] = []
		if scene.house_driver.is_in_house: shutdown_errors.append("House not reset outdoors during teardown.")
		if not scene.environment_driver._house_lighting_cache.is_empty(): shutdown_errors.append("House cache survived teardown.")
		if not adapter._saved.is_empty(): shutdown_errors.append("Reflection saved state survived teardown.")
		if environment.sky != saved.sky: shutdown_errors.append("Original sky resource not restored.")
		if environment.ambient_light_energy != saved.energy: shutdown_errors.append("Original ambient energy not restored.")
		if environment.reflected_light_source != saved.reflection_source: shutdown_errors.append("Original reflection source not restored.")
		for state: Dictionary in probe_states:
			if not is_instance_valid(state.probe) or state.probe.visible != state.visible: shutdown_errors.append("Original adaptation probe visibility not restored.")
		entry["shutdown_assertions"] = {"errors":shutdown_errors,"restored_energy":environment.ambient_light_energy,
			"restored_reflection_source":environment.reflected_light_source,"house_outdoors":not scene.house_driver.is_in_house}
		if not shutdown_errors.is_empty(): report.failures.append(slug+": teardown "+str(shutdown_errors))
		report.maps.append(entry)
		scene.process_mode = previous_process
		Engine.time_scale = previous_time
	FileAccess.open(out.path_join("reflection-house-validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SOURCE_REFLECTION_HOUSE_VALIDATED ",JSON.stringify({"maps":report.maps.size(),"failures":report.failures}))
	scene.queue_free()
	await settle(5)
	quit(0 if report.failures.is_empty() else 1)
