extends SceneTree

## Headless tests for the parts that do not need the editor UI.
##
## First time only (registers the addon's class_names):
##   godot --headless --path <project> --import
## Then:
##   godot --headless --path <project> --script res://tests/run_tests.gd
##
## Exit code 0 = all passed.

var _pass := 0
var _fail := 0

func _init() -> void:
    test_math()
    test_atlas_preset()
    test_detector_basic()
    test_detector_hard_normals()
    test_detector_performance()
    test_baker_basic()
    test_baker_split_shared_vertex()
    test_baker_preserves_blend_shapes()
    test_shader_patcher()
    test_key_builder()
    print("\n%d passed, %d failed" % [_pass, _fail])
    quit(1 if _fail > 0 else 0)

# ------------------------------------------------------------------ utils

func check(cond: bool, label: String) -> void:
    if cond:
        _pass += 1
    else:
        _fail += 1
        push_error("FAIL: " + label)
        print("FAIL: ", label)

func near(a: Vector2, b: Vector2, eps: float = 1e-5) -> bool:
    return a.distance_to(b) < eps

## Quad made of two triangles. Vertices are NOT shared with other quads.
func _add_quad(verts: PackedVector3Array, uvs: PackedVector2Array, normals: PackedVector3Array,
        indices: PackedInt32Array, origin: Vector3, uv_origin: Vector2, uv_size: Vector2, normal: Vector3 = Vector3.BACK) -> void:
    var base := verts.size()
    verts.append_array([origin, origin + Vector3.RIGHT, origin + Vector3.RIGHT + Vector3.UP, origin + Vector3.UP])
    uvs.append_array([uv_origin, uv_origin + Vector2(uv_size.x, 0), uv_origin + uv_size, uv_origin + Vector2(0, uv_size.y)])
    for i in 4:
        normals.append(normal)
    indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])

func _mesh_from(verts: PackedVector3Array, uvs: PackedVector2Array, normals: PackedVector3Array, indices: PackedInt32Array) -> ArrayMesh:
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = verts
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices
    var m := ArrayMesh.new()
    m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return m

func _two_quad_mesh() -> ArrayMesh:
    var v := PackedVector3Array(); var u := PackedVector2Array(); var n := PackedVector3Array(); var i := PackedInt32Array()
    _add_quad(v, u, n, i, Vector3(0, 0, 0), Vector2(0.0, 0.0), Vector2(0.4, 0.4))
    _add_quad(v, u, n, i, Vector3(3, 0, 0), Vector2(0.5, 0.5), Vector2(0.4, 0.4))
    return _mesh_from(v, u, n, i)

# ------------------------------------------------------------------ tests

func test_math() -> void:
    var isl := Rect2(0.25, 0.5, 0.25, 0.125)
    var xf := UVIslandMath.compose(isl, Vector2.ZERO, Vector2.ONE, 0.0, false, false, Rect2())
    var p := UVIslandMath.pack(xf)
    check(near(Vector2(p[0].x, p[0].y), Vector2.ZERO) and near(Vector2(p[1].x, p[1].y), Vector2.ZERO), "identity packs to zeros")

    var region := Rect2(0.5, 0.0, 0.125, 0.25)
    xf = UVIslandMath.compose(isl, Vector2.ZERO, Vector2.ONE, 0.0, false, true, region)
    check(near(xf * isl.position, region.position), "atlas maps island min to region min")
    check(near(xf * isl.end, region.end), "atlas maps island max to region max")

    xf = UVIslandMath.compose(isl, Vector2.ZERO, Vector2(2, 2), 0.0, false, false, Rect2())
    check(near(xf * isl.get_center(), isl.get_center()), "scale keeps island center fixed")

    xf = UVIslandMath.compose(isl, Vector2.ZERO, Vector2.ONE, 90.0, false, false, Rect2())
    check(near(xf * isl.get_center(), isl.get_center()), "rotation keeps island center fixed")

    xf = UVIslandMath.compose(isl, Vector2(0.1, 0.2), Vector2.ONE, 0.0, false, false, Rect2())
    var pk := UVIslandMath.pack(xf)
    check(near(UVIslandMath.apply_packed(pk[0], pk[1], Vector2(0.3, 0.6)), Vector2(0.4, 0.8)), "packed offset round trip")

func test_atlas_preset() -> void:
    var a := UVAtlasPreset.new()
    a.generate_grid(2, 2)
    check(a.regions.size() == 4, "grid makes 4 regions")
    check(a.has_region("cell_1_0"), "grid names use col_row")
    check(near(a.get_region_rect("cell_1_0").position, Vector2(0.5, 0.0)), "cell_1_0 is top-right")
    check(a.find_region_at(Vector2(0.75, 0.25)) == "cell_1_0", "find_region_at")
    var r := a.add_region("cell_1_0", Rect2(0, 0, 0.1, 0.1))
    check(r.region_name != "cell_1_0", "duplicate names are made unique")
    check(a.rename_region("cell_0_0", "eyes_open"), "rename")
    check(not a.rename_region("eyes_open", "cell_1_0"), "rename refuses duplicates")
    a.inset = 0.01
    var inner := a.get_region_rect("cell_1_0")
    check(is_equal_approx(inner.size.x, 0.48), "inset shrinks region")
    var snap := a.snapshot()
    a.remove_region("eyes_open")
    a.restore(snap)
    check(a.has_region("eyes_open"), "snapshot/restore")
    a.add_region("bad", Rect2(0.9, 0.9, 0.5, 0.5))
    check(a.validate().size() >= 1, "validate flags out-of-range region")

