@tool
extends VBoxContainer

## Dock UI. Tabs: Setup (v0.5/0.6) | Atlas (v0.7/0.8) | Animate (v0.9) | Check (v1.0)
## Every scene-changing action goes through EditorUndoRedoManager.

const VERSION := "1.0.0"

var undo_redo: EditorUndoRedoManager
var picker_dialog: UVAtlasPickerDialog

var _detected: Array[UVIsland] = []
var _status: Label
var _uv_option: OptionButton
var _overwrite_check: CheckBox
var _save_mesh_check: CheckBox
var _save_dir_edit: LineEdit
var _island_list: ItemList
var _atlas_picker: EditorResourcePicker
var _grid_cols: SpinBox
var _grid_rows: SpinBox
var _player_option: OptionButton
var _players: Array[AnimationPlayer] = []
var _anim_name: LineEdit
var _anim_length: SpinBox
var _anim_loop: CheckBox
var _template_option: OptionButton
var _amount: SpinBox
var _dir_x: SpinBox
var _dir_y: SpinBox
var _fps: SpinBox
var _regions_edit: LineEdit
var _report: RichTextLabel
var _syncing := false

func _init() -> void:
    name = "UV Island Animator"

func _ready() -> void:
    var title := Label.new()
    title.text = "UV Island Animator %s" % VERSION
    title.add_theme_font_size_override("font_size", 16)
    add_child(title)

    _status = Label.new()
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    add_child(_status)

    var tabs := TabContainer.new()
    tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
    tabs.custom_minimum_size = Vector2(280, 460)
    add_child(tabs)
    tabs.add_child(_build_setup_tab())
    tabs.add_child(_build_atlas_tab())
    tabs.add_child(_build_animate_tab())
    tabs.add_child(_build_check_tab())

    EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
    _on_selection_changed()

# ================================================================ UI build

func _tab(tab_name: String) -> VBoxContainer:
    var v := VBoxContainer.new()
    v.name = tab_name
    return v

func _btn(text: String, cb: Callable, tip: String = "") -> Button:
    var b := Button.new()
    b.text = text
    b.tooltip_text = tip
    b.pressed.connect(cb)
    return b

func _label(text: String) -> Label:
    var l := Label.new()
    l.text = text
    l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    return l

func _spin(lo: float, hi: float, step: float, value: float) -> SpinBox:
    var s := SpinBox.new()
    s.min_value = lo
    s.max_value = hi
    s.step = step
    s.value = value
    s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    return s

func _build_setup_tab() -> Control:
    var t := _tab("Setup")
    var row := HBoxContainer.new()
    row.add_child(_label("UV channel"))
    _uv_option = OptionButton.new()
    _uv_option.add_item("UV0 (main)", 0)
    _uv_option.add_item("UV1 (second)", 1)
    row.add_child(_uv_option)
    t.add_child(row)

    t.add_child(_btn("1. Detect UV Islands", _detect, "Select a MeshInstance3D first."))

    _overwrite_check = CheckBox.new()
    _overwrite_check.text = "Overwrite existing CUSTOM0"
    t.add_child(_overwrite_check)
    _save_mesh_check = CheckBox.new()
    _save_mesh_check.text = "Save baked mesh as .res (recommended for imported models)"
    _save_mesh_check.button_pressed = true
    t.add_child(_save_mesh_check)
    _save_dir_edit = LineEdit.new()
    _save_dir_edit.text = "res://uv_island_baked/"
    t.add_child(_save_dir_edit)
    t.add_child(_btn("2. Bake Island IDs (CUSTOM0)", _bake, "Writes island IDs to CUSTOM0. Splits vertices shared between islands. Undoable."))
    t.add_child(_btn("3. Set Up Animator + Tracks", _setup_animator, "Creates/updates the UVIslandAnimator sibling and one track per island. Undoable."))
    t.add_child(_btn("4. Install Materials (keep my material)", _install_materials, "Patches a COPY of each surface's current material; your textures and settings are kept."))
    var r := HBoxContainer.new()
    r.add_child(_btn("Refresh Materials", _refresh_materials, "Rebuild after you edit the original material."))
    r.add_child(_btn("Restore Originals", _restore_materials))
    t.add_child(r)

    _island_list = ItemList.new()
    _island_list.custom_minimum_size = Vector2(240, 160)
    _island_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _island_list.item_selected.connect(_on_island_selected)
    t.add_child(_island_list)
    return t

