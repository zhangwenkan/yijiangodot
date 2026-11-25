extends SceneTree
## Seven real-asset checks: four boardwalk directions, stairs up/down, Youxian door.
## Requires local imported assets. No generated geometry, nav edits, or ray snapping.
## Run: godot --headless --fixed-fps 60 --path project --script res://scripts/verification/verify_original_movement_regression.gd -- --output=<report.json>

var output: String="user://original-movement-regression.json"
var report: Dictionary={"scope":"Seven headless physics regressions on original imported collisions; no visual/full-map equivalence claim.","cases":[],"failures":[]}

class CaseDriver extends Node:
	var player: CharacterBody3D
	var house: Node
	var definition: Dictionary
	var tick: int=0
	var waypoint: int=0
	var arrived_tick: int=-1
	var finished: bool=false
	var previous: Vector3
	var start_position: Vector3
	var inside: bool=false
	var row: Dictionary={}
	func v3(value: Vector3) -> Array: return [value.x,value.y,value.z]
	func xz(a: Vector3,b: Vector3) -> float: return Vector2(a.x-b.x,a.z-b.z).length()
	func begin() -> void:
		process_physics_priority=50
		start_position=player.global_position
		previous=start_position
		row={"name":definition.name,"map":definition.map,"initial_placements":1,"mid_case_teleports":0,"initial_feet":v3(start_position),"min_gap":INF,"max_gap":-INF,"missing_support_ticks":0,"below_support_ticks":0,"below_dry_ticks":0,"support_components":{},"outward_travel_m":0.0,"return_travel_m":0.0,"outward_displacement_m":0.0,"house_transitions":[],"samples":[],"anomalies":[],"max_height":start_position.y,"min_height":start_position.y}
	func _physics_process(delta: float) -> void:
		if finished: return
		var pos: Vector3=player.global_position
		var moved: float=xz(pos,previous)
		var door_case: bool=definition.has("path")
		if not door_case:
			if tick<definition.frames: row.outward_travel_m+=moved
			elif tick<definition.frames*2: row.return_travel_m+=moved
			if tick==definition.frames: row.outward_displacement_m=xz(pos,start_position)
		var hit: Dictionary=player._support_at(pos,player.MAX_STEP_HEIGHT+.07,player.MAX_STEP_HEIGHT+.15)
		var sample: Dictionary={"tick":tick,"feet":v3(pos),"gap":null,"support":"","edge_blocked":player.blocked_at_edge,"scale":player.source_house_scale,"speed":player.move_speed}
		if hit.is_empty(): row.missing_support_ticks+=1
		else:
			var gap: float=pos.y-float(hit.position.y)
			var component: String=str(int(hit.collider.get_meta("source_component",-1)))
			sample.gap=gap
			sample.support=str(hit.collider.get_meta("source_name","unknown"))
			row.support_components[component]=int(row.support_components.get(component,0))+1
			row.min_gap=minf(row.min_gap,gap)
			row.max_gap=maxf(row.max_gap,gap)
			if gap<-.03: row.below_support_ticks+=1
			if gap<-.03 or gap>.15: row.anomalies.append(sample)
		if pos.y<player.MIN_DRY_FOOT_HEIGHT: row.below_dry_ticks+=1
		row.min_height=minf(row.min_height,pos.y)
		row.max_height=maxf(row.max_height,pos.y)
		if is_instance_valid(house) and house.is_in_house!=inside:
			inside=house.is_in_house
			row.house_transitions.append({"tick":tick,"inside":inside,"feet":v3(pos),"scale":player.source_house_scale,"speed":player.move_speed})
		if tick%6==0: row.samples.append(sample)
		var controls: Vector2=Vector2.ZERO
		if door_case:
			while waypoint<definition.path.size() and xz(pos,definition.path[waypoint])<.12: waypoint+=1
			if waypoint==definition.path.size() and arrived_tick<0: arrived_tick=tick
			if arrived_tick<0 and tick<720:
				var heading: Vector3=definition.path[waypoint]-pos
				heading.y=0
				heading=heading.normalized()*minf(1.0,heading.length()/maxf(player.move_speed*delta,.001))
				controls=Vector2(heading.z,-heading.x)
			if (arrived_tick>=0 and tick-arrived_tick>=60) or tick>=780: finished=true
		else:
			if tick<definition.frames: controls=definition.input
			elif tick<definition.frames*2: controls=-definition.input
			if tick>=definition.frames*2+60: finished=true
		player.set_review_motion(Vector2.ZERO if finished else controls)
		if finished:
			row.final_feet=v3(pos)
			row.return_distance_m=xz(pos,start_position)
			row.arrived=arrived_tick>=0 if door_case else true
			row.final_inside=inside
			row.final_scale=player.source_house_scale
			row.final_speed=player.move_speed
		previous=pos
		tick+=1

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="): output=argument.trim_prefix("--output=")
	call_deferred("run")

func save_report() -> void:
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var file: FileAccess=FileAccess.open(output,FileAccess.WRITE)
	if file==null:
		push_error("Cannot write movement regression report: "+output)
		return
	file.store_string(JSON.stringify(report,"\t"))

func required_assets() -> Array[String]:
	var paths: Array[String]=["res://assets/characters/original_hero/source-manifest.json","res://assets/characters/original_hero/original_hero.tres","res://assets/characters/original_hero/footsteps/manifest.json","res://assets/environment/original-houses.json"]
	for map: String in ["wuming","youxian"]:
		paths.append("res://assets/%s/collision.glb"%map)
		for weights: String in ["atlas-weights-1-4.png","atlas-weights-5-8.png"]: paths.append("res://assets/%s/landscape/%s"%[map,weights])
	return paths

