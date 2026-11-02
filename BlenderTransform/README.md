# Blender Transform

Blender-style G / R / S transforms for the Godot 4 3D editor.

## Install
Copy `blender_transform.gd` and `plugin.cfg` to `addons/blender_transform/`, then enable it in Project Settings → Plugins.

## Use
Select a Node3D, hover the 3D viewport and press a key. Plain keys only (Ctrl+S etc. are untouched).

| Key | Action |
|---|---|
| **G / R / S** | Move / Rotate / Scale (switch any time) |
| **R** again | Rotate: toggle view-plane ↔ turntable |
| **X / Y / Z** | Constrain; press again to cycle (see below) |
| **MMB** | Lock the axis you are moving along; in a plane lock, swap the plane (XY ↔ XZ) |
| **Shift+X/Y/Z** | Lock the plane *excluding* that axis |
| **0-9 . - ⌫** | Type a value (distance, degrees, scale factor) |
| **Ctrl / Shift** | Snap / precision |
| **Enter, Space, LMB** | Confirm |
| **Esc, RMB** | Cancel |
| **Alt+G / R / S** | Clear position / rotation / scale, then **X / Y / Z** limit it to those axes (press an axis again to undo it; none = all) |

## Axis cycle
Repeat X/Y/Z to step through:

- **Use Local Space off:** global axis → global plane → local axis → local plane → none
- **Use Local Space on:** local axis → local plane → global axis → global plane → none

The plane pairs your axis with the other axis that faces the camera (front view: X, X = XY).

## Notes
- A gizmo under the selection shows GLOBAL/LOCAL and the locked axes.
- The cursor wraps at the viewport edges so you can drag indefinitely (`CONTINUOUS_GRAB`).
- S is ignored while an AnimationPlayer plays, so Godot's animation Stop still works (`YIELD_S_TO_ANIMATION`).
- Both options are constants at the top of the script.
