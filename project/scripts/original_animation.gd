extends Node3D
## Recovered original clip data and Blueprint timelines, with documented cross-engine limits.
const CONFIG := "res://assets/environment/original-environment-config.json"
const DATA := "res://assets/animation/original-animation-data.json"
var coverage := {"boats":0,"animated_boats":0,"butterflies":0,"birds":0,"big_boats":0,"missing":[]}
var _config: Dictionary
var _data: Dictionary
var _map: Dictionary
var _world: Node3D
var _player: Node3D
var _sources: Dictionary = {}
var _materials: Dictionary = {}
var _butterflies: Array[Dictionary] = []
var _birds: Array[Dictionary] = []
var _big_boats: Array[Dictionary] = []
var _bird_manifest: Dictionary = {}
var _time := 0.0

func setup(slug: String, world: Node3D, player: Node3D) -> void:
	_world = world
	_player = player
	_config = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	_data = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	_map = _config.get("maps", {}).get(slug, {})
	_index_sources(world)
	_setup_boats()
	_setup_butterflies()
	_setup_birds()
	for item in _data.get("big_boats", {}).get(slug, []):
		var node := _mesh(item["source_name"])
		if node != null:
			_big_boats.append({"node":node,"rest":node.global_transform,"source":item})
			coverage.big_boats += 1
	print("Original animation coverage ", slug, ": ", JSON.stringify(coverage))

func _index_sources(node: Node) -> void:
	if node.has_meta("source_name"):
		_sources[str(node.get_meta("source_name"))] = node
	if node is MeshInstance3D and node.mesh != null:
		for i in node.mesh.get_surface_count():
			var mat: Material = node.get_active_material(i)
			if mat != null:
				_materials[mat.resource_name] = mat
	for child in node.get_children():
		_index_sources(child)

func _first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _first_mesh(child)
		if found != null:
			return found
	return null

func _mesh(source: String) -> MeshInstance3D:
	var node = _sources.get(source)
	return _first_mesh(node) if is_instance_valid(node) else null

func _ue(m: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(m[0][0],m[2][0],m[1][0]),Vector3(m[0][2],m[2][2],m[1][2]),Vector3(m[0][1],m[2][1],m[1][1])),Vector3(m[0][3],m[2][3],m[1][3])*0.01)

func _load_gltf(path: String) -> Node3D:
	if ResourceLoader.exists(path):
		return load(path).instantiate()
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path,state) == OK:
		return doc.generate_scene(state)
	return null

func _setup_boats() -> void:
	var policy: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/material-policy.json"))
	for item in _map.get("skeletal_components", []):
		var props: Dictionary = item["properties"]
		var key := str(props.get("SkeletalMesh", "")).get_slice(".",1)
		if not key.begins_with("SM_JN_"):
			continue
		var rig := _load_gltf("res://assets/animation/%s.glb" % key)
		if rig == null:
			coverage.missing.append(item["name"])
			continue
		add_child(rig)
		rig.global_transform = _ue(item["matrix_ue"])
		rig.set_meta("source_name",item["name"])
		var override_name := ""
		var overrides: Array = props.get("OverrideMaterials", [])
		if not overrides.is_empty():
			var source_mat := str(overrides[0]).get_slice(".",1)
			for matkey in policy:
				if policy[matkey].get("source_name") == source_mat:
					override_name = matkey
					break
		for mesh in rig.find_children("*","MeshInstance3D",true,false):
			for i in mesh.mesh.get_surface_count():
				var mat: Material = mesh.mesh.surface_get_material(i)
				var matname: String = override_name if override_name != "" else mat.resource_name
				if _materials.has(matname):
					mesh.set_surface_override_material(i,_materials[matname])
		coverage.boats += 1
		var clip := str(props.get("AnimationData",{}).get("AnimToPlay", "")).get_slice(".",1)
		if clip == "":
			continue
		for anim in rig.find_children("*","AnimationPlayer",true,false):
			if anim.has_animation(clip):
				anim.get_animation(clip).length = 2.0 # Original 61 samples / 30.5 fps, includes final frame interval.
				anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
				anim.play(clip)
				coverage.animated_boats += 1
				break

