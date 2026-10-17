"""Осмотр .blend Quaternius: кости, ограничения, действия, ключи IK."""
import bpy, sys
for o in bpy.data.objects:
    print("OBJ", o.name, o.type, tuple(round(v,3) for v in o.location), tuple(round(v,3) for v in o.scale), tuple(round(v,3) for v in o.rotation_euler), o.dimensions[:])
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
for pb in arm.pose.bones:
    b = pb.bone
    cons = [(c.type, getattr(c,'subtarget','')) for c in pb.constraints]
    print("BONE", b.name, "parent", b.parent.name if b.parent else None, "deform", b.use_deform,
          "head", tuple(round(v,3) for v in b.head_local), "tail", tuple(round(v,3) for v in b.tail_local), cons)
for a in bpy.data.actions:
    fr = a.frame_range
    groups = sorted({fc.data_path.split('"')[1] for fc in a.fcurves if '"' in fc.data_path})
    print("ACT", a.name, tuple(fr), len(a.fcurves), groups)
print("fps", bpy.context.scene.render.fps)