func _build_atlas_tab() -> Control:
    var t := _tab("Atlas")
    t.add_child(_label("Shared atlas for this animator (a .tres you can reuse across characters):"))
    _atlas_picker = EditorResourcePicker.new()
    _atlas_picker.base_type = "UVAtlasPreset"
    _atlas_picker.editable = true
    _atlas_picker.resource_changed.connect(_on_atlas_resource_changed)
    t.add_child(_atlas_picker)
    t.add_child(_btn("Open Visual Picker for Selected Island", _open_picker,
        "Click a region to assign it to the island selected in the Setup tab."))
    t.add_child(_label("Quick grid (replaces regions in the shared atlas):"))
    var g := HBoxContainer.new()
    _grid_cols = _spin(1, 64, 1, 4)
    _grid_rows = _spin(1, 64, 1, 4)
    g.add_child(_grid_cols)
    g.add_child(_label("x"))
    g.add_child(_grid_rows)
    g.add_child(_btn("Generate", _generate_grid))
    t.add_child(g)
    t.add_child(_label("Tip: save the atlas (picker drop-down > Save) and reuse it for every mesh with the same texture layout."))
    return t

func _build_animate_tab() -> Control:
    var t := _tab("Animate")
    var pr := HBoxContainer.new()
    _player_option = OptionButton.new()
    _player_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    pr.add_child(_player_option)
    pr.add_child(_btn("Rescan", _refresh_players))
    t.add_child(pr)

    _anim_name = LineEdit.new()
    _anim_name.text = "uv_anim"
    _anim_name.placeholder_text = "Animation name (created if missing)"
    t.add_child(_anim_name)
    var lr := HBoxContainer.new()
    lr.add_child(_label("Length"))
    _anim_length = _spin(0.05, 600.0, 0.05, 1.0)
    lr.add_child(_anim_length)
    _anim_loop = CheckBox.new()
    _anim_loop.text = "Loop"
    _anim_loop.button_pressed = true
    lr.add_child(_anim_loop)
    t.add_child(lr)

    _template_option = OptionButton.new()
    for i in UVIslandKeyBuilder.TEMPLATE_NAMES.size():
        _template_option.add_item(UVIslandKeyBuilder.TEMPLATE_NAMES[i], i)
    t.add_child(_template_option)

    var ar := HBoxContainer.new()
    ar.add_child(_label("Amount"))
    _amount = _spin(-100.0, 100.0, 0.01, 1.0)
    ar.add_child(_amount)
    t.add_child(ar)
    var dr := HBoxContainer.new()
    dr.add_child(_label("Dir"))
    _dir_x = _spin(-10.0, 10.0, 0.01, 1.0)
    _dir_y = _spin(-10.0, 10.0, 0.01, 0.0)
    dr.add_child(_dir_x)
    dr.add_child(_dir_y)
    t.add_child(dr)
    var fr := HBoxContainer.new()
    fr.add_child(_label("FPS"))
    _fps = _spin(0.1, 120.0, 0.1, 12.0)
    fr.add_child(_fps)
    t.add_child(fr)
    _regions_edit = LineEdit.new()
    _regions_edit.placeholder_text = "Flipbook regions: a,b,c (empty = all)"
    t.add_child(_regions_edit)

    t.add_child(_btn("Create Keys for Selected Island", _create_keys,
        "Scroll/Pulse/Rotate/Flipbook use Amount, Dir, FPS. Undoable."))
    t.add_child(_btn("Key Current Values at Playhead", _key_snapshot,
        "Pose the track in the Inspector, move the animation playhead, click."))
    t.add_child(_label("Scroll: offset moves by Dir x Amount over Length. Pulse: scale x Amount and back. Rotate: 360 degrees (sign of Amount)."))
    return t

func _build_check_tab() -> Control:
    var t := _tab("Check")
    t.add_child(_btn("Validate Setup", _validate))
    _report = RichTextLabel.new()
    _report.bbcode_enabled = true
    _report.fit_content = false
    _report.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _report.custom_minimum_size = Vector2(240, 300)
    t.add_child(_report)
    return t

# ============================================================ selection

func _selected_nodes() -> Array[Node]:
    return EditorInterface.get_selection().get_selected_nodes()

