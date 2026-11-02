@tool
extends EditorPlugin

# ==================================================
# Blender-style G / R / S transform operators for the Godot 4 3D editor
#
#   G / R / S        start Translate / Rotate / Scale (no modifier keys)
#   R (while rotating) toggle View-Plane <-> Turntable
#   X / Y / Z        cycle constraint for that axis. The cycle starts in the space
#                    chosen by Godot's "Use Local Space" toolbar toggle:
#                      toggle OFF: global axis -> global plane -> local axis -> local plane -> none
#                      toggle ON : local axis -> local plane -> global axis -> global plane -> none
#                    (plane = that axis + the in-plane partner that faces the camera,
#                     e.g. front view: X, X = XY plane)
#   MMB              pick the axis the mouse is moving along (Blender style); while in a
#                    plane stage it instead swaps to the other plane containing that axis
#   Shift+X/Y/Z      plane EXCLUDING that axis: global -> local -> none
#                    (local -> global -> none when "Use Local Space" is ON)
#   0-9 . - Backspace  numeric input
#   Ctrl = snap, Shift = precision
#   Enter / Space / LMB = confirm, Esc / RMB = cancel
#   Alt+G / Alt+R / Alt+S = clear location / rotation / scale
#                    ...then X / Y / Z toggle which axes are reset (pressing an axis twice backs it out;
#                    no axis toggled = reset all). Enter/click confirms, Esc cancels.
#   S while an AnimationPlayer is playing: not used for scale, so Godot's animation Stop (S) works
#   Continuous grab: the cursor wraps at the edges of the 3D viewport during a transform
#                    (CONTINUOUS_GRAB constant), so you can keep dragging past the screen limits.
#
# Plane constraints:
#   Translate : moves freely inside the plane (ray-plane intersection)
#   Rotate    : rotates around the plane normal
#   Scale     : scales both plane axes
# ==================================================

enum TransformType { NONE, TRANSLATE, ROTATE, SCALE }
enum RotateSubMode { VIEW_PLANE, TURNTABLE }
enum ConstraintStage { NONE, GLOBAL_AXIS, VIEW_PLANE, LOCAL_AXIS, EXCLUDE_GLOBAL, EXCLUDE_LOCAL, LOCAL_VIEW_PLANE }

const AXIS_NAMES := ["X", "Y", "Z"]

# --- State ---
var current_op := TransformType.NONE
var rot_submode := RotateSubMode.VIEW_PLANE

# Constraint state
var constraint_stage := ConstraintStage.NONE
var constraint_key := -1                      # 0 = X, 1 = Y, 2 = Z, -1 = none
var constraint_axes: Array[Vector3] = []      # 0, 1 (axis) or 2 (plane) unit vectors
var constraint_label := ""

# Selection and snapshot data
var selected_nodes: Array[Node3D] = []
var initial_local_transforms: Dictionary = {}   # Node3D -> Transform3D
var initial_global_transforms: Dictionary = {}  # Node3D -> Transform3D
var pivot_point := Vector3.ZERO
var screen_pivot := Vector2.ZERO
var initial_mouse_pos := Vector2.ZERO
var initial_angle_offset := 0.0

# Continuous screen-angle tracking (allows more than one full turn)
var angle_prev_mouse := Vector2.ZERO   # virtual mouse position at the last rotation update
var rot_accum := 0.0
var rot_ref_radius := 200.0            # constant radius (px) that turns mouse movement into angle
var wrap_offset := Vector2.ZERO        # total teleport of the real cursor: real cursor = virtual_mouse + wrap_offset

# Mouse tracking
var virtual_mouse := Vector2.ZERO   # viewport-space mouse, advanced by event.relative during a transform

# Numeric input
var numeric_input := ""
var is_numeric_active := false

# Constants
const TURNTABLE_SENSITIVITY := 0.005
const PRECISION_FACTOR := 0.1
const SNAP_ROT_DEGREES := 5.0
const SNAP_SCALE_STEP := 0.1
const SNAP_TRANS_STEP := 0.5
const EDGE_ON_THRESHOLD := 0.02

# Continuous grab: when the cursor reaches the edge of the 3D viewport it is warped to the
# opposite edge, so a transform can go on indefinitely (like Blender). Set to false to disable.
const CONTINUOUS_GRAB := true

# While an AnimationPlayer is playing, a plain S is left to Godot (its animation "Stop" shortcut)
# instead of starting a scale. Set to false to always use S for scale.
const YIELD_S_TO_ANIMATION := true

# MMB axis pick (like Blender): during G/R/S, press the middle mouse button and the axis that
# best matches the direction you have been moving the mouse gets locked.
# Set MMB_AXIS_FROM_CURSOR to true to use the direction from the object to the cursor instead
# ("point at the axis" style).
const MMB_AXIS_FROM_CURSOR := false
const MMB_MIN_MOVE := 8.0         # px: below this the direction is too small to decide
const MMB_MIN_AXIS_LENGTH := 0.03  # axes shorter than this on screen (looking straight down them) are skipped
const WRAP_MARGIN := 4.0          # px from the viewport edge that triggers a wrap
const WARP_MATCH_RADIUS := 6.0    # px: a motion event this close to the warp target is our own warp

# Rotation rate: mouse movement is converted to angle using a constant reference radius (px,
# before editor scaling) taken from where the cursor started, clamped to this range.
const ROT_MIN_RADIUS := 60.0
const ROT_MAX_RADIUS := 250.0

# Overlay gizmo
const GIZMO_OFFSET := 70.0     # px below the selection pivot
const GIZMO_RADIUS := 26.0     # px length of a full-length axis line
const AXIS_COLORS := [Color(0.93, 0.28, 0.35), Color(0.55, 0.83, 0.25), Color(0.25, 0.55, 0.95)]

var constraint_indices: Array[int] = []   # which of X/Y/Z (0/1/2) are constrained
var last_camera: Camera3D = null
var active_viewport: SubViewport = null   # viewport the current transform started in
var local_space_button: Button = null      # Godot's "Use Local Space" toolbar toggle (found lazily)
var local_space_next_search_ms := 0       # throttle for failed lookups
var local_space_warned := false
var warp_pending := false                 # true while waiting for the motion event caused by our own warp
var warp_target := Vector2.ZERO
var warp_jump_limit := Vector2.ZERO
var warp_deadline_ms := 0
var plane_partner_override := -1          # MMB: forces the in-plane partner axis (0/1/2), -1 = automatic
# Reset modal (after Alt+G / Alt+R / Alt+S): X / Y / Z toggle which axes are reset
enum ResetKind { NONE, POSITION, ROTATION, SCALE }
var reset_kind := ResetKind.NONE
var reset_nodes: Array[Node3D] = []
var reset_originals: Dictionary = {}      # Node3D -> Vector3 (value of the property before the reset)
var reset_axes: Array[int] = []           # toggled axes (0/1/2); empty = reset all three
var overlays: Array[Control] = []          # viewport overlay controls, captured in the draw callback


