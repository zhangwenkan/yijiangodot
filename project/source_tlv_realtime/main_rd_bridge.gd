extends RefCounted
## All methods prefixed _rt and render_cascade run on the main render thread.
## Only a 192-byte completion record is read back per pair. Initial UBO layout
## discovery reads 5696 bytes once per probe; no atlas/volume is read back here.
const FOLDER := "res://source_tlv_realtime/"
const STATUS_BYTES := 192
const SHADERS := ["atlas_inject.glsl.txt", "filter_volume.glsl.txt", "finish_status.glsl.txt"]
var _rd: RenderingDevice
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _sampler := RID()
var _raw: Array[RID] = []
var _slots: Array[Dictionary] = []
var _jobs: Dictionary = {}
var _checked_ubo := [false, false]
var _closed := false
var _freed := false
var _mutex := Mutex.new()
var _events: Array[Dictionary] = []
var _diagnostic_directory := ""
var _diagnostic_claimed := false

func initialize(pool_size: int, diagnostic_directory: String = "") -> void:
	_diagnostic_directory=diagnostic_directory
	RenderingServer.call_on_render_thread(_rt_initialize.bind(pool_size))

func take_events() -> Array[Dictionary]:
	_mutex.lock()
	var value: Array[Dictionary] = _events
	_events = []
	_mutex.unlock()
	return value

func _event(value: Dictionary) -> void:
	_mutex.lock()
	_events.append(value)
	_mutex.unlock()

func _rt_initialize(pool_size: int) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_event({"kind":"fatal", "error":"Main RenderingDevice required; no local-RD fallback."})
		_freed=true
		_event({"kind":"closed"})
		return
	for file in SHADERS:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string(FOLDER+file)
		var spirv := _rd.shader_compile_spirv_from_source(source)
		var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not error.is_empty():
			_event({"kind":"fatal", "error":file+": "+error})
			_rt_free()
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		if not shader.is_valid():
			_event({"kind":"fatal","error":"Shader allocation failed: "+file}); _rt_free(); return
		_shaders.append(shader)
		var pipeline := _rd.compute_pipeline_create(shader)
		if not pipeline.is_valid():
			_event({"kind":"fatal","error":"Compute pipeline allocation failed: "+file}); _rt_free(); return
		_pipelines.append(pipeline)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)
	if not _sampler.is_valid():
		_event({"kind":"fatal","error":"Sampler allocation failed."}); _rt_free(); return
	for index in 2:
		var raw := _rt_texture()
		if not raw.is_valid():
			_event({"kind":"fatal","error":"Raw scratch texture allocation failed."}); _rt_free(); return
		_raw.append(raw)
	for index in pool_size:
		var images: Array[RID] = []
		var textures: Array[Dictionary] = []
		var slot := {"images":images,"textures":textures,"status":RID(),"token":-1}
		_slots.append(slot)
		for cascade in 2:
			var pair: Dictionary = {}
			textures.append(pair)
			for key in ["ambient", "directional"]:
				var id := _rt_texture()
				if not id.is_valid():
					_event({"kind":"fatal","error":"Filtered texture allocation failed."}); _rt_free(); return
				images.append(id)
				var wrapper := Texture3DRD.new()
				wrapper.texture_rd_rid = id
				pair[key] = wrapper
		var status := _rd.storage_buffer_create(STATUS_BYTES)
		slot.status=status
		if not status.is_valid():
			_event({"kind":"fatal","error":"Status buffer allocation failed."}); _rt_free(); return
	var public_slots: Array[Dictionary] = []
	for index in _slots.size():
		public_slots.append({"slot":index,"textures":_slots[index].textures,"images":_slots[index].images})
	_event({"kind":"initialized","slots":public_slots,"status_bytes":STATUS_BYTES,
		"filtered_pool_bytes":pool_size*4*64*64*64*8,"raw_scratch_bytes":2*64*64*64*8})

func _rt_texture() -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = 64; format.height = 64; format.depth = 64
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	if not _diagnostic_directory.is_empty(): format.usage_bits|=RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(format,RDTextureView.new())