func _selected_mesh() -> MeshInstance3D:
    for n in _selected_nodes():
        if n is MeshInstance3D:
            return n
        if n is UVIslandAnimator:
            return (n as UVIslandAnimator).get_mesh_instance()
        if n is UVIslandTrack and n.get_parent() is UVIslandAnimator:
            return (n.get_parent() as UVIslandAnimator).get_mesh_instance()
    return null

func _current_animator() -> UVIslandAnimator:
    for n in _selected_nodes():
        if n is UVIslandAnimator:
            return n
        if n is UVIslandTrack and n.get_parent() is UVIslandAnimator:
            return n.get_parent()
    var mi := _selected_mesh()
    if mi != null and mi.get_parent() != null:
        for c in mi.get_parent().get_children():
            if c is UVIslandAnimator and (c as UVIslandAnimator).get_mesh_instance() == mi:
                return c
    return null

func _islands() -> Array[UVIsland]:
    if not _detected.is_empty():
        return _detected
    var a := _current_animator()
    return a.islands if a != null else _detected

func _selected_island() -> UVIsland:
    var sel := _island_list.get_selected_items()
    var list := _islands()
    if sel.is_empty() or sel[0] >= list.size():
        return null
    return list[sel[0]]

func _on_selection_changed() -> void:
    var a := _current_animator()
    var mi := _selected_mesh()
    if mi == null:
        _status.text = "Select a MeshInstance3D (or its UVIslandAnimator)."
    else:
        var baked := UVIslandMeshBaker.is_baked(mi.mesh)
        var parts := PackedStringArray()
        parts.append("Mesh: %s" % mi.name)
        parts.append("baked: %s" % ("yes" if baked else "no"))
        if a != null:
            parts.append("islands: %d" % a.islands.size())
            parts.append("tracks: %d" % a.get_tracks().size())
        _status.text = "  |  ".join(parts)
    _syncing = true
    if _atlas_picker != null:
        _atlas_picker.edited_resource = a.atlas if a != null else null
    _syncing = false
    if _island_list != null and _detected.is_empty():
        _fill_island_list()
    if _player_option != null and _player_option.item_count == 0:
        _refresh_players()

func _fill_island_list() -> void:
    _island_list.clear()
    for island in _islands():
        _island_list.add_item("%s | surf %d | %d tris | %s -> %s" % [
            island.name, island.surface, island.triangle_count,
            _fmt(island.uv_min), _fmt(island.uv_max)])

func _fmt(v: Vector2) -> String:
    return "(%.2f, %.2f)" % [v.x, v.y]

func _on_island_selected(_i: int) -> void:
    pass

func _say(text: String) -> void:
    _status.text = text

# ================================================================ undo helpers

func _root() -> Node:
    return EditorInterface.get_edited_scene_root()

func _begin(label: String) -> void:
    undo_redo.create_action(label, UndoRedo.MERGE_DISABLE, _root())

func _do_m(obj: Object, method: String, args: Array = []) -> void:
    undo_redo.force_fixed_history()
    undo_redo.callv("add_do_method", [obj, method] + args)

func _undo_m(obj: Object, method: String, args: Array = []) -> void:
    undo_redo.force_fixed_history()
    undo_redo.callv("add_undo_method", [obj, method] + args)

func _do_p(obj: Object, prop: String, value: Variant) -> void:
    undo_redo.force_fixed_history()
    undo_redo.add_do_property(obj, prop, value)

func _undo_p(obj: Object, prop: String, value: Variant) -> void:
    undo_redo.force_fixed_history()
    undo_redo.add_undo_property(obj, prop, value)

# ================================================================ SETUP actions

func _detect() -> void:
    var mi := _selected_mesh()
    if mi == null or mi.mesh == null:
        _say("Select a MeshInstance3D with a mesh first.")
        return
    var start := Time.get_ticks_msec()
    var res := UVIslandDetector.detect_with_report(mi.mesh, _uv_option.get_selected_id())
    _detected = res["islands"]
    _fill_island_list()
    var msg := "Detected %d UV islands in %d ms." % [_detected.size(), Time.get_ticks_msec() - start]
    if _detected.size() > UVIslandMaterialBuilder.MAX_ISLANDS:
        msg += " WARNING: more than %d islands; not supported." % UVIslandMaterialBuilder.MAX_ISLANDS
    if res["warnings"].size() > 0:
        msg += " " + " ".join(res["warnings"])
    _say(msg)