func _handles(object: Object) -> bool:
	return object is Node3D


func _exit_tree() -> void:
	if current_op != TransformType.NONE:
		_cancel_transform()
	if reset_kind != ResetKind.NONE:
		_finish_reset(false)


# -----------------------------------------------------------------
# INPUT ENTRY POINT
#
# Everything (keys, mouse motion, clicks) is read in _input instead of
# _forward_3d_gui_input. The forwarded GUI events are only delivered while the
# 3D viewport has focus, so the first G/R/S after clicking elsewhere (Scene
# dock, Inspector...) started a transform that never received mouse motion
# until an RMB click gave the viewport focus.
#
# During a transform the mouse position is advanced with event.relative from
# a start position, so start and updates always share one coordinate space.
# -----------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# The reset modal gets first look at every event; it returns true when it consumed it.
	# Otherwise the event carries on (so e.g. G right after Alt+G starts a move).
	if reset_kind != ResetKind.NONE and _input_reset_modal(event):
		return

	if current_op == TransformType.NONE:
		_input_idle(event)
	else:
		_input_active(event)


func _input_idle(event: InputEvent) -> void:
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return

	# Don't start while flying with RMB or typing in a text field
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return

	var vp := _get_hovered_viewport()
	if vp == null or vp.get_camera_3d() == null:
		return

	active_viewport = vp
	var handled := _handle_idle_key(vp.get_camera_3d(), key_event)
	if current_op == TransformType.NONE:
		active_viewport = null   # nothing started (Alt+G reset, no selection...)
	if handled:
		get_viewport().set_input_as_handled()


func _input_active(event: InputEvent) -> void:
	if not is_instance_valid(active_viewport) or active_viewport.get_camera_3d() == null:
		_cancel_transform()
		return
	var camera := active_viewport.get_camera_3d()

	# Mouse motion
	var motion := event as InputEventMouseMotion
	if motion != null:
		get_viewport().set_input_as_handled()

		if warp_pending and Time.get_ticks_msec() > warp_deadline_ms:
			warp_pending = false   # the warp produced no event (platform dependent)

		# Ignore the motion event generated by our own warp: it is a jump, not user movement.
		if warp_pending:
			var is_warp_event := motion.position.distance_to(warp_target) <= WARP_MATCH_RADIUS \
				or absf(motion.relative.x) > warp_jump_limit.x or absf(motion.relative.y) > warp_jump_limit.y
			if is_warp_event:
				warp_pending = false
				return

		virtual_mouse += motion.relative
		_accumulate_rotation(motion.relative)
		if not is_numeric_active:
			_process_mouse_transform(camera, virtual_mouse)

		if CONTINUOUS_GRAB:
			_wrap_mouse(motion.position)
		return

	# Mouse clicks: LMB confirm, RMB cancel
	var button := event as InputEventMouseButton
	if button != null:
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_confirm_transform()
			get_viewport().set_input_as_handled()
		elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_transform()
			get_viewport().set_input_as_handled()
		elif button.pressed and button.button_index == MOUSE_BUTTON_MIDDLE:
			# In a plane lock MMB swaps the plane; otherwise it picks the axis you point at
			if not _cycle_plane_partner(camera):
				_pick_axis_with_mmb(camera)
			get_viewport().set_input_as_handled()
		return

	# Keys
	var key_event := event as InputEventKey
	if key_event != null and key_event.pressed and not key_event.echo:
		if _handle_active_key(camera, key_event):
			get_viewport().set_input_as_handled()


# Continuous grab. Only the real cursor is moved: the transform is driven by the accumulated
# event.relative (virtual_mouse), so wrapping never changes the transform itself.
func _wrap_mouse(mouse: Vector2) -> void:
	if warp_pending or not is_instance_valid(active_viewport):
		return
	var container := active_viewport.get_parent() as Control
	if container == null:
		return

	var rect := container.get_global_rect()
	var margin := WRAP_MARGIN * EditorInterface.get_editor_scale()
	var target := mouse

	if mouse.x <= rect.position.x + margin:
		target.x = rect.end.x - margin * 3.0
	elif mouse.x >= rect.end.x - margin:
		target.x = rect.position.x + margin * 3.0

	if mouse.y <= rect.position.y + margin:
		target.y = rect.end.y - margin * 3.0
	elif mouse.y >= rect.end.y - margin:
		target.y = rect.position.y + margin * 3.0

	if target == mouse:
		return

	wrap_offset += target - mouse

	warp_target = target
	warp_jump_limit = rect.size * 0.4
	warp_pending = true
	warp_deadline_ms = Time.get_ticks_msec() + 150
	# warp_mouse takes window pixels; the editor may scale its UI
	Input.warp_mouse(get_viewport().get_final_transform() * target)


# True if any AnimationPlayer in the edited scene is currently playing.
func _is_animation_playing() -> bool:
	var root := EditorInterface.get_edited_scene_root()
	return root != null and _find_playing_animation(root)


func _find_playing_animation(node: Node) -> bool:
	if node is AnimationPlayer and (node as AnimationPlayer).is_playing():
		return true
	for child in node.get_children():
		if _find_playing_animation(child):
			return true
	return false


# The 3D editor viewport (of up to four) currently under the mouse, or null.
func _get_hovered_viewport() -> SubViewport:
	for i in 4:
		var vp := EditorInterface.get_editor_viewport_3d(i)
		if vp == null:
			continue
		var container := vp.get_parent() as Control
		if container == null or not container.is_visible_in_tree():
			continue
		if container.get_global_rect().has_point(container.get_global_mouse_position()):
			return vp
	return null


# Only used for the overlay camera and to swallow leftover mouse events.
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if current_op == TransformType.NONE:
		last_camera = camera
		return AFTER_GUI_INPUT_PASS
	return AFTER_GUI_INPUT_STOP if event is InputEventMouse else AFTER_GUI_INPUT_PASS


# -----------------------------------------------------------------
# KEY HANDLING
# -----------------------------------------------------------------

