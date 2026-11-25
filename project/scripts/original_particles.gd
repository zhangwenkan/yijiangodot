extends Node3D
## Animation adapter for recovered Cascade modules. Geometry is imported from Blender MCP.
## Source positions, textures and distributions are retained; this is not the native UE renderer.

const CONFIG := "res://assets/environment/original-particles.json"
const DRAW := "res://assets/environment/particles/particle-draw.glb"
const SPRITE_SHADER := preload("res://shaders/original_particle_sprite.gdshader")
const SPLASH_SHADER := preload("res://shaders/original_particle_splash.gdshader")
const SPLASH_MATERIAL := "/Game/JH/MapEditor/Environment/Ocean/Materials/M_水花.M_水花"
const SMOKE_SHADER := preload("res://shaders/original_particle_smoke.gdshader")
const SMOKE_MATERIAL := "/Game/JH/Particles/Fire/Materials/1_6_smoke2_vg2_Inst.1_6_smoke2_vg2_Inst"

class Particle:
	var age := 0.0
	var life := 1.0
	var pos := Vector3.ZERO # Original UE axes, centimetres, relative to emitter.
	var velocity := Vector3.ZERO
	var current_velocity := Vector3.ZERO
	var acceleration := Vector3.ZERO
	var size := Vector3.ONE
	var color := Vector3.ONE
	var alpha := 1.0
	var rotation := 0.0
	var rotation_rate := 0.0
	var mesh_rotation := Vector3.ZERO
	var mesh_rotation_rate := Vector3.ZERO
	var orbit_offset := Vector3.ZERO
	var orbit_rotation := Vector3.ZERO
	var orbit_rate := Vector3.ZERO
	var random := Vector3.ZERO
	var frame_offset := 0.0
	var previous_render_pos := Vector3.ZERO # Source UE cm, including previous Orbit offset.
	var previous_world := Vector3.ZERO
	var collision_time := 0.0
	var drag := 0.0
	var dynamic_parameters := Vector4.ONE

class Emitter:
	var data: Dictionary
	var modules: Dictionary = {}
	var particles: Array[Particle] = []
	var draw: MultiMeshInstance3D
	var multi: MultiMesh
	var transform := Transform3D.IDENTITY
	var source_group := ""
	var source_emitter := ""
	var time := 0.0
	var remainder := 0.0
	var capacity := 32
	var mesh := false
	var square := true
	var velocity_align := false
	var source_alignment := 0 # 0 screen, 1 velocity, 2 EPAL_ROTATE_Z.
	var source_axis := Vector3.UP
	var direction_image: Image
	var direction_texture: ImageTexture
	var frame_random := false
	var frames := 1
	var frame_movie := false
	var collision := false
	var splash := false
	var smoke := false
	var dynamic_image: Image
	var dynamic_texture: ImageTexture
	var source_dynamic_parameters: Array[Dictionary] = []

var coverage: Dictionary = {}
var _emitters: Array[Emitter] = []
var _textures: Dictionary = {}
var _generated: Node3D
var _world: Node3D
var _rng := RandomNumberGenerator.new()
var _sprite_mesh: Mesh
var _leaf_mesh: Mesh
var _config: Dictionary
var _time_accumulator := 0.0
var _emitter_lookup: Dictionary = {}

