@tool
extends ConfirmationDialog
class_name UVAtlasPickerDialog

## Atlas region editor + picker in a popup.
## Choose a region visually, or draw new ones and name them.
## Every edit to the preset goes through UndoRedo when one is provided.

signal region_chosen(region_name: String)

var undo_redo: EditorUndoRedoManager
var history_context: Object

var _preset: UVAtlasPreset
var _picker: UVAtlasPicker
var _list: ItemList
var _name_edit: LineEdit
var _cols: SpinBox
var _rows: SpinBox
var _inset: SpinBox
var _status: Label
var _building := false

func _init() -> void:
    title = "Pick Atlas Region"
    ok_button_text = "Use Selected Region"
    min_size = Vector2i(820, 560)

    var split := HSplitContainer.new()
    split.size_flags_vertical = Control.SIZE_EXPAND_FILL
    add_child(split)

    _picker = UVAtlasPicker.new()
    _picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _picker.region_clicked.connect(_on_picker_clicked)
    _picker.rect_drawn.connect(_on_rect_drawn)
    split.add_child(_picker)

    var side := VBoxContainer.new()
    side.custom_minimum_size = Vector2(250, 0)
    split.add_child(side)

    var l1 := Label.new()
    l1.text = "Regions"
    side.add_child(l1)

    _list = ItemList.new()
    _list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _list.item_selected.connect(_on_list_selected)
    _list.item_activated.connect(_on_list_activated)
    side.add_child(_list)

    _name_edit = LineEdit.new()
    _name_edit.placeholder_text = "Region name"
    side.add_child(_name_edit)

    var row1 := HBoxContainer.new()
    side.add_child(row1)
    row1.add_child(_button("Rename", _on_rename))
    row1.add_child(_button("Delete", _on_delete))

    var hint := Label.new()
    hint.text = "Drag on the texture to draw a rectangle, then:"
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    side.add_child(hint)
    side.add_child(_button("Add Region From Drawn Rect", _on_add_drawn))

    var gl := Label.new()
    gl.text = "Grid (replaces all regions)"
    side.add_child(gl)
    var grid := HBoxContainer.new()
    side.add_child(grid)
    _cols = _spin(1, 64, 4)
    _rows = _spin(1, 64, 4)
    var times := Label.new()
    times.text = "x"
    grid.add_child(_cols)
    grid.add_child(times)
    grid.add_child(_rows)
    grid.add_child(_button("Generate", _on_generate_grid))

    var il := Label.new()
    il.text = "Inset (avoids bleeding)"
    side.add_child(il)
    _inset = SpinBox.new()
    _inset.min_value = 0.0
    _inset.max_value = 0.05
    _inset.step = 0.0001
    _inset.value_changed.connect(_on_inset_changed)
    side.add_child(_inset)

    var snap := CheckBox.new()
    snap.text = "Snap to texture pixels"
    snap.button_pressed = true
    snap.toggled.connect(_on_snap_toggled)
    side.add_child(snap)

    _status = Label.new()
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    side.add_child(_status)

## island_rect: pass Rect2() and has_island=false for none.
func open_for(preset: UVAtlasPreset, texture: Texture2D, island_rect: Rect2, has_island: bool, current_region: String = "") -> void:
    _preset = preset
    _picker.preset = preset
    _picker.texture = texture if texture != null else preset.reference_texture
    if has_island:
        _picker.set_island_rect(island_rect)
    else:
        _picker.clear_island_rect()
    _picker.selected_region = current_region
    _picker.reset_view()
    _rebuild_list()
    _building = true
    _inset.value = preset.inset
    _building = false
    _status.text = ""
    popup_centered()

func get_selected_region() -> String:
    return _picker.selected_region

# ------------------------------------------------------------------ actions

func _on_picker_clicked(region_name: String) -> void:
    _select_in_list(region_name)
    _name_edit.text = region_name

func _on_list_selected(index: int) -> void:
    var n := _list.get_item_text(index)
    _picker.selected_region = n
    _name_edit.text = n