func _handle_idle_key(camera: Camera3D, event: InputEventKey) -> bool:
	var key := event.keycode

	# Never hijack Ctrl / Meta shortcuts (Ctrl+S save, etc.)
	if event.ctrl_pressed or event.meta_pressed:
		return false

	if event.alt_pressed:
		if event.shift_pressed:
			return false
		match key:
			KEY_G: return _start_reset(ResetKind.POSITION)
			KEY_R: return _start_reset(ResetKind.ROTATION)
			KEY_S: return _start_reset(ResetKind.SCALE)
		return false

	if event.shift_pressed:
		return false

	match key:
		KEY_G: return _start_op(camera, TransformType.TRANSLATE)
		KEY_R: return _start_op(camera, TransformType.ROTATE)
		KEY_S:
			if YIELD_S_TO_ANIMATION and _is_animation_playing():
				return false   # let Godot's animation "Stop" shortcut (S) handle it
			return _start_op(camera, TransformType.SCALE)
	return false


func _handle_active_key(camera: Camera3D, event: InputEventKey) -> bool:
	var key := event.keycode
	var plain := not (event.ctrl_pressed or event.alt_pressed or event.meta_pressed)

	if plain and key == KEY_G:
		_switch_op(camera, TransformType.TRANSLATE)
		return true
	if plain and key == KEY_S:
		_switch_op(camera, TransformType.SCALE)
		return true
	if plain and key == KEY_R:
		if current_op == TransformType.ROTATE:
			rot_submode = RotateSubMode.TURNTABLE if rot_submode == RotateSubMode.VIEW_PLANE else RotateSubMode.VIEW_PLANE
			_set_constraint(ConstraintStage.NONE, -1, camera)
			_recalculate(camera)
		else:
			_switch_op(camera, TransformType.ROTATE)
		return true

	if key >= KEY_X and key <= KEY_Z:
		_cycle_constraint(key - KEY_X, event.shift_pressed, camera)
		return true

	if _is_numeric_key(key):
		_handle_numeric_input(key, camera)
		return true

	if key == KEY_ENTER or key == KEY_KP_ENTER or key == KEY_SPACE:
		_confirm_transform()
		return true
	if key == KEY_ESCAPE:
		_cancel_transform()
		return true

	return false


func _is_numeric_key(key: Key) -> bool:
	return (key >= KEY_0 and key <= KEY_9) or (key >= KEY_KP_0 and key <= KEY_KP_9) \
		or key == KEY_PERIOD or key == KEY_KP_PERIOD \
		or key == KEY_MINUS or key == KEY_KP_SUBTRACT \
		or key == KEY_BACKSPACE


# -----------------------------------------------------------------
# RESET TRANSFORMS (Alt+G, Alt+R, Alt+S)
# -----------------------------------------------------------------

# After Alt+G / Alt+R / Alt+S the reset is applied to all axes at once and a small modal opens:
#   X / Y / Z  toggle that axis. With at least one axis toggled ONLY those axes are reset (the
#              others return to their original values); toggling every axis off again goes back
#              to the full reset, so pressing an axis twice undoes it.
#   Enter / Space / click / any other key  confirm      Esc  cancel (restores everything)
# Rotation is reset per Euler component, like the rotation fields in the Inspector.

func _reset_property(kind: ResetKind) -> String:
	match kind:
		ResetKind.POSITION: return "position"
		ResetKind.ROTATION: return "rotation"
	return "scale"


func _reset_title(kind: ResetKind) -> String:
	match kind:
		ResetKind.POSITION: return "Location"
		ResetKind.ROTATION: return "Rotation"
	return "Scale"


func _start_reset(kind: ResetKind) -> bool:
	var nodes: Array[Node3D] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is Node3D:
			nodes.append(node)
	if nodes.is_empty():
		return false

	reset_kind = kind
	reset_nodes = nodes
	reset_axes.clear()
	reset_originals.clear()
	var prop := _reset_property(kind)
	for node in nodes:
		reset_originals[node] = node.get(prop)
	_apply_reset()
	return true


func _apply_reset() -> void:
	var prop := _reset_property(reset_kind)
	var neutral := 1.0 if reset_kind == ResetKind.SCALE else 0.0
	for node in reset_nodes:
		if not is_instance_valid(node):
			continue
		var value: Vector3 = reset_originals[node]
		if reset_axes.is_empty():
			value = Vector3(neutral, neutral, neutral)
		else:
			for axis in reset_axes:
				value[axis] = neutral
		node.set(prop, value)
	_refresh_overlays()


func _reset_axes_text() -> String:
	if reset_axes.is_empty():
		return "all axes"
	var sorted_axes := reset_axes.duplicate()
	sorted_axes.sort()
	var letters: PackedStringArray = []
	for axis in sorted_axes:
		letters.append(AXIS_NAMES[axis])
	return " ".join(letters)


# Returns true when the event was consumed by the modal.
func _input_reset_modal(event: InputEvent) -> bool:
	var key_event := event as InputEventKey
	var button := event as InputEventMouseButton

	if button != null:
		if not button.pressed or button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			return false
		_finish_reset(true)   # a click confirms and still reaches the editor
		return false

	if key_event == null:
		return false   # mouse motion etc.: the modal stays open

	var keycode := key_event.keycode
	if keycode in [KEY_ALT, KEY_SHIFT, KEY_CTRL, KEY_META, KEY_CAPSLOCK]:
		return false   # modifier keys on their own don't end the modal

	var is_axis_key := keycode == KEY_X or keycode == KEY_Y or keycode == KEY_Z
	if not key_event.pressed:
		return false
	if key_event.echo:
		if is_axis_key:
			get_viewport().set_input_as_handled()
			return true
		return false

	# Typing in a text field or hovering another panel: confirm and leave the event alone
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or _get_hovered_viewport() == null:
		_finish_reset(true)
		return false

	if is_axis_key and not (key_event.ctrl_pressed or key_event.meta_pressed):
		var axis := keycode - KEY_X
		var idx := reset_axes.find(axis)
		if idx >= 0:
			reset_axes.remove_at(idx)   # pressed twice: back out of that axis
		else:
			reset_axes.append(axis)
		_apply_reset()
		get_viewport().set_input_as_handled()
		return true

	if keycode == KEY_ESCAPE:
		_finish_reset(false)
		get_viewport().set_input_as_handled()
		return true

	if keycode == KEY_ENTER or keycode == KEY_KP_ENTER or keycode == KEY_SPACE:
		_finish_reset(true)
		get_viewport().set_input_as_handled()
		return true

	# Any other key confirms; it then continues as normal input (Alt+R after Alt+G starts a new reset)
	_finish_reset(true)
	return false


