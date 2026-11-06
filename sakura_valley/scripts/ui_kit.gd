extends RefCounted
## The look of the interface: colors, fonts, the shared theme and the icons.
## Icons are drawn from SVG at startup, so the project needs no image files for them.

const PAPER := Color("fbf5ec")
const PAPER_SOFT := Color("f3e8da")
const PAPER_DEEP := Color("e7d9c8")
const LINE := Color("e6d7c5")
const INK := Color("5b4a40")
const INK_SOFT := Color("7f6b5f")
const SAKURA := Color("eeb2c0")
const SAKURA_DEEP := Color("bd6580")
const SAKURA_INK := Color("a8566c")
const SAKURA_PALE := Color("fae6e9")
const SAGE := Color("8fb17f")
const HONEY := Color("e4b45f")
const CORAL := Color("d97f70")
const CORAL_INK := Color("ad5a4b")
const CORAL_PALE := Color("f8e4de")
const SHADOW := Color(0.3, 0.2, 0.16, 0.2)

## Route colors, shared by the line on the ground and the legend in the forecast card.
const ROUTE_WALK := Color("df5548")
const ROUTE_CLIMB := Color("e8892f")
const ROUTE_BOAT := Color("3f93cc")
const ROUTE_BRIDGE := Color("e9bb34")
const ROUTE_BUILT := Color("b5824c")
const ROUTE_TUNNEL := Color("7a6aa8")

## Drawn in white and tinted by whatever displays them.
const LINE_ICONS := {
	"raise": "<path d='M3 20c2.5-5 5.500-8 9-8s6.500 3 9 8'/><path d='M12 9V3'/><path d='M9 5.500 12 2.500l3 3'/>",
	"lower": "<path d='M3 11c2.500 5 5.500 8 9 8s6.500-3 9-8'/><path d='M12 3v8'/><path d='M9 8.500l3 3 3-3'/>",
	"smooth": "<path d='M3 10c3-5 6-5 9 0s6 5 9 0'/><path d='M3 17c3-2.500 6-2.500 9 0s6 2.500 9 0'/>",
	"flatten": "<path d='M3 19.500h18'/><path d='M8 4v10'/><path d='M5.500 11.500 8 14l2.500-2.500'/><path d='M16 4v10'/><path d='M13.500 11.500 16 14l2.500-2.500'/>",
	"slope": "<path d='M3.500 19.500h17V6.500z'/><path d='M14.500 19.500v-3.500'/>",
	"pinch": "<path d='M3 12h6.500'/><path d='M6.500 8.500 10 12l-3.500 3.500'/><path d='M21 12h-6.500'/><path d='M17.500 8.500 14 12l3.500 3.500'/>",
	"wall": "<path d='M2.500 19.500c3-7 6-9.500 9.500-9.500s6.500 2.500 9.500 9.500z'/><path d='M7 14.500h10'/>",
	"tunnel": "<path d='M3 20.500h18'/><path d='M5.500 20.500V12a6.500 6.500 0 0 1 13 0v8.500'/><path d='M9.500 20.500V13a2.500 2.500 0 0 1 5 0v7.500'/>",
	"heart": "<path d='M12 20.500C6 16 3 12.800 3 9a4.700 4.700 0 0 1 9-1.900A4.700 4.700 0 0 1 21 9c0 3.800-3 7-9 11.500z'/>",
	"blast": "<circle cx='12' cy='12' r='3.500'/><path d='M12 2.500v3.500M12 18v3.500M2.500 12H6M18 12h3.500M5.300 5.300l2.500 2.500M16.200 16.200l2.500 2.500M5.300 18.700l2.500-2.500M16.200 7.800l2.500-2.500'/>",
	"undo": "<path d='M8 4.500 4 8.500l4 4'/><path d='M4 8.500h10.500a5.750 5.750 0 0 1 0 11.500H11'/>",
	"tower": "<path d='M7 21 8.500 10h7L17 21z'/><path d='M6.500 10V5h2.700v2.500h1.500V5h2.600v2.500h1.500V5h2.700v5z'/><path d='M10.800 21v-4a1.200 1.200 0 0 1 2.400 0v4'/>",
	"flag": "<path d='M6 21V4'/><path d='M6 5c3.500-2 6 1.500 12-.5v9c-6 2-8.500-1.500-12 .5'/>",
	"speed": "<path d='M4.500 6.500 11 12l-6.500 5.500z'/><path d='M13 6.500 19.500 12 13 17.500z'/>",
	"clock": "<circle cx='12' cy='12' r='9'/><path d='M12 7v5l3 2'/>",
	"leaf": "<path d='M5 19C4 10 10 4 20 4c0 10-6 16-15 15z'/><path d='M5 19l8-8'/>",
	"shield": "<path d='M12 3 5 6v5.500c0 4.500 3 7.500 7 9.500 4-2 7-5 7-9.500V6z'/>",
	"cone": "<path d='M4 7a16 16 0 0 1 16 0l-8 14z'/>",
	"reach": "<path d='M4 20 19 5'/><path d='M13.500 4.500H19.500V10.500'/>",
	"damage": "<path d='M12 3l2.500 6 6.500.500-5 4.200 1.600 6.300-5.600-3.400-5.600 3.400 1.600-6.300-5-4.200 6.500-.500z'/>",
	"rate": "<path d='M13 2.500 5.500 13.500H12l-1 8 7.500-11H12z'/>",
	"route": "<circle cx='6' cy='18' r='2.500'/><circle cx='18' cy='6' r='2.500'/><path d='M8.500 18H15a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h6.500'/>",
	"kills": "<circle cx='12' cy='11' r='7.500'/><path d='M9 21v-3M15 21v-3M12 21v-3'/><circle cx='9.300' cy='10.500' r='.8' fill='#fff'/><circle cx='14.700' cy='10.500' r='.8' fill='#fff'/>",
	"aim": "<circle cx='12' cy='12' r='7'/><circle cx='12' cy='12' r='1.300' fill='#fff'/><path d='M12 2v3.500M12 18.500V22M2 12h3.500M18.500 12H22'/>",
	"close": "<path d='M6.500 6.500l11 11M17.500 6.500l-11 11'/>",
	"help": "<path d='M9 9a3 3 0 1 1 4.600 2.500c-1 .7-1.600 1.300-1.600 2.500'/><circle cx='12' cy='18' r='.8' fill='#fff'/>",
	"menu": "<path d='M5 7h14M5 12h14M5 17h14'/>",
	"trash": "<path d='M4 7h16'/><path d='M9 7V4.500h6V7'/><path d='M6.500 7l1 13h9l1-13'/>",
	"upgrade": "<path d='M6 13.500l6-6 6 6'/><path d='M6 19l6-6 6 6'/><path d='M7 4.500h10'/>",
	"catapult": "<path d='M3.500 20h17'/><path d='M7 20l5-7 5 7'/><path d='M12 13 18.500 5.500'/><circle cx='19' cy='4.500' r='1.700'/><path d='M9.500 11.500h-3v3'/>",
	"sniper": "<circle cx='12' cy='12' r='7.500'/><circle cx='12' cy='12' r='3'/><path d='M12 1.500v5M12 17.500v5M1.500 12h5M17.500 12h5'/>",
}

