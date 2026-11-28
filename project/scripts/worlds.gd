extends Node3D
## Playable source-map reconstruction. All visible geometry is imported from Blender.
## Original-engine launchers are the reference for the complete look and behaviour.

var slug := "wuming"
var world: Node3D
var camera: Camera3D
var environment_driver: Node3D
var player: CharacterBody3D
var collision_world: Node3D
var foreground_driver: Node
var audio_driver: Node
var house_driver: Node
var source_renderer: Node
var source_rendering := true
var source_distortion := true
var source_atmosphere := true
var loading := false
var inspection := false
var focus := Vector3.ZERO
var height := 4.0
var distance := 32.0
var information: Label
var coverage: Label
var status := ""
var foliage_instances := 0
var capture_path := ""
var capture_after := 5.0
var elapsed := 0.0
var captured := false
var view_index := 0
var positions: Array[Vector3] = []
var viewpoint_picker: OptionButton
var initial_focus := Vector3.ZERO
var material_policies: Dictionary = {}
var ready_elapsed := 0.0
var tour_path := ""
var tour: Dictionary = {}
var tour_samples: Array[Dictionary] = []
var tour_step := -1
var tour_clock := 0.0
var sample_clock := 0.0
var hide_ui := false
var lighting_review := false
var lighting_stage := -1
var motion_frames := ""
var frame_clock := 0.0
var recorded_frames := 0
var frame_pending := false
var tour_finished := false
var frame_times: Array[float] = []
var tour_snapshots: Dictionary = {}

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--map="):
			slug = argument.trim_prefix("--map=")
		elif argument.begins_with("--capture="):
			capture_path = argument.trim_prefix("--capture=")
		elif argument.begins_with("--capture-after="):
			capture_after = float(argument.trim_prefix("--capture-after="))
		elif argument.begins_with("--tour="):
			tour_path = argument.trim_prefix("--tour=")
		elif argument == "--hide-ui":
			hide_ui = true
		elif argument == "--inspect":
			inspection = true
		elif argument == "--lighting-review":
			lighting_review = true
		elif argument == "--source-rendering":
			source_rendering = true
		elif argument == "--legacy-lighting":
			source_rendering = false
		elif argument == "--source-distortion":
			source_distortion = true
		elif argument == "--source-atmosphere":
			source_atmosphere = true
		elif argument.begins_with("--motion-frames="):
			motion_frames = argument.trim_prefix("--motion-frames=")
	if tour_path != "":
		tour = JSON.parse_string(FileAccess.get_file_as_string(tour_path))
	if motion_frames != "":
		DirAccess.make_dir_recursive_absolute(motion_frames)
	_build_ui()
	if FileAccess.file_exists("res://assets/material-policy.json"):
		material_policies = JSON.parse_string(FileAccess.get_file_as_string("res://assets/material-policy.json"))
	await get_tree().process_frame
	await _load_world(slug)

