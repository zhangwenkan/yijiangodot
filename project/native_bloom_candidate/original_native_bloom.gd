extends CompositorEffect
## Independent diagnostic: insert immediately BEFORE Native Film in one compositor.
## Both use POST_TRANSPARENT. Godot glow OFF; Godot tone mapper LINEAR/exposure 1.
## No scene geometry or shared runtime is modified by this staging candidate.

const STAGE_SIZES := [0.30000001192092896, 1.0, 2.0, 10.0, 30.0, 64.0]
# Exact float32 values from the shipped FPostProcessSettings constructor.
const STAGE_TINTS := [0.3465000092983246, 0.1379999965429306,
	0.11760000139474869, 0.06599999964237213, 0.06599999964237213, 0.061000000685453415]
const PROFILE_BLOOM_QUALITY := [4, 4, 5, 5, 5]
const PROFILE_FILTER_SCALE := [0.6, 0.7, 0.8, 1.0, 1.0]
const PROFILE_FAST_THRESHOLD := [0.0, 2.0, 3.0, 100.0, 100.0]
const QUALITY_STAGE_COUNT := [0, 3, 3, 4, 5, 6]

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _kernel_buffer := RID()
var _sampler_border := RID()
var _sampler_clamp := RID()
var _half_scene := RID()
var _levels: Array[RID] = []
var _horizontal: Array[RID] = []
var _accumulated: Array[RID] = []
var _sizes: Array[Vector2i] = []
var _horizontal_sizes: Array[Vector2i] = []
var _sample_counts: Array[int] = []
var _allocated_size := Vector2i.ZERO
var _allocated_profile := -1
var _lock := Mutex.new()
var _inside := false
var _outdoor_intensity := 5.0
var _indoor_intensity := 5.0
# Explicit candidate assumption. These profiles are from the game's BaseScalability.ini.
# A live native process's currently selected profile has not been captured.
var _profile := 3
var _shader_path := ""

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	_shader_path = get_script().resource_path.get_base_dir() + "/original_native_bloom.glsl"
	RenderingServer.call_on_render_thread(_initialize_compute)

func set_source_indoor(value: bool) -> void:
	_lock.lock()
	_inside = value
	_lock.unlock()

func set_source_intensities(outdoor: float, indoor: float) -> void:
	# Main-map BP_IntoHouseTrigger retains Bloom=5. S5's 0.5 is a separate map,
	# or an explicit numeric fixture input, never inferred from house state.
	_lock.lock()
	_outdoor_intensity = maxf(outdoor, 0.0)
	_indoor_intensity = maxf(indoor, 0.0)
	_lock.unlock()

func set_source_postprocess_quality(value: int) -> void:
	_lock.lock()
	_profile = clampi(value, 0, 4)
	_lock.unlock()

func _initialize_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("Native Bloom candidate needs the RD Forward+ renderer.")
		return
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(_shader_path).replace("#[compute]", "")
	var spirv := _rd.shader_compile_spirv_from_source(source)
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		push_error("Native Bloom candidate compile failed: " + error)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER
	sampler.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.border_color = RenderingDevice.SAMPLER_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK
	_sampler_border = _rd.sampler_create(sampler)
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler_clamp = _rd.sampler_create(sampler)

func _make_texture(size: Vector2i) -> RID:
	var format := RDTextureFormat.new()
	format.width = size.x
	format.height = size.y
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return _rd.texture_create(format, RDTextureView.new(), [])

func _free_targets() -> void:
	if _rd == null:
		return
	for collection in [_levels, _horizontal, _accumulated]:
		for target in collection:
			if target.is_valid():
				_rd.free_rid(target)
	_levels.clear()
	_horizontal.clear()
	_accumulated.clear()
	_sizes.clear()
	_horizontal_sizes.clear()
	_sample_counts.clear()
	if _half_scene.is_valid():
		_rd.free_rid(_half_scene)
		_half_scene = RID()
	if _kernel_buffer.is_valid():
		_rd.free_rid(_kernel_buffer)
		_kernel_buffer = RID()

func _build_targets(size: Vector2i, profile: int) -> void:
	_free_targets()
	var dimensions := size
	var packed_kernels := PackedByteArray()
	packed_kernels.resize(6 * 32 * 16)
	for stage in range(6):
		dimensions = Vector2i(maxi(1, ceili(float(dimensions.x)/2.0)), maxi(1, ceili(float(dimensions.y)/2.0)))
		_sizes.append(dimensions)
		_levels.append(_make_texture(dimensions))
		# UE computes both axes' radius from this level's WIDTH, before clamping.
		var radius: float = float(dimensions.x) * STAGE_SIZES[stage] * 50.0 * 0.01 * 0.5
		var fast: bool = radius >= PROFILE_FAST_THRESHOLD[profile]
		var horizontal_size := Vector2i(maxi(1, ceili(float(dimensions.x)/2.0)) if fast else dimensions.x, dimensions.y)
		_horizontal_sizes.append(horizontal_size)
		_horizontal.append(_make_texture(horizontal_size))
		_accumulated.append(_make_texture(dimensions))
		var sigma := clampf(radius, 0.00001, 31.0)
		var integer_radius := mini(ceili(clampf(radius * PROFILE_FILTER_SCALE[profile], 0.00001, 31.0)), 31)
		var offsets: Array[float] = []
		var weights: Array[float] = []
		var total := 0.0
		for i in range(-integer_radius, integer_radius+1, 2):
			var weight0 := exp(-16.7 * pow(float(i)/sigma, 2.0))
			var weight1 := exp(-16.7 * pow(float(i+1)/sigma, 2.0)) if i != integer_radius else 0.0
			var weight := weight0 + weight1
			# At tiny diagnostic resolutions both paired weights can underflow.
			# This pair contributes zero; choose its integer center to stay finite.
			offsets.append(float(i) + weight1/weight if weight > 0.0 else float(i))
			weights.append(weight)
			total += weight
		_sample_counts.append(weights.size())
		for i in weights.size():
			var byte_offset := (stage*32+i)*16
			packed_kernels.encode_float(byte_offset, offsets[i])
			packed_kernels.encode_float(byte_offset+4, weights[i]/total)
	_half_scene = _make_texture(_sizes[0])
	_kernel_buffer = _rd.storage_buffer_create(packed_kernels.size(), packed_kernels)
	_allocated_size = size
	_allocated_profile = profile