## Drawn in their own colors.
const COLOR_ICONS := {
	"coin": "<circle cx='12' cy='12' r='10' fill='#F0CB85' stroke='#C8995A' stroke-width='1.600'/><circle cx='12' cy='12' r='6.300' fill='#F6DCA5' stroke='#D3A966' stroke-width='1.300'/>",
	"sakura": "<g fill='#F1B3C2'><ellipse cx='12' cy='6.200' rx='3.500' ry='4.800'/><ellipse cx='12' cy='6.200' rx='3.500' ry='4.800' transform='rotate(72 12 12)'/><ellipse cx='12' cy='6.200' rx='3.500' ry='4.800' transform='rotate(144 12 12)'/><ellipse cx='12' cy='6.200' rx='3.500' ry='4.800' transform='rotate(216 12 12)'/><ellipse cx='12' cy='6.200' rx='3.500' ry='4.800' transform='rotate(288 12 12)'/></g><circle cx='12' cy='12' r='2.300' fill='#F6DE9C'/>",
	"grabber": "<circle cx='12' cy='12' r='9' fill='#FFFFFF' stroke='#C76F87' stroke-width='3'/>",
	"grabber_on": "<circle cx='12' cy='12' r='9.500' fill='#FAE6E9' stroke='#A8566C' stroke-width='3'/>",
}

static var _icons := {}


