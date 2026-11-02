@tool
extends EditorPlugin

const CLICK_TOLERANCE_PX: float = 6.0
const DRAG_THRESHOLD_PX: float = 4.0

var _tri_cache: Dictionary = {}   # Mesh -> TriangleMesh
var _surf_cache: Dictionary = {}  # Mesh -> Array of surface Dictionaries
var _press_pos: Vector2 = Vector2.ZERO
var _press_valid: bool = false
var _press_additive: bool = false
var _press_selection: Array = []


func _enter_tree() -> void:
    set_input_event_forwarding_always_enabled()
    scene_changed.connect(_on_scene_changed)


func _exit_tree() -> void:
    _tri_cache.clear()
    _surf_cache.clear()


func _on_scene_changed(_scene_root: Node) -> void:
    _tri_cache.clear()
    _surf_cache.clear()


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
    var mb: InputEventMouseButton = event as InputEventMouseButton
    if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
        return AFTER_GUI_INPUT_PASS

    if mb.pressed:
        _press_pos = mb.position
        _press_valid = not (mb.alt_pressed or mb.meta_pressed)
        _press_additive = mb.shift_pressed or mb.ctrl_pressed
        _press_selection = EditorInterface.get_selection().get_selected_nodes().duplicate()
        return AFTER_GUI_INPUT_PASS

    if not _press_valid:
        return AFTER_GUI_INPUT_PASS
    _press_valid = false
    if mb.position.distance_to(_press_pos) > DRAG_THRESHOLD_PX:
        return AFTER_GUI_INPUT_PASS

    var root: Node = EditorInterface.get_edited_scene_root()
    if root == null:
        return AFTER_GUI_INPUT_PASS

    var picked: MeshInstance3D = _pick(camera, mb.position, root)
    if picked != null:
        _apply_selection.call_deferred(picked, root, _press_additive, _press_selection.duplicate())
    return AFTER_GUI_INPUT_PASS


func _apply_selection(mesh: Node, root: Node, additive: bool, previous: Array) -> void:
    # Make sure the mesh is reachable in the Scene dock
    var n: Node = mesh.get_parent()
    while n != null and n != root:
        if n.scene_file_path != "":
            root.set_editable_instance(n, true)
        n = n.get_parent()

    var sel: EditorSelection = EditorInterface.get_selection()
    sel.clear()

    if not additive:
        sel.add_node(mesh)
        return

    var was_selected: bool = false
    for prev in previous:
        var pn: Node = prev as Node
        if pn == null or not is_instance_valid(pn):
            continue
        if pn == mesh:
            was_selected = true
            continue  # toggled off
        sel.add_node(pn)
    if not was_selected:
        sel.add_node(mesh)


func _pick(camera: Camera3D, screen_pos: Vector2, root: Node) -> MeshInstance3D:
    var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
    var ray_dir: Vector3 = camera.project_ray_normal(screen_pos)

    var meshes: Array[MeshInstance3D] = []
    _find_meshes(root, meshes)

    var best: MeshInstance3D = null
    var best_dist: float = INF
    var skinned: Dictionary = {}  # MeshInstance3D -> Array of PackedVector3Array

    # Pass 1: exact triangle hits
    for mi: MeshInstance3D in meshes:
        var d: float = INF
        var skel: Skeleton3D = mi.get_node_or_null(mi.skeleton) as Skeleton3D
        if skel != null:
            var wv_list: Array = _skin_mesh(mi, skel)
            skinned[mi] = wv_list
            d = _hit_world_surfaces(mi, wv_list, ray_origin, ray_dir)
        else:
            d = _rigid_hit(mi, ray_origin, ray_dir)
        if d < best_dist:
            best_dist = d
            best = mi

    if best != null:
        return best

    # Pass 2: near misses within a few pixels of the click
    var px_scale: float = _pixel_scale(camera)
    var persp: bool = camera.projection != Camera3D.PROJECTION_ORTHOGONAL
    var best_px: float = CLICK_TOLERANCE_PX
    for mi: MeshInstance3D in meshes:
        var wv_list2: Array = []
        if skinned.has(mi):
            wv_list2 = skinned[mi]
        else:
            wv_list2 = _skin_mesh(mi, null)
        var px: float = _near_miss_px(wv_list2, ray_origin, ray_dir, px_scale, persp)
        if px < best_px:
            best_px = px
            best = mi
    return best


func _pixel_scale(camera: Camera3D) -> float:
    var vp_size: Vector2 = camera.get_viewport().get_visible_rect().size
    if vp_size.x <= 0.0 or vp_size.y <= 0.0:
        vp_size = Vector2(800.0, 600.0)
    var span: float = vp_size.y
    if camera.keep_aspect == Camera3D.KEEP_WIDTH:
        span = vp_size.x
    if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
        return camera.size / span
    return 2.0 * tan(deg_to_rad(camera.fov) * 0.5) / span


func _near_miss_px(wv_list: Array, ray_origin: Vector3, ray_dir: Vector3, px_scale: float, persp: bool) -> float:
    var best_px: float = INF
    for s: int in range(wv_list.size()):
        var wv: PackedVector3Array = wv_list[s]
        for i: int in range(wv.size()):
            var rel: Vector3 = wv[i] - ray_origin
            var t: float = rel.dot(ray_dir)
            if t <= 0.0:
                continue
            var perp: float = (rel - ray_dir * t).length()
            var px_world: float = px_scale
            if persp:
                px_world = px_scale * t
            if px_world <= 0.0:
                continue
            var px: float = perp / px_world
            if px < best_px:
                best_px = px
    return best_px


