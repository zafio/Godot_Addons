@tool
extends EditorPlugin
## Hover Side Panel
## Hover a *selected* node in the Scene dock and an Inspector panel pops up
## to the right of the dock. Move the mouse into the panel to edit properties.
##
## - Panel stays open while the mouse is over it, a field inside it has focus,
##   or the "Pin" button is toggled on.
## - Esc or the close button dismisses it (it won't re-open until you leave the row).

const HOVER_DELAY := 0.0       # seconds hovering a selected node before the panel opens
const HIDE_DELAY := 0.1       # grace period after the mouse leaves before closing
const PANEL_WIDTH := 300.0
const PANEL_MAX_HEIGHT := 700.0
const MARGIN := 6
const SCENE_POPUP_WIDTH := 300.0
const SCENE_POPUP_MAX_HEIGHT := 650
const SCENE_POPUP_GAP := 6.0      # space between the Inspector dock and the popup
const SCENE_POPUP_PADDING := 4.0   # inner padding of the popup
const SCENE_HIDE_DELAY := 0.1  # grace period after the mouse leaves the Scene popup

var _base: Control
var _dock: Control
var _tree: Tree

var _panel: PanelContainer
var _inspector: EditorInspector
var _icon: TextureRect
var _title: Label
var _pin: Button
var _close: Button

# Scene popup (Tab over the Inspector dock)
var _inspector_dock: Control
var _inspector_searched := false
var _scene_popup: PanelContainer
var _scene_filter: LineEdit
var _scene_view: Tree
var _scene_scroll_item: TreeItem
var _scene_syncing := false
var _scene_apply_pending := false
var _scene_leave := 0.0

var _shown_node: Node
var _candidate: Node
var _dismissed: Node
var _hover_time := 0.0
var _leave_time := 0.0
var _retry := 0.0
var _enabled := true  # toggled with Tab while hovering the Scene dock


func _enter_tree() -> void:
	_base = EditorInterface.get_base_control()
	_build_panel()
	_build_scene_popup()
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	set_process(true)
	set_process_input(true)


func _exit_tree() -> void:
	set_process(false)
	set_process_input(false)
	if is_instance_valid(_inspector):
		_inspector.edit(null)
	if is_instance_valid(_panel):
		if _panel.get_parent():
			_panel.get_parent().remove_child(_panel)
		_panel.queue_free()
	var sel := EditorInterface.get_selection()
	if sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.disconnect(_on_selection_changed)
	if is_instance_valid(_scene_popup):
		if _scene_popup.get_parent():
			_scene_popup.get_parent().remove_child(_scene_popup)
		_scene_popup.queue_free()
	_scene_popup = null
	_panel = null
	_tree = null
	_dock = null
	_inspector_dock = null


# ---------------------------------------------------------------- UI

func _build_panel() -> void:
	var s := EditorInterface.get_editor_scale()

	_panel = PanelContainer.new()
	_panel.name = "HoverInspectorPanel"
	_panel.top_level = true
	_panel.visible = false

	_panel.add_theme_stylebox_override("panel", _make_panel_style())

	var vb := VBoxContainer.new()
	_panel.add_child(vb)

	var header := HBoxContainer.new()
	vb.add_child(header)

	_icon = TextureRect.new()
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.custom_minimum_size = Vector2(16, 16) * s
	header.add_child(_icon)

	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.clip_text = true
	header.add_child(_title)

	_pin = Button.new()
	_pin.toggle_mode = true
	_pin.flat = true
	_pin.tooltip_text = "Keep this panel open"
	_set_button_look(_pin, "Pin", "Pin")
	header.add_child(_pin)

	_close = Button.new()
	_close.flat = true
	_close.tooltip_text = "Close (Esc)"
	_set_button_look(_close, "Close", "x")
	_close.pressed.connect(_on_close_pressed)
	header.add_child(_close)

	vb.add_child(HSeparator.new())

	_inspector = EditorInspector.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_inspector.custom_minimum_size = Vector2(0, 200 * s)
	vb.add_child(_inspector)

	_base.add_child(_panel)


