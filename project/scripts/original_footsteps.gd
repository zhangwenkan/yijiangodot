extends Node
## Original sound payloads and source PhysMaterials; native switch is approximated.

const FOLDER := "res://assets/characters/original_hero/footsteps/"
var manifest: Dictionary
var streams: Dictionary = {}
var used_bags: Dictionary = {}
var elapsed := 0.0
var voices: Array[AudioStreamPlayer] = []
var voice_index := 0
var weights: Array[Image] = []
var terrain: Dictionary = {}
var play_count := 0
var last_group := ""

func _ready() -> void:
	manifest = JSON.parse_string(FileAccess.get_file_as_string(FOLDER + "manifest.json"))
	for group in manifest.cue_groups:
		streams[group] = []
		used_bags[group] = []
		for wave in manifest.cue_groups[group].waves:
			var audio := AudioStreamOggVorbis.load_from_file(FOLDER + wave.file)
			if audio != null:
				streams[group].append(audio)
	for i in 3:
		var voice := AudioStreamPlayer.new()
		add_child(voice)
		voices.append(voice)

func select_map(slug: String) -> void:
	terrain = manifest.landscapes.get(slug, {})
	weights.clear()
	for filename in ["atlas-weights-1-4.png", "atlas-weights-5-8.png"]:
		var texture: Texture2D = load("res://assets/%s/landscape/%s" % [slug, filename])
		weights.append(texture.get_image())
	elapsed = 0

func update_motion(delta: float, moved: float, support: Dictionary, feet: Vector3) -> void:
	if moved < 0.0008 or support.is_empty():
		elapsed = 0
		return
	elapsed += delta
	if elapsed < float(manifest.interval):
		return
	elapsed = fmod(elapsed, float(manifest.interval))
	var physical_material := ""
	var collider: Node = support.get("collider")
	if is_instance_valid(collider):
		physical_material = manifest.meshes.get(str(collider.get_meta("source_mesh", "")), "")
		if int(collider.get_meta("source_component", 0)) == -1:
			physical_material = _landscape_material(feet)
	var group := "Dirt"
	if physical_material in ["PM_Wood", "PM_WoodBridge"]:
		group = "Wood"
	elif physical_material == "PM_Grass":
		group = "Grass"
	if streams[group].is_empty():
		return
	if used_bags[group].is_empty():
		for i in streams[group].size():
			used_bags[group].append(i)
		used_bags[group].shuffle()
	var index: int = used_bags[group].pop_back()
	var voice := voices[voice_index]
	voice_index = (voice_index + 1) % voices.size()
	voice.stream = streams[group][index]
	voice.volume_db = linear_to_db(float(manifest.sound_class_volume) * float(manifest.cue_groups[group].volume))
	voice.play()
	last_group = group
	play_count += 1

func _landscape_material(feet: Vector3) -> String:
	if terrain.is_empty() or weights.size() != 2:
		return ""
	var origin: Array = terrain.minimum_xy_ue_cm
	var step: Array = terrain.grid_step_xy_ue_cm
	var x := int(round((feet.x * 100.0 - float(origin[0])) / float(step[0])))
	var y := int(round((feet.z * 100.0 - float(origin[1])) / float(step[1])))
	var strongest := -1.0
	var layer_index := 0
	for atlas_index in 2:
		var texture := weights[atlas_index]
		if texture == null or texture.is_empty():
			continue
		var pixel := texture.get_pixel(clampi(x, 0, texture.get_width() - 1), clampi(y, 0, texture.get_height() - 1))
		for channel in 4:
			if pixel[channel] > strongest:
				strongest = pixel[channel]
				layer_index = atlas_index * 4 + channel
	return str(terrain.layers[layer_index]) if layer_index < terrain.layers.size() else ""