func test_detector_basic() -> void:
    var res := UVIslandDetector.detect_with_report(_two_quad_mesh(), 0)
    var islands: Array[UVIsland] = res["islands"]
    check(islands.size() == 2, "two separate quads -> 2 islands (got %d)" % islands.size())
    if islands.size() == 2:
        check(islands[0].triangle_count == 2 and islands[1].triangle_count == 2, "2 triangles each")
        check(near(islands[1].uv_min, Vector2(0.5, 0.5)), "island 1 uv_min")

func test_detector_hard_normals() -> void:
    # One quad whose two triangles use SEPARATE vertices (hard edge) but the same
    # positions/UVs along the shared edge. Must remain one island.
    var v := PackedVector3Array(); var u := PackedVector2Array(); var n := PackedVector3Array(); var i := PackedInt32Array()
    v.append_array([Vector3(0,0,0), Vector3(1,0,0), Vector3(1,1,0), Vector3(0,0,0), Vector3(1,1,0), Vector3(0,1,0)])
    u.append_array([Vector2(0,0), Vector2(1,0), Vector2(1,1), Vector2(0,0), Vector2(1,1), Vector2(0,1)])
    for k in 6:
        n.append(Vector3.BACK if k < 3 else Vector3(0, 0.3, 1).normalized())
    i.append_array([0, 1, 2, 3, 4, 5])
    var islands := UVIslandDetector.detect(_mesh_from(v, u, n, i), 0)
    check(islands.size() == 1, "split-normal vertices stay one island (got %d)" % islands.size())

func test_detector_performance() -> void:
    var v := PackedVector3Array(); var u := PackedVector2Array(); var n := PackedVector3Array(); var i := PackedInt32Array()
    var side := 120
    for y in side:
        for x in side:
            _add_quad(v, u, n, i, Vector3(x * 1.1, y * 1.1, 0), Vector2(float(x) / side, float(y) / side), Vector2(0.5 / side, 0.5 / side))
    var m := _mesh_from(v, u, n, i)
    var t0 := Time.get_ticks_msec()
    var islands := UVIslandDetector.detect(m, 0)
    var ms := Time.get_ticks_msec() - t0
    print("perf: %d islands / %d tris in %d ms" % [islands.size(), side * side * 2, ms])
    check(islands.size() == side * side, "every separate quad is an island")
    check(ms < 8000, "detector stays fast on ~29k triangles (%d ms)" % ms)

func test_baker_basic() -> void:
    var mesh := _two_quad_mesh()
    var islands := UVIslandDetector.detect(mesh, 0)
    var res := UVIslandMeshBaker.bake(mesh, islands, 0)
    check(res["mesh"] != null, "bake succeeds: %s" % str(res["errors"]))
    if res["mesh"] == null:
        return
    var baked: ArrayMesh = res["mesh"]
    check(UVIslandMeshBaker.is_baked(baked), "baked mesh is tagged")
    var arrays := baked.surface_get_arrays(0)
    var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
    check(custom.size() == 8, "one custom value per vertex")
    check(custom[0] == 0.0 and custom[4] == 1.0, "ids stored as plain integers")

