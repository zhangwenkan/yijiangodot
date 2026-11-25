extends Node
## Executes the recovered SoundCue graph over original exported wave recordings.
## Source positions, delays, concatenation, modulation, random weights and loops are kept.
## Listener placement and distance attenuation are explicit cross-engine adaptations.

const CONFIG_PATH := "res://assets/environment/original-audio.json"
var report := {"backgrounds": 0, "ambient_components": 0, "disabled_components": 0, "waves_available": 0, "missing": []}
var _config: Dictionary = {}
var _states: Array[Dictionary] = []
var _streams: Dictionary = {}
var _focus := Vector3.ZERO
var _random := RandomNumberGenerator.new()
var _listener: AudioListener3D
var _camera: Camera3D

func setup(slug: String, focus: Vector3, camera: Camera3D = null) -> Dictionary:
	_focus = focus
	_camera = camera
	_listener = AudioListener3D.new()
	add_child(_listener)
	_listener.position = focus
	_listener.make_current()
	_random.seed = 610 if slug == "wuming" else 600
	_config = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	var map: Dictionary = _config.get("maps", {}).get(slug, {})
	report.waves_available = _config.get("waves", {}).size()
	for reference in map.get("background", []):
		_start_source(reference, {"background": true, "name": "SourceBackgroundMusic"})
		report.backgrounds += 1
	for component in map.get("components", []):
		var properties: Dictionary = component.get("properties", {})
		if not properties.get("bAutoActivate", true):
			report.disabled_components += 1
			continue
		_start_source(str(properties.get("Sound", "")), component)
		report.ambient_components += 1
	print("ORIGINAL_AUDIO_BOUND ", slug, " ", JSON.stringify(report))
	return report

func update_focus(position: Vector3) -> void:
	_focus = position
	if is_instance_valid(_listener):
		_listener.global_position = position
		if is_instance_valid(_camera):
			_listener.global_basis = _camera.global_basis

func shutdown() -> void:
	set_process(false)
	for state in _states:
		if is_instance_valid(state.player):
			state.player.stop()
			state.player.stream = null
	_states.clear()
	_streams.clear()

func _exit_tree() -> void:
	shutdown()

func _start_source(reference: String, component: Dictionary) -> void:
	var p: Dictionary = component.get("properties", {})
	var use_spatial := not bool(component.get("background", false)) and bool(p.get("AttenuationOverrides", {}).get("bSpatialize", true))
	var player = AudioStreamPlayer3D.new() if use_spatial else AudioStreamPlayer.new()
	player.name = "SourceAudio_" + str(_states.size())
	add_child(player)
	var state := {"player": player, "queue": [], "waiting": 0.0, "current": false, "looping": false,
		"volume": 1.0, "pitch": 1.0, "position": Vector3.ZERO, "background": component.get("background", false),
		"attenuation": p.get("AttenuationOverrides", {}), "component_volume": float(p.get("VolumeMultiplier", 1.0)),
		"spatialize": true, "finished": false, "reference": reference, "component": component, "random_used": {}}
	if component.has("matrix_ue"):
		var m: Array = component.matrix_ue
		state.position = Vector3(m[0][3], m[2][3], m[1][3]) * 0.01
	if use_spatial:
		player.position = state.position
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		player.max_distance = 0.0
		player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		player.max_db = 12.0
	if _config.cues.has(reference):
		var cue: Dictionary = _config.cues[reference]
		state.cue = cue
		var root: Dictionary = cue.nodes[str(int(cue.root))]
		var cp: Dictionary = root.properties
		if not p.get("bOverrideAttenuation", false):
			var attenuation_ref: String = str(cp.get("AttenuationSettings", {}).get("object", ""))
			state.attenuation = _config.attenuations.get(attenuation_ref, {}).get("Attenuation", {})
		state.queue.append({"node": int(cp.FirstNode.index), "volume": float(cp.get("VolumeMultiplier", 1.0)) * float(cue.get("class_volume", 1.0)), "pitch": 1.0})
	elif _config.waves.has(reference):
		state.queue.append({"wave": reference, "volume": 1.0, "pitch": 1.0, "loop": bool(_config.waves[reference].properties.get("bLooping", false))})
	else:
		report.missing.append(reference)
		player.queue_free()
		return
	_states.append(state)
	_advance(state)

func _process(delta: float) -> void:
	for state in _states:
		var player = state.player
		if state.finished:
			continue
		if state.waiting > 0.0:
			state.waiting -= delta
		elif state.current:
			if not player.playing and not state.looping:
				state.current = false
				_advance(state)
		else:
			_advance(state)
		var gain := _attenuation_gain(state) * float(state.volume) * float(state.component_volume)
		player.volume_db = linear_to_db(maxf(0.00001, gain))

