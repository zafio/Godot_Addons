@tool
extends EditorPlugin
## View Pie — Blender-style pie menu for Godot's 3D viewport.
##
## Hold Z over a 3D viewport, flick toward an item, release.
## (Tap Z quickly instead and the pie stays open until you click an item.)
## Alt+Z reverts everything the pie changed back to how the editor was.
##
##   N  Overlays               gizmos/grid/origin/info on-off (already-hidden items stay hidden)
##   W  Wireframe              grey wire on black, no surfaces
##   SW Shadeless + Wireframe  Godot's Unshaded mode with a wireframe drawn on top
##   NW Shadeless              Godot's Unshaded display mode
##   E  Solid                  grey clay look of Godot's Display Lighting on a dark grey background; lit like the current view
##   NE Preview Sunlight       the 3D toolbar's sun toggle
##   SE Preview Environment    the 3D toolbar's environment toggle
##   S  Frame Selected         focus + zoom so the selection fills the view
##
## Shortcuts:  Editor Settings > Shortcuts > View Pie
## Colours:    Editor Settings > General > View Pie
##
## Everything works by pressing the editor's own menu items / buttons, or by
## setting materials directly on rendering-server instances, so nothing is
## ever written into your scenes.

const PieMenu := preload("pie_menu.gd")

const SC_OPEN := "view_pie/open_pie_menu"
const SC_REVERT := "view_pie/revert_view_state"

const SET_FLAT_LINE := "view_pie/wireframe/line_color"
const SET_FLAT_BG := "view_pie/wireframe/background_color"
const SET_OVER_LINE := "view_pie/shadeless_plus_wireframe/line_color"
const SET_SOLID_COLOR := "view_pie/solid/color"
const SET_SOLID_BG := "view_pie/solid/background_color"
const SET_SOLID_AMBIENT := "view_pie/solid/ambient_light"
const SET_FRAME_MARGIN := "view_pie/frame_selected/margin"

## Editor menu items are found by their shortcut, so this works in any editor language.
const OVERLAY_SHORTCUTS: PackedStringArray = [
	"spatial_editor/view_gizmos",
	"spatial_editor/view_transform_gizmo",
	"spatial_editor/view_grid_lines",   # per-viewport grid
	"spatial_editor/view_grid",         # global View > View Grid
	"spatial_editor/view_origin",
	"spatial_editor/view_information",
	"spatial_editor/view_fps",
]
## What "show overlays" turns on when there's nothing to restore (Godot's defaults).
const OVERLAY_DEFAULTS: PackedStringArray = [
	"spatial_editor/view_gizmos",
	"spatial_editor/view_transform_gizmo",
	"spatial_editor/view_grid_lines",
	"spatial_editor/view_grid",
	"spatial_editor/view_origin",
]
const DISPLAY_SHORTCUTS: PackedStringArray = [
	"spatial_editor/view_display_normal",
	"spatial_editor/view_display_wireframe",
	"spatial_editor/view_display_overdraw",
	"spatial_editor/view_display_lighting",
	"spatial_editor/view_display_unshaded",
]
const SC_DISPLAY_NORMAL := "spatial_editor/view_display_normal"
const SC_DISPLAY_UNSHADED := "spatial_editor/view_display_unshaded"
const SC_FOCUS := "spatial_editor/focus_selection"

const VIEWPORT_COUNT := 4
const TAP_TIME := 0.25  # releasing Z faster than this (with nothing picked) keeps the pie open

enum Shade { NONE, FLAT_WIRE, UNLIT_WIRE, UNLIT, SOLID }

const WIRE_SHADER := """
shader_type spatial;
render_mode unshaded, wireframe, cull_disabled, shadows_disabled%s;
uniform vec4 line_color : source_color = vec4(0.6, 0.6, 0.6, 1.0);
// Pulls lines slightly toward the camera so they don't z-fight with the surface.
uniform float pull = 0.0015;
void vertex() {
	vec4 v = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	if (PROJECTION_MATRIX[3][3] > 0.5) { v.z *= 1.0 - pull; } else { v.xyz *= 1.0 - pull; }
	POSITION = PROJECTION_MATRIX * v;
}
void fragment() {
	ALBEDO = line_color.rgb;%s
}
"""

## Same as the material Godot's "Display Lighting" mode puts on everything.
const SOLID_SHADER := """
shader_type spatial;
uniform vec3 albedo : source_color = vec3(0.6);
void vertex() {
	ROUGHNESS = 0.8;
}
void fragment() {
	ALBEDO = albedo;
	ROUGHNESS = 0.8;
	METALLIC = 0.2;
}
"""