func _finish_reset(commit: bool) -> void:
	if reset_kind == ResetKind.NONE:
		return
	var prop := _reset_property(reset_kind)

	if commit:
		var changed := false
		for node in reset_nodes:
			if is_instance_valid(node) and not (node.get(prop) as Vector3).is_equal_approx(reset_originals[node]):
				changed = true
				break
		if changed:
			var action_name := "Clear " + _reset_title(reset_kind)
			if not reset_axes.is_empty():
				action_name += " " + _reset_axes_text()
			var ur := get_undo_redo()
			ur.create_action(action_name)
			for node in reset_nodes:
				if is_instance_valid(node):
					ur.add_do_property(node, prop, node.get(prop))
					ur.add_undo_property(node, prop, reset_originals[node])
			ur.commit_action(false)   # already applied live
	else:
		for node in reset_nodes:
			if is_instance_valid(node):
				node.set(prop, reset_originals[node])

	reset_kind = ResetKind.NONE
	reset_nodes.clear()
	reset_originals.clear()
	reset_axes.clear()
	_refresh_overlays()


# -----------------------------------------------------------------
# CORE TRANSFORM LOGIC
# -----------------------------------------------------------------

func _process_mouse_transform(camera: Camera3D, mouse_pos: Vector2) -> void:
	var is_snap := Input.is_key_pressed(KEY_CTRL)
	var is_precision := Input.is_key_pressed(KEY_SHIFT)

	match current_op:
		TransformType.TRANSLATE:
			_apply_translation(camera, mouse_pos, is_snap, is_precision)
		TransformType.ROTATE:
			_apply_rotation(camera, mouse_pos, is_snap, is_precision)
		TransformType.SCALE:
			_apply_scale(camera, mouse_pos, is_snap, is_precision)

	_refresh_overlays()


# --- 1. TRANSLATE (G) ---

func _apply_translation(camera: Camera3D, mouse_pos: Vector2, is_snap: bool, is_precision: bool) -> void:
	# Single axis: slide along the axis so the object follows the cursor ON SCREEN. Projecting a
	# camera-plane movement onto the axis (the old way) made foreshortened axes crawl: an axis
	# that looks 36% long on screen only moved 36% as far as the cursor.
	if constraint_axes.size() == 1:
		var axis := constraint_axes[0]
		var mag := _axis_param(camera, mouse_pos, axis) - _axis_param(camera, initial_mouse_pos, axis)
		if is_precision:
			mag *= PRECISION_FACTOR
		if is_snap:
			mag = snappedf(mag, SNAP_TRANS_STEP)
		_move_selection(axis * mag)
		return

	var delta = null

	# Plane constraint: intersect with the constraint plane itself for exact tracking
	if constraint_axes.size() == 2:
		delta = _plane_delta(camera, mouse_pos, Plane(_constraint_normal(), pivot_point))

	# Otherwise (or if the plane is edge-on): plane facing the camera at pivot depth
	if delta == null:
		var cam_forward := -camera.global_transform.basis.z.normalized()
		delta = _plane_delta(camera, mouse_pos, Plane(cam_forward, pivot_point))

	if delta == null:
		return

	var delta_3d: Vector3 = delta
	if is_precision:
		delta_3d *= PRECISION_FACTOR

	if constraint_axes.is_empty():
		if is_snap:
			delta_3d = delta_3d.snapped(Vector3.ONE * SNAP_TRANS_STEP)
	else:
		var result := Vector3.ZERO
		for axis in constraint_axes:
			var mag := delta_3d.dot(axis)
			if is_snap:
				mag = snappedf(mag, SNAP_TRANS_STEP)
			result += axis * mag
		delta_3d = result

	_move_selection(delta_3d)


func _move_selection(delta_3d: Vector3) -> void:
	for node in selected_nodes:
		if is_instance_valid(node):
			var init_g: Transform3D = initial_global_transforms[node]
			node.global_position = init_g.origin + delta_3d


# Position (in world units from the pivot) on the axis line that is closest to the mouse ray.
# Subtracting the value for the initial mouse position gives a movement that tracks the cursor
# along the axis as seen on screen. Looking almost straight down the axis the problem becomes
# ill-conditioned, so the divisor is clamped (the axis then moves at most ~10x the cursor).
func _axis_param(camera: Camera3D, mouse: Vector2, axis: Vector3) -> float:
	var ray_origin := camera.project_ray_origin(mouse)
	var ray_dir := camera.project_ray_normal(mouse)
	var w := pivot_point - ray_origin
	var b := axis.dot(ray_dir)
	var denom := maxf(1.0 - b * b, 0.01)
	return (b * ray_dir.dot(w) - axis.dot(w)) / denom


# Returns Vector3 (hit_current - hit_initial) or null if the plane is edge-on / missed.
func _plane_delta(camera: Camera3D, mouse_pos: Vector2, plane: Plane) -> Variant:
	var dir_init := camera.project_ray_normal(initial_mouse_pos)
	var dir_curr := camera.project_ray_normal(mouse_pos)
	if absf(plane.normal.dot(dir_init)) < EDGE_ON_THRESHOLD or absf(plane.normal.dot(dir_curr)) < EDGE_ON_THRESHOLD:
		return null

	var hit_init = plane.intersects_ray(camera.project_ray_origin(initial_mouse_pos), dir_init)
	var hit_curr = plane.intersects_ray(camera.project_ray_origin(mouse_pos), dir_curr)
	# Compare with null: a hit at exactly (0,0,0) is a valid hit but is "falsy" in GDScript.
	if hit_init == null or hit_curr == null:
		return null
	return (hit_curr as Vector3) - (hit_init as Vector3)


# --- 2. ROTATE (R) ---

func _apply_rotation(camera: Camera3D, mouse_pos: Vector2, is_snap: bool, is_precision: bool) -> void:
	var axis_vec := _constraint_normal()

	if axis_vec != Vector3.ZERO:
		# Axis (or plane-normal) rotation, direction corrected for the viewing side
		var angle := _screen_angle(mouse_pos, is_snap, is_precision)
		var view_axis := -camera.global_transform.basis.z.normalized()
		if axis_vec.dot(view_axis) < 0.0:
			angle = -angle
		_apply_rotation_matrix(Basis(axis_vec, angle))

	elif rot_submode == RotateSubMode.TURNTABLE:
		# Yaw around world UP, pitch around camera right
		var total_delta := mouse_pos - initial_mouse_pos
		if is_precision:
			total_delta *= PRECISION_FACTOR
		var yaw := total_delta.x * TURNTABLE_SENSITIVITY
		var pitch := total_delta.y * TURNTABLE_SENSITIVITY
		if is_snap:
			yaw = deg_to_rad(snappedf(rad_to_deg(yaw), SNAP_ROT_DEGREES))
			pitch = deg_to_rad(snappedf(rad_to_deg(pitch), SNAP_ROT_DEGREES))
		var rot_yaw := Basis(Vector3.UP, yaw)
		var rot_pitch := Basis(camera.global_transform.basis.x.normalized(), pitch)
		_apply_rotation_matrix(rot_yaw * rot_pitch)

	else:
		# View-plane rotation
		var angle := _screen_angle(mouse_pos, is_snap, is_precision)
		var view_axis := -camera.global_transform.basis.z.normalized()
		_apply_rotation_matrix(Basis(view_axis, angle))


