extends CanvasLayer
## Everything on screen that is not the world. It reads the game's state each frame and calls
## its public functions, and game logic never touches these controls.

const Kit = preload("res://scripts/ui_kit.gd")
const GameConfig = preload("res://scripts/game_config.gd")
const EDGE := 20.0
## How far above the bottom edge the hint sits, clear of the tool dock.
const HINT_ABOVE_DOCK := -192.0
const FLOAT_RISE := 56.0
const FLOAT_SECONDS := 2.2
## Wide enough for a preset's size slider with its 自动 switch, so the dock keeps its width between tools.
const SLIDER_AREA_WIDTH := 262.0
const HELP_ROWS: Array[Array] = [
	["左键", "涂抹地形 / 建造"], ["Shift", "反向涂抹"], ["Ctrl + 滚轮", "笔刷大小"], ["Alt + 滚轮", "笔刷力度"],
	["Z X N M", "小山丘 / 土堤 / 大坑 / 隧道"], ["点击隧道口", "查看或填平隧道"],
	["Ctrl + Z", "撤销上一步摆放操作"], ["T", "放置防御塔"], ["点击塔", "查看攻击范围"], ["V", "用鼠标瞄准"],
	["方向键", "微调炮口"], ["Esc", "取消或关闭"], ["B", "开始战斗"], ["空格", "暂停 / 继续战斗"], ["1 - 5", "战斗速度"], ["右键拖动", "旋转镜头"],
	["滚轮", "缩放镜头"], ["W A S D", "移动镜头"], ["C", "切换视角"], ["F1", "操作说明"], ["F2", "隐藏界面"], ["F3", "性能详情"],
]

var main: Node3D
var brush: Node
var paths: Node
var towers: Node
var tools: Node

var root: Control
var top_column: VBoxContainer
var gold_pill: PanelContainer
var gold_label: Label
var home_pill: PanelContainer
var home_label: Label
var shown_home := -1
var help_button: Button
var menu_button: Button
## Set by the first press of the menu button. A second press soon after leaves for the level menu.
var leave_armed_until := 0
var fps_chip: PanelContainer
var fps_label: Label
var phase_icon: TextureRect
var phase_title: Label
var phase_sub: Label
var phase_bar: ProgressBar
var phase_card: PanelContainer
var forecast_card: PanelContainer
var forecast_time: Label
var route_rows := {}
var wave_title: Label
var wave_rows: VBoxContainer
var gate_rows: Array[Dictionary] = []
var shown_wave := -1
var shown_options := -1
var forecast_shown := true
var tool_dock: PanelContainer
var tool_buttons := {}
var preset_buttons := {}
var tunnel_card: PanelContainer
var tunnel_length: Label
var tunnel_sell_label: Label
var end_screen: Control
var end_title: Label
var end_sub: Label
var end_stars: HBoxContainer
const STAR_SIZE := 52.0
var retry_button: Button
var next_button: Button
var undo_button: Button
var radius_slider: HSlider
var radius_value: Label
var strength_slider: HSlider
var strength_value: Label
var brush_sliders: VBoxContainer
## Size sliders for each preset, by preset id: {"box", "rows": {key: [slider, value label]}, "auto"}.
var preset_sliders := {}
var tower_dock: PanelContainer
var build_button: Button
var build_price: Label
var build_contents: VBoxContainer
## Per tower type: its "button", "price" label and "contents".
var build_buttons := {}
var battle_dock: VBoxContainer
var pause_button: Button
var speed_buttons: Array[Button] = []
var start_button: Button
var tower_card: PanelContainer
var tower_name: Label
var tower_lean: Label
var stat_values := {}
var effect_label: Label
## Upgrade tree chips by node id ("" is the base tower), and what each needs to be reached.
var tree_chips := {}
var tree_ancestors := {}
var upgrade_box: VBoxContainer
var tree_box: VBoxContainer
var tree_type := ""
var aim_box: VBoxContainer
var tower_icon: TextureRect
var upgrade_key := ""
var upgrade_rows: Array[Dictionary] = []
var chip_styles := {}
var yaw_slider: HSlider
var yaw_value: Label
var pitch_slider: HSlider
var pitch_value: Label
var aim_button: Button
var sell_button: Button
var sell_label: Label
var aim_dragging := false
var close_button: Button
var hint_panel: PanelContainer
var hint_dot: Panel
var hint_main: Label
var hint_sub: Label
var banner: PanelContainer
var banner_title: Label
var banner_sub: Label
var help_card: PanelContainer

var tip_text := ""
var shown_gold := 0.0
var last_money := 0.0
var shown_phase := -1
var shown_plan := -1
var shown_selection := {}
var card_timer := 0.0
var fps_timer := 0.0
var show_details := false
var banner_tween: Tween


func setup(main_node: Node3D, brush_node: Node, path_node: Node, tower_node: Node, tools_node: Node) -> void:
	main = main_node
	brush = brush_node
	paths = path_node
	towers = tower_node
	tools = tools_node
	layer = 5
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = Kit.make_theme()
	root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(root)
	_build_top_left()
	_build_phase_card()
	_build_forecast()
	_build_tool_dock()
	_build_tower_dock()
	_build_battle_dock()
	_build_tower_card()
	_build_tunnel_card()
	_build_hint()
	_build_banner()
	_build_help()
	_build_end_screen()
	shown_gold = brush.money
	last_money = brush.money
	towers.selection_changed.connect(_on_selection_changed)
	towers.aim_changed.connect(_refresh_tower_card)
	tools.state_changed.connect(_on_tools_changed)
	paths.plan_changed.connect(_on_plan_changed)
	paths.level_finished.connect(_on_level_finished)
	_on_selection_changed()
	_sync_phase()
	_sync_forecast()
	show_banner(paths.level["name"], paths.level["goal_hint"], 5.0)


## Pins a control to a point on the screen. It grows away from the nearest screen edge.
func _place(control: Control, anchor_x: float, anchor_y: float, x: float, y: float) -> void:
	control.anchor_left = anchor_x
	control.anchor_right = anchor_x
	control.anchor_top = anchor_y
	control.anchor_bottom = anchor_y
	control.offset_left = x
	control.offset_right = x
	control.offset_top = y
	control.offset_bottom = y
	control.grow_horizontal = _grow(anchor_x)
	control.grow_vertical = _grow(anchor_y)
	control.set_meta("rest_y", y)
	root.add_child(control)


func _grow(anchor: float) -> Control.GrowDirection:
	if anchor <= 0.0:
		return Control.GROW_DIRECTION_END
	if anchor >= 1.0:
		return Control.GROW_DIRECTION_BEGIN
	return Control.GROW_DIRECTION_BOTH