var _pie: Control
var _pie_open := false
var _pie_click_mode := false
var _pie_opened_ms := 0
var _pie_keycode: Key = KEY_NONE
var _pie_physical: Key = KEY_NONE
var _pie_viewport := 0
var _swallow_lmb_release := false

# Overlays
var _hidden_items: Array = []  # [[PopupMenu, id]]

# Shading modes
var _shade := Shade.NONE
var _base_display := {}         # viewport index -> [PopupMenu, id] checked before we changed it
var _env_backup := {}           # viewport index -> Environment the editor camera had
var _material_targets: Array = []  # instance ids of GeometryInstance3D we touched
var _flat_mat: ShaderMaterial
var _over_mat: ShaderMaterial
var _solid_mat: ShaderMaterial
var _black_env: Environment

# Snapshot for Alt+Z (cleared on revert)
var _snap_sun: Variant = null   # bool once the sun was toggled
var _snap_env: Variant = null   # bool once the preview environment was toggled
var _env_button_ref: Button
var _snap_camera := {}          # viewport index -> {pivot: Vector3, dist: float}


# ==========================================================================
# Lifecycle

func _enter_tree() -> void:
	if not EditorInterface.get_editor_settings().has_method("add_shortcut"):
		push_error("View Pie needs Godot 4.6 or newer.")
		return
	_register_shortcuts()
	_register_settings()
	_build_materials()

	_pie = PieMenu.new()
	EditorInterface.get_base_control().add_child(_pie)

	scene_changed.connect(_on_scene_changed)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	# Solid follows the preview-environment toggle. Event driven: no polling.
	_env_button_ref = _env_button()
	if _env_button_ref:
		_env_button_ref.pressed.connect(_queue_solid_refresh, CONNECT_DEFERRED)
	EditorInterface.get_editor_settings().settings_changed.connect(_update_materials_from_settings)


func _exit_tree() -> void:
	if _pie == null:
		return
	_close_pie()
	# Never leave the editor in a modified state when the addon is disabled.
	_set_shade(Shade.NONE)
	if not _hidden_items.is_empty():
		_show_overlays()
	if is_instance_valid(_env_button_ref) and _env_button_ref.pressed.is_connected(_queue_solid_refresh):
		_env_button_ref.pressed.disconnect(_queue_solid_refresh)
	if get_tree().node_removed.is_connected(_on_node_removed):
		get_tree().node_removed.disconnect(_on_node_removed)
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	var es := EditorInterface.get_editor_settings()
	if es.settings_changed.is_connected(_update_materials_from_settings):
		es.settings_changed.disconnect(_update_materials_from_settings)
	_pie.queue_free()
	_pie = null


# ==========================================================================
# Input

func _unhandled_key_input(event: InputEvent) -> void:
	# Unhandled stage: text fields, and other tools that use Z (e.g. an
	# axis lock during a transform), get the key first.
	if _pie == null or _pie_open:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	var es := EditorInterface.get_editor_settings()
	var open_sc: Shortcut = es.get_shortcut(SC_OPEN)
	var revert_sc: Shortcut = es.get_shortcut(SC_REVERT)

	if open_sc and open_sc.matches_event(k):
		var vp := _hovered_viewport()
		if vp < 0 or Input.get_mouse_button_mask() != 0:
			return
		_open_pie(vp, k)
		get_viewport().set_input_as_handled()
	elif revert_sc and revert_sc.matches_event(k):
		if not _is_3d_editor_visible():
			return
		_revert_all()
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if _pie == null:
		return
	if not _pie_open:
		# Eat the release of the click that picked an item, so the viewport
		# doesn't treat it as a selection click.
		if _swallow_lmb_release and event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_swallow_lmb_release = false
			get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion:
		_pie.update_hover()
		get_viewport().set_input_as_handled()

	elif event is InputEventKey:
		var k := event as InputEventKey
		get_viewport().set_input_as_handled()
		if k.echo:
			return
		if k.pressed and k.keycode == KEY_ESCAPE:
			_close_pie()
		elif _is_pie_key(k):
			if not k.pressed and not _pie_click_mode:
				var id: StringName = _pie.hovered_id
				if id == &"" and (Time.get_ticks_msec() - _pie_opened_ms) < TAP_TIME * 1000.0:
					_pie_click_mode = true  # quick tap: keep the pie open, pick with a click
					return
				_close_pie()
				if id != &"":
					_activate(id)
			elif k.pressed and _pie_click_mode:
				_close_pie()

	elif event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		get_viewport().set_input_as_handled()
		if not b.pressed:
			return
		if b.button_index == MOUSE_BUTTON_LEFT:
			var id: StringName = _pie.hovered_id
			_close_pie()
			_swallow_lmb_release = true
			if id != &"":
				_activate(id)
		elif b.button_index == MOUSE_BUTTON_RIGHT:
			_close_pie()


