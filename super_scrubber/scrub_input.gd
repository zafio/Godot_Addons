@tool
extends Node
## Input handler for the Animation dock.
##
## Lives as a child of Godot's AnimationPlayerEditor so it receives input from
## whichever window the dock is in (docked or floating). All behaviour only
## triggers while the mouse is over the animation track editor.
##
##   G (hold)      the playhead snaps to the cursor and follows it.
##   G (tap)       insert keyframe(s) at the playhead with the current values,
##                 for the track (or node group) under the mouse if any.
##   F (tap)       same as tapping G, without touching the playhead.
##   Space+wheel   change key values: the hovered key, or all selected keys
##   or F+wheel    (when hovering a selected key or no key). Shift = fine,
##                 hold X/Y/Z to limit to one axis.
##   Q / E         jump the playhead to the previous / next keyframe of the
##                 selected track or keys, else of the selected node(s), else
##                 of the whole animation. Hold to keep stepping.
##   Ctrl+F        show only the tracks of the nodes selected in the viewport
##                 or Scene tree (Godot's own filter button, toggled); press
##                 again to show all tracks.
##   Auto Key      (the red-dot button next to "Add Track") while on, every
##                 change you make in the viewport or Inspector to an animated
##                 property (moving / rotating / scaling a node, editing a
##                 value) is keyed at the playhead straight away, like
##                 Blender's auto keying. Only properties that already have a
##                 track are keyed. Undo once to remove the key, twice to undo
##                 the change too.
## Keys land on an existing key when the playhead is within half a frame of
## it (so they replace it rather than adding one next to it).

## A G press shorter than this (seconds), without moving, counts as a tap.
const TAP_MAX_TIME := 0.2
## Moving the mouse at least this many pixels while G is down makes it a drag, not a tap.
const DRAG_START_PX := 6.0
## Editor notifications ("Keyed 2 track(s)...", "nothing to key", ...).
const SHOW_NOTIFICATIONS := false
## Space+wheel step per notch (Shift = fine).
const STEP := 0.1
const FINE_STEP := 0.01
## Rotation step per notch, in degrees (Shift = fine).
const ROT_STEP_DEG := 5.0
const FINE_ROT_STEP_DEG := 1.0
## Value comparison tolerance when detecting changed properties.
const EPS := 1e-4
## A key this close to the playhead counts as being under it (the time SpinBox
## rounds to 0.0001, so a key's exact time can sit slightly off the playhead).
const JUMP_EPS := 2e-4

var plugin: EditorPlugin

# Editor internals (found by class name / structure, cached).
var _ape: Control            # AnimationPlayerEditor
var _track_editor: Control   # AnimationTrackEditor
var _timeline: Range         # AnimationTimelineEdit (a Range; value = scroll offset in seconds)
var _zoom: Range             # zoom HSlider at the bottom of the track editor
var _frame: Range            # "Animation position (in seconds)" SpinBox
var _btn_play_bw_from: Button
var _btn_stop: Button
var _btn_play_from: Button
var _add_track_hb: Control
var _add_track_btn: Control
var _filter_edit: Control
var _sel_filter_btn: Button
var _len_hb: Control

var _attached := false

# State.
var _g_down := false
var _g_press_time := 0.0
var _g_key_plan: Dictionary = {}
var _g_press_ms := 0
var _g_press_mouse := Vector2.ZERO
var _last_scrub_time := -1.0
var _native_drag := false
var _drag_vp: Viewport
var _drag_y := 0.0
var _drag_last_pos = null
var _pushing_drag := false

# Properties edited in the Inspector since the last seek/key: [{id, prop}]
var _pending_edits: Array = []

## Test hook: viewport-space mouse position to use instead of the real cursor.
var debug_mouse = null
var _inspector_connected := false

# Mirrored key selection: "track@time" -> [track, time]
var _selection := {}
var _sel_anim: Animation
var _clear_mark := false

# F key state.
var _f_down := false
var _f_used_wheel := false

# Value feedback.
var _hud: PanelContainer
var _hud_label: Label
var _hud_hide_ms := 0
var _burst_sig := ""
var _burst_ms := 0
var _burst_total := 0.0
var _rows_check_ms := 0

# Auto Key.
var _auto_key := false
var _auto_btn: Button
var _auto_history: UndoRedo
var _auto_version := -1
var _auto_pending := false
var _committing := false
var _time_regex := RegEx.create_from_string("(-?[0-9]+(?:[.,][0-9]+)?)\\s*$")


func _ready() -> void:
	set_process(true)
	set_process_input(true)
	var inspector := EditorInterface.get_inspector()
	if inspector and not inspector.property_edited.is_connected(_on_property_edited):
		inspector.property_edited.connect(_on_property_edited)
		inspector.edited_object_changed.connect(_on_inspector_object_changed)
		_inspector_connected = true


func shutdown() -> void:
	if _inspector_connected:
		var inspector := EditorInterface.get_inspector()
		if inspector and inspector.property_edited.is_connected(_on_property_edited):
			inspector.property_edited.disconnect(_on_property_edited)
		if inspector and inspector.edited_object_changed.is_connected(_on_inspector_object_changed):
			inspector.edited_object_changed.disconnect(_on_inspector_object_changed)
	if is_instance_valid(_frame) and _frame.value_changed.is_connected(_on_frame_changed):
		_frame.value_changed.disconnect(_on_frame_changed)
	if is_instance_valid(_hud):
		_hud.queue_free()
	if is_instance_valid(_auto_btn):
		_auto_btn.queue_free()
	_watch_history(null)


# ---------------------------------------------------------------------------
# Locating the editor's controls
# ---------------------------------------------------------------------------

func _nodes_ok() -> bool:
	return is_instance_valid(_ape) and is_instance_valid(_track_editor) \
		and is_instance_valid(_timeline) and is_instance_valid(_zoom) \
		and is_instance_valid(_frame) and is_instance_valid(_btn_play_from) \
		and is_instance_valid(_btn_play_bw_from) and is_instance_valid(_btn_stop) \
		and is_instance_valid(_add_track_hb)


func _ensure_nodes() -> bool:
	if _nodes_ok():
		return true
	_ape = _find_class(get_tree().root, "AnimationPlayerEditor")
	if _ape == null:
		return false
	_track_editor = _find_class(_ape, "AnimationTrackEditor")
	if _track_editor == null:
		return false
	_timeline = _find_class(_track_editor, "AnimationTimelineEdit") as Range
	_zoom = null
	for s in _find_all(_track_editor, "HSlider"):
		var r := s as Range
		if is_equal_approx(r.min_value, 0.0) and is_equal_approx(r.max_value, 2.0) and is_equal_approx(r.step, 0.01):
			_zoom = r
			break
	# The time SpinBox sits right after an HBox holding the 5 playback buttons:
	# [play_bw_from, play_bw, stop, play, play_from]
	_frame = null
	for sb in _find_all(_ape, "SpinBox"):
		if _track_editor.is_ancestor_of(sb):
			continue
		var idx: int = sb.get_index(true)
		if idx == 0:
			continue
		var prev: Node = sb.get_parent().get_child(idx - 1, true)
		if prev is HBoxContainer:
			var btns: Array = []
			for c in prev.get_children(true):
				if c is Button:
					btns.append(c)
			if btns.size() == 5:
				_frame = sb as Range
				_btn_play_bw_from = btns[0]
				_btn_stop = btns[2]
				_btn_play_from = btns[4]
				break
	if _timeline:
		for c in _timeline.get_children(true):
			if c is HBoxContainer:
				var menu: Node = _find_class_typed(c, MenuButton)
				if menu:
					_add_track_hb = c
					_add_track_btn = menu
					_filter_edit = _find_class_typed(c, LineEdit)
				else:
					_len_hb = c
	if _frame and not _frame.value_changed.is_connected(_on_frame_changed):
		_frame.value_changed.connect(_on_frame_changed)
	if not _nodes_ok():
		return false
	# Reparent next to the dock so floating docks also send us input.
	if not _attached and get_parent() != _ape:
		_attached = true
		reparent.call_deferred(_ape)
	return true


