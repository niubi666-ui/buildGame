"""Exports the towers to the game and refreshes the saved .blend. Run from the repository root:

    E:/blender/blender.exe --background --factory-startup --python art/models/towers/export_towers.py

Writes sakura_valley/assets/models/towers/{cannon,catapult,sniper}.glb, then rebuilds the preview
scenes (WindmillTowers, TowerUpgrades) and saves windmill_towers.blend next to this file.
Add `-- --renders` at the end to also re-render the upgrade lineups into previews/.
Godot reimports the .glb files the next time the editor or the game opens the project.
"""

import os
import sys
import time

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(ROOT, "sakura_valley", "assets", "models", "towers")

ns = {"__name__": "windmill_towers"}
with open(os.path.join(HERE, "build_windmill_towers.py"), encoding="utf-8") as f:
	exec(f.read(), ns)

started = time.time()
os.makedirs(OUT, exist_ok=True)
for name, info in ns["export_glb"](OUT.replace("\\", "/")).items():
	print(f"exported {name}.glb: {info['meshes']} meshes, {info['triangles']} triangles")
ns["build"]()
ns["build_lineup"]()
if "--renders" in sys.argv:
	ns["render_lineup"](os.path.join(HERE, "previews").replace("\\", "/"))
for scene in list(bpy.data.scenes):
	if scene.name not in (ns["SCENE_NAME"], ns["LINEUP_NAME"]):
		bpy.data.scenes.remove(scene)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "windmill_towers.blend"))
print(f"done in {time.time() - started:.0f} s")
