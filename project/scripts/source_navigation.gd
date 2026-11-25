extends RefCounted
## Queries the recovered source Detour polygons. Does not generate scene models.

var data: Dictionary
var polygons: Array
var grid: Dictionary
var report: Dictionary

func setup(slug: String) -> Dictionary:
	data = JSON.parse_string(FileAccess.get_file_as_string("res://assets/source-navigation/%s-query.json" % slug))
	polygons = data.polygons
	grid = data.grid
	# Decode the serialized source coordinates once. Polygon order, detail
	# triangles, portals, grid traversal, and all query limits stay unchanged.
	for p in polygons:
		for i in p.v.size():
			p.v[i] = _decode_source_vector(p.v[i])
		for tri in p.tri:
			for i in tri.size():
				tri[i] = _decode_source_vector(tri[i])
		p.center = _decode_source_vector(p.center)
		for link in p.links:
			for i in link.portal.size():
				link.portal[i] = _decode_source_vector(link.portal[i])
	report = {"source_tiles":int(data.source_tiles),"source_polygons":polygons.size(),"rebaked":false}
	return report

func _decode_source_vector(a: Array) -> Vector3:
	return Vector3(float(a[0]),float(a[1]),float(a[2]))

func _v(a: Vector3) -> Vector3:
	return a

func _cross(a: Vector3, b: Vector3, c: Vector3) -> float:
	return (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)

func _xz(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x-b.x,a.z-b.z).length()

func _height(poly: int, point: Vector3) -> Vector3:
	for tri in polygons[poly].tri:
		var a := _v(tri[0])
		var b := _v(tri[1])
		var c := _v(tri[2])
		var den := _cross(a,b,c)
		if absf(den) < 0.00000001:
			continue
		var u := _cross(a,point,c)/den
		var v := _cross(a,b,point)/den
		if u >= -0.00001 and v >= -0.00001 and u+v <= 1.00001:
			return Vector3(point.x,a.y+(b.y-a.y)*u+(c.y-a.y)*v,point.z)
	return Vector3(point.x,_v(polygons[poly].center).y,point.z)

func _closest(poly: int, point: Vector3) -> Vector3:
	var inside := true
	var vertices: Array = polygons[poly].v
	var best := Vector3.INF
	var distance := INF
	var sign_seen := 0
	for i in vertices.size():
		var a := _v(vertices[i])
		var b := _v(vertices[(i+1)%vertices.size()])
		var side := _cross(a,b,point)
		if absf(side) > 0.000001:
			var side_sign := 1 if side > 0.0 else -1
			if sign_seen != 0 and side_sign != sign_seen:
				inside = false
			sign_seen = side_sign
		var ab := Vector2(b.x-a.x,b.z-a.z)
		var ap := Vector2(point.x-a.x,point.z-a.z)
		var t := clampf(ap.dot(ab)/maxf(ab.length_squared(),0.00000001),0.0,1.0)
		var q := a.lerp(b,t)
		var ds := _xz(q,point)
		if ds < distance:
			distance = ds
			best = q
	return _height(poly,point) if inside else best

func project(point: Vector3, horizontal := 0.75, vertical := 1.25) -> Dictionary:
	var candidates: Dictionary = {}
	for x in range(floori((point.x-horizontal)/10.0),floori((point.x+horizontal)/10.0)+1):
		for z in range(floori((point.z-horizontal)/10.0),floori((point.z+horizontal)/10.0)+1):
			for i in grid.get("%s,%s" % [x,z],[]):
				candidates[int(i)] = true
	var result: Dictionary = {}
	var distance := INF
	for i in candidates:
		var q := _closest(i,point)
		if _xz(q,point) > horizontal or absf(q.y-point.y) > vertical:
			continue
		var ds := q.distance_squared_to(point)
		if ds < distance:
			distance = ds
			result = {"poly":i,"point":q,"distance":sqrt(ds)}
	return result

func point_on_poly(poly: int, point: Vector3) -> Vector3:
	return _closest(poly,point)