func _load_world(map_name: String) -> void:
	if loading:
		return
	loading = true
	status = "正在载入原地图与碰撞…"
	slug = map_name
	if is_instance_valid(source_renderer):
		source_renderer.shutdown()
		source_renderer.queue_free()
		source_renderer = null
	if is_instance_valid(house_driver):
		house_driver.shutdown()
		house_driver.queue_free()
	for old_node in [player, collision_world, foreground_driver]:
		if is_instance_valid(old_node):
			old_node.queue_free()
	if is_instance_valid(world):
		world.queue_free()
	if is_instance_valid(environment_driver):
		environment_driver.queue_free()
	await get_tree().process_frame
	var path := "res://assets/%s/world.glb" % slug
	if not ResourceLoader.exists(path):
		status = "原地图资产还在导出，请先使用原引擎观景入口。"
		loading = false
		return
	world = load(path).instantiate()
	preload("res://scripts/source_metadata.gd").restore(world, path)
	world.set_meta("source_metadata_restored", true)
	add_child(world)
	_apply_source_render_policy(world)
	_apply_landscape_material()
	foliage_instances = 0
	_load_original_instances()
	preload("res://scripts/original_actor_initial_state.gd").apply_visuals(world, slug)
	if not is_instance_valid(camera):
		camera = preload("res://scripts/original_camera.gd").new()
		camera.name = "FixedSourceDirectionCamera"
		camera.keep_aspect = Camera3D.KEEP_WIDTH
		camera.fov = 40.0
		camera.near = 0.1
		camera.far = 1800.0
		camera.current = true
		add_child(camera)
	initial_focus = Vector3(-89.4105, 3.44927, 10.53873) if slug == "wuming" else Vector3(-61.85358, 3.68085, 28.81919)
	focus = initial_focus
	height = focus.y
	distance = 32.0
	positions = [initial_focus]
	var viewpoint_names := ["码头"]
	if slug == "wuming":
		positions.append_array([Vector3(-79.8,3.5,38.231), Vector3(-89.4105,3.45,0), Vector3(-48.95716,6.91981,138.11031), Vector3(-74.5,2.47325,143.0)])
		viewpoint_names.append_array(["村屋台阶", "港口栈道", "演武场", "渔船岸边"])
	else:
		positions.append_array([Vector3(-49.96,4.551,59.25), Vector3(-37.72,7.106,51.4), Vector3(-60.6,2.534,4.46)])
		viewpoint_names.append_array(["村中鸟院", "蝶园", "大船码头"])
	viewpoint_picker.clear()
	for viewpoint_name in viewpoint_names:
		viewpoint_picker.add_item(viewpoint_name)
	view_index = 0
	camera.reset_at(initial_focus)
	camera.inspection = inspection
	var env_path := "res://scripts/original_environment.gd"
	if ResourceLoader.exists(env_path):
		environment_driver = load(env_path).new()
		add_child(environment_driver)
		environment_driver.setup(slug, world, camera)
	else:
		_add_temporary_environment()
	collision_world = preload("res://scripts/original_collision.gd").new()
	add_child(collision_world)
	var collision_report: Dictionary = collision_world.setup(slug)
	player = preload("res://scripts/original_player.gd").new()
	add_child(player)
	player.configure(camera)
	player.input_enabled = not inspection
	await get_tree().physics_frame
	await get_tree().physics_frame
	var supported: bool = player.place_at_source_actor_position(initial_focus)
	camera.follow_target = player
	camera.configure_source_bounds(slug, player)
	camera.reset_at(player.get_camera_anchor())
	var wind_driver := preload("res://scripts/original_wind.gd").new()
	world.add_child(wind_driver)
	wind_driver.setup(world)
	var animation_driver := preload("res://scripts/original_animation.gd").new()
	world.add_child(animation_driver)
	animation_driver.setup(slug, world, player)
	var ambient_sprites := preload("res://scripts/original_ambient_sprites.gd").new()
	world.add_child(ambient_sprites)
	ambient_sprites.setup(slug, world)
	var animal_behavior := preload("res://scripts/source_animal_behavior.gd").new()
	world.add_child(animal_behavior)
	animal_behavior.setup(slug, ambient_sprites, player)
	var particle_driver := preload("res://scripts/original_particles.gd").new()
	world.add_child(particle_driver)
	particle_driver.setup(slug, world)
	var particle_materials := preload("res://scripts/original_particle_materials.gd").new()
	world.add_child(particle_materials)
	particle_materials.setup(particle_driver)
	var beam_driver := preload("res://scripts/original_torch_beam.gd").new()
	world.add_child(beam_driver)
	beam_driver.setup(slug, world)
	audio_driver = preload("res://scripts/original_audio.gd").new()
	world.add_child(audio_driver)
	audio_driver.setup(slug, player.get_camera_anchor(), camera)
	preload("res://scripts/original_backdrop_surface.gd").bind(world)
	var surface_driver := preload("res://scripts/original_surface.gd").new()
	world.add_child(surface_driver)
	surface_driver.setup(world)
	if slug == "wuming":
		var waterfall_driver := preload("res://source_waterfall_candidate/source_waterfall_adapter.gd").new()
		world.add_child(waterfall_driver)
		waterfall_driver.install(world)
		var bagua_driver := preload("res://source_bagua_candidate/source_bagua_adapter.gd").new()
		world.add_child(bagua_driver)
		bagua_driver.install(world)
	foreground_driver = preload("res://scripts/original_foreground.gd").new()
	add_child(foreground_driver)
	foreground_driver.setup(slug, world, camera, player)
	var lightfunction_driver := preload("res://scripts/original_lightfunctions.gd").new()
	world.add_child(lightfunction_driver)
	lightfunction_driver.setup(slug, world)
	house_driver = preload("res://scripts/original_house.gd").new()
	add_child(house_driver)
	house_driver.setup(slug, world, collision_world, player, camera, environment_driver)
	environment_driver.setup_source_scene_reflection()
	if source_rendering:
		source_renderer = preload("res://scripts/original_source_renderer.gd").new()
		add_child(source_renderer)
		source_renderer.setup(self, source_distortion, source_atmosphere)
	status = "原主角 · 原地形与阻挡 · 固定方向镜头" if supported else "起点支撑未找到，需检查碰撞"
	loading = false
	ready_elapsed = 0.0
	tour_clock = 0.0
	tour_step = -1
	tour_finished = false
	sample_clock = 0.0
	tour_samples.clear()
	frame_times.clear()
	tour_snapshots.clear()
	print("ORIGINAL_WORLD_READY ", slug, " foliage_instances=", foliage_instances)
	print("ORIGINAL_PLAY_READY ", slug, " supported=", supported, " feet=", player.global_position, " camera=", camera.global_position, " collision=", collision_report.bodies)

