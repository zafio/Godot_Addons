# UV Island Animator 1.0

Animate individual UV islands of a mesh with an `AnimationPlayer`: scroll,
scale, rotate, or swap an island onto a named region of an atlas (eyes, mouths,
decals...). Written for Godot 4.7.x (GDScript). Renderer-agnostic: the UV change
is done in the vertex shader.

## Install

Copy `addons/uv_island_animator/` into your project's `addons/` folder and
enable **UV Island Animator** in Project Settings > Plugins.

## Quick start

1. Select a `MeshInstance3D`. Open the **UV Island Animator** dock.
2. **Setup** tab
   1. *Detect UV Islands*
   2. *Bake Island IDs (CUSTOM0)*. Imported meshes: keep "Save baked mesh as .res" on.
   3. *Set Up Animator + Tracks*: adds a `UVIslandAnimator` sibling and one `UVIslandTrack` per island.
   4. *Install Materials (keep my material)*: your textures/settings are kept (see below).
3. **Atlas** tab (optional): assign/create a `UVAtlasPreset`, generate a grid, or open the visual picker.
4. **Animate** tab: pick an `AnimationPlayer`, an island in the Setup list, a template, click *Create Keys*.
5. **Check** tab: *Validate Setup* whenever something looks wrong.

Everything the dock changes to your scene is undoable (Ctrl+Z).

## What each version added

| Version | Feature |
|---|---|
| 0.6 | **Material preservation.** The material's own shader is kept; only a small UV transform is prepended to `vertex()`. Works with `StandardMaterial3D`/`ORMMaterial3D` (all maps, settings, `next_pass`) and text `ShaderMaterial`s. Originals are never modified and can be restored. |
| 0.7 | **Atlas system.** `UVAtlasPreset` resource (named regions, grid generator, inset), reusable as `.tres`. |
| 0.8 | **Visual picker.** Click a region on the texture, or drag to draw a new one. Also available from the Inspector on any `UVIslandTrack`. |
| 0.9 | **One-click animation.** Scroll / Pulse / Rotate / Atlas flipbook / Snapshot-at-playhead templates that write real keys. |
| 1.0 | Multi-surface meshes, vertex splitting when islands share vertices, blend shapes/skinning/surface names preserved, persistence after reload + at runtime, undo/redo, validator, tests. |

## How it works

* **Detection** groups triangles that share an edge with identical position and UV. Hard-normal splits don't break an island.
* **Baking** writes the island id per vertex into `CUSTOM0` (R_FLOAT, `-1` = none).
* **Material** shader gets two `vec4[256]` uniform arrays (one 2x3 affine transform per island, stored as a delta from identity so an all-zero array means "unchanged") and at the start of `vertex()` transforms `UV` (or `UV2`) using the island id from `CUSTOM0`. Doing it per vertex is exactly equivalent to per pixel because the transform is affine, and it is cheaper than the old 32-way branch in the fragment shader.
* Because the transform runs first, the material's own `uv1_scale/offset` still applies after it.

## Track properties (key these)

`offset`, `scale`, `rotation_degrees`, `use_atlas`, `atlas_region` (string, discrete), plus
`pivot_mode` and `atlas_override`. `atlas_min/atlas_max` are used only when no region name is set.

**Order of operations:** atlas remap (island bounding box -> region) -> scale + rotate about pivot -> offset.
Pivot defaults to the island (or region) center; `UV_CENTER` reproduces v0.5.

## Behaviour changes from 0.5

* Scale/rotation pivot defaults to the island center (was 0.5, 0.5).
* Atlas mapping is now island-bounding-box -> region (v0.5 mapped the whole 0..1 texture).
* Island ids are stored as plain integers, so **meshes baked with 0.5 must be re-baked** (tick *Overwrite existing CUSTOM0* if asked).
* Limit is 256 islands per mesh (was 32).
* `UVIslandTrack` nodes are matched by `island_id`, not by node name.

## Known limits

* Triplanar materials ignore mesh UVs, so nothing visible happens there (the validator warns).
* Mesh LODs are dropped on bake (they would be invalid after vertex splitting). Re-import/regenerate if you need them.
* Text `ShaderMaterial` with `shader_type spatial` only. `VisualShader` is converted to a text copy.
* If a shader's `vertex()` already writes `UV` conditionally, the island transform is applied before it.
* Atlas regions assume 0..1 UVs.
* A patched material is a copy: use *Refresh Materials* after editing the original.

See `docs/TESTING.md` for the checklist to run on real character meshes, and `CHANGELOG.md`.
