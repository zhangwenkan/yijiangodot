extends "res://scripts/source_navigation.gd"
## Honor native BTTask_MoveTo AllowPartialPath on the recovered source graph.
## Inherited route() stays complete-only; animals explicitly opt in here.
## Exact routes retain the current adapter result. No new edge/surface/extent.
## Fallback follows the local Shipping Detour lastBestNode rule: portal midpoint,
## 3D heuristic, update only after a better candidate, partial bit if end not found.
## Native anchors/query/filter/link ordering and CharacterMovement remain separate.

var last_result: Dictionary = {}

func route_allow_partial(start: Dictionary, goal: Dictionary) -> Array[Dictionary]:
	var complete: Array[Dictionary] = super.route(start,goal)
	if not complete.is_empty():
		last_result = {"status":"complete","target_reached":true,"path":complete,"endpoint":goal.point,"requested_goal_poly":int(goal.poly),"last_reachable_poly":int(goal.poly),"endpoint_displacement_m":_xz(start.point,goal.point)}
		return complete
	last_result = _partial_route(start,goal)
	return last_result.path

func _partial_route(start: Dictionary, goal: Dictionary) -> Dictionary:
	var first := int(start.poly)
	var last := int(goal.poly)
	var frontier: Array[int] = [first]
	var g := {first:0.0}
	# ARecastNavMesh constructor 0x1437a48d8: 0x3f7fbe77 ~= 0.999.
	# The failing component's 220 source polygons are all default area 63 / flag 1.
	var heuristic_scale := 0.999
	var f := {first:start.point.distance_to(goal.point)*heuristic_scale}
	var positions := {first:start.point}
	var came: Dictionary = {}
	var closed: Dictionary = {}
	var best_poly := first
	var best_heuristic := float(f[first])
	var updates: Array[Dictionary] = [{"poly":first,"point":start.point,"heuristic":best_heuristic}]
	var reopened := 0
	var iterations := 0
	while not frontier.is_empty():
		iterations += 1
		if iterations > polygons.size()*4:
			return {"status":"search_guard","target_reached":false,"path":[]}
		var best_index := 0
		for j in range(1,frontier.size()):
			if float(f[frontier[j]]) < float(f[frontier[best_index]]):
				best_index = j
		var current := frontier[best_index]
		frontier.remove_at(best_index)
		closed[current] = true
		if current == last:
			best_poly = current
			break
		var parent_poly := int(came[current].from) if came.has(current) else -1
		for link in polygons[current].links:
			var next := int(link.to)
			if next == parent_poly:
				continue
			# Native 0x143734565–45ee recalculates each portal midpoint when
			# heuristic scale <= 1, rather than fixing the first incoming portal.
			var node_point: Vector3 = (_v(link.portal[0])+_v(link.portal[1]))*0.5
			var current_point: Vector3 = positions[current]
			var score := float(g[current])+current_point.distance_to(node_point)
			var heuristic := node_point.distance_to(goal.point)*heuristic_scale
			if next == last:
				score += node_point.distance_to(goal.point)
				heuristic = 0.0
			var total := score+heuristic
			# Native 0x1437348d4–48f9 compares the total for open/closed nodes.
			if f.has(next) and total >= float(f[next]):
				continue
			if closed.has(next):
				closed.erase(next)
				reopened += 1
			g[next] = score
			f[next] = total
			positions[next] = node_point
			came[next] = {"from":current,"link":link}
			if not frontier.has(next):
				frontier.append(next)
			# Native 0x14373499a–49bd: nearest search NODE, not nearest
			# polygon boundary across the whole connected component.
			if heuristic < best_heuristic:
				best_heuristic = heuristic
				best_poly = next
				updates.append({"poly":next,"point":node_point,"heuristic":heuristic})
	var corridor: Array[int] = [best_poly]
	var portals: Array = []
	var current := best_poly
	while current != first:
		if not came.has(current) or corridor.size() > polygons.size():
			return {"status":"corridor_guard","target_reached":false,"path":[]}
		var previous: Dictionary = came[current]
		portals.push_front(previous.link.portal)
		current = int(previous.from)
		corridor.push_front(current)
	var endpoint := _closest(best_poly,goal.point)
	var path: Array[Dictionary] = _funnel(start.point,endpoint,corridor,portals)
	var progress := _xz(start.point,endpoint)
	var partial := best_poly != last
	if not path.is_empty():
		path[-1].partial = partial
		path[-1].requested_goal = goal.point
	return {"status":("partial" if partial else "complete_fallback") if not path.is_empty() else "funnel_failure", "target_reached":not partial,
		"path":path,"corridor":corridor,"last_reachable_poly":best_poly,"requested_goal_poly":int(goal.poly),
		"endpoint":endpoint,"unreached_distance_m":endpoint.distance_to(goal.point),"endpoint_displacement_m":progress,
		"zero_displacement_partial":partial and progress < 0.00001,
		"last_best_heuristic":best_heuristic,"last_best_updates":updates,"reopened_nodes":reopened,
		"source_polygons_visited":closed.size(),"iterations":iterations,"added_links":0,"expanded_query_extent":false,
		"selection_rule":"Shipping 0x143733ff0 lastBestNode / 3D portal-midpoint heuristic",
		"limitation":"Current decoded graph link order / tie order; default-area cost only; current funnel and source anchors remain adapter behavior"}