static func _find_class(n: Node, cls: String) -> Node:
	if n.get_class() == cls:
		return n
	for c in n.get_children(true):
		var r: Node = _find_class(c, cls)
		if r:
			return r
	return null


static func _find_class_typed(n: Node, type) -> Node:
	for c in n.get_children(true):
		if is_instance_of(c, type):
			return c
		var r: Node = _find_class_typed(c, type)
		if r:
			return r
	return null


static func _find_all(n: Node, cls: String, out: Array = []) -> Array:
	if n.is_class(cls):
		out.append(n)
	for c in n.get_children(true):
		_find_all(c, cls, out)
	return out


# ---------------------------------------------------------------------------
# Timeline geometry (mirrors AnimationTimelineEdit's private math)
# ---------------------------------------------------------------------------

func _zoom_scale() -> float:
	var zv := _zoom.max_value - _zoom.value
	if zv < 1.0:
		zv = 1.0 - zv
		return pow(1.0 + zv, 8.0) * 100.0
	return 1.0 / pow(zv, 8.0) * 100.0


func _buttons_width() -> float:
	if is_instance_valid(_len_hb):
		return _timeline.size.x - _len_hb.position.x
	return 0.0


func _name_limit() -> float:
	var s := EditorInterface.get_editor_scale()
	var hsize_w := 0.0
	var icon := _timeline.get_theme_icon(&"Hsize", &"EditorIcons")
	if icon:
		hsize_w = icon.get_width()
	var filter_w := 0.0
	if is_instance_valid(_filter_edit) and _filter_edit.visible:
		filter_w = _filter_edit.custom_minimum_size.x
	var add_w := 0.0
	if is_instance_valid(_add_track_btn):
		add_w = _add_track_btn.get_combined_minimum_size().x
	var floor_limit := add_w + hsize_w + filter_w + 16.0 * s
	var limit := floor_limit
	# add_track_hb is sized to (name_limit - (hsize + 16) * EDSCALE), but it can't
	# shrink below its own minimum; in that case the editor uses the floor value.
	if _add_track_hb.size.x > _add_track_hb.get_combined_minimum_size().x + 0.5:
		limit = maxf(_add_track_hb.size.x + (hsize_w + 16.0) * s, floor_limit)
	limit = minf(limit, _timeline.size.x - _buttons_width() - 1.0)
	return limit


func _x_to_time(x: float) -> float:
	return (x - _name_limit()) / _zoom_scale() + _timeline.value


func _time_to_x(t: float) -> float:
	return (t - _timeline.value) * _zoom_scale() + _name_limit()


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _local_mouse(c: CanvasItem) -> Vector2:
	if debug_mouse != null:
		return c.get_global_transform_with_canvas().affine_inverse() * debug_mouse
	return c.get_local_mouse_position()

func _can_handle() -> bool:
	if not _ensure_nodes():
		return false
	if not _track_editor.is_visible_in_tree():
		return false
	var local := _local_mouse(_track_editor)
	if not Rect2(Vector2.ZERO, _track_editor.size).has_point(local):
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	var player := _find_player()
	return player != null and player.has_animation(player.assigned_animation)


func _input(event: InputEvent) -> void:
	# During a G drag the playhead follows one position per frame, sampled from
	# the live cursor. Real motion events lag behind it, so letting them through
	# too would seek twice a frame and pull the playhead back and forth.
	if _native_drag and not _pushing_drag and event is InputEventMouseMotion:
		get_viewport().set_input_as_handled()
		return
	var mb := event as InputEventMouseButton
	if mb:
		if _handle_wheel(mb):
			get_viewport().set_input_as_handled()
		return
	var k := event as InputEventKey
	if k == null:
		return
	if k.keycode == KEY_F and k.ctrl_pressed:
		_handle_selected_filter(k)
		return
	if k.keycode == KEY_F:
		_handle_f(k)
		return
	if k.keycode == KEY_Q or k.keycode == KEY_E:
		_handle_jump(k)
		return
	if k.keycode != KEY_G:
		return

	if k.pressed:
		if k.echo or _g_down:
			if _g_down:
				get_viewport().set_input_as_handled()
			return
		if k.ctrl_pressed or k.alt_pressed or k.meta_pressed or k.shift_pressed:
			return
		if not _can_handle():
			return
		get_viewport().set_input_as_handled()
		_g_press()
	elif _g_down:
		get_viewport().set_input_as_handled()
		_g_release(true)


## F: tap inserts keyframes; held, it works as the modifier for the wheel.
func _handle_f(k: InputEventKey) -> void:
	if k.pressed:
		if k.echo or _f_down:
			if _f_down:
				get_viewport().set_input_as_handled()
			return
		if k.ctrl_pressed or k.alt_pressed or k.meta_pressed or k.shift_pressed:
			return
		if not _can_handle():
			return
		get_viewport().set_input_as_handled()
		_f_down = true
		_f_used_wheel = false
	elif _f_down:
		get_viewport().set_input_as_handled()
		_f_down = false
		if not _f_used_wheel and _nodes_ok():
			_insert_keys()


## Ctrl+F: the track editor's own "Only show tracks from nodes selected in
## tree" toggle (it follows the viewport selection too, which is the editor's).
func _handle_selected_filter(k: InputEventKey) -> void:
	if not k.pressed or k.echo or _g_down or _f_down:
		return
	if k.alt_pressed or k.meta_pressed or k.shift_pressed:
		return
	if not _can_handle():
		return
	var btn := _selected_filter_button()
	if btn == null:
		return
	get_viewport().set_input_as_handled()
	btn.button_pressed = not btn.button_pressed
	btn.pressed.emit() # the editor rebuilds the track list on "pressed"
	_toast("Tracks: selected nodes only" if btn.button_pressed else "Tracks: all", 0)


func _selected_filter_button() -> Button:
	if is_instance_valid(_sel_filter_btn):
		return _sel_filter_btn
	var icon := EditorInterface.get_editor_theme().get_icon(&"AnimationFilter", &"EditorIcons")
	for b in _find_all(_track_editor, "Button"):
		var btn := b as Button
		if btn.toggle_mode and btn.icon == icon:
			_sel_filter_btn = btn
			return btn
	return null


## Q / E: echo is allowed, so holding the key walks through the keyframes.
func _handle_jump(k: InputEventKey) -> void:
	if not k.pressed or _g_down:
		return
	if k.ctrl_pressed or k.alt_pressed or k.meta_pressed or k.shift_pressed:
		return
	if not _can_handle():
		return
	get_viewport().set_input_as_handled()
	_jump_to_key(-1 if k.keycode == KEY_Q else 1)