func _bake() -> void:
    var mi := _selected_mesh()
    if mi == null or mi.mesh == null:
        _say("Select a MeshInstance3D with a mesh first.")
        return
    if _detected.is_empty():
        _detect()
    if _detected.is_empty():
        return
    var res := UVIslandMeshBaker.bake(mi.mesh, _detected, _uv_option.get_selected_id(), _overwrite_check.button_pressed)
    var errors: PackedStringArray = res["errors"]
    if res["mesh"] == null:
        _say("Bake failed: " + (errors[0] if errors.size() > 0 else "unknown error"))
        return
    var baked: ArrayMesh = res["mesh"]
    var saved := ""
    if _save_mesh_check.button_pressed:
        saved = _save_baked_mesh(baked, mi)

    var old_mesh := mi.mesh
    _begin("Bake UV island IDs")
    _do_p(mi, "mesh", baked)
    _undo_p(mi, "mesh", old_mesh)
    undo_redo.add_do_reference(baked)
    undo_redo.commit_action()

    var msg := "Baked island IDs into CUSTOM0."
    if res["split_vertices"] > 0:
        msg += " Split %d shared vertices." % res["split_vertices"]
    if not saved.is_empty():
        msg += " Saved to %s." % saved
    _say(msg)

func _save_baked_mesh(baked: ArrayMesh, mi: MeshInstance3D) -> String:
    var dir := _save_dir_edit.text.strip_edges()
    if not dir.ends_with("/"):
        dir += "/"
    var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
    if err != OK and err != ERR_ALREADY_EXISTS:
        push_warning("UV Island Animator: could not create %s (error %d); mesh kept embedded." % [dir, err])
        return ""
    var scene := _root()
    var base := "%s_%s" % [scene.name if scene != null else "scene", mi.name]
    var path := "%s%s.res" % [dir, base.validate_filename()]
    err = ResourceSaver.save(baked, path)
    if err != OK:
        push_warning("UV Island Animator: saving %s failed (error %d); mesh kept embedded." % [path, err])
        return ""
    baked.take_over_path(path)
    EditorInterface.get_resource_filesystem().update_file(path)
    return path

func _setup_animator() -> void:
    var mi := _selected_mesh()
    if mi == null:
        _say("Select a MeshInstance3D first.")
        return
    if _detected.is_empty() and _current_animator() != null:
        _detected = _current_animator().islands.duplicate()
    if _detected.is_empty():
        _detect()
    if _detected.is_empty():
        return
    var root := _root()
    var parent := mi.get_parent()
    if root == null or parent == null:
        _say("The mesh must be inside an open scene.")
        return

    var animator := _current_animator()
    var created := animator == null
    _begin("Set up UV Island Animator")
    if created:
        animator = UVIslandAnimator.new()
        animator.name = "UVIslandAnimator"
        _do_m(parent, "add_child", [animator, true])
        _do_p(animator, "owner", root)
        _undo_m(parent, "remove_child", [animator])
        undo_redo.add_do_reference(animator)
    else:
        _undo_p(animator, "uv_channel", animator.uv_channel)
        _undo_p(animator, "islands", animator.islands)
    _do_m(animator, "set_mesh_instance", [mi])
    _do_p(animator, "uv_channel", _uv_option.get_selected_id())
    _do_p(animator, "islands", _detected)

    var new_tracks := animator.make_missing_tracks(_detected)
    for t in new_tracks:
        _do_m(animator, "add_child", [t, true])
        _do_p(t, "owner", root)
        _undo_m(animator, "remove_child", [t])
        undo_redo.add_do_reference(t)
    undo_redo.commit_action()
    _say("Animator ready: %d islands, %d new tracks. Next: Install Materials." % [_detected.size(), new_tracks.size()])
    _on_selection_changed()

func _install_materials() -> void:
    var a := _current_animator()
    if a == null:
        _say("Set up the animator first (step 3).")
        return
    _begin("Install UV island materials")
    _do_m(a, "install_materials")
    _undo_m(a, "restore_materials")
    undo_redo.commit_action()
    _report_warnings(a.last_warnings, "Materials installed.")

func _refresh_materials() -> void:
    var a := _current_animator()
    if a == null:
        return
    _begin("Refresh UV island materials")
    _do_m(a, "refresh_materials")
    _undo_m(a, "restore_materials")
    undo_redo.commit_action()
    _report_warnings(a.last_warnings, "Materials refreshed.")

