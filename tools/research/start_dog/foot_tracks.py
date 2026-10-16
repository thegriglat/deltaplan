"""Траектории стоп (концы костей FF.*/FFB.*) по кадрам действия: печать y,z в единицах модели (до масштаба)."""
import bpy, sys
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
act_names = argv or ["Walk", "Gallop"]
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
feet = ["FF.L", "FF.R", "FFB.L", "FFB.R"]
sc = bpy.context.scene
for an in act_names:
    act = bpy.data.actions[an]
    arm.animation_data.action = act
    f0, f1 = int(act.frame_range[0]), int(act.frame_range[1])
    for f in range(f0, f1 + 1):
        sc.frame_set(f)
        row = []
        for n in feet:
            p = arm.matrix_world @ arm.pose.bones[n].tail
            row.append("%.3f,%.3f" % (p.y, p.z))
        body = arm.matrix_world @ arm.pose.bones["Body"].head
        print("TRK %s %d %s body=%.3f,%.3f,%.3f" % (an, f, " ".join(row), body.x, body.y, body.z))