func _apply_landscape_material() -> void:
	var landscape_driver := preload("res://scripts/original_compiled_landscape.gd").new()
	world.add_child(landscape_driver)
	landscape_driver.setup(world, slug)

func _load_original_instances() -> void:
	var manifest_path := "res://assets/%s/instances.json" % slug
	var library_path := "res://assets/%s/foliage-library.glb" % slug
	if not FileAccess.file_exists(manifest_path) or not ResourceLoader.exists(library_path):
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	var library: Node3D = load(library_path).instantiate()
	preload("res://scripts/source_metadata.gd").restore(library, library_path)
	_apply_source_render_policy(library)
	var library_nodes: Dictionary = {}
	for node in library.find_children("*", "MeshInstance3D", true, false):
		library_nodes[node.name] = node
	var group_number := 0
	var chunk_size := 12.0
	var world_transform := world.global_transform
	var chunk_report := {"map":slug,"cell_size_m":chunk_size,"source_groups":0,"original_multimeshes":0,"chunks":0,"instances_before":0,"instances_after":0,"max_chunk_instances":0,"groups":[]}
	for group in data.get("groups", []):
		var transforms: Array = group.get("transforms_godot", [])
		var required_nodes: Array = group.get("library_nodes", [])
		var cells: Dictionary = {}
		for i in transforms.size():
			var values: Array = transforms[i]
			var world_origin := world_transform * Vector3(values[9],values[10],values[11])
			var cell := Vector2i(floori(world_origin.x/chunk_size),floori(world_origin.z/chunk_size))
			if not cells.has(cell):
				cells[cell] = PackedInt32Array()
			var indices: PackedInt32Array = cells[cell]
			indices.append(i)
			cells[cell] = indices
		var bound_nodes := 0
		for mesh_name in required_nodes:
			var source: MeshInstance3D = library_nodes.get(mesh_name)
			if source == null:
				# Godot imports Blender's numeric suffix ".001" as "_001".
				source = library_nodes.get(str(mesh_name).replace(".", "_"))
			if source == null or source.mesh == null:
				push_warning("Missing original foliage library node: " + str(mesh_name))
				continue
			chunk_report.original_multimeshes += 1
			chunk_report.instances_before += transforms.size()
			for cell in cells:
				var indices: PackedInt32Array = cells[cell]
				var multimesh := MultiMesh.new()
				multimesh.transform_format = MultiMesh.TRANSFORM_3D
				# Each chunk shares the imported mesh and its materials. Instance
				# transforms remain in their original coordinate frame unchanged.
				multimesh.mesh = source.mesh
				multimesh.instance_count = indices.size()
				var bounds := AABB()
				for chunk_index in indices.size():
					var transform := _original_instance_transform(transforms[indices[chunk_index]])
					multimesh.set_instance_transform(chunk_index,transform)
					var instance_bounds := transform * source.mesh.get_aabb()
					bounds = instance_bounds if chunk_index == 0 else bounds.merge(instance_bounds)
				multimesh.custom_aabb = bounds
				var inst := MultiMeshInstance3D.new()
				inst.name = "OriginalInstances_%d_%s_Chunk_%d_%d" % [group_number,str(mesh_name),cell.x,cell.y]
				inst.multimesh = multimesh
				for key in source.get_meta_list():
					inst.set_meta(key,source.get_meta(key))
				inst.set_meta("source_component",group.get("source_component",0))
				inst.set_meta("source_map",group.get("source_map",""))
				inst.set_meta("source_name",group.get("source_name",""))
				inst.set_meta("source_group_index",group_number)
				inst.set_meta("source_library_node",str(mesh_name))
				inst.set_meta("source_instance_indices",indices)
				inst.set_meta("source_chunk_cell",cell)
				world.add_child(inst)
				chunk_report.chunks += 1
				chunk_report.instances_after += indices.size()
				chunk_report.max_chunk_instances = maxi(chunk_report.max_chunk_instances,indices.size())
			bound_nodes += 1
		if not required_nodes.is_empty() and bound_nodes == required_nodes.size():
			foliage_instances += transforms.size()
		else:
			push_warning("Incomplete original foliage group %d: %d/%d library nodes bound" % [group_number, bound_nodes, required_nodes.size()])
		chunk_report.groups.append({"source_group":group_number,"source_instances":transforms.size(),"cells":cells.size(),"bound_library_nodes":bound_nodes})
		group_number += 1
	chunk_report.source_groups = group_number
	chunk_report.source_instances = foliage_instances
	world.set_meta("original_instance_chunking",chunk_report)
	print("ORIGINAL_INSTANCES_CHUNKED ",JSON.stringify(chunk_report))
	library.free()

