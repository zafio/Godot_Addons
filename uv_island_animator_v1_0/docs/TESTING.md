# Testing

## 1. Headless unit tests

```
godot --headless --path <your_project> --import          # once, registers class_names
godot --headless --path <your_project> --script res://tests/run_tests.gd
```
Copy `tests/` into the project (or adjust the path). Exit code 0 = pass.

Covered: affine math, atlas resource, detector (basic, hard normals, performance),
baker (ids, shared-vertex split, blend shapes/names), shader patcher, key builder apply/revert.

## 2. Things that need the editor (not covered by the headless tests)

Run these once on 4.7.2 before trusting a release:

- [ ] Plugin enables with no errors in the Output panel.
- [ ] Material install on a `StandardMaterial3D` with albedo + normal + ORM + emission: looks identical before and after (compare screenshots). If the dock warns "Exact conversion failed", note the reason.
- [ ] Same for a hand-written spatial `ShaderMaterial`.
- [ ] Setting a track's `offset` moves only that island.
- [ ] Vec4 arrays: if uniforms don't update, flip `USE_COLOR_ARRAY` to `true` in `uv_island_material_builder.gd`.
- [ ] Save scene, close, reopen: animation still works, no re-bake needed.
- [ ] Run the game: animation works at runtime.
- [ ] Ctrl+Z / Ctrl+Y through: bake, setup, install materials, atlas edit, create keys.
- [ ] Atlas picker: draw region, rename, delete, generate grid, click to assign.
- [ ] Create Keys with each template; scrub in the Animation panel.
- [ ] Snapshot: pose a track, move playhead, "Key Current Values at Playhead".

## 3. Real character mesh checklist

For each of your characters (glb/gltf import):

- [ ] Detect: island count is plausible; time is reasonable (a 100k-triangle mesh should be seconds, not minutes).
- [ ] Bake reports split vertices (fine) and no errors. Skinned mesh still deforms correctly with its Skeleton3D/Skin.
- [ ] Blend shapes (visemes/expressions) still work after bake.
- [ ] Multiple surfaces (body/eyes/hair): every surface with islands has a patched material; surfaces without UVs are untouched.
- [ ] Mirrored/overlapping UV halves: check the island list; animate one half and confirm only that half changes.
- [ ] Eyes/mouth flipbook: create an atlas grid or regions, run the Flipbook template, check for edge bleeding (raise `inset` if needed).
- [ ] Mesh with UVs outside 0..1 (tiling): validator shows an info line; confirm expected behaviour.
- [ ] Re-import the glb: the baked `.res` is a copy, so re-bake after re-import.
- [ ] Validate tab shows no errors.