func setup(slug: String, world: Node3D) -> Dictionary:
	shutdown()
	_world = world
	_rng.seed = 60261023
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	if not parsed is Dictionary:
		push_error("Original particle source data is missing.")
		return {}
	_config = parsed
	coverage = _config.get("coverage", {}).duplicate(true)
	coverage["bound_components"] = 0
	coverage["bound_emitters"] = 0
	coverage["capacity"] = 0
	coverage["active_particles"] = 0
	coverage["unhandled_modules"] = []
	coverage["splash_material_emitters"] = 0
	coverage["splash_dynamic_evaluated_emitters"] = 0
	coverage["smoke_dynamic_evaluated_emitters"] = 0
	coverage["smoke_dynamic_upload_bytes_per_step"] = 0
	coverage["dynamic_unhandled_emitters"] = []
	coverage["splash_distortion_pass"] = "not_restored; source formula recovered, main pass only"
	if not _load_meshes():
		return coverage
	_generated = Node3D.new()
	_generated.name = "OriginalCascadeParticles_" + slug
	world.add_child(_generated)
	for component in _config.get("maps", {}).get(slug, []):
		if not component.get("active", true):
			continue
		coverage["bound_components"] += 1
		for source in component["emitters"]:
			if not source.get("active", true):
				continue
			var emitter := _create_emitter(component, source)
			_emitters.append(emitter)
			_emitter_lookup[emitter.source_group + "|" + str(source["name"])] = emitter
			coverage["bound_emitters"] += 1
			coverage["capacity"] += emitter.capacity
	# Only P_Steam_Lit has an explicitly serialized warmup (7 sec).
	for emitter in _emitters:
		var warmup := float(emitter.data.get("warmup", 0.0))
		for step in range(int(ceil(warmup * 30.0))):
			_simulate(emitter, 1.0 / 30.0)
		_draw(emitter)
	_time_accumulator = 0.0
	set_process(true)
	print("Original particle adapter ", slug, ": ", JSON.stringify(coverage))
	return coverage

func shutdown() -> void:
	set_process(false)
	_emitters.clear()
	_emitter_lookup.clear()
	_textures.clear()
	if is_instance_valid(_generated):
		_generated.queue_free()
	_generated = null

func _load_meshes() -> bool:
	var packed: PackedScene = load(DRAW)
	if packed == null:
		push_error("Import Blender particle-draw.glb before starting particle adapter.")
		return false
	var root := packed.instantiate()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if str(node.name).begins_with("SourceParticleSpriteDraw"):
			_sprite_mesh = node.mesh
		elif str(node.name).begins_with("SourceParticleLeafDraw"):
			_leaf_mesh = node.mesh
	root.free()
	return _sprite_mesh != null and _leaf_mesh != null

func _ue_transform(m: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(m[0][0], m[2][0], m[1][0]), Vector3(m[0][2], m[2][2], m[1][2]), Vector3(m[0][1], m[2][1], m[1][1])), Vector3(m[0][3], m[2][3], m[1][3]) * 0.01)

func _v(value, fallback := Vector3.ZERO) -> Vector3:
	if value is Dictionary:
		return Vector3(float(value.get("X", fallback.x)), float(value.get("Y", fallback.y)), float(value.get("Z", fallback.z)))
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback

func _gd(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, v.y)

func _world_acceleration(e: Emitter, module: Dictionary, value: Vector3) -> Vector3:
	if module.get("bAlwaysInWorldSpace", false):
		return _gd(e.transform.basis.inverse() * _gd(value))
	return value

func _random() -> Vector3:
	return Vector3(_rng.randf(), _rng.randf(), _rng.randf())

func _sample(d: Dictionary, time: float, random: Vector3) -> Vector3:
	var dim := int(d.get("dim", 1))
	if d.has("points"):
		var points: Array = d["points"]
		if points.is_empty():
			return Vector3.ZERO
		var index := 0
		while index + 1 < points.size() and float(points[index + 1][0]) <= time:
			index += 1
		var a: Array = points[index]
		var av := _array_vector(a[1], dim)
		if index + 1 == points.size() or str(a[4]) == "CIM_Constant":
			return av
		var b: Array = points[index + 1]
		var duration := maxf(float(b[0]) - float(a[0]), 0.0001)
		var t := clampf((time - float(a[0])) / duration, 0.0, 1.0)
		var bv := _array_vector(b[1], dim)
		if str(a[4]) == "CIM_Linear":
			return av.lerp(bv, t)
		return av * (2.0*t*t*t-3.0*t*t+1.0) + _array_vector(a[3],dim)*duration*(t*t*t-2.0*t*t+t) + bv*(-2.0*t*t*t+3.0*t*t) + _array_vector(b[2],dim)*duration*(t*t*t-t*t)
	var values: Array = d.get("v", [0.0])
	var count := int(d.get("count", 1))
	var stride := int(d.get("stride", dim))
	var sub := int(d.get("sub", 0))
	var t := clampf((time - float(d.get("bias", 0.0))) * float(d.get("scale", 0.0)), 0.0, maxf(count - 1, 0))
	var i := int(t)
	var j := mini(i + 1, count - 1)
	var a := _table_vector(values, i*stride, dim).lerp(_table_vector(values, j*stride, dim), t-i)
	if int(d.get("op", 1)) == 2 and sub > 0:
		var b := _table_vector(values, i*stride+sub, dim).lerp(_table_vector(values, j*stride+sub, dim), t-i)
		a += (b - a) * random
	return a

