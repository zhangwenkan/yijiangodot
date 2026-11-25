extends SceneTree
## Capture after source units and analytic height fog, without SH feedback.
var out := ""
var scene: Node3D
var summary: Array=[]
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lighting-report-dir="): out=arg.trim_prefix("--lighting-report-dir=")
	call_deferred("run")
func run() -> void:
	scene=load("res://worlds.tscn").instantiate()
	root.add_child(scene)
	while not is_instance_valid(scene.house_driver) or scene.loading: await process_frame
	for slug in ["wuming","youxian"]:
		if scene.slug!=slug: await scene._load_world(slug)
		scene.tour_finished=true
		scene.player.set_review_motion(Vector2.ZERO)
		var env: Environment=scene.world.find_children("*","WorldEnvironment",true,false)[0].environment
		var sun: DirectionalLight3D=scene.world.find_children("*","DirectionalLight3D",true,false)[0]
		sun.light_energy=30.0/PI
		var lights=load("res://source_lighting_candidate/original_local_light_calibration.gd").new()
		var light_report: Dictionary=lights.apply(scene.world,true,true)
		var fog=load("res://source_lighting_candidate/source_height_fog_adapter.gd").new()
		root.add_child(fog)
		var fog_report: Dictionary=fog.install(scene.world,env,"res://source_lighting_candidate/"+slug+"-height-fog.json",{})
		var capture=load("res://sky_capture_candidate/capture_source_sky.gd").new()
		root.add_child(capture)
		var result: Dictionary=await capture.capture(scene,scene.world,env,out.path_join(slug).path_join("capture"),128,Vector3.ZERO)
		summary.append({"map":slug,"source_sun":sun.light_energy,"lights":light_report,"fog":fog_report,"capture":result.report,"no_sh_installed":true})
		fog.restore()
		lights.restore()
		fog.queue_free()
		capture.queue_free()
		await process_frame
	FileAccess.open(out.path_join("summary.json"),FileAccess.WRITE).store_string(JSON.stringify(summary,"\t"))
	print("SOURCE_LIGHTING_CAPTURE_DONE maps=",summary.size())
	scene.queue_free()
	for i in 5: await process_frame
	quit()
