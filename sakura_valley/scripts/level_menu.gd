extends Control
## The first screen: one card per level, each with a small relief map drawn from the level's own terrain.

const Kit = preload("res://scripts/ui_kit.gd")
const GameConfig = preload("res://scripts/game_config.gd")
const TerrainData = preload("res://scripts/terrain_data.gd")

const MAP_PIXELS := 120
## Cards are this wide at most, and narrow down so every level fits across the screen.
const CARD_WIDTH := 312.0
const CARD_GAP := 22.0
const ROW_WIDTH := 1800.0
const WATER := Color("5fa9cf")
const CLOUD := Color("eef2f6")
const CLOUD_SHADE := Color("cfdbe6")
const LOW_GRASS := Color("6f9a4f")
const HIGH_GRASS := Color("b8c77a")
const ROCK := Color("8d8478")
const ROAD := Color("d4b07a")

var maps_to_draw: Array[Dictionary] = []
var card_width := CARD_WIDTH
var loading: Control


func _ready() -> void:
	# Tests and command-line launches go straight to the battle.
	var first := not GameConfig.menu_seen
	GameConfig.menu_seen = true
	var shot := _shot_path()
	if first and shot == "" and _arg("menuclick") == "" and not OS.get_cmdline_user_args().is_empty():
		get_tree().change_scene_to_file.call_deferred("res://main.tscn")
		return
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = Kit.make_theme()
	_build_background()
	var page := VBoxContainer.new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.add_theme_constant_override("separation", 0)
	add_child(page)
	page.add_child(_build_header())
	var middle := CenterContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(middle)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(CARD_GAP))
	middle.add_child(row)
	var count := maxi(GameConfig.level_order().size(), 1)
	card_width = minf(CARD_WIDTH, (ROW_WIDTH - CARD_GAP * float(count - 1)) / float(count))
	for id: String in GameConfig.level_order():
		row.add_child(_build_card(id))
	page.add_child(_build_footer())
	_build_loading()
	if shot != "":
		_take_shot(shot)
	var click := _arg("menuclick")
	if click != "":
		_start(click)


func _process(_delta: float) -> void:
	# One map per frame, so the menu shows up at once and fills in.
	if not maps_to_draw.is_empty():
		var job: Dictionary = maps_to_draw.pop_front()
		job["rect"].texture = _draw_map(job["level"])
		var tween := create_tween()
		tween.tween_property(job["rect"], "modulate:a", 1.0, 0.35)


func _build_background() -> void:
	var back := ColorRect.new()
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/menu_backdrop.gdshader")
	back.material = material
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(back)


func _build_header() -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 96)
	margin.add_theme_constant_override("margin_top", 70)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	margin.add_child(stack)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	stack.add_child(head)
	head.add_child(_icon("sakura", 58.0))
	var title := _label("樱谷守望", "BannerLabel")
	title.add_theme_font_size_override("font_size", 52)
	head.add_child(title)
	var sub := _label("你是这片山谷的神。挑一处地方，用你改变大地的力量守住它。", "MutedLabel")
	sub.add_theme_font_size_override("font_size", 19)
	stack.add_child(sub)
	return margin


func _build_footer() -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 96)
	margin.add_theme_constant_override("margin_right", 96)
	margin.add_theme_constant_override("margin_bottom", 56)
	var row := HBoxContainer.new()
	margin.add_child(row)
	var note := _label("敌人永远走最快的路。地形一变，路线就跟着变。", "MutedLabel")
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(note)
	var sandbox_id := String(GameConfig.load_json("levels/index.json").get("sandbox", ""))
	if sandbox_id != "":
		var sandbox := Button.new()
		sandbox.text = "试验场"
		sandbox.icon = Kit.icon("flag", 40)
		sandbox.expand_icon = false
		sandbox.add_theme_constant_override("icon_max_width", 22)
		sandbox.tooltip_text = GameConfig.level(sandbox_id).get("card", "")
		sandbox.custom_minimum_size = Vector2(170.0, 50.0)
		sandbox.pressed.connect(_start.bind(sandbox_id))
		row.add_child(sandbox)
	return margin