func _array_vector(values: Array, dim: int) -> Vector3:
	return _table_vector(values, 0, dim)

func _table_vector(values: Array, start: int, dim: int) -> Vector3:
	if start >= values.size():
		return Vector3.ZERO
	var x := float(values[start])
	return Vector3(x, float(values[start+1]) if dim > 1 and start+1 < values.size() else x, float(values[start+2]) if dim > 2 and start+2 < values.size() else x)

func _value(module: Dictionary, key: String, time: float, random: Vector3, fallback := Vector3.ZERO) -> Vector3:
	var data = module.get(key)
	if data is Dictionary and (data.has("v") or data.has("points")):
		return _sample(data, time, random)
	return fallback

func _maximum(d: Dictionary, fallback := 1.0) -> float:
	var largest := -INF
	for x in d.get("v", []):
		largest = maxf(largest, float(x))
	for p in d.get("points", []):
		for x in p[1]:
			largest = maxf(largest, float(x))
	return largest if largest > -INF else fallback

func _create_emitter(component: Dictionary, source: Dictionary) -> Emitter:
	var e := Emitter.new()
	e.data = source.duplicate()
	e.data["warmup"] = component.get("warmup", 0.0)
	e.source_group = component["source"]
	e.transform = _ue_transform(component["matrix_ue"])
	e.mesh = source["mesh"]
	e.splash = not e.mesh and str(source["material"]) == SPLASH_MATERIAL
	e.smoke = not e.mesh and str(source["material"]) == SMOKE_MATERIAL and str(source["source"]) == "PS_HuoDui.ParticleSpriteEmitter_14"
	if e.splash or e.smoke:
		e.source_dynamic_parameters = _source_dynamic_parameters(source)
	if e.splash:
		coverage["splash_material_emitters"] += 1
		if e.source_dynamic_parameters.size() == 4:
			coverage["splash_dynamic_evaluated_emitters"] += 1
	if e.smoke and e.source_dynamic_parameters.size() == 4:
		coverage["smoke_dynamic_evaluated_emitters"] += 1
	var req: Dictionary = source["required"]
	var origin := _gd(_v(req.get("EmitterOrigin", {}))) * 0.01
	e.transform.origin += e.transform.basis * origin
	var rotation_data: Dictionary = req.get("EmitterRotation", {})
	if rotation_data.has("EmitterRotation"):
		rotation_data = rotation_data["EmitterRotation"]
	if not rotation_data.is_empty():
		var yaw := deg_to_rad(float(rotation_data.get("Yaw",0)))
		var pitch := deg_to_rad(float(rotation_data.get("Pitch",0)))
		var roll := deg_to_rad(float(rotation_data.get("Roll",0)))
		var ue_basis := Basis(Vector3(0,0,1),yaw) * Basis(Vector3(0,1,0),pitch) * Basis(Vector3(1,0,0),roll)
		e.transform.basis *= Basis(_gd(ue_basis.x),_gd(ue_basis.z),_gd(ue_basis.y))
	e.square = req.get("ScreenAlignment", "PSA_Square") == "PSA_Square"
	e.velocity_align = req.get("ScreenAlignment", "") == "PSA_Velocity"
	e.source_alignment = 1 if e.velocity_align else 0
	if bool(req.get("bUseLocalSpace", false)):
		e.source_axis = _ue_transform(component["matrix_ue"]).basis.y.normalized()
	if not e.velocity_align:
		for module in source["modules"]:
			if module["type"] == "OrientationAxisLock" and module.get("LockAxisFlags", "") == "EPAL_ROTATE_Z":
				e.source_alignment = 2
	e.frame_random = str(req.get("InterpolationMethod", "")).contains("Random")
	var material_data: Dictionary = _config["materials"][source["material"]]
	var atlas := Vector2(float(req.get("SubImages_Horizontal", material_data["atlas"][0])), float(req.get("SubImages_Vertical", material_data["atlas"][1])))
	e.frames = int(atlas.x * atlas.y)
	var maxlife := 0.0
	for m in source["modules"]:
		var type: String = m["type"]
		if not e.modules.has(type):
			e.modules[type] = []
		e.modules[type].append(m)
		if type.begins_with("Lifetime"):
			maxlife += _maximum(m.get("Lifetime", {}))
		if type == "LocationEmitter":
			e.source_emitter = m.get("EmitterName", "")
		if type == "SubUVMovie":
			e.frame_movie = true
		if type == "Collision":
			e.collision = true
		if type == "ParameterDynamic" and e.source_dynamic_parameters.size() != 4:
			if not coverage["unhandled_modules"].has(type):
				coverage["unhandled_modules"].append(type)
			coverage["dynamic_unhandled_emitters"].append({"component": e.source_group, "emitter": source["source"]})
	e.capacity = maxi(8, int(ceil(_maximum(source["rate"]) * _maximum(source["rate_scale"]) * maxlife)) + 8)
	if e.source_alignment == 1:
		e.direction_image = Image.create(e.capacity, 1, false, Image.FORMAT_RGBAF)
		e.direction_image.fill(Color(0.0, 0.0, 0.0, 0.0))
		e.direction_texture = ImageTexture.create_from_image(e.direction_image)
	if e.smoke:
		# One RGBAF data texel per particle, without changing the quad or custom slots.
		e.dynamic_image = Image.create(e.capacity, 1, false, Image.FORMAT_RGBAF)
		e.dynamic_image.fill(Color(0.0, 0.0, 0.0, 0.0))
		e.dynamic_texture = ImageTexture.create_from_image(e.dynamic_image)
		coverage["smoke_dynamic_upload_bytes_per_step"] += e.capacity * 16
	e.multi = MultiMesh.new()
	e.multi.transform_format = MultiMesh.TRANSFORM_3D
	e.multi.use_colors = true
	e.multi.use_custom_data = true
	e.multi.mesh = _leaf_mesh if e.mesh else _sprite_mesh
	e.multi.instance_count = e.capacity
	e.multi.visible_instance_count = 0
	e.draw = MultiMeshInstance3D.new()
	e.draw.name = "SourceParticle_" + str(_emitters.size())
	e.draw.multimesh = e.multi
	e.draw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.draw.custom_aabb = AABB(Vector3.ONE * -60, Vector3.ONE * 120)
	e.draw.position = e.transform.origin
	e.draw.set_meta("source_component", component["source"])
	e.draw.set_meta("source_emitter", source["source"])
	e.draw.material_override = _material(material_data, atlas, e)
	_generated.add_child(e.draw)
	for burst in source.get("bursts", []):
		if float(burst.get("Time", 0.0)) <= 0.0:
			for i in range(int(burst.get("Count", 0))):
				_spawn(e)
	return e

