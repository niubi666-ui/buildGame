extends Node
## Automated interface test. Sends real mouse and keyboard events through the same path as a
## player's, so a button that is covered, off screen or badly laid out fails here.

var main: Node3D
var ui: CanvasLayer
var brush: Node
var paths: Node
var towers: Node
var terrain
var dir := ""
var failures := 0
var held := 0


func run(main_node: Node3D, out_dir: String, full: bool) -> void:
	main = main_node
	ui = main.ui
	brush = main.brush
	paths = main.paths
	towers = main.towers
	terrain = main.terrain
	dir = out_dir
	DirAccess.make_dir_recursive_absolute(dir)
	main.apply_view("strategy")
	brush.test_mouse = Vector2(5.0, 500.0)
	await _wait(2.5)
	var size := get_viewport().get_visible_rect().size
	print("UI window %s, canvas %s" % [get_window().size, size])
	if full:
		await _test_all()
	else:
		await _test_layout()
	print("UI failures: %d" % failures)
	get_tree().quit()


func _check(ok: bool, label: String) -> void:
	print("UI %s %s" % ["ok  " if ok else "FAIL", label])
	if not ok:
		failures += 1


## Nothing may run off the screen, and no two panels may cover each other.
func _audit(state: String) -> void:
	var items := {
		"gold": ui.gold_pill, "help_button": ui.help_button, "fps": ui.fps_chip, "phase": ui.phase_card, "forecast": ui.forecast_card,
		"tools": ui.tool_dock, "tower_dock": ui.tower_dock, "battle_dock": ui.battle_dock, "tower_card": ui.tower_card,
		"hint": ui.hint_panel, "banner": ui.banner, "help": ui.help_card,
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
			var other_rect: Rect2 = items[other].get_global_rect()
			if rect.intersects(other_rect):
				problems.append("%s overlaps %s" % [key, other])
		seen.append(key)
	_check(problems.is_empty(), "layout %s: %d panels %s" % [state, seen.size(), problems if not problems.is_empty() else ""])


## Hover, panels and clicks on screen all use this one conversion.
func _to_window(canvas: Vector2) -> Vector2:
	return get_viewport().get_stretch_transform() * canvas


## The camera's own projection already gives positions in interface coordinates.
func _world_to_canvas(world: Vector3) -> Vector2:
	return main.camera.unproject_position(world)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _frames(count: int) -> void:
	for n in count:
		await get_tree().process_frame


func _motion(canvas: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	var at := _to_window(canvas)
	event.position = at
	event.global_position = at
	event.button_mask = held
	Input.parse_input_event(event)
	await _frames(2)


func _button_event(canvas: Vector2, down: bool, button := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	var at := _to_window(canvas)
	event.button_index = button
	event.pressed = down
	event.position = at
	event.global_position = at
	held = MOUSE_BUTTON_MASK_LEFT if down else 0
	event.button_mask = held
	Input.parse_input_event(event)
	await _frames(2)


func _click_at(canvas: Vector2) -> void:
	await _motion(canvas)
	await _button_event(canvas, true)
	await _button_event(canvas, false)


func _click(control: Control) -> void:
	await _click_at(control.get_global_rect().get_center())


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await _frames(2)


## Press on a slider, drag to the chosen fraction along it, and let go.
func _drag(slider: HSlider, from: float, to: float) -> void:
	var rect := slider.get_global_rect()
	var y := rect.get_center().y
	var start := Vector2(lerpf(rect.position.x, rect.end.x, from), y)
	var finish := Vector2(lerpf(rect.position.x, rect.end.x, to), y)
	await _motion(start)
	await _button_event(start, true)
	for n in range(1, 6):
		await _motion(start.lerp(finish, float(n) / 5.0))
	await _button_event(finish, false)


func _slider_value(slider: HSlider, fraction: float) -> float:
	var width := slider.size.x
	var grabber := 22.0
	var position := clampf((fraction * width - grabber * 0.5) / (width - grabber), 0.0, 1.0)
	return lerpf(slider.min_value, slider.max_value, position)


## Points the world mouse at a spot on the ground.
func _hover_world(world: Vector3) -> void:
	var canvas := _world_to_canvas(world)
	brush.test_mouse = canvas
	await _motion(canvas)
	await _frames(2)


func _click_world(world: Vector3) -> void:
	await _hover_world(world)
	await _button_event(brush.test_mouse, true)
	await _button_event(brush.test_mouse, false)


## A clear part of the screen, so the mouse stops hovering whatever it was on.
func _rest_mouse() -> void:
	await _motion(get_viewport().get_visible_rect().size * Vector2(0.72, 0.55))


func _shot(name_text: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name_text])


func _good_spot() -> Vector3:
	var best := Vector3.ZERO
	var best_covered := -1.0
	for j in range(-10, 11, 2):
		for i in range(-10, 11, 2):
			var x := float(i) * 6.0
			var z := float(j) * 6.0
			var check: Dictionary = towers.check_spot(x, z)
			if not check["ok"]:
				continue
			var apex: Vector3 = check["apex"]
			var aim: PackedFloat32Array = paths.core.best_aim(apex.x, apex.y, apex.z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"])
			if aim.size() != 3:
				continue
			var covered: float = towers._covered(apex, Vector3(aim[0], aim[1], aim[2]))
			if covered > best_covered:
				best_covered = covered
				best = Vector3(x, terrain.height_at(x, z), z)
	return best


## The quick pass, for checking each window size.
func _test_layout() -> void:
	var size := get_viewport().get_visible_rect().size
	await _shot("build_%dx%d" % [get_window().size.x, get_window().size.y])
	_audit("build")
	var spot := _good_spot()
	# The game reads the real cursor in interface coordinates, then casts a ray from that position.
	# Each half is checked separately, because the test must never move the player's real mouse.
	var cursor := Vector2(DisplayServer.mouse_get_position() - DisplayServer.window_get_position())
	var expected := get_viewport().get_stretch_transform().affine_inverse() * cursor
	var read_back := get_viewport().get_mouse_position()
	_check(read_back.distance_to(expected) < 3.0, "the real cursor reads in interface coordinates: %s, expected %s" % [read_back, expected])
	var canvas := _world_to_canvas(spot)
	brush.test_mouse = canvas
	await _frames(3)
	var error: float = Vector3(brush.hit).distance_to(spot)
	_check(brush.has_hit and error < 1.5, "a position in interface coordinates lands within %.2f m of the ground spot" % error)
	brush.test_mouse = null
	await _motion(ui.tool_dock.get_global_rect().get_center())
	await _frames(3)
	_check(brush.over_ui and not brush.has_hit and not brush.ring.visible, "with the mouse over a panel, the brush ring goes away")
	brush.test_mouse = canvas
	await _motion(canvas)
	towers.toggle_placing()
	await _frames(4)
	_audit("placing")
	towers.place_at(spot.x, spot.z, 0.0, -0.2, false)
	ui.toggle_help()
	await _wait(0.5)
	_audit("tower card and help")
	await _shot("card_%dx%d" % [get_window().size.x, get_window().size.y])
	ui.toggle_help()
	paths.start_battle()
	await _wait(1.0)
	_audit("battle")
	await _shot("battle_%dx%d" % [get_window().size.x, get_window().size.y])
	print("UI canvas used %s" % size)


func _test_all() -> void:
	await _shot("1_build")
	_audit("build")
	await _test_tools()
	await _test_undo()
	await _test_help()
	await _test_tower()
	await _test_forecast()
	await _test_gold()
	await _test_speed()
	await _test_battle()
	await _test_keys()
	await _test_cost()


func _test_tools() -> void:
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	var money: float = brush.money
	for id: int in ui.tool_buttons:
		var button: Button = ui.tool_buttons[id]
		await _click(button)
		_check(brush.tool == id and button.button_pressed, "clicking tool %s selects it (tool %d, wanted %d, lit %s, hovered %s)" % [button.text, brush.tool, id, button.button_pressed, get_viewport().gui_get_hovered_control()])
	await _motion(ui.tool_buttons[terrain.TOOL_SLOPE].get_global_rect().get_center())
	await _frames(2)
	_check(ui.hint_panel.visible and ui.tip_text != "", "hovering a tool shows its tip: %s" % ui.tip_text)
	await _wait(0.25)
	await _shot("2_tool_tip")
	await _rest_mouse()
	_check(ui.tip_text == "", "the tip clears when the mouse leaves")
	await _drag(ui.radius_slider, 0.3, 0.75)
	_check(absf(brush.radius - lerpf(3.0, brush.max_radius, 0.75)) < 3.0, "dragging the size slider sets radius to %.0f" % brush.radius)
	await _drag(ui.strength_slider, 0.3, 0.5)
	_check(absf(brush.strength - 1.6) < 0.3, "dragging the strength slider sets it to %.1f" % brush.strength)
	await _key(KEY_Q)
	await _frames(2)
	_check(ui.tool_buttons[terrain.TOOL_RAISE].button_pressed, "the Q key lights the raise button")
	brush.select_tool(terrain.TOOL_PINCH)
	brush.radius = 35.0
	await _frames(2)
	_check(ui.radius_value.text == str(int(brush.max_pinch_radius)), "the size shows the pinch limit: %s" % ui.radius_value.text)
	brush.radius = 14.0
	brush.strength = 1.0
	brush.select_tool(terrain.TOOL_LOWER)
	await _frames(2)
	_check(is_equal_approx(ui.radius_slider.value, 14.0), "the size slider follows the brush")
	# The wheel and the slider must share one range, or the slider cannot show the real value.
	for n in 40:
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		wheel.alt_pressed = true
		wheel.position = _to_window(get_viewport().get_visible_rect().size * Vector2(0.72, 0.55))
		Input.parse_input_event(wheel)
	await _frames(3)
	_check(is_equal_approx(brush.strength, ui.strength_slider.value) and is_equal_approx(brush.strength, brush.max_strength), "Alt + wheel stops at the slider's end: %.1f" % brush.strength)
	brush.strength = 1.0
	await _frames(2)
	var moved := 0.0
	for n in saved.size():
		moved = maxf(moved, absf(terrain.heights[n] - saved[n]))
	_check(moved == 0.0 and is_equal_approx(money, brush.money), "using the dock never paints the ground")


func _test_undo() -> void:
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	var money: float = brush.money
	_check(ui.undo_button.disabled, "undo starts disabled")
	var spot := Vector3(40.0, terrain.height_at(40.0, 40.0), 40.0)
	await _hover_world(spot)
	await _button_event(brush.test_mouse, true)
	await _wait(0.4)
	await _button_event(brush.test_mouse, false)
	await _frames(3)
	_check(brush.money < money, "painting on the ground spends gold")
	_check(not ui.undo_button.disabled, "undo is available after a stroke")
	await _wait(0.5)
	await _click(ui.undo_button)
	await _frames(3)
	var moved := 0.0
	for n in saved.size():
		moved = maxf(moved, absf(terrain.heights[n] - saved[n]))
	_check(moved == 0.0 and is_equal_approx(money, brush.money), "the undo button restores ground and gold")
	await _rest_mouse()


func _test_help() -> void:
	await _click(ui.help_button)
	await _wait(0.3)
	_check(ui.help_card.visible, "the help button opens the help card")
	_audit("help open")
	await _shot("3_help")
	await _key(KEY_F1)
	await _wait(0.3)
	_check(not ui.help_card.visible, "F1 closes it")
	await _rest_mouse()


func _test_tower() -> void:
	var spot := _good_spot()
	var money: float = brush.money
	await _click(ui.build_button)
	await _frames(2)
	_check(towers.mode == towers.Mode.PLACING and ui.build_button.button_pressed, "the tower button starts placing")
	await _hover_world(spot)
	await _frames(3)
	_check(ui.hint_panel.visible and towers.hint_text != "", "placing shows a hint: %s" % towers.hint_line())
	_audit("placing")
	await _wait(0.2)
	await _shot("4_placing")
	await _click_world(spot)
	_check(towers.towers.size() == 1 and brush.money < money, "clicking the ground builds a tower")
	_check(towers.mode == towers.Mode.AIMING, "building moves on to aiming")
	await _hover_world(spot + Vector3(-30.0, 0.0, 20.0))
	await _frames(3)
	await _button_event(brush.test_mouse, true)
	await _button_event(brush.test_mouse, false)
	_check(towers.mode == towers.Mode.IDLE, "a click confirms the aim")
	await _wait(0.3)
	var tower: Dictionary = towers.towers[0]
	_check(ui.tower_card.visible, "the tower card opens")
	_audit("tower card")
	await _rest_mouse()
	await _shot("5_tower_card")
	var yaw_before: float = tower["yaw"]
	await _drag(ui.yaw_slider, 0.5, 0.8)
	# The slider's ends sit half a grabber in from its edges, which shifts the value a little.
	_check(absf(rad_to_deg(float(tower["yaw"])) - _slider_value(ui.yaw_slider, 0.8)) < 4.0 and tower["yaw"] != yaw_before, "dragging the slider turns the gun to %d deg" % int(rad_to_deg(float(tower["yaw"]))))
	await _drag(ui.pitch_slider, 0.5, 0.25)
	_check(absf(rad_to_deg(float(tower["pitch"])) - _slider_value(ui.pitch_slider, 0.25)) < 4.0, "dragging the slider tilts the gun to %d deg" % int(rad_to_deg(float(tower["pitch"]))))
	var shown_yaw := int(round(rad_to_deg(float(tower["yaw"]))))
	await _frames(2)
	_check(ui.yaw_value.text == "%d°" % shown_yaw, "the card shows the new angle %s" % ui.yaw_value.text)
	# Dragging all the way must not make the grabber jump to the other end.
	await _drag(ui.yaw_slider, 0.8, 1.0)
	_check(ui.yaw_slider.value >= 170.0, "dragged to the end, the slider stays there: %d" % int(ui.yaw_slider.value))
	await _frames(2)
	_check(absf(rad_to_deg(float(tower["yaw"]))) >= 170.0, "the gun faces that way: %d deg" % int(rad_to_deg(float(tower["yaw"]))))
	await _click(ui.aim_button)
	await _frames(2)
	_check(towers.mode == towers.Mode.AIMING, "the aim button starts aiming")
	await _key(KEY_ESCAPE)
	_check(towers.mode == towers.Mode.IDLE, "Esc stops aiming")
	await _click(ui.close_button)
	await _wait(0.3)
	_check(towers.selected.is_empty() and not ui.tower_card.visible, "the close button shuts the card")
	await _hover_world(Vector3(tower["center"]) + Vector3(tower["normal"]) * 6.0)
	await _button_event(brush.test_mouse, true)
	await _button_event(brush.test_mouse, false)
	await _wait(0.3)
	_check(towers.selected == tower and ui.tower_card.visible, "clicking the tower opens it again")
	money = brush.money
	await _click(ui.sell_button)
	await _wait(0.3)
	_check(towers.towers.is_empty() and brush.money > money and not ui.tower_card.visible, "the sell button refunds %d" % int(brush.money - money))
	await _rest_mouse()
	towers.place_at(spot.x, spot.z, 0.0, 0.0, false)
	var placed: Dictionary = towers.towers[0]
	var best: PackedFloat32Array = paths.core.best_aim(placed["apex"].x, placed["apex"].y, placed["apex"].z, 0.0, 0.0, 1.0, towers.normal_spec["half_angle"], towers.normal_spec["range"])
	towers._set_tower_aim(placed, atan2(best[0], best[2]), asin(best[1]))
	await _frames(2)
	var lit := func() -> bool:
		for id: int in ui.tool_buttons:
			if ui.tool_buttons[id].button_pressed:
				return true
		return false
	_check(not lit.call(), "no tool is lit while a tower is selected")
	await _key(KEY_E)
	await _wait(0.3)
	_check(towers.selected.is_empty() and not ui.tower_card.visible and lit.call(), "picking a tool closes the tower card and lights the tool")
	await _key(KEY_T)
	await _frames(2)
	_check(towers.mode == towers.Mode.PLACING and not lit.call(), "no tool is lit while placing")
	await _click(ui.tool_buttons[terrain.TOOL_LOWER])
	await _frames(2)
	_check(towers.mode == towers.Mode.IDLE and ui.tool_buttons[terrain.TOOL_LOWER].button_pressed, "clicking a tool stops placing")
	await _rest_mouse()
	await _wait(0.3)


func _test_forecast() -> void:
	var saved: PackedFloat32Array = terrain.heights.duplicate()
	var time_before: String = ui.forecast_time.text
	_check(ui.route_rows["walk"]["row"].visible and not ui.route_rows["bridge"]["row"].visible, "the forecast starts with only walking")
	paths._carve(Vector2(-170.0, -58.0), Vector2(170.0, -58.0), 11.0, -16.0)
	paths._apply_test_terrain()
	await _frames(3)
	_check(ui.route_rows["bridge"]["row"].visible and ui.forecast_time.text != time_before, "a deep trench adds bridging: %s, %s" % [ui.forecast_time.text, ui.route_rows["bridge"]["value"].text])
	await _wait(0.4)
	await _shot("6_forecast_bridge")
	paths._restore_terrain(saved)
	paths._apply_test_terrain()
	await _frames(3)


func _test_gold() -> void:
	var money: float = brush.money
	brush.money = 100.0
	await _frames(3)
	_check(ui.build_button.disabled, "the tower button disables when gold runs short")
	await _click(ui.build_button)
	_check(towers.mode == towers.Mode.IDLE, "a disabled tower button does nothing")
	await _wait(0.5)
	await _rest_mouse()
	await _shot("7_short_of_gold")
	brush.money = 0.0
	var spot := Vector3(40.0, terrain.height_at(40.0, 40.0), 40.0)
	await _hover_world(spot)
	await _button_event(brush.test_mouse, true)
	await _frames(3)
	_check(ui.hint_panel.visible and ui.hint_main.text.contains("金币用完"), "painting with no gold explains why nothing happens")
	await _button_event(brush.test_mouse, false)
	await _rest_mouse()
	brush.money = money
	# The number counts up quickly but smoothly, so a jump this large takes a moment.
	await _wait(1.2)
	_check(ui.gold_label.text == str(int(round(money))), "the gold number catches up: %s" % ui.gold_label.text)


func _test_speed() -> void:
	for n in ui.speed_buttons.size():
		await _click(ui.speed_buttons[n])
		await _frames(2)
		_check(is_equal_approx(paths.speed, paths.SPEEDS[n]) and ui.speed_buttons[n].button_pressed, "the %s button sets the speed" % paths.SPEED_NAMES[n])
	await _key(KEY_1)
	await _frames(2)
	_check(ui.speed_buttons[0].button_pressed, "the 1 key lights the 1x button")
	await _rest_mouse()


func _test_battle() -> void:
	await _click(ui.start_button)
	await _frames(2)
	_check(paths.phase == paths.Phase.BATTLE, "the start button starts the battle")
	await _wait(0.5)
	_check(ui.banner.visible, "a banner announces the wave: %s" % ui.banner_title.text)
	_audit("battle with banner")
	await _shot("8_wave_banner")
	await _rest_mouse()
	await _wait(0.2)
	_check(not ui.tool_dock.visible and not ui.start_button.visible and not ui.forecast_card.visible, "terrain tools, start button and forecast hide in battle")
	await _click(ui.speed_buttons[4])
	await _frames(2)
	_check(is_equal_approx(paths.speed, 8.0), "speed can change during battle")
	await _click(ui.build_button)
	await _frames(2)
	_check(towers.mode == towers.Mode.PLACING, "towers can still be placed in battle")
	await _key(KEY_ESCAPE)
	await _rest_mouse()
	var shot_taken := false
	while paths.phase == paths.Phase.BATTLE:
		await get_tree().process_frame
		if not shot_taken and paths.core.kills() >= 2:
			shot_taken = true
			towers.select(towers.towers[0])
			await _wait(0.3)
			_audit("battle with tower card")
			await _shot("9_battle")
			towers.deselect()
	await _frames(2)
	_check(ui.banner.visible and ui.banner_title.text.ends_with("波结束"), "a banner sums up the wave: %s" % ui.banner_sub.text)
	await _wait(0.5)
	_check(ui.tool_dock.visible and ui.start_button.visible and ui.forecast_card.visible, "everything returns after the wave")
	_audit("after battle")
	await _shot("10_wave_end")
	await _click(ui.speed_buttons[0])
	await _rest_mouse()
	await _wait(3.2)
	_check(not ui.banner.visible, "the banner fades away by itself")


func _test_keys() -> void:
	await _key(KEY_F2)
	await _frames(2)
	_check(not ui.root.visible, "F2 hides the interface")
	await _shot("11_hidden")
	await _key(KEY_F2)
	await _frames(2)
	_check(ui.root.visible, "F2 brings it back")
	await _key(KEY_F3)
	await _wait(0.4)
	_check(ui.fps_label.text.contains("路线"), "F3 shows the timing details")
	await _key(KEY_F1)
	await _wait(0.3)
	_audit("help and timing details open together")
	await _key(KEY_ESCAPE)
	await _wait(0.3)
	_check(not ui.help_card.visible, "Esc closes the help card")
	await _key(KEY_F3)


func _measure(frames: int) -> float:
	var begin := Time.get_ticks_usec()
	await _frames(frames)
	return float(frames) / (float(Time.get_ticks_usec() - begin) / 1000000.0)


## What the interface itself costs, with hidden and shown frames in turn to cancel out any drift.
func _test_cost() -> void:
	await _wait(1.0)
	var hidden_total := 0.0
	var shown_total := 0.0
	for n in 3:
		ui.root.visible = false
		await _frames(30)
		hidden_total += await _measure(200)
		ui.root.visible = true
		await _frames(30)
		shown_total += await _measure(200)
	print("UI cost: %.0f fps without the interface, %.0f fps with it" % [hidden_total / 3.0, shown_total / 3.0])