func _is_pie_key(k: InputEventKey) -> bool:
	return (_pie_keycode != KEY_NONE and k.keycode == _pie_keycode) \
		or (_pie_physical != KEY_NONE and k.physical_keycode == _pie_physical)


# ==========================================================================
# Pie

func _open_pie(vp: int, k: InputEventKey) -> void:
	_pie_viewport = vp
	_pie_keycode = k.keycode
	_pie_physical = k.physical_keycode
	_pie_opened_ms = Time.get_ticks_msec()
	_pie_click_mode = false
	_pie_open = true
	_pie.open(_pie.get_parent().get_local_mouse_position(), _pie_items())


func _close_pie() -> void:
	_pie_open = false
	_pie_click_mode = false
	if _pie:
		_pie.close()


func _pie_items() -> Array:
	var sun := _sun_button()
	var env := _env_button()
	return [
		{ slot = 2, id = &"overlays", label = "Overlays", toggle = true, active = _overlays_on() },
		{ slot = 4, id = &"flat_wire", label = "Wireframe", toggle = true, active = _shade == Shade.FLAT_WIRE },
		{ slot = 5, id = &"unlit_wire", label = "Shadeless + Wireframe", toggle = true, active = _shade == Shade.UNLIT_WIRE },
		{ slot = 3, id = &"unlit", label = "Shadeless", toggle = true, active = _shade == Shade.UNLIT },
		{ slot = 0, id = &"solid", label = "Solid", toggle = true, active = _shade == Shade.SOLID },
		{ slot = 1, id = &"sun", label = "Preview Sunlight", toggle = true,
			active = sun != null and sun.button_pressed and not sun.disabled,
			enabled = sun != null and not sun.disabled },
		{ slot = 7, id = &"env", label = "Preview Environment", toggle = true,
			active = env != null and env.button_pressed and not env.disabled,
			enabled = env != null and not env.disabled },
		{ slot = 6, id = &"frame", label = "Frame Selected", toggle = false },
	]


func _activate(id: StringName) -> void:
	match id:
		&"overlays": _toggle_overlays()
		&"flat_wire": _toggle_shade(Shade.FLAT_WIRE)
		&"unlit_wire": _toggle_shade(Shade.UNLIT_WIRE)
		&"unlit": _toggle_shade(Shade.UNLIT)
		&"solid": _toggle_shade(Shade.SOLID)
		&"sun": _toggle_sun()
		&"env": _toggle_env()
		&"frame": _frame_selected(_pie_viewport)


# ==========================================================================
# N — Overlays
#
# The on/off state is read from the editor's menus every time (never cached),
# so it can't get out of sync with manual menu changes or other addons.
#   Something visible -> hide everything that's on, remembering what it was.
#   Nothing visible   -> bring back what we hid; if there's nothing to bring
#                        back (you hid them by hand), turn on Godot's defaults.

func _toggle_overlays() -> void:
	if _overlays_on():
		_hide_overlays()
	else:
		_show_overlays(true)


## True if any overlay is on in a visible viewport (or in the global View menu).
func _overlays_on() -> bool:
	for entry in _overlay_entries(OVERLAY_SHORTCUTS, true):
		if _is_checked(entry):
			return true
	return false


func _hide_overlays() -> void:
	_hidden_items.clear()
	for entry in _overlay_entries(OVERLAY_SHORTCUTS, false):
		if _is_checked(entry):
			_press(entry)
			_hidden_items.append(entry)


func _show_overlays(use_defaults := false) -> void:
	var entries := _hidden_items.duplicate()
	if entries.is_empty() and use_defaults:
		entries = _overlay_entries(OVERLAY_DEFAULTS, false)
	for entry in entries:
		if is_instance_valid(entry[0]) and entry[0].get_item_index(entry[1]) >= 0 and not _is_checked(entry):
			_press(entry)
	_hidden_items.clear()


## Overlay menu items. visible_only: skip viewports hidden by the current layout.
func _overlay_entries(paths: PackedStringArray, visible_only: bool) -> Array:
	var editor := _node3d_editor()
	if editor == null:
		return []
	var vp_roots: Array[Control] = []
	for i in VIEWPORT_COUNT:
		var r := _viewport_root(i)
		if r:
			vp_roots.append(r)
	var popups := _popups_under(editor)
	var out: Array = []
	for path in paths:
		for entry in _find_items(popups, path):
			if visible_only:
				var owner_vp: Control = null
				for r in vp_roots:
					if r.is_ancestor_of(entry[0]):
						owner_vp = r
						break
				if owner_vp and not owner_vp.is_visible_in_tree():
					continue
			out.append(entry)
	return out


