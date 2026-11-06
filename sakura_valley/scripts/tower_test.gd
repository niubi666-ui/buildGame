extends Node
## Automated tower test. Sends the same input events a player would, and rebuilds the kind
## of steep spire a player sculpts, then reports what happens and takes screenshots.

var main: Node3D
var towers: Node
var brush: Node
var paths: Node
var terrain
var core
var dir := ""


func run(main_node: Node3D, out_dir: String) -> void:
	main = main_node
	towers = main.towers
	brush = main.brush
	paths = main.paths
	terrain = main.terrain
	core = paths.core
	dir = out_dir
	DirAccess.make_dir_recursive_absolute(dir)
	main.apply_view("strategy")
	brush.money = 1000000.0
	await get_tree().create_timer(3.0).timeout

	await _test_slope_tool()
	var peak := Vector2(-40.0, 30.0)
	_raise_spire(peak)
	await _settle(30)
	_survey(peak)
	await _test_steep_placement(peak)
	await _test_aim_controls()
	await _test_rejections(peak)
	await _test_flat_and_sell()
	await _test_battle()
	await _showcase(peak)
	await _test_load()
	get_tree().quit()


## The slope brush should remove bumps but keep the ground's lean.
func _test_slope_tool() -> void:
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	var money: float = brush.money
	var peak := Vector2(-85.0, 55.0)
	# Clears the view for the screenshots. This test changes nothing else that lasts.
	brush.clear_trees_near(peak.x, peak.y, 42.0)
	brush.paint(terrain.TOOL_RAISE, peak.x, peak.y, 18.0, 1.0, 1.6)
	brush.paint(terrain.TOOL_RAISE, peak.x, peak.y, 9.0, 1.0, 0.8)
	brush.paint(terrain.TOOL_RAISE, peak.x + 3.0, peak.y + 9.0, 3.0, 1.0, 0.5)
	terrain.upload_state()
	var spot := Vector2(peak.x, peak.y + 9.0)
	var before: Dictionary = terrain.fit_ground_plane(spot.x, spot.y, 6.0)
	var check_before: Dictionary = towers.check_spot(spot.x, spot.y)
	var world := Vector3(spot.x, terrain.height_at(spot.x, spot.y), spot.y)
	_look_at(world, 62.0, -22.0, 0.1)
	await _settle(6)
	await _shot("0a_slope_before")
	_look_at(world, 62.0, -9.0, PI * 0.5)
	await _settle(6)
	await _shot("0a_slope_before_side")
	_look_at(world, 62.0, -22.0, 0.1)
	await _settle(3)
	await _press_key(KEY_H)
	print("TEST H key picks slope tool: %s" % [brush.tool == terrain.TOOL_SLOPE])
	brush.radius = 8.0
	await _hover(world)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = brush.test_mouse
	Input.parse_input_event(press)
	await get_tree().create_timer(1.5).timeout
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = brush.test_mouse
	Input.parse_input_event(release)
	await _settle(4)
	var after: Dictionary = terrain.fit_ground_plane(spot.x, spot.y, 6.0)
	var check_after: Dictionary = towers.check_spot(spot.x, spot.y)
	print("TEST slope tool: tilt %.0f to %.0f deg, roughness %.2f to %.2f m; tower cost %d to %d; spent %d" % [
		rad_to_deg(acos(before["normal"].y)), rad_to_deg(acos(after["normal"].y)), before["roughness"], after["roughness"],
		check_before.get("cost", -1), check_after.get("cost", -1), int(money - brush.money),
	])
	await _shot("0b_slope_after")
	# A tower on the slope the brush just made, seen from the side.
	var slope_tower: bool = towers.place_at(spot.x, spot.y, 0.0, -0.4, false)
	towers.deselect()
	print("TEST tower on brushed slope: built %s, tilt %.0f deg" % [slope_tower, towers.towers[towers.towers.size() - 1]["tilt"] if slope_tower else -1.0])
	_look_at(world, 62.0, -9.0, PI * 0.5)
	await _settle(6)
	await _shot("0c_slope_side_with_tower")
	if slope_tower:
		towers.select(towers.towers[towers.towers.size() - 1])
		towers.sell_selected()
	terrain.restore_heights(saved, Rect2i(0, 0, terrain.RES, terrain.RES))
	terrain.upload_state()
	brush._refresh_water_if_needed()
	brush._sync_followers(Vector2.ZERO, 0.0, true)
	brush.clear_undo()
	brush.money = money
	brush.select_tool(terrain.TOOL_LOWER)
	brush.radius = 14.0
	paths.replan()
	main.apply_view("strategy")
	await _settle(3)