func _setup_butterflies() -> void:
	for actor in _map.get("butterflies", []):
		var props: Dictionary = actor["properties"]
		var components: Dictionary = {}
		for component in actor["components"]:
			components[component["name"]] = component
		var driver := _ue(components[props["Butterfly_Anim_Var01"]]["matrix_ue"])
		var root := _ue(components[props["Butterfly_Root"]]["matrix_ue"])
		var body := _ue(components[props["Butterfly"]]["matrix_ue"])
		var parts: Array[Dictionary] = []
		for key in ["ButterflyBody","ButterflyWing_L","ButterflyWing_R"]:
			var node := _mesh(props[key])
			if node == null:
				continue
			if key != "ButterflyBody":
				var offsets: Array = props.get("WingsType", [])
				var variant := int(props.get("SetButteflyVariation", 0))
				if variant < offsets.size():
					for surface in node.mesh.get_surface_count():
						var source_material := node.get_active_material(surface)
						if source_material is StandardMaterial3D:
							var wing_material: StandardMaterial3D = source_material.duplicate()
							wing_material.uv1_offset = Vector3(float(offsets[variant].X),float(offsets[variant].Y),0)
							node.set_surface_override_material(surface,wing_material)
			var hinge := body
			if key != "ButterflyBody":
				var hinge_key := "ButterflyWing_Root_L" if key.ends_with("_L") else "ButterflyWing_Root_R"
				hinge = _ue(components[props[hinge_key]]["matrix_ue"])
			parts.append({"node":node,"key":key,"hinge":body.affine_inverse()*hinge,"relative":hinge.affine_inverse()*node.global_transform})
		var paths: Array = props["ButterflyPathAnimations"]
		var choice := clampi(int(props.get("PathAnimationVariation",0)),0,paths.size()-1)
		var clip: String = str(paths[choice]).get_slice(".",1)
		if parts.size() != 3 or not _data.paths.has(clip):
			coverage.missing.append(actor["name"]+": butterfly binding")
			continue
		_butterflies.append({"driver":driver,"root":driver.affine_inverse()*root,"body":root.affine_inverse()*body,"parts":parts,"path":_data.paths[clip],"rate":lerpf(0.35,2.5,float(props.get("PathAnimationSpeed",0.0)))})
		coverage.butterflies += 1

func _path_pose(path: Dictionary, time: float) -> Transform3D:
	var samples: Array = path.samples
	var frame := fposmod(time*float(path.fps),float(samples.size()))
	var a: Dictionary = samples[int(frame)]
	var b: Dictionary = samples[(int(frame)+1)%samples.size()]
	var q1 := Quaternion(a.q[0],a.q[1],a.q[2],a.q[3]).normalized()
	var q2 := Quaternion(b.q[0],b.q[1],b.q[2],b.q[3]).normalized()
	var t1 := Vector3(a.t[0],a.t[1],a.t[2])
	var t2 := Vector3(b.t[0],b.t[1],b.t[2])
	return Transform3D(Basis(q1.slerp(q2,frame-floorf(frame))),t1.lerp(t2,frame-floorf(frame)))

func _setup_birds() -> void:
	if _map.get("birds",[]).is_empty():
		return
	var path := "res://assets/animation/birds/source-manifest.json"
	if not FileAccess.file_exists(path):
		coverage.missing.append("bird sprite data")
		return
	_bird_manifest = JSON.parse_string(FileAccess.get_file_as_string(path))
	var frames: SpriteFrames = load("res://assets/animation/birds/original_birds.tres")
	if frames == null:
		coverage.missing.append("bird sprite texture import")
		return
	for actor in _map.get("birds",[]):
		var props: Dictionary = actor["properties"]
		var components: Dictionary = {}
		for component in actor["components"]:
			components[component["name"]] = component
		var sprite_source: Dictionary = components[props["Sprite"]]
		var sprite := AnimatedSprite3D.new()
		sprite.sprite_frames = frames
		sprite.pixel_size = 0.01
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sprite.shaded = true
		sprite.double_sided = true
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		sprite.alpha_scissor_threshold = 0.3333
		sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		add_child(sprite)
		var source_transform := _ue(_data.get("bird_components",{}).get(sprite_source["name"],sprite_source["matrix_ue"]))
		# JHPaperFlipbook NPC faces the camera in native C++; point sampling restores foot contact.
		var support_query := PhysicsRayQueryParameters3D.create(source_transform.origin+Vector3.UP*0.15,source_transform.origin-Vector3.UP*3.0,4)
		var support := get_world_3d().direct_space_state.intersect_ray(support_query)
		if not support.is_empty():
			source_transform.origin.y = float(support.position.y)+0.012
		sprite.set_meta("source_actor_transform",_ue(sprite_source["matrix_ue"]))
		sprite.set_meta("foot_contact_adaptation",not support.is_empty())
		sprite.global_transform = source_transform
		var flipbook: String = sprite_source["properties"].get("SourceFlipbook","")
		var direction := "right" if flipbook.ends_with("_R") else "left"
		sprite.play("idle_"+direction)
		_seek_sprite(sprite,float(sprite_source["properties"].get("AccumulatedTime",0.0)))
		var bird := {"node":sprite,"rest":source_transform,"box":_ue(components[props["Box"]]["matrix_ue"]),"delta":Vector3(float(props.get("可调的值",0)),float(props.get("飞行高度",1000)),float(props.get("左边（-往左）",-1000)))*0.01,"direction":direction,"elapsed":-1.0,"finished":false}
		_birds.append(bird)
		_update_bird_pivot(sprite)
		coverage.birds += 1