func _panel(type_name: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = type_name
	return panel


func _label(text: String, type_name := "") -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = type_name
	return label


## Layout boxes ignore the mouse, so the empty space inside them still counts as the world.
func _hbox(gap: int) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", gap)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return box


func _vbox(gap: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", gap)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return box


func _icon(icon_name: String, size: float, tint := Color.WHITE) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = Kit.icon(icon_name)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = Vector2(size, size)
	rect.self_modulate = tint
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _button(text: String, type_name: String, icon_name := "") -> Button:
	var button := Button.new()
	button.text = text
	button.theme_type_variation = type_name
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if icon_name != "":
		button.icon = Kit.icon(icon_name)
	_juice(button)
	return button


## A wide button whose icon and text stay together in the middle. Returns the button and its label.
func _wide_button(text: String, type_name: String, icon_name: String, tint: Color, height: float, label_type := "") -> Array:
	var button := _button("", type_name)
	button.custom_minimum_size = Vector2(0.0, height)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(center)
	var row := _hbox(9)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(row)
	row.add_child(_icon(icon_name, 22.0, tint))
	var label := _label(text, label_type)
	label.add_theme_color_override("font_color", tint)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	return [button, label]


func _slider(low: float, high: float, step: float, width: float) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.custom_minimum_size = Vector2(width, 22.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.focus_mode = Control.FOCUS_NONE
	slider.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return slider


## A key shown as a little tag in the corner of a button.
func _badge(parent: Control, letter: String) -> void:
	var badge := _panel("BadgePanel")
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	badge.offset_right = -5.0
	badge.offset_left = -5.0
	badge.offset_top = 5.0
	badge.offset_bottom = 5.0
	var label := _label(letter, "BadgeLabel")
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(label)
	parent.add_child(badge)


## Gently grows on hover and dips when pressed.
func _juice(control: Control) -> void:
	control.resized.connect(func() -> void: control.pivot_offset = control.size * 0.5)
	control.mouse_entered.connect(_bounce.bind(control, 1.04))
	control.mouse_exited.connect(_bounce.bind(control, 1.0))
	if control is BaseButton:
		control.button_down.connect(_bounce.bind(control, 0.96))
		control.button_up.connect(_bounce.bind(control, 1.0))


func _bounce(control: Control, target: float) -> void:
	if control.has_meta("bounce"):
		var old: Tween = control.get_meta("bounce")
		if old.is_valid():
			old.kill()
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "scale", Vector2.ONE * target, 0.14)
	control.set_meta("bounce", tween)


func _pulse(control: Control) -> void:
	control.pivot_offset = control.size * 0.5
	if control.has_meta("bounce"):
		var old: Tween = control.get_meta("bounce")
		if old.is_valid():
			old.kill()
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "scale", Vector2.ONE * 1.07, 0.09)
	tween.tween_property(control, "scale", Vector2.ONE, 0.2)
	control.set_meta("bounce", tween)


## Slides a dock off the bottom of the screen, or back, while fading it.
func _slide(control: Control, show: bool) -> void:
	var rest: float = control.get_meta("rest_y")
	var hidden_y := rest + 220.0
	if control.has_meta("slide"):
		var old: Tween = control.get_meta("slide")
		if old.is_valid():
			old.kill()
	var tween := create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if show:
		control.visible = true
	var target := rest if show else hidden_y
	tween.tween_property(control, "offset_top", target, 0.3)
	tween.tween_property(control, "offset_bottom", target, 0.3)
	tween.tween_property(control, "modulate:a", 1.0 if show else 0.0, 0.24)
	if not show:
		tween.chain().tween_callback(control.hide)
	control.set_meta("slide", tween)


func _fade(control: Control, show: bool) -> void:
	if control.has_meta("fade"):
		var old: Tween = control.get_meta("fade")
		if old.is_valid():
			old.kill()
	if show == control.visible and control.modulate.a >= 0.99:
		return
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	if show:
		control.visible = true
	tween.tween_property(control, "modulate:a", 1.0 if show else 0.0, 0.16)
	if not show:
		tween.tween_callback(control.hide)
	control.set_meta("fade", tween)


func _tip(control: Control, text: String) -> void:
	control.mouse_entered.connect(func() -> void: tip_text = text)
	control.mouse_exited.connect(func() -> void:
		if tip_text == text:
			tip_text = "")


## Gold, the frame rate and the help card share one column, so none of them can overlap.
func _build_top_left() -> void:
	top_column = _vbox(10)
	_place(top_column, 0.0, 0.0, EDGE, EDGE)
	var row := _hbox(10)
	top_column.add_child(row)
	gold_pill = _panel("PillPanel")
	row.add_child(gold_pill)
	var inner := _hbox(10)
	gold_pill.add_child(inner)
	inner.add_child(_icon("coin", 30.0))
	gold_label = _label("0", "NumberLabel")
	gold_label.custom_minimum_size = Vector2(92.0, 0.0)
	inner.add_child(gold_label)
	_tip(gold_pill, "金币：改地形和建塔都要花钱，击杀敌人可以获得")
	help_button = _button("", "RoundButton", "help")
	help_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	help_button.pressed.connect(toggle_help)
	_tip(help_button, "操作说明  F1")
	row.add_child(help_button)
	menu_button = _button("", "RoundButton", "menu")
	menu_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	menu_button.pressed.connect(_on_menu_pressed)
	_tip(menu_button, "返回选关")
	row.add_child(menu_button)
	home_pill = _panel("PillPanel")
	row.add_child(home_pill)
	var home_inner := _hbox(8)
	home_pill.add_child(home_inner)
	home_inner.add_child(_icon("heart", 28.0, Kit.CORAL))
	home_label = _label("", "NumberLabel")
	home_inner.add_child(home_label)
	_tip(home_pill, "家园生命：每有一名敌人抵达就减少 1，归零就输了")
	home_pill.visible = paths.home_hp_max > 0
	fps_chip = _panel("ChipPanel")
	fps_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fps_chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	top_column.add_child(fps_chip)
	fps_label = _label("", "MutedLabel")
	fps_chip.add_child(fps_label)


func _build_phase_card() -> void:
	phase_card = _panel("PillPanel")
	phase_card.custom_minimum_size = Vector2(430.0, 0.0)
	_place(phase_card, 0.5, 0.0, 0.0, EDGE)
	var stack := _vbox(6)
	phase_card.add_child(stack)
	var row := _hbox(10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_child(row)
	phase_icon = _icon("sakura", 28.0)
	row.add_child(phase_icon)
	phase_title = _label("", "TitleLabel")
	row.add_child(phase_title)
	phase_sub = _label("", "MutedLabel")
	row.add_child(phase_sub)
	phase_bar = ProgressBar.new()
	phase_bar.show_percentage = false
	phase_bar.custom_minimum_size = Vector2(0.0, 8.0)
	phase_bar.max_value = 1.0
	phase_bar.step = 0.001
	phase_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(phase_bar)


func _build_forecast() -> void:
	forecast_card = _panel("CardPanel")
	forecast_card.custom_minimum_size = Vector2(290.0, 0.0)
	_place(forecast_card, 1.0, 0.0, -EDGE, EDGE)
	var stack := _vbox(7)
	forecast_card.add_child(stack)
	wave_title = _label("", "MutedLabel")
	stack.add_child(wave_title)
	wave_rows = _vbox(5)
	stack.add_child(wave_rows)
	stack.add_child(HSeparator.new())
	stack.add_child(_label("敌人路线预告", "MutedLabel"))
	var time_row := _hbox(8)
	stack.add_child(time_row)
	time_row.add_child(_icon("clock", 24.0, Kit.INK_SOFT))
	forecast_time = _label("", "NumberLabel")
	time_row.add_child(forecast_time)
	time_row.add_child(_label("后最快到家", "MutedLabel"))
	for gate: Dictionary in paths.gates:
		var gate_row := _vbox(0)
		stack.add_child(gate_row)
		var top := _hbox(8)
		gate_row.add_child(top)
		var route_name := _label("", "ValueLabel")
		route_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top.add_child(route_name)
		var time := _label("", "ValueLabel")
		top.add_child(time)
		var others := _label("", "MutedLabel")
		others.add_theme_font_size_override("font_size", 14)
		gate_row.add_child(others)
		gate_rows.append({"route": route_name, "time": time, "others": others})
	for entry: Array in [["walk", "步行", Kit.ROUTE_WALK], ["climb", "爬坡", Kit.ROUTE_CLIMB], ["boat", "渡水", Kit.ROUTE_BOAT], ["bridge", "搭桥", Kit.ROUTE_BRIDGE], ["built", "走已有的桥", Kit.ROUTE_BUILT], ["tunnel", "穿隧道", Kit.ROUTE_TUNNEL]]:
		var row := _hbox(8)
		row.add_child(_dot(entry[2]))
		row.add_child(_label(entry[1], "MutedLabel"))
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(spacer)
		var value := _label("", "ValueLabel")
		row.add_child(value)
		stack.add_child(row)
		route_rows[entry[0]] = {"row": row, "value": value}


func _dot(color: Color) -> Panel:
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(12.0, 12.0)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.add_theme_stylebox_override("panel", Kit.box(color, 6))
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return dot


func _build_tool_dock() -> void:
	tool_dock = _panel("DockPanel")
	_place(tool_dock, 0.5, 1.0, 0.0, -EDGE)
	var rows := _vbox(4)
	tool_dock.add_child(rows)
	var preset_row := _hbox(4)
	rows.add_child(preset_row)
	for entry: Dictionary in tools.tool_list():
		var button: Button = _wide_button(entry["name"], "ToolButton", entry["icon"], Kit.INK_SOFT, 46.0)[0]
		button.toggle_mode = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var id: String = entry["id"]
		button.pressed.connect(func() -> void: tools.activate(id))
		_badge(button, entry["key"])
		_tip(button, entry["tip"])
		preset_row.add_child(button)
		preset_buttons[id] = button
	var row := _hbox(4)
	rows.add_child(row)
	for entry: Dictionary in brush.TOOL_INFO:
		var button := _button(entry["name"], "ToolButton", entry["icon"])
		button.toggle_mode = true
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		button.custom_minimum_size = Vector2(74.0, 76.0)
		var id: int = entry["id"]
		button.pressed.connect(func() -> void: brush.select_tool(id))
		_badge(button, entry["letter"])
		_tip(button, entry["tip"])
		row.add_child(button)
		tool_buttons[id] = button
	row.add_child(VSeparator.new())
	# The brush sliders and each preset's size sliders share one spot; only the active tool's show.
	var slider_area := _hbox(0)
	slider_area.custom_minimum_size.x = SLIDER_AREA_WIDTH
	row.add_child(slider_area)
	var sliders := _vbox(6)
	sliders.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sliders.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider_area.add_child(sliders)
	brush_sliders = sliders
	for preset: Dictionary in tools.presets:
		_build_preset_sliders(slider_area, preset)
	var radius_row := _dock_slider(sliders, "大小", brush.min_radius, brush.max_radius, 1.0)
	radius_slider = radius_row[0]
	radius_value = radius_row[1]
	radius_slider.value_changed.connect(func(value: float) -> void: brush.radius = value)
	_tip(radius_slider, "笔刷大小，也可以用 Ctrl + 滚轮")
	var strength_row := _dock_slider(sliders, "力度", brush.min_strength, brush.max_strength, 0.1)
	strength_slider = strength_row[0]
	strength_value = strength_row[1]
	strength_slider.value_changed.connect(func(value: float) -> void: brush.strength = value)
	_tip(strength_slider, "笔刷力度，也可以用 Alt + 滚轮")
	row.add_child(VSeparator.new())
	undo_button = _button("撤销", "ToolButton", "undo")
	undo_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	undo_button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	undo_button.custom_minimum_size = Vector2(66.0, 76.0)
	undo_button.pressed.connect(func() -> void: brush.undo())
	row.add_child(undo_button)


func _build_preset_sliders(parent: Control, preset: Dictionary) -> void:
	var box := _vbox(4)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.visible = false
	parent.add_child(box)
	var rows := {}
	var auto_button: Button = null
	for setting: Dictionary in preset.get("adjust", []):
		var key: String = setting["key"]
		var parts := _dock_slider(box, setting["name"], setting["min"], setting["max"], setting["step"])
		var slider: HSlider = parts[0]
		slider.value_changed.connect(func(value: float) -> void: tools.set_size(key, value))
		var tip := "%s（米）" % setting["name"]
		match String(setting.get("wheel", "")):
			"ctrl":
				tip += "，也可以用 Ctrl + 滚轮"
			"alt":
				tip += "，也可以用 Alt + 滚轮"
		_tip(slider, tip)
		rows[key] = parts
		if key == "length" and preset.get("fit_ends", false):
			auto_button = _button("自动", "SegmentButton")
			auto_button.toggle_mode = true
			auto_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			auto_button.toggled.connect(func(on: bool) -> void: tools.set_stretch(on))
			_tip(auto_button, "打开时土堤自动伸到两边山坡。想留一条缝，就关掉它，自己定长度")
			slider.get_parent().add_child(auto_button)
	preset_sliders[preset["id"]] = {"box": box, "rows": rows, "auto": auto_button}


## Shows the active preset's sizes in place of the brush sliders. While a ridge stretches by itself,
## its length slider follows the length it stretched to.
func _sync_preset_sliders() -> void:
	var shown := false
	for id: String in preset_sliders:
		var entry: Dictionary = preset_sliders[id]
		var active: bool = tools.active_id == id
		entry["box"].visible = active
		if not active:
			continue
		shown = true
		var rows: Dictionary = entry["rows"]
		for key: String in rows:
			var slider: HSlider = rows[key][0]
			var value: float = tools.sizes[id][key]
			if key == "length" and tools.stretching():
				value = tools.preview_length
			slider.set_value_no_signal(value)
			rows[key][1].text = str(int(round(value)))
		if entry["auto"] != null:
			entry["auto"].set_pressed_no_signal(tools.stretch)
	brush_sliders.visible = not shown


func _dock_slider(parent: Control, text: String, low: float, high: float, step: float) -> Array:
	var row := _hbox(8)
	parent.add_child(row)
	row.add_child(_label(text, "MutedLabel"))
	var slider := _slider(low, high, step, 120.0)
	row.add_child(slider)
	var value := _label("", "ValueLabel")
	value.custom_minimum_size = Vector2(32.0, 0.0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	return [slider, value]


## One button per tower type, in the order of data/towers.json. build_button is the plain cannon's.
func _build_tower_dock() -> void:
	tower_dock = _panel("DockPanel")
	_place(tower_dock, 0.0, 1.0, EDGE, -EDGE)
	var row := _hbox(6)
	tower_dock.add_child(row)
	for type: String in towers.specs:
		var spec: Dictionary = towers.specs[type]
		var button := Button.new()
		button.theme_type_variation = "ToolButton"
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(92.0, 76.0)
		button.pressed.connect(towers.toggle_placing.bind(type))
		_juice(button)
		_tip(button, "%s  %s" % [spec.get("tip", spec["name"]), spec.get("key", "")])
		row.add_child(button)
		var stack := _vbox(1)
		stack.set_anchors_preset(Control.PRESET_FULL_RECT)
		stack.alignment = BoxContainer.ALIGNMENT_CENTER
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(stack)
		var type_icon := _icon(String(spec.get("icon", "tower")), 30.0, Kit.INK_SOFT)
		type_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		stack.add_child(type_icon)
		var price_row := _hbox(4)
		price_row.alignment = BoxContainer.ALIGNMENT_CENTER
		price_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_child(price_row)
		price_row.add_child(_icon("coin", 16.0))
		var price := _label(str(int(spec["cost"])), "ValueLabel")
		price.mouse_filter = Control.MOUSE_FILTER_IGNORE
		price_row.add_child(price)
		var name_label := _label(spec["name"], "MutedLabel")
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stack.add_child(name_label)
		_badge(button, String(spec.get("key", "")))
		build_buttons[type] = {"button": button, "price": price, "contents": stack}
	build_button = build_buttons["normal"]["button"]
	build_price = build_buttons["normal"]["price"]
	build_contents = build_buttons["normal"]["contents"]


func _build_battle_dock() -> void:
	battle_dock = _vbox(10)
	battle_dock.alignment = BoxContainer.ALIGNMENT_END
	_place(battle_dock, 1.0, 1.0, -EDGE, -EDGE)
	var speed_pill := _panel("PillPanel")
	speed_pill.size_flags_horizontal = Control.SIZE_SHRINK_END
	battle_dock.add_child(speed_pill)
	var row := _hbox(2)
	speed_pill.add_child(row)
	pause_button = _button("暂停", "SegmentButton")
	pause_button.toggle_mode = true
	pause_button.custom_minimum_size = Vector2(52.0, 34.0)
	pause_button.pressed.connect(paths.toggle_battle_pause)
	_tip(pause_button, "空格暂停或继续战斗，暂停时可以建塔、升级和拆塔")
	row.add_child(pause_button)
	var speed_icon := _icon("speed", 22.0, Kit.INK_SOFT)
	row.add_child(speed_icon)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(4.0, 0.0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap)
	for n in paths.SPEEDS.size():
		var button := _button(paths.SPEED_NAMES[n], "SegmentButton")
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(46.0, 34.0)
		button.pressed.connect(paths.set_speed.bind(n))
		_tip(button, "战斗速度 %s  按 %d" % [paths.SPEED_NAMES[n], n + 1])
		row.add_child(button)
		speed_buttons.append(button)
	start_button = _wide_button("开始战斗", "PrimaryButton", "flag", Color.WHITE, 58.0, "TitleLabel")[0]
	start_button.pressed.connect(func() -> void: paths.start_battle())
	_badge(start_button, "B")
	_tip(start_button, "敌人出发后不能再改地形，但还能放塔和拆塔  B")
	battle_dock.add_child(start_button)


func _build_tower_card() -> void:
	tower_card = _panel("CardPanel")
	tower_card.custom_minimum_size = Vector2(340.0, 0.0)
	_place(tower_card, 1.0, 0.5, -EDGE, 0.0)
	tower_card.visible = false
	var stack := _vbox(10)
	tower_card.add_child(stack)
	var head := _hbox(8)
	stack.add_child(head)
	tower_icon = _icon("tower", 32.0, Kit.SAKURA_DEEP)
	head.add_child(tower_icon)
	var names := _vbox(0)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(names)
	tower_name = _label("", "TitleLabel")
	names.add_child(tower_name)
	tower_lean = _label("", "MutedLabel")
	names.add_child(tower_lean)
	close_button = _button("", "RoundButton", "close")
	close_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close_button.theme_type_variation = "ToolButton"
	close_button.pressed.connect(func() -> void: towers.deselect())
	_tip(close_button, "关闭  Esc")
	head.add_child(close_button)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 6)
	stack.add_child(grid)
	for entry: Array in [["cone", "cone", "范围"], ["reach", "reach", "射程"], ["damage", "damage", "伤害"], ["rate", "rate", "射速"], ["splash", "blast", "爆炸"], ["route", "route", "覆盖路线"], ["kills", "kills", "击杀"]]:
		var cell := _hbox(6)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_child(_icon(entry[1], 18.0, Kit.INK_SOFT))
		cell.add_child(_label(entry[2], "MutedLabel"))
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(spacer)
		var value := _label("", "ValueLabel")
		cell.add_child(value)
		grid.add_child(cell)
		stat_values[entry[0]] = value
	effect_label = _label("", "MutedLabel")
	effect_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(effect_label)
	_build_upgrade_section(stack)
	# Aiming, hidden for a catapult, which throws all round.
	aim_box = _vbox(10)
	stack.add_child(aim_box)
	aim_box.add_child(HSeparator.new())
	aim_box.add_child(_label("炮口方向", "MutedLabel"))
	var yaw_row := _dock_slider(aim_box, "水平", -180.0, 180.0, 1.0)
	yaw_slider = yaw_row[0]
	yaw_value = yaw_row[1]
	yaw_value.custom_minimum_size = Vector2(48.0, 0.0)
	var pitch_row := _dock_slider(aim_box, "俯仰", -90.0, 90.0, 1.0)
	pitch_slider = pitch_row[0]
	pitch_value = pitch_row[1]
	pitch_value.custom_minimum_size = Vector2(48.0, 0.0)
	for slider: HSlider in [yaw_slider, pitch_slider]:
		slider.value_changed.connect(_on_aim_slider)
		slider.drag_started.connect(func() -> void:
			aim_dragging = true
			towers.begin_slider_aim())
		slider.drag_ended.connect(func(changed: bool) -> void:
			aim_dragging = false
			towers.end_slider_aim(changed))
	aim_button = _wide_button("用鼠标瞄准", "Button", "aim", Kit.INK, 42.0)[0]
	aim_button.pressed.connect(func() -> void: towers.start_aiming())
	_badge(aim_button, "V")
	_tip(aim_button, "移动鼠标来瞄准，左键确定")
	aim_box.add_child(aim_button)
	var sell_parts := _wide_button("", "DangerButton", "trash", Kit.CORAL_INK, 42.0)
	sell_button = sell_parts[0]
	sell_label = sell_parts[1]
	sell_button.pressed.connect(func() -> void: towers.sell_selected())
	stack.add_child(sell_button)


## The whole upgrade tree as rows of chips, one row per level, then buttons for what can be bought next.
func _build_upgrade_section(stack: VBoxContainer) -> void:
	stack.add_child(HSeparator.new())
	stack.add_child(_label("升级路线", "MutedLabel"))
	chip_styles = {
		"taken": Kit.box(Kit.SAKURA_PALE, 10, Vector2(6.0, 3.0), Kit.SAKURA, 2),
		"open": Kit.box(Kit.PAPER_SOFT, 10, Vector2(6.0, 3.0), Kit.SAKURA_DEEP, 1),
		"later": Kit.box(Kit.PAPER_SOFT, 10, Vector2(6.0, 3.0)),
		"closed": Kit.box(Color(1.0, 1.0, 1.0, 0.0), 10, Vector2(6.0, 3.0)),
	}
	tree_box = _vbox(4)
	stack.add_child(tree_box)
	upgrade_box = _vbox(6)
	stack.add_child(upgrade_box)


## Draws the chips for one tower type's tree. The card is shared, so this runs when a different type is selected.
func _fill_upgrade_tree(type: String) -> void:
	tree_type = type
	for child in tree_box.get_children():
		tree_box.remove_child(child)
		child.queue_free()
	tree_chips.clear()
	tree_ancestors.clear()
	upgrade_key = "-"
	var tree := tree_box
	var level: Array = [{"id": "", "name": towers.specs[type]["name"], "ancestors": []}]
	while not level.is_empty():
		var row := _hbox(4)
		tree.add_child(row)
		var below: Array = []
		for node: Dictionary in level:
			var chip := PanelContainer.new()
			chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var label := _label(node["name"], "MutedLabel")
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			chip.add_child(label)
			row.add_child(chip)
			tree_chips[node["id"]] = {"chip": chip, "label": label}
			tree_ancestors[node["id"]] = node["ancestors"]
			var children: Array = towers.upgrade_tree(type) if node["id"] == "" else node.get("next", [])
			for child: Dictionary in children:
				var entry := child.duplicate()
				var ancestors: Array = node["ancestors"].duplicate()
				if node["id"] != "":
					ancestors.append(node["id"])
				entry["ancestors"] = ancestors
				below.append(entry)
		level = below


## Colours each chip by whether it was taken, can be bought now, may come later, or is ruled out.
func _sync_upgrade_tree(path: Array, options: Array) -> void:
	var open_ids := {}
	for option: Dictionary in options:
		open_ids[option["id"]] = true
	for id: String in tree_chips:
		var state := "taken"
		if id != "":
			var ancestors: Array = tree_ancestors[id]
			var depth := ancestors.size()
			var ruled_out := false
			for n in mini(depth, path.size()):
				if ancestors[n] != path[n]:
					ruled_out = true
			if depth < path.size():
				state = "taken" if path[depth] == id else "closed"
			elif open_ids.has(id):
				state = "open"
			else:
				state = "closed" if ruled_out else "later"
			if ruled_out:
				state = "closed"
		var chip: PanelContainer = tree_chips[id]["chip"]
		var label: Label = tree_chips[id]["label"]
		chip.add_theme_stylebox_override("panel", chip_styles[state])
		var colors := {"taken": Kit.SAKURA_INK, "open": Kit.INK, "later": Kit.INK_SOFT, "closed": Color(Kit.INK_SOFT, 0.35)}
		label.add_theme_color_override("font_color", colors[state])


## One button per thing the tower can buy next, each with its price and what it does.
func _sync_upgrade_buttons(options: Array) -> void:
	var key := ""
	for option: Dictionary in options:
		key += "%s;" % option["id"]
	if key != upgrade_key:
		upgrade_key = key
		for child in upgrade_box.get_children():
			upgrade_box.remove_child(child)
			child.queue_free()
		upgrade_rows.clear()
		if options.is_empty():
			upgrade_box.add_child(_label("已经升到顶了", "MutedLabel"))
		for option: Dictionary in options:
			upgrade_rows.append(_make_upgrade_button(option))
	for row: Dictionary in upgrade_rows:
		var affordable: bool = brush.money >= float(row["cost"])
		row["button"].disabled = not affordable
		row["price"].add_theme_color_override("font_color", Kit.INK if affordable else Kit.CORAL_INK)


func _make_upgrade_button(option: Dictionary) -> Dictionary:
	var button := _button("", "Button")
	button.custom_minimum_size = Vector2(0.0, 68.0)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side: String in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	for side: String in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	button.add_child(margin)
	var lines := _vbox(2)
	lines.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(lines)
	var top := _hbox(6)
	lines.add_child(top)
	top.add_child(_icon("upgrade", 18.0, Kit.SAKURA_DEEP))
	var title := _label(("升级为 %s" % option["name"]) if option["id"] != "star" else ("强化 %s" % option["name"]), "")
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(spacer)
	var price := _label("%d 金" % int(option["cost"]), "ValueLabel")
	price.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(price)
	var tip := _label(option["tip"], "MutedLabel")
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(tip)
	var id: String = option["id"]
	button.pressed.connect(func() -> void:
		if towers.upgrade_selected(id):
			_refresh_tower_card())
	upgrade_box.add_child(button)
	return {"button": button, "price": price, "cost": option["cost"], "id": id}


func _build_tunnel_card() -> void:
	tunnel_card = _panel("CardPanel")
	tunnel_card.custom_minimum_size = Vector2(320.0, 0.0)
	_place(tunnel_card, 1.0, 0.5, -EDGE, 0.0)
	tunnel_card.visible = false
	var stack := _vbox(10)
	tunnel_card.add_child(stack)
	var head := _hbox(8)
	stack.add_child(head)
	head.add_child(_icon("tunnel", 32.0, Kit.ROUTE_TUNNEL))
	var names := _vbox(0)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(names)
	names.add_child(_label(tools.config["tunnel"]["name"], "TitleLabel"))
	tunnel_length = _label("", "MutedLabel")
	names.add_child(tunnel_length)
	var close := _button("", "ToolButton", "close")
	close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close.pressed.connect(func() -> void: tools.deselect_tunnel())
	_tip(close, "关闭  Esc")
	head.add_child(close)
	var parts := _wide_button("", "DangerButton", "trash", Kit.CORAL_INK, 42.0)
	parts[0].pressed.connect(func() -> void: tools.remove_selected_tunnel())
	tunnel_sell_label = parts[1]
	stack.add_child(parts[0])


func _build_end_screen() -> void:
	end_screen = Control.new()
	end_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	end_screen.visible = false
	root.add_child(end_screen)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(Kit.INK, 0.28)
	end_screen.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	end_screen.add_child(center)
	var card := _panel("CardPanel")
	card.custom_minimum_size = Vector2(460.0, 0.0)
	center.add_child(card)
	var stack := _vbox(14)
	card.add_child(stack)
	var head := _hbox(14)
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_child(head)
	head.add_child(_icon("sakura", 46.0))
	end_title = _label("", "BannerLabel")
	head.add_child(end_title)
	end_stars = _hbox(10)
	end_stars.alignment = BoxContainer.ALIGNMENT_CENTER
	for n in 3:
		var star := _icon("star_empty", STAR_SIZE)
		star.pivot_offset = Vector2(STAR_SIZE, STAR_SIZE) * 0.5
		end_stars.add_child(star)
	stack.add_child(end_stars)
	end_sub = _label("", "MutedLabel")
	end_sub.add_theme_font_size_override("font_size", 17)
	end_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(end_sub)
	retry_button = _wide_button("再来一次", "PrimaryButton", "undo", Color.WHITE, 56.0, "TitleLabel")[0]
	next_button = _wide_button("下一关", "PrimaryButton", "flag", Color.WHITE, 56.0, "TitleLabel")[0]
	next_button.pressed.connect(_go_next)
	next_button.visible = false
	stack.add_child(next_button)
	retry_button.pressed.connect(func() -> void: get_tree().reload_current_scene())
	stack.add_child(retry_button)
	var pick_button: Button = _wide_button("选择关卡", "Button", "route", Kit.INK, 48.0, "ValueLabel")[0]
	pick_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://menu.tscn"))
	stack.add_child(pick_button)


func _build_hint() -> void:
	hint_panel = _panel("HintPanel")
	hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(hint_panel, 0.5, 1.0, 0.0, HINT_ABOVE_DOCK)
	hint_panel.visible = false
	var row := _hbox(12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_panel.add_child(row)
	hint_dot = Panel.new()
	hint_dot.custom_minimum_size = Vector2(12.0, 12.0)
	hint_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hint_dot.add_theme_stylebox_override("panel", Kit.box(Color.WHITE, 6))
	hint_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hint_dot)
	var stack := _vbox(0)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stack)
	hint_main = _label("")
	hint_main.add_theme_font_size_override("font_size", 17)
	hint_main.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(hint_main)
	hint_sub = _label("", "MutedLabel")
	hint_sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(hint_sub)


func _build_banner() -> void:
	banner = _panel("BannerPanel")
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(banner, 0.5, 0.2, 0.0, 0.0)
	banner.visible = false
	var row := _hbox(14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.add_child(row)
	row.add_child(_icon("sakura", 46.0))
	var stack := _vbox(0)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stack)
	banner_title = _label("", "BannerLabel")
	banner_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(banner_title)
	banner_sub = _label("", "MutedLabel")
	banner_sub.add_theme_font_size_override("font_size", 17)
	banner_sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(banner_sub)


func _build_help() -> void:
	help_card = _panel("CardPanel")
	help_card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	top_column.add_child(help_card)
	help_card.visible = false
	var stack := _vbox(10)
	help_card.add_child(stack)
	stack.add_child(_label("操作说明", "TitleLabel"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 5)
	stack.add_child(grid)
	for row: Array in HELP_ROWS:
		grid.add_child(_label(row[0], "ValueLabel"))
		grid.add_child(_label(row[1], "MutedLabel"))


func toggle_help() -> void:
	_fade(help_card, not help_card.visible)


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_SPACE:
			if paths.phase != paths.Phase.BATTLE or paths.outcome != "":
				return
			paths.toggle_battle_pause()
		KEY_F1:
			toggle_help()
		KEY_F2:
			root.visible = not root.visible
		KEY_F3:
			show_details = not show_details
		KEY_ESCAPE:
			if not help_card.visible:
				return
			toggle_help()
		_:
			return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_sync_gold(delta)
	_sync_home()
	_sync_phase()
	_sync_forecast()
	_sync_tools()
	_sync_hint()
	card_timer -= delta
	if card_timer <= 0.0 and not towers.selected.is_empty():
		card_timer = 0.3
		_refresh_tower_card()
	fps_timer -= delta
	if fps_timer <= 0.0:
		fps_timer = 0.25
		_sync_fps()


func _sync_gold(delta: float) -> void:
	var money: float = brush.money
	if money > last_money + 0.5 and paths.phase == paths.Phase.BATTLE:
		_pulse(gold_pill)
	last_money = money
	var change := absf(money - shown_gold)
	shown_gold = move_toward(shown_gold, money, maxf(change * 9.0, 200.0) * delta)
	gold_label.text = str(int(round(shown_gold)))


func _sync_home() -> void:
	if shown_home == paths.home_hp:
		return
	var hurt: bool = shown_home != -1 and paths.home_hp < shown_home
	shown_home = paths.home_hp
	home_label.text = str(shown_home)
	home_label.add_theme_color_override("font_color", Kit.CORAL_INK if shown_home * 3 <= paths.home_hp_max else Kit.INK)
	if hurt:
		_pulse(home_pill)


func _sync_phase() -> void:
	var battle: bool = paths.phase == paths.Phase.BATTLE
	pause_button.visible = battle and paths.outcome == ""
	pause_button.set_pressed_no_signal(paths.battle_paused)
	pause_button.text = "继续" if paths.battle_paused else "暂停"
	if battle:
		var total: int = maxi(paths.wave_total, 1)
		var kills: int = paths.core.kills()
		var arrived: int = paths.core.arrived()
		var title := "第 %d 波" % paths.wave
		phase_title.text = title + " · 已暂停" if paths.battle_paused else title
		phase_sub.text = "击杀 %d · 抵达家园 %d · 还剩 %d" % [kills, arrived, paths.core.active()]
		phase_bar.value = float(kills + arrived) / float(total)
	else:
		phase_title.text = "摆放阶段"
		phase_sub.text = "所有敌人都挡住了" if paths.next_wave().is_empty() else "第 %d 波将有 %d 名敌人" % [paths.wave + 1, paths.wave_count(paths.next_wave())]
	if shown_phase == paths.phase:
		return
	var first := shown_phase == -1
	shown_phase = paths.phase
	phase_bar.visible = battle
	phase_icon.texture = Kit.icon("shield" if battle else "sakura")
	phase_icon.self_modulate = Kit.SAKURA_DEEP if battle else Color.WHITE
	if first:
		return
	_slide(tool_dock, not battle and paths.outcome == "")
	_fade(start_button, not battle and paths.outcome == "")
	if battle:
		show_banner("第 %d 波来袭" % paths.wave, "%d 名敌人正在逼近家园，地形已锁定" % paths.wave_total)
	elif paths.outcome == "":
		show_banner("第 %d 波结束" % paths.wave, "击杀 %d · 抵达家园 %d · 获得 %d 金" % [paths.core.kills(), paths.core.arrived(), paths.earned_this_wave])


func show_banner(title: String, sub: String, hold := 2.0) -> void:
	if banner_tween != null and banner_tween.is_valid():
		banner_tween.kill()
	banner_title.text = title
	banner_sub.text = sub
	banner.visible = true
	banner.modulate.a = 0.0
	banner.pivot_offset = banner.size * 0.5
	banner.scale = Vector2.ONE * 0.97
	banner_tween = create_tween()
	banner_tween.set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	banner_tween.tween_property(banner, "modulate:a", 1.0, 0.35)
	banner_tween.tween_property(banner, "scale", Vector2.ONE, 0.35)
	banner_tween.chain().tween_interval(hold)
	banner_tween.chain().tween_property(banner, "modulate:a", 0.0, 0.6)
	banner_tween.chain().tween_callback(banner.hide)


static func _clock_text(seconds: float) -> String:
	var total := int(round(seconds))
	if total < 60:
		return "%d 秒" % total
	return "%d 分 %d 秒" % [total / 60, total % 60]


func _sync_forecast() -> void:
	var wanted: bool = paths.phase != paths.Phase.BATTLE and paths.outcome == "" and towers.selected.is_empty() and tools.selected_tunnel.is_empty()
	if wanted != forecast_shown:
		forecast_shown = wanted
		_fade(forecast_card, wanted)
	if paths.plan.is_empty():
		return
	if shown_wave != paths.wave:
		shown_wave = paths.wave
		_fill_wave_preview()
	if shown_plan == paths.plan_version and shown_options == paths.options_version:
		return
	var changed: bool = shown_plan != -1 and shown_plan != paths.plan_version
	shown_plan = paths.plan_version
	shown_options = paths.options_version
	var plan: Dictionary = paths.plan
	forecast_time.text = _clock_text(plan["time"])
	for n in gate_rows.size():
		_fill_gate_row(gate_rows[n], paths.gate_plans[n])
	_route_row("walk", plan["walk"] > 0.0, "%d 米" % int(plan["walk"]))
	_route_row("climb", plan["climb"] > 0.0, "%d 米" % int(plan["climb"]))
	_route_row("boat", plan["boat"] > 0.0, "%d 米" % int(plan["boat"]))
	_route_row("bridge", plan["bridges"] > 0, "%d 座 · %d 米" % [plan["bridges"], int(plan["span"])])
	_route_row("built", plan["built"] > 0, "%d 座" % plan["built"])
	_route_row("tunnel", plan["tunnels"] > 0, "%d 次" % plan["tunnels"])
	if changed and forecast_card.visible:
		_pulse(forecast_time)


func _fill_gate_row(row: Dictionary, gate: Dictionary) -> void:
	row["route"].text = "%s敌人 → %s" % [gate["name"], gate["label"]] if gate["label"] != "" else "%s敌人" % gate["name"]
	row["time"].text = "%d 秒" % int(round(gate["time"]))
	var parts: PackedStringArray = []
	for option: Dictionary in gate["alternatives"]:
		parts.append("%s %d" % [option["label"], int(round(option["time"]))])
	row["others"].text = "其他走法：" + " / ".join(parts)
	row["others"].visible = not parts.is_empty()


## Tells the player who is coming, and what each kind is good at, while there is still time to prepare.
func _fill_wave_preview() -> void:
	for child in wave_rows.get_children():
		child.queue_free()
	if paths.next_wave().is_empty():
		wave_title.text = "所有波次都结束了"
		return
	var total := "" if paths.level.get("endless", false) else " / %d" % paths.total_waves()
	wave_title.text = "下一波：第 %d%s 波" % [paths.wave + 1, total]
	for entry: Dictionary in paths.wave_summary(paths.next_wave()):
		var row := _vbox(0)
		var top := _hbox(8)
		top.add_child(_dot(entry["color"]))
		top.add_child(_label("%s × %d" % [entry["name"], entry["count"]], "ValueLabel"))
		row.add_child(top)
		var trait_label := _label(entry["trait"], "MutedLabel")
		trait_label.add_theme_font_size_override("font_size", 14)
		row.add_child(trait_label)
		wave_rows.add_child(row)


## A note beside the mouse saying what the last change did to the enemies' time.
func _on_plan_changed(changes: Array) -> void:
	var lines: PackedStringArray = []
	var slower := 0.0
	for change: Dictionary in changes:
		var line: String = change["name"]
		if absf(change["delta"]) >= 0.5:
			line += " %+d 秒" % int(round(change["delta"]))
			slower += change["delta"]
		if change["moved"]:
			line += " · 改为%s" % change["label"]
		lines.append(line)
	var chip := _panel("ChipPanel")
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := _label("\n".join(lines), "ValueLabel")
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Kit.CORAL_INK if slower < 0.0 else Kit.INK)
	chip.add_child(label)
	root.add_child(chip)
	var at: Vector2 = brush.current_mouse() + Vector2(18.0, -30.0)
	var limit := root.size - chip.get_combined_minimum_size() - Vector2(EDGE, EDGE)
	chip.position = Vector2(clampf(at.x, EDGE, limit.x), clampf(at.y, FLOAT_RISE + EDGE, limit.y))
	var tween := create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(chip, "position:y", chip.position.y - FLOAT_RISE, FLOAT_SECONDS)
	tween.tween_property(chip, "modulate:a", 0.0, FLOAT_SECONDS * 0.35).set_delay(FLOAT_SECONDS * 0.65)
	tween.chain().tween_callback(chip.queue_free)


func _on_tools_changed() -> void:
	var tunnel: Dictionary = tools.selected_tunnel
	if tunnel.is_empty():
		if tunnel_card.visible:
			_fade(tunnel_card, false)
		return
	tunnel_length.text = "长 %d 米 · 里面的敌人打不到" % int(tunnel["length"])
	tunnel_sell_label.text = "填平，返还 %d 金" % tools.tunnel_refund()
	_fade(tunnel_card, true)


func _on_level_finished(won: bool) -> void:
	var stars := GameConfig.stars_for(paths.home_hp, paths.home_hp_max) if won else 0
	end_stars.visible = paths.home_hp_max > 0
	for n in 3:
		var star: TextureRect = end_stars.get_child(n)
		star.texture = Kit.icon("star" if n < stars else "star_empty")
		star.scale = Vector2.ONE
	if won:
		end_title.text = "家园守住了"
		# A run with no home to lose (the --play check) proves nothing, so it never counts as cleared.
		var best := false
		if paths.home_hp_max > 0:
			best = GameConfig.record_stars(main.level_id, stars)
		var next := GameConfig.next_level(main.level_id)
		next_button.visible = next != ""
		var lines: PackedStringArray = ["挡住了全部 %d 波敌人，家园还剩 %d / %d 点生命" % [paths.total_waves(), paths.home_hp, paths.home_hp_max]]
		if stars < 3 and paths.home_hp_max > 0:
			var saved := GameConfig.best_stars(main.level_id)
			lines.append("家园一点血都不掉，就能拿到三颗星。" if saved < 3 else "你在这一关拿到过三颗星。")
		elif best:
			lines.append("三颗星！这就是最好的守法。")
		end_sub.text = "\n".join(lines)
	else:
		end_title.text = "家园失守"
		end_sub.text = "倒在了第 %d 波。\n%s" % [paths.wave, paths.level["goal_hint"]]
	end_screen.visible = true
	end_screen.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(end_screen, "modulate:a", 1.0, 0.5)
	# The earned stars pop in one after another.
	for n in stars:
		var star: TextureRect = end_stars.get_child(n)
		star.scale = Vector2.ONE * 0.2
		tween.tween_property(star, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Leaving loses the battle, so the first press only asks.
func _on_menu_pressed() -> void:
	if Time.get_ticks_msec() < leave_armed_until:
		get_tree().change_scene_to_file("res://menu.tscn")
		return
	leave_armed_until = Time.get_ticks_msec() + 3000
	show_banner("返回选关？", "再点一次离开，这一关的进度不会保存", 3.0)


func _go_next() -> void:
	GameConfig.chosen_level = GameConfig.next_level(main.level_id)
	get_tree().change_scene_to_file("res://main.tscn")


func _route_row(key: String, used: bool, text: String) -> void:
	route_rows[key]["row"].visible = used
	route_rows[key]["value"].text = text


func _sync_tools() -> void:
	# A lit tool means a click on the ground will sculpt, so none is lit while towers have the mouse.
	var sculpting: bool = towers.mode == towers.Mode.IDLE and towers.selected.is_empty() and tools.active_id == "" and tools.selected_tunnel.is_empty()
	for id: int in tool_buttons:
		tool_buttons[id].set_pressed_no_signal(sculpting and id == brush.tool)
	for id: String in preset_buttons:
		preset_buttons[id].set_pressed_no_signal(tools.active_id == id)
	undo_button.disabled = brush.history.count() == 0 or brush.locked or brush.ground_busy or brush.painting
	radius_slider.set_value_no_signal(brush.radius)
	radius_value.text = str(int(round(brush.effective_radius())))
	strength_slider.set_value_no_signal(brush.strength)
	strength_value.text = "%.1f" % brush.strength
	_sync_preset_sliders()
	for type: String in build_buttons:
		var parts: Dictionary = build_buttons[type]
		var affordable: bool = brush.money >= float(towers.specs[type]["cost"])
		var placing: bool = towers.mode == towers.Mode.PLACING and towers.place_type == type
		parts["button"].disabled = not affordable and not placing
		parts["contents"].modulate.a = 0.6 if parts["button"].disabled else 1.0
		parts["button"].set_pressed_no_signal(placing)
		parts["price"].add_theme_color_override("font_color", Kit.INK if affordable else Kit.CORAL_INK)
	for n in speed_buttons.size():
		speed_buttons[n].set_pressed_no_signal(n == paths.speed_index)


func _sync_hint() -> void:
	var main_text: String = tip_text
	if undo_button.is_hovered():
		main_text = "撤销%s  Ctrl + Z" % brush.history.last_label() if brush.history.count() > 0 else "当前没有可撤销的操作"
	var sub_text := ""
	var dot := Kit.SAKURA
	if brush.painting and brush.money <= 0.0:
		main_text = "金币用完了，这一笔改不动地形了"
		sub_text = "击杀敌人或拆除防御塔可以获得金币"
		dot = Kit.CORAL
	elif main_text == "" and tools.hint_text != "":
		main_text = tools.hint_text
		sub_text = tools.hint_sub
		dot = [Kit.SAKURA, Kit.SAGE, Kit.HONEY, Kit.CORAL][tools.hint_kind]
	elif main_text == "":
		main_text = towers.hint_text
		sub_text = towers.hint_sub
		dot = [Kit.SAKURA, Kit.SAGE, Kit.HONEY, Kit.CORAL][towers.hint_kind]
	if main_text == "":
		if hint_panel.visible:
			hint_panel.visible = false
		return
	hint_main.text = main_text
	hint_sub.text = sub_text
	hint_sub.visible = sub_text != ""
	hint_dot.self_modulate = dot
	var battle: bool = paths.phase == paths.Phase.BATTLE
	var y := -EDGE if battle and not tool_dock.visible else HINT_ABOVE_DOCK
	hint_panel.offset_top = y
	hint_panel.offset_bottom = y
	hint_panel.visible = true


func _sync_fps() -> void:
	var text := "%d FPS" % Engine.get_frames_per_second()
	if show_details:
		text += "\n路线 %.1f ms  水面 %.1f ms  敌人 %.2f ms\n笔刷 %.1f ms  上传 %.1f ms" % [paths.last_solve_ms, brush.last_water_ms, paths.last_step_ms, brush.last_edit_ms, brush.last_upload_ms]
	fps_label.text = text


func _on_selection_changed() -> void:
	card_timer = 0.3
	if towers.selected.is_empty():
		_fade(tower_card, false)
		return
	_refresh_tower_card()
	_fade(tower_card, true)


func _refresh_tower_card() -> void:
	var info: Dictionary = towers.selected_info()
	if info.is_empty():
		return
	var stars: int = info["stars"]
	tower_name.text = info["name"] + ("  " + "★".repeat(stars) if stars > 0 else "")
	tower_lean.text = "建在平地上" if info["tilt"] < 3.0 else "塔身倾斜 %d°" % int(round(info["tilt"]))
	if info["type"] != tree_type:
		_fill_upgrade_tree(info["type"])
		tower_icon.texture = Kit.icon(String(towers.specs[info["type"]].get("icon", "tower")))
	aim_box.visible = info["aimable"]
	stat_values["cone"].text = "全方向" if info["lob"] else "%d° 圆锥" % info["cone_degrees"]
	var reach_text := "%d 米" % info["range"]
	if info["min_range"] > 0:
		reach_text = "%d–%d 米" % [info["min_range"], info["range"]]
	stat_values["reach"].text = reach_text if info["range_bonus"] <= 0 else reach_text + " + 高度"
	stat_values["damage"].text = str(info["damage"])
	stat_values["rate"].text = "%.1f 发/秒" % info["rate"]
	stat_values["splash"].text = "%d 米 · 最多 %d 人" % [info["splash"], info["splash_targets"]] if info["splash"] > 0.0 else "单体"
	stat_values["route"].text = "%d 米" % info["covered"]
	stat_values["kills"].text = str(info["kills"])
	var effects: PackedStringArray = []
	if info["lob"]:
		effects.append("抛射：石头越过山丘")
	if info["height_damage"] > 0.0:
		effects.append("比目标每高 1 米，伤害多 %s，最多多 %d" % [String.num(float(info["height_damage"]), 1), info["height_damage_max"]])
	if info["min_range"] > 0:
		effects.append("%d 米以内打不到" % info["min_range"])
	if info["range_bonus"] > 0:
		effects.append("比目标每高 1 米，射程多 1 米，最多多 %d 米" % info["range_bonus"])
	if info["fire_dps"] > 0.0:
		effects.append("落点燃烧，每秒烧 %d" % int(info["fire_dps"]))
	if info["slow"] > 0.0:
		effects.append("命中减速 %d%%" % int(round(float(info["slow"]) * 100.0)))
	if info["knock"]:
		effects.append("把爬墙的敌人震回墙脚")
	effect_label.text = "　·　".join(effects)
	effect_label.visible = not effects.is_empty()
	_sync_upgrade_tree(info["path"], info["options"])
	_sync_upgrade_buttons(info["options"])
	# A slider being dragged already shows the right place. Moving it would make it jump at the ends.
	if not aim_dragging:
		# +180 and -180 are the same direction, so the grabber stays where the player left it.
		if absf(wrapf(float(info["yaw_degrees"]) - yaw_slider.value, -180.0, 180.0)) > 0.5:
			yaw_slider.set_value_no_signal(info["yaw_degrees"])
		pitch_slider.set_value_no_signal(info["pitch_degrees"])
	yaw_value.text = "%d°" % int(round(yaw_slider.value))
	pitch_value.text = "%d°" % int(round(pitch_slider.value))
	sell_label.text = "拆除，返还 %d 金" % info["refund"]


func _on_aim_slider(_value: float) -> void:
	towers.aim_selected_degrees(yaw_slider.value, pitch_slider.value)
