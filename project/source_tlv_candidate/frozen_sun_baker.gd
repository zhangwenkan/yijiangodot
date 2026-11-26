extends RefCounted
## Frozen-frame diagnostic only. CPU resolves captured real shadow/LF, GPU does
## source SH/half accumulation/filter. Not an interactive per-frame solution.
static func bake(captures: Array[PackedByteArray], bounds: Array[Dictionary], sun: DirectionalLight3D, output: String) -> Dictionary:
	if captures.size() != 2 or bounds.size() != 2: return {"error":"Missing matching cascades"}
	for bound in bounds:
		if int(bound.get("dimension",0)) != 64 or not bound.get("min_ue_cm") is Vector3:
			return {"error":"Invalid volume bounds"}
		var minimum: Vector3 = bound.min_ue_cm
		var voxel := float(bound.get("voxel_cm",0))
		if not minimum.is_finite() or not is_finite(voxel) or voxel <= 0.0: return {"error":"Nonfinite volume bounds"}
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null: return {"error":"RenderingDevice unavailable"}
	var compute := preload("res://source_tlv_candidate/volume_compute.gd").new()
	var error := compute.initialize(rd, "res://source_tlv_candidate")
	if not error.is_empty(): compute.release(); rd.free(); return {"error":error}
	var textures: Array[Dictionary] = []
	var uploads: Array[Dictionary] = []
	var direction_godot := sun.global_basis.z.normalized()
	var direction_ue := Vector3(direction_godot.x, direction_godot.z, direction_godot.y)
	var color := sun.light_color.srgb_to_linear()
	var radiance := Vector3(color.r, color.g, color.b) * sun.light_energy
	for cascade in 2:
		if captures[cascade].size() != 512*512*8:
			compute.release(); rd.free(); return {"error":"Incomplete HDR atlas"}
		var resolved := PackedFloat32Array()
		var directions := PackedFloat32Array()
		resolved.resize(64*64*64*4); directions.resize(resolved.size())
		for z in 64:
			for y in 64:
				for x in 64:
					var source_offset := ((z/8*64+y)*512+(z%8*64+x))*8
					var shadow := captures[cascade].decode_half(source_offset)
					var light_function := captures[cascade].decode_half(source_offset+2)
					var present := captures[cascade].decode_half(source_offset+4)
					if not is_finite(shadow) or not is_finite(light_function) or present != 1.0:
						compute.release(); rd.free(); return {"error":"Unresolved real sun input"}
					var contribution := shadow * light_function
					if cascade == 1:
						var uv := (Vector3(x,y,z)+Vector3.ONE*0.5)/64.0
						var faded := uv*(1.0+4.0/64.0)-Vector3.ONE*(2.0/64.0)
						var factors := ((Vector3.ONE*0.5-(faded-Vector3.ONE*0.5).abs())*10.0).clamp(Vector3.ZERO,Vector3.ONE)
						contribution = lerpf(1.0,contribution,factors.x*factors.y*factors.z)
					var index := ((z*64+y)*64+x)*4
					resolved[index] = radiance.x*contribution
					resolved[index+1] = radiance.y*contribution
					resolved[index+2] = radiance.z*contribution
					resolved[index+3] = contribution
					directions[index] = direction_ue.x
					directions[index+1] = direction_ue.y
					directions[index+2] = direction_ue.z
		FileAccess.open(output.path_join("cascade"+str(cascade)+"-resolved.f32"),FileAccess.WRITE).store_buffer(resolved.to_byte_array())
		FileAccess.open(output.path_join("cascade"+str(cascade)+"-directions.f32"),FileAccess.WRITE).store_buffer(directions.to_byte_array())
		compute.clear()
		error = compute.inject(resolved.to_byte_array(),directions.to_byte_array())
		if not error.is_empty(): compute.release(); rd.free(); return {"error":error}
		compute.filter()
		rd.submit(); rd.sync()
		if rd.buffer_get_data(compute.validation).decode_u32(0) != 0:
			compute.release(); rd.free(); return {"error":"GPU rejected input"}
		for i in 2:
			FileAccess.open(output.path_join("cascade"+str(cascade)+"-raw-"+["ambient","directional"][i]+".rgba16f"),FileAccess.WRITE).store_buffer(rd.texture_get_data(compute.volumes[i],0))
		var pair: Dictionary = {}
		for i in 2:
			var bytes := rd.texture_get_data(compute.volumes[2+i],0)
			if bytes.size() != 64*64*64*8:
				compute.release(); rd.free(); return {"error":"Incomplete filtered GPU volume"}
			var images: Array[Image] = []
			for z in 64:
				images.append(Image.create_from_data(64,64,false,Image.FORMAT_RGBAH,bytes.slice(z*64*64*8,(z+1)*64*64*8)))
			var texture := ImageTexture3D.new()
			var result := texture.create(Image.FORMAT_RGBAH,64,64,64,false,images)
			if result != OK: compute.release(); rd.free(); return {"error":"Texture upload failed"}
			var readback := texture.get_data()
			if readback.size() != 64:
				compute.release(); rd.free(); return {"error":"Texture3D upload slice count mismatch"}
			for z in 64:
				if readback[z].get_data() != images[z].get_data():
					compute.release(); rd.free(); return {"error":"Texture3D upload changed volume bytes"}
			var key: String = ["ambient","directional"][i]
			uploads.append({"cascade":cascade,"volume":key,"slices":64,"byte_exact":true})
			pair[key] = texture
			FileAccess.open(output.path_join("cascade"+str(cascade)+"-filtered-"+key+".rgba16f"),FileAccess.WRITE).store_buffer(bytes)
		textures.append(pair)
	compute.release(); rd.free()
	return {"textures":textures,"uploads":uploads,"source_energy_over_pi":sun.light_energy,"linear_color":str(color),"direction_ue":str(direction_ue)}
