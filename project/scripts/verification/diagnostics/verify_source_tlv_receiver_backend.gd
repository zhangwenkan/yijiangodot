extends "res://scripts/verification/verify_source_tlv_receiver.gd"
## Same frozen receiver diagnostic, with strict actual-backend observations.
var expected_backend := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--diagnostic-driver="):
			expected_backend = arg.trim_prefix("--diagnostic-driver=")
	super._initialize()

func observe_backend(stage: String) -> bool:
	var actual := RenderingServer.get_current_rendering_driver_name()
	var method := RenderingServer.get_current_rendering_method()
	var valid := expected_backend in ["d3d12", "vulkan"] and actual == expected_backend and method == "forward_plus"
	if not report.has("backend_observations"):
		report.backend_observations = []
	report.backend_observations.append({"stage":stage,"expected":expected_backend,"actual":actual,"method":method,"passed":valid})
	check(valid, "Unexpected rendering backend at " + stage + ": " + actual + "/" + method)
	return valid

func progress(stage: String) -> void:
	observe_backend(stage)
	super.progress(stage)

func run() -> void:
	if not observe_backend("before-scene"):
		if not out.is_empty():
			DirAccess.make_dir_recursive_absolute(out)
			super.progress("backend-rejected")
		quit(2)
		return
	await super.run()