func _build_card(id: String) -> Control:
	var level: Dictionary = GameConfig.level(id)
	var card := PanelContainer.new()
	card.theme_type_variation = "CardPanel"
	card.custom_minimum_size = Vector2(card_width, 0.0)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	card.add_child(stack)

	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", Kit.box(Kit.PAPER_DEEP, 14, Vector2(4.0, 4.0)))
	stack.add_child(frame)
	var map := TextureRect.new()
	map.custom_minimum_size = Vector2(card_width - 44.0, card_width - 44.0)
	map.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	map.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	map.modulate.a = 0.0
	frame.add_child(map)
	maps_to_draw.append({"rect": map, "level": level})

	var parts := String(level["name"]).split("：", true, 1)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	stack.add_child(head)
	var badge := PanelContainer.new()
	badge.theme_type_variation = "BadgePanel"
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.add_child(_label(parts[0] if parts.size() > 1 else "", "BadgeLabel"))
	head.add_child(badge)
	head.add_child(_stars(GameConfig.best_stars(id)))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	head.add_child(_difficulty(int(level.get("difficulty", 1))))
	stack.add_child(_label(parts[parts.size() - 1], "TitleLabel"))

	var about := _label(String(level.get("card", "")), "MutedLabel")
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.custom_minimum_size = Vector2(card_width - 40.0, 92.0)
	about.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(about)

	var go := Button.new()
	go.theme_type_variation = "PrimaryButton"
	go.text = "出发"
	go.custom_minimum_size = Vector2(0.0, 50.0)
	go.pressed.connect(_start.bind(id))
	stack.add_child(go)

	card.pivot_offset = Vector2(card_width * 0.5, 300.0)
	card.mouse_entered.connect(_lift.bind(card, true))
	card.mouse_exited.connect(_lift.bind(card, false))
	return card