# The angle is accumulated per mouse event in _accumulate_rotation(); here we only snap it.
func _screen_angle(_mouse_pos: Vector2, is_snap: bool, _is_precision: bool) -> float:
	var angle := rot_accum
	if is_snap:
		angle = deg_to_rad(snappedf(rad_to_deg(angle), SNAP_ROT_DEGREES))
	return angle


# Turns one mouse movement into a rotation increment around the screen pivot.
# - The direction comes from the REAL cursor position (virtual_mouse + wrap_offset), so it
#   is unaffected by how far the unwrapped virtual mouse has drifted after wraps.
# - The size is the tangential movement divided by a CONSTANT reference radius, so the
#   rate is the same everywhere on screen (no speed change after a wrap) and it fades
#   smoothly to zero near the pivot instead of exploding or flipping.
func _accumulate_rotation(relative: Vector2) -> void:
	var real_pos := virtual_mouse + wrap_offset
	var r := (real_pos - relative * 0.5) - screen_pivot
	var ref := rot_ref_radius
	var delta := (r.x * relative.y - r.y * relative.x) / (ref * maxf(r.length(), ref))
	if Input.is_key_pressed(KEY_SHIFT):
		delta *= PRECISION_FACTOR
	rot_accum += delta


func _apply_rotation_matrix(rot_basis: Basis) -> void:
	for node in selected_nodes:
		if is_instance_valid(node):
			var init_g: Transform3D = initial_global_transforms[node]
			var new_basis := rot_basis * init_g.basis
			var new_origin := pivot_point + (rot_basis * (init_g.origin - pivot_point))
			node.global_transform = Transform3D(new_basis, new_origin)


# --- 3. SCALE (S) ---

func _apply_scale(_camera: Camera3D, mouse_pos: Vector2, is_snap: bool, is_precision: bool) -> void:
	var init_dist := maxf(20.0, (initial_mouse_pos - screen_pivot).length())
	var curr_dist := (mouse_pos - screen_pivot).length()
	var factor := curr_dist / init_dist

	if is_precision:
		factor = 1.0 + (factor - 1.0) * PRECISION_FACTOR
	if is_snap:
		factor = snappedf(factor, SNAP_SCALE_STEP)

	_apply_scale_factor(factor)


# Builds a matrix that scales by `factor` along every constraint axis
# (uniformly in all directions when unconstrained).
func _scale_matrix(factor: float) -> Basis:
	if constraint_axes.is_empty():
		return Basis.from_scale(Vector3.ONE * factor)

	var units: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var cols: Array[Vector3] = []
	for e in units:
		var v := e
		for axis in constraint_axes:
			v += axis * (axis.dot(e) * (factor - 1.0))
		cols.append(v)
	return Basis(cols[0], cols[1], cols[2])


func _apply_scale_factor(factor: float) -> void:
	var m := _scale_matrix(factor)
	for node in selected_nodes:
		if not is_instance_valid(node):
			continue
		var init_g: Transform3D = initial_global_transforms[node]
		var new_basis := m * init_g.basis
		var new_origin := pivot_point + m * (init_g.origin - pivot_point)
		node.global_transform = Transform3D(new_basis, new_origin)


# -----------------------------------------------------------------
# AXIS / PLANE CONSTRAINTS
# -----------------------------------------------------------------

func _cycle_constraint(axis_idx: int, exclude: bool, camera: Camera3D) -> void:
	# "Use Local Space" ON inverts the order in which the spaces are visited
	var local_first := _is_local_space_enabled()
	plane_partner_override = -1
	var next: ConstraintStage

	if exclude:
		var first := ConstraintStage.EXCLUDE_LOCAL if local_first else ConstraintStage.EXCLUDE_GLOBAL
		var second := ConstraintStage.EXCLUDE_GLOBAL if local_first else ConstraintStage.EXCLUDE_LOCAL
		next = first
		if constraint_key == axis_idx:
			if constraint_stage == first:
				next = second
			elif constraint_stage == second:
				next = ConstraintStage.NONE
	else:
		# Both spaces get an axis stage and a plane stage; the toggle only decides which space goes first
		var sequence: Array[ConstraintStage] = []
		if local_first:
			sequence = [
				ConstraintStage.LOCAL_AXIS, ConstraintStage.LOCAL_VIEW_PLANE,
				ConstraintStage.GLOBAL_AXIS, ConstraintStage.VIEW_PLANE,
			]
		else:
			sequence = [
				ConstraintStage.GLOBAL_AXIS, ConstraintStage.VIEW_PLANE,
				ConstraintStage.LOCAL_AXIS, ConstraintStage.LOCAL_VIEW_PLANE,
			]
		next = sequence[0]
		if constraint_key == axis_idx:
			var idx := sequence.find(constraint_stage)
			if idx >= 0:
				next = sequence[idx + 1] if idx + 1 < sequence.size() else ConstraintStage.NONE

	_set_constraint(next, axis_idx if next != ConstraintStage.NONE else -1, camera)
	_recalculate(camera)


func _stage_is_local(stage: ConstraintStage) -> bool:
	return stage == ConstraintStage.LOCAL_AXIS \
		or stage == ConstraintStage.LOCAL_VIEW_PLANE \
		or stage == ConstraintStage.EXCLUDE_LOCAL


# -----------------------------------------------------------------
# GODOT "USE LOCAL SPACE" TOGGLE
#
# The editor doesn't expose this state through the API, so we find the toolbar
# button in the 3D editor. It is identified by its shortcut ("spatial_editor/local_coords"),
# which works in any editor language and survives key remapping.
# -----------------------------------------------------------------

func _is_local_space_enabled() -> bool:
	if not is_instance_valid(local_space_button):
		local_space_button = null
		if Time.get_ticks_msec() >= local_space_next_search_ms:
			local_space_button = _find_local_space_button(EditorInterface.get_editor_main_screen())
			if local_space_button == null:
				local_space_next_search_ms = Time.get_ticks_msec() + 2000
				if not local_space_warned:
					local_space_warned = true
					push_warning("Blender Transform: couldn't find the 'Use Local Space' toolbar button; assuming it is off.")
	return local_space_button != null and local_space_button.button_pressed