func _jump_to_key(dir: int) -> void:
	var player := _find_player()
	if player == null:
		return
	var anim := player.get_animation(player.assigned_animation)
	if anim == null:
		return
	if player.is_playing():
		_btn_stop.pressed.emit() # pause
	var now: float = _frame.value
	var best := 0.0
	var found := false
	for track: int in _jump_tracks(anim, player):
		for k in anim.track_get_key_count(track):
			var t := anim.track_get_key_time(track, k)
			var ahead := t > now + JUMP_EPS if dir > 0 else t < now - JUMP_EPS
			if ahead and (not found or (t < best if dir > 0 else t > best)):
				best = t
				found = true
	if found:
		_timeline.emit_signal(&"timeline_changed", best, false)


## Tracks Q / E look at, most specific selection first:
##  1. the focused row (the editor's "selected track"), plus the tracks of any
##     selected keys when that row holds one of them,
##  2. the tracks of the selected keys,
##  3. the tracks of the selected node(s),
##  4. every track.
func _jump_tracks(anim: Animation, player: AnimationPlayer) -> Array:
	var key_tracks := {}
	if anim == _sel_anim and not _clear_mark:
		for id in _selection:
			if _selection[id][0] < anim.get_track_count():
				key_tracks[_selection[id][0]] = true
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and focus.is_class("AnimationTrackEdit"):
		var rows := _row_track_map(anim)
		if rows.has(focus):
			return key_tracks.keys() if key_tracks.has(rows[focus]) else [rows[focus]]
	if not key_tracks.is_empty():
		return key_tracks.keys()
	var all: Array = range(anim.get_track_count())
	var root := player.get_node_or_null(player.root_node)
	if root == null:
		return all
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var out: Array = []
	for i: int in all:
		var n := _track_node(anim, i, root)
		if n != null and n != player and n in selected:
			out.append(i)
	return out if not out.is_empty() else all


func _process(_delta: float) -> void:
	if is_instance_valid(_hud) and _hud.visible and Time.get_ticks_msec() > _hud_hide_ms:
		_hud.hide()
	if _f_down and not Input.is_key_pressed(KEY_F):
		_f_down = false
	_auto_key_tick()
	# Keep selection-mirror signal connections on (rebuilt) track rows.
	var now := Time.get_ticks_msec()
	if now - _rows_check_ms > 250 and not _g_down:
		_rows_check_ms = now
		_watch_rows()

	# Safety net if the key-up event went elsewhere (focus change, window switch).
	if _g_down and not Input.is_key_pressed(KEY_G):
		_g_release(false)

	if _g_down and _nodes_ok():
		if _native_drag:
			_native_drag_motion()
		else:
			_scrub_to_mouse()


func _g_press() -> void:
	_g_down = true
	_g_press_ms = Time.get_ticks_msec()
	_g_press_mouse = _local_mouse(_track_editor)
	_last_scrub_time = -1.0
	var player := _find_player()
	if player and player.is_playing():
		_btn_stop.pressed.emit() # pause
	# Capture what a tap would key *before* the playhead moves: seeking re-applies
	# the animation and would overwrite the values we want to key.
	_g_press_time = _frame.value
	_g_key_plan = _build_key_plan(_g_press_time)
	# Snap the playhead to the cursor immediately by driving the timeline's own
	# LMB drag, so the editor does the pixel -> time conversion itself.
	_native_drag = _begin_native_drag()
	if not _native_drag:
		_scrub_to_mouse()


func _g_release(allow_tap: bool) -> void:
	_g_down = false
	if _native_drag:
		_end_native_drag()
	var held := (Time.get_ticks_msec() - _g_press_ms) / 1000.0
	var moved := _local_mouse(_track_editor).distance_to(_g_press_mouse) if _nodes_ok() else INF
	var plan := _g_key_plan
	_g_key_plan = {}
	if not allow_tap or held >= TAP_MAX_TIME or moved >= DRAG_START_PX or not _nodes_ok():
		return
	# Tap: put the playhead back where it was and key there.
	_timeline.emit_signal(&"timeline_changed", _g_press_time, false)
	_commit_key_plan(plan)


## Starts the timeline's native scrub drag with a synthetic left-button press.
## The timeline then holds mouse focus as during a normal LMB drag, and
## _native_drag_motion feeds it the cursor position once per frame.
func _begin_native_drag() -> bool:
	var vp := _timeline.get_viewport()
	if vp == null:
		return false
	var player := _find_player()
	var anim: Animation = player.get_animation(player.assigned_animation) if player else null
	var s := EditorInterface.get_editor_scale()
	# The press must land in the time area (not the name column or the buttons)
	# and must avoid the animation-length handle, or it would start a resize.
	var left := _name_limit() + 12.0 * s
	var right := _timeline.size.x - _buttons_width() - 12.0 * s
	if right <= left:
		return false
	var x := clampf(_local_mouse(_timeline).x, left, right)
	if anim:
		var handle := _timeline.get_theme_icon(&"TimelineHandle", &"EditorIcons")
		var hw: float = handle.get_width() if handle else 16.0 * s
		var end_x := _time_to_x(anim.length)
		var margin := hw * 0.5 + 6.0 * s
		if absf(x - end_x) < margin:
			x = end_x - margin if end_x - margin >= left else end_x + margin
			if x > right:
				return false
	_drag_vp = vp
	_drag_y = _timeline.size.y * 0.5
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev.pressed = true
	ev.position = _timeline.get_global_transform_with_canvas() * Vector2(x, _drag_y)
	ev.global_position = ev.position
	vp.push_input(ev, true)
	_drag_last_pos = null
	_native_drag_motion() # move from the press point to the real cursor x
	return true


func _native_drag_motion() -> void:
	if not is_instance_valid(_drag_vp):
		return
	var lp := _local_mouse(_timeline)
	var p := _timeline.get_global_transform_with_canvas() * Vector2(lp.x, _drag_y)
	if _drag_last_pos != null and _drag_last_pos == p:
		return
	_drag_last_pos = p
	var mm := InputEventMouseMotion.new()
	mm.position = p
	mm.global_position = p
	_pushing_drag = true
	_drag_vp.push_input(mm, true)
	_pushing_drag = false


func _end_native_drag() -> void:
	_native_drag = false
	if not is_instance_valid(_drag_vp):
		return
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	# Release where the cursor is now, so the timeline doesn't jump.
	var p = _drag_last_pos
	if is_instance_valid(_timeline):
		p = _timeline.get_global_transform_with_canvas() * Vector2(_local_mouse(_timeline).x, _drag_y)
	ev.position = p if p != null else Vector2.ZERO
	ev.global_position = ev.position
	_drag_vp.push_input(ev, true)
	_drag_vp = null


## Fallback scrub (used only if the native drag can't start).
func _scrub_to_mouse() -> void:
	var player := _find_player()
	if player == null:
		return
	var anim := player.get_animation(player.assigned_animation)
	if anim == null:
		return
	var t := clampf(_x_to_time(_local_mouse(_timeline).x), 0.0, anim.length)
	if absf(t - _last_scrub_time) < 1e-6:
		return
	_last_scrub_time = t
	# Same signal a click on the timeline emits, so editor snapping etc. applies.
	_timeline.emit_signal(&"timeline_changed", t, false)


# ---------------------------------------------------------------------------
# Hovered track rows
# ---------------------------------------------------------------------------

## Track indices under the mouse: [i] for a track row, all of the node's tracks
## for a group header, or null when the mouse isn't over any track row.
func _hovered_tracks(anim: Animation):
	var row_track := _row_track_map(anim)
	for r in row_track:
		if _mouse_over(r):
			return [row_track[r]]
	for g in _find_all(_track_editor, "AnimationTrackEditGroup"):
		if g.is_visible_in_tree() and _mouse_over(g):
			var out: Array = []
			for c in g.get_parent().get_children(true):
				if row_track.has(c):
					out.append(row_track[c])
			return out
	return null