func _attenuation_gain(state: Dictionary) -> float:
	if state.background:
		return 1.0
	var p: Dictionary = state.attenuation
	if p.get("bAttenuate", true) == false:
		return 1.0
	var shape: Dictionary = p.get("AttenuationShapeExtents", {})
	shape = shape.get("AttenuationShapeExtents", shape)
	var inner := float(shape.get("X", 400.0)) * 0.01
	var falloff := maxf(0.01, float(p.get("FalloffDistance", 3600.0)) * 0.01)
	return clampf(1.0 - maxf(0.0, _focus.distance_to(state.position) - inner) / falloff, 0.0, 1.0)

func _advance(state: Dictionary) -> void:
	var operations := 0
	while not state.queue.is_empty() and operations < 64:
		operations += 1
		var item: Dictionary = state.queue.pop_front()
		if item.has("wave"):
			_play_wave(state, item)
			return
		var node: Dictionary = state.cue.nodes.get(str(int(item.node)), {})
		var p: Dictionary = node.get("properties", {})
		var kind: String = str(node.get("class", "")).get_slice(".", 1)
		var children: Array = p.get("ChildNodes", [])
		match kind:
			"SoundNodeWavePlayer":
				var wave: String = str(p.get("SoundWaveAssetPtr", {}).get("AssetPath", {}).get("AssetName", ""))
				_play_wave(state, {"wave": wave, "volume": item.volume, "pitch": item.pitch, "loop": bool(p.get("bLooping", false))})
				return
			"SoundNodeDelay":
				_push_children(state, children, item)
				state.waiting = _random.randf_range(float(p.get("DelayMin", 0.0)), float(p.get("DelayMax", 0.0)))
				return
			"SoundNodeLooping":
				state.queue.push_front(item.duplicate())
				_push_children(state, children, item)
			"SoundNodeModulator":
				item.volume *= _random.randf_range(float(p.get("VolumeMin", 0.95)), float(p.get("VolumeMax", 1.05)))
				item.pitch *= _random.randf_range(float(p.get("PitchMin", 0.95)), float(p.get("PitchMax", 1.05)))
				_push_children(state, children, item)
			"SoundNodeRandom":
				if children.is_empty():
					continue
				var weights: Array = p.get("Weights", [])
				var random_key := str(int(item.node))
				var used: Array = state.random_used.get(random_key, [])
				var without_replacement := bool(p.get("bRandomizeWithoutReplacement", true))
				if used.size() >= children.size() or not without_replacement:
					used.clear()
				var total := 0.0
				for i in children.size():
					if not used.has(i):
						total += float(weights[i]) if i < weights.size() else 1.0
				var choice := _random.randf() * total
				var selected := children.size() - 1
				for i in children.size():
					if used.has(i):
						continue
					choice -= float(weights[i]) if i < weights.size() else 1.0
					if choice <= 0.0:
						selected = i
						break
				used.append(selected)
				state.random_used[random_key] = used
				_push_children(state, [children[selected]], item)
			"SoundNodeConcatenator":
				_push_children(state, children, item, p.get("InputVolume", []))
			_:
				_push_children(state, children, item)
	if state.queue.is_empty():
		state.finished = true

func _push_children(state: Dictionary, children: Array, item: Dictionary, volumes: Array = []) -> void:
	for i in range(children.size() - 1, -1, -1):
		state.queue.push_front({"node": int(children[i].index), "volume": float(item.volume) * (float(volumes[i]) if i < volumes.size() else 1.0), "pitch": float(item.pitch)})

func _play_wave(state: Dictionary, item: Dictionary) -> void:
	var reference: String = str(item.wave)
	var wave: Dictionary = _config.waves.get(reference, {})
	if wave.is_empty():
		report.missing.append(reference)
		return
	var key := reference + (":loop" if item.get("loop", false) else ":once")
	if not _streams.has(key):
		var stream := AudioStreamOggVorbis.load_from_file(str(wave.path))
		if stream == null:
			report.missing.append(str(wave.path))
			return
		stream.loop = bool(item.get("loop", false))
		_streams[key] = stream
	var player = state.player
	player.stream = _streams[key]
	player.pitch_scale = float(item.pitch)
	state.pitch = float(item.pitch)
	state.volume = float(item.volume) * float(wave.get("class_volume", 1.0))
	state.looping = bool(item.get("loop", false))
	state.current = true
	player.volume_db = linear_to_db(maxf(0.00001, _attenuation_gain(state) * float(state.volume) * float(state.component_volume)))
	player.play()
