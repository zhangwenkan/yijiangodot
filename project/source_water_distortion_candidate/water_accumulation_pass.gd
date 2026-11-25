extends RefCounted
## Additional raster contribution to the shared native distortion accumulation.
const ROOT := "res://source_water_distortion_candidate/"
var _rd: RenderingDevice
var _lock:=Mutex.new()
var _payload: Dictionary={}
var _textures: Array[Texture2D]=[]
var _transform:=Transform3D.IDENTITY
var _parameters:=PackedFloat32Array()
var _active:=false
var _shader:=RID()
var _pipeline:=RID()
var _vertex_buffer:=RID()
var _index_buffer:=RID()
var _vertex_array:=RID()
var _index_array:=RID()
var _frame:=RID()
var _format:=0
var last_frame:=PackedByteArray()

func configure_original_mesh(mesh: Mesh, textures: Array[Texture2D]) -> Dictionary:
	if mesh==null or mesh.get_surface_count()!=1 or textures.size()!=6:
		return {"passed":false,"reason":"Need the existing one-surface Water mesh and six source normal textures"}
	var arrays:=mesh.surface_get_arrays(0)
	var positions: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array=arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
	if positions.is_empty() or positions.size()!=normals.size() or positions.size()!=uvs.size() or indices.is_empty():
		return {"passed":false,"reason":"Missing authored position/normal/UV/index; no geometry synthesis fallback"}
	var vertices:=PackedFloat32Array()
	for i in positions.size():
		vertices.append_array(PackedFloat32Array([positions[i].x,positions[i].y,positions[i].z,normals[i].x,normals[i].y,normals[i].z,uvs[i].x,uvs[i].y]))
	var context:=HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(vertices.to_byte_array())
	context.update(indices.to_byte_array())
	var digest:=context.finish().hex_encode()
	_lock.lock()
	_payload={"vertices":vertices.to_byte_array(),"indices":indices.to_byte_array(),"vertex_count":positions.size(),"index_count":indices.size()}
	_textures=textures
	_lock.unlock()
	return {"passed":true,"vertex_count":positions.size(),"index_count":indices.size(),"copied_data_sha256":digest,"geometry_changed":false}

func submit(transform: Transform3D, parameters: PackedFloat32Array, active: bool) -> void:
	_lock.lock()
	_transform=transform
	_parameters=parameters
	_active=active and parameters.size()==24
	_lock.unlock()

func active() -> bool:
	_lock.lock()
	var value:=_active and not _payload.is_empty()
	_lock.unlock()
	return value