# Collects every toggle button that looks like "Use Local Space" and prefers a visible one.
# The 2D editor has a matching hidden button that is always pressed, so it is skipped.
func _find_local_space_button(root: Node) -> Button:
	var candidates: Array[Button] = []
	_collect_local_space_buttons(root, candidates)

	var best: Button = null
	for candidate in candidates:
		if candidate.is_visible_in_tree():
			best = candidate
			break
	if best == null and not candidates.is_empty():
		best = candidates[0]

	return best


func _collect_local_space_buttons(node: Node, out: Array[Button]) -> void:
	if node is Button and _is_local_space_button(node as Button):
		out.append(node as Button)
	for child in node.get_children():
		if child is SubViewport or child.get_class() == "CanvasItemEditor":
			continue   # skip rendered scene content and the 2D editor
		_collect_local_space_buttons(child, out)


func _is_local_space_button(button: Button) -> bool:
	if not button.toggle_mode or button.shortcut == null:
		return false
	var settings := EditorInterface.get_editor_settings()
	for shortcut_event in button.shortcut.events:
		if settings.is_shortcut("spatial_editor/local_coords", shortcut_event):
			return true
	# Fallback if the shortcut was unbound: match the English name
	return button.shortcut.resource_name.contains("Local Space") or button.tooltip_text.contains("Local Space")


func _set_constraint(stage: ConstraintStage, key: int, camera: Camera3D) -> void:
	constraint_stage = stage
	constraint_key = key
	_rebuild_constraint(camera)


func _rebuild_constraint(camera: Camera3D) -> void:
	constraint_axes.clear()
	constraint_indices.clear()
	constraint_label = ""
	if constraint_stage == ConstraintStage.NONE or constraint_key < 0:
		return

	var use_local := _stage_is_local(constraint_stage)
	var basis := Basis.IDENTITY
	if use_local and not selected_nodes.is_empty():
		basis = (initial_global_transforms[selected_nodes[0]] as Transform3D).basis.orthonormalized()
	var axes: Array[Vector3] = [basis.x.normalized(), basis.y.normalized(), basis.z.normalized()]

	var k := constraint_key
	var a := (k + 1) % 3
	var b := (k + 2) % 3
	var space := "local" if use_local else "global"

	match constraint_stage:
		ConstraintStage.GLOBAL_AXIS, ConstraintStage.LOCAL_AXIS:
			constraint_axes.append(axes[k])
			constraint_indices.append(k)
			constraint_label = "%s (%s)" % [AXIS_NAMES[k], space]

		ConstraintStage.VIEW_PLANE, ConstraintStage.LOCAL_VIEW_PLANE:
			# Of the two other axes, the one pointing most along the view direction
			# becomes the plane normal; the other one is the in-plane partner.
			var view_dir := -camera.global_transform.basis.z.normalized()
			var normal_idx := a if absf(axes[a].dot(view_dir)) >= absf(axes[b].dot(view_dir)) else b
			var partner := b if normal_idx == a else a
			if plane_partner_override >= 0 and plane_partner_override != k:
				partner = plane_partner_override   # chosen with the middle mouse button
			constraint_axes.append(axes[k])
			constraint_axes.append(axes[partner])
			constraint_indices.append(k)
			constraint_indices.append(partner)
			constraint_label = "%s%s plane (%s, view-dependent)" % [AXIS_NAMES[k], AXIS_NAMES[partner], space]

		ConstraintStage.EXCLUDE_GLOBAL, ConstraintStage.EXCLUDE_LOCAL:
			constraint_axes.append(axes[a])
			constraint_axes.append(axes[b])
			constraint_indices.append(a)
			constraint_indices.append(b)
			constraint_label = "%s%s plane, excluding %s (%s)" % [AXIS_NAMES[a], AXIS_NAMES[b], AXIS_NAMES[k], space]

	print("Constraint: ", constraint_label)


# Middle mouse button while a plane containing the constrained axis is active: switch to the
# other plane that contains that axis (X: XY <-> XZ, Y: YX <-> YZ, Z: ZX <-> ZY).
func _cycle_plane_partner(camera: Camera3D) -> bool:
	if constraint_stage != ConstraintStage.VIEW_PLANE and constraint_stage != ConstraintStage.LOCAL_VIEW_PLANE:
		return false
	if constraint_indices.size() < 2:
		return false

	var current: int = constraint_indices[1]
	plane_partner_override = 3 - constraint_key - current   # the remaining axis (0 + 1 + 2 = 3)
	_rebuild_constraint(camera)
	_recalculate(camera)
	return true


# MMB axis pick. Compares the direction of the mouse with the on-screen DIRECTION of the three
# axes (global, or local when "Use Local Space" is on) and locks the closest one by angle.
# Short (foreshortened) axes are favoured slightly, so they are at least as easy to pick as long
# ones. Only an axis pointing straight at the camera, whose screen direction is meaningless,
# is skipped.
func _pick_axis_with_mmb(camera: Camera3D) -> bool:
	var min_move := MMB_MIN_MOVE * EditorInterface.get_editor_scale()

	# Direction: how the mouse has moved since the start (unwrapped, so wraps don't matter)...
	var dir := virtual_mouse - initial_mouse_pos
	# ...or, if it hasn't moved, / if requested: from the object towards the real cursor
	if MMB_AXIS_FROM_CURSOR or dir.length() < min_move:
		dir = (virtual_mouse + wrap_offset) - screen_pivot
	if dir.length() < min_move:
		return false
	dir = dir.normalized()

	var local_first := _is_local_space_enabled()
	var basis := Basis.IDENTITY
	if local_first and not selected_nodes.is_empty():
		basis = (initial_global_transforms[selected_nodes[0]] as Transform3D).basis.orthonormalized()
	var axes: Array[Vector3] = [basis.x, basis.y, basis.z]

	var cam_basis := camera.global_transform.basis
	var best := -1
	var best_score := 0.0
	for i in 3:
		# Screen direction of the axis (camera right = +x, camera up = -y); length = foreshortening
		var screen_dir := Vector2(axes[i].dot(cam_basis.x), -axes[i].dot(cam_basis.y))
		var axis_len := screen_dir.length()
		if axis_len < MMB_MIN_AXIS_LENGTH:
			continue   # points (almost) straight at / away from the camera: no usable direction
		# Angle between the mouse direction and the axis line (0 = same line). Short axes get a
		# smaller penalty, which widens the range of directions that select them: the shorter an
		# axis looks, the less precisely you can aim along it.
		var angle := acos(clampf(absf(dir.dot(screen_dir / axis_len)), 0.0, 1.0))
		var score := 1.0 / (0.01 + angle * (0.5 + 0.5 * minf(axis_len, 1.0)))
		if score > best_score:
			best_score = score
			best = i
	if best < 0:
		return false

	_set_constraint(ConstraintStage.LOCAL_AXIS if local_first else ConstraintStage.GLOBAL_AXIS, best, camera)
	_recalculate(camera)
	return true


