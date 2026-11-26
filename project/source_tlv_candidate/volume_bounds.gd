extends RefCounted
## Comparative UE source bounds. Values are source UE centimetres, not Godot metres.
static func ue(v: Vector3) -> Vector3: return Vector3(v.x, v.z, v.y)

static func from_camera(camera: Camera3D, aspect: float) -> Array[Dictionary]:
	var origin := ue(camera.global_position) * 100.0
	var forward := ue(-camera.global_basis.z).normalized()
	var right := ue(camera.global_basis.x).normalized()
	var up := ue(camera.global_basis.y).normalized()
	var half_fov := maxf(deg_to_rad(40.0 * 0.5), deg_to_rad(45.0))
	var snap := deg_to_rad(10.0)
	half_fov += snap - fmod(half_fov, snap)
	var output: Array[Dictionary] = []
	for limits in [Vector2(0, 1500), Vector2(1500, 5000)]:
		var corners: Array[Vector3] = []
		var center := Vector3.ZERO
		for distance in [limits.x, limits.y]:
			for sign_x in [-1.0, 1.0]:
				for sign_y in [-1.0, 1.0]:
					var p: Vector3 = origin + forward * distance + right * (sign_x * distance * tan(half_fov)) + up * (sign_y * distance * tan(half_fov) / aspect)
					corners.append(p)
					center += p * (1.0 / 44.0 if corners.size() <= 4 else 1.0 / 4.4)
		var radius := 0.0
		for p in corners: radius = maxf(radius, p.distance_to(center))
		var voxel := radius * 2.0 / 64.0
		center -= Vector3(fmod(center.x, voxel), fmod(center.y, voxel), fmod(center.z, voxel))
		output.append({"min_ue_cm":center - Vector3.ONE * radius, "center_ue_cm":center,
			"radius_cm":radius, "voxel_cm":voxel, "dimension":64, "half_fov_degrees":rad_to_deg(half_fov)})
	return output
