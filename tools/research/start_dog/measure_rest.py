"""Пропорции модели в позе покоя: высота в холке (верх меша над передними лапами), полная высота, длина."""
import bpy
from mathutils import Vector
mesh = next(o for o in bpy.data.objects if o.type == 'MESH')
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
dg = bpy.context.evaluated_depsgraph_get()
me = mesh.evaluated_get(dg).to_mesh()
vs = [mesh.matrix_world @ v.co for v in me.vertices]
b = arm.data.bones
ys = (b['FrontShoulder.L'].head_local.y)
zmin = min(v.z for v in vs); zmax = max(v.z for v in vs)
wz = max(v.z for v in vs if abs(v.y - ys) < 0.15)
print("RES y_shoulder %.3f zmin %.3f zmax %.3f withers %.3f len %.3f width %.3f" % (ys, zmin, zmax, wz, max(v.y for v in vs)-min(v.y for v in vs), max(v.x for v in vs)-min(v.x for v in vs)))
print("RES body len (torso) %.3f" % (b['Back'].head_local.y - b['Neck1'].head_local.y))
print("RES tris", sum(len(p.vertices)-2 for p in me.polygons), "mats", [m.name for m in mesh.data.materials])
for k in range(-22, 16):
    y0 = k * 0.1
    zs = [v.z for v in vs if y0 <= v.y < y0 + 0.1]
    if zs: print("PROF y=%.1f top=%.3f bot=%.3f" % (y0, max(zs), min(zs)))
