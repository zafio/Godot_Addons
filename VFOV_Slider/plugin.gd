@tool
extends EditorPlugin

const DEFAULT_FOV: float = 70.0
const MIN_FOV: float = 10.0
const MAX_FOV: float = 130.0

var container: HBoxContainer
var fov_slider: HSlider
var fov_label: Label
var reset_button: Button
var dolly_toggle_btn: Button

var _is_updating: bool = false
var _dolly_enabled: bool = true
var _dolly_states: Dictionary = {} # viewport_idx -> { focal_point, initial_dist, initial_fov }
var _last_fov: float = DEFAULT_FOV


func _enter_tree() -> void:
	_create_ui()
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, container)
	_position_in_toolbar.call_deferred()
	_init_sync.call_deferred()


func _exit_tree() -> void:
	if container:
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, container)
		container.queue_free()


func _create_ui() -> void:
	container = HBoxContainer.new()
	container.alignment = BoxContainer.ALIGNMENT_CENTER
	container.add_theme_constant_override("separation", 3)
	container.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	container.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var vs = VSeparator.new()
	container.add_child(vs)

	var title = Label.new()
	title.text = "FOV:"
	title.tooltip_text = "3D Viewport Perspective VFOV"
	container.add_child(title)

	fov_slider = HSlider.new()
	fov_slider.min_value = MIN_FOV
	fov_slider.max_value = MAX_FOV
	fov_slider.step = 0.5
	fov_slider.value = DEFAULT_FOV
	fov_slider.custom_minimum_size = Vector2(70, 0)
	fov_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	fov_slider.tooltip_text = "Adjust Viewport Perspective VFOV (Dolly Zoom active)"
	fov_slider.value_changed.connect(_on_fov_slider_changed)
	fov_slider.drag_started.connect(_on_drag_started)
	fov_slider.drag_ended.connect(_on_drag_ended)
	container.add_child(fov_slider)

	fov_label = Label.new()
	fov_label.text = "%d°" % int(DEFAULT_FOV)
	fov_label.custom_minimum_size = Vector2(30, 0)
	container.add_child(fov_label)

	# Dolly Zoom toggle button
	dolly_toggle_btn = Button.new()
	dolly_toggle_btn.text = "🎥"
	dolly_toggle_btn.flat = false
	dolly_toggle_btn.toggle_mode = true
	dolly_toggle_btn.button_pressed = true
	dolly_toggle_btn.tooltip_text = "Toggle Dolly Zoom: Keep model size constant while morphing perspective"
	dolly_toggle_btn.toggled.connect(func(pressed: bool): _dolly_enabled = pressed)
	container.add_child(dolly_toggle_btn)

	# Reset button
	reset_button = Button.new()
	reset_button.text = "↺"
	reset_button.flat = true
	reset_button.tooltip_text = "Reset VFOV to default (%d°)" % int(DEFAULT_FOV)
	reset_button.pressed.connect(func(): fov_slider.value = DEFAULT_FOV)
	container.add_child(reset_button)

	var vs_end = VSeparator.new()
	container.add_child(vs_end)


func _position_in_toolbar() -> void:
	if not container or not container.get_parent():
		return
	var parent = container.get_parent()

	var target_index := -1
	for i in range(parent.get_child_count()):
		var child = parent.get_child(i)
		if child is MenuButton and child.text == "View":
			target_index = i + 1
			break

	if target_index == -1:
		for i in range(parent.get_child_count()):
			var child = parent.get_child(i)
			if child is Button and ("Move" in child.tooltip_text or "Translate" in child.tooltip_text or "Select" in child.tooltip_text):
				target_index = i + 1

	if target_index != -1 and target_index < parent.get_child_count():
		parent.move_child(container, target_index)


func _init_sync() -> void:
	_hook_viewport_dialogs()
	_sync_from_viewports()


func _get_viewport_dialog_data() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var base = EditorInterface.get_base_control()
	if not base:
		return result

	var all_dialogs = base.find_children("", "ConfirmationDialog", true, false)
	for d in all_dialogs:
		if d is ConfirmationDialog and d.title == "Viewport Settings":
			var spinboxes = d.find_children("", "SpinBox", true, false)
			if spinboxes.size() > 0:
				result.append({
					"dialog": d as ConfirmationDialog,
					"fov_spinbox": spinboxes[0] as SpinBox
				})
	return result


func _hook_viewport_dialogs() -> void:
	for item in _get_viewport_dialog_data():
		var dialog: ConfirmationDialog = item["dialog"]
		var spin: SpinBox = item["fov_spinbox"]
		var callback := _on_external_dialog_confirmed.bind(spin)
		if not dialog.confirmed.is_connected(callback):
			dialog.confirmed.connect(callback)