func _dispatch(commands: int, source: RID, additive: RID, output: RID, source_size: Vector2i,
		output_size: Vector2i, operation: int, stage: int, has_additive: bool, intensity: float) -> void:
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	source_uniform.binding = 0
	source_uniform.add_id(_sampler_clamp if operation <= 1 else _sampler_border)
	source_uniform.add_id(source)
	var additive_uniform := RDUniform.new()
	additive_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	additive_uniform.binding = 1
	additive_uniform.add_id(_sampler_border)
	additive_uniform.add_id(additive)
	var kernel_uniform := RDUniform.new()
	kernel_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	kernel_uniform.binding = 2
	kernel_uniform.add_id(_kernel_buffer)
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 3
	output_uniform.add_id(output)
	var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [source_uniform, additive_uniform, kernel_uniform, output_uniform])
	var push := PackedByteArray()
	push.resize(64)
	push.encode_s32(0, output_size.x)
	push.encode_s32(4, output_size.y)
	push.encode_s32(8, source_size.x)
	push.encode_s32(12, source_size.y)
	push.encode_s32(16, operation)
	push.encode_s32(20, stage*32)
	push.encode_s32(24, _sample_counts[stage])
	push.encode_s32(28, int(has_additive))
	push.encode_float(32, 1.0) # Source BloomThreshold.
	push.encode_float(36, intensity)
	push.encode_float(40, STAGE_TINTS[stage]/6.0)
	push.encode_float(44, 1.0) # Native r.Downsample.Quality default, not in scalability overrides.
	_rd.compute_list_bind_compute_pipeline(commands, _pipeline)
	_rd.compute_list_bind_uniform_set(commands, uniforms, 0)
	_rd.compute_list_set_push_constant(commands, push, push.size())
	_rd.compute_list_dispatch(commands, ceili(float(output_size.x)/8.0), ceili(float(output_size.y)/8.0), 1)
	_rd.compute_list_add_barrier(commands)

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null or not _pipeline.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	_lock.lock()
	var inside := _inside
	var profile := _profile
	var intensity := _indoor_intensity if inside else _outdoor_intensity
	_lock.unlock()
	if size != _allocated_size or profile != _allocated_profile:
		_build_targets(size, profile)
	var last_stage: int = 6 - QUALITY_STAGE_COUNT[PROFILE_BLOOM_QUALITY[profile]]
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var commands := _rd.compute_list_begin()
		_dispatch(commands, color, color, _half_scene, size, _sizes[0], 0, 0, false, intensity)
		_dispatch(commands, _half_scene, _half_scene, _levels[0], _sizes[0], _sizes[0], 1, 0, false, intensity)
		for stage in range(1, 6):
			_dispatch(commands, _levels[stage-1], _levels[stage-1], _levels[stage], _sizes[stage-1], _sizes[stage], 0, stage, false, intensity)
		for stage in range(5, last_stage-1, -1):
			_dispatch(commands, _levels[stage], _levels[stage], _horizontal[stage], _sizes[stage], _horizontal_sizes[stage], 2, stage, false, intensity)
			var additive := _accumulated[stage+1] if stage < 5 else _levels[stage]
			_dispatch(commands, _horizontal[stage], additive, _accumulated[stage], _horizontal_sizes[stage], _sizes[stage], 3, stage, stage < 5, intensity)
		_dispatch(commands, _accumulated[last_stage], _accumulated[last_stage], color, _sizes[last_stage], size, 4, last_stage, false, intensity)
		_rd.compute_list_end()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		# PREDELETE cannot safely dispatch another GDScript member method.
		for collection in [_levels, _horizontal, _accumulated]:
			for target in collection:
				if target.is_valid():
					_rd.free_rid(target)
		if _half_scene.is_valid():
			_rd.free_rid(_half_scene)
		if _kernel_buffer.is_valid():
			_rd.free_rid(_kernel_buffer)
		if _sampler_border.is_valid():
			_rd.free_rid(_sampler_border)
		if _sampler_clamp.is_valid():
			_rd.free_rid(_sampler_clamp)
		if _shader.is_valid():
			_rd.free_rid(_shader)
