@tool
extends Control
## The pie itself: drawing + picking the hovered slice. All behaviour lives in plugin.gd.

## Slot index -> screen direction. 0 = E, then counter-clockwise (N = 2, W = 4, S = 6).
const DIRS: Array[Vector2] = [
	Vector2(1, 0), Vector2(0.7071, -0.7071), Vector2(0, -1), Vector2(-0.7071, -0.7071),
	Vector2(-1, 0), Vector2(-0.7071, 0.7071), Vector2(0, 1), Vector2(0.7071, 0.7071),
]

const RADIUS := 115.0       # distance from centre to each item (unscaled)
const DEAD_ZONE := 22.0     # no item is picked inside this radius (unscaled)

## [{slot:int, id:StringName, label:String, toggle:bool, active:bool, enabled:bool}]
var items: Array = []
var center := Vector2.ZERO
var hovered_id: StringName = &""

var _s := 1.0  # editor scale


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	focus_mode = FOCUS_NONE
	visible = false
	z_index = 100


func open(at: Vector2, new_items: Array) -> void:
	_s = EditorInterface.get_editor_scale()
	items = new_items
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# Keep the whole pie on screen.
	var m := (RADIUS + 40.0) * _s
	var r := get_rect()
	center = Vector2(
		clampf(at.x, m + 90.0 * _s, maxf(m, r.size.x - m - 90.0 * _s)),
		clampf(at.y, m, maxf(m, r.size.y - m)))
	hovered_id = &""
	visible = true
	update_hover()


func close() -> void:
	visible = false
	hovered_id = &""


func update_hover() -> void:
	var v := get_local_mouse_position() - center
	var new_id: StringName = &""
	if v.length() >= DEAD_ZONE * _s:
		# Pick the item whose direction is closest to the mouse direction (Blender behaviour).
		var dir := v.normalized()
		var best := -2.0
		for it in items:
			if not it.get("enabled", true):
				continue
			var d := dir.dot(DIRS[it.slot])
			if d > best:
				best = d
				new_id = it.id
	if new_id != hovered_id:
		hovered_id = new_id
	queue_redraw()


func _draw() -> void:
	if not visible:
		return
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var accent := _theme_color("accent_color", "Editor", Color(0.44, 0.73, 0.98))
	var text_col := _theme_color("font_color", "Label", Color(0.88, 0.88, 0.88))
	var panel := _theme_color("base_color", "Editor", Color(0.13, 0.14, 0.17))
	panel = panel.darkened(0.15)
	panel.a = 0.95

	# Centre ring + direction pointer.
	var ring_r := 13.0 * _s
	draw_arc(center, ring_r, 0.0, TAU, 40, Color(0, 0, 0, 0.55), 6.0 * _s, true)
	draw_arc(center, ring_r, 0.0, TAU, 40, Color(1, 1, 1, 0.35), 2.0 * _s, true)
	var mouse := get_local_mouse_position()
	if mouse.distance_to(center) >= DEAD_ZONE * _s:
		var ang := (mouse - center).angle()
		draw_arc(center, ring_r, ang - 0.55, ang + 0.55, 16, accent, 4.0 * _s, true)

	for it in items:
		_draw_item(it, font, font_size, accent, text_col, panel)


func _draw_item(it: Dictionary, font: Font, font_size: int, accent: Color, text_col: Color, panel: Color) -> void:
	var dir: Vector2 = DIRS[it.slot]
	var anchor := center + dir * RADIUS * _s
	var label: String = it.label
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pad := Vector2(12.0, 6.0) * _s
	var dot_w := 16.0 * _s if it.get("toggle", false) else 0.0
	var size := Vector2(text_size.x + dot_w, text_size.y) + pad * 2.0

	var pos := Vector2(anchor.x - size.x * 0.5, anchor.y - size.y * 0.5)
	if dir.x > 0.3:
		pos.x = anchor.x - 8.0 * _s
	elif dir.x < -0.3:
		pos.x = anchor.x - size.x + 8.0 * _s
	var rect := Rect2(pos, size)

	var hovered: bool = it.id == hovered_id
	var enabled: bool = it.get("enabled", true)
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(int(size.y * 0.5))
	sb.bg_color = accent.darkened(0.35) if hovered else panel
	sb.border_color = accent if hovered else Color(1, 1, 1, 0.12)
	sb.set_border_width_all(maxi(1, int(_s)))
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = int(4 * _s)
	draw_style_box(sb, rect)

	var x := rect.position.x + pad.x
	var col := text_col if enabled else Color(text_col, 0.35)
	if hovered:
		col = Color.WHITE
	if it.get("toggle", false):
		var c := Vector2(x + 5.0 * _s, rect.get_center().y)
		if it.get("active", false):
			draw_circle(c, 4.5 * _s, accent if not hovered else Color.WHITE, true, -1.0, true)
		else:
			draw_arc(c, 4.5 * _s, 0.0, TAU, 20, Color(col, 0.6), 1.5 * _s, true)
		x += dot_w
	var baseline := rect.position.y + pad.y + font.get_ascent(font_size)
	draw_string(font, Vector2(x, baseline), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)


func _theme_color(name: StringName, type: StringName, fallback: Color) -> Color:
	return get_theme_color(name, type) if has_theme_color(name, type) else fallback