func _texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if not _textures.has(path):
		_textures[path] = load(path)
	return _textures[path]

func _material(source: Dictionary, atlas: Vector2, e: Emitter) -> ShaderMaterial:
	if e.splash:
		return _splash_material(e)
	if e.smoke:
		return _smoke_material(e, atlas)
	var material := ShaderMaterial.new()
	material.shader = SPRITE_SHADER
	if source.get("blend", "") == "BLEND_Additive":
		var shader := Shader.new()
		shader.code = SPRITE_SHADER.code.replace("blend_mix", "blend_add")
		material.shader = shader
	if e.mesh:
		var shader := Shader.new()
		shader.code = SPRITE_SHADER.code.replace("depth_draw_never", "depth_draw_opaque")
		material.shader = shader
	var texture := _texture(source.get("texture", ""))
	material.set_shader_parameter("source_texture", texture)
	material.set_shader_parameter("has_texture", texture != null)
	material.set_shader_parameter("radial", source.get("radial", false))
	material.set_shader_parameter("billboard", not e.mesh)
	material.set_shader_parameter("source_alignment", e.source_alignment)
	material.set_shader_parameter("source_lock_axis", e.source_axis)
	if e.direction_texture != null:
		material.set_shader_parameter("source_direction_data", e.direction_texture)
	material.set_shader_parameter("masked_leaf", e.mesh)
	material.set_shader_parameter("atlas", atlas)
	material.set_shader_parameter("frame_blend", not e.frame_random)
	material.set_shader_parameter("opacity_from_rgb", source.get("splash", false))
	material.set_shader_parameter("emission_strength", float(source.get("emission", 0.0)))
	material.set_shader_parameter("soft_distance", 0.12 if not e.mesh else 0.0)
	var normal := _texture(source.get("normal", ""))
	material.set_shader_parameter("has_normal", normal != null)
	material.set_shader_parameter("source_normal", normal)
	for m in e.modules.get("PivotOffset", []):
		var p: Dictionary = m.get("PivotOffset", {})
		material.set_shader_parameter("pivot", Vector2(float(p.get("X",0)),float(p.get("Y",0))))
	for m in e.modules.get("OrientationAxisLock", []):
		material.set_shader_parameter("lock_vertical", not e.velocity_align and m.get("LockAxisFlags", "") == "EPAL_ROTATE_Z")
	return material