func random_reachable(start_poly: int, center: Vector3, radius: float, rng: RandomNumberGenerator) -> Dictionary:
	var queue: Array[int] = [start_poly]
	var seen := {start_poly:true}
	var selected := -1
	var total_area := 0.0
	for current in queue:
		var p: Dictionary = polygons[current]
		var vertices: Array = p.v
		var area := 0.0
		for j in range(1,vertices.size()-1):
			area += absf(_cross(_v(vertices[0]),_v(vertices[j]),_v(vertices[j+1])))*0.5
		total_area += area
		if rng.randf()*total_area <= area:
			selected = current
		for link in p.links:
			var next := int(link.to)
			if seen.has(next):
				continue
			var a := _v(link.portal[0])
			var b := _v(link.portal[1])
			var ab := Vector2(b.x-a.x,b.z-a.z)
			var ac := Vector2(center.x-a.x,center.z-a.z)
			var q := a.lerp(b,clampf(ac.dot(ab)/maxf(ab.length_squared(),0.000001),0.0,1.0))
			if _xz(q,center) > radius:
				continue
			seen[next] = true
			queue.append(next)
	if selected < 0:
		return {}
	var vertices: Array = polygons[selected].v
	var tri := 1
	var area_total := 0.0
	for j in range(1,vertices.size()-1):
		var area := absf(_cross(_v(vertices[0]),_v(vertices[j]),_v(vertices[j+1])))*0.5
		area_total += area
		if rng.randf()*area_total <= area:
			tri = j
	var u := sqrt(rng.randf())
	var v := rng.randf()
	var point := _v(vertices[0])*(1.0-u)+_v(vertices[tri])*(u*(1.0-v))+_v(vertices[tri+1])*(u*v)
	return {"poly":selected,"point":_height(selected,point)}

func route(start: Dictionary, goal: Dictionary) -> Array[Dictionary]:
	var first := int(start.poly)
	var last := int(goal.poly)
	var frontier: Array[int] = [first]
	var g := {first:0.0}
	var f := {first:_xz(start.point,goal.point)}
	var came: Dictionary = {}
	var closed: Dictionary = {}
	while not frontier.is_empty():
		var best_index := 0
		for j in range(1,frontier.size()):
			if float(f[frontier[j]]) < float(f[frontier[best_index]]):
				best_index = j
		var current := frontier[best_index]
		frontier.remove_at(best_index)
		if current == last:
			var corridor: Array[int] = [last]
			var portals: Array = []
			while current != first:
				var previous: Dictionary = came[current]
				portals.push_front(previous.link.portal)
				current = int(previous.from)
				corridor.push_front(current)
			return _funnel(start.point,goal.point,corridor,portals)
		closed[current] = true
		for link in polygons[current].links:
			var next := int(link.to)
			if closed.has(next):
				continue
			var score := float(g[current])+_v(polygons[current].center).distance_to(_v(polygons[next].center))
			if not g.has(next) or score < float(g[next]):
				g[next] = score
				f[next] = score+_xz(_v(polygons[next].center),goal.point)
				came[next] = {"from":current,"link":link}
				if not frontier.has(next):
					frontier.append(next)
	return []

func _funnel(start: Vector3, goal: Vector3, corridor: Array[int], source: Array) -> Array[Dictionary]:
	# Source polygons run clockwise in XZ; edge order supplies portal left/right.
	var portals: Array = [[start,start]]
	for p in source:
		portals.append([_v(p[0]),_v(p[1])])
	portals.append([goal,goal])
	var points: Array[Dictionary] = []
	var apex := start
	var left := start
	var right := start
	var apex_index := 0
	var left_index := 0
	var right_index := 0
	var i := 1
	var guard := 0
	while i < portals.size() and guard < portals.size()*8:
		guard += 1
		var new_left: Vector3 = portals[i][0]
		var new_right: Vector3 = portals[i][1]
		# This sign is the conventional Detour triArea2D (the negative XZ cross).
		if -_cross(apex,right,new_right) <= 0.0:
			if _xz(apex,right) < 0.00001 or -_cross(apex,left,new_right) > 0.0:
				right = new_right
				right_index = i
			else:
				points.append({"point":left,"poly":corridor[mini(left_index,corridor.size()-1)]})
				apex = left
				apex_index = left_index
				left = apex
				right = apex
				left_index = apex_index
				right_index = apex_index
				i = apex_index+1
				continue
		if -_cross(apex,left,new_left) >= 0.0:
			if _xz(apex,left) < 0.00001 or -_cross(apex,right,new_left) < 0.0:
				left = new_left
				left_index = i
			else:
				points.append({"point":right,"poly":corridor[mini(right_index,corridor.size()-1)]})
				apex = right
				apex_index = right_index
				left = apex
				right = apex
				left_index = apex_index
				right_index = apex_index
				i = apex_index+1
				continue
		i += 1
	if guard >= portals.size()*8:
		return []
	points.append({"point":goal,"poly":corridor[-1]})
	return points