func run() -> void:
	var missing: Array[String]=[]
	for path: String in required_assets():
		if not FileAccess.file_exists(path) and not ResourceLoader.exists(path): missing.append(path)
	if not missing.is_empty():
		report.status="blocked_missing_local_assets"
		report.missing_assets=missing
		report.failures.append("Restore and import the local original assets before running this regression.")
		save_report()
		quit(2)
		return
	var cases: Array=[
		{"name":"boardwalk7084_right_return","map":"wuming","start":Vector3(-89.4105,3.45,0),"input":Vector2.RIGHT,"frames":12,"required_component":"7084"},
		{"name":"boardwalk7084_left_return","map":"wuming","start":Vector3(-89.4105,3.45,0),"input":Vector2.LEFT,"frames":12,"required_component":"7084"},
		{"name":"boardwalk7084_up_return","map":"wuming","start":Vector3(-89.4105,3.45,0),"input":Vector2.UP,"frames":12,"required_component":"7084"},
		{"name":"boardwalk7084_down_return","map":"wuming","start":Vector3(-89.4105,3.45,0),"input":Vector2.DOWN,"frames":12,"required_component":"7084"},
		{"name":"stair6896_up_return","map":"wuming","start":Vector3(-79.8,3.5,38.231),"input":Vector2.UP,"frames":48,"required_component":"6896"},
		{"name":"stair6896_down_return","map":"wuming","start":Vector3(-77.3,4.4,38.231),"input":Vector2.DOWN,"frames":48,"required_component":"6896"},
		{"name":"youxian_original_door_enter_exit","map":"youxian","start":Vector3(-54.99952,3.3729863,44.87575),"path":[Vector3(-51.34952,3.920986,44.87575),Vector3(-54.99952,3.3729863,44.87575)]}]
	for map: String in ["wuming","youxian"]:
		var scene:=Node3D.new()
		root.add_child(scene)
		var collision: Node3D=preload("res://scripts/original_collision.gd").new()
		scene.add_child(collision)
		var collision_report: Dictionary=collision.setup(map)
		if int(collision_report.get("bodies",0))==0:
			report.failures.append(map+": no imported collision bodies")
			scene.queue_free()
			await process_frame
			continue
		for definition: Dictionary in cases:
			if definition.map!=map: continue
			var player: CharacterBody3D=preload("res://scripts/original_player.gd").new()
			scene.add_child(player)
			player.input_enabled=false
			player.footsteps.select_map(map)
			player.set_review_motion(Vector2.ZERO)
			var house: Node
			if definition.has("path"):
				house=preload("res://scripts/original_house.gd").new()
				scene.add_child(house)
				# Actual trigger transforms and collision lists, with no visual scene.
				var visual_root:=Node3D.new()
				scene.add_child(visual_root)
				house.setup(map,visual_root,collision,player,null,null)
				visual_root.queue_free()
			await physics_frame
			await physics_frame
			if not player.place_at_source_actor_position(definition.start):
				report.failures.append(definition.name+": unsupported original start")
				if is_instance_valid(house): house.queue_free()
				player.queue_free()
				await process_frame
				continue
			for i in 8: await physics_frame
			var driver:=CaseDriver.new()
			driver.player=player
			driver.house=house
			driver.definition=definition
			driver.begin()
			scene.add_child(driver)
			while not driver.finished: await process_frame
			var row: Dictionary=driver.row
			if row.missing_support_ticks>0 or row.below_support_ticks>0 or row.below_dry_ticks>0: report.failures.append(definition.name+": support violation")
			if definition.has("required_component"):
				if not row.support_components.has(definition.required_component): report.failures.append(definition.name+": required original support not contacted")
				if row.outward_displacement_m<.3 or row.return_travel_m<.3: report.failures.append(definition.name+": did not move in both directions")
				if definition.name.begins_with("stair") and row.max_height-row.min_height<.5: report.failures.append(definition.name+": did not traverse original stair height")
			else:
				if not row.arrived or row.final_inside or row.house_transitions.size()!=2: report.failures.append(definition.name+": entry/exit failed")
				if absf(row.final_scale-1.0)>.0001 or absf(row.final_speed-6.0)>.0001: report.failures.append(definition.name+": exterior capsule/speed not restored")
				for transition: Dictionary in row.house_transitions:
					if transition.inside and (absf(transition.scale-.6)>.0001 or absf(transition.speed-3.0)>.0001): report.failures.append(definition.name+": interior capsule/speed incorrect")
			report.cases.append(row)
			print("ORIGINAL_MOVEMENT_CASE ",JSON.stringify({"name":row.name,"min_gap":row.min_gap,"missing":row.missing_support_ticks,"negative":row.below_support_ticks,"arrived":row.arrived}))
			driver.queue_free()
			if is_instance_valid(house):
				house.shutdown()
				house.queue_free()
			player.queue_free()
			await process_frame
		scene.queue_free()
		await process_frame
	report.status="passed" if report.failures.is_empty() and report.cases.size()==7 else "failed"
	save_report()
	print("ORIGINAL_MOVEMENT_REGRESSION ",report.status," ",output)
	quit(0 if report.status=="passed" else 1)