func _restore_materials() -> void:
    var a := _current_animator()
    if a == null:
        return
    _begin("Restore original materials")
    _do_m(a, "restore_materials")
    _undo_m(a, "install_materials")
    undo_redo.commit_action()
    _say("Original materials restored.")

func _report_warnings(warnings: PackedStringArray, ok_text: String) -> void:
    if warnings.is_empty():
        _say(ok_text)
    else:
        _say(ok_text + " " + " ".join(warnings))

# ================================================================ ATLAS actions

func _ensure_atlas(a: UVIslandAnimator) -> UVAtlasPreset:
    if a.atlas != null:
        return a.atlas
    var p := UVAtlasPreset.new()
    p.preset_name = "Atlas"
    _begin("Create atlas preset")
    _do_p(a, "atlas", p)
    _undo_p(a, "atlas", null)
    undo_redo.add_do_reference(p)
    undo_redo.commit_action()
    _atlas_picker.edited_resource = p
    return p

func _on_atlas_resource_changed(res: Resource) -> void:
    if _syncing:
        return
    var a := _current_animator()
    if a == null:
        return
    _begin("Assign atlas")
    _do_p(a, "atlas", res)
    _undo_p(a, "atlas", a.atlas)
    undo_redo.commit_action()

func _generate_grid() -> void:
    var a := _current_animator()
    if a == null:
        _say("Set up the animator first.")
        return
    var p := _ensure_atlas(a)
    var before := p.snapshot()
    p.generate_grid(int(_grid_cols.value), int(_grid_rows.value))
    var after := p.snapshot()
    _begin("Generate atlas grid")
    _do_m(p, "restore", [after])
    _undo_m(p, "restore", [before])
    undo_redo.commit_action(false)
    _say("Generated %d regions." % p.regions.size())

func _open_picker() -> void:
    var a := _current_animator()
    var island := _selected_island()
    if a == null or island == null:
        _say("Select an island in the Setup tab (and set up the animator) first.")
        return
    var p := _ensure_atlas(a)
    picker_dialog.undo_redo = undo_redo
    picker_dialog.history_context = _root()
    if picker_dialog.region_chosen.is_connected(_on_region_chosen):
        picker_dialog.region_chosen.disconnect(_on_region_chosen)
    picker_dialog.region_chosen.connect(_on_region_chosen)
    var t := a.get_track(island.island_id)
    picker_dialog.open_for(p, a.get_preview_texture(island.surface), island.get_uv_rect(), true, t.atlas_region if t != null else "")

func _on_region_chosen(region_name: String) -> void:
    var a := _current_animator()
    var island := _selected_island()
    if a == null or island == null:
        return
    var t := a.get_track(island.island_id)
    if t == null:
        _say("Island %d has no track yet; run 'Set Up Animator + Tracks'." % island.island_id)
        return
    _begin("Set atlas region")
    _do_p(t, "atlas_region", region_name)
    _do_p(t, "use_atlas", true)
    _undo_p(t, "atlas_region", t.atlas_region)
    _undo_p(t, "use_atlas", t.use_atlas)
    undo_redo.commit_action()
    _say("%s -> region '%s'." % [island.name, region_name])

# ================================================================ ANIMATE actions

func _refresh_players() -> void:
    _player_option.clear()
    _players.clear()
    var root := _root()
    if root == null:
        return
    var found: Array[Node] = root.find_children("*", "AnimationPlayer", true, false)
    if root is AnimationPlayer:
        found.append(root)
    for n in found:
        _players.append(n as AnimationPlayer)
        _player_option.add_item(str(root.get_path_to(n)) if n != root else str(root.name))

func _current_player() -> AnimationPlayer:
    if _players.is_empty():
        _refresh_players()
    var i := _player_option.selected
    return _players[i] if i >= 0 and i < _players.size() else null

func _gather_context(need_track: bool) -> Dictionary:
    var a := _current_animator()
    var island := _selected_island()
    var player := _current_player()
    if a == null or island == null:
        _say("Select an island in the Setup tab first.")
        return {}
    var track := a.get_track(island.island_id)
    if track == null:
        _say("Island %d has no track. Run 'Set Up Animator + Tracks'." % island.island_id)
        return {}
    if player == null:
        _say("No AnimationPlayer found in the scene. Add one and press Rescan.")
        return {}
    if _anim_name.text.strip_edges().is_empty():
        _say("Enter an animation name.")
        return {}
    return {"animator": a, "island": island, "track": track, "player": player}