func begin(snapshot: Dictionary) -> void:
	RenderingServer.call_on_render_thread(_rt_begin.bind(snapshot.duplicate(true)))

func _rt_begin(snapshot: Dictionary) -> void:
	if _closed or _freed: return
	var slot: int = snapshot.slot
	var token: int = snapshot.snapshot_id
	if slot < 0 or slot >= _slots.size() or int(_slots[slot].token) >= 0 or _jobs.has(token):
		_event({"kind":"fatal","error":"Slot/token ownership conflict at begin."})
		return
	_slots[slot].token = token
	var zeros := PackedByteArray()
	zeros.resize(STATUS_BYTES)
	_rd.buffer_update(_slots[slot].status,0,STATUS_BYTES,zeros)
	var diagnostic := not _diagnostic_directory.is_empty() and not _diagnostic_claimed
	if diagnostic: _diagnostic_claimed=true
	_jobs[token] = {"snapshot":snapshot,"done":[false,false],"frames":[-1,-1],
		"ack_requested":false,"cancelled":false,"error":"","diagnostic":diagnostic,"diagnostic_records":[]}

func _uniform(kind: int, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = kind
	uniform.binding = binding
	for id in ids: uniform.add_id(id)
	return uniform

func _push(snapshot: Dictionary, cascade: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(64)
	var radiance: Vector3 = snapshot.radiance
	var direction: Vector3 = snapshot.direction_ue
	for component in 3:
		bytes.encode_float(component*4,radiance[component])
		bytes.encode_float(16+component*4,direction[component])
	for index in 4:
		bytes.encode_u32(32+index*4,int(snapshot[["snapshot_id","install_generation","house_generation","owner_generation"][index]]))
	bytes.encode_u32(48,cascade)
	bytes.encode_u32(52,int(snapshot.request_frame)&0xFFFFFFFF)
	return bytes

func _dispatch(shader_index: int, uniforms: Array[RDUniform], push: PackedByteArray) -> void:
	var set := UniformSetCacheRD.get_cache(_shaders[shader_index],0,uniforms)
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_pipelines[shader_index])
	_rd.compute_list_bind_uniform_set(commands,set,0)
	if not push.is_empty(): _rd.compute_list_set_push_constant(commands,push,push.size())
	_rd.compute_list_dispatch(commands,16,16,16)
	_rd.compute_list_end()

func render_cascade(snapshot: Dictionary, cascade: int, render_data: RenderData) -> void:
	var token: int = snapshot.snapshot_id
	if _closed or not _jobs.has(token): return
	var job: Dictionary = _jobs[token]
	if job.ack_requested: return
	if cascade < 0 or cascade > 1 or job.done[cascade]:
		_rt_reject(token,"Duplicate/invalid cascade callback.")
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null or buffers.get_view_count()!=1 or buffers.get_internal_size()!=Vector2i(512,512):
		_rt_reject(token,"Expected one 512x512 non-XR probe.")
		return
	var color := buffers.get_color_layer(0)
	var format := _rd.texture_get_format(color)
	if format.format!=RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT or (format.usage_bits&RenderingDevice.TEXTURE_USAGE_STORAGE_BIT)==0:
		_rt_reject(token,"Probe color must be linear RGBA16F with STORAGE usage.")
		return
	var ubo: RID = scene_data.get_uniform_buffer()
	if not _checked_ubo[cascade]:
		var initial := _rd.buffer_get_data(ubo)
		if initial.size()!=5696:
			_rt_reject(token,"Unsupported scene UBO layout: "+str(initial.size()))
			return
		_checked_ubo[cascade] = true
		_event({"kind":"ubo_layout","cascade":cascade,"bytes":initial.size(),
			"initial_bytes":initial,"engine":Engine.get_version_info(),"precision":4,
			"current_clock_offset":2816,"previous_clock_offset":5664})
	var slot: Dictionary = _slots[int(snapshot.slot)]
	if int(slot.token)!=token:
		_rt_reject(token,"Slot no longer belongs to this snapshot.")
		return
	var push := _push(snapshot,cascade)
	_dispatch(0,[
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,0,[color]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,[_raw[0]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,2,[_raw[1]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,3,[slot.status])],push)
	for component in 2:
		_dispatch(1,[
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,0,[_sampler,_raw[component]]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,[slot.images[cascade*2+component]])],PackedByteArray())
	_dispatch(2,[
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,0,[slot.images[cascade*2]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,[slot.images[cascade*2+1]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,2,[slot.status]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,3,[ubo])],push)
	if bool(job.diagnostic): _rt_dump_cascade(job,cascade,color,ubo)
	job.done[cascade] = true
	job.frames[cascade] = Engine.get_frames_drawn()
	if job.done[0] and job.done[1]:
		if job.frames[0]!=job.frames[1]: job.error = "Near/far were produced in different drawn frames."
		_rt_request_ack(token)

func abandon(token: int, reason: String) -> void:
	RenderingServer.call_on_render_thread(_rt_reject.bind(token,reason))

func _rt_reject(token: int, reason: String) -> void:
	if not _jobs.has(token): return
	var job: Dictionary = _jobs[token]
	job.cancelled = true
	job.error = reason
	if not job.ack_requested: _rt_request_ack(token)

func _rt_request_ack(token: int) -> void:
	var job: Dictionary = _jobs[token]
	job.ack_requested = true
	var status: RID = _slots[int(job.snapshot.slot)].status
	var error := _rd.buffer_get_data_async(status,_ack_callback.bind(token),0,STATUS_BYTES)
	if error!=OK:
		# No completion evidence: quarantine the slot; never age it back to FREE.
		_event({"kind":"fatal","error":"Status async read failed; slot quarantined: "+str(error)})

func _ack_callback(bytes: PackedByteArray, token: int) -> void:
	# Exact 4.7.2 calls this in _stall_for_frame after fence_wait. Normalize onto
	# the render queue anyway; no GDScript worker may mutate RD ownership state.
	RenderingServer.call_on_render_thread(_rt_ack.bind(bytes,token))

func _rt_ack(bytes: PackedByteArray, token: int) -> void:
	if not _jobs.has(token): return
	var job: Dictionary = _jobs[token]
	_jobs.erase(token)
	if bool(job.diagnostic):
		var status_path := _diagnostic_directory.path_join("status.bin")
		var file := FileAccess.open(status_path,FileAccess.WRITE)
		if file!=null: file.store_buffer(bytes); file.close()
		var metadata := {"snapshot":job.snapshot,"actual_frames":job.frames,"done":job.done,
			"cancelled":job.cancelled,"error":job.error,"status_file":"status.bin",
			"captures":job.diagnostic_records,"only_one_pair":true,
			"radiance":Array([job.snapshot.radiance.x,job.snapshot.radiance.y,job.snapshot.radiance.z]),
			"direction_ue":Array([job.snapshot.direction_ue.x,job.snapshot.direction_ue.y,job.snapshot.direction_ue.z]),
			"engine":Engine.get_version_info(),"scope":"Explicit one-pair full readback; not the normal realtime path."}
		var metadata_file := FileAccess.open(_diagnostic_directory.path_join("diagnostic.json"),FileAccess.WRITE)
		if metadata_file!=null: metadata_file.store_string(JSON.stringify(metadata,"\t")); metadata_file.close()
		_event({"kind":"diagnostic","directory":_diagnostic_directory,"metadata":metadata})
	_event({"kind":"complete","snapshot":job.snapshot,"frames":job.frames,
		"done":job.done,"status":bytes,"cancelled":job.cancelled,"error":job.error})
	if _closed and _jobs.is_empty(): _rt_free()

func release_slot(slot: int, token: int) -> void:
	RenderingServer.call_on_render_thread(_rt_release_slot.bind(slot,token))

func _rt_release_slot(slot: int, token: int) -> void:
	if _freed or slot<0 or slot>=_slots.size(): return
	if int(_slots[slot].token)==token and not _jobs.has(token): _slots[slot].token=-1

func close() -> void:
	RenderingServer.call_on_render_thread(_rt_close)

func _rt_close() -> void:
	_closed = true
	for token in _jobs.keys(): _rt_reject(int(token),"Owner closed.")
	if _jobs.is_empty(): _rt_free()

func _rt_free() -> void:
	if _freed or _rd==null: return
	_freed = true
	for slot in _slots:
		for pair in slot.textures:
			for key in ["ambient","directional"]:
				# The wrapper owns an RS view, not the original RD texture.
				if pair.has(key): pair[key].texture_rd_rid=RID()
		for id in slot.images:
			if id.is_valid(): _rd.free_rid(id)
		if slot.status.is_valid(): _rd.free_rid(slot.status)
	_slots.clear()
	for id in _raw+_pipelines+_shaders:
		if id.is_valid(): _rd.free_rid(id)
	_raw.clear(); _pipelines.clear(); _shaders.clear()
	if _sampler.is_valid(): _rd.free_rid(_sampler)
	_event({"kind":"closed"})

func _rt_dump_cascade(job: Dictionary, cascade: int, color: RID, ubo: RID) -> void:
	# Explicit diagnostic option and a single claimed token only. Never enabled
	# by normal install. Synchronous full readback is acceptable only here.
	if _diagnostic_directory.is_empty() or not bool(job.diagnostic): return
	var copy_source := RDShaderSource.new()
	copy_source.source_compute="""
#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(rgba16f,set=0,binding=0) uniform readonly image2D src;
layout(rgba16f,set=0,binding=1) uniform writeonly image2D dst;
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);if(all(lessThan(p,imageSize(dst))))imageStore(dst,p,imageLoad(src,p));}
"""
	var spirv := _rd.shader_compile_spirv_from_source(copy_source)
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty(): job.error="Diagnostic copy compile failed: "+compile_error; return
	var shader := _rd.shader_create_from_spirv(spirv)
	var pipeline := _rd.compute_pipeline_create(shader)
	var format := RDTextureFormat.new()
	format.texture_type=RenderingDevice.TEXTURE_TYPE_2D
	format.format=RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width=512; format.height=512
	format.usage_bits=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var copy := _rd.texture_create(format,RDTextureView.new())
	if not shader.is_valid() or not pipeline.is_valid() or not copy.is_valid():
		job.error="Diagnostic atlas copy allocation failed."
		for id in [copy,pipeline,shader]:
			if id.is_valid(): _rd.free_rid(id)
		return
	var set := _rd.uniform_set_create([
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,0,[color]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,[copy])],shader,0)
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,pipeline)
	_rd.compute_list_bind_uniform_set(commands,set,0)
	_rd.compute_list_dispatch(commands,64,64,1)
	_rd.compute_list_end()
	var slot: Dictionary = _slots[int(job.snapshot.slot)]
	var record := {"cascade":cascade,"frame":Engine.get_frames_drawn(),"files":[]}
	var payloads := {"atlas.rgba16f":_rd.texture_get_data(copy,0),"scene-ubo.bin":_rd.buffer_get_data(ubo),
		"raw-ambient.rgba16f":_rd.texture_get_data(_raw[0],0),
		"raw-directional.rgba16f":_rd.texture_get_data(_raw[1],0),
		"filtered-ambient.rgba16f":_rd.texture_get_data(slot.images[cascade*2],0),
		"filtered-directional.rgba16f":_rd.texture_get_data(slot.images[cascade*2+1],0)}
	for key in payloads:
		var name := "cascade"+str(cascade)+"-"+str(key)
		var file := FileAccess.open(_diagnostic_directory.path_join(name),FileAccess.WRITE)
		if file==null: job.error="Cannot write diagnostic file: "+name; continue
		file.store_buffer(payloads[key]); file.close()
		record.files.append({"file":name,"bytes":payloads[key].size()})
	job.diagnostic_records.append(record)
	for id in [set,copy,pipeline,shader]: _rd.free_rid(id)