func _constraint_normal() -> Vector3:
	if constraint_axes.size() == 2:
		return constraint_axes[0].cross(constraint_axes[1]).normalized()
	if constraint_axes.size() == 1:
		return constraint_axes[0]
	return Vector3.ZERO


# -----------------------------------------------------------------
# NUMERIC INPUT
# -----------------------------------------------------------------

func _handle_numeric_input(key: Key, camera: Camera3D) -> void:
	if key == KEY_BACKSPACE:
		if numeric_input.length() > 0:
			numeric_input = numeric_input.substr(0, numeric_input.length() - 1)
	elif key == KEY_MINUS or key == KEY_KP_SUBTRACT:
		numeric_input = numeric_input.substr(1) if numeric_input.begins_with("-") else "-" + numeric_input
	elif key == KEY_PERIOD or key == KEY_KP_PERIOD:
		if not numeric_input.contains("."):
			numeric_input += "."
	else:
		if key >= KEY_0 and key <= KEY_9:
			numeric_input += str(key - KEY_0)
		elif key >= KEY_KP_0 and key <= KEY_KP_9:
			numeric_input += str(key - KEY_KP_0)

	is_numeric_active = not (numeric_input.is_empty() or numeric_input == "-")
	_recalculate(camera)


# Numeric behaviour:
#   Translate : distance along the axis (first axis of a plane); free = along view direction
#   Rotate    : degrees around axis / plane normal; free = around the view axis
#   Scale     : factor along the axis / both plane axes; free = uniform
func _apply_numeric(camera: Camera3D) -> void:
	var val := numeric_input.to_float()
	var view_axis := -camera.global_transform.basis.z.normalized()

	match current_op:
		TransformType.TRANSLATE:
			var dir := constraint_axes[0] if not constraint_axes.is_empty() else view_axis
			var delta := dir * val
			for node in selected_nodes:
				if is_instance_valid(node):
					node.global_position = (initial_global_transforms[node] as Transform3D).origin + delta
		TransformType.ROTATE:
			var axis_vec := _constraint_normal()
			if axis_vec == Vector3.ZERO:
				axis_vec = view_axis
			_apply_rotation_matrix(Basis(axis_vec, deg_to_rad(val)))
		TransformType.SCALE:
			_apply_scale_factor(val)

	_refresh_overlays()


func _recalculate(camera: Camera3D) -> void:
	if is_numeric_active:
		_apply_numeric(camera)
	else:
		_process_mouse_transform(camera, _current_mouse())


func _current_mouse() -> Vector2:
	return virtual_mouse


# Mouse position inside the active viewport, used once when a transform starts.
func _viewport_mouse_position() -> Vector2:
	if is_instance_valid(active_viewport) and active_viewport.get_parent() is Control:
		return (active_viewport.get_parent() as Control).get_local_mouse_position()
	return Vector2.ZERO


# -----------------------------------------------------------------
# LIFECYCLE & UNDO/REDO
# -----------------------------------------------------------------

func _start_op(camera: Camera3D, new_op: TransformType) -> bool:
	var nodes: Array[Node3D] = []
	# Top-level selection only, so children of selected parents aren't transformed twice
	for node in EditorInterface.get_selection().get_top_selected_nodes():
		if node is Node3D:
			nodes.append(node)

	if nodes.is_empty():
		return false

	selected_nodes = nodes
	initial_local_transforms.clear()
	initial_global_transforms.clear()

	var sum_pos := Vector3.ZERO
	for node in selected_nodes:
		initial_local_transforms[node] = node.transform
		initial_global_transforms[node] = node.global_transform
		sum_pos += node.global_position
	pivot_point = sum_pos / float(selected_nodes.size())

	virtual_mouse = _viewport_mouse_position()
	_begin_op(camera, new_op)
	return true


func _switch_op(camera: Camera3D, new_op: TransformType) -> void:
	_reset_to_initial()
	_begin_op(camera, new_op)


# Shared by start and switch: re-captures the mouse reference so the new
# operation always starts from where the cursor is right now.
func _begin_op(camera: Camera3D, new_op: TransformType) -> void:
	last_camera = camera
	virtual_mouse += wrap_offset   # restart from where the cursor really is
	wrap_offset = Vector2.ZERO
	screen_pivot = camera.unproject_position(pivot_point)
	initial_mouse_pos = _current_mouse()
	var init_dir := initial_mouse_pos - screen_pivot
	initial_angle_offset = atan2(init_dir.y, init_dir.x)
	angle_prev_mouse = initial_mouse_pos
	rot_accum = 0.0
	rot_ref_radius = clampf((initial_mouse_pos - screen_pivot).length(), ROT_MIN_RADIUS, ROT_MAX_RADIUS) * EditorInterface.get_editor_scale()
	plane_partner_override = -1

	current_op = new_op
	rot_submode = RotateSubMode.VIEW_PLANE
	numeric_input = ""
	is_numeric_active = false
	_set_constraint(ConstraintStage.NONE, -1, camera)
	_recalculate(camera)


func _confirm_transform() -> void:
	var changed := false
	for node in selected_nodes:
		if is_instance_valid(node) and not node.transform.is_equal_approx(initial_local_transforms[node]):
			changed = true
			break

	if changed:
		var ur := get_undo_redo()
		var op_name := "Translate" if current_op == TransformType.TRANSLATE else ("Rotate" if current_op == TransformType.ROTATE else "Scale")
		ur.create_action("Blender-Style " + op_name)
		for node in selected_nodes:
			if is_instance_valid(node):
				ur.add_do_property(node, "transform", node.transform)
				ur.add_undo_property(node, "transform", initial_local_transforms[node])
		ur.commit_action(false)  # already applied live

	_cleanup()


func _cancel_transform() -> void:
	_reset_to_initial()
	_cleanup()


func _reset_to_initial() -> void:
	for node in selected_nodes:
		if is_instance_valid(node):
			node.transform = initial_local_transforms[node]


func _cleanup() -> void:
	current_op = TransformType.NONE
	rot_submode = RotateSubMode.VIEW_PLANE
	constraint_stage = ConstraintStage.NONE
	constraint_key = -1
	constraint_axes.clear()
	active_viewport = null
	warp_pending = false
	wrap_offset = Vector2.ZERO
	plane_partner_override = -1
	constraint_indices.clear()
	constraint_label = ""
	numeric_input = ""
	is_numeric_active = false
	selected_nodes.clear()
	initial_local_transforms.clear()
	initial_global_transforms.clear()
	_refresh_overlays()


# -----------------------------------------------------------------
# OVERLAY: axis gizmo (local / global) + constrained-axis letters
# -----------------------------------------------------------------