func _is_checked(entry: Array) -> bool:
	var popup: PopupMenu = entry[0]
	var idx := popup.get_item_index(entry[1])
	return idx >= 0 and popup.is_item_checked(idx)


# ==========================================================================
# W / SW / NW / E — shading modes (mutually exclusive, like Blender's shading)

func _toggle_shade(mode: Shade) -> void:
	_set_shade(Shade.NONE if _shade == mode else mode)


func _set_shade(mode: Shade) -> void:
	if mode == _shade:
		return
	_clear_materials()
	_restore_env()
	if _shade == Shade.NONE:
		_capture_base_display()
	_shade = mode
	match mode:
		Shade.NONE:
			_restore_base_display()
		Shade.FLAT_WIRE:
			_set_display_all(SC_DISPLAY_NORMAL)
			_apply_black_env()
			_apply_materials()
		Shade.UNLIT_WIRE:
			_set_display_all(SC_DISPLAY_UNSHADED)
			_apply_materials()
		Shade.UNLIT:
			_set_display_all(SC_DISPLAY_UNSHADED)
		Shade.SOLID:
			_set_display_all(SC_DISPLAY_NORMAL)
			_apply_solid_env()
			_apply_materials()


func _capture_base_display() -> void:
	_base_display.clear()
	for i in VIEWPORT_COUNT:
		var entry := _checked_display_item(i)
		if not entry.is_empty():
			_base_display[i] = entry


func _restore_base_display() -> void:
	for i in VIEWPORT_COUNT:
		if _base_display.has(i) and is_instance_valid(_base_display[i][0]):
			_press(_base_display[i])
		else:
			_set_display(i, SC_DISPLAY_NORMAL)
	_base_display.clear()


func _checked_display_item(vp: int) -> Array:
	var root := _viewport_root(vp)
	if root == null:
		return []
	var popups := _popups_under(root)
	for path in DISPLAY_SHORTCUTS:
		for entry in _find_items(popups, path):
			var popup: PopupMenu = entry[0]
			if popup.is_item_checked(popup.get_item_index(entry[1])):
				return entry
	# "Display Advanced..." submenu: a child PopupMenu of the View menu.
	var view_popup := _viewport_view_popup(vp)
	if view_popup:
		for child in view_popup.get_children(true):
			if child is PopupMenu:
				for i in child.item_count:
					if child.is_item_radio_checkable(i) and child.is_item_checked(i):
						return [child, child.get_item_id(i)]
	return []


func _set_display_all(path: String) -> void:
	for i in VIEWPORT_COUNT:
		_set_display(i, path)


func _set_display(vp: int, path: String) -> void:
	var root := _viewport_root(vp)
	if root == null:
		return
	for entry in _find_items(_popups_under(root), path):
		_press(entry)


# --- materials ------------------------------------------------------------

func _build_materials() -> void:
	var opaque := Shader.new()
	opaque.code = WIRE_SHADER % ["", ""]
	_flat_mat = ShaderMaterial.new()
	_flat_mat.shader = opaque

	var blended := Shader.new()
	blended.code = WIRE_SHADER % [", blend_mix, depth_draw_never", "\n\tALPHA = line_color.a;"]
	_over_mat = ShaderMaterial.new()
	_over_mat.shader = blended

	var solid := Shader.new()
	solid.code = SOLID_SHADER
	_solid_mat = ShaderMaterial.new()
	_solid_mat.shader = solid

	_black_env = Environment.new()
	_black_env.background_mode = Environment.BG_COLOR
	_black_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_black_env.ambient_light_color = Color.BLACK
	_black_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_update_materials_from_settings()


func _update_materials_from_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if _flat_mat:
		_flat_mat.set_shader_parameter("line_color", es.get_setting(SET_FLAT_LINE))
	if _over_mat:
		_over_mat.set_shader_parameter("line_color", es.get_setting(SET_OVER_LINE))
	if _solid_mat:
		var c: Color = es.get_setting(SET_SOLID_COLOR)
		_solid_mat.set_shader_parameter("albedo", Vector3(c.r, c.g, c.b))
	if _black_env:
		_black_env.background_color = es.get_setting(SET_FLAT_BG)
	if _shade == Shade.SOLID:
		_apply_solid_env()


func _apply_materials() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			_apply_material_to(n)
		stack.append_array(n.get_children(true))


