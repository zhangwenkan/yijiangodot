extends SceneTree
## Offline local-device compute: separate from the running playable scene.
var out := ""
var inputs := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tlv-out="): out = arg.trim_prefix("--tlv-out=")
		if arg.begins_with("--tlv-input="): inputs = arg.trim_prefix("--tlv-input=")
	call_deferred("run")

func run() -> void:
	if out.is_empty() or inputs.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	var report := {"cases":[], "failures":[], "scope":"Resolved real-map sun inputs -> half SH accumulation -> 8tap filtered RGBA16F volumes. No production replacement."}
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(inputs.path_join("manifest.json")))
	var rd := RenderingServer.create_local_rendering_device()
	var compute := preload("res://source_tlv_candidate/volume_compute.gd").new()
	var error := compute.initialize(rd,"res://source_tlv_candidate")
	if not error.is_empty():
		report.failures.append(error)
	else:
		for item in manifest.cases:
			var folder: String = out.path_join("cases").path_join(item.name)
			DirAccess.make_dir_recursive_absolute(folder)
			compute.clear()
			for light in item.lights:
				error = compute.inject(FileAccess.get_file_as_bytes(inputs.path_join(light.resolved)),FileAccess.get_file_as_bytes(inputs.path_join(light.direction)))
				if not error.is_empty(): report.failures.append(item.name+": "+error)
			compute.filter()
			rd.submit()
			rd.sync()
			var status := rd.buffer_get_data(compute.validation)
			if status.decode_u32(0) != 0: report.failures.append(item.name+": invalid GPU input")
			for i in 4:
				FileAccess.open(folder.path_join(["ambient", "directional", "filtered-ambient", "filtered-directional"][i]+".rgba16f"),FileAccess.WRITE).store_buffer(rd.texture_get_data(compute.volumes[i],0))
			report.cases.append(item.name)
			print("TLV_COMPUTE_CASE ", item.name)
	compute.release()
	rd.free()
	FileAccess.open(out.path_join("compute.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	quit(0 if report.failures.is_empty() else 1)