func test_baker_split_shared_vertex() -> void:
    # Two triangles touching only at ONE shared vertex (index 2), far apart in UV.
    var v := PackedVector3Array([Vector3(0,0,0), Vector3(1,0,0), Vector3(0.5,1,0), Vector3(1,2,0), Vector3(0,2,0)])
    var u := PackedVector2Array([Vector2(0,0), Vector2(0.2,0), Vector2(0.1,0.2), Vector2(0.9,0.9), Vector2(0.7,0.9)])
    var n := PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
    var i := PackedInt32Array([0, 1, 2, 2, 3, 4])
    var mesh := _mesh_from(v, u, n, i)
    var islands := UVIslandDetector.detect(mesh, 0)
    check(islands.size() == 2, "touching-at-a-point triangles are 2 islands (got %d)" % islands.size())
    var res := UVIslandMeshBaker.bake(mesh, islands, 0)
    check(res["mesh"] != null, "bake succeeds with shared vertex: %s" % str(res["errors"]))
    if res["mesh"] != null:
        check(res["split_vertices"] == 1, "exactly one vertex split (got %d)" % res["split_vertices"])
        var arrays := (res["mesh"] as ArrayMesh).surface_get_arrays(0)
        check((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 6, "vertex count grew by 1")
        check((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).size() == 6, "normals duplicated too")
        check((arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() == 6, "uvs duplicated too")

func test_baker_preserves_blend_shapes() -> void:
    var v := PackedVector3Array(); var u := PackedVector2Array(); var n := PackedVector3Array(); var i := PackedInt32Array()
    _add_quad(v, u, n, i, Vector3.ZERO, Vector2.ZERO, Vector2(0.5, 0.5))
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = v
    arrays[Mesh.ARRAY_NORMAL] = n
    arrays[Mesh.ARRAY_TEX_UV] = u
    arrays[Mesh.ARRAY_INDEX] = i
    var shape := []
    shape.resize(Mesh.ARRAY_MAX)
    var moved := PackedVector3Array()
    for p in v:
        moved.append(p + Vector3(0, 0, 0.5))
    shape[Mesh.ARRAY_VERTEX] = moved
    shape[Mesh.ARRAY_NORMAL] = n
    var mesh := ArrayMesh.new()
    mesh.add_blend_shape("push")
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [shape])
    mesh.surface_set_name(0, "skin")
    var res := UVIslandMeshBaker.bake(mesh, UVIslandDetector.detect(mesh, 0), 0)
    check(res["mesh"] != null, "bake with blend shapes succeeds: %s" % str(res["errors"]))
    if res["mesh"] != null:
        var baked: ArrayMesh = res["mesh"]
        check(baked.get_blend_shape_count() == 1 and baked.get_blend_shape_name(0) == "push", "blend shape kept")
        check(baked.surface_get_name(0) == "skin", "surface name kept")

func test_shader_patcher() -> void:
    var code := "shader_type spatial;\n// void vertex() { fake }\nuniform vec4 c;\nvoid vertex() {\n    VERTEX.x += 1.0;\n}\nvoid fragment() { ALBEDO = c.rgb; }\n"
    var r := UVIslandMaterialBuilder.patch_shader_code(code, 0)
    check(String(r["error"]).is_empty(), "patch ok")
    var patched: String = r["code"]
    check(patched.contains("uniform vec4 uvi_m["), "uniform arrays added")
    check(patched.find("uvi_i") > patched.find("void vertex() {\n"), "snippet placed after real vertex(){")
    check(patched.find("uniform vec4 uvi_m[") > patched.find("uniform vec4 c;"), "declared before real vertex()")
    check(patched.find("VERTEX.x += 1.0;") > patched.find("uvi_i"), "user code kept, after our transform")

    var again := UVIslandMaterialBuilder.patch_shader_code(patched, 0)
    check(not String(again["error"]).is_empty(), "double patch is refused")

    var no_vertex := UVIslandMaterialBuilder.patch_shader_code("shader_type spatial;\nvoid fragment() { ALBEDO = vec3(1.0); }\n", 1)
    check(String(no_vertex["error"]).is_empty() and String(no_vertex["code"]).contains("void vertex()"), "adds vertex() when missing")
    check(String(no_vertex["code"]).contains("UV2 = "), "UV channel 1 writes UV2")

    var canvas := UVIslandMaterialBuilder.patch_shader_code("shader_type canvas_item;\nvoid fragment() {}\n", 0)
    check(not String(canvas["error"]).is_empty(), "non-spatial shaders are refused")

func test_key_builder() -> void:
    var root := Node3D.new()
    var player := AnimationPlayer.new()
    player.name = "Player"
    var animator := UVIslandAnimator.new()
    animator.name = "UVIslandAnimator"
    var track := UVIslandTrack.new()
    track.name = "Island_0"
    root.add_child(player)
    root.add_child(animator)
    animator.add_child(track)
    get_root().add_child(root)   # gives player.root_node ".." a valid target

    var anim := Animation.new()
    var plan := UVIslandKeyBuilder.build_plan(UVIslandKeyBuilder.Template.SCROLL, player, track, {"length": 2.0, "amount": 1.0})
    check(plan.size() == 2, "scroll plan has 2 keys")
    check(str(plan[0]["path"]).ends_with(":offset"), "key path targets offset")
    UVIslandKeyBuilder.apply_plan(anim, plan)
    check(anim.get_track_count() == 1 and anim.track_get_key_count(0) == 2, "plan applied")
    UVIslandKeyBuilder.revert_plan(anim, plan)
    check(anim.get_track_count() == 0, "revert removes created track")

    # pre-existing track/key must survive an apply+revert
    var idx := anim.add_track(Animation.TYPE_VALUE)
    anim.track_set_path(idx, plan[0]["path"])
    anim.track_insert_key(idx, 0.0, Vector2(9, 9))
    var plan2 := UVIslandKeyBuilder.build_plan(UVIslandKeyBuilder.Template.SCROLL, player, track, {"length": 2.0})
    UVIslandKeyBuilder.apply_plan(anim, plan2)
    UVIslandKeyBuilder.revert_plan(anim, plan2)
    check(anim.get_track_count() == 1 and anim.track_get_key_value(0, 0) == Vector2(9, 9), "revert restores overwritten key")
    root.queue_free()