## Visible track rows -> track index.
func _row_track_map(anim: Animation) -> Dictionary:
	var paths := {}
	for i in anim.get_track_count():
		paths[str(anim.track_get_path(i))] = true
	var nl := _name_limit()
	var row_track := {}
	var seen := {}
	for r in _find_all(_track_editor, "AnimationTrackEdit"):
		if not r.is_visible_in_tree():
			continue
		var p := _row_path(r, paths, nl)
		if p == "":
			continue
		var n: int = seen.get(p, 0)
		seen[p] = n + 1
		var idx := _nth_track_with_path(anim, p, n)
		if idx >= 0:
			row_track[r] = idx
	return row_track


## The track path shown in a row, read through the row's own tooltip.
static func _row_path(row: Control, paths: Dictionary, name_limit: float) -> String:
	var y := row.size.y * 0.5
	var x := name_limit - 4.0
	while x > 8.0:
		var tip := row.get_tooltip(Vector2(x, y))
		if paths.has(tip):
			return tip
		x -= 6.0
	return ""


static func _nth_track_with_path(anim: Animation, path: String, n: int) -> int:
	for i in anim.get_track_count():
		if str(anim.track_get_path(i)) == path:
			if n == 0:
				return i
			n -= 1
	return -1


## Mouse inside the control and inside every scroll area clipping it.
func _mouse_over(c: Control) -> bool:
	if not Rect2(Vector2.ZERO, c.size).has_point(_local_mouse(c)):
		return false
	var p := c.get_parent()
	while p:
		if p is ScrollContainer:
			var sc := p as Control
			if not Rect2(Vector2.ZERO, sc.size).has_point(_local_mouse(sc)):
				return false
		p = p.get_parent()
	return true


# ---------------------------------------------------------------------------
# Space/F + mouse wheel: nudge key values
# ---------------------------------------------------------------------------

## Space+wheel or F+wheel changes key values:
##  - over a key that is selected: all selected keys,
##  - over an unselected key: just that key,
##  - not over a key: all selected keys (if any).
## Shift = fine steps. Hold X / Y / Z to limit vectors and rotations to one axis
## (for colors: R / G / B).
func _handle_wheel(mb: InputEventMouseButton) -> bool:
	if not mb.pressed or mb.ctrl_pressed or mb.alt_pressed or mb.meta_pressed:
		return false
	var via_f := _f_down
	if not via_f and not Input.is_key_pressed(KEY_SPACE):
		return false
	var dir := 0
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_RIGHT:
			dir = 1
		MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT:
			dir = -1
		_:
			return false
	if not _ensure_nodes() or not _track_editor.is_visible_in_tree():
		return false
	if not Rect2(Vector2.ZERO, _track_editor.size).has_point(_local_mouse(_track_editor)):
		return false
	var player := _find_player()
	if player == null:
		return false
	var anim := player.get_animation(player.assigned_animation)
	if anim == null:
		return false

	if _clear_mark:
		_selection.clear()
	var selected: Array = []
	if anim == _sel_anim:
		for id in _selection:
			selected.append(_selection[id])
	var hit := _key_under_mouse()
	var targets: Array
	if hit.is_empty():
		if selected.is_empty():
			return false # nothing to change: let the wheel scroll as usual
		targets = selected
	elif _selection.has(_sel_id(hit.track, hit.time)) and anim == _sel_anim:
		targets = selected
	else:
		targets = [[hit.track, hit.time]]

	# Some platforms turn Shift+wheel into horizontal wheel events.
	var fine := mb.shift_pressed or mb.button_index == MOUSE_BUTTON_WHEEL_LEFT \
			or mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT
	var amount := dir * (mb.factor if mb.factor > 0.0 else 1.0)
	_nudge_targets(anim, targets, amount, fine, hit)
	if via_f:
		_f_used_wheel = true
	return true


## {anim, root, track, time, row} of the key under the mouse, or {}.
func _key_under_mouse() -> Dictionary:
	var player := _find_player()
	if player == null:
		return {}
	var anim := player.get_animation(player.assigned_animation)
	if anim == null:
		return {}
	var rows := _row_track_map(anim)
	for r: Control in rows:
		if not _mouse_over(r):
			continue
		var track: int = rows[r]
		# The row's tooltip uses the editor's own key hit-test; its first line
		# carries the key time.
		var local := _local_mouse(r)
		var tip := r.get_tooltip(local)
		var best := -1
		var m := _time_regex.search(tip.get_slice("\n", 0))
		if m != null and tip.contains("\n"):
			var t := m.get_string(1).replace(",", ".").to_float()
			var best_d := 0.001
			for k in anim.track_get_key_count(track):
				var d := absf(anim.track_get_key_time(track, k) - t)
				if d <= best_d:
					best_d = d
					best = k
		elif tip == "":
			# Godot's tooltip never reports keys on rows that don't pick keys by
			# distance (bool, color, audio...). Use our own geometry there.
			var nl := _name_limit()
			if local.x >= nl - 8.0 and local.x <= r.size.x - _buttons_width():
				var best_px := 9.0 * EditorInterface.get_editor_scale()
				for k in anim.track_get_key_count(track):
					var d := absf(_time_to_x(anim.track_get_key_time(track, k)) - local.x)
					if d <= best_px:
						best_px = d
						best = k
		if best < 0:
			return {}
		return {"anim": anim, "root": player.get_node_or_null(player.root_node),
			"track": track, "time": anim.track_get_key_time(track, best), "row": r}
	return {}


func _nudge_targets(anim: Animation, targets: Array, amount: float, fine: bool, hit: Dictionary) -> void:
	var axis := -1
	if Input.is_key_pressed(KEY_X):
		axis = 0
	elif Input.is_key_pressed(KEY_Y):
		axis = 1
	elif Input.is_key_pressed(KEY_Z):
		axis = 2

	var ur := plugin.get_undo_redo()
	# Notches within a short burst merge into one undo step. MERGE_ALL + reversed
	# undo ops restores every touched key to its value before the burst.
	ur.create_action("SuperScrubber: Adjust Key Value", UndoRedo.MERGE_ALL, null, true)
	var changed: Array = [] # [track, new value, prop]
	var skipped := 0
	for e in targets:
		var track: int = e[0]
		if track >= anim.get_track_count() or anim.track_is_compressed(track):
			continue
		var k := anim.track_find_key(track, e[1], Animation.FIND_MODE_APPROX)
		if k < 0:
			continue
		var type := anim.track_get_type(track)
		var prop := _track_prop(anim, track)
		var old
		if type == Animation.TYPE_BEZIER:
			old = anim.bezier_track_get_key_value(track, k)
		elif type in [Animation.TYPE_VALUE, Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D,
				Animation.TYPE_SCALE_3D, Animation.TYPE_BLEND_SHAPE]:
			old = anim.track_get_key_value(track, k)
		else:
			skipped += 1
			continue
		var new = _nudged(old, amount, fine, axis, type, prop)
		if new == null:
			skipped += 1
			continue
		if type == Animation.TYPE_BEZIER:
			ur.add_do_method(anim, "bezier_track_set_key_value", track, k, new)
			ur.add_undo_method(anim, "bezier_track_set_key_value", track, k, old)
		else:
			ur.add_do_method(anim, "track_set_key_value", track, k, new)
			ur.add_undo_method(anim, "track_set_key_value", track, k, old)
		changed.append([track, new, prop])
	if changed.is_empty():
		ur.commit_action(false)
		if skipped > 0:
			_toast("SuperScrubber: this key type can't be adjusted with the wheel.", 1)
		return
	# Re-apply the animation at the playhead so the viewport shows the change.
	ur.add_do_method(self, "_refresh_pose")
	ur.add_undo_method(self, "_refresh_pose")
	ur.commit_action()
	_show_feedback(anim, targets, changed, amount, fine, axis, hit)