func _make_panel_style() -> StyleBoxFlat:
	var s := EditorInterface.get_editor_scale()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _base.get_theme_color("base_color", "Editor")
	sb.border_color = _base.get_theme_color("dark_color_1", "Editor")
	sb.set_border_width_all(maxi(1, int(s)))
	sb.set_corner_radius_all(int(4 * s))
	sb.set_content_margin_all(6 * s)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = int(8 * s)
	return sb


func _build_scene_popup() -> void:
	var s := EditorInterface.get_editor_scale()

	_scene_popup = PanelContainer.new()
	_scene_popup.name = "HoverInspectorScenePopup"
	_scene_popup.top_level = true
	_scene_popup.visible = false
	var style := _make_panel_style()
	style.set_content_margin_all(SCENE_POPUP_PADDING * s)
	_scene_popup.add_theme_stylebox_override("panel", style)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(6 * s))
	_scene_popup.add_child(vb)

	_scene_filter = LineEdit.new()
	_scene_filter.placeholder_text = "Filter nodes"
	_scene_filter.clear_button_enabled = true
	_scene_filter.text_changed.connect(_on_scene_filter_changed)
	vb.add_child(_scene_filter)

	_scene_view = Tree.new()
	_scene_view.select_mode = Tree.SELECT_MULTI
	_scene_view.hide_root = false
	_scene_view.allow_reselect = true
	_scene_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scene_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scene_view.custom_minimum_size = Vector2(0, 200 * s)
	_scene_view.multi_selected.connect(_on_scene_view_multi_selected)
	_scene_view.item_activated.connect(_on_scene_item_activated)
	vb.add_child(_scene_view)

	_base.add_child(_scene_popup)


func _set_button_look(button: Button, icon_name: String, fallback_text: String) -> void:
	if _base.has_theme_icon(icon_name, "EditorIcons"):
		button.icon = _base.get_theme_icon(icon_name, "EditorIcons")
	else:
		button.text = fallback_text


func _on_close_pressed() -> void:
	_dismissed = _shown_node
	_pin.button_pressed = false
	_hide_panel()


# ---------------------------------------------------------------- Scene dock lookup

func _ensure_scene_tree(delta: float) -> bool:
	if is_instance_valid(_tree) and _tree.is_inside_tree():
		return true
	_retry -= delta
	if _retry > 0.0:
		return false
	_retry = 1.0

	_dock = _find_by_class(_base, "SceneTreeDock") as Control
	var search_root: Node = _dock if _dock != null else _base
	var editor := _find_by_class(search_root, "SceneTreeEditor")
	if editor == null:
		return false
	var trees := editor.find_children("*", "Tree", true, false)
	if trees.is_empty():
		return false
	_tree = trees[0] as Tree
	return _tree != null


func _find_by_class(node: Node, cls: String) -> Node:
	if node == _panel or node == _scene_popup:
		return null
	if node.get_class() == cls:
		return node
	for child in node.get_children():
		var found := _find_by_class(child, cls)
		if found != null:
			return found
	return null


# ---------------------------------------------------------------- Hover logic

func _process(delta: float) -> void:
	_update_scene_popup(delta)
	if _panel == null or not _ensure_scene_tree(delta):
		return
	if not _enabled:
		return

	var selected: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	var mouse := _base.get_global_mouse_position()

	# Selection changed / node deleted while the panel was open.
	if _panel.visible and (not is_instance_valid(_shown_node) or not selected.has(_shown_node)):
		_hide_panel()

	var hovered := _hovered_selected_node(selected)

	# After Esc / close, stay closed until the mouse leaves that row.
	if is_instance_valid(_dismissed):
		if hovered == _dismissed:
			hovered = null
		else:
			_dismissed = null

	# Keep the panel alive while it is being used.
	if _panel.visible and (_pin.button_pressed or _mouse_in_panel(mouse) or _panel_has_focus()):
		_leave_time = 0.0
		_candidate = null
		return

	if hovered == null:
		_candidate = null
		_hover_time = 0.0
		if _panel.visible:
			_leave_time += delta
			if _leave_time >= HIDE_DELAY:
				_hide_panel()
		return

	_leave_time = 0.0
	if _panel.visible:
		if hovered != _shown_node:
			_show_for(hovered)  # switch straight to the newly hovered selected node
		return

	if hovered != _candidate:
		_candidate = hovered
		_hover_time = 0.0
	_hover_time += delta
	if _hover_time >= HOVER_DELAY:
		_show_for(hovered)


