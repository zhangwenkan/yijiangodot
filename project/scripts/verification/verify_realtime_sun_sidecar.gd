extends SceneTree
## Explicit opt-in diagnostic only. Does not install into worlds.gd/launchers.
## Run first with receiver disabled; enable only after bridge numerical checks.
var out := ""
var wanted_driver := ""
var map_slug := "wuming"
var enable_receiver := false
var diagnostic_once := false
var scene: Node3D
var producer: Node
var report: Dictionary = {"failures":[],"phases":[],"scope":"Candidate runtime smoke/lifecycle; no UE/full-restoration or whole-map visual pass."}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tlv-out="): out=arg.trim_prefix("--tlv-out=")
		elif arg.begins_with("--diagnostic-driver="): wanted_driver=arg.trim_prefix("--diagnostic-driver=")
		elif arg.begins_with("--tlv-map="): map_slug=arg.trim_prefix("--tlv-map=")
		elif arg=="--enable-tlv-receiver": enable_receiver=true
		elif arg=="--diagnostic-once": diagnostic_once=true
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition: report.failures.append(message)

func save_report(stage: String) -> void:
	report.stage=stage
	if producer!=null: report.producer=producer.report
	FileAccess.open(out.path_join("realtime-sidecar.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("REALTIME_SUN_STAGE ",stage)

func wait_produced(target: int, budget: int = 180) -> bool:
	for frame in budget:
		await process_frame
		if int(producer.report.get("produced",0))>=target: return true
		if producer.report.get("status") in ["stopped","restore_conflict"]: return false
	return false

func run() -> void:
	if out.is_empty() or wanted_driver not in ["vulkan","d3d12"] or map_slug not in ["wuming","youxian"]: quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	check(RenderingServer.get_current_rendering_driver_name()==wanted_driver,"Requested driver not active.")
	check(RenderingServer.get_current_rendering_method()=="forward_plus","Expected Forward+.")
	if not report.failures.is_empty(): save_report("backend-rejected"); quit(1); return
	root.size=Vector2i(960,540)
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.source_renderer) or scene.loading: await process_frame
	scene.tour_finished=true
	if scene.slug!=map_slug: await scene._load_world(map_slug)
	for frame in 40: await process_frame
	producer=preload("res://source_tlv_realtime/realtime_sun.gd").new()
	root.add_child(producer)
	var options := {"enable_receiver":enable_receiver,"max_age_frames":8}
	if diagnostic_once: options.diagnostic_once_directory=out.path_join("single-pair")
	var installed: Dictionary = producer.install(scene,map_slug,options)
	check(installed.get("status")!="failed","Producer install failed: "+str(installed))
	if installed.get("status")=="failed": save_report("install-rejected"); quit(1); return
	save_report("installed")
	check(await wait_produced(4),"Four initial complete snapshots were not produced.")
	report.phases.append({"phase":"outdoor","produced":producer.report.get("produced",0),"last":producer.report.get("last_snapshot",{})})
	save_report("outdoor")
	if not report.failures.is_empty(): await shutdown(); return
	var prior := int(producer.report.produced)
	scene.house_driver.set_inside(true)
	check(producer._active.is_empty(),"House generation did not immediately invalidate active pair.")
	check(await wait_produced(prior+2),"Inside-state complete snapshots were not produced.")
	check(bool(producer._active.get("house_inside",false)),"Published pair is not the current inside state.")
	report.phases.append({"phase":"inside","produced":producer.report.produced,"last":producer.report.get("last_snapshot",{})})
	save_report("inside")
	prior=int(producer.report.produced)
	scene.house_driver.set_inside(false)
	check(producer._active.is_empty(),"Exit-house generation did not immediately invalidate pair.")
	check(await wait_produced(prior+2),"Outside-state pair after house exit was not produced.")
	check(not bool(producer._active.get("house_inside",true)),"Old inside pair escaped generation rejection.")
	report.phases.append({"phase":"outside-return","produced":producer.report.produced,"last":producer.report.get("last_snapshot",{})})
	await shutdown()

func shutdown() -> void:
	producer.stop("Sidecar diagnostic complete.")
	var closed := false
	for frame in 90:
		await process_frame
		var result: Dictionary = producer.drain_shutdown()
		if bool(result.closed): closed=true; break
	check(closed,"GPU shutdown did not acknowledge closed; resources may be quarantined.")
	check(producer.report.status=="stopped","Restore owner conflict.")
	save_report("complete")
	producer.queue_free()
	scene.queue_free()
	for frame in 5: await process_frame
	quit(0 if report.failures.is_empty() else 1)