func _refresh_pose() -> void:
	if _nodes_ok():
		_timeline.emit_signal(&"timeline_changed", _frame.value, false)


static func _track_prop(anim: Animation, track: int) -> String:
	var path := anim.track_get_path(track)
	if path.get_subname_count() > 0:
		return str(path.get_subname(path.get_subname_count() - 1))
	return ""


# ---------------------------------------------------------------------------
# Value feedback (tooltip)
# ---------------------------------------------------------------------------

func _show_feedback(anim: Animation, targets: Array, changed: Array, amount: float,
		fine: bool, axis: int, hit: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	var sig := "%s|%d|%s" % [str(targets), axis, fine]
	if sig != _burst_sig or now - _burst_ms > 1000:
		_burst_total = 0.0
	_burst_sig = sig
	_burst_ms = now
	_burst_total += amount

	# Hovering a key whose Godot tooltip is open: refresh that tooltip in place.
	if not hit.is_empty() and changed.size() == 1 and _update_native_tooltip(hit.row):
		_hide_hud()
		return

	var first: Array = changed[0]
	var lines: PackedStringArray = []
	if changed.size() == 1:
		lines.append("%s: %s" % [_track_label(anim, first[0]), _fmt(first[1])])
	else:
		lines.append("%d keys" % changed.size())
	var delta := _fmt_delta(first[1], first[2], fine, _burst_total)
	if delta != "":
		lines.append(delta + ("  (%s)" % ["X", "Y", "Z"][axis] if axis >= 0 else ""))
	_show_hud("\n".join(lines))


func _update_native_tooltip(row: Control) -> bool:
	if not is_instance_valid(row):
		return false
	for c in row.get_children(true):
		if c is PopupPanel and c.visible:
			var lbl := _find_class_typed(c, Label) as Label
			var text := row.get_tooltip(_local_mouse(row)).strip_edges()
			if lbl == null or text == "":
				return false
			lbl.text = text
			c.size = Vector2i(c.get_contents_minimum_size())
			return true
	return false


func _show_hud(text: String) -> void:
	if not is_instance_valid(_hud):
		_hud = PanelContainer.new()
		_hud.theme_type_variation = &"TooltipPanel"
		_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hud.top_level = true
		_hud.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
		_hud_label = Label.new()
		_hud_label.theme_type_variation = &"TooltipLabel"
		_hud.add_child(_hud_label)
		_track_editor.add_child(_hud, false, Node.INTERNAL_MODE_BACK)
	_hud_label.text = text
	_hud.reset_size()
	var s := EditorInterface.get_editor_scale()
	var vr := _track_editor.get_viewport_rect()
	var mouse := _track_editor.get_global_transform_with_canvas() * _local_mouse(_track_editor)
	var pos := mouse + Vector2(14.0, 18.0) * s
	pos.x = minf(pos.x, vr.end.x - _hud.size.x - 4.0)
	if pos.y + _hud.size.y > vr.end.y:
		pos.y = mouse.y - _hud.size.y - 6.0 * s
	_hud.position = pos
	_hud.show()
	_hud_hide_ms = Time.get_ticks_msec() + 1200


func _hide_hud() -> void:
	if is_instance_valid(_hud):
		_hud.hide()


func _track_label(anim: Animation, track: int) -> String:
	var path := anim.track_get_path(track)
	var node := str(path.get_concatenated_names())
	match anim.track_get_type(track):
		Animation.TYPE_POSITION_3D:
			return node + " (Position)"
		Animation.TYPE_ROTATION_3D:
			return node + " (Rotation)"
		Animation.TYPE_SCALE_3D:
			return node + " (Scale)"
		Animation.TYPE_BLEND_SHAPE:
			return node + " (Blend Shape)"
	return str(path)


static func _fmt_num(f: float) -> String:
	var s := "%.3f" % f
	s = s.rstrip("0").rstrip(".")
	return "0" if s == "-0" else s


static func _fmt(v) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "On" if v else "Off"
		TYPE_FLOAT:
			return _fmt_num(v)
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4:
			var parts: PackedStringArray = []
			for i in _vec_len(v):
				parts.append(_fmt_num(v[i]))
			return "(" + ", ".join(parts) + ")"
		TYPE_QUATERNION:
			var e: Vector3 = (v as Quaternion).get_euler()
			return "(%s°, %s°, %s°)" % [_fmt_num(rad_to_deg(e.x)), _fmt_num(rad_to_deg(e.y)), _fmt_num(rad_to_deg(e.z))]
		TYPE_COLOR:
			var c: Color = v
			return "(%s, %s, %s, %s)" % [_fmt_num(c.r), _fmt_num(c.g), _fmt_num(c.b), _fmt_num(c.a)]
	return str(v)


static func _fmt_delta(v, prop: String, fine: bool, total: float) -> String:
	var rot_deg := FINE_ROT_STEP_DEG if fine else ROT_STEP_DEG
	match typeof(v):
		TYPE_BOOL:
			return ""
		TYPE_INT, TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I:
			return "Δ %+d" % int(roundf(total))
		TYPE_QUATERNION:
			return "Δ %s°" % _signed(total * rot_deg)
	if prop == "rotation" or prop == "rotation_degrees":
		return "Δ %s°" % _signed(total * rot_deg)
	return "Δ %s" % _signed(total * (FINE_STEP if fine else STEP))


static func _signed(f: float) -> String:
	return ("+" if f >= 0.0 else "") + _fmt_num(f)


## Returns the value moved by `amount` steps, or null if the type isn't supported.
static func _nudged(v, amount: float, fine: bool, axis: int, type: int, prop: String):
	var step := FINE_STEP if fine else STEP
	var rot_deg := FINE_ROT_STEP_DEG if fine else ROT_STEP_DEG
	if prop == "rotation":
		step = deg_to_rad(rot_deg) # euler radians
	elif prop == "rotation_degrees":
		step = rot_deg
	var d := amount * step
	var di := int(signf(amount)) * maxi(1, int(roundf(absf(amount))))
	match typeof(v):
		TYPE_BOOL:
			return not v
		TYPE_INT:
			return v + di
		TYPE_FLOAT:
			return v + d
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4:
			return _add_axis(v, d, axis)
		TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I:
			return _add_axis(v, di, axis)
		TYPE_COLOR:
			var c: Color = v
			if axis == 0 or axis == -1:
				c.r += d
			if axis == 1 or axis == -1:
				c.g += d
			if axis == 2 or axis == -1:
				c.b += d
			return c
		TYPE_QUATERNION:
			var ax := Vector3.UP
			if axis == 0:
				ax = Vector3.RIGHT
			elif axis == 2:
				ax = Vector3.BACK
			return (Quaternion(ax, deg_to_rad(amount * rot_deg)) * (v as Quaternion)).normalized()
	return null


static func _add_axis(v, d, axis: int):
	if axis < 0:
		for i in _vec_len(v):
			v[i] += d
	elif axis < _vec_len(v):
		v[axis] += d
	return v


static func _vec_len(v) -> int:
	match typeof(v):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return 2
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return 3
	return 4


# ---------------------------------------------------------------------------
# Key selection mirror
# ---------------------------------------------------------------------------
# Godot doesn't expose the key selection to scripts, so it is mirrored from the
# rows' select_key / deselect_key signals. The editor shows a key object in the
# Inspector while keys are selected. When it clears the selection, the Inspector
# goes to null; when it merely rebuilds that object it goes null -> new key object
# synchronously. So "Inspector left a key object and didn't come back" = cleared.

func _sel_id(track: int, time: float) -> String:
	return "%d@%.4f" % [track, time]


func _watch_rows() -> void:
	if not _nodes_ok():
		return
	var player := _find_player()
	if player == null:
		return
	var anim := player.get_animation(player.assigned_animation)
	if anim != _sel_anim:
		_selection.clear()
		_sel_anim = anim
	if _clear_mark and not _selection.is_empty():
		_selection.clear()
	for r in _find_all(_track_editor, "AnimationTrackEdit"):
		var cb_sel := Callable(self, "_on_row_select_key").bind(r)
		if not r.is_connected(&"select_key", cb_sel):
			# Deferred, so it runs after the editor's own (also deferred) handler.
			r.connect(&"select_key", cb_sel, CONNECT_DEFERRED)
			r.connect(&"deselect_key", Callable(self, "_on_row_deselect_key").bind(r), CONNECT_DEFERRED)


func _row_track_for(row: Node) -> Array:
	if not is_instance_valid(row) or _sel_anim == null:
		return []
	var map := _row_track_map(_sel_anim)
	return [map[row]] if map.has(row) else []


func _on_row_select_key(index: int, single: bool, row: Node) -> void:
	var t := _row_track_for(row)
	if t.is_empty():
		return
	var track: int = t[0]
	if index < 0 or index >= _sel_anim.track_get_key_count(track):
		return
	if single or _clear_mark:
		_selection.clear()
		_clear_mark = false
	var time := _sel_anim.track_get_key_time(track, index)
	_selection[_sel_id(track, time)] = [track, time]


func _on_row_deselect_key(index: int, row: Node) -> void:
	var t := _row_track_for(row)
	if t.is_empty():
		return
	var track: int = t[0]
	if index < 0 or index >= _sel_anim.track_get_key_count(track):
		return
	_selection.erase(_sel_id(track, _sel_anim.track_get_key_time(track, index)))


func _on_inspector_object_changed() -> void:
	var obj := EditorInterface.get_inspector().get_edited_object()
	_clear_mark = obj == null or not (obj.get_class() in ["AnimationTrackKeyEdit", "AnimationMultiTrackKeyEdit"])


# ---------------------------------------------------------------------------
# Player lookup
# ---------------------------------------------------------------------------

func _find_player() -> AnimationPlayer:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var players: Array = []
	_collect_players(root, players)
	if players.is_empty():
		return null
	if players.size() == 1:
		return players[0]
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n in players:
			return n
	var fallback: AnimationPlayer = null
	for p: AnimationPlayer in players:
		if p.assigned_animation != &"" and p.has_animation(p.assigned_animation):
			if fallback == null:
				fallback = p
			if is_instance_valid(_frame) and p.is_playing() == false \
					and absf(p.current_animation_position - _frame.value) < 1e-4:
				return p
	return fallback if fallback else players[0]


static func _collect_players(n: Node, out: Array) -> void:
	if n is AnimationPlayer:
		out.append(n)
	for c in n.get_children():
		_collect_players(c, out)


# ---------------------------------------------------------------------------
# Inspector edit tracking
# ---------------------------------------------------------------------------

func _on_property_edited(property: String) -> void:
	var obj := EditorInterface.get_inspector().get_edited_object()
	if not (obj is Node) or obj is AnimationMixer:
		return
	var id := obj.get_instance_id()
	for e in _pending_edits:
		if e.id == id and e.prop == property:
			return
	_pending_edits.append({"id": id, "prop": property})


func _on_frame_changed(_v: float) -> void:
	# Seeking re-applies the animation, which overwrites unkeyed edits.
	_pending_edits.clear()


# ---------------------------------------------------------------------------
# Keyframe insertion
# ---------------------------------------------------------------------------

## What gets keyed, decided from the current state at time t:
##  - mouse over a track row: that track; over a node group header: all its tracks.
##  - otherwise, in priority order:
##    1. properties edited in the Inspector since the last seek (creates tracks if needed),
##    2. existing tracks whose current value differs from the animation at t
##       (catches gizmo moves in the viewport),
##    3. if nothing changed: every track of the selected node(s).
## Returns {anim, t, jobs} or {error}.
func _build_key_plan(t: float, auto: bool = false) -> Dictionary:
	var player := _find_player()
	if player == null:
		return {"error": "SuperScrubber: no AnimationPlayer found."}
	var anim := player.get_animation(player.assigned_animation)
	if anim == null:
		return {"error": "SuperScrubber: no animation selected."}
	var root := player.get_node_or_null(player.root_node)
	if root == null:
		return {"error": "SuperScrubber: AnimationPlayer root node not found."}

	var jobs: Array = []
	# What's shown is the animation at the playhead (t); the keys go on an
	# existing key if one is within half a frame of it.
	var key_t := _key_time(anim, t)
	var hovered = null if auto else _hovered_tracks(anim)
	if hovered != null:
		for i: int in hovered:
			if anim.track_is_compressed(i):
				continue
			var cur = _read_track_value(anim, i, root)
			if cur != null:
				jobs.append({"track": i, "type": anim.track_get_type(i), "value": cur})
		if jobs.is_empty():
			return {"error": "SuperScrubber: can't read a value for the hovered track."}
		return {"anim": anim, "t": key_t, "jobs": jobs}

	var used := {}

	# 1. Inspector edits (Auto Key: only existing tracks, caught below, so
	#    editing some unrelated setting never creates a track).
	for e in ([] if auto else _pending_edits):
		var node := instance_from_id(e.id) as Node
		if node == null or not is_instance_valid(node):
			continue
		if node != root and not root.is_ancestor_of(node):
			continue
		_jobs_for_edit(anim, root, node, e.prop, jobs, used)

	# 2. Changed values on existing tracks.
	for i in anim.get_track_count():
		if used.has(i) or not anim.track_is_enabled(i) or anim.track_is_compressed(i):
			continue
		if anim.track_get_key_count(i) == 0:
			continue
		var cur = _read_track_value(anim, i, root)
		var ref = _interpolate(anim, i, t)
		if cur == null or ref == null:
			continue
		if not _values_equal(cur, ref):
			used[i] = true
			jobs.append({"track": i, "type": anim.track_get_type(i), "value": cur})

	# 3. Fallback: all tracks of selected nodes.
	if jobs.is_empty() and not auto:
		var selected := EditorInterface.get_selection().get_selected_nodes()
		for i in anim.get_track_count():
			if anim.track_is_compressed(i):
				continue
			var n := _track_node(anim, i, root)
			if n == null or n == player or not (n in selected):
				continue
			var cur = _read_track_value(anim, i, root)
			if cur != null:
				jobs.append({"track": i, "type": anim.track_get_type(i), "value": cur})

	if jobs.is_empty():
		return {"error": "SuperScrubber: nothing to key. Hover a track, change a property, or select an animated node."}
	return {"anim": anim, "t": key_t, "jobs": jobs}


static func _half_frame(anim: Animation) -> float:
	return (anim.step if anim.step > 0.0 else 1.0 / 30.0) * 0.5


## Track `i`'s key within half a frame of `t`, or -1. Of several (duplicates),
## the one nearest a whole frame of the animation's step, i.e. the original.
static func _near_key(anim: Animation, i: int, t: float) -> int:
	var half := _half_frame(anim)
	var step := half * 2.0
	var best := -1
	var best_off := INF
	var k0 := anim.track_find_key(i, t - half, Animation.FIND_MODE_NEAREST)
	for j in range(maxi(k0, 0), anim.track_get_key_count(i)):
		var kt := anim.track_get_key_time(i, j)
		if kt > t + half:
			break
		if absf(kt - t) >= half:
			continue
		var off := absf(kt / step - roundf(kt / step)) * step
		if off < best_off - 1e-7 or (absf(off - best_off) <= 1e-7 and absf(kt - t) < absf(anim.track_get_key_time(i, best) - t)):
			best = j
			best_off = off
	return best


## The time new keys go to: an existing key's time when one is within half a
## frame of `t` (the animation's step, or 1/60 s), preferring a key on a whole
## frame (an original over a stray duplicate), else `t`.
static func _key_time(anim: Animation, t: float) -> float:
	var step := _half_frame(anim) * 2.0
	var best := t
	var best_off := INF
	for i in anim.get_track_count():
		var k := _near_key(anim, i, t)
		if k < 0:
			continue
		var kt := anim.track_get_key_time(i, k)
		var off := absf(kt / step - roundf(kt / step)) * step
		if off < best_off - 1e-7 or (absf(off - best_off) <= 1e-7 and absf(kt - t) < absf(best - t)):
			best = kt
			best_off = off
	return best


func _insert_keys() -> void:
	_commit_key_plan(_build_key_plan(_frame.value))


func _commit_key_plan(plan: Dictionary) -> void:
	if plan.is_empty():
		return
	if plan.has("error"):
		_toast(plan.error, 1)
		return
	var anim: Animation = plan.anim
	var t: float = plan.t
	var jobs: Array = plan.jobs

	var ur := plugin.get_undo_redo()
	_committing = true
	ur.create_action("Auto Key" if plan.get("auto", false) else "Insert Keyframe(s)", UndoRedo.MERGE_DISABLE, null, true)
	var next_idx := anim.get_track_count()
	for job in jobs:
		var type: int = job.type
		var v = job.value
		if job.track < 0:
			var idx := next_idx
			next_idx += 1
			ur.add_do_method(anim, "add_track", type)
			ur.add_do_method(anim, "track_set_path", idx, job.path)
			if type == Animation.TYPE_VALUE:
				ur.add_do_method(anim, "value_track_set_update_mode", idx, _update_mode_for(v))
			_add_insert_do(ur, anim, idx, type, t, v)
			ur.add_undo_method(anim, "remove_track", idx)
			continue
		var i: int = job.track
		# This track's own key within half a frame of the playhead (each
		# track separately: one track's key time must never decide another's).
		var k := _near_key(anim, i, t)
		if k >= 0:
			if type != Animation.TYPE_BEZIER:
				# Leftover duplicates of it within half a frame go (they made
				# playback jump between two poses on the same frame).
				var kt := anim.track_get_key_time(i, k)
				var dups: Array = []
				for j in anim.track_get_key_count(i):
					if j != k and absf(anim.track_get_key_time(i, j) - kt) < _half_frame(anim):
						dups.append([anim.track_get_key_time(i, j), anim.track_get_key_value(i, j), anim.track_get_key_transition(i, j)])
				ur.add_do_method(anim, "track_set_key_value", i, k, v)
				for d in dups:
					ur.add_do_method(anim, "track_remove_key_at_time", i, d[0])
					ur.add_undo_method(anim, "track_insert_key", i, d[0], d[1], d[2])
				# Undo runs backwards: the value is restored first, while the
				# duplicates are still gone, so use the key's index without them.
				var k_after := k
				for d in dups:
					if d[0] < kt:
						k_after -= 1
				ur.add_undo_method(anim, "track_set_key_value", i, k_after, anim.track_get_key_value(i, k))
				continue
			if type == Animation.TYPE_BEZIER:
				ur.add_do_method(anim, "bezier_track_set_key_value", i, k, v)
				ur.add_undo_method(anim, "bezier_track_set_key_value", i, k, anim.bezier_track_get_key_value(i, k))
			else:
				ur.add_do_method(anim, "track_set_key_value", i, k, v)
				ur.add_undo_method(anim, "track_set_key_value", i, k, anim.track_get_key_value(i, k))
		else:
			_add_insert_do(ur, anim, i, type, t, v)
			ur.add_undo_method(anim, "track_remove_key_at_time", i, t)
	ur.commit_action()
	_committing = false
	_auto_version = _auto_history.get_version() if is_instance_valid(_auto_history) else -1

	_pending_edits.clear()
	_toast("Keyed %d track(s) at %.3f s" % [jobs.size(), t], 0)


func _jobs_for_edit(anim: Animation, root: Node, node: Node, prop: String, jobs: Array, used: Dictionary) -> void:
	var np := root.get_path_to(node)
	var value = node.get(prop)
	if value == null:
		return
	var value_path := NodePath(str(np) + ":" + prop)

	# Existing value/bezier track on this exact property.
	for type in [Animation.TYPE_VALUE, Animation.TYPE_BEZIER]:
		var i := anim.find_track(value_path, type)
		if i >= 0 and not anim.track_is_compressed(i):
			if not used.has(i):
				used[i] = true
				var v = value if type == Animation.TYPE_VALUE else _read_track_value(anim, i, root)
				if v != null:
					jobs.append({"track": i, "type": type, "value": v})
			return

	# Existing 3D transform tracks on the node.
	var types3d: Array = []
	if node is Node3D:
		match prop:
			"position":
				types3d = [Animation.TYPE_POSITION_3D]
			"rotation", "rotation_degrees", "quaternion", "basis":
				types3d = [Animation.TYPE_ROTATION_3D]
			"scale":
				types3d = [Animation.TYPE_SCALE_3D]
			"transform", "global_transform", "global_position", "global_rotation":
				types3d = [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D]
	var found := false
	for type in types3d:
		var i := anim.find_track(np, type)
		if i >= 0 and not anim.track_is_compressed(i):
			found = true
			if not used.has(i):
				used[i] = true
				var v = _read_track_value(anim, i, root)
				if v != null:
					jobs.append({"track": i, "type": type, "value": v})
	if found:
		return

	# No track yet: create one.
	var key := "new:" + str(value_path)
	if used.has(key):
		return
	used[key] = true
	if node is Node3D and prop == "position":
		jobs.append({"track": -1, "type": Animation.TYPE_POSITION_3D, "path": np, "value": node.position})
	elif node is Node3D and prop == "quaternion":
		jobs.append({"track": -1, "type": Animation.TYPE_ROTATION_3D, "path": np, "value": node.quaternion})
	elif node is Node3D and prop == "scale":
		jobs.append({"track": -1, "type": Animation.TYPE_SCALE_3D, "path": np, "value": node.scale})
	else:
		jobs.append({"track": -1, "type": Animation.TYPE_VALUE, "path": value_path, "value": value})


func _add_insert_do(ur: EditorUndoRedoManager, anim: Animation, i: int, type: int, t: float, v) -> void:
	match type:
		Animation.TYPE_POSITION_3D:
			ur.add_do_method(anim, "position_track_insert_key", i, t, v)
		Animation.TYPE_ROTATION_3D:
			ur.add_do_method(anim, "rotation_track_insert_key", i, t, v)
		Animation.TYPE_SCALE_3D:
			ur.add_do_method(anim, "scale_track_insert_key", i, t, v)
		Animation.TYPE_BLEND_SHAPE:
			ur.add_do_method(anim, "blend_shape_track_insert_key", i, t, v)
		Animation.TYPE_BEZIER:
			ur.add_do_method(anim, "bezier_track_insert_key", i, t, float(v), Vector2(-0.1, 0.0), Vector2(0.1, 0.0))
		_:
			ur.add_do_method(anim, "track_insert_key", i, t, v, 1.0)


static func _update_mode_for(v) -> int:
	match typeof(v):
		TYPE_BOOL, TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH, TYPE_OBJECT, TYPE_INT, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return Animation.UPDATE_DISCRETE
	return Animation.UPDATE_CONTINUOUS


static func _track_node(anim: Animation, i: int, root: Node) -> Node:
	var path := anim.track_get_path(i)
	var names := str(path.get_concatenated_names())
	if names == "":
		names = "."
	return root.get_node_or_null(NodePath(names))


static func _read_track_value(anim: Animation, i: int, root: Node):
	var node := _track_node(anim, i, root)
	if node == null:
		return null
	var sub := str(anim.track_get_path(i).get_concatenated_subnames())
	match anim.track_get_type(i):
		Animation.TYPE_VALUE, Animation.TYPE_BEZIER:
			if sub == "":
				return null
			return node.get_indexed(NodePath(":" + sub))
		Animation.TYPE_POSITION_3D:
			if node is Skeleton3D and sub != "":
				var b: int = node.find_bone(sub)
				return node.get_bone_pose_position(b) if b >= 0 else null
			return node.position if node is Node3D else null
		Animation.TYPE_ROTATION_3D:
			if node is Skeleton3D and sub != "":
				var b: int = node.find_bone(sub)
				return node.get_bone_pose_rotation(b) if b >= 0 else null
			return node.quaternion if node is Node3D else null
		Animation.TYPE_SCALE_3D:
			if node is Skeleton3D and sub != "":
				var b: int = node.find_bone(sub)
				return node.get_bone_pose_scale(b) if b >= 0 else null
			return node.scale if node is Node3D else null
		Animation.TYPE_BLEND_SHAPE:
			if node is MeshInstance3D:
				var b: int = node.find_blend_shape_by_name(sub)
				return node.get_blend_shape_value(b) if b >= 0 else null
	return null


static func _interpolate(anim: Animation, i: int, t: float):
	match anim.track_get_type(i):
		Animation.TYPE_VALUE:
			return anim.value_track_interpolate(i, t)
		Animation.TYPE_POSITION_3D:
			return anim.position_track_interpolate(i, t)
		Animation.TYPE_ROTATION_3D:
			return anim.rotation_track_interpolate(i, t)
		Animation.TYPE_SCALE_3D:
			return anim.scale_track_interpolate(i, t)
		Animation.TYPE_BLEND_SHAPE:
			return anim.blend_shape_track_interpolate(i, t)
		Animation.TYPE_BEZIER:
			return anim.bezier_track_interpolate(i, t)
	return null


static func _values_equal(a, b) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
		return absf(float(a) - float(b)) < EPS
	if ta != tb:
		return false
	match ta:
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4:
			return (a - b).length() < EPS
		TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I:
			return a == b
		TYPE_QUATERNION:
			return absf(a.normalized().dot(b.normalized())) > 1.0 - 1e-6
		TYPE_COLOR:
			return Vector4(a.r - b.r, a.g - b.g, a.b - b.b, a.a - b.a).length() < EPS
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_RECT2, TYPE_AABB, TYPE_PLANE:
			return a.is_equal_approx(b)
	return a == b


# ---------------------------------------------------------------------------
# Auto Key
# ---------------------------------------------------------------------------

## Every frame: keep the button in the Animation panel, follow the edited
## scene's undo history, and key after a new change.
func _auto_key_tick() -> void:
	if not _nodes_ok():
		return
	if not is_instance_valid(_auto_btn) or not _auto_btn.is_inside_tree():
		_add_auto_button()
	if not _auto_key:
		return
	var root := EditorInterface.get_edited_scene_root()
	var ur := plugin.get_undo_redo()
	var history: UndoRedo = ur.get_history_undo_redo(ur.get_object_history_id(root)) if root else null
	if history != _auto_history:
		_watch_history(history)
	if _auto_pending:
		_auto_pending = false
		_auto_key_now()


func _watch_history(history: UndoRedo) -> void:
	if is_instance_valid(_auto_history) and _auto_history.version_changed.is_connected(_on_history_version):
		_auto_history.version_changed.disconnect(_on_history_version)
	_auto_history = history
	_auto_version = history.get_version() if history else -1
	if history:
		history.version_changed.connect(_on_history_version)


## A change was committed, undone or redone. Only a new change (the version
## went up and nothing is left to redo) is keyed, on the next frame, once the
## gizmo or Inspector has finished applying it.
func _on_history_version() -> void:
	if not is_instance_valid(_auto_history):
		return
	var v := _auto_history.get_version()
	var fresh := v > _auto_version and not _auto_history.has_redo()
	_auto_version = v
	if fresh and _auto_key and not _committing:
		_auto_pending = true


func _auto_key_now() -> void:
	if not _track_editor.is_visible_in_tree():
		return
	var player := _find_player()
	if player == null or player.is_playing() or not player.has_animation(player.assigned_animation):
		return
	var plan := _build_key_plan(_frame.value, true)
	if plan.has("error"):
		return # nothing animated changed
	plan["auto"] = true
	_commit_key_plan(plan)


func _add_auto_button() -> void:
	if not is_instance_valid(_add_track_hb):
		return
	if is_instance_valid(_auto_btn):
		_auto_btn.queue_free()
	_auto_btn = Button.new()
	_auto_btn.name = "SuperScrubberAutoKey"
	_auto_btn.toggle_mode = true
	_auto_btn.flat = true
	_auto_btn.text = "●"
	_auto_btn.tooltip_text = "Auto Key (SuperScrubber): key every change to an animated property at the playhead, as you make it."
	_auto_btn.add_theme_color_override(&"font_pressed_color", Color(1.0, 0.25, 0.25))
	_auto_btn.add_theme_color_override(&"font_hover_pressed_color", Color(1.0, 0.4, 0.4))
	_auto_key = bool(EditorInterface.get_editor_settings().get_project_metadata("super_scrubber", "auto_key", false))
	_auto_btn.button_pressed = _auto_key
	_auto_btn.toggled.connect(_set_auto_key)
	_add_track_hb.add_child(_auto_btn)
	_add_track_hb.move_child(_auto_btn, 0)


func _set_auto_key(on: bool) -> void:
	_auto_key = on
	_auto_pending = false
	EditorInterface.get_editor_settings().set_project_metadata("super_scrubber", "auto_key", on)
	if is_instance_valid(_auto_btn) and _auto_btn.button_pressed != on:
		_auto_btn.set_pressed_no_signal(on)
	if is_instance_valid(_auto_history):
		_auto_version = _auto_history.get_version()


func _toast(msg: String, severity: int) -> void:
	if not SHOW_NOTIFICATIONS:
		return
	if EditorInterface.has_method(&"get_editor_toaster"):
		var toaster = EditorInterface.get_editor_toaster()
		if toaster:
			toaster.push_toast(msg, severity)
			return
	print(msg)
