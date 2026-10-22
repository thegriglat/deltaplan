"""TT-8: поза sit из assets/models/pilot.glb -> pilot_sit.json (кости, пустышки кистей, вершины тела без рук).
Запуск (из корня): blender -b --python tools/research/tow-trike/extract_sit.py
Оси Blender от карабина (как trike_params.json): x вправо, y вперёд, z вверх, м."""
import json
import bpy

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath="assets/models/pilot.glb")
arm = bpy.data.objects["Pilot"]
arm.animation_data_create()
act = bpy.data.actions["sit_Pilot"]
arm.animation_data.action = act
bpy.context.scene.frame_set(int(act.frame_range[0]))
bpy.context.view_layer.update()
out = {"bones": {}, "empties": {}}
for b in arm.pose.bones:
    out["bones"][b.name] = [[round(x, 4) for x in arm.matrix_world @ b.head],
                            [round(x, 4) for x in arm.matrix_world @ b.tail]]
for n in ("HandL", "HandR", "Head", "WristL", "WristR"):
    out["empties"][n] = [round(x, 4) for x in bpy.data.objects[n].matrix_world.translation]
ob0 = bpy.data.objects["PilotBody"]
names = {i: g.name for i, g in enumerate(ob0.vertex_groups)}
dg = bpy.context.evaluated_depsgraph_get()
ob = ob0.evaluated_get(dg)
me = ob.to_mesh()
ARM = ("UpperArm", "Forearm", "Hand")
pts, arm_pts = [], []
for v, v0 in zip(me.vertices, ob0.data.vertices):
    g = max(v0.groups, key=lambda a: a.weight) if v0.groups else None
    nm = names[g.group] if g else ""
    p = [round(x, 4) for x in ob.matrix_world @ v.co]
    (arm_pts if nm.startswith(ARM) else pts).append(p)
out["body_pts"] = pts
out["arm_pts"] = arm_pts
json.dump(out, open("tools/research/tow-trike/pilot_sit.json", "w"))
print("PTS", len(pts), "ARM", len(arm_pts))