func _original_instance_transform(values: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(values[0],values[1],values[2]),Vector3(values[3],values[4],values[5]),Vector3(values[6],values[7],values[8])),Vector3(values[9],values[10],values[11]))

func _apply_source_render_policy(root: Node3D) -> void:
	for node in root.find_children("*", "Node3D", true, false):
		if node.has_meta("source_visible") and not bool(node.get_meta("source_visible")):
			node.visible = false
		if not node is MeshInstance3D or node.mesh == null:
			continue
		for surface in node.mesh.get_surface_count():
			var material = node.mesh.surface_get_material(surface)
			if not material is StandardMaterial3D:
				continue
			# Source COLOR contains animation weights; color textures own the albedo.
			material.vertex_color_use_as_albedo = false
			var policy: Dictionary = material_policies.get(material.resource_name, {})
			if policy.is_empty():
				continue
			if policy.get("blend_mode", "") == "BLEND_Masked":
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				material.alpha_scissor_threshold = float(policy.get("opacity_mask_clip_value", 0.3333))
			elif policy.get("blend_mode", "") == "BLEND_Opaque":
				material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			material.cull_mode = BaseMaterial3D.CULL_DISABLED if policy.get("two_sided", false) else BaseMaterial3D.CULL_BACK

func _add_temporary_environment() -> void:
	environment_driver = Node3D.new()
	add_child(environment_driver)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.48,0.61,0.67)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75,0.81,0.83)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	environment_driver.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52,-25,0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	environment_driver.add_child(sun)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(18,18)
	layer.add_child(panel)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	panel.add_child(stack)
	information = Label.new()
	information.add_theme_font_size_override("font_size", 22)
	stack.add_child(information)
	coverage = Label.new()
	coverage.add_theme_font_size_override("font_size", 16)
	stack.add_child(coverage)
	var buttons := HBoxContainer.new()
	stack.add_child(buttons)
	for option in [["无名岛", "wuming"],["游仙村", "youxian"]]:
		var button := Button.new()
		button.text = option[0]
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_load_world.bind(option[1]))
		buttons.add_child(button)
	viewpoint_picker = OptionButton.new()
	viewpoint_picker.focus_mode = Control.FOCUS_NONE
	viewpoint_picker.item_selected.connect(_select_viewpoint)
	buttons.add_child(viewpoint_picker)
	var hint := Label.new()
	hint.text = "WASD / 方向键：行走　F：自由观察　滚轮：远近　F7：下个地点　Home：码头　Tab：界面"
	hint.add_theme_font_size_override("font_size", 16)
	stack.add_child(hint)
	var note := Label.new()
	note.text = "复原对照版 · 水体、受光和部分动态仍有移植差异。"
	note.add_theme_color_override("font_color", Color(1.0,0.83,0.48))
	stack.add_child(note)
	panel.name = "ReviewControls"
	panel.visible = not hide_ui
	set_meta("controls_path", panel.get_path())