func _spawn(e: Emitter) -> void:
	if e.particles.size() >= e.capacity:
		return
	var p := Particle.new()
	p.random = _random()
	p.life = 0.0
	for type in ["Lifetime", "Lifetime_Seeded"]:
		for m in e.modules.get(type, []):
			p.life += _value(m,"Lifetime",e.time,_random(),Vector3.ONE).x
	p.life = maxf(p.life, 0.02)
	for m in e.modules.get("Size", []):
		p.size = _value(m,"StartSize",e.time,_random(),Vector3.ONE)
	for m in e.modules.get("Location", []):
		p.pos += _value(m,"StartLocation",e.time,_random())
	for m in e.modules.get("LocationPrimitiveSphere", []):
		var direction := Vector3(_rng.randfn(),_rng.randfn(),_rng.randfn()).normalized()
		var radius := _value(m,"StartRadius",e.time,_random()).x
		p.pos += direction * radius * (1.0 if m.get("SurfaceOnly",false) else pow(_rng.randf(),1.0/3.0)) + _value(m,"StartLocation",e.time,_random())
	for m in e.modules.get("LocationPrimitiveCylinder", []):
		var angle := _rng.randf() * TAU
		var radius := _value(m,"StartRadius",e.time,_random()).x * sqrt(_rng.randf())
		var height := _value(m,"StartHeight",e.time,_random()).x
		p.pos += Vector3(cos(angle)*radius,sin(angle)*radius,_rng.randf_range(-0.5,0.5)*height) + _value(m,"StartLocation",e.time,_random())
	if not e.source_emitter.is_empty():
		var parent = _emitter_lookup.get(e.source_group + "|" + e.source_emitter)
		if parent is Emitter and not parent.particles.is_empty():
			p.pos += parent.particles[_rng.randi_range(0,parent.particles.size()-1)].pos
	for m in e.modules.get("Velocity", []):
		p.velocity += _value(m,"StartVelocity",e.time,_random()) + p.pos.normalized() * _value(m,"StartVelocityRadial",e.time,_random()).x
	for m in e.modules.get("Acceleration", []):
		p.acceleration += _world_acceleration(e,m,_value(m,"Acceleration",e.time,_random()))
	for m in e.modules.get("AccelerationConstant", []):
		p.acceleration += _world_acceleration(e,m,_v(m.get("Acceleration",{})))
	for m in e.modules.get("AccelerationDrag", []):
		p.drag += _value(m,"DragCoefficientRaw",e.time,_random()).x
	for m in e.modules.get("Color", []):
		p.color = _value(m,"StartColor",e.time,_random(),Vector3.ONE)
		p.alpha = _value(m,"StartAlpha",e.time,_random(),Vector3.ONE).x
	for m in e.modules.get("Rotation", []):
		p.rotation += _value(m,"StartRotation",e.time,_random()).x * TAU
	for m in e.modules.get("RotationRate", []):
		p.rotation_rate += _value(m,"StartRotationRate",e.time,_random()).x * TAU
	for m in e.modules.get("MeshRotation", []):
		p.mesh_rotation += _value(m,"StartRotation",e.time,_random()) * TAU
	for m in e.modules.get("MeshRotationRate", []):
		p.mesh_rotation_rate += _value(m,"StartRotationRate",e.time,_random()) * TAU
	for m in e.modules.get("Orbit", []):
		p.orbit_offset += _value(m,"OffsetAmount",e.time,_random())
		p.orbit_rotation += _value(m,"RotationAmount",e.time,_random()) * TAU
		p.orbit_rate += _value(m,"RotationRateAmount",e.time,_random()) * TAU
	if e.frame_random:
		p.frame_offset = float(_rng.randi_range(0,maxi(e.frames-1,0)))
	p.previous_render_pos = p.pos + _orbit(p)
	p.previous_world = e.transform * (_gd(p.pos) * 0.01)
	_update_source_dynamic(e, p, true)
	e.particles.append(p)