func _hovered_selected_node(selected: Array[Node]) -> Node:
	if not _tree.is_visible_in_tree():
		return null
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return null  # clicking / dragging nodes in the tree
	var local := _tree.get_local_mouse_position()
	if not Rect2(Vector2.ZERO, _tree.size).has_point(local):
		return null
	var item := _tree.get_item_at_position(local)
	if item == null:
		return null
	var node := _node_from_item(item)
	if node != null and selected.has(node):
		return node
	return null


func _node_from_item(item: TreeItem) -> Node:
	var meta: Variant = item.get_metadata(0)
	if meta is Node:
		return meta
	if meta is NodePath or meta is String:
		var path: NodePath = meta if meta is NodePath else NodePath(String(meta))
		var n: Node = null
		if path.is_absolute():
			n = _base.get_node_or_null(path)
		if n == null:
			var root := EditorInterface.get_edited_scene_root()
			if root != null:
				n = root.get_node_or_null(path)
		return n
	return null


func _mouse_in_panel(mouse: Vector2) -> bool:
	return _panel.get_global_rect().has_point(mouse)


func _panel_has_focus() -> bool:
	var focus := _base.get_viewport().gui_get_focus_owner()
	return focus != null and _panel.is_ancestor_of(focus)


# ---------------------------------------------------------------- Show / hide

func _show_for(node: Node) -> void:
	_shown_node = node
	_candidate = null
	_hover_time = 0.0
	_leave_time = 0.0

	var cls := node.get_class()
	var icon_name := cls if _base.has_theme_icon(cls, "EditorIcons") else "Node"
	_icon.texture = _base.get_theme_icon(icon_name, "EditorIcons")
	_title.text = "%s  (%s)" % [node.name, cls]

	_inspector.edit(node)
	_place_panel()
	_panel.show()


func _place_panel() -> void:
	var s := EditorInterface.get_editor_scale()
	var bounds := _base.size
	var margin := MARGIN * s
	var w := PANEL_WIDTH * s
	var h := minf(PANEL_MAX_HEIGHT * s, bounds.y - margin * 2.0)

	var dock_rect := (_dock if _dock != null else _tree).get_global_rect()
	var x := dock_rect.end.x + 2.0 * s
	if x + w > bounds.x - margin:
		x = dock_rect.position.x - w - 2.0 * s  # no room on the right, flip to the left
	x = clampf(x, margin, maxf(margin, bounds.x - w - margin))

	var mouse_y := _base.get_global_mouse_position().y
	var y := clampf(mouse_y - 40.0 * s, margin, maxf(margin, bounds.y - h - margin))

	_panel.size = Vector2(w, h)
	_panel.global_position = Vector2(x, y)


# ---------------------------------------------------------------- Scene popup (Tab over Inspector)

func _get_inspector_area() -> Control:
	if is_instance_valid(_inspector_dock) and _inspector_dock.is_inside_tree():
		return _inspector_dock
	if not _inspector_searched:
		_inspector_searched = true
		_inspector_dock = _find_by_class(_base, "InspectorDock") as Control
		if _inspector_dock != null:
			return _inspector_dock
	return EditorInterface.get_inspector()


func _mouse_over_inspector_dock() -> bool:
	var area := _get_inspector_area()
	if area == null or not area.is_visible_in_tree():
		return false
	return area.get_global_rect().has_point(_base.get_global_mouse_position())