func _process(delta: float) -> void:
	elapsed += delta
	if not loading and is_instance_valid(player):
		ready_elapsed += delta
		focus = player.get_camera_anchor()
		camera.advance(delta, focus)
		if environment_driver.has_method("update_focus"):
			environment_driver.update_focus(focus)
		if environment_driver.has_method("update_player"):
			environment_driver.update_player(player.global_position)
		if is_instance_valid(audio_driver):
			audio_driver.update_focus(focus)
		if not tour.is_empty() and not tour_finished:
			_advance_tour(delta)
		if motion_frames != "" and not frame_pending and not tour_finished:
			frame_clock += delta
			if frame_clock >= 1.0/15.0:
				frame_clock = fmod(frame_clock, 1.0/15.0)
				_record_motion_frame()
		if lighting_review:
			_review_lighting()
	if is_instance_valid(information):
		information.text = ("无名岛" if slug == "wuming" else "游仙村") + " · Godot 复原" + (" · 自由观察" if inspection else " · 行走")
		coverage.text = status
	if capture_path != "" and ready_elapsed >= capture_after and is_instance_valid(camera) and not captured:
		captured = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(capture_path)
		print("REVIEW_CAPTURE ", capture_path)
		get_tree().quit()

func _advance_tour(delta: float) -> void:
	tour_clock += delta
	var steps: Array = tour.get("steps", [])
	var cursor := 0.0
	var current := steps.size()
	for i in steps.size():
		cursor += float(steps[i].get("seconds", 1.0))
		if tour_clock < cursor:
			current = i
			break
	if current != tour_step:
		tour_step = current
		if current < steps.size():
			var step: Dictionary = steps[current]
			if step.has("source_position"):
				var source: Array = step.source_position
				if is_instance_valid(house_driver):
					house_driver.reset_outdoors()
				player.place_at_source_actor_position(Vector3(source[0], source[1], source[2]))
				camera.reset_at(player.get_camera_anchor())
			var motion: Array = step.get("motion", [0,0])
			player.set_review_motion(Vector2(float(motion[0]), float(motion[1])))
			print("REVIEW_TOUR_STEP ", current, " ", step.get("label", ""))
		else:
			tour_finished = true
			player.set_review_motion(Vector2.ZERO)
			var report_path: String = tour.get("report", "")
			if report_path != "":
				var file := FileAccess.open(report_path, FileAccess.WRITE)
				file.store_string(JSON.stringify({"map":slug,"samples":tour_samples,"travelled":player.travelled_distance,"steps":steps,"recorded_frames":recorded_frames,"frame_times":frame_times,"duration":tour_clock}, "\t"))
			if capture_path == "":
				if is_instance_valid(audio_driver):
					audio_driver.shutdown()
				await get_tree().create_timer(0.3).timeout
				get_tree().quit()
	if current < steps.size() and steps[current].has("snapshot") and tour_clock >= cursor - 0.7 and not tour_snapshots.has(current):
		tour_snapshots[current] = true
		_capture_tour_snapshot(str(steps[current].snapshot))
	sample_clock += delta
	if sample_clock >= 0.1:
		sample_clock = 0.0
		var p := player.global_position
		var c := camera.global_position
		tour_samples.append({"time":tour_clock,"feet":[p.x,p.y,p.z],"camera":[c.x,c.y,c.z],"rotation":[camera.rotation.x,camera.rotation.y,camera.rotation.z],"edge_blocked":player.blocked_at_edge,"fps":Engine.get_frames_per_second(),"draw_calls":Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),"rendered_objects":Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),"rendered_primitives":Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)})