# Now that mouse motion is consumed in _input, the 3D viewport no longer gets
# events that make it redraw its overlay, so request the redraw ourselves.
func _refresh_overlays() -> void:
	update_overlays()
	for i in range(overlays.size() - 1, -1, -1):
		var overlay := overlays[i]
		if is_instance_valid(overlay):
			overlay.queue_redraw()
		else:
			overlays.remove_at(i)


func _current_pivot() -> Vector3:
	var sum := Vector3.ZERO
	var count := 0
	for node in selected_nodes:
		if is_instance_valid(node):
			sum += node.global_position
			count += 1
	return sum / float(count) if count > 0 else pivot_point


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if not overlays.has(overlay):
		overlays.append(overlay)

	if reset_kind != ResetKind.NONE:
		_draw_reset_hint(overlay)
		return

	if current_op == TransformType.NONE or selected_nodes.is_empty():
		return
	if last_camera == null or not is_instance_valid(last_camera):
		return

	var cam := last_camera
	var pivot := _current_pivot()
	if cam.is_position_behind(pivot):
		return

	var ui := EditorInterface.get_editor_scale()
	var radius := GIZMO_RADIUS * ui
	var margin := 24.0 * ui

	# Anchor: below the selection, kept inside the viewport
	var anchor := cam.unproject_position(pivot) + Vector2(0.0, GIZMO_OFFSET * ui)
	anchor.x = clampf(anchor.x, radius + margin, overlay.size.x - radius - margin)
	anchor.y = clampf(anchor.y, radius + margin, overlay.size.y - radius - 70.0 * ui)

	# Which space is being shown: local axes of the first selected node, else global
	var is_local := _stage_is_local(constraint_stage) if constraint_stage != ConstraintStage.NONE else _is_local_space_enabled()
	var basis := Basis.IDENTITY
	if is_local:
		basis = (initial_global_transforms[selected_nodes[0]] as Transform3D).basis.orthonormalized()

	var cam_basis := cam.global_transform.basis
	var forward := -cam_basis.z
	var axes: Array[Vector3] = [basis.x, basis.y, basis.z]

	# Draw far axes first so near ones end up on top
	var order: Array[int] = [0, 1, 2]
	order.sort_custom(func(a: int, b: int) -> bool: return axes[a].dot(forward) > axes[b].dot(forward))

	var has_constraint := not constraint_indices.is_empty()

	overlay.draw_circle(anchor, radius + 8.0 * ui, Color(0, 0, 0, 0.35))
	for i in order:
		# Screen-space direction of the axis (camera right = +x, camera up = -y)
		var dir := Vector2(axes[i].dot(cam_basis.x), -axes[i].dot(cam_basis.y)) * radius
		var col: Color = AXIS_COLORS[i]
		var width := 1.5 * ui
		var dot_radius := 2.5 * ui
		if not has_constraint:
			col.a = 0.8
		elif i in constraint_indices:
			col.a = 1.0
			width = 3.0 * ui
			dot_radius = 4.0 * ui
		else:
			col.a = 0.25
		overlay.draw_line(anchor, anchor + dir, col, width, true)
		overlay.draw_circle(anchor + dir, dot_radius, col)

	# Text: use the editor theme's font, measure it ourselves (no alignment/width tricks)
	# and put a dark pill behind each line so it is readable on any background.
	var font := overlay.get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font

	var tag_size := maxi(int(11.0 * ui), 10)
	var tag_text := "LOCAL" if is_local else "GLOBAL"
	var tag_w := font.get_string_size(tag_text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size).x
	var tag_y := anchor.y + radius + 22.0 * ui
	var tag_pos := Vector2(anchor.x - tag_w * 0.5, tag_y)
	overlay.draw_rect(Rect2(tag_pos.x - 6.0 * ui, tag_y - tag_size - 1.0 * ui, tag_w + 12.0 * ui, tag_size + 7.0 * ui), Color(0, 0, 0, 0.5))
	overlay.draw_string_outline(font, tag_pos, tag_text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size, 3, Color(0, 0, 0, 0.8))
	overlay.draw_string(font, tag_pos, tag_text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size, Color(1, 1, 1, 0.9))

	# Constrained axis letters, colored per axis and centered under the tag
	if has_constraint:
		var letter_size := maxi(int(16.0 * ui), 12)
		var gap := 6.0 * ui
		var sorted_idx := constraint_indices.duplicate()
		sorted_idx.sort()

		var total := gap * (sorted_idx.size() - 1)
		for i in sorted_idx:
			total += font.get_string_size(AXIS_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, letter_size).x

		var x := anchor.x - total * 0.5
		var letter_y := tag_y + 22.0 * ui
		overlay.draw_rect(Rect2(x - 7.0 * ui, letter_y - letter_size - 1.0 * ui, total + 14.0 * ui, letter_size + 7.0 * ui), Color(0, 0, 0, 0.5))
		for i in sorted_idx:
			var pos := Vector2(x, letter_y)
			overlay.draw_string_outline(font, pos, AXIS_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, letter_size, 4, Color(0, 0, 0, 0.8))
			overlay.draw_string(font, pos, AXIS_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, letter_size, AXIS_COLORS[i])
			x += font.get_string_size(AXIS_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, letter_size).x + gap


# Small status pill at the bottom of the viewport while the reset modal is open.
func _draw_reset_hint(overlay: Control) -> void:
	var ui := EditorInterface.get_editor_scale()
	var font := overlay.get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font

	var title := "Reset %s: %s" % [_reset_title(reset_kind), _reset_axes_text()]
	var hint := "X / Y / Z pick axes (again to undo)  ·  Enter confirm  ·  Esc cancel"
	var title_size := maxi(int(15.0 * ui), 12)
	var hint_size := maxi(int(11.0 * ui), 10)
	var title_w := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size).x
	var hint_w := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hint_size).x
	var width := maxf(title_w, hint_w)

	var center_x := overlay.size.x * 0.5
	var bottom := overlay.size.y - 24.0 * ui
	var hint_y := bottom
	var title_y := bottom - hint_size - 8.0 * ui

	overlay.draw_rect(Rect2(center_x - width * 0.5 - 10.0 * ui, title_y - title_size - 4.0 * ui, width + 20.0 * ui, title_size + hint_size + 20.0 * ui), Color(0, 0, 0, 0.5))
	overlay.draw_string(font, Vector2(center_x - title_w * 0.5, title_y), title, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size, Color(1, 1, 1, 0.95))
	overlay.draw_string(font, Vector2(center_x - hint_w * 0.5, hint_y), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hint_size, Color(1, 1, 1, 0.6))
