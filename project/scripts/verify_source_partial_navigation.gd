extends SceneTree
## CPU-only regression for source navigation partial-path semantics.
const FIXTURE := "res://scripts/fixtures/partial_navigation_samples.json"
var output := "user://partial-navigation-validation.json"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--partial-nav-out="):
			output = arg.trim_prefix("--partial-nav-out=")
	call_deferred("_run")

func _point(row: Dictionary) -> Dictionary:
	return {"poly":int(row.poly),"point":Vector3(float(row.point[0]),float(row.point[1]),float(row.point[2]))}

func _json_ready(value: Variant) -> Variant:
	if value is Vector3:
		return [value.x,value.y,value.z]
	if value is Dictionary:
		var copy := {}
		for key in value: copy[key] = _json_ready(value[key])
		return copy
	if value is Array:
		var copy: Array = []
		for item in value: copy.append(_json_ready(item))
		return copy
	return value

func _run() -> void:
	var candidate = load("res://scripts/source_navigation_partial.gd").new()
	var baseline = load("res://scripts/source_navigation.gd").new()
	candidate.setup("youxian")
	baseline.setup("youxian")
	var source: Array = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var report := {"errors":[],"samples":[],"complete_path_checks":0,"default_complete_only_checks":0,"method":"CPU-only production scripts; original polygons and links unchanged"}
	for row in source:
		var start := _point(row.start)
		var goal := _point(row.goal)
		var old_path: Array = baseline.route(start,goal)
		if not candidate.route(start,goal).is_empty():
			report.errors.append("inherited complete-only route accepted an unreachable target")
		else:
			report.default_complete_only_checks += 1
		var path: Array = candidate.route_allow_partial(start,goal)
		var result: Dictionary = candidate.last_result.duplicate(true)
		result.original_path_empty = old_path.is_empty()
		if not old_path.is_empty() or path.is_empty() or result.get("status","") != "partial" or result.get("target_reached",true):
			report.errors.append("recorded failure did not remain a genuine partial")
			report.samples.append(result)
			continue
		for i in range(1,result.corridor.size()):
			var valid := false
			for link in candidate.polygons[int(result.corridor[i-1])].links:
				if int(link.to)==int(result.corridor[i]): valid = true
			if not valid: report.errors.append("invented corridor link")
		if candidate.point_on_poly(int(result.last_reachable_poly),result.endpoint).distance_to(result.endpoint)>0.0001:
			report.errors.append("partial endpoint outside last source polygon")
		if result.last_reachable_poly == int(goal.poly) or result.endpoint.distance_to(goal.point)<0.0001:
			report.errors.append("disconnected requested target falsely reached")
		if not path[-1].get("partial",false) or path[-1].requested_goal != goal.point:
			report.errors.append("terminal waypoint lost partial / requested goal identity")
		for i in range(1,result.last_best_updates.size()):
			if result.last_best_updates[i].heuristic >= result.last_best_updates[i-1].heuristic:
				report.errors.append("lastBestNode heuristic did not strictly improve")
		report.samples.append(result)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261126
	for i in 100:
		var poly := int(rng.randi_range(0,candidate.polygons.size()-1))
		var origin: Vector3 = candidate.polygons[poly].center
		var start := {"poly":poly,"point":origin}
		var goal: Dictionary = candidate.random_reachable(poly,origin,3.0,rng)
		var expected: Array = baseline.route(start,goal)
		var default_path: Array = candidate.route(start,goal)
		var actual: Array = candidate.route_allow_partial(start,goal)
		if not expected.is_empty():
			report.complete_path_checks += 1
			if expected != actual or expected != default_path: report.errors.append("complete path changed")
	if report.complete_path_checks != 100: report.errors.append("complete-route coverage below 100")
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var f := FileAccess.open(output,FileAccess.WRITE)
	f.store_string(JSON.stringify(_json_ready(report),"\t"));f.close()
	print("SOURCE_PARTIAL_NAVIGATION ",report.samples.size()," complete=",report.complete_path_checks," errors=",report.errors)
	quit(0 if report.errors.is_empty() else 1)