static func icon(icon_name: String, pixels := 56) -> Texture2D:
	var key := "%s@%d" % [icon_name, pixels]
	if _icons.has(key):
		return _icons[key]
	var svg: String
	if COLOR_ICONS.has(icon_name):
		svg = "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'>%s</svg>" % COLOR_ICONS[icon_name]
	else:
		svg = "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='#fff' stroke-width='1.900' stroke-linecap='round' stroke-linejoin='round'>%s</svg>" % LINE_ICONS[icon_name]
	var image := Image.new()
	image.load_svg_from_string(svg, float(pixels) / 24.0)
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	_icons[key] = texture
	return texture


static func box(background: Color, radius: int, pad := Vector2.ZERO, border := Color(0.0, 0.0, 0.0, 0.0), border_width := 0, shadow := 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.set_corner_radius_all(radius)
	style.corner_detail = 10
	style.content_margin_left = pad.x
	style.content_margin_right = pad.x
	style.content_margin_top = pad.y
	style.content_margin_bottom = pad.y
	if border_width > 0:
		style.set_border_width_all(border_width)
		style.border_color = border
	if shadow > 0:
		style.shadow_color = SHADOW
		style.shadow_size = shadow
		style.shadow_offset = Vector2(0.0, float(shadow) * 0.4)
	return style


static func _font(weight: int) -> SystemFont:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Noto Sans SC", "Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "sans-serif"])
	font.font_weight = weight
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return font


static func _label_type(theme: Theme, type_name: String, color: Color, size: int, font: Font) -> void:
	theme.set_type_variation(type_name, "Label")
	theme.set_color("font_color", type_name, color)
	theme.set_font_size("font_size", type_name, size)
	theme.set_font("font", type_name, font)


static func _panel_type(theme: Theme, type_name: String, style: StyleBox) -> void:
	theme.set_type_variation(type_name, "PanelContainer")
	theme.set_stylebox("panel", type_name, style)


## Styles lists normal, hover, pressed and disabled. Colors lists the text and icon color for each.
static func _button_type(theme: Theme, type_name: String, styles: Array[StyleBox], colors: Array[Color], size: int, font: Font, icon_width: int) -> void:
	if type_name != "Button":
		theme.set_type_variation(type_name, "Button")
	theme.set_stylebox("normal", type_name, styles[0])
	theme.set_stylebox("hover", type_name, styles[1])
	theme.set_stylebox("pressed", type_name, styles[2])
	theme.set_stylebox("hover_pressed", type_name, styles[2])
	theme.set_stylebox("disabled", type_name, styles[3])
	theme.set_stylebox("focus", type_name, StyleBoxEmpty.new())
	var text_states: Array[String] = ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]
	var icon_states: Array[String] = ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_disabled_color"]
	for n in 4:
		theme.set_color(text_states[n], type_name, colors[n])
		theme.set_color(icon_states[n], type_name, colors[n])
	theme.set_color("font_hover_pressed_color", type_name, colors[2])
	theme.set_color("icon_hover_pressed_color", type_name, colors[2])
	theme.set_color("font_focus_color", type_name, colors[0])
	theme.set_color("icon_focus_color", type_name, colors[0])
	theme.set_font_size("font_size", type_name, size)
	theme.set_font("font", type_name, font)
	theme.set_constant("icon_max_width", type_name, icon_width)
	theme.set_constant("h_separation", type_name, 8)


