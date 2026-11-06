extends Node
## Plays the first level through real mouse and keyboard events, then checks what the game did.
## Run with: -- --leveltest=dir. Add --lose to let the enemies win instead of defending.

const WALL_AT := Vector3(-112.0, 0.0, -15.0)
## Up the outer hillside, where no angle lets a ridge reach high ground at both ends.
const GAP_AT := Vector3(-140.0, 0.0, -55.0)
## Off the middle of the road, which the ridge should still close by stretching to the hillsides.
const WALL_OFF_CENTRE := Vector3(-124.0, 0.0, -30.0)
const TUNNEL_NORTH := Vector3(16.0, 0.0, -108.0)
const TUNNEL_SOUTH := Vector3(0.0, 0.0, 88.0)
const TOWER_SPOTS: Array[Vector2] = [
	Vector2(84.0, -40.0), Vector2(84.0, -25.0), Vector2(84.0, 25.0), Vector2(84.0, 40.0),
	Vector2(136.0, -30.0), Vector2(136.0, -10.0), Vector2(136.0, 10.0), Vector2(136.0, 30.0),
	Vector2(84.0, 8.0), Vector2(84.0, 55.0), Vector2(70.0, 80.0),
]

var other_types: Array[Dictionary] = []
var main: Node3D
var ui: CanvasLayer
var brush: Node
var paths: Node
var towers: Node
var tools: Node
var feel: Node
var terrain
var dir := ""
var failures := 0
var held := 0


func run(main_node: Node3D, out_dir: String, lose: bool) -> void:
	main = main_node
	ui = main.ui
	brush = main.brush
	paths = main.paths
	towers = main.towers
	tools = main.tools
	feel = main.feel
	terrain = main.terrain
	dir = out_dir
	DirAccess.make_dir_recursive_absolute(dir)
	main.apply_view("strategy")
	brush.test_mouse = Vector2(5.0, 500.0)
	await _wait(1.5)
	if Engine.has_meta("level_test_retried"):
		var fresh: bool = brush.money == float(paths.level["start_gold"]) and paths.home_hp == paths.home_hp_max and paths.wave == 0 and paths.outcome == "" and not ui.end_screen.visible
		_check(fresh, "the retry button starts the level afresh: %d gold, %d health, wave %d" % [int(brush.money), paths.home_hp, paths.wave])
		await _key(KEY_B)
		await _wait(1.0)
		_check(paths.phase == paths.Phase.BATTLE and paths.core.active() > 0, "and a new wave can start")
	elif lose:
		await _test_lose()
	else:
		await _test_scenery()
		await _test_start()
		await _test_ridge()
		await _test_ridge_sizes()
		await _test_hill_and_trees()
		await _test_pit_and_flood()
		await _test_tunnel()
		await _test_upgrades()
		await _test_full_game()
	print("LEVEL failures: %d" % failures)
	get_tree().quit()


func _check(ok: bool, label: String) -> void:
	print("LEVEL %s %s" % ["ok  " if ok else "FAIL", label])
	if not ok:
		failures += 1


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _frames(count: int) -> void:
	for n in count:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, shot_name])


func _to_window(canvas: Vector2) -> Vector2:
	return get_viewport().get_stretch_transform() * canvas


