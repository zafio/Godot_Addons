@tool
extends Control
class_name UVAtlasPicker

## v0.8 - visual atlas picker.
## Shows the texture with the island's UV bounds and the atlas regions.
##   Left click            pick the region under the cursor
##   Left drag             draw a new rectangle (emits rect_drawn)
##   Mouse wheel           zoom at cursor
##   Middle / right drag   pan
##   Double click          reset view

signal region_clicked(region_name: String)
signal rect_drawn(rect: Rect2)

var texture: Texture2D:
    set(v):
        texture = v
        queue_redraw()
var preset: UVAtlasPreset:
    set(v):
        preset = v
        queue_redraw()
var island_rect: Rect2 = Rect2()
var has_island_rect := false
var selected_region: String = "":
    set(v):
        selected_region = v
        queue_redraw()
## Snap drawn rectangles to whole texture pixels.
var snap_to_pixels := true

var _zoom := 1.0
var _pan := Vector2.ZERO
var _hover_uv := Vector2(-1, -1)
var _dragging := false
var _drag_start_uv := Vector2.ZERO
var _drag_start_px := Vector2.ZERO
var _drag_uv := Vector2.ZERO
var _panning := false
var _drawn_rect := Rect2()

func _init() -> void:
    custom_minimum_size = Vector2(360, 360)
    clip_contents = true
    mouse_filter = Control.MOUSE_FILTER_STOP

func set_island_rect(rect: Rect2) -> void:
    island_rect = rect
    has_island_rect = true
    queue_redraw()

func clear_island_rect() -> void:
    has_island_rect = false
    queue_redraw()

func reset_view() -> void:
    _zoom = 1.0
    _pan = Vector2.ZERO
    queue_redraw()

func get_last_drawn_rect() -> Rect2:
    return _drawn_rect

# ---------------------------------------------------------------- mapping

func _base_rect() -> Rect2:
    var avail := size - Vector2(8, 8)
    var tex_size := Vector2(1, 1)
    if texture != null:
        tex_size = texture.get_size()
    var s := minf(avail.x / maxf(tex_size.x, 1.0), avail.y / maxf(tex_size.y, 1.0))
    var dim := tex_size * s
    return Rect2((size - dim) * 0.5, dim)

func _view_rect() -> Rect2:
    var b := _base_rect()
    var center := size * 0.5
    return Rect2((b.position - center) * _zoom + center + _pan, b.size * _zoom)

func _uv_to_screen(uv: Vector2) -> Vector2:
    var v := _view_rect()
    return v.position + uv * v.size

func _screen_to_uv(p: Vector2) -> Vector2:
    var v := _view_rect()
    return (p - v.position) / v.size

func _uv_rect_to_screen(r: Rect2) -> Rect2:
    var v := _view_rect()
    return Rect2(v.position + r.position * v.size, r.size * v.size)

func _snap(uv: Vector2) -> Vector2:
    uv = uv.clamp(Vector2.ZERO, Vector2.ONE)
    if snap_to_pixels and texture != null:
        var s := texture.get_size()
        uv = Vector2(round(uv.x * s.x) / s.x, round(uv.y * s.y) / s.y)
    return uv

# ------------------------------------------------------------------ input

func _gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var mb := event as InputEventMouseButton
        if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
            _zoom_at(mb.position, 1.15)
        elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
            _zoom_at(mb.position, 1.0 / 1.15)
        elif mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
            _panning = mb.pressed
        elif mb.button_index == MOUSE_BUTTON_LEFT:
            if mb.double_click:
                reset_view()
            elif mb.pressed:
                _dragging = true
                _drag_start_px = mb.position
                _drag_start_uv = _screen_to_uv(mb.position)
                _drag_uv = _drag_start_uv
            elif _dragging:
                _dragging = false
                if mb.position.distance_to(_drag_start_px) < 4.0:
                    var hit := _region_at(_screen_to_uv(mb.position))
                    if not hit.is_empty():
                        selected_region = hit
                        region_clicked.emit(hit)
                else:
                    var a := _snap(_drag_start_uv)
                    var b := _snap(_screen_to_uv(mb.position))
                    var r := Rect2(a, Vector2.ZERO).expand(b)
                    if r.size.x > 0.0 and r.size.y > 0.0:
                        _drawn_rect = r
                        rect_drawn.emit(r)
                queue_redraw()
        accept_event()
    elif event is InputEventMouseMotion:
        var mm := event as InputEventMouseMotion
        _hover_uv = _screen_to_uv(mm.position)
        if _panning:
            _pan += mm.relative
        if _dragging:
            _drag_uv = _screen_to_uv(mm.position)
        queue_redraw()

func _zoom_at(pos: Vector2, factor: float) -> void:
    var before := _screen_to_uv(pos)
    _zoom = clampf(_zoom * factor, 0.5, 64.0)
    var after_screen := _uv_to_screen(before)
    _pan += pos - after_screen
    queue_redraw()

func _region_at(uv: Vector2) -> String:
    return preset.find_region_at(uv) if preset != null else ""

# ------------------------------------------------------------------- draw

func _draw() -> void:
    var view := _view_rect()
    draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.12, 0.13))
    # checker under the texture so transparent areas are visible
    var cell := 16.0
    var y := view.position.y
    var row := 0
    while y < view.end.y:
        var x := view.position.x
        var col := row % 2
        while x < view.end.x:
            var r := Rect2(x, y, minf(cell, view.end.x - x), minf(cell, view.end.y - y))
            draw_rect(r, Color(0.28, 0.28, 0.3) if col % 2 == 0 else Color(0.2, 0.2, 0.22))
            x += cell
            col += 1
        y += cell
        row += 1
    if texture != null:
        draw_texture_rect(texture, view, false)
    else:
        draw_rect(view, Color(0.25, 0.25, 0.28), false, 1.0)
        draw_string(get_theme_default_font(), view.position + Vector2(8, 20), "No texture", HORIZONTAL_ALIGNMENT_LEFT, -1, 14)

    if preset != null:
        var font := get_theme_default_font()
        var hover_name := _region_at(_hover_uv)
        for r in preset.regions:
            if r == null:
                continue
            var sr := _uv_rect_to_screen(r.rect)
            var is_sel := r.region_name == selected_region
            var is_hover := r.region_name == hover_name
            if is_sel:
                draw_rect(sr, Color(0.2, 0.7, 1.0, 0.25))
            elif is_hover:
                draw_rect(sr, Color(1.0, 1.0, 1.0, 0.12))
            draw_rect(sr, Color(0.2, 0.8, 1.0) if is_sel else Color(1.0, 1.0, 1.0, 0.7), false, 2.0 if is_sel else 1.0)
            if sr.size.x > 30.0 and sr.size.y > 14.0:
                draw_string(font, sr.position + Vector2(3, 13), r.region_name, HORIZONTAL_ALIGNMENT_LEFT, sr.size.x - 4.0, 11, Color(1, 1, 1, 0.95))

    if has_island_rect:
        draw_rect(_uv_rect_to_screen(island_rect), Color(1.0, 0.85, 0.1), false, 2.0)

    if _dragging and _drag_start_px.distance_to(_uv_to_screen(_drag_uv)) >= 4.0:
        var dr := Rect2(_snap(_drag_start_uv), Vector2.ZERO).expand(_snap(_drag_uv))
        var sd := _uv_rect_to_screen(dr)
        draw_rect(sd, Color(0.3, 1.0, 0.4, 0.2))
        draw_rect(sd, Color(0.3, 1.0, 0.4), false, 2.0)
