extends Node3D
## Source-visible sprites; recovered animal controller supplies authored scene AI.

const FOLDER := "res://assets/ambient-sprites/"
var manifest: Dictionary
var frames: SpriteFrames
var textures: Dictionary = {}
var sprites: Array[Dictionary] = []
var report: Dictionary = {}

func setup(slug: String, _world: Node3D) -> Dictionary:
	if not FileAccess.file_exists(FOLDER + "manifest.json"):
		return {"objects": 0, "pending": true}
	manifest = JSON.parse_string(FileAccess.get_file_as_string(FOLDER + "manifest.json"))
	if FileAccess.file_exists("res://assets/source-animals/manifest.json"):
		var animals: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/source-animals/manifest.json"))
		manifest.flipbooks.merge(animals.flipbooks, true)
		manifest.sprites.merge(animals.sprites, true)
		manifest.maps[slug].append_array(animals.get("maps",{}).get(slug, []))
	if FileAccess.file_exists("res://assets/source-npcs/manifest.json"):
		var humans: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/source-npcs/manifest.json"))
		manifest.flipbooks.merge(humans.flipbooks, true)
		manifest.sprites.merge(humans.sprites, true)
		manifest.maps[slug].append_array(humans.maps.get(slug, []))
	frames = SpriteFrames.new()
	frames.remove_animation("default")
	for ref in manifest.flipbooks:
		var definition: Dictionary = manifest.flipbooks[ref]
		frames.add_animation(ref)
		frames.set_animation_speed(ref, float(definition.fps))
		frames.set_animation_loop(ref, true)
		for frame in definition.frames:
			var source: Dictionary = manifest.sprites[frame.sprite]
			if not textures.has(source.texture_file):
				var path := str(source.get("texture_path", FOLDER + str(source.texture_file)))
				textures[source.texture_file] = load(path) if ResourceLoader.exists(path) else ImageTexture.create_from_image(Image.load_from_file(path))
			var texture := AtlasTexture.new()
			texture.atlas = textures[source.texture_file]
			var region: Array = source.region
			texture.region = Rect2(float(region[0]),float(region[1]),float(region[2]),float(region[3]))
			texture.filter_clip = true
			frames.add_frame(ref, texture, float(frame.duration))
	for definition in manifest.maps.get(slug, []):
		var holder := Node3D.new()
		holder.name = "SourceAmbient_%s_%s" % [slug, definition.component]
		holder.set_meta("source_map", definition.map)
		holder.set_meta("source_component", definition.component)
		holder.set_meta("source_name", definition.name)
		add_child(holder)
		var matrix: Array = definition.matrix_ue
		var origin := Vector3(float(matrix[0][3]),float(matrix[2][3]),float(matrix[1][3])) * 0.01
		var axis_x := Vector3(float(matrix[0][0]),float(matrix[2][0]),float(matrix[1][0]))
		var axis_y := Vector3(float(matrix[0][2]),float(matrix[2][2]),float(matrix[1][2]))
		var source_normal := Vector3(float(matrix[0][1]),float(matrix[2][1]),float(matrix[1][1]))
		if definition.is_npc:
			holder.position = origin
			holder.scale = Vector3(axis_x.length(), axis_y.length(), source_normal.length())
		else:
			holder.transform = Transform3D(Basis(axis_x,axis_y,axis_x.cross(axis_y).normalized()*source_normal.length()), origin)
		var sprite := AnimatedSprite3D.new()
		sprite.name = "OriginalPaperFlipbook"
		sprite.sprite_frames = frames
		sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y if definition.is_npc else BaseMaterial3D.BILLBOARD_DISABLED
		sprite.shaded = bool(definition.get("shaded",true))
		sprite.double_sided = true
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		sprite.alpha_scissor_threshold = 0.3333
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		var tint: Dictionary = definition.sprite_color.get("SpriteColor", {})
		if not tint.is_empty():
			sprite.modulate = Color(float(tint.get("R",1.0)),float(tint.get("G",1.0)),float(tint.get("B",1.0)),float(tint.get("A",1.0)))
		holder.add_child(sprite)
		sprite.play(definition.flipbook, float(definition.play_rate))
		var animation: Dictionary = manifest.flipbooks[definition.flipbook]
		var total := 0.0
		for frame in animation.frames:
			total += float(frame.duration)
		var tick := fmod(float(definition.time) * float(animation.fps), maxf(total, 1.0))
		for frame_index in animation.frames.size():
			var duration: float = animation.frames[frame_index].duration
			if tick < duration:
				sprite.set_frame_and_progress(frame_index, tick/duration)
				break
			tick -= duration
		if not definition.playing:
			sprite.pause()
		# Fish and airborne seagulls retain their authored elevation. Native
		# aquatic/flying movement cannot be replaced by a ground snap.
		var airborne_or_aquatic := bool(definition.get("aquatic",false)) or str(definition.flipbook).contains("/HaiOu/") or str(definition.flipbook).contains("/JinLi_") or str(definition.flipbook).contains("/Yu_")
		var entry := {"sprite":sprite,"holder":holder,"definition":definition,"needs_ground":definition.is_npc and not airborne_or_aquatic}
		sprites.append(entry)
		sprite.frame_changed.connect(_pivot.bind(sprite))
		sprite.animation_changed.connect(_pivot.bind(sprite))
		_pivot(sprite)
	report = {"map":slug,"objects":sprites.size(),"source_flipbooks":manifest.flipbooks.size(),"atlases":textures.size(),"npc_ai_restored":false}
	print("ORIGINAL_AMBIENT_SPRITES_READY ",JSON.stringify(report))
	return report

func _physics_process(_delta: float) -> void:
	for entry in sprites:
		if not entry.needs_ground:
			continue
		entry.needs_ground = false
		var holder: Node3D = entry.holder
		var origin := holder.global_position
		# Native SceneNPC capsules settle on the original support. Query only
		# around their authored elevation, preserving shore/underwater wildlife.
		var ray := PhysicsRayQueryParameters3D.create(origin+Vector3.UP*0.5,origin-Vector3.UP*2.0,4)
		var hit := get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty() and hit.normal.y > 0.4:
			holder.global_position.y = hit.position.y + 0.025

func _pivot(sprite: AnimatedSprite3D) -> void:
	if not manifest.flipbooks.has(str(sprite.animation)):
		return
	var animation: Dictionary = manifest.flipbooks[str(sprite.animation)]
	var source: Dictionary = manifest.sprites[animation.frames[sprite.frame].sprite]
	var unit := 0.01 / float(source.ppu)
	var region: Array = source.region
	var pivot: Array = source.pivot
	sprite.pixel_size = unit
	sprite.position = Vector3((float(region[2])*0.5-float(pivot[0]))*unit,(float(pivot[1])-float(region[3])*0.5)*unit,0)
