extends Node
## Looks at the battle effects up close: builds one tower of each kind beside the first route,
## plus a fire cannon, runs the first wave and saves a picture every few tenths of a second.
## Run with --level=<id> --fxtest=<folder>. Add --fxspeed=<index> to try a faster game speed.

var main: Node3D
var towers: Node
var paths: Node
var terrain


func run(main_node: Node3D, dir: String, args: Dictionary) -> void:
	main = main_node
	towers = main.towers
	paths = main.paths
	terrain = main.terrain
	DirAccess.make_dir_recursive_absolute(dir)
	for n in 10:
		await get_tree().process_frame
	main.brush.money = 99999.0
	var route: PackedFloat32Array = paths.route_points
	var count := route.size() / 4
	# A stretch about two thirds of the way along the first route, where the enemies will be.
	var mid := count * 2 / 3
	var focus := Vector3(route[mid * 4], route[mid * 4 + 1], route[mid * 4 + 2])
	var ahead := Vector3(route[(mid + 1) * 4], 0.0, route[(mid + 1) * 4 + 2]) - Vector3(focus.x, 0.0, focus.z)
	var side := ahead.normalized().cross(Vector3.UP)
	var plan := [["normal", -1.0, 16.0, []], ["catapult", 1.0, 24.0, []], ["sniper", 1.0, 13.0, []], ["normal", -1.0, 26.0, ["scatter", "blaze"]]]
	var along := -12.0
	for item: Array in plan:
		towers.place_type = item[0]
		var placed := false
		for tries in 30:
			var spot: Vector3 = focus + side * float(item[1]) * (float(item[2]) + float(tries)) + ahead.normalized() * along
			if towers.place_at(spot.x, spot.z, 0.0, 0.0, false):
				placed = true
				break
		along += 12.0
		if not placed:
			print("FX could not place ", item[0])
			continue
		var tower: Dictionary = towers.towers[towers.towers.size() - 1]
		var aim: PackedFloat32Array = paths.core.tower_best_aim(tower["id"])
		if aim.size() == 3:
			var direction := Vector3(aim[0], aim[1], aim[2])
			towers._set_tower_aim(tower, atan2(direction.x, direction.z), asin(clampf(direction.y, -1.0, 1.0)))
		towers.select(tower)
		for id: String in item[3]:
			towers.upgrade_selected(id)
		towers.deselect()
		print("FX placed %s at %s" % [item[0], tower["center"]])
	# --fxmany=N adds N more towers along the route, to see how the frame rate holds up.
	var extra := int(args.get("fxmany", "0"))
	var kinds := ["normal", "catapult", "sniper"]
	var step := 0
	while extra > 0 and step < 400:
		var n := clampi(mid - 40 + (step * 7) % 80, 0, count - 1)
		var flank := 1.0 if step % 2 == 0 else -1.0
		var spot := Vector3(route[n * 4], 0.0, route[n * 4 + 2]) + side * flank * (12.0 + float(step % 5) * 4.0)
		towers.place_type = kinds[step % 3]
		if towers.place_at(spot.x, spot.z, 0.0, 0.0, false):
			var t: Dictionary = towers.towers[towers.towers.size() - 1]
			var a: PackedFloat32Array = paths.core.tower_best_aim(t["id"])
			if a.size() == 3:
				towers._set_tower_aim(t, atan2(a[0], a[2]), asin(clampf(a[1], -1.0, 1.0)))
			extra -= 1
		step += 1
	print("FX towers %d after %d tries" % [towers.towers.size(), step])
	if args.has("fxnotrees"):
		for tree: Node3D in main.tree_nodes:
			tree.visible = false
	main.brush.hide_for_capture()
	main.ui.visible = false
	var middle := focus
	for tower: Dictionary in towers.towers:
		middle += tower["center"]
	middle /= float(towers.towers.size() + 1)
	main.target = middle + Vector3.UP * 3.0
	main.dist = float(args.get("fxdist", "85"))
	main.pitch = float(args.get("fxpitch", "-52"))
	main.yaw = atan2(side.x, side.z) + float(args.get("fxyaw", "0.4"))
	main._update_camera()
	paths.set_speed(int(args.get("fxspeed", "0")))
	# Its own wave from the first gate, so the enemies walk the route the towers stand beside.
	# Starting a little way up the route, so the enemies walk straight past the towers.
	var back := maxi(mid - int(args.get("fxback", "25")), 0)
	var gate := Vector2(route[back * 4], route[back * 4 + 2])
	paths.phase = paths.Phase.BATTLE
	main.brush.locked = true
	paths.route.visible = false
	paths.core.begin_wave()
	paths.core.add_group(paths.type_index[String(args.get("fxenemy", "walker"))], gate.x, gate.y, int(args.get("fxcount", "40")), 0.7, 0.0)
	paths.core.finish_wave()
	paths._wave_started(int(args.get("fxcount", "40")))
	# Fast-forward until the enemies reach the towers, then watch at the chosen speed.
	paths.set_speed(3)
	while paths.sim_time < float(args.get("fxwait", "4")) and paths.phase == paths.Phase.BATTLE:
		await get_tree().process_frame
	paths.set_speed(int(args.get("fxspeed", "0")))
	var saved := 0
	var next_shot := 0.0
	var frames := 0
	var frame_time := 0.0
	var worst := 0.0
	while paths.phase == paths.Phase.BATTLE and saved < 14 and paths.sim_time < 240.0:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		if true:
			frames += 1
			frame_time += dt
			worst = maxf(worst, dt)
		if frames % 300 == 0:
			print("FX at %.0f s: %.0f fps, kills %d, active %d" % [paths.sim_time, Engine.get_frames_per_second(), paths.core.kills(), paths.core.active()])
		if paths.sim_time >= next_shot:
			next_shot = paths.sim_time + float(args.get("fxevery", "0.35")) * paths.speed
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s/fx_%02d.png" % [dir, saved])
			saved += 1
	print("FX kills %d, frames %d, average %.1f fps, slowest frame %.1f ms" % [paths.core.kills(), frames, frames / maxf(frame_time, 0.001), worst * 1000.0])
	get_tree().quit()