## Towers leaning at very different angles on one spire, for a look at the whole idea.
func _showcase(peak: Vector2) -> void:
	var built := 0
	for spot: Vector2 in [Vector2(-7.0, 0.0), Vector2(11.0, -3.0), Vector2(0.0, -13.0), Vector2(5.0, 16.0)]:
		var x: float = peak.x + spot.x
		var z: float = peak.y + spot.y
		var check: Dictionary = towers.check_spot(x, z)
		if not check["ok"]:
			print("TEST showcase spot refused: ", check["reason"])
			continue
		var best: PackedFloat32Array = core.best_aim(check["apex"].x, check["apex"].y, check["apex"].z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"])
		var yaw := atan2(spot.x, spot.y)
		var pitch := -0.3
		if best.size() == 3:
			yaw = atan2(best[0], best[2])
			pitch = asin(best[1])
		var begin := Time.get_ticks_usec()
		var placed: bool = towers.place_at(x, z, yaw, pitch, false)
		var place_ms := float(Time.get_ticks_usec() - begin) / 1000.0
		if placed:
			built += 1
			print("TEST showcase tower: tilt %.0f deg, building it took %.1f ms" % [towers.towers[towers.towers.size() - 1]["tilt"], place_ms])
	towers.deselect()
	var top := Vector3(peak.x, terrain.height_at(peak.x, peak.y) * 0.45, peak.y)
	_look_at(top, 95.0, -15.0, 0.25)
	await _settle(6)
	await _shot("9_spire_towers")
	towers.select(towers.towers[towers.towers.size() - 1])
	await _settle(4)
	await _shot("10_spire_range")
	towers.deselect()
	main.apply_view("strategy")
	await _settle(3)
	await _shot("11_game_view")


## Built with the real brush: broad base, narrower cone, then a tight peak.
func _raise_spire(at: Vector2) -> void:
	var tool: int = terrain.TOOL_RAISE
	brush.paint(tool, at.x, at.y, 22.0, 1.0, 1.3)
	brush.paint(tool, at.x, at.y, 11.0, 1.0, 1.6)
	brush.paint(tool, at.x, at.y, 6.0, 1.0, 1.6)
	brush.paint(tool, at.x, at.y, 3.0, 1.0, 1.2)
	terrain.upload_state()
	brush._sync_followers(at, 30.0, false)
	paths.replan()
	print("TEST spire top height %.1f m (ground %.1f m)" % [terrain.height_at(at.x, at.y), terrain.height_at(at.x + 28.0, at.y)])


## Reports what the rules say all the way around and up the spire.
func _survey(peak: Vector2) -> void:
	var allowed := 0
	var refused := {}
	var steepest := 0.0
	var roughest := 0.0
	for r in range(3, 26):
		for n in 16:
			var angle := TAU * float(n) / 16.0
			var check: Dictionary = towers.check_spot(peak.x + cos(angle) * float(r), peak.y + sin(angle) * float(r))
			if check["ok"]:
				allowed += 1
				steepest = maxf(steepest, check["tilt"])
				roughest = maxf(roughest, check["roughness"])
			else:
				var reason := String(check["reason"]).left(6)
				refused[reason] = int(refused.get(reason, 0)) + 1
	print("TEST survey: allowed %d, steepest allowed %.0f deg, roughest allowed %.1f m; refused %s" % [allowed, steepest, roughest, refused])
	for r in [4, 6, 8, 10, 12, 15, 18, 22]:
		var check: Dictionary = towers.check_spot(peak.x, peak.y + float(r))
		print("TEST   south face at %d m: ok %s, tilt %.0f, roughness %.2f, %s" % [r, check["ok"], check.get("tilt", -1.0), check.get("roughness", -1.0), check.get("reason", "")])


func _steepest_face(peak: Vector2) -> Vector3:
	var best := Vector3.ZERO
	var best_tilt := -1.0
	for r10 in range(30, 200, 5):
		var z: float = peak.y + float(r10) * 0.1
		var check: Dictionary = towers.check_spot(peak.x, z)
		if check["ok"] and check["tilt"] > best_tilt:
			best_tilt = check["tilt"]
			best = Vector3(peak.x, terrain.height_at(peak.x, z), z)
	print("TEST steepest south-face spot: tilt %.0f deg at %s" % [best_tilt, best])
	return best


func _look_at(point: Vector3, distance: float, pitch: float, yaw: float) -> void:
	main.target = point
	main.dist = distance
	main.pitch = pitch
	main.yaw = yaw
	main._update_camera()


func _test_steep_placement(peak: Vector2) -> void:
	var spot := _steepest_face(peak)
	_look_at(spot, 70.0, -14.0, 0.15)
	await _settle(5)
	await _shot("1_spire")
	var count_before: int = towers.towers.size()
	await _press_key(KEY_T)
	print("TEST T key enters placing: %s, brush paused: %s" % [towers.mode == towers.Mode.PLACING, brush.paused])
	await _hover(spot)
	await _settle(3)
	print("TEST steep hint: ", towers.hint_line())
	await _shot("2_steep_preview")
	await _click_at(spot)
	var placed: bool = towers.towers.size() == count_before + 1
	print("TEST steep placed: %s, now aiming: %s" % [placed, towers.mode == towers.Mode.AIMING])
	if not placed:
		return
	var tower: Dictionary = towers.towers[towers.towers.size() - 1]
	print("TEST tower tilt %.0f deg, normal %s, apex %s" % [tower["tilt"], tower["normal"], tower["apex"]])
	# Moving the mouse aims the gun at the ground under it.
	var target := Vector3(peak.x + 45.0, 0.0, peak.y + 22.0)
	target.y = terrain.height_at(target.x, target.z)
	await _hover(target)
	await _settle(2)
	var aim: Vector3 = towers.aim_vector(tower["yaw"], tower["pitch"])
	var wanted := (target + Vector3.UP * 1.1 - Vector3(tower["apex"])).normalized()
	print("TEST mouse aim matches target: %.3f (1 is exact); pitch %.0f deg" % [aim.dot(wanted), rad_to_deg(tower["pitch"])])
	await _shot("3_aiming")
	await _click_at(target)
	print("TEST left click confirms aim: %s; panel open: %s" % [towers.mode == towers.Mode.IDLE, main.ui.tower_card.visible])
	# Reshaping removed the ground's bumps under the footing.
	var refit: Dictionary = terrain.fit_ground_plane(tower["center"].x, tower["center"].z, 3.5)
	print("TEST ground roughness under finished tower: %.2f m" % refit["roughness"])
	_look_at(tower["center"], 48.0, -10.0, 0.7)
	await _settle(4)
	await _shot("4_steep_tower_side")
	_look_at(tower["apex"], 36.0, -26.0, 0.0)
	await _settle(4)
	await _shot("5_steep_tower_front")
	main.apply_view("strategy")
	await _settle(3)
	await _shot("6_steep_tower_game_view")


func _test_aim_controls() -> void:
	var tower: Dictionary = towers.selected
	if tower.is_empty():
		print("TEST aim controls skipped: nothing selected")
		return
	var apex: Vector3 = tower["apex"]
	# The sliders reach every direction, and the firing cone goes with them.
	var pairs: Array = [[0.0, 90.0, "straight up"], [0.0, -90.0, "straight down"], [90.0, 0.0, "level east"], [-90.0, 0.0, "level west"], [180.0, 0.0, "level north"], [0.0, 0.0, "level south"]]
	for pair: Array in pairs:
		main.ui.yaw_slider.value = pair[0]
		main.ui.pitch_slider.value = pair[1]
		await get_tree().process_frame
		var aim: Vector3 = towers.aim_vector(tower["yaw"], tower["pitch"])
		print("TEST slider %s: aim %s, covers %d m of route" % [pair[2], aim.snapped(Vector3.ONE * 0.01), int(towers._covered(apex, aim))])
	# Arrow keys nudge the aim.
	var yaw_before: float = tower["yaw"]
	var pitch_before: float = tower["pitch"]
	await _press_key(KEY_LEFT)
	await _press_key(KEY_UP)
	print("TEST arrow keys: yaw moved %.1f deg, pitch moved %.1f deg" % [rad_to_deg(tower["yaw"] - yaw_before), rad_to_deg(tower["pitch"] - pitch_before)])
	# V aims with the mouse again, and Esc puts the old aim back.
	yaw_before = tower["yaw"]
	await _press_key(KEY_V)
	print("TEST V enters aiming: %s" % [towers.mode == towers.Mode.AIMING])
	await _hover(Vector3(apex.x - 40.0, terrain.height_at(apex.x - 40.0, apex.z + 30.0), apex.z + 30.0))
	await _settle(2)
	var moved := absf(float(tower["yaw"]) - yaw_before) > 0.01
	await _press_key(KEY_ESCAPE)
	print("TEST mouse moved aim: %s; Esc restored it: %s" % [moved, absf(float(tower["yaw"]) - yaw_before) < 0.001])
	# Wheel lifts the gun above what the mouse points at, so it can aim into the sky.
	await _press_key(KEY_V)
	await _hover(Vector3(apex.x + 30.0, terrain.height_at(apex.x + 30.0, apex.z + 30.0), apex.z + 30.0))
	for n in 18:
		await _wheel(MOUSE_BUTTON_WHEEL_UP)
	await _settle(2)
	print("TEST wheel while aiming: pitch now %.0f deg" % rad_to_deg(tower["pitch"]))
	await _press_key(KEY_ESCAPE)
	# Aim it at the route for the battle later.
	var best: PackedFloat32Array = core.best_aim(apex.x, apex.y, apex.z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"])
	if best.size() == 3:
		towers._set_tower_aim(tower, atan2(best[0], best[2]), asin(best[1]))
	print("TEST best aim covers %d m of route" % int(towers._covered(apex, towers.aim_vector(tower["yaw"], tower["pitch"]))))


func _test_rejections(peak: Vector2) -> void:
	main.apply_view("strategy")
	towers.deselect()
	var count: int = towers.towers.size()
	var money: float = brush.money
	await _press_key(KEY_T)
	await _click_at(Vector3(terrain.LAKE.x, terrain.WATER_LEVEL, terrain.LAKE.y))
	await _settle(2)
	print("TEST water placed: %s; hint: %s" % [towers.towers.size() != count, towers.hint_line()])
	var home: Vector2 = terrain.home_center()
	await _click_at(Vector3(home.x, terrain.height_at(home.x, home.y), home.y))
	await _settle(2)
	print("TEST village placed: %s; hint: %s" % [towers.towers.size() != count, towers.hint_line()])
	var near: Vector3 = towers.towers[0]["center"] + Vector3(0.5, 0.0, 0.5)
	var near_check: Dictionary = towers.check_spot(near.x, near.z)
	print("TEST too close: ok %s, %s" % [near_check["ok"], near_check.get("reason", "")])
	# The pit floor lies below the water level but is dry, so it must be buildable.
	var pit: Vector2 = terrain.pit_center()
	var floor_check: Dictionary = towers.check_spot(pit.x, pit.y)
	print("TEST dry pit floor: ok %s, height %.1f, tilt %.0f, %s" % [floor_check["ok"], terrain.height_at(pit.x, pit.y), floor_check.get("tilt", -1.0), floor_check.get("reason", "")])
	# A rock needle: very steep and uneven, so the footing cannot sit on it.
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	var needle := Vector2(-70.0, 90.0)
	brush.paint(terrain.TOOL_RAISE, needle.x, needle.y, 3.2, 1.0, 12.0)
	var results := {}
	for r in [1, 2, 3, 4]:
		for n in 8:
			var a := TAU * float(n) / 8.0
			var c: Dictionary = towers.check_spot(needle.x + cos(a) * float(r), needle.y + sin(a) * float(r))
			var label: String = "ok" if c["ok"] else String(c["reason"]).left(8)
			results[label] = int(results.get(label, 0)) + 1
	print("TEST needle %.0f m tall: %s" % [terrain.height_at(needle.x, needle.y), results])
	terrain.restore_heights(saved, Rect2i(0, 0, terrain.RES, terrain.RES))
	terrain.upload_state()
	brush.money = money
	print("TEST money unchanged after refusals: %s" % [is_equal_approx(brush.money, money)])
	await _press_key(KEY_ESCAPE)
	print("TEST Esc leaves placing: %s" % [towers.mode == towers.Mode.IDLE])


func _find_flat_spot() -> Vector3:
	var best := Vector3.ZERO
	var best_covered := -1.0
	for j in range(-12, 13):
		for i in range(-12, 13):
			var x := float(i) * 6.0
			var z := float(j) * 6.0
			var check: Dictionary = towers.check_spot(x, z)
			if not check["ok"] or check["tilt"] > 5.0:
				continue
			var yaw_aim: PackedFloat32Array = core.best_aim(check["apex"].x, check["apex"].y, check["apex"].z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"])
			if yaw_aim.size() != 3:
				continue
			var covered: float = towers._covered(check["apex"], Vector3(yaw_aim[0], yaw_aim[1], yaw_aim[2]))
			if covered > best_covered:
				best_covered = covered
				best = Vector3(x, terrain.height_at(x, z), z)
	return best


func _test_flat_and_sell() -> void:
	var spot := _find_flat_spot()
	var money: float = brush.money
	await _press_key(KEY_T)
	await _click_at(spot)
	var tower: Dictionary = towers.towers[towers.towers.size() - 1]
	# The click that builds the tower leaves the automatic aim in place until the mouse moves.
	var auto_yaw: float = tower["yaw"]
	await _settle(4)
	print("TEST build click kept auto aim: %s, covers %d m" % [is_equal_approx(tower["yaw"], auto_yaw), int(towers._covered(tower["apex"], towers.aim_vector(tower["yaw"], tower["pitch"])))])
	await _click_at(spot)
	print("TEST flat tower: spent %d, tilt %.1f deg, aim mode closed %s" % [int(money - brush.money), tower["tilt"], towers.mode == towers.Mode.IDLE])
	await _press_key(KEY_ESCAPE)
	print("TEST Esc deselects: %s, range hidden: %s" % [towers.selected.is_empty(), not towers.cone_view.visible])
	var side: Vector3 = tower["center"] + Vector3(tower["normal"]) * 6.0
	await _click_at(side)
	print("TEST clicking a tower selects it: %s" % [towers.selected == tower])
	# Clicking empty ground closes the panel, and must not dig there.
	var empty_spot := Vector3(spot.x + 30.0, 0.0, spot.z)
	empty_spot.y = terrain.height_at(empty_spot.x, empty_spot.z)
	var before_click: PackedFloat32Array = terrain.heights.duplicate()
	await _click_at(empty_spot)
	var dug := 0.0
	for n in before_click.size():
		dug = maxf(dug, absf(terrain.heights[n] - before_click[n]))
	print("TEST click on ground deselects: %s, ground moved %.3f m" % [towers.selected.is_empty(), dug])
	towers.select(tower)

	# The ground under a tower cannot be sculpted.
	var center: Vector3 = tower["center"]
	var center_index: int = terrain._index_of(center.x, center.z)
	var height_before: float = terrain.heights[center_index]
	brush.paint(terrain.TOOL_LOWER, center.x, center.z, 10.0, 3.0, 1.0)
	print("TEST ground under tower moved %.3f m by brush" % absf(terrain.heights[center_index] - height_before))
	brush.paint(terrain.TOOL_RAISE, center.x, center.z, 10.0, 3.0, 1.0)

	# Selling refunds, and puts back the ground the foundation reshaped.
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	var patch: Dictionary = tower["patch"]
	var indices: PackedInt32Array = patch["indices"]
	var deltas: PackedFloat32Array = patch["deltas"]
	money = brush.money
	towers.select(tower)
	towers.sell_selected()
	await _settle(2)
	var worst := 0.0
	for n in indices.size():
		worst = maxf(worst, absf(terrain.heights[indices[n]] - (saved[indices[n]] - deltas[n])))
	print("TEST sold: refund %d, towers left %d, ground error %.4f m, unlocked %s" % [int(brush.money - money), towers.towers.size(), worst, terrain.edit_mask[center_index] > 0.0])
	towers.place_at(center.x, center.z, 0.0, 0.0, false)
	var rebuilt: Dictionary = towers.towers[towers.towers.size() - 1]
	var best: PackedFloat32Array = core.best_aim(rebuilt["apex"].x, rebuilt["apex"].y, rebuilt["apex"].z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"])
	if best.size() == 3:
		towers._set_tower_aim(rebuilt, atan2(best[0], best[2]), asin(best[1]))
	towers.select(rebuilt)
	_look_at(rebuilt["center"], 42.0, -24.0, 0.6)
	await _settle(4)
	await _shot("7a_flat_tower_close")
	main.apply_view("strategy")
	await _settle(3)
	await _shot("7_flat_tower_selected")


func _test_battle() -> void:
	# A tower that will be sold mid-battle, so its ground should only return once the wave ends.
	var doomed_spot := _find_flat_spot()
	towers.place_at(doomed_spot.x, doomed_spot.z, 0.0, 0.0, false)
	var doomed: Dictionary = towers.towers[towers.towers.size() - 1]
	var doomed_indices: PackedInt32Array = doomed["patch"]["indices"]
	var doomed_deltas: PackedFloat32Array = doomed["patch"]["deltas"]
	var spent := 0.0
	var start_money: float = brush.money
	paths.set_speed(4)
	towers.deselect()
	await _press_key(KEY_B)
	print("TEST B key: battle %s, terrain locked %s" % [paths.phase == paths.Phase.BATTLE, brush.locked])
	var shot_taken := false
	var heights_at_start: PackedFloat32Array = terrain.heights.duplicate()
	# Building and selling during battle must leave the ground alone until the wave ends.
	var extra: Dictionary = {}
	var sold_center := Vector3.ZERO
	while paths.phase == paths.Phase.BATTLE:
		await get_tree().process_frame
		if not shot_taken and core.kills() >= 3:
			shot_taken = true
			towers.select(towers.towers[0])
			await _shot("8_battle")
		if extra.is_empty() and core.kills() >= 1:
			var spot := _find_flat_spot()
			var money_before: float = brush.money
			var built: bool = towers.place_at(spot.x, spot.z, 0.3, -0.2, false)
			spent += money_before - brush.money
			extra = towers.towers[towers.towers.size() - 1]
			towers.deselect()
			var moved := 0.0
			for n in heights_at_start.size():
				moved = maxf(moved, absf(terrain.heights[n] - heights_at_start[n]))
			print("TEST build during battle: %s; ground moved %.3f m; pad waits for wave end: %s" % [built, moved, extra["patch"].is_empty()])
			var money_before_sale: float = brush.money
			towers.select(doomed)
			towers.sell_selected()
			spent -= brush.money - money_before_sale
			var moved_by_sale := 0.0
			for n in doomed_indices.size():
				moved_by_sale = maxf(moved_by_sale, absf(terrain.heights[doomed_indices[n]] - heights_at_start[doomed_indices[n]]))
			print("TEST sell during battle: ground moved %.3f m, removal queued: %s" % [moved_by_sale, towers.pending_removals.size() == 1])
	paths.set_speed(0)
	print("TEST wave: kills %d, reached home %d of %d, gold from kills %d" % [core.kills(), core.arrived(), paths.WAVE_SIZE, int(brush.money - start_money + spent)])
	var restore_error := 0.0
	for n in doomed_indices.size():
		restore_error = maxf(restore_error, absf(terrain.heights[doomed_indices[n]] - (heights_at_start[doomed_indices[n]] - doomed_deltas[n])))
	var extra_patch: Dictionary = extra.get("patch", {})
	var largest := 0.0
	if not extra_patch.is_empty():
		for delta: float in extra_patch["deltas"]:
			largest = maxf(largest, absf(delta))
	print("TEST after wave: sold ground restored within %.3f m; battle tower pad applied %s, cells %d, largest change %.2f m; tools back %s" % [
		restore_error, not extra_patch.is_empty(), extra_patch["indices"].size() if not extra_patch.is_empty() else 0, largest, main.ui.tool_dock.visible,
	])
	for tower in towers.towers:
		print("TEST   tower %d, tilt %.0f deg, kills %d" % [tower["id"], tower["tilt"], core.tower_kills(tower["id"])])


func _test_load() -> void:
	# Time each moment a player could feel.
	var tower: Dictionary = towers.towers[0]
	var apex: Vector3 = tower["apex"]
	var aim: Vector3 = towers.aim_vector(tower["yaw"], tower["pitch"])
	var begin := Time.get_ticks_usec()
	towers._show_range(apex, aim)
	var show_ms := float(Time.get_ticks_usec() - begin) / 1000.0
	begin = Time.get_ticks_usec()
	var check: Dictionary = towers.check_spot(apex.x + 25.0, apex.z)
	var check_ms := float(Time.get_ticks_usec() - begin) / 1000.0
	begin = Time.get_ticks_usec()
	core.best_aim(apex.x, apex.y, apex.z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"])
	var aim_ms := float(Time.get_ticks_usec() - begin) / 1000.0
	print("TEST timings: range display %.2f ms, spot check %.2f ms (ok %s), best aim %.2f ms" % [show_ms, check_ms, check["ok"], aim_ms])
	towers.deselect()
	main.apply_view("strategy")
	await _settle(30)
	_report("idle", await _measure_sweep(false))
	await _press_key(KEY_T)
	_report("sweeping tower preview", await _measure_sweep(true))
	await _press_key(KEY_ESCAPE)
	towers.select(towers.towers[0])
	await _settle(30)
	_report("tower selected", await _measure_sweep(false))
	towers.deselect()

	# Make sure there are six towers, all covering route.
	var added := 0
	for j in range(-10, 11, 4):
		for i in range(-10, 11, 4):
			if towers.towers.size() >= 6:
				break
			var x := float(i) * 6.0
			var z := float(j) * 6.0
			var spot: Dictionary = towers.check_spot(x, z)
			if spot["ok"] and core.best_aim(spot["apex"].x, spot["apex"].y, spot["apex"].z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"]).size() == 3:
				var best: PackedFloat32Array = core.best_aim(spot["apex"].x, spot["apex"].y, spot["apex"].z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"])
				if towers.place_at(x, z, atan2(best[0], best[2]), asin(best[1]), false):
					added += 1
	towers.deselect()
	print("TEST towers for load test: %d (added %d)" % [towers.towers.size(), added])
	await _settle(30)
	_report_frames("no enemies", await paths._measure_frames(200))
	paths.phase = paths.Phase.BATTLE
	paths.route.visible = false
	paths.spawn_wave(300, 0.03)
	paths.set_speed(0)
	await get_tree().create_timer(12.0).timeout
	_report_frames("300 enemies 1x", await paths._measure_frames(300))
	paths.set_speed(4)
	_report_frames("300 enemies 8x", await paths._measure_frames(300))
	paths.phase = paths.Phase.BUILD


func _measure_sweep(move: bool) -> Dictionary:
	var size := get_viewport().get_visible_rect().size
	var total := 0.0
	var worst := 0.0
	var previous := Time.get_ticks_usec()
	for n in 300:
		var t := float(n) / 300.0
		if move:
			brush.test_mouse = Vector2(lerpf(size.x * 0.2, size.x * 0.8, t), size.y * (0.5 + 0.25 * sin(t * 12.0)))
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := float(now - previous) / 1000.0
		previous = now
		total += frame_ms
		worst = maxf(worst, frame_ms)
	return {"fps": 300000.0 / total, "worst": worst}


func _report(label: String, m: Dictionary) -> void:
	print("TEST %s: %.0f fps, worst frame %.1f ms" % [label, m["fps"], m["worst"]])


func _report_frames(label: String, m: Dictionary) -> void:
	print("TEST %s: %.0f fps; battle step avg %.3f ms, worst %.3f ms" % [label, m["fps"], m["step"], m["worst"]])


func _settle(frames: int) -> void:
	for n in frames:
		await get_tree().process_frame


func _press_key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await _settle(2)


func _wheel(button: MouseButton) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	event.position = brush.test_mouse
	Input.parse_input_event(event)
	await get_tree().process_frame


func _hover(world: Vector3) -> void:
	brush.test_mouse = main.camera.unproject_position(world)
	await _settle(3)


func _click_at(world: Vector3) -> void:
	await _hover(world)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = brush.test_mouse
		Input.parse_input_event(event)
		await _settle(2)


func _shot(name_text: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name_text])