func _apply_material_to(gi: GeometryInstance3D) -> void:
	var rid := gi.get_instance()
	if not rid.is_valid():
		return
	match _shade:
		Shade.FLAT_WIRE:
			RenderingServer.instance_geometry_set_material_override(rid, _flat_mat.get_rid())
		Shade.SOLID:
			RenderingServer.instance_geometry_set_material_override(rid, _solid_mat.get_rid())
		Shade.UNLIT_WIRE:
			RenderingServer.instance_geometry_set_material_overlay(rid, _over_mat.get_rid())
		_:
			return
	_material_targets.append(gi.get_instance_id())


func _clear_materials() -> void:
	for id in _material_targets:
		var gi := instance_from_id(id) as GeometryInstance3D
		if gi == null:
			continue
		var rid := gi.get_instance()
		if not rid.is_valid():
			continue
		# Put back whatever the node itself has.
		RenderingServer.instance_geometry_set_material_override(rid,
				gi.material_override.get_rid() if gi.material_override else RID())
		RenderingServer.instance_geometry_set_material_overlay(rid,
				gi.material_overlay.get_rid() if gi.material_overlay else RID())
	_material_targets.clear()


func _uses_materials() -> bool:
	return _shade == Shade.FLAT_WIRE or _shade == Shade.UNLIT_WIRE or _shade == Shade.SOLID


func _on_node_added(node: Node) -> void:
	if _shade == Shade.SOLID and node is WorldEnvironment:
		_queue_solid_refresh()
	if _uses_materials() and node is GeometryInstance3D:
		_apply_new_node.call_deferred(node)


func _apply_new_node(node: Node) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree():
		return
	if not _uses_materials():
		return
	var root := EditorInterface.get_edited_scene_root()
	if root and (node == root or root.is_ancestor_of(node)):
		_apply_material_to(node)


func _on_scene_changed(_root: Node) -> void:
	_queue_solid_refresh()
	if _uses_materials():
		_clear_materials()
		_apply_materials()


# --- backgrounds ------------------------------------------------------------
# Set on the editor cameras (a camera's environment beats the world's), so
# the scene's WorldEnvironment / the preview environment are never touched.

func _apply_black_env() -> void:
	for i in VIEWPORT_COUNT:
		_set_camera_env(i, _black_env)


## Solid: the environment's visuals (sky, fog, glow, adjustments...) are hidden
## and replaced by a flat background colour, but the lighting follows what the
## view would normally use: the scene's WorldEnvironment, or Godot's preview
## environment when "Toggle preview environment" is on. With neither, a neutral
## ambient light (Editor Settings > View Pie > Solid > Ambient Light) is used.
## Nothing on the WorldEnvironment node is changed.
func _apply_solid_env() -> void:
	for i in VIEWPORT_COUNT:
		var cam := _editor_camera(i)
		if cam:
			_set_camera_env(i, _make_solid_env(_lighting_source_env(i, cam)))


## The environment this viewport would render with if View Pie weren't involved.
func _lighting_source_env(vp: int, cam: Camera3D) -> Environment:
	var own: Environment = _env_backup[vp][0] if _env_backup.has(vp) else cam.environment
	if own:
		return own  # e.g. the editor's "no environment" one when View Environment is off
	var world := cam.get_world_3d()
	if world == null:
		return null
	return world.environment if world.environment else world.fallback_environment


func _make_solid_env(src: Environment) -> Environment:
	var es := EditorInterface.get_editor_settings()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = es.get_setting(SET_SOLID_BG)
	if src == null:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = es.get_setting(SET_SOLID_AMBIENT)
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		return env

	var has_sky := src.background_mode == Environment.BG_SKY and src.sky != null
	env.sky = src.sky
	env.sky_rotation = src.sky_rotation
	env.sky_custom_fov = src.sky_custom_fov

	# "Background" as a light source would now mean our flat colour, so point
	# it at what the background really was.
	var amb := src.ambient_light_source
	env.ambient_light_color = src.ambient_light_color
	if amb == Environment.AMBIENT_SOURCE_BG:
		if has_sky:
			amb = Environment.AMBIENT_SOURCE_SKY
		elif src.background_mode == Environment.BG_COLOR:
			amb = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = src.background_color
		elif src.background_mode == Environment.BG_CLEAR_COLOR:
			amb = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = ProjectSettings.get_setting("rendering/environment/defaults/default_clear_color", Color(0.3, 0.3, 0.3))
		else:
			amb = Environment.AMBIENT_SOURCE_DISABLED
	env.ambient_light_source = amb
	env.ambient_light_energy = src.ambient_light_energy
	env.ambient_light_sky_contribution = src.ambient_light_sky_contribution

	var refl := src.reflected_light_source
	if refl == Environment.REFLECTION_SOURCE_BG:
		refl = Environment.REFLECTION_SOURCE_SKY if has_sky else Environment.REFLECTION_SOURCE_DISABLED
	env.reflected_light_source = refl

	env.tonemap_mode = src.tonemap_mode
	env.tonemap_exposure = src.tonemap_exposure
	env.tonemap_white = src.tonemap_white
	return env


