extends Node
## Quick look at a level: which way each enemy type goes from each gate, how long it takes and how,
## then a picture from every camera spot. Run with --level=<id> --levelcheck=<folder>.

const MODES := ["走", "爬", "船", "搭桥", "终点", "桥", "隧道"]


func run(main: Node3D, dir: String) -> void:
	for n in 10:
		await get_tree().process_frame
	var paths: Node = main.paths
	var core = paths.core
	var terrain = main.terrain
	var ids: Array = paths.type_index.keys()
	var flat := PackedFloat32Array()
	for id: String in ids:
		flat.append(float(paths.type_index[id]))
	core.set_active_types(flat, flat.size())
	core.set_terrain(terrain.heights, terrain.route_water_mask(), terrain.RES, terrain.SIZE, terrain.WATER_LEVEL)
	core.solve(paths.home.x, paths.home.y, paths.goal_radius)
	print("CHECK level ", main.level_id, " bridge candidates ", core.bridges().size())
	for gate: Dictionary in paths.gates:
		var point: Vector2 = gate["point"]
		print("CHECK gate ", gate["name"], " ground ", snappedf(terrain.height_at(point.x, point.y), 0.1))
		for id: String in ids:
			var type: int = paths.type_index[id]
			var points: PackedFloat32Array = core.trace(type, point.x, point.y)
			var time: float = core.cost_at(type, point.x, point.y)
			print("CHECK   %s %s 秒 %s | %s" % [id, "无路" if time > 1e8 else str(int(time)), terrain.shape.describe_route(points), _modes(points)])
			if "--trace" in OS.get_cmdline_user_args():
				print("CHECK     path ", _waypoints(points))
	if dir != "":
		main._capture(dir, PackedStringArray(main.view_order))
	else:
		get_tree().quit()


## Metres travelled in each mode along a trace.
func _modes(points: PackedFloat32Array) -> String:
	var totals := {}
	for n in range(0, points.size() - 4, 4):
		var from := Vector3(points[n], points[n + 1], points[n + 2])
		var to := Vector3(points[n + 4], points[n + 5], points[n + 6])
		var mode := int(points[n + 3])
		totals[mode] = totals.get(mode, 0.0) + from.distance_to(to)
	var parts: Array[String] = []
	for mode: int in totals:
		parts.append("%s %d 米" % [MODES[mode] if mode < MODES.size() else str(mode), int(totals[mode])])
	return "，".join(parts)


## Every few metres of a trace as x,z,height and the mode's first letter, to see where a route really goes.
func _waypoints(points: PackedFloat32Array) -> String:
	var parts: Array[String] = []
	var last := Vector2(INF, INF)
	for n in range(0, points.size(), 4):
		var at := Vector2(points[n], points[n + 2])
		if at.distance_to(last) < 8.0 and n + 4 < points.size():
			continue
		last = at
		var mode := int(points[n + 3])
		parts.append("%d,%d,%d%s" % [int(at.x), int(at.y), int(points[n + 1]), MODES[mode] if mode < MODES.size() else str(mode)])
	return " ".join(parts)


## --watch=x,z[,dist]: plays the first wave with no towers and saves a picture every few seconds
## looking down at that spot, to see how enemies really look as they go by. Pictures go to the
## --levelcheck folder; --watchfrom= sets the first second to capture.
func watch(main: Node3D, dir: String, spec: String, from: float) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for n in 10:
		await get_tree().process_frame
	var paths: Node = main.paths
	var parts := spec.split(",")
	var at := Vector2(float(parts[0]), float(parts[1]))
	main.brush.hide_for_capture()
	main.ui.visible = false
	paths.route.visible = false
	main.target = Vector3(at.x, main.terrain.height_at(at.x, at.y) + 2.0, at.y)
	main.dist = float(parts[2]) if parts.size() > 2 else 60.0
	main.pitch = -38.0
	main.yaw = 0.5
	main._update_camera()
	paths.home_hp_max = 0
	paths.start_battle()
	paths.set_speed(paths.SPEEDS.size() - 1)
	while paths.sim_time < from and paths.phase == paths.Phase.BATTLE:
		await get_tree().process_frame
	paths.set_speed(0)
	for shot in 8:
		var next: float = paths.sim_time + 3.0
		while paths.sim_time < next and paths.phase == paths.Phase.BATTLE:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/watch_%d.png" % [dir, shot])
	get_tree().quit()


## Runs every wave with no towers and a home that cannot fall, so each unit's real path gets walked.
func play(main: Node3D) -> void:
	for n in 10:
		await get_tree().process_frame
	var paths: Node = main.paths
	paths.home_hp_max = 0
	paths.set_speed(paths.SPEEDS.size() - 1)
	for wave in paths.total_waves():
		var started: float = paths.sim_time
		var total: int = paths.wave_count(paths.next_wave())
		paths.start_battle()
		var limit := started + 900.0
		while paths.phase == paths.Phase.BATTLE and paths.sim_time < limit:
			await get_tree().process_frame
		var bridges: PackedFloat32Array = paths.core.bridges()
		print("PLAY wave %d: %d of %d arrived in %d s, %s, bridge data %d" % [wave + 1, paths.core.arrived(), total, int(paths.sim_time - started), "stuck %d" % paths.core.active() if paths.phase == paths.Phase.BATTLE else "done", bridges.size()])
		if paths.phase == paths.Phase.BATTLE:
			break
		for n in 5:
			await get_tree().process_frame
	get_tree().quit()


## --dam=x,z: raises a round plug of ground there, refreshes the water and reports the routes again.
func dam(main: Node3D, spec: String) -> void:
	for n in 10:
		await get_tree().process_frame
	var terrain = main.terrain
	var parts := spec.split(",")
	var at := Vector2(float(parts[0]), float(parts[1]))
	var before: int = terrain.water_cells.size()
	var half: float = terrain.SIZE * 0.5
	for j in terrain.RES:
		for i in terrain.RES:
			var p := Vector2(-half + float(i) * terrain.step, -half + float(j) * terrain.step)
			if p.distance_to(at) < 22.0:
				terrain.heights[j * terrain.RES + i] = maxf(terrain.heights[j * terrain.RES + i], 7.0)
	terrain.refresh_water()
	print("CHECK dam at %s: water cells %d -> %d" % [spec, before, terrain.water_cells.size()])
	run(main, "")


## --uishot=<file>: the game as the player first sees it, interface and all.
func ui_shot(_main: Node3D, path: String) -> void:
	await get_tree().create_timer(7.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
