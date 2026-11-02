# Changelog

## 1.0.0
* Multi-surface meshes: islands carry their surface; each surface gets its own patched material.
* Vertices shared by two islands are split during bake instead of refusing to bake.
* Bake preserves blend shapes, 4/8 bone weights, custom channels 1-3, surface names, materials, custom_aabb.
* Islands and patched materials persist in the scene; works after reload and at runtime.
* All dock actions use EditorUndoRedoManager (bake, setup, materials, atlas edits, keys).
* `UVIslandValidator` + Check tab.
* Headless tests in `tests/run_tests.gd`.
* Non-destructive track creation (existing keyed tracks are never freed).

## 0.9.0
* `UVIslandKeyBuilder`: Scroll, Pulse, Rotate, Atlas flipbook, Snapshot templates; undoable.

## 0.8.0
* `UVAtlasPicker` control and `UVAtlasPickerDialog`; Inspector button on `UVIslandTrack`.

## 0.7.0
* `UVAtlasPreset` / `UVAtlasRegion` resources, grid generator, inset, snapshot/restore.
* `UVIslandTrack.atlas_region` (enum drop-down from the atlas), `atlas_override`.

## 0.6.0
* Material preservation: patch the material's own shader instead of replacing it.

## Fixed bugs found in 0.5
* Baker used `Mesh.ARRAY_FORMAT_CUSTOM_R_FLOAT`, which does not exist (correct: `Mesh.ARRAY_CUSTOM_R_FLOAT`).
* Shader builder emitted a literal `\n` (double-escaped) into the shader source, which breaks compilation.
* Islands and materials were not saved with the scene, so nothing worked after reload or at runtime.
* Detection was O(n^2) in triangles and merged overlapping mirrored shells.
* `create_tracks()` freed nodes and re-added the same names in the same frame (names got mangled).