func _process(delta: float) -> void:
	_time_accumulator += minf(delta, 0.15)
	if _time_accumulator < 1.0 / 30.0:
		return
	var dt := _time_accumulator
	_time_accumulator = 0.0
	var total := 0
	for e in _emitters:
		_simulate(e, dt)
		_draw(e)
		total += e.particles.size()
	coverage["active_particles"] = total

func _simulate(e: Emitter, dt: float) -> void:
	e.time += dt
	if e.time < float(e.data["required"].get("EmitterDelay",0.0)):
		return
	e.remainder += maxf(0.0,_sample(e.data["rate"],e.time,_random()).x * _sample(e.data["rate_scale"],e.time,_random()).x) * dt
	var spawn := int(e.remainder)
	e.remainder -= spawn
	for i in range(spawn):
		_spawn(e)
	for i in range(e.particles.size()-1,-1,-1):
		var p := e.particles[i]
		p.age += dt
		if p.age >= p.life:
			e.particles.remove_at(i)
			continue
		var life := p.age / p.life
		p.previous_render_pos = p.pos + _orbit(p)
		var acceleration := p.acceleration
		for m in e.modules.get("AccelerationOverLifetime", []):
			acceleration += _world_acceleration(e,m,_value(m,"AccelOverLife",life,p.random))
		p.velocity = (p.velocity + acceleration*dt) * exp(-p.drag*dt)
		var velocity := p.velocity
		for m in e.modules.get("VelocityOverLifetime", []):
			var scale := _value(m,"VelOverLife",life,p.random,Vector3.ONE)
			velocity = scale if m.get("Absolute",false) else velocity * scale
		p.pos += velocity * dt
		p.current_velocity = velocity
		_update_source_dynamic(e, p, false)
		p.rotation += p.rotation_rate * dt
		p.mesh_rotation += p.mesh_rotation_rate * dt
		p.orbit_rotation += p.orbit_rate * dt
		if e.collision:
			p.collision_time += dt
			if p.collision_time >= 0.1:
				p.collision_time = 0.0
				var destination := e.transform * (_gd(p.pos + _orbit(p)) * 0.01)
				var query := PhysicsRayQueryParameters3D.create(p.previous_world,destination)
				query.collision_mask = 1
				var hit := _world.get_world_3d().direct_space_state.intersect_ray(query)
				p.previous_world = destination
				if not hit.is_empty():
					e.particles.remove_at(i)

func _orbit(p: Particle) -> Vector3:
	return Basis.from_euler(p.orbit_rotation) * p.orbit_offset