func _uniform(kind: int, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform:=RDUniform.new()
	uniform.uniform_type=kind
	uniform.binding=binding
	for id in ids: uniform.add_id(id)
	return uniform

func _projection(data: PackedFloat32Array, matrix: Projection) -> void:
	for v in [matrix.x,matrix.y,matrix.z,matrix.w]:
		data.append_array(PackedFloat32Array([v.x,v.y,v.z,v.w]))

func prepare(rd: RenderingDevice, framebuffer: RID, scene: RenderSceneData, size: Vector2i, output_size: Vector2i, depth: RID, repeat_sampler: RID, point_sampler: RID) -> RID:
	if not active(): return RID()
	_rd=rd
	_lock.lock()
	var payload: Dictionary=_payload
	var textures: Array[Texture2D]=_textures
	var model: Transform3D=_transform
	var parameters: PackedFloat32Array=_parameters
	_lock.unlock()
	if not _shader.is_valid():
		var source:=RDShaderSource.new()
		source.source_vertex=FileAccess.get_file_as_string(ROOT+"water_accumulate.vert.glsl.txt")
		source.source_fragment=FileAccess.get_file_as_string(ROOT+"water_accumulate.frag.glsl.txt")
		var spirv:=rd.shader_compile_spirv_from_source(source)
		for stage in [RenderingDevice.SHADER_STAGE_VERTEX,RenderingDevice.SHADER_STAGE_FRAGMENT]:
			var error:=spirv.get_stage_compile_error(stage)
			if not error.is_empty():
				push_error("Water distortion compile: "+error)
				return RID()
		_shader=rd.shader_create_from_spirv(spirv)
		_frame=rd.uniform_buffer_create(432)
		var vertex_bytes: PackedByteArray=payload.vertices
		var index_bytes: PackedByteArray=payload.indices
		_vertex_buffer=rd.vertex_buffer_create(vertex_bytes.size(),vertex_bytes)
		_index_buffer=rd.index_buffer_create(int(payload.index_count),RenderingDevice.INDEX_BUFFER_FORMAT_UINT32,index_bytes)
		var attrs: Array[RDVertexAttribute]=[]
		for i in 3:
			var attr:=RDVertexAttribute.new()
			attr.location=i
			attr.format=RenderingDevice.DATA_FORMAT_R32G32_SFLOAT if i==2 else RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
			attr.offset=[0,12,24][i]
			attr.stride=32
			attrs.append(attr)
		_format=rd.vertex_format_create(attrs)
		_vertex_array=rd.vertex_array_create(int(payload.vertex_count),_format,[_vertex_buffer,_vertex_buffer,_vertex_buffer])
		_index_array=rd.index_array_create(_index_buffer,0,int(payload.index_count))
		var attachment:=RDPipelineColorBlendStateAttachment.new()
		attachment.enable_blend=true
		attachment.src_color_blend_factor=RenderingDevice.BLEND_FACTOR_ONE
		attachment.dst_color_blend_factor=RenderingDevice.BLEND_FACTOR_ONE
		attachment.src_alpha_blend_factor=RenderingDevice.BLEND_FACTOR_ONE
		attachment.dst_alpha_blend_factor=RenderingDevice.BLEND_FACTOR_ONE
		var blend:=RDPipelineColorBlendState.new()
		blend.attachments=[attachment]
		var raster:=RDPipelineRasterizationState.new()
		raster.cull_mode=RenderingDevice.POLYGON_CULL_DISABLED
		_pipeline=rd.render_pipeline_create(_shader,rd.framebuffer_get_format(framebuffer),_format,RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,raster,RDPipelineMultisampleState.new(),RDPipelineDepthStencilState.new(),blend)
	if not _pipeline.is_valid(): return RID()
	var data:=PackedFloat32Array()
	var projection:=scene.get_view_projection(0)
	var camera:=scene.get_cam_transform()
	_projection(data,projection)
	_projection(data,projection.inverse())
	_projection(data,Projection(camera.affine_inverse()))
	_projection(data,Projection(camera))
	data.append_array(PackedFloat32Array([size.x,size.y,output_size.x,output_size.y]))
	_projection(data,Projection(model))
	data.append_array(parameters)
	last_frame=data.to_byte_array()
	rd.buffer_update(_frame,0,432,last_frame)
	var uniforms: Array[RDUniform]=[_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,0,[_frame])]
	for i in 6:
		var texture:=RenderingServer.texture_get_rd_texture(textures[i].get_rid(),false)
		if not texture.is_valid(): return RID()
		uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,i+1,[repeat_sampler,texture]))
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,7,[point_sampler,depth]))
	var scene_buffer:=scene.get_uniform_buffer()
	if not scene_buffer.is_valid(): return RID()
	uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,8,[scene_buffer]))
	return UniformSetCacheRD.get_cache(_shader,0,uniforms)

func draw(commands: int, uniform_set: RID) -> void:
	if not uniform_set.is_valid(): return
	_rd.draw_list_bind_render_pipeline(commands,_pipeline)
	_rd.draw_list_bind_uniform_set(commands,uniform_set,0)
	_rd.draw_list_bind_vertex_array(commands,_vertex_array)
	_rd.draw_list_bind_index_array(commands,_index_array)
	_rd.draw_list_draw(commands,true,1)

func release(rd: RenderingDevice) -> void:
	for id in [_vertex_buffer,_index_buffer,_frame,_shader]:
		if id.is_valid(): rd.free_rid(id)
	_vertex_buffer=RID()
	_index_buffer=RID()
	_frame=RID()
	_shader=RID()
	_pipeline=RID()
	_vertex_array=RID()
	_index_array=RID()