## The best result so far: three stars, filled for each one earned.
func _stars(earned: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.tooltip_text = "最好成绩 %d / 3 颗星" % earned if earned > 0 else "还没守住过"
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	for n in 3:
		row.add_child(_icon("star" if n < earned else "star_empty", 22.0))
	return row


## Petals for difficulty: filled for each step up.
func _difficulty(level: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.tooltip_text = "难度 %d / 4" % level
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	for n in 4:
		row.add_child(_icon("sakura", 18.0, Color.WHITE if n < level else Color(1.0, 1.0, 1.0, 0.22)))
	return row


func _lift(card: Control, up: bool) -> void:
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector2.ONE * (1.03 if up else 1.0), 0.18)


func _build_loading() -> void:
	loading = ColorRect.new()
	loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	(loading as ColorRect).color = Color(Kit.PAPER, 0.82)
	loading.visible = false
	add_child(loading)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	loading.add_child(center)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	center.add_child(row)
	row.add_child(_icon("sakura", 40.0))
	row.add_child(_label("正在塑造大地……", "TitleLabel"))


func _start(id: String) -> void:
	GameConfig.chosen_level = id
	loading.visible = true
	loading.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(loading, "modulate:a", 1.0, 0.2)
	await tween.finished
	# Let the loading note reach the screen before the long terrain build blocks the frame.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_tree().change_scene_to_file("res://main.tscn")


## A shaded relief map, north up: clouds, water, grass by height, cliffs, roads, the gates and home.
func _draw_map(level: Dictionary) -> ImageTexture:
	var terrain := TerrainData.new()
	terrain.setup(level["map"])
	var shape = terrain.shape
	var void_level: float = terrain.void_level
	var size := MAP_PIXELS
	var cell: float = terrain.SIZE / float(size)
	var half: float = terrain.SIZE * 0.5
	var heights := PackedFloat32Array()
	var roads := PackedFloat32Array()
	heights.resize(size * size)
	roads.resize(size * size)
	var low := INF
	var high := -INF
	for j in size:
		for i in size:
			var point: Vector3 = shape.sample(-half + (float(i) + 0.5) * cell, -half + (float(j) + 0.5) * cell)
			heights[j * size + i] = point.x
			roads[j * size + i] = point.z
			if point.x > void_level + 1.0 and point.x > terrain.WATER_LEVEL:
				low = minf(low, point.x)
				high = maxf(high, point.x)
	var has_water: bool = not shape.water_seeds().is_empty()
	var light := Vector3(-0.55, 0.75, -0.4).normalized()
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for j in size:
		for i in size:
			var h := heights[j * size + i]
			var color: Color
			if h < void_level:
				color = CLOUD.lerp(CLOUD_SHADE, clampf((void_level - h) * 0.03, 0.0, 0.6))
			elif has_water and h < terrain.WATER_LEVEL:
				color = WATER.lerp(WATER.darkened(0.3), clampf((terrain.WATER_LEVEL - h) / 8.0, 0.0, 1.0))
			else:
				var hx := heights[j * size + mini(i + 1, size - 1)] - heights[j * size + maxi(i - 1, 0)]
				var hz := heights[mini(j + 1, size - 1) * size + i] - heights[maxi(j - 1, 0) * size + i]
				var normal := Vector3(-hx, cell * 2.0, -hz).normalized()
				var steep := 1.0 - normal.y
				var t := clampf((h - low) / maxf(high - low, 1.0), 0.0, 1.0)
				color = LOW_GRASS.lerp(HIGH_GRASS, t).lerp(ROCK, smoothstep(0.18, 0.45, steep))
				color = color.lerp(ROAD, clampf(roads[j * size + i], 0.0, 1.0) * 0.85)
				var shade := clampf(normal.dot(light) * 1.25, 0.35, 1.15)
				color = Color(color.r * shade, color.g * shade, color.b * shade)
			image.set_pixel(i, j, color)
	var home: Vector2 = terrain.home_center()
	_dot(image, home, terrain.SIZE, 4.0, Kit.SAKURA_DEEP)
	for gate: Dictionary in level["gates"]:
		_dot(image, Vector2(gate["x"], gate["z"]), terrain.SIZE, 3.2, Kit.CORAL_INK)
	return ImageTexture.create_from_image(image)


static func _dot(image: Image, at: Vector2, world: float, radius: float, color: Color) -> void:
	var size := image.get_width()
	var c := (at / world + Vector2(0.5, 0.5)) * float(size)
	for j in range(int(c.y - radius - 2.0), int(c.y + radius + 3.0)):
		for i in range(int(c.x - radius - 2.0), int(c.x + radius + 3.0)):
			if i < 0 or j < 0 or i >= size or j >= size:
				continue
			var d := Vector2(float(i) + 0.5, float(j) + 0.5).distance_to(c)
			if d < radius + 1.2:
				var ring := Color.WHITE if d > radius - 0.2 else color
				image.set_pixel(i, j, image.get_pixel(i, j).lerp(ring, clampf(radius + 1.2 - d, 0.0, 1.0)))


func _label(text: String, type_name := "") -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = type_name
	return label


func _icon(icon_name: String, size: float, tint := Color.WHITE) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = Kit.icon(icon_name)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = Vector2(size, size)
	rect.modulate = tint
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## The value of a --name=value launch argument, or "".
func _arg(arg_name: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--%s=" % arg_name):
			return arg.trim_prefix("--%s=" % arg_name)
	return ""


## --menushot=<file>: save a picture of the menu once every map is drawn, then quit.
func _shot_path() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--menushot="):
			return arg.trim_prefix("--menushot=")
	return ""


func _take_shot(path: String) -> void:
	var begin := Time.get_ticks_msec()
	while not maps_to_draw.is_empty():
		await get_tree().process_frame
	print("MENU maps drawn in ", Time.get_ticks_msec() - begin, " ms")
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