func _draw(e: Emitter) -> void:
	for i in range(e.particles.size()):
		var p := e.particles[i]
		var life := p.age / p.life
		var size := p.size
		var color := p.color
		var alpha := p.alpha
		var frame := p.frame_offset
		# Cascade's Scale/ScaleBySpeed reset from BaseSize; MultiplyLife multiplies
		# current size. Original module order therefore matters for the bonfire.
		for m in e.data["modules"]:
			match m["type"]:
				"SizeMultiplyLife":
					var factor := _value(m,"LifeMultiplier",life,p.random,Vector3.ONE)
					if m.get("MultiplyX",true): size.x *= factor.x
					if m.get("MultiplyY",true): size.y *= factor.y
					if m.get("MultiplyZ",true): size.z *= factor.z
				"SizeScale":
					size = p.size * _value(m,"SizeScale",life,p.random,Vector3.ONE)
				"SizeScaleBySpeed":
					var speed := p.current_velocity.length()
					var s: Dictionary = m.get("SpeedScale",{})
					var maximum: Dictionary = m.get("MaxScale",{})
					size = p.size * Vector3(clampf(speed*float(s.get("X",1)),1.0,float(maximum.get("X",1))),clampf(speed*float(s.get("Y",1)),1.0,float(maximum.get("Y",1))),1.0)
		for m in e.modules.get("ColorOverLife", []):
			color = _value(m,"ColorOverLife",life,p.random,Vector3.ONE)
			alpha = _value(m,"AlphaOverLife",life,p.random,Vector3.ONE).x
		for m in e.modules.get("ColorScaleOverLife", []):
			color *= _value(m,"ColorScaleOverLife",life,p.random,Vector3.ONE)
			alpha *= _value(m,"AlphaScaleOverLife",life,p.random,Vector3.ONE).x
		if not e.frame_random:
			for m in e.modules.get("SubUV", []):
				frame = _value(m,"SubImageIndex",life,p.random).x
			for m in e.modules.get("SubUVMovie", []):
				frame = fmod(p.age * _value(m,"FrameRate",life,p.random).x, float(e.frames))
			if e.frames > 1 and not e.modules.has("SubUV") and not e.frame_movie:
				frame = life * float(e.frames-1)
		var offset := e.transform.basis * (_gd(p.pos + _orbit(p)) * 0.01)
		var scale := e.transform.basis.get_scale().abs()
		var basis: Basis
		# The same Godot draw angle drives the material and distortion pass.
		# Source PSA_Velocity ignores particle spin; other sprites reverse Y.
		var angle := 0.0 if e.velocity_align else -p.rotation
		if e.mesh:
			# Mesh-particle StartSize is a dimensionless scale, unlike sprite size in cm.
			basis = e.transform.basis * Basis.from_euler(_gd(p.mesh_rotation)).scaled(_gd(size))
		else:
			if e.square or absf(size.y) < 0.0001:
				size.y = size.x
			basis = Basis.from_scale(Vector3(maxf(absf(size.x)*scale.x*0.01,0.00001),maxf(absf(size.y)*scale.y*0.01,0.00001),1.0))
			if e.source_alignment == 1:
				# Preserve world delta (including Orbit), in source cm. The vertex factory
				# derives its camera-dependent 3D basis every rendered frame.
				var source_delta := e.transform.basis * _gd(p.pos + _orbit(p) - p.previous_render_pos)
				e.direction_image.set_pixel(i, 0, Color(source_delta.x, source_delta.y, source_delta.z, 0.0))
		e.multi.set_instance_transform(i,Transform3D(basis,offset))
		e.multi.set_instance_color(i,Color(color.x,color.y,color.z,alpha))
		if e.smoke:
			var parameters := p.dynamic_parameters
			e.dynamic_image.set_pixel(i, 0, Color(parameters.x, parameters.y, parameters.z, parameters.w))
		if e.splash:
			# Source ParticleSpeed is in world cm/s. Swap UE axes, retain emitter scale.
			var speed_cm_s := (e.transform.basis * _gd(p.current_velocity)).length()
			e.multi.set_instance_custom_data(i,Color(angle,frame,p.dynamic_parameters.z,speed_cm_s))
		else:
			e.multi.set_instance_custom_data(i,Color(angle,frame,life,0.0))
	if e.direction_texture != null and not e.particles.is_empty():
		e.direction_texture.update(e.direction_image)
	if e.smoke and not e.particles.is_empty():
		e.dynamic_texture.update(e.dynamic_image)
	e.multi.visible_instance_count = e.particles.size()