## --fxdemo=<folder>: plays every impact and launch on open ground in front of the camera, no battle.
func demo(main_node: Node3D, dir: String, args: Dictionary) -> void:
	main = main_node
	paths = main.paths
	terrain = main.terrain
	DirAccess.make_dir_recursive_absolute(dir)
	for n in 10:
		await get_tree().process_frame
	for tree: Node3D in main.tree_nodes:
		tree.visible = false
	main.brush.hide_for_capture()
	main.ui.visible = false
	var at := Vector3(float(args.get("fxx", "0")), 0.0, float(args.get("fxz", "60")))
	at.y = terrain.height_at(at.x, at.z)
	main.target = at + Vector3.UP * 2.0
	main.dist = float(args.get("fxdist", "45"))
	main.pitch = float(args.get("fxpitch", "-28"))
	main.yaw = float(args.get("fxyaw", "0.3"))
	main._update_camera()
	await get_tree().create_timer(2.0).timeout
	var fx = paths.fx
	var plays := [
		["cannon", 5.0, 0], ["cannon_blaze", 7.0, 1], ["catapult", 6.0, 0], ["sniper", 0.0, 0], ["quake", 3.5, 2], ["death", 0.0, 0], ["upgrade", 0.0, 0], ["launch", 0.0, 0],
	]
	var styles := {"cannon": "cannon", "cannon_blaze": "cannon", "catapult": "catapult", "sniper": "sniper", "quake": "cannon"}
	for play: Array in plays:
		var name_text: String = play[0]
		for wait in [0.06, 0.18, 0.5]:
			var ground := at + Vector3(0.0, 1.1, 0.0)
			if name_text == "death":
				fx.died(at, Color(0.8, 0.5, 0.4).srgb_to_linear())
			elif name_text == "upgrade":
				fx.upgraded(at + Vector3.UP * 6.0)
			elif name_text == "launch":
				fx.tower_styles[901] = "cannon"
				fx.tower_styles[902] = "sniper"
				fx.tower_styles[903] = "catapult"
				fx.launched(901, at + Vector3(-8.0, 9.0, 0.0), at + Vector3(20.0, 1.0, 30.0))
				fx.launched(902, at + Vector3(0.0, 9.0, 0.0), at + Vector3(10.0, 1.0, -40.0))
				fx.launched(903, at + Vector3(8.0, 6.0, 0.0), at + Vector3(20.0, 1.0, 30.0))
			else:
				fx.tower_styles[900] = styles[name_text]
				fx.impact(900, ground, play[1], play[2])
			# Let it play for a moment, in real time, then capture.
			var until := Time.get_ticks_msec() + int(wait * 1000.0)
			while Time.get_ticks_msec() < until:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s/%s_%d.png" % [dir, name_text, int(wait * 100.0)])
			await get_tree().create_timer(1.6).timeout
	get_tree().quit()