func _rigid_hit(mi: MeshInstance3D, ray_origin: Vector3, ray_dir: Vector3) -> float:
    var tm: TriangleMesh = _get_tri_mesh(mi.mesh)
    if tm == null:
        return INF
    var xf: Transform3D = mi.global_transform
    var inv: Transform3D = xf.affine_inverse()
    var hit: Dictionary = tm.intersect_ray(inv * ray_origin, inv.basis * ray_dir)
    if hit.is_empty():
        return INF
    var local_pos: Vector3 = hit["position"]
    return ray_origin.distance_to(xf * local_pos)


func _hit_world_surfaces(mi: MeshInstance3D, wv_list: Array, ray_origin: Vector3, ray_dir: Vector3) -> float:
    var surfaces: Array = _get_surfaces(mi.mesh)
    var closest: float = INF
    for s: int in range(wv_list.size()):
        var wv: PackedVector3Array = wv_list[s]
        if wv.size() == 0:
            continue
        var surf: Dictionary = surfaces[s]
        var indices: PackedInt32Array = surf["indices"]

        # Cheap bounds test to skip surfaces the ray can't reach
        var box: AABB = AABB(wv[0], Vector3.ZERO)
        for i: int in range(1, wv.size()):
            box = box.expand(wv[i])
        box = box.grow(box.get_longest_axis_size() * 0.01 + 0.000001)
        if box.intersects_ray(ray_origin, ray_dir) == null:
            continue

        var tri_count: int = wv.size() / 3
        if indices.size() > 0:
            tri_count = indices.size() / 3
        for t: int in range(tri_count):
            var i0: int = t * 3
            var i1: int = t * 3 + 1
            var i2: int = t * 3 + 2
            if indices.size() > 0:
                i0 = indices[i0]
                i1 = indices[i1]
                i2 = indices[i2]
            var hit: Variant = Geometry3D.ray_intersects_triangle(
                ray_origin, ray_dir, wv[i0], wv[i1], wv[i2])
            if hit != null:
                var hp: Vector3 = hit
                var dist: float = ray_origin.distance_to(hp)
                if dist < closest:
                    closest = dist
    return closest


# Returns world-space vertices for each surface (skinned if a skeleton is given).
func _skin_mesh(mi: MeshInstance3D, skel: Skeleton3D) -> Array:
    var out: Array = []
    if mi.mesh == null:
        return out

    var poses: Array[Transform3D] = []
    if skel != null:
        var skin: Skin = mi.skin
        if skin == null:
            skin = skel.create_skin_from_rest_transforms()
        for i: int in range(skin.get_bind_count()):
            var b: int = skin.get_bind_bone(i)
            if b < 0:
                b = skel.find_bone(skin.get_bind_name(i))
            if b < 0:
                poses.append(Transform3D.IDENTITY)
            else:
                poses.append(skel.get_bone_global_pose(b) * skin.get_bind_pose(i))

    var mesh_xf: Transform3D = mi.global_transform
    var surfaces: Array = _get_surfaces(mi.mesh)
    for s: int in range(surfaces.size()):
        var surf: Dictionary = surfaces[s]
        var verts: PackedVector3Array = surf["verts"]
        var bones: PackedInt32Array = surf["bones"]
        var weights: PackedFloat32Array = surf["weights"]
        var bpv: int = surf["bpv"]
        var has_skin: bool = skel != null and bpv > 0

        var wv: PackedVector3Array = PackedVector3Array()
        wv.resize(verts.size())
        for vi: int in range(verts.size()):
            var v: Vector3 = verts[vi]
            var p: Vector3 = v
            if has_skin:
                p = Vector3.ZERO
                for k: int in range(bpv):
                    var w: float = weights[vi * bpv + k]
                    if w <= 0.0:
                        continue
                    var bi: int = bones[vi * bpv + k]
                    if bi >= 0 and bi < poses.size():
                        p += (poses[bi] * v) * w
            wv[vi] = mesh_xf * p
        out.append(wv)
    return out


func _get_surfaces(m: Mesh) -> Array:
    if _surf_cache.has(m):
        return _surf_cache[m]
    var list: Array = []
    for s: int in range(m.get_surface_count()):
        var surf: Dictionary = {}
        var verts: PackedVector3Array = PackedVector3Array()
        var bones: PackedInt32Array = PackedInt32Array()
        var weights: PackedFloat32Array = PackedFloat32Array()
        var indices: PackedInt32Array = PackedInt32Array()
        var bpv: int = 0

        if m.surface_get_primitive_type(s) == Mesh.PRIMITIVE_TRIANGLES:
            var arrays: Array = m.surface_get_arrays(s)
            var verts_v: Variant = arrays[Mesh.ARRAY_VERTEX]
            if verts_v != null:
                verts = verts_v
            var bones_v: Variant = arrays[Mesh.ARRAY_BONES]
            if bones_v != null:
                bones = bones_v
            var weights_v: Variant = arrays[Mesh.ARRAY_WEIGHTS]
            if weights_v != null:
                weights = weights_v
            var indices_v: Variant = arrays[Mesh.ARRAY_INDEX]
            if indices_v != null:
                indices = indices_v
            if verts.size() > 0 and bones.size() > 0 and weights.size() > 0:
                bpv = bones.size() / verts.size()

        surf["verts"] = verts
        surf["bones"] = bones
        surf["weights"] = weights
        surf["indices"] = indices
        surf["bpv"] = bpv
        list.append(surf)
    _surf_cache[m] = list
    return list


func _get_tri_mesh(m: Mesh) -> TriangleMesh:
    if m == null:
        return null
    if not _tri_cache.has(m):
        _tri_cache[m] = m.generate_triangle_mesh()
    return _tri_cache[m] as TriangleMesh


func _find_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
    var mi: MeshInstance3D = n as MeshInstance3D
    if mi != null and mi.is_visible_in_tree():
        out.append(mi)
    for c: Node in n.get_children():
        _find_meshes(c, out)