func _motion(canvas: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	var at := _to_window(canvas)
	event.position = at
	event.global_position = at
	event.button_mask = held
	Input.parse_input_event(event)
	await _frames(2)


func _button_event(canvas: Vector2, down: bool, button := MOUSE_BUTTON_LEFT, alt := false) -> void:
	var event := InputEventMouseButton.new()
	event.alt_pressed = alt
	var at := _to_window(canvas)
	event.button_index = button
	event.pressed = down
	event.position = at
	event.global_position = at
	held = MOUSE_BUTTON_MASK_LEFT if down and button == MOUSE_BUTTON_LEFT else 0
	event.button_mask = held
	Input.parse_input_event(event)
	await _frames(2)


func _click_at(canvas: Vector2) -> void:
	await _motion(canvas)
	await _button_event(canvas, true)
	await _button_event(canvas, false)


func _click(control: Control) -> void:
	await _click_at(control.get_global_rect().get_center())


func _key(code: Key, ctrl := false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.ctrl_pressed = ctrl
	event.pressed = true
	Input.parse_input_event(event)
	await _frames(2)


func _ground(spot: Vector3) -> Vector3:
	return Vector3(spot.x, terrain.height_at(spot.x, spot.z), spot.z)


func _hover_world(world: Vector3) -> void:
	var canvas: Vector2 = main.camera.unproject_position(_ground(world))
	brush.test_mouse = canvas
	await _motion(canvas)
	await _frames(3)


func _click_world(world: Vector3) -> void:
	await _hover_world(world)
	var canvas: Vector2 = brush.test_mouse
	await _button_event(canvas, true)
	await _button_event(canvas, false)


func _wait_for_tools() -> void:
	while not tools.job.is_empty():
		await get_tree().process_frame
	await _frames(3)


func _wait_for_options() -> void:
	while not paths.option_jobs.is_empty():
		await get_tree().process_frame
	await _frames(3)


## Nothing may run off the screen, and no two panels may cover each other.
func _audit(state: String) -> void:
	var items := {
		"gold": ui.gold_pill, "home": ui.home_pill, "phase": ui.phase_card, "forecast": ui.forecast_card,
		"tools": ui.tool_dock, "tower_dock": ui.tower_dock, "battle_dock": ui.battle_dock, "tower_card": ui.tower_card,
		"tunnel_card": ui.tunnel_card, "hint": ui.hint_panel, "banner": ui.banner,
	}
	var screen := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var seen: Array[String] = []
	var problems: Array[String] = []
	for key: String in items:
		var control: Control = items[key]
		if not control.is_visible_in_tree():
			continue
		var rect := control.get_global_rect()
		if not screen.encloses(rect):
			problems.append("%s off screen %s" % [key, rect])
		for other: String in seen:
			if rect.intersects(items[other].get_global_rect()):
				problems.append("%s overlaps %s" % [key, other])
		seen.append(key)
	_check(problems.is_empty(), "layout %s: %d panels %s" % [state, seen.size(), problems if not problems.is_empty() else ""])


func _route_labels() -> String:
	var labels: PackedStringArray = []
	for plan: Dictionary in paths.gate_plans:
		var alternatives: PackedStringArray = []
		for option: Dictionary in plan["alternatives"]:
			alternatives.append("%s %d" % [option["label"], int(option["time"])])
		labels.append("%s %s %d 秒 [%s]" % [plan["name"], plan["label"], int(plan["time"]), " / ".join(alternatives)])
	return "; ".join(labels)


func _test_start() -> void:
	_check(ui.home_pill.visible and ui.home_label.text == "12", "home health shows %s" % ui.home_label.text)
	_check(ui.banner.visible, "the level opens with its goal")
	await _audit("start")
	await _shot("01_start")
	await _wait_for_options()
	await _frames(3)
	print("LEVEL routes at the start: %s" % _route_labels())
	_check(paths.gate_plans.size() == 2, "both gates have a plan")
	_check(paths.gate_plans[0]["label"] == "走西路" and paths.gate_plans[1]["label"] == "走东路", "each gate takes its own road")
	_check(not paths.gate_plans[0]["alternatives"].is_empty(), "the forecast compares other routes")
	_check(ui.wave_rows.get_child_count() >= 1 and ui.wave_title.text.contains("1 / 3"), "the wave preview says: %s" % ui.wave_title.text)
	await _wait(5.5)
	await _audit("forecast")
	await _shot("02_forecast")


func _test_ridge() -> void:
	var money: float = brush.money
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	await _click(ui.preset_buttons["ridge"])
	_check(tools.active_id == "ridge" and brush.tools_busy, "the ridge button starts placing")
	_check(ui.preset_buttons["ridge"].button_pressed, "its button lights up")
	await _hover_world(WALL_AT)
	await _frames(4)
	_check(tools.ghost.visible and tools.hint_text.contains("金"), "the ghost and price show: %s" % tools.hint_text)
	await _audit("placing a ridge")
	await _shot("03_ridge_ghost")
	_check(tools.hint_text.contains("接上山坡") and not tools.gap_markers[0].visible, "the ridge reaches the hillsides: %s" % tools.hint_text)
	await _hover_world(GAP_AT)
	await _frames(4)
	_check(tools.gap_markers[0].visible and tools.hint_kind == tools.HINT_WARN, "a ridge that misses the high ground shows a red post: %s" % tools.hint_text)
	await _shot("03b_ridge_gap")
	await _hover_world(WALL_OFF_CENTRE)
	await _frames(4)
	_check(not tools.gap_markers[0].visible and tools.hint_text.contains("接上山坡"), "an off-centre ridge still reaches both hillsides: %s" % tools.hint_text)
	await _shot("03c_ridge_off_centre")
	await _hover_world(WALL_AT)
	await _frames(4)
	var canvas: Vector2 = brush.test_mouse
	await _button_event(canvas, true, MOUSE_BUTTON_WHEEL_UP)
	await _button_event(canvas, false, MOUSE_BUTTON_WHEEL_UP)
	await _frames(3)
	_check(absf(tools.yaw) > 0.1, "the wheel turns it")
	await _button_event(canvas, true, MOUSE_BUTTON_WHEEL_DOWN)
	await _button_event(canvas, false, MOUSE_BUTTON_WHEEL_DOWN)
	await _frames(3)
	await _button_event(canvas, true)
	await _button_event(canvas, false)
	_check(not tools.job.is_empty() and brush.money < money, "a click places it for %d gold" % int(money - brush.money))
	await _key(KEY_Z, true)
	_check(not tools.job.is_empty() and brush.ground_busy, "undo waits while the ground is moving")
	await _wait(0.3)
	await _shot("04_ridge_rising")
	await _wait_for_tools()
	await _wait(0.15)
	var flipped: bool = paths.gate_plans[0]["label"] == "走东路"
	_check(flipped, "the west enemies now take the east road: %s" % _route_labels())
	await _shot("05_route_flip")
	await _wait_for_options()
	print("LEVEL routes with the ridge: %s" % _route_labels())
	await _key(KEY_ESCAPE)
	_check(tools.active_id == "" and not brush.tools_busy, "Esc stops placing")
	await _key(KEY_Z, true)
	await _frames(3)
	_check(brush.money == money, "undo gives the gold back")
	var difference := 0.0
	for n in range(0, saved.size(), 97):
		difference = maxf(difference, absf(terrain.heights[n] - saved[n]))
	_check(difference < 0.01, "undo puts the ground back")
	_check(paths.gate_plans[0]["label"] == "走西路", "and the enemies return to their own road")


func _nearest_tree() -> Vector3:
	var best := Vector3(-120.0, 0.0, 100.0)
	var best_distance := INF
	for tree: Node3D in brush.hides_on_bare_ground:
		if not is_instance_valid(tree):
			continue
		var d: float = absf(tree.position.x) + absf(tree.position.z - 90.0)
		if tree.position.z > 40.0 and tree.position.z < 100.0 and d < best_distance:
			best_distance = d
			best = tree.position
	return best


func _test_hill_and_trees() -> void:
	var money: float = brush.money
	var spot := _nearest_tree()
	main.apply_view("south")
	await _frames(3)
	var trees_before: int = brush.hides_on_bare_ground.size()
	await _key(KEY_Z)
	_check(tools.active_id == "hill", "the Z key picks the small hill")
	await _hover_world(spot)
	await _frames(4)
	print("LEVEL hill hint: %s" % tools.hint_text)
	await _button_event(brush.test_mouse, true)
	await _button_event(brush.test_mouse, false)
	await _wait(0.45)
	await _shot("06_hill_rising")
	await _wait_for_tools()
	await _wait(0.5)
	await _shot("07_trees_fallen")
	await _key(KEY_ESCAPE)
	print("LEVEL trees %d before, %d after; hill cost %d" % [trees_before, brush.hides_on_bare_ground.size(), int(money - brush.money)])
	await _key(KEY_Z, true)
	await _frames(3)
	_check(brush.money == money, "undo refunds the hill")
	# Digging out from under a tree makes it fall.
	await _key(KEY_N)
	await _hover_world(spot)
	await _frames(3)
	await _button_event(brush.test_mouse, true)
	await _button_event(brush.test_mouse, false)
	await _wait_for_tools()
	await _wait(0.25)
	await _shot("07b_tree_toppling")
	var fallen := 0
	for tree: Node3D in brush.hides_on_bare_ground:
		if tree.get_meta("down", false):
			fallen += 1
	_check(fallen > 0, "digging under trees topples %d of them" % fallen)
	await _wait(1.0)
	await _shot("07c_tree_down")
	await _key(KEY_Z, true)
	await _wait(1.0)
	_check(brush.money == money, "undo refunds the pit")
	fallen = 0
	for tree: Node3D in brush.hides_on_bare_ground:
		if tree.get_meta("down", false):
			fallen += 1
	_check(fallen == 0, "and the trees stand up again")


## The whole world with no interface over it.
func _test_scenery() -> void:
	ui.root.visible = false
	for view: String in main.view_order:
		main.apply_view(view)
		await _wait(0.5)
		await _shot("00_view_%s" % view)
	main.target = Vector3(50.0, 6.0, 90.0)
	main.yaw = 0.0
	main.pitch = -38.0
	main.dist = 90.0
	main._update_camera()
	await _wait(0.5)
	await _shot("00_view_pond")
	ui.root.visible = true
	main.apply_view("strategy")
	await _frames(3)


func _test_pit_and_flood() -> void:
	var money: float = brush.money
	main.target = Vector3(50.0, 6.0, 90.0)
	main.yaw = 0.0
	main.pitch = -38.0
	main.dist = 110.0
	main._update_camera()
	await _frames(3)
	await _key(KEY_N)
	_check(tools.active_id == "pit", "the N key picks the big pit")
	var spot := Vector3(30.0, 0.0, 85.0)
	await _hover_world(spot)
	await _frames(4)
	print("LEVEL pit hint: %s" % tools.hint_text)
	var flood_before: float = brush.flood_clock
	await _button_event(brush.test_mouse, true)
	await _button_event(brush.test_mouse, false)
	await _wait_for_tools()
	await _wait(0.35)
	await _shot("08_pit_flooding")
	print("LEVEL flood clock %.2f -> %.2f" % [flood_before, brush.flood_clock])
	await _wait(1.6)
	await _shot("09_pit_flooded")
	await _key(KEY_ESCAPE)
	await _key(KEY_Z, true)
	await _frames(3)
	_check(brush.money == money, "undo refunds the pit")
	main.apply_view("strategy")
	await _frames(3)


func _test_tunnel() -> void:
	var money: float = brush.money
	await _click(ui.preset_buttons["tunnel"])
	_check(tools.active_id == "tunnel", "the tunnel button works")
	await _hover_world(TUNNEL_NORTH)
	await _frames(3)
	await _shot("10_tunnel_first")
	await _click_world(TUNNEL_NORTH)
	_check(tools.tunnel_start != Vector2.INF, "the first click picks a mouth")
	await _hover_world(TUNNEL_SOUTH)
	await _frames(4)
	print("LEVEL tunnel hint: %s / %s" % [tools.hint_text, tools.hint_sub])
	await _shot("11_tunnel_preview")
	await _click_world(TUNNEL_SOUTH)
	_check(tools.tunnels.size() == 1 and brush.money < money, "the second click digs it for %d gold" % int(money - brush.money))
	_check(tools.active_id == "", "the tool closes afterwards")
	await _wait(0.2)
	print("LEVEL routes with the tunnel: %s" % _route_labels())
	_check(paths.gate_plans[0]["label"] == "穿隧道" and paths.gate_plans[1]["label"] == "穿隧道", "every enemy takes the tunnel")
	await _shot("12_tunnel_route")
	var tunnel: Dictionary = tools.tunnels[0]
	var door: Vector2 = tunnel["doors"][1]
	main.apply_view("south")
	await _frames(3)
	await _wait(0.4)
	await _shot("13_portal_south")
	var door_world := Vector3(door.x, float(tunnel["levels"][1]) + 3.0, door.y)
	var door_canvas: Vector2 = main.camera.unproject_position(door_world)
	brush.test_mouse = door_canvas
	await _click_at(door_canvas)
	_check(tools.selected_tunnel == tunnel, "clicking a portal selects the tunnel")
	await _wait(0.3)
	_check(ui.tunnel_card.visible, "its card opens")
	_check(not ui.forecast_card.visible, "the forecast steps aside for it")
	await _audit("tunnel card")
	await _shot("14_tunnel_card")
	var before: float = brush.money
	await _click(ui.tunnel_sell_label.get_parent().get_parent().get_parent())
	_check(tools.tunnels.is_empty() and brush.money > before, "filling it in refunds %d" % int(brush.money - before))
	await _wait(0.4)
	_check(paths.gate_plans[0]["label"] == "走西路", "the enemies go back to the roads: %s" % _route_labels())
	_check(ui.forecast_card.visible, "and the forecast returns")
	main.apply_view("strategy")
	await _frames(3)


## The player picks a ridge's sizes, and can leave a gap on purpose.
func _test_ridge_sizes() -> void:
	var money: float = brush.money
	await _click(ui.preset_buttons["ridge"])
	var sizes: Dictionary = ui.preset_sliders["ridge"]
	_check(sizes["box"].visible and not ui.brush_sliders.visible, "the ridge shows its own sliders in place of the brush ones")
	await _hover_world(WALL_AT)
	await _frames(4)
	var auto_length: float = tools.preview_length
	_check(sizes["auto"].button_pressed and int(sizes["rows"]["length"][1].text) == int(round(auto_length)), "the length slider shows the stretched length: %s" % sizes["rows"]["length"][1].text)
	await _shot("05b_ridge_sliders")
	var height_before: float = tools.sizes["ridge"]["height"]
	var canvas: Vector2 = brush.test_mouse
	await _button_event(canvas, true, MOUSE_BUTTON_WHEEL_UP, true)
	await _button_event(canvas, false, MOUSE_BUTTON_WHEEL_UP, true)
	await _frames(3)
	_check(tools.sizes["ridge"]["height"] > height_before, "Alt + wheel raises it to %d" % int(tools.sizes["ridge"]["height"]))
	tools.set_size("height", height_before)
	await _click(sizes["auto"])
	_check(not tools.stretch, "the 自动 switch turns stretching off")
	var slider: HSlider = sizes["rows"]["length"][0]
	slider.value = 40.0
	await _hover_world(WALL_AT + Vector3(0.0, 0.0, 1.0))
	await _frames(4)
	_check(absf(tools.preview_length - 40.0) < 0.5 and tools.gap_markers[0].visible and tools.gap_markers[1].visible, "a 40 metre ridge keeps its length and shows both gaps: %s" % tools.hint_text)
	await _shot("05c_ridge_short")
	await _button_event(brush.test_mouse, true)
	await _button_event(brush.test_mouse, false)
	await _wait_for_tools()
	await _wait(0.15)
	_check(paths.gate_plans[0]["label"] == "走西路", "with the gap left open the west enemies keep their road: %s" % _route_labels())
	await _key(KEY_Z, true)
	await _frames(3)
	_check(brush.money == money, "undo refunds the short ridge")
	await _click(ui.preset_buttons["ridge"])
	await _click(sizes["auto"])
	_check(tools.stretch, "and the switch turns stretching back on")
	await _key(KEY_ESCAPE)
	tools.sizes["ridge"]["length"] = float(tools.presets[1]["length"])
	await _wait(0.4)
	main.apply_view("strategy")
	await _frames(3)


## A tower is upgraded from its card: one branch, then a final form, then a star, then sold.
func _test_upgrades() -> void:
	var money: float = brush.money
	brush.money = 20000.0
	var spot: Vector2 = TOWER_SPOTS[0]
	var check: Dictionary = towers.check_spot(spot.x, spot.y)
	towers.place_at(spot.x, spot.y, 0.0, -0.2, false)
	towers.deselect()
	await _frames(2)
	var tower: Dictionary = towers.towers.back()
	await _click_world(Vector3(spot.x, 0.0, spot.y))
	await _wait(0.4)
	_check(towers.selected == tower and ui.tower_card.visible, "clicking a tower opens its card")
	_check(ui.upgrade_rows.size() == 2, "the card offers two branches: %s" % ui.upgrade_key)
	await _click(ui.upgrade_rows[0]["button"])
	await _wait(0.4)
	_check(tower["path"] == ["scatter"] and ui.tower_name.text.begins_with("散射炮"), "the first button makes it a %s" % ui.tower_name.text)
	await _click(ui.upgrade_rows[1]["button"])
	await _wait(0.4)
	_check(tower["path"] == ["scatter", "blaze"] and ui.effect_label.text.contains("燃烧"), "the second makes it a fire gun: %s" % ui.effect_label.text)
	var heavy_chip: Label = ui.tree_chips["heavy"]["label"]
	_check(heavy_chip.get_theme_color("font_color").a < 0.5, "the branch not taken is greyed out")
	await _click(ui.upgrade_rows[0]["button"])
	await _wait(0.4)
	_check(tower["stars"] == 1 and ui.tower_name.text.contains("★"), "a star comes after the final form: %s" % ui.tower_name.text)
	await _audit("tower card with upgrades")
	await _shot("14b_upgrade_card")
	var paid: int = tower["paid"]
	_check(paid == int(check["cost"]) + 700 + 1100 + 600, "the tower remembers all it cost: %d" % paid)
	var before: float = brush.money
	await _click(ui.sell_button)
	await _wait(0.3)
	_check(int(brush.money - before) == int(floorf(float(paid) * towers.refund_rate)), "selling refunds 70%% of all of it: %d" % int(brush.money - before))
	brush.money = money
	await _wait(0.4)


## The designed way through: wall off one road, then guard the other.
func _test_full_game() -> void:
	brush.test_mouse = Vector2(5.0, 500.0)
	await _frames(2)
	await _key(KEY_X)
	await _click_world(WALL_AT)
	# How smooth the ground stays while it rises, and while the other routes are compared afterwards.
	var job_frames := 0
	var job_time := 0.0
	var job_worst := 0.0
	while not tools.job.is_empty():
		await get_tree().process_frame
		job_frames += 1
		job_time += get_process_delta_time()
		job_worst = maxf(job_worst, get_process_delta_time())
	var option_frames := 0
	var option_time := 0.0
	var option_worst := 0.0
	await get_tree().process_frame
	while not paths.option_jobs.is_empty():
		await get_tree().process_frame
		option_frames += 1
		option_time += get_process_delta_time()
		option_worst = maxf(option_worst, get_process_delta_time())
	print("LEVEL ground rising: %.0f fps, worst frame %.1f ms; comparing routes: %.0f fps, worst frame %.1f ms" % [
		float(job_frames) / maxf(job_time, 0.001), job_worst * 1000.0, float(option_frames) / maxf(option_time, 0.001), option_worst * 1000.0,
	])
	await _build_towers()
	await _add_other_types()
	await _wait(0.2)
	print("LEVEL ready with %d towers and %d gold: %s" % [towers.towers.size(), int(brush.money), _route_labels()])
	await _shot("15_ready")
	for n in 3:
		await _play_wave(n)
		if paths.outcome != "":
			break
		await _build_towers()
	await _wait(0.8)
	_check(paths.outcome == "won", "the designed strategy wins the level, with %d of %d health left" % [paths.home_hp, paths.home_hp_max])
	for tower: Dictionary in other_types:
		_check(paths.core.tower_kills(tower["id"]) > 0, "the %s took part: %d kills" % [tower["spec"]["name"], paths.core.tower_kills(tower["id"])])
	_check(ui.end_screen.visible, "the end screen opens")
	print("LEVEL end screen: %s / %s" % [ui.end_title.text, ui.end_sub.text])
	await _shot("20_won")


## A near look at one place with no interface over it, then back to the strategy view.
func _close_up(point: Vector3, shot_name: String, distance := 34.0) -> void:
	ui.root.visible = false
	main.target = point
	main.yaw = 60.0
	main.pitch = -52.0
	main.dist = distance
	main._update_camera()
	await _wait(0.5)
	await _shot(shot_name)
	ui.root.visible = true
	main.apply_view("strategy")
	await _frames(3)


## One catapult and one sniper on top of the designed towers, paid for separately, each at the spot on
## the east side where it covers the most route. Their cards must fit their type.
func _add_other_types() -> void:
	for type: String in ["catapult", "sniper"]:
		towers.place_type = type
		var spec: Dictionary = towers.specs[type]
		var stats: PackedFloat32Array = towers.stats_for(spec)
		var best := {}
		var best_covered := 0.0
		for x in range(60, 150, 8):
			for z in range(-90, 100, 8):
				var check: Dictionary = towers.check_spot(float(x), float(z))
				if not check["ok"]:
					continue
				var apex: Vector3 = check["apex"]
				var aim: PackedFloat32Array = paths.core.stats_best_aim(apex.x, apex.y, apex.z, 0.0, 0.0, 1.0, stats, stats.size())
				if aim.size() != 3:
					continue
				var covered: float = paths.core.stats_covered(apex.x, apex.y, apex.z, aim[0], aim[1], aim[2], stats, stats.size())
				if covered > best_covered:
					best_covered = covered
					best = {"x": float(x), "z": float(z), "cost": check["cost"], "yaw": atan2(aim[0], aim[2]), "pitch": asin(clampf(aim[1], -1.0, 1.0))}
		_check(not best.is_empty(), "there is somewhere to build a %s" % spec["name"])
		if best.is_empty():
			continue
		brush.money += float(best["cost"])
		_check(towers.place_at(best["x"], best["z"], best["yaw"], best["pitch"], false), "a %s is built at %d, %d covering %d m" % [spec["name"], int(best["x"]), int(best["z"]), int(best_covered)])
		var tower: Dictionary = towers.towers.back()
		other_types.append(tower)
		await _wait(0.4)
		_check(ui.tower_name.text == spec["name"] and ui.tree_type == type, "its card shows the %s and its tree: %s" % [spec["name"], ui.tower_name.text])
		_check(ui.aim_box.visible == (type != "catapult"), "the aim controls %s" % ("show" if ui.aim_box.visible else "hide"))
		await _audit("%s card" % type)
		await _shot("15%s_%s" % ["b" if type == "catapult" else "c", type])
		towers.deselect()
		await _frames(2)
		await _close_up(Vector3(tower["apex"]), "15d_%s_close" % type)
	towers.place_type = "normal"


func _build_towers() -> void:
	var half: float = towers.normal_spec["half_angle"]
	var reach: float = towers.normal_spec["range"]
	var cost: float = towers.normal_spec["cost"]
	for spot in TOWER_SPOTS:
		if brush.money < cost + 500.0:
			return
		var check: Dictionary = towers.check_spot(spot.x, spot.y)
		if not check["ok"]:
			continue
		var apex: Vector3 = check["apex"]
		var aim: PackedFloat32Array = paths.core.best_aim(apex.x, apex.y, apex.z, 0.0, 0.0, 1.0, half, reach)
		if aim.size() != 3:
			continue
		var direction := Vector3(aim[0], aim[1], aim[2])
		var yaw := atan2(direction.x, direction.z)
		var pitch := asin(clampf(direction.y, -1.0, 1.0))
		towers.place_at(spot.x, spot.y, yaw, pitch, false)
		towers.deselect()
		await _frames(2)


func _play_wave(index: int) -> void:
	paths.set_speed(4)
	await _key(KEY_B)
	await _frames(3)
	_check(paths.phase == paths.Phase.BATTLE, "wave %d starts" % (index + 1))
	_check(brush.locked, "the ground is locked during battle")
	_check(not ui.forecast_card.visible or ui.forecast_card.modulate.a < 1.0, "the forecast hides")
	var shot_taken := false
	var fps_total := 0.0
	var fps_frames := 0
	var started := Time.get_ticks_msec()
	while paths.phase == paths.Phase.BATTLE and paths.outcome == "":
		await get_tree().process_frame
		fps_total += get_process_delta_time()
		fps_frames += 1
		if not shot_taken and paths.core.kills() >= 6:
			shot_taken = true
			var previous: int = paths.speed_index
			paths.set_speed(0)
			await _wait(0.5)
			await _shot("%d_wave_%d" % [16 + index, index + 1])
			if index == 0 and not other_types.is_empty():
				await _close_up(Vector3(other_types[0]["apex"]), "16b_stones_in_flight", 70.0)
			paths.set_speed(previous)
		if Time.get_ticks_msec() - started > 120000:
			_check(false, "wave %d finished in time" % (index + 1))
			break
	print("LEVEL wave %d: kills %d, reached home %d of %d, earned %d, health %d, %.0f fps" % [
		index + 1, paths.core.kills(), paths.core.arrived(), paths.wave_total, paths.earned_this_wave, paths.home_hp, float(fps_frames) / maxf(fps_total, 0.001),
	])
	paths.set_speed(0)
	await _frames(3)


func _test_lose() -> void:
	paths.set_speed(4)
	await _key(KEY_B)
	var started := Time.get_ticks_msec()
	while paths.outcome == "" and Time.get_ticks_msec() - started < 120000:
		await get_tree().process_frame
	await _wait(0.8)
	_check(paths.outcome == "lost", "with no defenses the home falls")
	_check(ui.end_screen.visible and ui.end_title.text == "家园失守", "the end screen says so")
	await _shot("21_lost")
	_check(ui.retry_button.is_visible_in_tree(), "the retry button is there")
	# The scene reloads now, which ends this run. The next one checks the result.
	Engine.set_meta("level_test_retried", true)
	await _click(ui.retry_button)