func _source_dynamic_parameters(source: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# Only the two recovered UserSet/table module layouts are accepted here.
	var emitter_name := str(source.get("source", ""))
	var expected_flags := 14 if emitter_name == "PS_水花.ParticleSpriteEmitter_0" else 15
	if emitter_name not in ["PS_水花.ParticleSpriteEmitter_0", "PS_HuoDui.ParticleSpriteEmitter_14"]:
		return result
	for module in source.get("modules", []):
		if module.get("type", "") != "ParameterDynamic":
			continue
		var parameters: Array = module.get("DynamicParams", [])
		if parameters.size() != 4 or int(module.get("UpdateFlags", -1)) != expected_flags:
			return []
		for channel in range(4):
			var parameter: Dictionary = parameters[channel]
			if parameter.get("ValueMethod", "") != "EDPV_UserSet" or parameter.get("bScaleVelocityByParamValue", false):
				return []
			var value: Dictionary = parameter.get("ParamValue", {})
			var table: Dictionary = value.get("Table", {})
			if table.is_empty() or not int(table.get("Op", 0)) in [1, 2] or int(table.get("LockFlag", -1)) != 0:
				return []
			var count := int(table.get("EntryCount", 0))
			var stride := int(table.get("EntryStride", 0))
			var values: Array = table.get("Values", [])
			if count <= 0 or stride <= 0 or values.size() != count * stride:
				return []
			result.append({"spawn_only": parameter.get("bSpawnTimeOnly", false), "emitter_time": parameter.get("bUseEmitterTime", false), "distribution": {"v": values, "op": int(table["Op"]), "count": count, "stride": stride, "sub": int(table.get("SubEntryStride", 0)), "bias": float(table.get("TimeBias", 0.0)), "scale": float(table.get("TimeScale", 0.0)), "dim": 1}})
		return result
	return result

func _update_source_dynamic(e: Emitter, p: Particle, spawning: bool) -> void:
	if e.source_dynamic_parameters.size() != 4:
		return
	for channel in range(4):
		var parameter: Dictionary = e.source_dynamic_parameters[channel]
		if not spawning and parameter["spawn_only"]:
			continue
		var sample_time := e.time if parameter["emitter_time"] else p.age / p.life
		# Existing per-particle random value preserves all other adapter RNG draws.
		# This samples the original R range, but is not UE's native random sequence.
		p.dynamic_parameters[channel] = _sample(parameter["distribution"], sample_time, p.random).x

func _splash_material(e: Emitter) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SPLASH_SHADER
	var bindings := {"splash_color_a": "T_FallingWater_01", "splash_color_b": "T_FallingWater_02", "splash_normal_a": "T_FallingWater_01_N", "splash_normal_b": "T_FallingWater_02_N", "splash_noise": "T_TilingNoise03"}
	for parameter in bindings:
		material.set_shader_parameter(parameter, _texture("res://assets/environment/particles/" + str(bindings[parameter]) + "_native.dds"))
	for module in e.modules.get("PivotOffset", []):
		var value: Dictionary = module.get("PivotOffset", {})
		material.set_shader_parameter("pivot", Vector2(float(value.get("X", 0)), float(value.get("Y", 0))))
	material.set_meta("source_material", SPLASH_MATERIAL)
	material.set_meta("fidelity", "Recovered main-pass expressions and native BC mip chains; Godot lighting/sorting adapter; native distortion not restored")
	return material


func _smoke_material(e: Emitter, atlas: Vector2) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SMOKE_SHADER
	material.set_shader_parameter("source_smoke", _texture("res://assets/environment/particles/1_6_smoke2_vg2_native.dds"))
	material.set_shader_parameter("source_normal", _texture("res://assets/environment/particles/Circle_normal_native.dds"))
	material.set_shader_parameter("source_dynamic_parameters", e.dynamic_texture)
	material.set_shader_parameter("atlas", atlas)
	for module in e.modules.get("PivotOffset", []):
		var value: Dictionary = module.get("PivotOffset", {})
		material.set_shader_parameter("pivot", Vector2(float(value.get("X", 0)), float(value.get("Y", 0))))
	material.set_meta("source_material", SMOKE_MATERIAL)
	material.set_meta("fidelity", "Recovered BlackBody binary32 literals, RGB dynamic curves, original atlas and normal mip chains; Godot lighting/sorting adapter")
	return material

func _exit_tree() -> void:
	shutdown()