func _show_scene_popup() -> void:
	_scene_filter.text = ""
	_refresh_scene_popup()
	_place_scene_popup()
	_scene_leave = 0.0
	_scene_popup.show()
	_scene_filter.grab_focus()


func _place_scene_popup() -> void:
	var s := EditorInterface.get_editor_scale()
	var bounds := _base.size
	var margin := MARGIN * s
	var w := SCENE_POPUP_WIDTH * s
	var h := minf(SCENE_POPUP_MAX_HEIGHT * s, bounds.y - margin * 2.0)

	var rect := _get_inspector_area().get_global_rect()
	var gap := SCENE_POPUP_GAP * s
	var x := rect.position.x - w - gap  # prefer the left of the Inspector dock
	if x < margin:
		x = rect.end.x + gap
	x = clampf(x, margin, maxf(margin, bounds.x - w - margin))

	var mouse_y := _base.get_global_mouse_position().y
	var y := clampf(mouse_y - 40.0 * s, margin, maxf(margin, bounds.y - h - margin))

	_scene_popup.size = Vector2(w, h)
	_scene_popup.global_position = Vector2(x, y)


func _hide_scene_popup() -> void:
	if not is_instance_valid(_scene_popup):
		return
	if _scene_popup.visible:
		var focus := _base.get_viewport().gui_get_focus_owner()
		if focus != null and _scene_popup.is_ancestor_of(focus):
			focus.release_focus()
	_scene_popup.hide()
	_scene_leave = 0.0


func _update_scene_popup(delta: float) -> void:
	if _scene_popup == null or not _scene_popup.visible:
		return
	var mouse := _base.get_global_mouse_position()
	var typing := _scene_filter.has_focus() and not _scene_filter.text.is_empty()
	if _scene_popup.get_global_rect().has_point(mouse) or _mouse_over_inspector_dock() or typing:
		_scene_leave = 0.0
		return
	_scene_leave += delta
	if _scene_leave >= SCENE_HIDE_DELAY:
		_hide_scene_popup()


func _icon_for(node: Node) -> Texture2D:
	var cls := node.get_class()
	var icon_name := cls if _base.has_theme_icon(cls, "EditorIcons") else "Node"
	return _base.get_theme_icon(icon_name, "EditorIcons")


func _refresh_scene_popup() -> void:
	_scene_syncing = true
	_scene_scroll_item = null
	_scene_view.clear()
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		var selected: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
		_add_node_item(root, null, root, _scene_filter.text.strip_edges(), selected)
	if _scene_scroll_item != null:
		_scene_view.scroll_to_item(_scene_scroll_item)
	_scene_syncing = false


func _add_node_item(node: Node, parent: TreeItem, root: Node, filter: String, selected: Array[Node]) -> TreeItem:
	var item := _scene_view.create_item(parent)
	item.set_text(0, String(node.name))
	item.set_icon(0, _icon_for(node))
	item.set_metadata(0, node)

	var any_child := false
	for child in node.get_children():
		if child.owner == root:  # same nodes the Scene dock shows
			if _add_node_item(child, item, root, filter, selected) != null:
				any_child = true

	if not filter.is_empty() and not any_child and not String(node.name).containsn(filter):
		item.free()
		return null

	if selected.has(node):
		item.select(0)
		if _scene_scroll_item == null:
			_scene_scroll_item = item
	return item


func _view_selected_nodes() -> Array[Node]:
	var result: Array[Node] = []
	var item := _scene_view.get_next_selected(null)
	while item != null:
		var node: Variant = item.get_metadata(0)
		if is_instance_valid(node) and node is Node:
			result.append(node as Node)
		item = _scene_view.get_next_selected(item)
	return result


func _on_scene_view_multi_selected(_item: TreeItem, _column: int, _selected: bool) -> void:
	if _scene_syncing or _scene_apply_pending:
		return
	_scene_apply_pending = true
	_apply_view_selection.call_deferred()