func _sync_from_viewports() -> void:
	var items = _get_viewport_dialog_data()
	var current_fov: float = DEFAULT_FOV

	if items.size() > 0 and items[0]["fov_spinbox"]:
		current_fov = float(items[0]["fov_spinbox"].value)

	_is_updating = true
	_last_fov = current_fov
	fov_slider.set_value_no_signal(current_fov)
	fov_label.text = "%.1f°" % current_fov if fmod(current_fov, 1.0) != 0.0 else "%d°" % int(current_fov)
	_is_updating = false


func _get_focal_point(cam: Camera3D) -> Vector3:
	# 1. If user has a node selected in the editor, focus on it
	var selection = EditorInterface.get_selection().get_selected_nodes()
	for node in selection:
		if node is VisualInstance3D:
			var aabb: AABB = node.get_aabb()
			return node.global_transform * aabb.get_center()
		elif node is Node3D:
			return node.global_position

	# 2. Raycast against 3D physics geometry in front of camera
	if cam.get_world_3d() and cam.get_world_3d().direct_space_state:
		var space = cam.get_world_3d().direct_space_state
		var from = cam.global_position
		var to = from - cam.global_transform.basis.z * 500.0
		var query = PhysicsRayQueryParameters3D.create(from, to)
		var hit = space.intersect_ray(query)
		if hit and hit.has("position"):
			return hit["position"]

	# 3. Default: point along camera forward vector relative to origin
	var cam_forward = -cam.global_transform.basis.z.normalized()
	var to_origin = -cam.global_position
	var t = to_origin.dot(cam_forward)
	if t > 0.5:
		return cam.global_position + cam_forward * t

	return cam.global_position + cam_forward * 4.0


func _on_drag_started() -> void:
	_dolly_states.clear()
	for i in range(4):
		var vp = EditorInterface.get_editor_viewport_3d(i)
		if vp:
			var cam = vp.get_camera_3d()
			if cam:
				var fp = _get_focal_point(cam)
				var dist = maxf((cam.global_position - fp).length(), 0.05)
				_dolly_states[i] = {
					"focal_point": fp,
					"initial_dist": dist,
					"initial_fov": fov_slider.value
				}


func _on_drag_ended(_value_changed: bool) -> void:
	_dolly_states.clear()
	_last_fov = fov_slider.value


func _apply_dolly_zoom(new_fov: float) -> void:
	var rad_new = deg_to_rad(new_fov) * 0.5
	var tan_new = tan(rad_new)
	if is_zero_approx(tan_new):
		return

	for i in range(4):
		var vp = EditorInterface.get_editor_viewport_3d(i)
		if not vp:
			continue
		var cam = vp.get_camera_3d()
		if not cam:
			continue

		var state: Dictionary = _dolly_states.get(i, {})
		if state.is_empty():
			var fp = _get_focal_point(cam)
			var dist = maxf((cam.global_position - fp).length(), 0.05)
			state = {
				"focal_point": fp,
				"initial_dist": dist,
				"initial_fov": _last_fov
			}
			_dolly_states[i] = state

		var fp: Vector3 = state["focal_point"]
		var d0: float = state["initial_dist"]
		var fov0: float = state["initial_fov"]

		var rad_0 = deg_to_rad(fov0) * 0.5
		var tan_0 = tan(rad_0)

		# Dolly Zoom calculation
		var d1 = d0 * (tan_0 / tan_new)

		var view_dir = (cam.global_position - fp)
		if view_dir.length_squared() < 0.0001:
			view_dir = cam.global_transform.basis.z
		view_dir = view_dir.normalized()

		cam.global_position = fp + view_dir * d1


func _on_fov_slider_changed(value: float) -> void:
	if _is_updating:
		return
	_is_updating = true

	fov_label.text = "%.1f°" % value if fmod(value, 1.0) != 0.0 else "%d°" % int(value)

	# 1. Update Godot's viewport FOV setting
	var items = _get_viewport_dialog_data()
	for item in items:
		var spin: SpinBox = item["fov_spinbox"]
		var dialog: ConfirmationDialog = item["dialog"]
		if spin and dialog:
			spin.value = value
			dialog.confirmed.emit()

	# 2. Apply Dolly Zoom camera displacement
	if _dolly_enabled:
		_apply_dolly_zoom(value)

	# 3. Store global setting
	var settings = EditorInterface.get_editor_settings()
	if settings:
		settings.set_setting("editors/3d/default_fov", value)

	_last_fov = value
	_is_updating = false


func _on_external_dialog_confirmed(spin: SpinBox) -> void:
	if _is_updating or not spin:
		return
	_is_updating = true
	_last_fov = spin.value
	fov_slider.set_value_no_signal(spin.value)
	fov_label.text = "%.1f°" % spin.value if fmod(spin.value, 1.0) != 0.0 else "%d°" % int(spin.value)
	_is_updating = false