func _queue_solid_refresh() -> void:
	# Deferred so the editor has finished swapping its preview environment.
	_refresh_solid_env.call_deferred()


func _refresh_solid_env() -> void:
	if _shade == Shade.SOLID:
		_apply_solid_env()


func _on_node_removed(node: Node) -> void:
	if _shade == Shade.SOLID and node is WorldEnvironment:
		_queue_solid_refresh()


func _set_camera_env(vp: int, env: Environment) -> void:
	var cam := _editor_camera(vp)
	if cam == null:
		return
	if not _env_backup.has(vp):
		_env_backup[vp] = [cam.environment, env]
	else:
		_env_backup[vp][1] = env
	cam.environment = env


func _restore_env() -> void:
	for i in _env_backup:
		var cam := _editor_camera(i)
		# Only undo it if nothing else changed the camera's environment meanwhile.
		if cam and cam.environment == _env_backup[i][1]:
			cam.environment = _env_backup[i][0]
	_env_backup.clear()


# ==========================================================================
# NE / SE — Preview sunlight / preview environment (the 3D toolbar buttons)

func _toggle_sun() -> void:
	var b := _sun_button()
	if b == null:
		_toast("View Pie: couldn't find the preview sunlight button.")
	elif b.disabled:
		_toast("Preview sunlight is disabled because the scene has a DirectionalLight3D.")
	else:
		if _snap_sun == null:
			_snap_sun = b.button_pressed
		_set_toolbar_toggle(b, not b.button_pressed)


func _toggle_env() -> void:
	var b := _env_button()
	if b == null:
		_toast("View Pie: couldn't find the preview environment button.")
	elif b.disabled:
		_toast("Preview environment is disabled because the scene has a WorldEnvironment.")
	else:
		if _snap_env == null:
			_snap_env = b.button_pressed
		_set_toolbar_toggle(b, not b.button_pressed)


func _set_toolbar_toggle(b: Button, on: bool) -> void:
	if b.button_pressed == on:
		return
	b.set_pressed_no_signal(on)
	b.pressed.emit()  # the editor listens to `pressed`, not `toggled`


func _sun_button() -> Button:
	return _toolbar_button("Toggle preview sunlight")


func _env_button() -> Button:
	if is_instance_valid(_env_button_ref):
		return _env_button_ref
	return _toolbar_button("Toggle preview environment")


func _toolbar_button(tooltip_prefix: String) -> Button:
	var editor := _node3d_editor()
	if editor == null:
		return null
	var stack: Array[Node] = [editor]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and n.toggle_mode and n.tooltip_text.begins_with(tooltip_prefix):
			return n
		stack.append_array(n.get_children(true))
	return null


# ==========================================================================
# S — Frame selected (focus + zoom to fill)
#
# Godot's Focus Selection only re-centres on the nodes' origins and keeps the
# zoom. We centre on the selection's bounding box instead, by focusing a
# temporary helper node placed at the box centre, then zoom with magnify
# gestures. Everything happens in the same frame: no waiting.

func _frame_selected(vp: int) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var cam := _editor_camera(vp)
	if root == null or cam == null:
		return

	var box := AABB()
	var has_box := false
	for n in EditorInterface.get_selection().get_top_selected_nodes():
		if n is Node3D and n.is_inside_tree():
			var b := _node_bounds(n)
			box = b if not has_box else box.merge(b)
			has_box = true
	if not has_box:
		_toast("Nothing selected to frame.")
		return
	if box.size.length() < 0.001:
		box = box.grow(0.5)  # a lone empty/marker: frame a 1 m cube around it

	var pivot := box.get_center()

	# Remember where the view was the first time, for Alt+Z.
	if not _snap_camera.has(vp):
		_snap_camera[vp] = _current_view(cam, pivot)

	_drive_camera(vp, pivot, _fit_distance(cam, vp, box, pivot))


## A pivot + distance that reproduces what `cam` shows right now.
func _current_view(cam: Camera3D, hint: Vector3) -> Dictionary:
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z.normalized()
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		# Editor ortho: eye sits (far - near) / 2 behind the pivot and
		# height = 2 * distance * tan(fov / 2).
		var d := cam.size / (2.0 * tan(deg_to_rad(cam.fov) * 0.5))
		return { pivot = eye + fwd * (cam.far - cam.near) * 0.5, dist = d }
	# Perspective: any pivot on the view ray gives the same picture; put it at
	# the depth of the thing being framed so orbiting afterwards feels natural.
	var d := maxf(fwd.dot(hint - eye), cam.near * 4.0 + 0.01)
	return { pivot = eye + fwd * d, dist = d }