func _apply_view_selection() -> void:
	_scene_apply_pending = false
	if _scene_syncing or _scene_popup == null or not _scene_popup.visible:
		return
	var nodes := _view_selected_nodes()
	if nodes.is_empty():
		EditorInterface.get_selection().clear()
	elif nodes.size() == 1:
		EditorInterface.edit_node(nodes[0])  # selects it and shows it in the Inspector
	else:
		var sel := EditorInterface.get_selection()
		sel.clear()
		for n in nodes:
			sel.add_node(n)


func _on_selection_changed() -> void:
	if _scene_popup == null or not _scene_popup.visible or _scene_syncing:
		return
	var current: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	var view := _view_selected_nodes()
	if current.size() == view.size():
		var same := true
		for n in current:
			if not view.has(n):
				same = false
				break
		if same:
			return
	_refresh_scene_popup()  # selection changed from outside (viewport, Scene dock...)


func _on_scene_filter_changed(_text: String) -> void:
	_refresh_scene_popup()


func _on_scene_item_activated() -> void:
	_hide_scene_popup()  # double-click / Enter on a node closes the popup


func _toggle_enabled() -> void:
	_enabled = not _enabled
	if not _enabled:
		_pin.button_pressed = false
		_dismissed = null
		_hide_panel()


func _mouse_over_scene_dock() -> bool:
	var area: Control = _dock if is_instance_valid(_dock) else _tree
	if not is_instance_valid(area) or not area.is_visible_in_tree():
		return false
	return area.get_global_rect().has_point(_base.get_global_mouse_position())


func _typing_in_text_field() -> bool:
	var focus := _base.get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


func _hide_panel() -> void:
	if not is_instance_valid(_panel):
		return
	if _panel.visible and _panel_has_focus():
		_base.get_viewport().gui_get_focus_owner().release_focus()
	_panel.hide()
	if is_instance_valid(_inspector):
		_inspector.edit(null)
	_shown_node = null
	_candidate = null
	_hover_time = 0.0
	_leave_time = 0.0


func _input(event: InputEvent) -> void:
	if _panel == null:
		return

	# Tab while hovering the Scene dock toggles the hover panel on/off.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB \
			and not (event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed):
		var mouse := _base.get_global_mouse_position()
		var over_popup := _scene_popup.visible and _scene_popup.get_global_rect().has_point(mouse)
		# Tab over the hover Inspector panel closes it.
		if _panel.visible and _mouse_in_panel(mouse) and not _typing_in_text_field():
			_dismissed = _shown_node
			_pin.button_pressed = false
			_hide_panel()
			_base.get_viewport().set_input_as_handled()
			return
		# Tab over the Inspector dock (or the popup itself) closes an open Scene popup.
		if _scene_popup.visible and (over_popup or _mouse_over_inspector_dock()):
			_hide_scene_popup()
			_base.get_viewport().set_input_as_handled()
			return
		if not _typing_in_text_field():
			# Tab over the Inspector dock opens the Scene popup.
			if _mouse_over_inspector_dock() and not (_panel.visible and _mouse_in_panel(mouse)):
				_show_scene_popup()
				_base.get_viewport().set_input_as_handled()
				return
			# Tab over the Scene dock toggles the hover panel.
			if _mouse_over_scene_dock():
				_toggle_enabled()
				_base.get_viewport().set_input_as_handled()
				return

	if _scene_popup.visible and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		var m := _base.get_global_mouse_position()
		if _scene_popup.get_global_rect().has_point(m) or _mouse_over_inspector_dock() \
				or _scene_filter.has_focus():
			_hide_scene_popup()
			_base.get_viewport().set_input_as_handled()
			return

	if not _panel.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if _panel_has_focus() or _mouse_in_panel(_base.get_global_mouse_position()):
			_dismissed = _shown_node
			_pin.button_pressed = false
			_hide_panel()
			_base.get_viewport().set_input_as_handled()