func _on_list_activated(_index: int) -> void:
    _on_confirmed()
    hide()

func _on_rect_drawn(rect: Rect2) -> void:
    _status.text = "Drawn: %s  (%.4f, %.4f, %.4f, %.4f)" % [
        _pixel_text(rect), rect.position.x, rect.position.y, rect.size.x, rect.size.y]

func _on_add_drawn() -> void:
    var r := _picker.get_last_drawn_rect()
    if r.size.x <= 0.0 or r.size.y <= 0.0:
        _status.text = "Draw a rectangle on the texture first."
        return
    var n := _name_edit.text.strip_edges()
    var created := [""]   # array: lambdas capture plain variables by value
    _commit("Add atlas region", func():
        created[0] = _preset.add_region(n if not n.is_empty() else "region", r).region_name)
    _rebuild_list()
    _picker.selected_region = created[0]
    _select_in_list(created[0])
    _name_edit.text = created[0]

func _on_rename() -> void:
    var old := _picker.selected_region
    var n := _name_edit.text.strip_edges()
    if old.is_empty() or n.is_empty() or n == old:
        return
    if _preset.has_region(n):
        _status.text = "A region named '%s' already exists." % n
        return
    _commit("Rename atlas region", func(): _preset.rename_region(old, n))
    _picker.selected_region = n
    _rebuild_list()
    _select_in_list(n)

func _on_delete() -> void:
    var old := _picker.selected_region
    if old.is_empty():
        return
    _commit("Delete atlas region", func(): _preset.remove_region(old))
    _picker.selected_region = ""
    _rebuild_list()

func _on_generate_grid() -> void:
    _commit("Generate atlas grid", func(): _preset.generate_grid(int(_cols.value), int(_rows.value)))
    _picker.selected_region = ""
    _rebuild_list()

func _on_snap_toggled(on: bool) -> void:
    _picker.snap_to_pixels = on

func _on_inset_changed(value: float) -> void:
    if _building or _preset == null:
        return
    _commit("Change atlas inset", func(): _preset.inset = value)

# ------------------------------------------------------------------ helpers

func _commit(label: String, mutate: Callable) -> void:
    var before := _preset.snapshot()
    mutate.call()
    var after := _preset.snapshot()
    if undo_redo != null:
        undo_redo.create_action(label, UndoRedo.MERGE_DISABLE, history_context if history_context != null else _preset)
        undo_redo.force_fixed_history()
        undo_redo.add_do_method(_preset, "restore", after)
        undo_redo.force_fixed_history()
        undo_redo.add_undo_method(_preset, "restore", before)
        undo_redo.commit_action(false)   # already applied above
    _picker.queue_redraw()

func _rebuild_list() -> void:
    _list.clear()
    if _preset == null:
        return
    for n in _preset.get_region_names():
        _list.add_item(n)
    _select_in_list(_picker.selected_region)

func _select_in_list(region_name: String) -> void:
    for i in _list.item_count:
        if _list.get_item_text(i) == region_name:
            _list.select(i)
            _list.ensure_current_is_visible()
            return

func _pixel_text(rect: Rect2) -> String:
    if _picker.texture == null:
        return ""
    var s := _picker.texture.get_size()
    return "%d,%d  %dx%d px" % [roundi(rect.position.x * s.x), roundi(rect.position.y * s.y), roundi(rect.size.x * s.x), roundi(rect.size.y * s.y)]

func _button(text: String, cb: Callable) -> Button:
    var b := Button.new()
    b.text = text
    b.pressed.connect(cb)
    return b

func _spin(lo: int, hi: int, value: int) -> SpinBox:
    var s := SpinBox.new()
    s.min_value = lo
    s.max_value = hi
    s.step = 1
    s.value = value
    return s

func _ready() -> void:
    confirmed.connect(_on_confirmed)

func _on_confirmed() -> void:
    var n := _picker.selected_region
    if not n.is_empty():
        region_chosen.emit(n)