func _record_motion_frame() -> void:
	frame_pending = true
	await RenderingServer.frame_post_draw
	var frame := get_viewport().get_texture().get_image()
	frame.resize(1280,720,Image.INTERPOLATE_LANCZOS)
	frame.save_jpg(motion_frames.path_join("%05d.jpg" % recorded_frames),0.9)
	frame_times.append(tour_clock)
	recorded_frames += 1
	frame_pending = false

func _capture_tour_snapshot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("REVIEW_POINT_CAPTURE ", path)

func _review_lighting() -> void:
	var stage := int(ready_elapsed / 3.0)
	if stage == lighting_stage:
		return
	lighting_stage = stage
	var env: Environment = world.find_children("*", "WorldEnvironment", true, false)[0].environment
	if stage == 0:
		print("LIGHT_DIAGNOSTIC env exposure=",env.tonemap_exposure," ambient=",env.ambient_light_energy," background=",env.background_energy_multiplier," skycontribution=",env.ambient_light_sky_contribution)
		for light in world.find_children("*", "Light3D", true, false):
			print("LIGHT_DIAGNOSTIC ",light.name," energy=",light.light_energy," direction=",-light.global_basis.z)
		return
	await RenderingServer.frame_post_draw
	var diagnostic_path := ProjectSettings.globalize_path("res://../artifacts/wandering-godot-play-review/captures/light-diagnostic-%d.png" % stage)
	DirAccess.make_dir_recursive_absolute(diagnostic_path.get_base_dir())
	get_viewport().get_texture().get_image().save_png(diagnostic_path)
	if stage == 1:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.72,0.76,0.82)
		env.ambient_light_energy = 0.12
		env.reflected_light_source = 2
	elif stage == 2:
		for light in world.find_children("*", "Light3D", true, false):
			light.visible = false
	elif stage == 3:
		env.fog_enabled = false
		for mesh in world.find_children("*", "MeshInstance3D", true, false):
			if mesh.material_override is ShaderMaterial and "fog_card" in str(mesh.material_override.shader.resource_path):
				mesh.visible = false
	elif stage >= 4:
		get_tree().quit()

func _unhandled_input(event: InputEvent) -> void:
	if loading or not is_instance_valid(player):
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.change_zoom(0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.change_zoom(1.0/0.9)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_HOME:
			_select_viewpoint(0)
		elif event.keycode == KEY_F:
			inspection = not inspection
			camera.inspection = inspection
			player.input_enabled = not inspection
		elif event.keycode == KEY_TAB:
			var controls := get_node(get_meta("controls_path")) as Control
			controls.visible = not controls.visible
		elif event.keycode == KEY_F7 and positions.size() > 1:
			_select_viewpoint((view_index + 1) % positions.size())

func _select_viewpoint(index: int) -> void:
	if loading or not is_instance_valid(player) or index >= positions.size():
		return
	if is_instance_valid(house_driver):
		house_driver.reset_outdoors()
	view_index = index
	viewpoint_picker.select(index)
	player.place_at_source_actor_position(positions[index])
	camera.reset_at(player.get_camera_anchor())