func _node_bounds(node: Node3D) -> AABB:
	var box := AABB(node.global_position, Vector3.ZERO)
	var found := false
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D and n.is_visible_in_tree():
			var a: AABB = n.global_transform * n.get_aabb()
			box = a if not found else box.merge(a)
			found = true
		stack.append_array(n.get_children())
	return box


## Camera distance at which `box` fills the view (with the margin setting).
func _fit_distance(cam: Camera3D, vp: int, box: AABB, pivot: Vector3) -> float:
	var basis := cam.global_transform.basis.orthonormalized()
	var vsize := Vector2(EditorInterface.get_editor_viewport_3d(vp).size)
	var aspect := vsize.x / maxf(1.0, vsize.y)
	var margin: float = EditorInterface.get_editor_settings().get_setting(SET_FRAME_MARGIN)
	var tv := tan(deg_to_rad(cam.fov) * 0.5)
	var th := tv * aspect
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		th = tv
		tv = th / aspect
	var ortho := cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	var need := 0.0
	for i in 8:
		var rel := box.get_endpoint(i) - pivot
		var x := absf(rel.dot(basis.x)) * margin
		var y := absf(rel.dot(basis.y)) * margin
		var z := rel.dot(basis.z)  # + toward the camera
		if ortho:
			need = maxf(need, maxf(y, x / aspect) / tv)
		else:
			need = maxf(need, maxf(z + x / th, z + y / tv))
	return maxf(need, _min_zoom_distance(cam))


## The editor clamps the orbit distance to max(near * 4, 0.01).
func _min_zoom_distance(cam: Camera3D) -> float:
	return maxf(cam.near * 4.0, 0.01)


## Sets the viewport's orbit pivot to `pivot` and its orbit distance to `dist`,
## instantly (the editor's own smoothing then animates the camera there).
func _drive_camera(vp: int, pivot: Vector3, dist: float) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var cam := _editor_camera(vp)
	var surface := _viewport_surface(vp)
	var root_ctrl := _viewport_root(vp)
	if root == null or cam == null or surface == null or root_ctrl == null:
		return

	# 1. Focus a temporary helper at the pivot, then restore the selection.
	#    (Selection signals are deferred, so the editor never sees the helper selected.)
	var selection := EditorInterface.get_selection()
	var previous: Array[Node] = selection.get_selected_nodes()
	var helper := Node3D.new()
	helper.name = "_ViewPieFocus"
	root.add_child(helper, false, Node.INTERNAL_MODE_BACK)
	helper.global_position = pivot
	selection.clear()
	selection.add_node(helper)
	for entry in _find_items(_popups_under(root_ctrl), SC_FOCUS):
		_press(entry)
	selection.clear()
	for n in previous:
		if is_instance_valid(n) and n.is_inside_tree():
			selection.add_node(n)
	root.remove_child(helper)
	helper.queue_free()

	# 2. Zoom. The current distance isn't readable, so first slam it into the
	#    editor's minimum (a known value), then scale from there to `dist`.
	#    Both happen before the next redraw, so only the final zoom is seen.
	var min_d := _min_zoom_distance(cam)
	_send_magnify(surface, 1.0e12)
	_send_magnify(surface, min_d / maxf(dist, min_d))


func _send_magnify(surface: Control, factor: float) -> void:
	# Distance is scaled by 1 / factor.
	var ev := InputEventMagnifyGesture.new()
	ev.factor = factor
	ev.position = surface.size * 0.5
	surface.gui_input.emit(ev)


# ==========================================================================
# Alt+Z — revert

func _revert_all() -> void:
	_close_pie()
	_set_shade(Shade.NONE)
	if not _hidden_items.is_empty():
		_show_overlays()
	if _snap_sun != null:
		var b := _sun_button()
		if b and not b.disabled:
			_set_toolbar_toggle(b, _snap_sun)
	_snap_sun = null
	if _snap_env != null:
		var b := _env_button()
		if b and not b.disabled:
			_set_toolbar_toggle(b, _snap_env)
	_snap_env = null

	for vp in _snap_camera:
		_drive_camera(vp, _snap_camera[vp].pivot, _snap_camera[vp].dist)
	_snap_camera.clear()


# ==========================================================================
# Editor lookup helpers

func _node3d_editor() -> Node:
	for child in EditorInterface.get_editor_main_screen().get_children():
		if child.get_class() == "Node3DEditor":
			return child
	return null


func _is_3d_editor_visible() -> bool:
	var e := _node3d_editor()
	return e != null and e.is_visible_in_tree()