func _seek_sprite(sprite: AnimatedSprite3D, time: float) -> void:
	var frames := sprite.sprite_frames
	var count := frames.get_frame_count(sprite.animation)
	var speed := frames.get_animation_speed(sprite.animation)
	var duration := 0.0
	for i in count:
		duration += frames.get_frame_duration(sprite.animation,i)/speed
	var remaining := fposmod(time,maxf(duration,0.000001))
	for i in count:
		var span := frames.get_frame_duration(sprite.animation,i)/speed
		if remaining < span:
			sprite.set_frame_and_progress(i,remaining/span)
			return
		remaining -= span

func _update_bird_pivot(sprite: AnimatedSprite3D) -> void:
	for animation in _bird_manifest.get("animations",[]):
		if animation.name != str(sprite.animation):
			continue
		var key: String = animation.frames[mini(sprite.frame,animation.frames.size()-1)].sprite
		var item: Dictionary = _bird_manifest.sprites[key]
		sprite.offset = Vector2(float(item.region[2])*0.5-float(item.pivot[0]),float(item.pivot[1])-float(item.region[3])*0.5)
		sprite.pixel_size = 0.01/float(item.pixels_per_unreal_unit)
		return

func _curve(suffix: String, time: float) -> float:
	for key in _config.get("curves",{}):
		if str(key).ends_with(suffix):
			return _rich_curve(_config.curves[key],time)
	return 0.0

func _rich_curve(keys: Array,time: float) -> float:
	if keys.is_empty():
		return 0.0
	for i in range(keys.size()-1):
		var a: Dictionary=keys[i]
		var b: Dictionary=keys[i+1]
		if time>float(b.Time):
			continue
		var span:=maxf(float(b.Time)-float(a.Time),0.000001)
		var u:=clampf((time-float(a.Time))/span,0,1)
		if a.get("InterpMode")=="RCIM_Constant":
			return float(a.Value)
		if a.get("InterpMode")=="RCIM_Linear":
			return lerpf(float(a.Value),float(b.Value),u)
		return (2*u*u*u-3*u*u+1)*float(a.Value)+(u*u*u-2*u*u+u)*float(a.get("LeaveTangent",0))*span+(-2*u*u*u+3*u*u)*float(b.Value)+(u*u*u-u*u)*float(b.get("ArriveTangent",0))*span
	return float(keys.back().Value)

func _process(delta: float) -> void:
	_time += delta
	var body_curve:=_curve("BP_Butterfly_C.CurveFloat_0",fposmod(_time,1.0))
	var wing_curve:=_curve("BP_Butterfly_C.CurveFloat_1",fposmod(_time,1.0))
	for butterfly in _butterflies:
		var pose:=_path_pose(butterfly.path,_time*float(butterfly.rate))
		var body: Transform3D=butterfly.body
		body.origin=Vector3(0,lerpf(-0.05,0.05,body_curve),0)
		var moving: Transform3D=butterfly.driver*pose*butterfly.root*body
		for part in butterfly.parts:
			var hinge: Transform3D=part.hinge
			if part.key!="ButterflyBody":
				var angle:=lerpf(60.0,-60.0,wing_curve) if part.key=="ButterflyWing_L" else lerpf(-60.0,60.0,wing_curve)
				hinge.basis=Basis(Vector3.BACK,deg_to_rad(angle)) # UE +Pitch converts to Godot +Z rotation.
			part.node.global_transform=moving*hinge*part.relative
	for item in _big_boats:
		var source: Dictionary=item.source
		var phase:=fposmod(maxf(0,_time-float(source.Time)),(5.0+float(source.Time))*2.0)
		var second:=phase>=5.0+float(source.Time)
		var local_time:=phase-(5.0+float(source.Time) if second else 0.0)
		var suffix:="BP_DaChuan_C.CurveFloat_0_1" if second else "BP_DaChuan_C.CurveFloat_0"
		var u:=_curve(suffix,minf(local_time,5.0))
		var angle:=lerpf(-float(source.Rotation),float(source.Rotation),u) if second else lerpf(float(source.Rotation),-float(source.Rotation),u)
		var lift:=lerpf(float(source.Location_Y),0.0,u) if second else lerpf(0.0,float(source.Location_Y),u)
		var local:=Transform3D(Basis(Vector3.RIGHT,deg_to_rad(angle)),Vector3.UP*lift*0.01) # UE MakeRotator first argument is Roll.
		item.node.global_transform=item.rest*local
	for bird in _birds:
		if bird.finished:
			continue
		var sprite: AnimatedSprite3D=bird.node
		if float(bird.elapsed)<0:
			if is_instance_valid(_player):
				var near: Vector3=bird.box.affine_inverse()*(_player.global_position+Vector3.UP*0.96)
				if absf(near.x)<=0.32 and absf(near.y)<=0.32 and absf(near.z)<=0.32:
					bird.elapsed=0.0
					sprite.play("run_"+str(bird.direction))
		else:
			bird.elapsed=float(bird.elapsed)+delta
			var u:=_curve("BP_SceneNPC_Bird_C.CurveFloat_0",float(bird.elapsed))
			sprite.global_position=bird.rest.origin+bird.delta*u
			if float(bird.elapsed)>=2.0:
				sprite.visible=false
				bird.finished=true
		_update_bird_pivot(sprite)
