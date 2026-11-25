extends "res://scripts/source_animal_behavior.gd"
## Review-only observer; production _begin_path performs every request unchanged.
var review_tick := 0
var request_trace: Array[Dictionary] = []

func _begin_path(a: Dictionary, goal: Dictionary, post_wait: float, next_phase: String) -> void:
	var row := {"index":request_trace.size(),"tick":review_tick,"component":int(a.component),"tree":str(a.tree),"start":_trace_anchor(a.anchor),"goal":_trace_anchor(goal),"rng_before":str(rng.state),"post_wait":post_wait,"next_phase":next_phase,"seen_hero":bool(a.seen_hero)}
	var moves_before := int(report.moves)
	var failures_before := int(report.path_failures)
	super._begin_path(a,goal,post_wait,next_phase)
	row.accepted = int(report.moves)>moves_before
	row.path_failure = int(report.path_failures)>failures_before
	row.status = "empty_goal" if goal.is_empty() else str(navigation.last_result.get("status","unknown"))
	row.rng_after = str(rng.state)
	row.waypoints = []
	if row.accepted:
		row.partial = bool(a.get("path_is_partial",false))
		for step in a.path:
			row.waypoints.append(_trace_anchor(step))
	request_trace.append(row)

func _trace_anchor(value: Dictionary) -> Dictionary:
	if value.is_empty():
		return {}
	var point: Vector3 = value.point
	return {"poly":int(value.poly),"point":[point.x,point.y,point.z]}