func _hovered_viewport() -> int:
	for i in VIEWPORT_COUNT:
		var sub := EditorInterface.get_editor_viewport_3d(i)
		if sub == null:
			continue
		var c := sub.get_parent() as Control
		if c and c.is_visible_in_tree() and c.get_global_rect().has_point(c.get_global_mouse_position()):
			return i
	return -1


## The Node3DEditorViewport control (SubViewport -> SubViewportContainer -> viewport).
func _viewport_root(vp: int) -> Control:
	var sub := EditorInterface.get_editor_viewport_3d(vp)
	if sub == null or sub.get_parent() == null:
		return null
	return sub.get_parent().get_parent() as Control


## The plain Control that receives the viewport's mouse/gesture input.
func _viewport_surface(vp: int) -> Control:
	var root := _viewport_root(vp)
	if root == null:
		return null
	for child in root.get_children():
		if child.get_class() == "Control":
			return child
	return null


## The editor's own camera (not a scene camera being previewed).
func _editor_camera(vp: int) -> Camera3D:
	var sub := EditorInterface.get_editor_viewport_3d(vp)
	if sub == null:
		return null
	for child in sub.get_children():
		if child is Camera3D:
			return child
	return null


func _viewport_view_popup(vp: int) -> PopupMenu:
	var root := _viewport_root(vp)
	if root == null:
		return null
	var found := _find_items(_popups_under(root), SC_DISPLAY_NORMAL)
	return found[0][0] if not found.is_empty() else null


func _popups_under(node: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is PopupMenu:
			out.append(n)
		stack.append_array(n.get_children(true))
	return out


## Menu items bound to the editor shortcut at `path` -> [[PopupMenu, id], ...]
func _find_items(popups: Array, path: String) -> Array:
	var out: Array = []
	var sc: Shortcut = EditorInterface.get_editor_settings().get_shortcut(path)
	if sc == null:
		return out
	for popup: PopupMenu in popups:
		for i in popup.item_count:
			if popup.get_item_shortcut(i) == sc:
				out.append([popup, popup.get_item_id(i)])
	return out


## Same as clicking the menu item.
func _press(entry: Array) -> void:
	var popup: PopupMenu = entry[0]
	if is_instance_valid(popup):
		popup.id_pressed.emit(entry[1])


func _toast(msg: String) -> void:
	if EditorInterface.has_method("get_editor_toaster"):
		EditorInterface.get_editor_toaster().push_toast(msg, EditorToaster.SEVERITY_WARNING)
	else:
		push_warning(msg)


# ==========================================================================
# Shortcuts & settings

func _register_shortcuts() -> void:
	var es := EditorInterface.get_editor_settings()
	# add_shortcut() keeps a binding you've customised; it only sets the default.
	es.add_shortcut(SC_OPEN, _make_shortcut("Open Pie Menu", KEY_Z, false))
	es.add_shortcut(SC_REVERT, _make_shortcut("Revert View State", KEY_Z, true))


func _make_shortcut(title: String, key: Key, alt: bool) -> Shortcut:
	var ev := InputEventKey.new()
	ev.keycode = key
	ev.alt_pressed = alt
	var sc := Shortcut.new()
	sc.resource_name = title
	sc.events = [ev]
	return sc


func _register_settings() -> void:
	_add_setting(SET_FLAT_LINE, Color(0.6, 0.6, 0.6), TYPE_COLOR)
	_add_setting(SET_FLAT_BG, Color(0, 0, 0), TYPE_COLOR, PROPERTY_HINT_COLOR_NO_ALPHA)
	_add_setting(SET_OVER_LINE, Color(0, 0, 0, 0.6), TYPE_COLOR)
	_add_setting(SET_SOLID_COLOR, Color(0.6, 0.6, 0.6), TYPE_COLOR, PROPERTY_HINT_COLOR_NO_ALPHA)
	_add_setting(SET_SOLID_BG, Color(0.06, 0.06, 0.06), TYPE_COLOR, PROPERTY_HINT_COLOR_NO_ALPHA)
	_add_setting(SET_SOLID_AMBIENT, Color(0.45, 0.45, 0.45), TYPE_COLOR, PROPERTY_HINT_COLOR_NO_ALPHA)
	_add_setting(SET_FRAME_MARGIN, 1.1, TYPE_FLOAT, PROPERTY_HINT_RANGE, "1.0,2.0,0.01")


func _add_setting(name: String, default: Variant, type: int, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(name):
		es.set_setting(name, default)
	es.set_initial_value(name, default, false)
	es.add_property_info({ "name": name, "type": type, "hint": hint, "hint_string": hint_string })