func _params() -> Dictionary:
    var regions := PackedStringArray()
    for r in _regions_edit.text.split(",", false):
        regions.append(r.strip_edges())
    return {
        "length": _anim_length.value,
        "amount": _amount.value,
        "direction": Vector2(_dir_x.value, _dir_y.value),
        "fps": _fps.value,
        "regions": regions,
    }

func _create_keys() -> void:
    var ctx := _gather_context(true)
    if ctx.is_empty():
        return
    var template := _template_option.get_selected_id()
    if template == UVIslandKeyBuilder.Template.SNAPSHOT:
        _key_snapshot()
        return
    _write_plan(ctx, template, _params())

func _key_snapshot() -> void:
    var ctx := _gather_context(true)
    if ctx.is_empty():
        return
    var player: AnimationPlayer = ctx["player"]
    var anim_name := _anim_name.text.strip_edges()
    var params := _params()
    var time := 0.0
    if player.assigned_animation == anim_name or player.current_animation == anim_name:
        time = player.current_animation_position
    params["time"] = time
    _write_plan(ctx, UVIslandKeyBuilder.Template.SNAPSHOT, params)

func _write_plan(ctx: Dictionary, template: int, params: Dictionary) -> void:
    var player: AnimationPlayer = ctx["player"]
    var track: UVIslandTrack = ctx["track"]
    var plan := UVIslandKeyBuilder.build_plan(template, player, track, params)
    if plan.is_empty():
        _say("Nothing to key. (Flipbook needs an atlas with regions and an atlas assigned.)")
        return
    var anim_name := _anim_name.text.strip_edges()
    var ensured := UVIslandKeyBuilder.ensure_animation(player, anim_name)
    var anim: Animation = ensured["animation"]
    var created: bool = ensured["created"]
    var lib: AnimationLibrary = ensured["library"]

    var action := {
        "anim": anim, "lib": lib, "name": anim_name, "created": created, "plan": plan,
        "old_length": anim.length, "old_loop": anim.loop_mode,
        "new_length": maxf(anim.length if not created else 0.0, maxf(UVIslandKeyBuilder.plan_length(plan, template, _fps.value), 0.05)),
        "new_loop": Animation.LOOP_LINEAR if _anim_loop.button_pressed else Animation.LOOP_NONE,
    }
    if template == UVIslandKeyBuilder.Template.SNAPSHOT and not created:
        action["new_loop"] = anim.loop_mode
    _begin("Add UV island keys")
    _do_m(self, "_do_keys", [action])
    _undo_m(self, "_undo_keys", [action])
    undo_redo.commit_action()
    _say("Added %d keys to '%s' for %s." % [plan.size(), anim_name, track.name])

# Called by UndoRedo (do / redo)
func _do_keys(action: Dictionary) -> void:
    var anim: Animation = action["anim"]
    var lib: AnimationLibrary = action["lib"]
    if action["created"] and not lib.has_animation(action["name"]):
        lib.add_animation(action["name"], anim)
    UVIslandKeyBuilder.apply_plan(anim, action["plan"])
    anim.length = action["new_length"]
    anim.loop_mode = action["new_loop"]

# Called by UndoRedo (undo)
func _undo_keys(action: Dictionary) -> void:
    var anim: Animation = action["anim"]
    var lib: AnimationLibrary = action["lib"]
    UVIslandKeyBuilder.revert_plan(anim, action["plan"])
    anim.length = action["old_length"]
    anim.loop_mode = action["old_loop"]
    if action["created"] and lib.has_animation(action["name"]):
        lib.remove_animation(action["name"])

# ================================================================ CHECK

func _validate() -> void:
    _report.clear()
    var a := _current_animator()
    var results := UVIslandValidator.validate(a)
    var player := _current_player()
    if player != null:
        results.append_array(UVIslandValidator.validate_animation_paths(player))
    var errors := 0
    var warns := 0
    for r in results:
        var color := "#7fd48a"
        match r["level"]:
            "error":
                color = "#ff6b6b"
                errors += 1
            "warning":
                color = "#ffd166"
                warns += 1
            "info":
                color = "#9ab"
        _report.append_text("[color=%s][b]%s[/b][/color] %s\n" % [color, str(r["level"]).to_upper(), r["message"]])
    _say("Validation: %d error(s), %d warning(s)." % [errors, warns])