static func make_theme() -> Theme:
	var regular := _font(400)
	var bold := _font(700)
	var theme := Theme.new()
	theme.default_font = regular
	theme.default_font_size = 18

	theme.set_color("font_color", "Label", INK)
	_label_type(theme, "MutedLabel", INK_SOFT, 15, regular)
	_label_type(theme, "ValueLabel", INK, 16, bold)
	_label_type(theme, "TitleLabel", INK, 20, bold)
	_label_type(theme, "NumberLabel", INK, 25, bold)
	_label_type(theme, "BannerLabel", INK, 32, bold)
	_label_type(theme, "BadgeLabel", INK_SOFT, 12, bold)

	var paper := Color(PAPER, 0.96)
	_panel_type(theme, "CardPanel", box(paper, 22, Vector2(18.0, 14.0), LINE, 1, 12))
	_panel_type(theme, "PillPanel", box(paper, 26, Vector2(16.0, 8.0), LINE, 1, 10))
	_panel_type(theme, "DockPanel", box(paper, 26, Vector2(12.0, 10.0), LINE, 1, 12))
	_panel_type(theme, "HintPanel", box(paper, 20, Vector2(20.0, 10.0), LINE, 1, 10))
	_panel_type(theme, "BannerPanel", box(paper, 30, Vector2(36.0, 18.0), LINE, 1, 16))
	_panel_type(theme, "ChipPanel", box(Color(PAPER, 0.86), 11, Vector2(10.0, 2.0)))
	_panel_type(theme, "BadgePanel", box(PAPER_DEEP, 7, Vector2(5.0, 0.0)))

	var plain := Vector2(14.0, 8.0)
	_button_type(theme, "Button", [
		box(PAPER_SOFT, 14, plain), box(PAPER_DEEP, 14, plain), box(SAKURA_PALE, 14, plain), box(Color(PAPER_SOFT, 0.5), 14, plain),
	], [INK, INK, SAKURA_INK, Color(INK_SOFT, 0.6)], 17, regular, 24)

	var tool := Vector2(6.0, 8.0)
	_button_type(theme, "ToolButton", [
		box(Color(1.0, 1.0, 1.0, 0.0), 18, tool), box(PAPER_SOFT, 18, tool), box(SAKURA_PALE, 18, tool, SAKURA, 2), box(Color(1.0, 1.0, 1.0, 0.0), 18, tool),
	], [INK_SOFT, INK, SAKURA_INK, Color(INK_SOFT, 0.45)], 15, regular, 30)

	var primary := Vector2(24.0, 12.0)
	_button_type(theme, "PrimaryButton", [
		box(SAKURA_DEEP, 24, primary, Color(1.0, 1.0, 1.0, 0.0), 0, 8), box(Color("c8728b"), 24, primary, Color(1.0, 1.0, 1.0, 0.0), 0, 10), box(Color("a85670"), 24, primary), box(Color(SAKURA_DEEP, 0.4), 24, primary),
	], [Color.WHITE, Color.WHITE, Color.WHITE, Color(1.0, 1.0, 1.0, 0.7)], 20, bold, 26)

	_button_type(theme, "DangerButton", [
		box(CORAL_PALE, 14, plain), box(Color("f4d6ce"), 14, plain), box(Color("eec6bb"), 14, plain), box(Color(CORAL_PALE, 0.5), 14, plain),
	], [CORAL_INK, CORAL_INK, CORAL_INK, Color(CORAL_INK, 0.5)], 17, regular, 22)

	var segment := Vector2(9.0, 4.0)
	_button_type(theme, "SegmentButton", [
		box(Color(1.0, 1.0, 1.0, 0.0), 14, segment), box(PAPER_SOFT, 14, segment), box(SAKURA_DEEP, 14, segment), box(Color(1.0, 1.0, 1.0, 0.0), 14, segment),
	], [INK_SOFT, INK, Color.WHITE, Color(INK_SOFT, 0.5)], 15, bold, 20)

	var round_pad := Vector2(8.0, 8.0)
	_button_type(theme, "RoundButton", [
		box(Color(PAPER, 0.96), 99, round_pad, LINE, 1, 6), box(PAPER_SOFT, 99, round_pad, LINE, 1, 6), box(SAKURA_PALE, 99, round_pad, SAKURA, 1), box(Color(PAPER, 0.5), 99, round_pad),
	], [INK_SOFT, INK, SAKURA_INK, Color(INK_SOFT, 0.5)], 15, regular, 22)

	var track := box(PAPER_DEEP, 4)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	var filled := box(SAKURA, 4)
	filled.content_margin_top = 4.0
	filled.content_margin_bottom = 4.0
	theme.set_stylebox("slider", "HSlider", track)
	theme.set_stylebox("grabber_area", "HSlider", filled)
	theme.set_stylebox("grabber_area_highlight", "HSlider", filled)
	theme.set_icon("grabber", "HSlider", icon("grabber", 22))
	theme.set_icon("grabber_highlight", "HSlider", icon("grabber_on", 22))
	theme.set_icon("grabber_disabled", "HSlider", icon("grabber", 22))

	theme.set_stylebox("background", "ProgressBar", box(PAPER_DEEP, 5))
	theme.set_stylebox("fill", "ProgressBar", box(SAKURA_DEEP, 5))

	var divider := StyleBoxLine.new()
	divider.color = LINE
	divider.thickness = 2
	divider.vertical = true
	theme.set_stylebox("separator", "VSeparator", divider)
	theme.set_constant("separation", "VSeparator", 14)
	return theme
